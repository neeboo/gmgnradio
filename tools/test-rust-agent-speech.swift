import Foundation

let production = ["AgentSpeech.swift", "RustVoiceClient.swift", "StreamingPCMPlayer.swift"].map {
    "apps/macos/Sources/GMGNRadio/Agent/\($0)"
}
let playerSource = try String(contentsOfFile: production[2], encoding: .utf8)
func audioCallbacksAreNonisolated(_ source: String) -> Bool {
    source.contains("block: StreamingPCMCallbacks.tap(onLevel: onLevel)")
        && source.contains("completionHandler: StreamingPCMCallbacks.played(onPlayed: onPlayed)")
}
guard audioCallbacksAreNonisolated(playerSource),
      !audioCallbacksAreNonisolated(playerSource.replacingOccurrences(
        of: "block: StreamingPCMCallbacks.tap(onLevel: onLevel)", with: "block: unsafeActorInheritedTap")),
      !audioCallbacksAreNonisolated(playerSource.replacingOccurrences(
        of: "completionHandler: StreamingPCMCallbacks.played(onPlayed: onPlayed)", with: "completionHandler: unsafeActorInheritedCompletion")) else {
    fatalError("production callback wiring or negative controls failed")
}
let program = #"""
import Foundation
import AVFoundation

final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = -1
    private var played = false
    private var mainThread = false
    func measured(_ value: Float) { lock.lock(); level = value; mainThread = Thread.isMainThread; lock.unlock() }
    func completed() { lock.lock(); played = true; mainThread = mainThread || Thread.isMainThread; lock.unlock() }
    func valid() -> Bool { lock.lock(); defer { lock.unlock() }; return level == 0.5 && played && !mainThread }
}

@MainActor final class Device: StreamingPCMDevice {
    var samples: [[Float]] = []
    var callbacks: [@Sendable () -> Void] = []
    var stopped = false
    var level: (@Sendable (Float) -> Void)?
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws { level = onLevel; stopped = false }
    func schedule(_ samples: [Float], onPlayed: @escaping @Sendable () -> Void) throws {
        self.samples.append(samples); callbacks.append(onPlayed)
    }
    func stop() { stopped = true }
    func drain() { let old = callbacks; callbacks.removeAll(); for callback in old { callback() } }
}

