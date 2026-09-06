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
let loopMethods = ["private func ensureResidentLoop(", "private func synchronizeResidentLoopPresentation(",
                   "private func performResidentTurn(", "private func cancelResidentMessage("].map {
    declaration($0, in: app)
}.joined(separator: "\n")
let contextMethod = app.contains("private func currentResidentWorldContext(")
    ? declaration("private func currentResidentWorldContext(", in: app) : ""
let toolsMethod = app.contains("private func makeResidentWorldTools(")
    ? declaration("private func makeResidentWorldTools(", in: app) : ""
let controller = try String(contentsOf: sources.appendingPathComponent("DesktopPresence/LiveCamWindowController.swift"), encoding: .utf8)
let replyMethods = ["func beginAgentReply(", "func finishAgentReply(", "func showChatStatus(", "func setResidentThinking("].map { declaration($0, in: controller) }.joined(separator: "\n")
let harness = #"""
import Foundation
import WorldRuntime

struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String; let name: String; let argumentsJSON: Data
}
struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String; let resultJSON: Data; let isError: Bool
}

@MainActor final class FormalRunner {
    var tools: [ResidentConversationTools] = []
    var prompts: [String] = []
    var pending: [Int: CheckedContinuation<AgentConversationOutcome, Error>] = [:]
    func run(_ prompt: String, _ tools: ResidentConversationTools) async throws -> AgentConversationOutcome {
        let index = self.tools.count
        self.tools.append(tools)
        prompts.append(prompt)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        for _ in 0..<100_000 {
            if tools.count >= count { return }
            await Task.yield()
        }
        print("FAIL: actual Live Cam send did not reach formal resident sender")
        exit(1)
    }
    func finish(_ index: Int) {
        pending.removeValue(forKey: index)!.resume(returning: AgentConversationOutcome(reply: "formal reply", sessionID: "formal-session"))
    }
}

final class FixtureLocator: AgentExecutableLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func setAvailable(_ value: Bool) { lock.lock(); available = value; lock.unlock() }
    func locate(executableNames: [String]) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return available ? URL(fileURLWithPath: "/fixture/" + executableNames[0]) : nil
    }
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

struct FixtureWorldState: WorldStatePersisting {
    let state: WorldState
    func load() throws -> WorldState? { state }
    func save(_ state: WorldState) throws {}
}

