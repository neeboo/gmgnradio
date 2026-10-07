// Compile the production playback lifecycle. Only the audio device is replaced.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift")
let program = #"""
import Foundation
@MainActor final class Device: AgentSpeechAudioDevice {
    var onFinished: (@MainActor (Bool) -> Void)?
    var canStart = true
    var power: Float = -20
    var samples = 0
    var stopped = false
    func start() -> Bool { canStart }
    func stop() { stopped = true }
    func measuredDecibels() -> Float { samples += 1; return power }
}
@MainActor final class Events { var states: [AgentSpeechPlaybackState] = [] }
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ good: Bool, _ message: String) { guard good else { fatalError("FAIL: " + message) }; count += 1 }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds: 3_000_000) }
            fatalError("FAIL: playback event did not arrive")
        }
        check(AgentSpeechPlaybackState.idle == .init(isPlaying: false, level: 0), "idle is explicitly silent")
        for value: Float in [.nan, .infinity, -.infinity, -160, -60] {
            check(AgentSpeechPlaybackState.normalizedLevel(decibels: value) == 0, "silence and invalid meter readings are zero")
        }
        check(abs(AgentSpeechPlaybackState.normalizedLevel(decibels: -20) - 0.1) < 0.001, "decibels convert to linear amplitude")
        check(AgentSpeechPlaybackState.normalizedLevel(decibels: 12) == 1, "loud signal is bounded")
        check(AgentSpeechPlaybackState(isPlaying: false, level: 1).level == 0 && AgentSpeechPlaybackState(isPlaying: true, level: .nan).level == 0, "state never carries inactive or nonfinite volume")
        let first = Device(), second = Device(), rejected = Device()
        rejected.canStart = false
        var devices = [first, second, rejected]
        let playback = AgentSpeechAudioPlayer(makeDevice: { _ in devices.removeFirst() })
        let firstEvents = Events()
        let firstTask = Task { try await playback.play(Data(), onPlaybackChanged: { firstEvents.states.append($0) }) }
        try await waitFor { first.samples > 0 }
        check(firstEvents.states.contains { $0.isPlaying && $0.level > 0 }, "successful device start emits measured playback")
        try await Task.sleep(nanoseconds: 115_000_000)
        check((2...5).contains(first.samples), "metering is about twenty updates per second")
        first.power = -160
        try await waitFor { firstEvents.states.last == .init(isPlaying: true, level: 0) }
        check(firstEvents.states.last?.level == 0, "silent audio keeps mouth level zero during playback")
        let oldFinish = first.onFinished
        first.onFinished?(true)
        try await firstTask.value
        check(firstEvents.states.last == .idle && first.stopped, "completion synchronously clears playback and device")
        let sampleCount = first.samples
        try await Task.sleep(nanoseconds: 60_000_000)
        check(first.samples == sampleCount, "completion ends metering work")

        let secondEvents = Events()
        let secondTask = Task { try await playback.play(Data(), onPlaybackChanged: { secondEvents.states.append($0) }) }
        try await waitFor { second.samples > 0 }
        let beforeOldCallback = secondEvents.states.count
        oldFinish?(false)
        check(secondEvents.states.count == beforeOldCallback && !second.stopped, "late completion cannot end newer playback")
        playback.stop()
        check(secondEvents.states.last == .idle && second.stopped, "explicit stop clears level immediately")
        do { try await secondTask.value; fatalError("FAIL: stop must cancel waiter") }
        catch { check(error is CancellationError, "stop ends playback waiter") }

        let failureEvents = Events()
        do { try await playback.play(Data(), onPlaybackChanged: { failureEvents.states.append($0) }); fatalError("FAIL: failed device start") }
        catch { check(!failureEvents.states.contains { $0.isPlaying } && failureEvents.states.last == .idle, "failed play never opens mouth") }

        let brokenDevice = Device(), brokenEvents = Events()
        let broken = AgentSpeechAudioPlayer(makeDevice: { _ in brokenDevice })
        let decoding = Task { try await broken.play(Data(), onPlaybackChanged: { brokenEvents.states.append($0) }) }
        try await waitFor { brokenDevice.samples > 0 }
        brokenDevice.onFinished?(false)
        do { try await decoding.value; fatalError("FAIL: failed playback must throw") }
        catch { check(brokenEvents.states.last == .idle && brokenDevice.stopped, "decoder failure during playback closes mouth and stops device") }

        let creationEvents = Events()
        let invalid = AgentSpeechAudioPlayer(makeDevice: { _ in throw BailianTTSError.playback })
        do { try await invalid.play(Data(), onPlaybackChanged: { creationEvents.states.append($0) }); fatalError("FAIL: invalid audio device") }
        catch { check(creationEvents.states == [.idle], "device creation failure emits only idle") }

        let cancelledDevice = Device(), cancellationEvents = Events()
        let cancellable = AgentSpeechAudioPlayer(makeDevice: { _ in cancelledDevice })
        let cancelled = Task { try await cancellable.play(Data(), onPlaybackChanged: { cancellationEvents.states.append($0) }) }
        try await waitFor { cancelledDevice.samples > 0 }
        cancelled.cancel()
        do { try await cancelled.value; fatalError("FAIL: cancelled playback") }
        catch { check(error is CancellationError && cancellationEvents.states.last == .idle, "Task cancellation clears playback state") }
        print("PASS: \(count) speech playback checks")
    }
}
"""#
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-playback-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let main = folder.appendingPathComponent("Checks.swift"), binary = folder.appendingPathComponent("checks")
try program.write(to: main, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-disable-sandbox", "-j1", "-swift-version", "6", "-parse-as-library", source.path,
    source.deletingLastPathComponent().appendingPathComponent("RustVoiceClient.swift").path,
    source.deletingLastPathComponent().appendingPathComponent("../Presence/TaskdHTTPTransport.swift").path,
    source.deletingLastPathComponent().appendingPathComponent("StreamingPCMPlayer.swift").path,
    main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
