import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-routing-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harness = #"""
import Foundation
struct Locator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: "/fixture/codex") }
}
struct MissingLocator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { nil }
}
enum FixtureError: Error { case failed }
struct TextRunner: CodexCommandRunning {
    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        CodexCommandResult(exitCode: 0, output: "{\"type\":\"thread.started\",\"thread_id\":\"ordinary\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"readonly\"}}")
    }
}
@MainActor final class Capture {
    var prompts: [String] = []
    var sessions: [String?] = []
    var cancelled = 0
    var pending: CheckedContinuation<AgentConversationOutcome, Error>?
}
@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            if !value { failed += 1; print("FAIL: \(label)") }
        }
        let suite = "gmgn-resident-routing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let captured = Capture()
        let service = AgentConversationService(locator: Locator(), defaults: defaults, runnerFactory: { _ in TextRunner() }, residentSender: { _, prompt, session, _ in
            captured.prompts.append(prompt); captured.sessions.append(session)
            return AgentConversationOutcome(reply: "tools reply", sessionID: "tools-thread")
        })
        service.selectBackend(.codex)
        check(service.supportsWorldTools, "installed Codex with formal sender supports tools")
        let world = ResidentWorldContext(selectedWorldID: "room", worldID: "room", displayName: "房间", revision: 1, residentPosition: [0,0,0], activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        let tools = ResidentConversationTools(worldID: "room", schemasJSON: Data("[]".utf8), call: { _,_,_ in ResidentCodexToolReply(resultJSON: Data("{}".utf8), isError: false) }, cancel: { captured.cancelled += 1 })
        service.preferenceStore.saveSessionID("old-readonly-thread", for: .codex, scope: world.sessionScope)
        let first = try await service.send("看房间", worldContext: world, worldTools: tools)
        check(first == "tools reply", "formal sender receives world request")
        check(captured.sessions.count == 1 && captured.sessions[0] == nil, "never resume former exec thread for dynamic tools")
        check(captured.prompts.first?.contains("当前为只读聊天") == false, "do not claim readonly when tools connected")
        check(captured.prompts.first?.contains("正式工具结果") == true, "prompt requires real tool results")
        _ = try await service.send("再看一次", worldContext: world, worldTools: tools)
        check((captured.sessions.last ?? nil) == "tools-thread", "formal session resumes itself")
        check(service.preferenceStore.sessionID(for: .codex, scope: world.sessionScope) == "old-readonly-thread", "ordinary room conversation preserved")
        let badTools = ResidentConversationTools(worldID: "different", schemasJSON: tools.schemasJSON, call: tools.call, cancel: tools.cancel)
        var rejected = false
        do { _ = try await service.send("开始", worldContext: world, worldTools: badTools) } catch { rejected = true }
        check(rejected, "reject mismatched capability world")
        check(captured.prompts.count == 2, "mismatched world never reaches model")
        let readonly = try await service.send("普通文字", worldContext: world)
        check(readonly == "readonly", "no tools stays on existing text path")
        service.selectBackend(.dsh)
        check(!service.supportsWorldTools, "unimplemented backend remains readonly")
        service.selectBackend(.codex)
        let otherWorld = ResidentWorldContext(selectedWorldID: "other", worldID: "other", displayName: nil, revision: 1, residentPosition: [], activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        let otherTools = ResidentConversationTools(worldID: "other", schemasJSON: tools.schemasJSON, call: tools.call, cancel: tools.cancel)
        _ = try await service.send("其他房间", worldContext: otherWorld, worldTools: otherTools)
        check((captured.sessions.last ?? nil) == nil, "another world starts separate session")
        _ = try await service.send("原房间", worldContext: world, worldTools: tools)
        check((captured.sessions.last ?? nil) == "tools-thread", "returning world resumes original session")
        let invalidWorld = ResidentWorldContext(selectedWorldID: "room", worldID: "room", displayName: nil, revision: 1, residentPosition: [.nan], activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        var before = captured.cancelled
        do { _ = try await service.send("invalid", worldContext: invalidWorld, worldTools: tools) } catch {}
        check(captured.cancelled > before, "prompt encoding failure releases lease")
        let missing = AgentConversationService(locator: MissingLocator(), defaults: defaults, residentSender: { _,_,_,_ in throw FixtureError.failed })
        before = captured.cancelled
        do { _ = try await missing.send("missing", worldContext: world, worldTools: tools) } catch {}
        check(captured.cancelled > before, "missing executable releases lease")
        let throwing = AgentConversationService(locator: Locator(), defaults: defaults, residentSender: { _,_,_,_ in throw FixtureError.failed })
        before = captured.cancelled
        do { _ = try await throwing.send("fail", worldContext: world, worldTools: tools) } catch {}
        check(captured.cancelled > before, "sender failure releases lease")
        let blocked = AgentConversationService(locator: Locator(), defaults: defaults, runnerFactory: { _ in TextRunner() }, residentSender: { _,_,_,_ in
            try await withCheckedThrowingContinuation { captured.pending = $0 }
        })
        let task = Task { @MainActor in
            do { _ = try await blocked.send("hang", worldContext: world, worldTools: tools); return false }
            catch { return true }
        }
        for _ in 0..<1000 { if captured.pending != nil { break }; await Task.yield() }
        check(captured.pending != nil, "formal sender suspended")
        before = captured.cancelled
        blocked.selectBackend(.dsh)
        check(captured.cancelled > before, "backend switch immediately invalidates tools")
        captured.pending?.resume(returning: AgentConversationOutcome(reply: "late", sessionID: "late-session"))
        captured.pending = nil
        check(await task.value, "late successful sender cannot return after cancellation")
        check(blocked.preferenceStore.sessionID(for: .codex, scope: world.sessionScope + ".tools.v3") == "tools-thread", "late session never overwrites original")
        print("\(failed == 0 ? "PASS" : "FAIL"): \(count) resident routing checks, \(failed) failures")
        exit(failed == 0 ? 0 : 1)
    }
}
"""#
let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-parse-as-library", "-j1"] + ["CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy", "ResidentCodexAgent", "ResidentSteeringDelivery"].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path
} + [main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