func worldPayload(_ prompt: String) throws -> [String: Any] {
    let json = prompt.components(separatedBy: "空间资料：\n")[1]
        .components(separatedBy: "\n用户消息：")[0]
    return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

typealias RealConversationService = AgentConversationService
@MainActor final class LiveCamPanel {
    var replies: [String] = []
    var statuses: [String] = []
    var text = ""
    var thinking = false
    func setResidentThinking(_ value: Bool) { thinking = value }
    func showAgentReply(_ reply: String) {
        text = reply
        if reply != "…" && !reply.isEmpty { replies.append(reply) }
    }
    func showChatStatus(_ value: String) { text = value; statuses.append(value) }
}
@MainActor final class Surface {
    let panel = LiveCamPanel()
    var window: AnyObject? { panel }
    var agentReplyBuffer = ""
    var replies: [String] { panel.replies }
    var statuses: [String] { panel.statuses }
    var waiting: Bool { panel.thinking }
    var deliveryNotice: String?
    func setResidentDeliveryNotice(_ value: String?) { deliveryNotice = value }
    func setResidentCanStop(_ value: Bool) {}
    \#(replyMethods)
}
@MainActor final class Speech {
    var isEnabled = false
    var spoken: [String] = []
    func announce(_ reply: String) { spoken.append(reply) }
    func stop() {}
}
@MainActor final class AppHarness {
    // Resolve the production method's singleton lookup to the injected real
    // service; the method itself is compiled unchanged, UI/TTS are inert sinks.
    enum AgentConversationService { static var shared: RealConversationService! }
    private var liveCamMessageID: UUID?
    private var residentAgentLoop: ResidentAgentLoop?
    private let residentActivityOwnership = ResidentActivityOwnership()
    private var residentActivityOutcome: ResidentActivityOutcome?
    var liveCamWindowController: Surface? = Surface()
    final class StageReply {
        func beginResidentReply() {}
        func finishResidentReply(_ text: String) {}
        func showResidentChatStatus(_ text: String) {}
        func setResidentThinking(_ thinking: Bool) {}
        func setResidentDeliveryNotice(_ notice: String?) {}
        func setResidentCanStop(_ canStop: Bool) {}
    }
    var stageWindowController: StageReply? = StageReply()
    func disconnectRealtimeVoice() { agentSpeechAnnouncer.stop() }
    func showResidentVoiceStatus(_ text: String) {
        liveCamWindowController?.showChatStatus(text)
        stageWindowController?.showResidentChatStatus(text)
    }
    var agentSpeechAnnouncer = Speech()
    struct Stage { var selectedWorldID = "unloaded-world" }
    var spatialStage = Stage()
    var livingWorldContext: WorldAgentContext?
    init(_ service: RealConversationService) { AgentConversationService.shared = service }
    \#(sendMethod)
    \#(loopMethods)
    \#(contextMethod)
    \#(toolsMethod)
    private func resumeResidentJukebox(owner: UUID) async throws { fatalError("Use the jukebox outcome suite for playback") }
    private func pauseResidentJukebox(owner: UUID?) async throws { fatalError("Use the jukebox outcome suite for playback") }
    func enqueue(_ message: String) async { await sendLiveCamMessage(message) }
    func stop() { cancelResidentMessage() }
    func waitUntilIdle() async {
        for _ in 0..<500_000 {
            if residentAgentLoop?.snapshot.isRunning != true { return }
            await Task.yield()
        }
        fatalError("Resident loop did not become idle")
    }
    func send(_ message: String) async {
        await sendLiveCamMessage(message)
        await waitUntilIdle()
    }
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
@MainActor func fixture(locator: FixtureLocator = FixtureLocator()) -> (RealConversationService, ControlledRunner, UserDefaults, String) {
    let suite = "gmgn-resident-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let runner = ControlledRunner()
    let service = RealConversationService(locator: locator, defaults: defaults, runnerFactory: { _ in runner })
    service.selectBackend(.codex)
    return (service, runner, defaults, suite)
}

@main struct Tests {
    @MainActor static func main() async throws {
        for mode in ["finish", "cancel", "selected-world", "replaced-context"] {
            let suite = "gmgn-formal-app-test-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let formal = FormalRunner()
            let textRunner = ControlledRunner()
            let service = RealConversationService(locator: FixtureLocator(), defaults: defaults,
                runnerFactory: { _ in textRunner }, residentSender: { _, prompt, _, tools in
                    try await formal.run(prompt, tools)
                })
            service.selectBackend(.codex)
            let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
                URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
            let context = try WorldAgentContext(manifest: manifest)
            let app = AppHarness(service)
            app.livingWorldContext = context
            app.spatialStage.selectedWorldID = manifest.worldID
            let request = Task { await app.send("去做个活动") }
            await formal.waitForCalls(1)
            let tools = formal.tools[0]
            check(tools.worldID == manifest.worldID, "\(mode): App binds actual world to formal tools")
            check((try JSONSerialization.jsonObject(with: tools.schemasJSON) as? [Any])?.count == 6,
                  "\(mode): App exposes four world tools and two loop tools")
            check(formal.prompts[0].contains("这是居民生活循环的一轮"), "\(mode): actual App supplies generic loop instructions")
            let observed = await tools.call("loop-read", "read_resident_state", Data("{}".utf8))
            check(!observed.isError && !tools.allowsSilentCompletion(), "\(mode): reading state alone does not authorize silent completion")
            let planned = await tools.call("loop-intent", "update_resident_intent",
                Data(#"{"summary":"保留当前委托，等待下一条引导","status":"waiting_user"}"#.utf8))
            check(!planned.isError && tools.allowsSilentCompletion(), "\(mode): actual App loop tool records intent for this turn")
            let started = await tools.call("start", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
            check(!started.isError && context.state.activeActivity?.activityID == "home.idle", "\(mode): actual App-to-service callback starts real activity")
            let stopped = await tools.call("stop", "stop_activity", Data("{}".utf8))
            check(!stopped.isError && context.state.activeActivity == nil, "\(mode): actual callback stops activity")
            switch mode {
            case "cancel": app.stop()
            case "selected-world": app.spatialStage.selectedWorldID = "other-world"
            case "replaced-context": app.livingWorldContext = try WorldAgentContext(manifest: manifest)
            default: break
            }
            if mode != "finish" {
                let stale = await tools.call("stale", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
                check(stale.isError && context.state.activeActivity == nil, "\(mode): old App lease rejects mutations immediately")
            }
            formal.finish(0)
            await request.value
            let after = await tools.call("after", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
            check(after.isError && context.state.activeActivity == nil, "\(mode): completed request releases formal capability lease")
            let latePlan = await tools.call("late-plan", "update_resident_intent", Data(#"{"summary":"迟到的修改","status":"active"}"#.utf8))
            check(latePlan.isError && !tools.allowsSilentCompletion(), "\(mode): ended or stopped turn cannot mutate intent")
            check(app.liveCamWindowController?.waiting == false, "\(mode): request always ends waiting bubble")
            check(app.liveCamWindowController?.replies == (mode == "finish" ? ["formal reply"] : []),
                  "\(mode): only current world receives formal reply")
        }
        // Use the shipping manifest and actual WorldAgentContext, with only the
        // external CLI process mocked. No real backend or saved world is read.
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.preferenceStore.saveSessionID("personal-session", for: .codex)
            let manifestData = try Data(contentsOf: URL(fileURLWithPath:
                "apps/macos/Resources/Worlds/marble-living-cabin/world.json"))
            let manifest = try JSONDecoder().decode(WorldManifest.self, from: manifestData)
            let context = try WorldAgentContext(manifest: manifest)
            let app = AppHarness(service)
            app.livingWorldContext = context
            app.spatialStage.selectedWorldID = manifest.worldID
            let first = Task { await app.send("你在什么地方，能做什么？") }
            await runner.waitForCalls(1)
            let firstCall = await runner.calls[0]
            let input = firstCall.input ?? firstCall.arguments.joined(separator: " ")
            check(input.contains(manifest.worldID), "current world ID reaches actual model input")
            check(input.contains("residentPosition"), "resident position reaches model input")
            check(input.contains("prop.jukebox") && input.contains("点唱机"), "declared jukebox has public identity")
            check(input.contains("music.listen") && input.contains("availableActivities"), "declared activities reach model input")
            check(input.contains("只读") && input.contains("不能声称"), "text backend explicitly cannot claim execution")
            check(input.contains("未知"), "absent object runtime position remains unknown")
            check(!input.contains(".glb") && !input.contains("/Users/") && !input.contains("resources"), "resource and private paths are not context")
            check(!firstCall.arguments.contains("personal-session"), "room does not resume personal chat session")
            if input.contains("空间资料：\n") {
                let payload = try worldPayload(input)
                let props = payload["objects"] as? [[String: Any]] ?? []
                check((payload["residentPosition"] as? [NSNumber])?.map(\.floatValue) == [context.state.agentTransform.position.x,
                    context.state.agentTransform.position.y, context.state.agentTransform.position.z], "resident position is actual runtime position")
                check(props.first?["position"] == nil && props.first?["isEnabled"] == nil, "unavailable object state is not fabricated from activity anchor")
                check(props.first?["activityIDs"] as? [String] == ["music.listen"], "object links to its declared activity")
            }
            await runner.finish(0, session: "cabin-session")
            await first.value
            check(service.preferenceStore.sessionID(for: .codex) == "personal-session", "room session does not replace personal chat session")

            try context.startActivity(id: "home.idle")
            let next = Task { await app.send("现在在做什么？") }
            await runner.waitForCalls(2)
            let secondCall = await runner.calls[1]
            check(secondCall.arguments.contains("cabin-session"), "same room resumes resident session")
            check(secondCall.input != firstCall.input && secondCall.input?.contains("activeActivity") == true,
                  "next turn gets updated live activity snapshot")
            if let prompt = secondCall.input, prompt.contains("空间资料：\n") {
                check(try worldPayload(prompt)["activeActivity"] as? String == "home.idle", "current activity value comes from executor snapshot")
            }
            await runner.finish(1, session: "cabin-session")
            await next.value

            // Selection can change before the old context has been replaced.
            app.spatialStage.selectedWorldID = "other-room"
            let switched = Task { await app.send("看看新房间") }
            await runner.waitForCalls(3)
            let switchedCall = await runner.calls[2]
            check(!switchedCall.arguments.contains("cabin-session"), "world mismatch never resumes old room session")
            check(switchedCall.input?.contains("prop.jukebox") != true && switchedCall.input?.contains("music.listen") != true,
                  "world mismatch does not expose old facilities")
            check(switchedCall.input?.contains("未知") == true, "unloaded world is explicitly unknown")
            await runner.finish(2, session: "unavailable-session")
            await switched.value

            app.spatialStage.selectedWorldID = manifest.worldID
            let delayed = Task { await app.send("旧空间的回答") }
            await runner.waitForCalls(4)
            let replies = app.liveCamWindowController?.replies
            let speech = app.agentSpeechAnnouncer.spoken
            app.spatialStage.selectedWorldID = "other-room"
            await runner.finish(3, reply: "old-room-reply")
            await delayed.value
            check(app.liveCamWindowController?.replies == replies, "world switch suppresses delayed room reply")
            check(app.agentSpeechAnnouncer.spoken == speech, "world switch suppresses delayed room speech")

            var state = WorldSimulation(manifest: manifest, startedAt: Date()).state
            state.objectStates["prop.jukebox"] = WorldObjectState(isEnabled: false,
                transform: WorldTransform(position: WorldVector3(x: 2, y: 3, z: 4),
                    rotation: manifest.spawn.rotation, scale: manifest.spawn.scale),
                metadata: ["apiKey": "DO-NOT-SEND-SECRET", "resource": "/private/test.glb"])
            state.objectStates["unpublished-object"] = WorldObjectState(transform: manifest.spawn)
            app.livingWorldContext = try WorldAgentContext(manifest: manifest, persistence: FixtureWorldState(state: state))
            app.spatialStage.selectedWorldID = manifest.worldID
            let restored = Task { await app.send("检查物件") }
            await runner.waitForCalls(5)
            let restoredInput = await runner.calls[4].input ?? ""
            check(!restoredInput.contains("DO-NOT-SEND-SECRET") && !restoredInput.contains("/private/") && !restoredInput.contains("unpublished-object"), "only declared public object state crosses prompt boundary")
            if restoredInput.contains("空间资料：\n") {
                let props = try worldPayload(restoredInput)["objects"] as! [[String: Any]]
                check(props[0]["position"] as? [Int] == [2, 3, 4] && props[0]["isEnabled"] as? Bool == false,
                      "known object position and enabled status are preserved")
            }
            await runner.finish(4)
            await restored.value
        }
        for backend in AgentConversationBackendID.allCases {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.selectBackend(backend)
            service.preferenceStore.saveSessionID("personal-session", for: backend)
            let roomA = ResidentWorldContext.unavailable(selectedWorldID: "room-A")
            let roomB = ResidentWorldContext.unavailable(selectedWorldID: "room-B")
            let first = Task { try await service.send("only-room-A-history", worldContext: roomA) }
            await runner.waitForCalls(1)
            check(await !runner.calls[0].arguments.contains("personal-session"), "\(backend): room starts outside personal session")
            await runner.finish(0, session: "room-A-session", backend: backend)
            _ = try await first.value
            let second = Task { try await service.send("same-room", worldContext: roomA) }
            await runner.waitForCalls(2)
            let sameArguments = await runner.calls[1].arguments
            check(backend == .dsh ? sameArguments.last?.contains("only-room-A-history") == true : sameArguments.contains("room-A-session"), "\(backend): room session continues")
            await runner.finish(1, session: "room-A-session", backend: backend)
            _ = try await second.value
            let third = Task { try await service.send("other-room", history: [.init(role: .user, text: "unsafe-external-history")], worldContext: roomB) }
            await runner.waitForCalls(3)
            let otherArguments = await runner.calls[2].arguments
            check(!otherArguments.contains("room-A-session") && !otherArguments.joined().contains("only-room-A-history") && !otherArguments.joined().contains("unsafe-external-history"), "\(backend): other room never inherits history")
            await runner.finish(2, session: "room-B-session", backend: backend)
            _ = try await third.value
            service.resetSession()
            check(service.preferenceStore.sessionID(for: backend) == "personal-session", "\(backend): resetting room preserves personal session")
            let reset = Task { try await service.send("reset-room", worldContext: roomB) }
            await runner.waitForCalls(4)
            check(await !runner.calls[3].arguments.contains("room-B-session"), "\(backend): reset starts fresh room session")
            await runner.finish(3, backend: backend)
            _ = try await reset.value
        }
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
            app.stop()
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
        for staleExit: Int32 in [0, 1] {
            let locator = FixtureLocator()
            let (service, runner, defaults, suite) = fixture(locator: locator)
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let old = Task { await app.send("old") }
            await runner.waitForCalls(1)
            app.stop()
            locator.setAvailable(false)
            await app.send("provider-disappeared")
            let failureStatuses = app.liveCamWindowController?.statuses
            check(failureStatuses?.count == 1, "new preflight failure is visible")
            await runner.finish(0, session: "stale-session", reply: "stale-reply", exit: staleExit)
            await old.value
            check(app.liveCamWindowController?.statuses == failureStatuses, "old failure cannot replace newer preflight error")
            check(app.liveCamWindowController?.replies.isEmpty == true, "old success cannot replace newer preflight error")
            check(app.agentSpeechAnnouncer.spoken.isEmpty, "old success after preflight failure cannot trigger TTS")
            check(service.preferenceStore.sessionID(for: .codex) == nil, "preflight failure cancels old session persistence")
        }
        for action in ["cancel", "reset", "switch", "stop-button"] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let request = Task { await app.send("waiting") }
            await runner.waitForCalls(1)
            check(app.liveCamWindowController?.waiting == true, "\(action): actual begin shows waiting")
            app.stop()
            switch action {
            case "reset": service.resetSession()
            case "switch": service.selectBackend(.dsh)
            default: break
            }
            check(app.liveCamWindowController?.waiting == false, "\(action): cancellation immediately ends waiting before process exits")
            await runner.finish(0)
            await request.value
            check(app.liveCamWindowController?.replies.isEmpty == true, "\(action): cancelled request never finishes a reply")
        }
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let old = Task { await app.send("old") }
            await runner.waitForCalls(1)
            await app.enqueue("current")
            for _ in 0..<100 { await Task.yield() }
            check(await runner.calls.count == 1, "unsupported steering queues guidance without cancelling active request")
            check(app.liveCamWindowController?.waiting == true, "queued guidance retains current thinking state")
            await runner.finish(0, session: "continued", reply: "first reply")
            await runner.waitForCalls(2)
            check(await runner.calls[1].arguments.contains("continued"), "queued guidance resumes completed session")
            check(app.liveCamWindowController?.waiting == true, "next queued turn remains visibly thinking")
            await runner.finish(1, reply: "current")
            await old.value
            check(app.liveCamWindowController?.waiting == false, "actual finish ends waiting")
            check(app.liveCamWindowController?.replies == ["first reply", "current"], "both serial turns publish their own completed reply")
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
let compilerArguments: [String] = ["-j1", "-parse-as-library",
    "-I", root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/Modules").path,
    sources.appendingPathComponent("Agent/CodexCLI.swift").path,
    sources.appendingPathComponent("Agent/AgentConversationService.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolContract.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolDispatcher.swift").path,
    sources.appendingPathComponent("Agent/ResidentWorldToolSession.swift").path,
    sources.appendingPathComponent("Agent/ResidentActivityOutcome.swift").path,
    sources.appendingPathComponent("Agent/ResidentCodexPolicy.swift").path,
    sources.appendingPathComponent("Agent/ResidentCodexTransport.swift").path,
    sources.appendingPathComponent("Agent/ResidentCodexAgent.swift").path,
    sources.appendingPathComponent("Agent/ResidentSteeringDelivery.swift").path,
    sources.appendingPathComponent("Agent/ResidentAgentLoop.swift").path,
    sources.appendingPathComponent("Agent/ResidentLoopTools.swift").path,
    sources.appendingPathComponent("Agent/ResidentActivityOwnership.swift").path,
    program.path, "-o", executable.path]
let runtimeObjects = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/WorldRuntime.build"),
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
let compiled = try run("/usr/bin/swiftc", compilerArguments + runtimeObjects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
