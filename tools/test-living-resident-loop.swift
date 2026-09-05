// Runs the real conversation service and Live Cam send method without the app,
// credentials, a model request, or an Xcode test host.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let app = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { fatalError("Missing \(signature)") }
    var depth = 0
    for i in source[opening...].indices {
        if source[i] == "{" { depth += 1 }
        if source[i] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...i]) }
    }
    fatalError("Unbalanced \(signature)")
}
let sendMethod = declaration("private func sendLiveCamMessage(", in: app)
let harness = #"""
import Foundation

struct FixtureLocator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: "/fixture/" + executableNames[0]) }
}
// The process boundary alone is simulated, including a process that ignores
// cancellation and delivers stdout after the user starts another request.
actor ControlledRunner: CodexCommandRunning {
    struct Call: Sendable { let arguments: [String]; let input: String? }
    var calls: [Call] = []
    var pending: [Int: CheckedContinuation<CodexCommandResult, Error>] = [:]
    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        let index = calls.count
        calls.append(Call(arguments: arguments, input: standardInput))
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        for _ in 0..<100_000 {
            if calls.count >= count { return }
            await Task.yield()
        }
        fatalError("Request never reached process boundary")
    }
    func finish(_ index: Int, session: String = "resident", reply: String = "hello", exit: Int32 = 0, backend: AgentConversationBackendID = .codex) {
        let events: String
        switch backend {
        case .codex: events = [
            "{\"type\":\"thread.started\",\"thread_id\":\"\(session)\"}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(reply)\"}}"
        ].joined(separator: "\n")
        case .claudeCode, .workbuddy, .qoder:
            events = "{\"session_id\":\"\(session)\",\"result\":\"\(reply)\"}"
        case .pi:
            events = "{\"type\":\"session\",\"id\":\"\(session)\"}\n{\"type\":\"message_end\",\"message\":{\"content\":\"\(reply)\"}}"
        case .dsh: events = reply
        }
        pending.removeValue(forKey: index)!.resume(returning: CodexCommandResult(exitCode: exit, output: events))
    }
}

typealias RealConversationService = AgentConversationService
@MainActor final class Surface {
    var replies: [String] = []
    var statuses: [String] = []
    func beginAgentReply() {}
    func finishAgentReply(_ reply: String) { replies.append(reply) }
    func showChatStatus(_ text: String) { statuses.append(text) }
}
@MainActor final class Speech {
    var isEnabled = false
    var spoken: [String] = []
    func announce(_ reply: String) { spoken.append(reply) }
}
@MainActor final class AppHarness {
    // Resolve the production method's singleton lookup to the injected real
    // service; the method itself is compiled unchanged, UI/TTS are inert sinks.
    enum AgentConversationService { static var shared: RealConversationService! }
    var liveCamWindowController: Surface? = Surface()
    var agentSpeechAnnouncer = Speech()
    init(_ service: RealConversationService) { AgentConversationService.shared = service }
    \#(sendMethod)
    func send(_ message: String) async { await sendLiveCamMessage(message) }
}

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
@MainActor func cancelled(_ task: Task<String, Error>) async -> Bool {
    do { _ = try await task.value; return false }
    catch is CancellationError { return true }
    catch AgentConversationError.cancelled { return true }
    catch { return false }
}
@MainActor func fixture() -> (RealConversationService, ControlledRunner, UserDefaults, String) {
    let suite = "gmgn-resident-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let runner = ControlledRunner()
    let service = RealConversationService(locator: FixtureLocator(), defaults: defaults, runnerFactory: { _ in runner })
    service.selectBackend(.codex)
    return (service, runner, defaults, suite)
}

