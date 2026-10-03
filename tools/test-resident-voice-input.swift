// Executes production Rust push-to-talk handlers with device/network boundaries injected.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let app = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"), encoding: .utf8)
func declaration(_ signature: String, _ source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { fatalError("missing \(signature)") }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unbalanced declaration")
}
let production = ["func disconnectRealtimeVoice()", "private func clearResidentVoiceShutdown(",
                  "func finishResidentVoiceFromStage()", "private func failResidentVoice(",
                  "private func consumeResidentVoiceEvent("].map { declaration($0, app) }.joined(separator: "\n")
let settings = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Settings/AgentSettingsModel.swift"), encoding: .utf8)
let preferences = declaration("final class RustSpeechPreferences", settings)
let harness = #"""
import Foundation
enum RustVoiceProvider: String { case bailian, elevenlabs, fish }
struct RustVoiceConfiguration { let provider: RustVoiceProvider; let apiKey: String; let voiceID: String; let model: String? }
enum E2ERuntime { static var defaults: UserDefaults { .standard } }
enum RealtimeVoicePreferences { static let replyVoiceIDKey = "speech.bailian.voiceID" }
\#(preferences)
struct RealtimeDJAudioLevel: Sendable { let peak: Double }
struct RustVoiceEvent: Sendable { let type: String; let text: String? }
enum State { case disconnected, failed(String) }
@MainActor final class Trace { var entries: [String] = [] }
@MainActor final class RustVoiceSession {
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    func cancel() { trace.entries.append("cancel") }
    func commit() async throws { trace.entries.append("commit") }
}
@MainActor final class PushToTalkAudioCapture {
    let trace: Trace
    var stopGate: CheckedContinuation<Void, Never>?
    var suspendStop = false
    init(_ trace: Trace) { self.trace = trace }
    func stop() async {
        trace.entries.append("stop")
        if suspendStop { await withCheckedContinuation { stopGate = $0 } }
    }
    func cancel() async { trace.entries.append("capture-cancel") }
}
@MainActor final class Panel { func setVoiceLevel<T: BinaryFloatingPoint>(_ level: T) {} }
@MainActor final class Announcer { func stop() {} }
@MainActor final class App {
    let trace = Trace()
    var residentVoiceRequestID: UUID?
    var residentVoiceAcceptsFinal = true
    var residentVoiceDidCommit = false
    var residentVoiceAudioBytes = 0
    var residentVoiceCapturedPeak: Double = 0
    var residentVoiceLastFinalReceived = false
    var residentVoiceEmptyFinalCount = 0
    var residentVoiceLastFinal = ""
    var residentVoiceSubmittedFinalCount = 0
    var residentVoiceSession: RustVoiceSession?
    var residentVoiceCapture: PushToTalkAudioCapture?
    var residentVoiceAudioContinuation: AsyncStream<(Data, RealtimeDJAudioLevel)>.Continuation?
    var residentVoiceAudioTask: Task<Void, Never>?
    var residentVoiceCommitTask: Task<Void, Never>?
    var residentVoiceEventTask: Task<Void, Never>?
    var residentVoiceShutdownTask: Task<Void, Never>?
    var residentVoiceShutdownGeneration: UInt64 = 0
    var realtimeVoiceConnectionTask: Task<Void, Never>?
    var realtimeVoiceTimeoutTask: Task<Void, Never>?
    var orbWindowController: Panel? = Panel()
    var stageWindowController: Panel? = Panel()
    let agentSpeechAnnouncer = Announcer()
    var statuses: [String] = []
    func setRealtimeVoiceState(_ state: State) {}
    func showResidentVoiceStatus(_ text: String) { statuses.append(text) }
    func showResidentVoiceFailure(_ text: String) { statuses.append(text) }
    func armResidentVoiceTimeout(requestID: UUID, seconds: Int, message: String) {}
    func sendLiveCamMessage(_ text: String) async {
        disconnectRealtimeVoice()
        trace.entries.append(Task.isCancelled ? "cancelled-send" : "send:\(text)")
    }
    \#(production)
    func receive(_ type: String, text: String? = nil, id: UUID) async {
        await consumeResidentVoiceEvent(RustVoiceEvent(type: type, text: text), requestID: id,
                                       session: residentVoiceSession ?? RustVoiceSession(trace))
    }
    func prepare(_ id: UUID, bytes: Int = 320) {
        residentVoiceRequestID = id; residentVoiceAcceptsFinal = true
        residentVoiceAudioBytes = bytes
        residentVoiceSession = RustVoiceSession(trace)
        residentVoiceCapture = PushToTalkAudioCapture(trace)
    }
}
@MainActor var failures = 0
@MainActor var checks = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}
@main struct Main {
    @MainActor static func main() async {
        let id = UUID()
        let final = App(); final.prepare(id); final.residentVoiceDidCommit = true
        await final.receive("final", text: " 去点歌 ", id: id)
        check(final.trace.entries.prefix(2).elementsEqual(["cancel", "send:去点歌"]), "Rust session cancelled before trimmed final enters selected Agent")
        await final.receive("final", text: "重复", id: id)
        check(final.residentVoiceSubmittedFinalCount == 1, "duplicate final ignored")
        let partial = App(); partial.prepare(id)
        await partial.receive("partial", text: "去", id: id)
        await partial.receive("partial", text: "去点歌", id: id)
        check(partial.statuses.last == "正在转写：去点歌" && partial.trace.entries.isEmpty, "partial replaces display without submitting")
        await partial.receive("final", text: "提前", id: id)
        check(partial.residentVoiceSubmittedFinalCount == 0, "final before manual commit cannot submit")
        let stale = App(); stale.prepare(UUID()); stale.residentVoiceDidCommit = true
        await stale.receive("final", text: "旧会话", id: id)
        check(stale.trace.entries.isEmpty, "old generation cannot close new recording or send")
        let empty = App(); empty.prepare(id); empty.residentVoiceDidCommit = true
        await empty.receive("final", text: "  ", id: id)
        check(empty.residentVoiceSubmittedFinalCount == 0 && empty.residentVoiceLastFinalReceived && empty.residentVoiceEmptyFinalCount == 1, "empty final is observable but never submits")
        let forwarding = App(); forwarding.prepare(id); forwarding.residentVoiceDidCommit = true
        let forwardingTask = Task { await forwarding.receive("final", text: "完整转交", id: id) }
        forwarding.residentVoiceEventTask = forwardingTask
        await forwardingTask.value
        check(forwarding.trace.entries.contains("send:完整转交") && !forwarding.trace.entries.contains("cancelled-send"), "shared Agent sender does not self-cancel final forwarding")
        let connecting = App(); connecting.prepare(id)
        connecting.realtimeVoiceConnectionTask = Task { try? await Task.sleep(for: .seconds(10)) }
        connecting.finishResidentVoiceFromStage()
        await connecting.residentVoiceShutdownTask?.value
        check(connecting.residentVoiceRequestID == nil && !connecting.trace.entries.contains("commit"), "release during connection cancels without late recording or commit")
        let commit = App(); commit.prepare(id)
        commit.residentVoiceAudioTask = Task { commit.trace.entries.append("audio-drained") }
        commit.finishResidentVoiceFromStage()
        let commitTask = commit.residentVoiceCommitTask
        commit.finishResidentVoiceFromStage()
        await commitTask?.value
        check(commit.trace.entries.contains("stop") && commit.trace.entries.contains("audio-drained") && commit.trace.entries.last == "commit", "capture stops and sender drains before commit")
        check(commit.trace.entries.filter { $0 == "commit" }.count == 1, "repeated release commits once")
        let noAudio = App(); noAudio.prepare(id, bytes: 0)
        noAudio.finishResidentVoiceFromStage(); await noAudio.residentVoiceCommitTask?.value
        check(!noAudio.trace.entries.contains("commit"), "zero captured bytes never commit")
        let stopping = App(); stopping.prepare(id)
        let capture = stopping.residentVoiceCapture!; capture.suspendStop = true
        stopping.finishResidentVoiceFromStage()
        while capture.stopGate == nil { await Task.yield() }
        let stoppingTask = stopping.residentVoiceCommitTask
        stopping.residentVoiceRequestID = UUID()
        capture.stopGate?.resume(); capture.stopGate = nil
        await stoppingTask?.value
        check(!stopping.trace.entries.contains("commit"), "superseded release cannot commit into new generation")
        let ended = App(); ended.prepare(id)
        await ended.receive("finished", id: id)
        check(ended.residentVoiceRequestID == nil && ended.residentVoiceSubmittedFinalCount == 0, "finished without final fails without delivery")
        let suite = "rust-voice-preferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = RustSpeechPreferences(defaults: defaults)
        check(prefs.provider(for: "asr", includesEnvironment: false) == .bailian, "fresh preferences default to supported ASR")
        defaults.set("test-bailian-key", forKey: "voice.bailian.apiKey")
        check(prefs.configuration(for: "asr", includesEnvironment: false).apiKey == "test-bailian-key", "existing Bailian key reused within injected suite")
        prefs.save(RustVoiceConfiguration(provider: .elevenlabs, apiKey: "test-eleven-key", voiceID: "test-voice", model: nil), for: "tts")
        check(prefs.provider(for: "tts", includesEnvironment: false) == .elevenlabs && prefs.provider(for: "asr", includesEnvironment: false) == .bailian, "TTS and ASR provider choices remain independent")
        prefs.save(RustVoiceConfiguration(provider: .elevenlabs, apiKey: "test-eleven-key", voiceID: "", model: nil), for: "asr")
        check(RustSpeechPreferences(defaults: defaults).configuration(for: "tts", includesEnvironment: false).voiceID == "test-voice", "ASR save preserves TTS voice ID across reload")
        prefs.save(RustVoiceConfiguration(provider: .fish, apiKey: "test-fish-key", voiceID: "test-reference", model: nil), for: "tts")
        check(prefs.configuration(for: "tts", includesEnvironment: false).provider == .fish, "Fish TTS choice persists without fallback")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) Rust push-to-talk production checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-voice-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Voice.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let executable = temporary.appendingPathComponent("voice-test")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", program.path, "-o", executable.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = executable
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
