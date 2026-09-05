// Real Bailian wire/transport/mapper, with only the socket and audio hardware replaced.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VoiceSession/Providers/Bailian/BailianRealtimeEventMapper.swift")
let contracts = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VoiceSession/RealtimeDJSession.swift")
let program = #"""
import Foundation
struct PlaybackContext: Codable, Equatable, Sendable {}
struct ProgramHostHint: Codable, Equatable, Sendable {}
struct StageVisualMood: Codable, Equatable, Sendable {}
struct DJAgentRadioState: Codable, Equatable, Sendable {}
enum ProductIdentity { static let bundleIdentifier = "fixture.gmgn.asr" }
enum DJAgentCapabilityManifest { static var providerTools: [[String: Any]] { [["name": "forbidden_fixture_tool"]] } }
struct DJRealtimePromptBuilder {
    func build(context: RealtimeDJContext?) throws -> String { fatalError("FAIL: ASR must never build DJ prompt") }
}
enum BailianPCMCodec { static func audioLevel(for: Data) -> RealtimeDJAudioLevel { .init(rms: 0, peak: 0) } }
@MainActor final class AudioGraphController {
    var playbackCount = 0
    var capture: (@Sendable (Data, RealtimeDJAudioLevel) -> Void)?
    func startBailianMicrophoneCapture(preferredDeviceID: String?, _ capture: @escaping @Sendable (Data, RealtimeDJAudioLevel) -> Void) throws { self.capture = capture }
    func stopBailianMicrophoneCapture() { capture = nil }
    func stopDJVoice() {}
    func playBailianVoicePCM(_ data: Data) throws { playbackCount += 1 }
    func waitForDJVoiceDrain() async {}
}
@MainActor final class FakeSocket: BailianWebSocketConnection {
    var sent: [[String: Any]] = []
    var incoming: [Data] = []
    var waiting: CheckedContinuation<Data, Error>?
    var closed = false
    var holdClose = false
    var autoHandshake = true
    var pauseAudioSend = false
    var audioSendWaiter: CheckedContinuation<Void, Never>?
    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        sent.append(value)
        if value["type"] as? String == "input_audio_buffer.append", pauseAudioSend {
            await withCheckedContinuation { audioSendWaiter = $0 }
        }
        if value["type"] as? String == "session.update", autoHandshake {
            push(["type": "session.updated", "session": ["model": "qwen3-asr-flash-realtime"]])
        }
    }
    func receive() async throws -> Data {
        if closed { throw CancellationError() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() { closed = true; if !holdClose { waiting?.resume(throwing: CancellationError()); waiting = nil } }
    func failReceive() { waiting?.resume(throwing: URLError(.cancelled)); waiting = nil }
    func push(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        if let waiting { self.waiting = nil; waiting.resume(returning: data) }
        else { incoming.append(data) }
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ result: Bool, _ label: String) { guard result else { fatalError("FAIL: " + label) }; checks += 1 }
        func data(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let legacyData = data(["apiKey": "fixture", "model": "qwen3.5-omni-flash-realtime", "voiceID": "fixture"])
        let legacy = try JSONDecoder().decode(BailianSessionPayload.self, from: legacyData)
        check(legacy.purpose == .dj, "old saved payload stays DJ compatible")
        let payload = BailianSessionPayload(apiKey: "fixture", model: legacy.model, voiceID: "fixture", purpose: .residentTranscription)
        let request = try BailianRealtimeWireProtocol.makeRequest(payload: payload)
        check(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "model" }?.value == "qwen3-asr-flash-realtime", "resident always uses recognition model")
        let configured = try JSONSerialization.jsonObject(with: BailianRealtimeWireProtocol.sessionUpdateData(payload: payload, instructions: "PRIVATE DJ PROMPT")) as! [String: Any]
        let session = configured["session"] as! [String: Any]
        check(Set(session.keys) == ["input_audio_format", "sample_rate", "turn_detection"], "only documented ASR session fields")
        check(session["input_audio_format"] as? String == "pcm" && session["sample_rate"] as? Int == 16000, "existing mono PCM input format")
        check((session["turn_detection"] as? [String: Any])?["type"] as? String == "server_vad", "ASR acoustic VAD")
        let oldWire = try JSONSerialization.jsonObject(with: BailianRealtimeWireProtocol.sessionUpdateData(payload: legacy, instructions: "fixture")) as! [String: Any]
        check((oldWire["session"] as? [String: Any])?["voice"] as? String == "fixture", "legacy DJ wire unchanged")
        let preview = try BailianRealtimeWireProtocol.decode(data(["type": "conversation.item.input_audio_transcription.text", "text": "去点唱机", "stash": "放音乐"]))
        var mapper = BailianRealtimeEventMapper()
        check(mapper.map(preview.event) == [.userTranscriptDelta("去点唱机放音乐")], "ASR cumulative text plus stash maps to preview")
        let failed = try BailianRealtimeWireProtocol.decode(data(["type": "conversation.item.input_audio_transcription.failed", "item_id": "failed", "error": ["code": "invalid_audio", "message": "fixture recognition failed"]]))
        let failures = mapper.map(failed.event)
        check(failures.count == 1 && { if case .failure = failures.first! { return true }; return false }(), "ASR failure reaches existing error UI")

        let socket = FakeSocket(), audio = AudioGraphController()
        let transport = BailianWebSocketRealtimeTransport(audioGraph: audio, connectionFactory: { _ in socket })
        let stream = await transport.eventStream()
        var observed: [ProviderRealtimeEvent] = []
        let collector = Task { for await event in stream { observed.append(event) } }
        try await transport.connect(payload: payload)
        check(socket.sent.count == 1, "connect sends only ASR configuration")
        try await transport.updateContext(Data("INVALID DJ CONTEXT".utf8))
        check(socket.sent.count == 1, "resident ignores DJ context without decoding it")
        do { try await transport.requestAgentResponse("forbidden"); fatalError("FAIL: second reasoning model") }
        catch { check(true, "resident rejects proactive DJ response") }
        do { try await transport.submitToolResult(.init(callID: "forbidden", resultJSON: Data(), isError: false)); fatalError("FAIL: second tool loop") }
        catch { check(true, "resident rejects realtime tool results") }
        try await transport.interrupt()
        check(socket.sent.count == 1, "interrupt never sends unsupported ASR response.cancel")
        try await transport.setMicrophoneCaptureEnabled(true)
        try await transport.setMicrophoneTransmissionEnabled(true)
        audio.capture?(Data(repeating: 0, count: 3200), .init(rms: 0.2, peak: 0.3))
        for _ in 0..<200 { await Task.yield() }
        check(socket.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "real capture callback sends PCM through socket")
        socket.push(["type": "conversation.item.input_audio_transcription.text", "text": "去点唱机", "stash": "放音乐", "item_id": "first"])
        for _ in 0..<2 { socket.push(["type": "conversation.item.input_audio_transcription.completed", "transcript": "去点唱机放音乐", "item_id": "first"]) }
        socket.push(["type": "conversation.item.input_audio_transcription.completed", "transcript": "去点唱机放音乐", "item_id": "second"])
        for _ in 0..<300 { await Task.yield() }
        check(observed.filter { $0.type == "conversation.item.input_audio_transcription.completed" }.count == 2, "item dedup drops duplicate delivery but permits repeated utterance")
        socket.push(["type": "response.audio.delta", "delta": Data(repeating: 0, count: 16).base64EncodedString()])
        socket.push(["type": "response.function_call_arguments.done", "name": "forbidden", "call_id": "bad", "arguments": "{}"])
        for _ in 0..<300 { await Task.yield() }
        check(audio.playbackCount == 0, "unexpected agent audio never reaches speaker")
        check(!observed.contains { $0.type.hasPrefix("response.") }, "unexpected agent and tool events never leave ASR transport")
        check(!socket.sent.contains { ["response.create", "response.cancel", "conversation.item.create"].contains($0["type"] as? String ?? "") }, "ASR wire has no response or tool command")
        await transport.disconnect(); collector.cancel()
        check(socket.closed, "disconnect closes its socket")

        // Closing an IO boundary does not guarantee that its pending completion vanishes.
        let oldAudio = FakeSocket(), newSocket = FakeSocket(), lateAudioGraph = AudioGraphController()
        oldAudio.holdClose = true
        var choices = [oldAudio, newSocket]
        let reconnecting = BailianWebSocketRealtimeTransport(audioGraph: lateAudioGraph, connectionFactory: { _ in choices.removeFirst() })
        try await reconnecting.connect(payload: payload)
        try await reconnecting.setMicrophoneCaptureEnabled(true)
        try await reconnecting.setMicrophoneTransmissionEnabled(true)
        let oldCapture = lateAudioGraph.capture
        for _ in 0..<200 { await Task.yield() }
        await reconnecting.disconnect()
        oldAudio.push(["type": "response.audio.delta", "delta": Data(repeating: 0, count: 16).base64EncodedString()])
        for _ in 0..<200 { await Task.yield() }
        check(lateAudioGraph.playbackCount == 0, "late response after disconnect cannot fall through into DJ playback")
        try await reconnecting.connect(payload: payload)
        try await reconnecting.setMicrophoneCaptureEnabled(true)
        try await reconnecting.setMicrophoneTransmissionEnabled(true)
        oldCapture?(Data(repeating: 0, count: 3200), .init(rms: 0.2, peak: 0.3))
        for _ in 0..<200 { await Task.yield() }
        check(!newSocket.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "old microphone callback cannot send into new connection")
        await reconnecting.disconnect()

        let oldError = FakeSocket(), healthy = FakeSocket(), errorAudio = AudioGraphController()
        oldError.holdClose = true
        var errorChoices = [oldError, healthy]
        let errors = BailianWebSocketRealtimeTransport(audioGraph: errorAudio, connectionFactory: { _ in errorChoices.removeFirst() })
        try await errors.connect(payload: payload)
        for _ in 0..<200 { await Task.yield() }
        try await errors.connect(payload: payload)
        try await errors.setMicrophoneCaptureEnabled(true)
        try await errors.setMicrophoneTransmissionEnabled(true)
        oldError.failReceive()
        for _ in 0..<200 { await Task.yield() }
        errorAudio.capture?(Data(repeating: 0, count: 3200), .init(rms: 0.2, peak: 0.3))
        for _ in 0..<200 { await Task.yield() }
        check(!healthy.closed && healthy.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "late URL cancellation cannot fail new session")
        await errors.disconnect()

        let oldHandshake = FakeSocket(), activeHandshake = FakeSocket()
        oldHandshake.autoHandshake = false; oldHandshake.holdClose = true
        var handshakeChoices = [oldHandshake, activeHandshake]
        let handshakes = BailianWebSocketRealtimeTransport(audioGraph: AudioGraphController(), connectionFactory: { _ in handshakeChoices.removeFirst() })
        let handshakeStream = await handshakes.eventStream()
        var connections = 0
        let handshakeCollector = Task { for await event in handshakeStream { if event.type == "connection.connected" { connections += 1 } } }
        let pendingHandshake = Task { try await handshakes.connect(payload: payload) }
        for _ in 0..<200 { await Task.yield() }
        try await handshakes.connect(payload: payload)
        oldHandshake.push(["type": "session.updated"])
        let staleResult = await pendingHandshake.result
        for _ in 0..<200 { await Task.yield() }
        check({ if case .failure = staleResult { return true }; return false }() && connections == 1 && !activeHandshake.closed, "late handshake is rejected without reconnecting or closing current session")
        await handshakes.disconnect(); handshakeCollector.cancel()

        let pausedSocket = FakeSocket(), pausedAudio = AudioGraphController()
        pausedSocket.pauseAudioSend = true
        let paused = BailianWebSocketRealtimeTransport(audioGraph: pausedAudio, connectionFactory: { _ in pausedSocket })
        try await paused.connect(payload: payload)
        try await paused.setMicrophoneCaptureEnabled(true)
        try await paused.setMicrophoneTransmissionEnabled(true)
        pausedAudio.capture?(Data(repeating: 0, count: 9600), .init(rms: 0.2, peak: 0.3))
        for _ in 0..<200 { await Task.yield() }
        check(pausedSocket.audioSendWaiter != nil, "audio fixture pauses first actual frame send")
        try await paused.setMicrophoneTransmissionEnabled(false)
        pausedSocket.pauseAudioSend = false; pausedSocket.audioSendWaiter?.resume(); pausedSocket.audioSendWaiter = nil
        for _ in 0..<200 { await Task.yield() }
        check(pausedSocket.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count == 1, "disabling transmission during send stops remaining buffered frames")
        await paused.disconnect()
        print("PASS: \(checks) resident ASR checks")
    }
}
"""#
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-asr-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let main = work.appendingPathComponent("Checks.swift")
try program.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("checks")
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", source.path, contracts.path, main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binary; try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