@main struct Tests {
    @MainActor static func main() async throws {
        for backend in AgentConversationBackendID.allCases {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.selectBackend(backend)
            let first = Task { try await service.send("my-name-is-resident") }
            await runner.waitForCalls(1)
            await runner.finish(0, reply: "remembered", backend: backend)
            check(try await first.value == "remembered", "\(backend): first turn parses provider output")
            let second = Task { try await service.send("what-is-my-name") }
            await runner.waitForCalls(2)
            let arguments = await runner.calls[1].arguments
            check(backend == .dsh ? arguments.last?.contains("my-name-is-resident") == true : arguments.contains("resident"), "\(backend): second turn retains context")
            await runner.finish(1, backend: backend)
            _ = try await second.value
            service.resetSession()
            let third = Task { try await service.send("fresh") }
            await runner.waitForCalls(3)
            let freshArguments = await runner.calls[2].arguments
            check(!freshArguments.contains("resident") && freshArguments.last?.contains("my-name-is-resident") != true, "\(backend): reset clears context")
            await runner.finish(2, backend: backend)
            _ = try await third.value
        }
        // Successful turns retain the provider session; failure cannot replace it.
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = Task { try await service.send("first") }
            await runner.waitForCalls(1)
            await runner.finish(0)
            check(try await first.value == "hello", "first turn returns parsed process output")
            let second = Task { try await service.send("second") }
            await runner.waitForCalls(2)
            check(await runner.calls[1].arguments.contains("resident"), "second turn resumes the same session")
            await runner.finish(1, session: "bad", exit: 1)
            do { _ = try await second.value; check(false, "failed process must throw") } catch { check(true, "failed process surfaced") }
            check(service.preferenceStore.sessionID(for: .codex) == "resident", "failure keeps last valid session")
            let third = Task { try await service.send("retry") }
            await runner.waitForCalls(3)
            check(await runner.calls[2].arguments.contains("resident"), "retry resumes last successful session")
            await runner.finish(2, reply: "recovered")
            check(try await third.value == "recovered", "failure permits next request")
        }
        for action in ["cancel", "reset", "switch", "supersede", "caller-cancel"] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let old = Task { try await service.send("old") }
            await runner.waitForCalls(1)
            switch action {
            case "cancel": service.cancel()
            case "reset": service.resetSession()
            case "switch": service.selectBackend(.dsh); service.selectBackend(.codex)
            case "caller-cancel": old.cancel()
            default: break
            }
            let current = Task { try await service.send("new") }
            await runner.waitForCalls(2)
            await runner.finish(1, session: "new-session", reply: "new-reply")
            check(try await current.value == "new-reply", "\(action): new request succeeds")
            await runner.finish(0, session: "stale-session", reply: "stale-reply")
            check(await cancelled(old), "\(action): delayed reply is cancelled")
            check(service.preferenceStore.sessionID(for: .codex) == "new-session", "\(action): stale reply cannot overwrite session")
        }
        for callerCancellation in [false, true] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let request = Task { try await service.send("cancel-without-new-request") }
            await runner.waitForCalls(1)
            if callerCancellation { request.cancel() } else { service.cancel() }
            await runner.finish(0)
            check(await cancelled(request), "cancel without superseding request discards result")
            check(service.preferenceStore.sessionID(for: .codex) == nil, "cancel cannot create a session")
        }
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.selectBackend(.dsh)
            let old = Task { try await service.send("discard-this-history") }
            await runner.waitForCalls(1)
            service.resetSession()
            await runner.finish(0, backend: .dsh)
            check(await cancelled(old), "DSH reset discards delayed output")
            let current = Task { try await service.send("new-history") }
            await runner.waitForCalls(2)
            check(await runner.calls[1].arguments.last?.contains("discard-this-history") != true, "DSH reset cannot restore stale history")
            await runner.finish(1, backend: .dsh)
            _ = try await current.value
        }
        // Old cleanup must not remove the new request's cancellation handle.
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let old = Task { try await service.send("old") }
            await runner.waitForCalls(1)
            let current = Task { try await service.send("new") }
            await runner.waitForCalls(2)
            await runner.finish(0)
            _ = await cancelled(old)
            service.cancel()
            await runner.finish(1)
            check(await cancelled(current), "old cleanup cannot detach current request cancellation")
        }
        // Late errors and replies cannot overwrite the visible reply or trigger TTS.
        for staleExit: Int32 in [0, 1] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let old = Task { await app.send("old") }
            await runner.waitForCalls(1)
            let current = Task { await app.send("new") }
            await runner.waitForCalls(2)
            await runner.finish(1, session: "new", reply: "current")
            await current.value
            await runner.finish(0, reply: "stale", exit: staleExit)
            await old.value
            check(app.liveCamWindowController?.replies == ["current"], "UI never publishes a stale reply")
            check(app.liveCamWindowController?.statuses == [], "UI never publishes a stale error")
            check(app.agentSpeechAnnouncer.spoken == ["current"], "TTS never announces stale output")
        }
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let failed = Task { await app.send("failure") }
            await runner.waitForCalls(1)
            await runner.finish(0, exit: 1)
            await failed.value
            check(app.liveCamWindowController?.statuses.count == 1, "current failure is visible")
            check(app.liveCamWindowController?.replies.isEmpty == true, "current failure cannot appear as a reply")
            check(app.agentSpeechAnnouncer.spoken.isEmpty, "current failure cannot trigger TTS")
            let retry = Task { await app.send("retry") }
            await runner.waitForCalls(2)
            await runner.finish(1, reply: "recovered")
            await retry.value
            check(app.liveCamWindowController?.replies == ["recovered"], "UI accepts reply after failure")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident conversation checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-loop-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("ResidentLoop.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("resident-loop")
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library",
    sources.appendingPathComponent("Agent/CodexCLI.swift").path,
    sources.appendingPathComponent("Agent/AgentConversationService.swift").path,
    program.path, "-o", executable.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
