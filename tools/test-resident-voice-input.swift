// Headless production App event handling and voice preferences; no microphone/network.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let app = try String(contentsOf: sourceRoot.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
func declaration(_ signature: String, _ source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)"); exit(1)
    }
    var depth = 0
    for i in source[opening...].indices {
        if source[i] == "{" { depth += 1 }
        if source[i] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...i]) }
    }
    fatalError("unbalanced declaration")
}
let consume = declaration("private func consumeResidentVoiceEvent(", app)
let shutdown = declaration("private func enqueueResidentVoiceShutdown(", app)
let listener = declaration("residentVoiceEventTask = Task", app)
let config = try String(contentsOf: sourceRoot.appendingPathComponent("Settings/AgentSettingsModel.swift"), encoding: .utf8)
let configuration = declaration("struct RealtimeVoiceConfiguration:", config)
let preferences = declaration("final class RealtimeVoicePreferences", config)
let harness = #"""
import Foundation
enum RealtimeDJProvider: String, Sendable { case bailian, elevenLabs = "elevenlabs", doubao }
\#(configuration)
\#(preferences)
struct Level { let peak: Double }
struct Failure { let message: String }
enum RealtimeDJEvent {
    case userTranscriptFinal(String), userTranscriptDelta(String), userSpeechStarted, userSpeechFinished, userAudioLevel(Level)
    case failure(Failure), connectionChanged(Connection), agentTranscriptFinal(String), agentAudioStarted
}
enum Connection { case connected, disconnected }
enum VoiceState: Equatable { case disconnected, connecting, connected, listening, failed(String) }
@MainActor protocol RealtimeDJSession: AnyObject {
    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws
    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws
    func disconnect() async
}
@MainActor final class Trace { var entries: [String] = [] }
@MainActor final class ConnectGate { var continuation: CheckedContinuation<Void, Never>? }
@MainActor final class Session: RealtimeDJSession {
    let trace: Trace
    var beforeDisconnect: (() -> Void)?
    var disconnectGate: CheckedContinuation<Void, Never>?
    var suspendDisconnect = false
    init(_ trace: Trace) { self.trace = trace }
    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws { trace.entries.append("capture:\(enabled)") }
    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws { trace.entries.append("transmit:\(enabled)") }
    func disconnect() async {
        trace.entries.append("disconnect"); beforeDisconnect?()
        if suspendDisconnect { await withCheckedContinuation { disconnectGate = $0 } }
    }
}
@MainActor final class Panel {
    func setVoiceLevel<T: BinaryFloatingPoint>(_ level: T) {}
}
@MainActor final class App {
    var residentVoiceRequestID: UUID?
    var residentVoiceAcceptsFinal = true
    var residentVoiceSession: (any RealtimeDJSession)?
    var residentVoiceEventTask: Task<Void, Never>?
    var residentVoiceShutdownTask: Task<Void, Never>?
    var residentVoiceShutdownGeneration: UInt64 = 0
    var realtimeVoiceTimeoutTask: Task<Void, Never>?
    var stageWindowController: Panel? = Panel()
    var orbWindowController: Panel? = Panel()
    var state = VoiceState.connected
    var statuses: [String] = []
    let trace = Trace()
    func setRealtimeVoiceState(_ state: VoiceState) { self.state = state }
    func showResidentVoiceStatus(_ text: String) { statuses.append(text) }
    func showResidentVoiceFailure(_ text: String) { statuses.append(text) }
    func sendLiveCamMessage(_ text: String) async {
        disconnectRealtimeVoice()
        trace.entries.append(Task.isCancelled ? "cancelled-send" : "send:\(text)")
    }
    func disconnectRealtimeVoice() {
        residentVoiceRequestID = nil; residentVoiceAcceptsFinal = false
        residentVoiceEventTask?.cancel(); residentVoiceEventTask = nil
    }
    \#(consume)
    \#(shutdown)
    private func clearResidentVoiceShutdown(generation: UInt64) {
        guard residentVoiceShutdownGeneration == generation else { return }
        residentVoiceShutdownTask = nil
    }
    func receive(_ event: RealtimeDJEvent, id: UUID, session: Session) async {
        await consumeResidentVoiceEvent(event, requestID: id, session: session)
    }
    func awaitShutdown() async { await residentVoiceShutdownTask?.value }
    func stopSession(_ session: Session, after task: Task<Void, Never>) -> Task<Void, Never> {
        enqueueResidentVoiceShutdown(session, after: task)
    }
    func listen(_ events: AsyncStream<RealtimeDJEvent>, requestID: UUID, session: Session) -> Task<Void, Never> {
        \#(listener)
        return residentVoiceEventTask!
    }
}
@MainActor var failures = 0
@MainActor var checks = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(label)") }
}
@main struct Main {
    @MainActor static func main() async {
        let app = App(); let id = UUID(); let session = Session(app.trace)
        app.residentVoiceRequestID = id
        await app.receive(.userTranscriptFinal(" 去点歌 "), id: id, session: session)
        check(app.trace.entries == ["capture:false", "transmit:false", "disconnect", "send:去点歌"], "microphone and ASR close before selected Agent receives final")
        await app.receive(.userTranscriptFinal("重复"), id: id, session: session)
        check(app.trace.entries.count == 4, "duplicate final ignored")
        let listening = App(); listening.residentVoiceRequestID = id
        let listeningSession = Session(listening.trace)
        let forwarding = Task { await listening.receive(.userTranscriptFinal("完整转交"), id: id, session: listeningSession) }
        listening.residentVoiceEventTask = forwarding
        await forwarding.value
        check(listening.trace.entries.last == "send:完整转交", "ASR final forwarding does not cancel its own Agent request")
        let streamApp = App(); streamApp.residentVoiceRequestID = id
        let stream = AsyncStream<RealtimeDJEvent>.makeStream()
        let streamTask = streamApp.listen(stream.stream, requestID: id, session: Session(streamApp.trace))
        var listenerFinished = false
        let observer = Task { await streamTask.value; listenerFinished = true }
        stream.continuation.yield(.userTranscriptFinal("结束监听"))
        for _ in 0..<200 { await Task.yield() }
        check(listenerFinished, "final reply ends listener without waiting for stream finish")
        stream.continuation.finish()
        await observer.value
        let partial = App(); partial.residentVoiceRequestID = id
        await partial.receive(.userTranscriptDelta("去"), id: id, session: Session(partial.trace))
        await partial.receive(.userTranscriptDelta("去点歌"), id: id, session: Session(partial.trace))
        check(partial.statuses.last == "正在转写：去点歌" && partial.trace.entries.isEmpty, "interim text replaces display without submitting")
        let cancelled = App(); let cancelledSession = Session(cancelled.trace)
        cancelled.residentVoiceRequestID = nil
        await cancelled.receive(.userTranscriptFinal("取消后迟到"), id: id, session: cancelledSession)
        check(cancelled.trace.entries.isEmpty, "cancelled final ignored")
        let superseded = App(); let old = UUID(); let new = UUID()
        superseded.residentVoiceRequestID = new
        await superseded.receive(.userTranscriptFinal("旧录音"), id: old, session: Session(superseded.trace))
        check(superseded.trace.entries.isEmpty, "old recording cannot close newer microphone or send")
        let racing = App(); racing.residentVoiceRequestID = id
        let slow = Session(racing.trace)
        slow.beforeDisconnect = { racing.residentVoiceRequestID = new }
        await racing.receive(.userTranscriptFinal("关闭过程中取消"), id: id, session: slow)
        check(!racing.trace.entries.contains(where: { $0.hasPrefix("send:") }), "new capture during disconnect prevents stale send")
        let queued = App(); queued.residentVoiceRequestID = id
        let blocked = Session(queued.trace); blocked.suspendDisconnect = true
        let completing = Task { await queued.receive(.userTranscriptFinal("older"), id: id, session: blocked) }
        while blocked.disconnectGate == nil { await Task.yield() }
        queued.residentVoiceRequestID = new
        let newCapture = Task { await queued.awaitShutdown(); queued.trace.entries.append("new-capture") }
        await Task.yield()
        check(!queued.trace.entries.contains("new-capture"), "new recording waits for suspended final cleanup")
        blocked.disconnectGate?.resume(); blocked.disconnectGate = nil
        await completing.value; await newCapture.value
        check(queued.trace.entries.last == "new-capture", "old cleanup finishes before new capture begins")
        let stuck = App(); let handshake = ConnectGate()
        let connecting = Task { await withCheckedContinuation { handshake.continuation = $0 } }
        while handshake.continuation == nil { await Task.yield() }
        let stuckSession = Session(stuck.trace)
        stuckSession.beforeDisconnect = {
            handshake.continuation?.resume(); handshake.continuation = nil
        }
        connecting.cancel()
        let cleanup = stuck.stopSession(stuckSession, after: connecting)
        for _ in 0..<100 { await Task.yield() }
        check(stuck.trace.entries.contains("disconnect"), "disconnect unblocks a handshake that ignores Task cancellation")
        handshake.continuation?.resume(); handshake.continuation = nil
        await cleanup.value
        let empty = App(); empty.residentVoiceRequestID = id
        await empty.receive(.userTranscriptFinal("  "), id: id, session: Session(empty.trace))
        check(!empty.trace.entries.contains(where: { $0.hasPrefix("send:") }), "empty final never submits")
        let configured = RealtimeVoiceConfiguration(provider: .bailian, apiKey: "fixture-only", agentID: nil, conversationToken: nil, voiceID: nil, model: nil, appID: nil, accessToken: nil, resourceID: nil)
        check(configured.isReadyForResidentTranscription, "ASR only needs key; no voice or answer model required")
        let suite = "resident-voice-preferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let voicePreferences = RealtimeVoicePreferences(defaults: defaults)
        check(voicePreferences.load().provider == .bailian && voicePreferences.loadMetadata().provider == .bailian, "fresh install defaults to supported transcription provider")
        defaults.set("elevenlabs", forKey: RealtimeVoicePreferences.providerKey)
        check(voicePreferences.load().provider == .elevenLabs, "saved provider choice is preserved")
        check(voicePreferences.replyVoiceID == "Cherry", "reply voice defaults independently from legacy Omni voice")
        voicePreferences.saveReplyVoiceID("Serena")
        check(RealtimeVoicePreferences(defaults: defaults).replyVoiceID == "Serena", "reply voice survives preference reload")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident single-utterance voice checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-voice-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Voice.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let process = Process()
let executable = temporary.appendingPathComponent("voice-test")
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", program.path, "-o", executable.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let test = Process()
test.executableURL = executable
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