@MainActor final class Stream: RustVoiceStreaming {
    let sessionID = UUID().uuidString
    var events: [RustVoiceEvent] = []
    var closed = false
    var cancelled = false
    func nextEvent() async throws -> RustVoiceEvent {
        guard !events.isEmpty else { throw RustVoiceError.invalidFrame }
        return events.removeFirst()
    }
    func cancel() { cancelled = true; closed = true }
    func close() { closed = true }
    func audio(_ bytes: Data, rate: Int = 24000) {
        events.append(.init(sessionID: sessionID, type: "audio", audioBase64: bytes.base64EncodedString(), sampleRate: rate, channels: 1, encoding: "pcm16le", text: nil, code: nil))
    }
    func end() { events.append(.init(sessionID: sessionID, type: "finished", audioBase64: nil, sampleRate: nil, channels: nil, encoding: nil, text: nil, code: nil)) }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: " + message) }; checks += 1
        }
        func until(_ message: String, _ condition: @MainActor () -> Bool) async throws {
            let end = Date().addingTimeInterval(2)
            while !condition() {
                guard Date() < end else { fatalError("timeout " + message) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        check(try StreamingPCMOutputRoute.overrideUID(environment: ["GMGN_E2E_VOICE_OUTPUT_DEVICE_UID": "explicit-test-output"]) == nil,
              "production ignores output override without E2E root")
        check(try StreamingPCMOutputRoute.overrideUID(environment: ["GMGN_E2E_DATA_ROOT": "/isolated", "GMGN_E2E_VOICE_OUTPUT_DEVICE_UID": "explicit-test-output"]) == "explicit-test-output",
              "isolated run accepts only its explicit UID")
        check(try StreamingPCMOutputRoute.overrideUID(environment: ["GMGN_E2E_DATA_ROOT": "/isolated"]) == nil,
              "no implicit route choice for isolated run")
        do {
            _ = try StreamingPCMOutputRoute.overrideUID(environment: ["GMGN_E2E_DATA_ROOT": "/isolated", "GMGN_E2E_VOICE_OUTPUT_DEVICE_UID": " "])
            fatalError("empty explicit device accepted")
        } catch { check(true, "invalid explicit UID fails without fallback") }
        let callbackState = CallbackState()
        let tap = StreamingPCMCallbacks.tap { callbackState.measured($0) }
        let played = StreamingPCMCallbacks.played { callbackState.completed() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
                buffer.frameLength = 4
                for index in 0..<4 { buffer.floatChannelData![0][index] = 0.5 }
                tap(buffer, AVAudioTime(hostTime: 0))
                played(.dataPlayedBack)
                continuation.resume()
            }
        }
        check(callbackState.valid(), "production AV tap and played callbacks run off MainActor without isolation assertion")
        var decoder = PCM16LEDecoder()
        check(decoder.decode(Data([0xff])).isEmpty, "odd byte held")
        check(decoder.decode(Data([0x7f, 0, 0x80])) == [Float(32767)/32768, -1], "cross chunk exact signed samples")
        check(decoder.trailingByte == nil, "trailing byte consumed")

        let device = Device(), player = StreamingPCMPlayer(makeDevice: { device })
        try player.begin { _ in }
        let many = Data(repeating: 0, count: 32768)
        let producer = Task { try await player.append(many) }
        try await until("bounded queue") { device.samples.count == 2 }
        check(player.peakQueuedFrames <= StreamingPCMPlayer.maximumQueuedFrames, "bounded device queue")
        check(device.samples.count == 2, "producer pauses before overflow")
        device.drain()
        try await producer.value
        var finished = false
        let drain = Task { try await player.finish(); finished = true }
        try await Task.sleep(for: .milliseconds(20))
        check(!finished, "synthesis complete still awaits actual played callbacks")
        device.drain(); try await drain.value
        check(finished && device.stopped, "played callbacks settle queue")

        let oddDevice = Device(), oddPlayer = StreamingPCMPlayer(makeDevice: { oddDevice })
        try oddPlayer.begin { _ in }; try await oddPlayer.append(Data([1]))
        do { try await oddPlayer.finish(); fatalError("odd input accepted") }
        catch { check(true, "incomplete last sample rejected") }
        oddPlayer.stop()

        let liveDevice = Device(), livePlayer = StreamingPCMPlayer(makeDevice: { liveDevice })
        let stream = Stream(); stream.audio(Data([0, 32])); stream.end()
        var outcomes: [AgentSpeechOutcome] = []
        var forwarded = false
        let speech = RustSpeechSynthesizer(configuration: { .init(provider: .fish, apiKey: "fixture-memory-only", voiceID: "reference") },
            statusStore: AgentSpeechStatusStore(), player: livePlayer, start: { text, settings in
                forwarded = text == "hello" && settings.provider == .fish && settings.voiceID == "reference"
                return stream
            })
        check(speech.speak("hello", completion: { outcomes.append($0) }), "Rust utterance starts")
        try await until("first PCM before drain") { liveDevice.samples.count == 1 }
        check(forwarded && outcomes.isEmpty, "provider forwarded and no early completion")
        liveDevice.drain()
        try await until("finished") { outcomes == [.finished] }
        check(stream.closed, "finished stream closed")

        let cancelledStream = Stream(); cancelledStream.audio(Data([0, 32])); cancelledStream.end()
        let cancelDevice = Device(), cancelPlayer = StreamingPCMPlayer(makeDevice: { cancelDevice })
        var cancelledOutcomes: [AgentSpeechOutcome] = [], lipEvents: [AgentSpeechPlaybackState] = []
        let cancelledSpeech = RustSpeechSynthesizer(configuration: { .init(apiKey: "fixture") },
            statusStore: AgentSpeechStatusStore(), player: cancelPlayer, onPlaybackChanged: { lipEvents.append($0) },
            start: { _, _ in cancelledStream })
        _ = cancelledSpeech.speak("cancel", completion: { cancelledOutcomes.append($0) })
        try await until("cancel queued") { cancelDevice.samples.count == 1 }
        let oldLevel = cancelDevice.level
        cancelledSpeech.stopSpeaking()
        let count = lipEvents.count
        cancelDevice.drain(); oldLevel?(1)
        try await Task.sleep(for: .milliseconds(30))
        check(cancelDevice.stopped && cancelledStream.cancelled, "cancel stops device and Rust session")
        check(cancelledOutcomes == [.cancelled], "cancel exactly once; old drain cannot finish")
        check(lipEvents.count == count, "old metering cannot animate new generation")

        let malformed = Stream(); malformed.audio(Data([0, 32]), rate: 16000); malformed.end()
        var failed: [AgentSpeechOutcome] = []
        let reject = RustSpeechSynthesizer(configuration: { .init(apiKey: "fixture") }, statusStore: AgentSpeechStatusStore(),
            player: StreamingPCMPlayer(makeDevice: { Device() }), start: { _, _ in malformed })
        _ = reject.speak("wrong format", completion: { failed.append($0) })
        try await until("invalid format") { failed == [.failed] }
        check(malformed.closed, "invalid stream closes without fallback")
        print("PASS: \(checks) production Rust speech / bounded PCM / drained completion / cancellation checks")
    }
}
"""#

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-rust-speech-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let driver = scratch.appendingPathComponent("main.swift"), binary = scratch.appendingPathComponent("checks")
try program.write(to: driver, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/env")
compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library"] + production + [driver.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit(); guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let checks = Process(); checks.executableURL = binary
try checks.run(); checks.waitUntilExit(); exit(checks.terminationStatus)
