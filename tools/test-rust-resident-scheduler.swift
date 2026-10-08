import Foundation

// Only world presentation/tool projection are fixtures; scheduler, HTTP client
// and the actual Unity lifecycle bridge remain production source.
@MainActor final class WorldAgentContext {
    struct Position { var x: Double = 0; var y: Double = 0; var z: Double = 0 }
    struct Transform { var position = Position() }
    struct Phase { let rawValue = "loop" }
    struct Activity { let id = "test"; let phase = Phase() }
    struct Snapshot { let worldID = "scheduler-test"; let agentTransform = Transform(); var activeActivity: Activity? }
    struct Held { let objectID: String }
    struct State { var heldProp: Held? }
    var snapshot = Snapshot(); var state = State()
}
struct ResidentPreferences {
    let defaults: UserDefaults
    var backgroundTurnsPerHour: Int { 6 }
}
struct ResidentSelfState {
    let space: String; let position: [Double]; let yawDegrees: Double?
    let avatarFormat: String?; let activityID: String?; let activityPhase: String?; let heldPropID: String?
}
@MainActor struct ResidentLoopTools {
    init(loop: ResidentAgentLoop, runID: UUID, selfState: @escaping () -> ResidentSelfState?) {}
}

private final class SchedulerClaimGate: @unchecked Sendable {
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    var isEntered: Bool { lock.withLock { entered } }
    func pause() { lock.withLock { entered = true }; resume.wait() }
}

@MainActor private final class SchedulerClock {
    var date = Date(timeIntervalSince1970: 1000)
}
@MainActor private final class SchedulerRunner {
    var inputs: [ResidentAgentLoop.Input] = []
    var waiting: [CheckedContinuation<String, Error>] = []
    var guides: [RustResidentSchedulerClient.SteeringInput] = []
    func run(_ input: ResidentAgentLoop.Input) async throws -> String {
        inputs.append(input)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func finish() { waiting.removeFirst().resume(returning: "实际模型轮次结束") }
}

@main struct RustResidentSchedulerAcceptance {
    enum TestError: Error { case timeout }
    @MainActor static func wait(_ label: String = "condition", _ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        FileHandle.standardError.write(Data("FAIL: timeout at \(label)\n".utf8))
        throw TestError.timeout
    }
    @MainActor static func rpc(_ transport: TaskdHTTPAuthorityClient, _ method: String,
                              _ values: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: values)
        let data = try await Task.detached {
            let values = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: values))
        }.value
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    @MainActor static func events(_ transport: TaskdHTTPAuthorityClient, _ scope: String) async throws -> [[String: Any]] {
        let result = try await rpc(transport, "agent_loop_read", ["worldID": "scheduler-test", "residentScope": scope])
        return result["events"] as? [[String: Any]] ?? []
    }
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2, "Provide isolated gmgn-taskd binary")
        // macOS Foundation normalizes /private/var back to symlinked /var;
        // taskd deliberately refuses symlink ancestors. Use the physical tmp path.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("gmgn-rust-scheduler-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let endpoint = root.appendingPathComponent("endpoint.json")
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        daemon.arguments = ["--root", root.path, "--endpoint-file", endpoint.path]
        let daemonOutput=Pipe()
        daemon.standardOutput = daemonOutput; daemon.standardError = daemonOutput
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        try await wait("private endpoint") {
            if !daemon.isRunning {
                let failure=daemonOutput.fileHandleForReading.readDataToEndOfFile()
                FileHandle.standardError.write(failure)
                return true
            }
            return FileManager.default.fileExists(atPath: endpoint.path)
        }
        guard daemon.isRunning else { throw TestError.timeout }
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpoint.path, helperPath: "", allowsLaunching: false)
        let controlURL = try transport.validatedControlURL()
        precondition(controlURL.scheme == "http" && controlURL.host == "127.0.0.1" && controlURL.path == "/rpc")
        let rejectedEndpoint = root.appendingPathComponent("invalid-endpoint.json")
        try JSONSerialization.data(withJSONObject: ["version": 2, "address": "example.com:80", "token": UUID().uuidString]).write(to: rejectedEndpoint)
        do {
            _ = try TaskdHTTPAuthorityClient(endpointFile: rejectedEndpoint.path, helperPath: "", allowsLaunching: false).validatedControlURL()
            preconditionFailure("DSH native control descriptor must reject remote addresses without network access")
        } catch {}
        let clock = SchedulerClock(), runner = SchedulerRunner()
        let client = RustResidentSchedulerClient(worldID: "scheduler-test", residentScope: "resident",
            hostSessionID: "host-one") { method, data in
                precondition(!Thread.isMainThread, "synchronous HTTP must run off the main thread")
                let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                do { return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params)) }
                catch { FileHandle.standardError.write(Data("FAIL: isolated RPC \(method): \(error)\n".utf8)); throw error }
            }
        let availability = SchedulerClock()
        let loop = ResidentAgentLoop(now: { clock.date }, configuration: .init(minimumWakeInterval: 1, backgroundTurnsPerHour: 6), run: { try await runner.run($0) },
            rustScheduler: client, rustSchedulerAvailability: { availability.date.timeIntervalSince1970 > 0 })
        loop.setBackgroundEnabled(true)
        loop.tick()
        // Main actor still runs while configure/enqueue/claim execute off-actor.
        for _ in 0..<100 { await Task.yield(); loop.tick() }
        try await wait("first claimed invocation") { runner.inputs.count == 1 }
        var rows = try await events(transport, "resident")
        precondition(rows.count == 1 && rows[0]["state"] as? String == "claimed")
        precondition(rows[0]["runID"] as? String == runner.inputs[0].runID.uuidString)
        precondition(rows[0]["receipt"] is NSNull, "claim is not completion")
        loop.stop()
        clock.date += 10
        for _ in 0..<100 { loop.tick(); await Task.yield() }
        for _ in 0..<100 {
            rows = try await events(transport, "resident")
            if rows[0]["state"] as? String == "cancel_requested" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(rows[0]["state"] as? String == "cancel_requested")
        precondition(runner.inputs.count == 1 && runner.waiting.count == 1, "stop cannot declare an unreturned invocation terminated")
        runner.finish()
        for _ in 0..<100 {
            rows = try await events(transport, "resident")
            if rows[0]["state"] as? String == "completed" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(rows[0]["state"] as? String == "completed", "late actual result must settle its original claim")
        precondition((rows[0]["receipt"] as? [String: Any])?["invocationReturned"] as? Bool == true)
        precondition(loop.snapshot.isStopped)

        // Switching authority while a call is in flight preserves its old scope.
        _ = loop.resumeAutonomyByUser()
        loop.tick(); try await wait("resumed invocation") { runner.inputs.count == 2 }
        let second = RustResidentSchedulerClient(worldID: "scheduler-test", residentScope: "other",
            endpointFile: endpoint.path, hostSessionID: "host-two")
        availability.date = Date(timeIntervalSince1970: 0)
        loop.bindRustScheduler(second, availability: { availability.date.timeIntervalSince1970 > 0 })
        loop.tick()
        precondition(runner.inputs.count == 2, "unavailable host cannot wake after scope switch")
        runner.finish()
        for _ in 0..<100 {
            rows = try await events(transport, "resident")
            if rows.last?["state"] as? String == "completed" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(rows.count == 2 && rows.last?["state"] as? String == "completed")
        let otherEvents = try await events(transport, "other")
        precondition(otherEvents.isEmpty, "old receipt cannot mutate new scope")

        // Missing explicit availability keeps injected migration mode fail-closed.
        let gated = ResidentAgentLoop(run: { _ in preconditionFailure("runtime gate must prohibit invocation") }, rustScheduler: second)
        gated.setBackgroundEnabled(true); gated.tick()
        for _ in 0..<50 { await Task.yield() }
        let gatedEvents = try await events(transport, "other")
        precondition(gatedEvents.isEmpty)

        let oldSession = RustResidentSchedulerClient(worldID: "scheduler-test", residentScope: "rollover",
            endpointFile: endpoint.path, hostSessionID: "old-session")
        let rollover = ResidentAgentLoop(now: { clock.date }, configuration: .init(minimumWakeInterval: 1, backgroundTurnsPerHour: 6),
            run: { try await runner.run($0) }, rustScheduler: oldSession, rustSchedulerAvailability: { true })
        rollover.setBackgroundEnabled(true); rollover.tick()
        try await wait("rollover original invocation") { runner.inputs.count == 3 }
        let newSession = RustResidentSchedulerClient(worldID: "scheduler-test", residentScope: "rollover",
            endpointFile: endpoint.path, hostSessionID: "new-session")
        rollover.bindRustScheduler(newSession, availability: { true })
        clock.date += 10; rollover.tick()
        for _ in 0..<100 {
            rows = try await events(transport, "rollover")
            if rows[0]["state"] as? String == "unknown" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(rows[0]["state"] as? String == "unknown")
        runner.finish()
        for _ in 0..<100 { rollover.tick(); try await Task.sleep(for: .milliseconds(2)) }
        rows = try await events(transport, "rollover")
        precondition(rows[0]["state"] as? String == "unknown", "stale-session completion must not settle new session")
        precondition(runner.inputs.count == 3, "unverified old invocation blocks new autonomous run")

        let humanClient = RustResidentSchedulerClient(worldID: "scheduler-test", residentScope: "front",
            endpointFile: endpoint.path, hostSessionID: "front-session")
        let front = ResidentAgentLoop(now: { clock.date }, configuration: .init(minimumWakeInterval: 86400, backgroundTurnsPerHour: 0),
            run: { try await runner.run($0) }, rustScheduler: humanClient, rustSchedulerAvailability: { true },
            rustSteer: { input in
                let read = try? await rpc(transport,"agent_loop_read",["worldID":"scheduler-test","residentScope":"front"])
                let messages = read?["humanMessages"] as? [[String:Any]] ?? []
                precondition(messages.contains { $0["messageID"] as? String == input.messageID && $0["state"] as? String == "steer_claimed" })
                runner.guides.append(input)
                return .unknown
            })
        let submission=UUID(), rawText="raw-user-marker-not-persisted"
        front.receiveUserMessage(rawText,submissionID:submission)
        front.receiveUserMessage(rawText,submissionID:submission)
        try await wait("human foreground without budget") { runner.inputs.count == 4 }
        rows = try await events(transport,"front")
        precondition(rows.count == 1 && rows[0]["state"] as? String == "claimed")
        precondition(rows[0]["runID"] as? String == runner.inputs[3].runID.uuidString)
        let controls = String(decoding:try JSONSerialization.data(withJSONObject:rows),as:UTF8.self)
        precondition(!controls.contains(rawText),"control ledger must not become a raw conversation memory layer")
        let guideID=UUID()
        front.receiveUserMessage("调整现在这一步",submissionID:guideID)
        try await wait("durable guide admission") { runner.guides.count == 1 }
        for _ in 0..<100 {
            let snapshot=try await rpc(transport,"agent_loop_read",["worldID":"scheduler-test","residentScope":"front"])
            let messages=snapshot["humanMessages"] as? [[String:Any]] ?? []
            if messages.contains(where:{$0["messageID"] as? String == guideID.uuidString && $0["state"] as? String == "unknown"}) {break;}
            try await Task.sleep(for:.milliseconds(5))
        }
        front.receiveUserMessage("调整现在这一步",submissionID:guideID)
        precondition(runner.guides.count == 1,"unknown same submission must not be resent")
        let image=root.appendingPathComponent("reference.png")
        try Data([0]).write(to:image)
        front.receiveUserMessage("带图队首",imageURLs:[image],submissionID:UUID())
        front.receiveUserMessage("图片后面的文字",submissionID:UUID())
        precondition(runner.guides.count == 1,"text behind an image cannot overtake the FIFO head")
        runner.finish()
        for _ in 0..<1000 {
            if runner.inputs.count == 5 {break;}
            clock.date += 1;front.tick();try await Task.sleep(for:.milliseconds(5))
        }
        precondition(runner.inputs.count == 5)
        precondition(runner.inputs[4].userMessages == ["带图队首","图片后面的文字"] && runner.inputs[4].imageURLs == [image])
        front.stop()
        front.receiveUserMessage("停止后新的明确指令",submissionID:UUID())
        for _ in 0..<100 {clock.date += 1;front.tick();try await Task.sleep(for:.milliseconds(2))}
        precondition(runner.inputs.count == 5,"new human input cannot bypass an unreturned cancelled invocation")
        runner.finish()
        for _ in 0..<1000 {
            if runner.inputs.count == 6 {break;}
            clock.date += 1;front.tick();try await Task.sleep(for:.milliseconds(5))
        }
        precondition(runner.inputs.count == 6 && runner.inputs[5].userMessages == ["停止后新的明确指令"])
        precondition(front.snapshot.intentPausedByUser,"fresh human input must not unpause ambient autonomy")
        runner.finish()
        for _ in 0..<100 {
            rows = try await events(transport,"front")
            if rows.last?["state"] as? String == "completed" {break;}
            try await Task.sleep(for:.milliseconds(5))
        }
        precondition(rows.last?["state"] as? String == "completed")

        let gate=SchedulerClaimGate()
        let racingClient=RustResidentSchedulerClient(worldID:"scheduler-test",residentScope:"claim-race",hostSessionID:"race-session") { method,data in
            if method == "agent_loop_claim" {gate.pause()}
            let params=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            return try JSONSerialization.data(withJSONObject:transport.call(method:method,params:params))
        }
        let race=ResidentAgentLoop(now:{clock.date},run:{try await runner.run($0)},rustScheduler:racingClient,rustSchedulerAvailability:{true})
        race.receiveUserMessage("scope换代前未执行输入",submissionID:UUID())
        try await wait("paused human claim") {gate.isEntered}
        race.bindRustScheduler(second,availability:{false})
        gate.resume.signal()
        for _ in 0..<100 {
            rows=try await events(transport,"claim-race")
            if rows.last?["state"] as? String == "cancelled" {break;}
            try await Task.sleep(for:.milliseconds(5))
        }
        precondition(rows.last?["state"] as? String == "cancelled" && runner.inputs.count == 6,"scope change during claim cannot execute or replay stale input")
        let suite = "gmgn.rust.bridge." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let bridge = UnityResidentAgentLoopBridge(context:WorldAgentContext(),defaults:defaults,now:{clock.date},
            available:{true},run:{try await runner.run($0)},cancelRun:{},onReply:{_ in})
        bridge.bindScheduler(RustResidentSchedulerClient(worldID:"scheduler-test",residentScope:"host-bridge",endpointFile:endpoint.path,hostSessionID:"host-A"),backend:"codex")
        bridge.start()
        try await wait("actual bridge Rust claim") {runner.inputs.count == 7}
        for _ in 0..<100 {bridge.refresh();await Task.yield()}
        precondition(runner.inputs.count == 7,"actual Host bridge must not run old and Rust schedulers together")
        bridge.bindScheduler(RustResidentSchedulerClient(worldID:"scheduler-test",residentScope:"host-bridge",endpointFile:endpoint.path,hostSessionID:"host-B"),backend:"dsh")
        bridge.refresh()
        try await Task.sleep(for:.milliseconds(30))
        runner.finish()
        for _ in 0..<100 {
            clock.date += 1;bridge.refresh();try await Task.sleep(for:.milliseconds(5))
        }
        rows=try await events(transport,"host-bridge")
        precondition(rows.contains {$0["state"] as? String == "unknown"} && runner.inputs.count == 7,
            "backend/session switch retains unknown old side effects and cannot replay next run")
        bridge.close()
        defaults.set(false,forKey:UnityResidentAgentLoopBridge.enabledKey)
        let humanBridge=UnityResidentAgentLoopBridge(context:WorldAgentContext(),defaults:defaults,now:{clock.date},
            available:{true},run:{try await runner.run($0)},cancelRun:{},onReply:{_ in preconditionFailure("human UI already owns reply")})
        humanBridge.humanRun={input in
            let durable=try await events(transport,"host-human")
            precondition(durable.last?["state"] as? String == "claimed" && durable.last?["runID"] as? String == input.runID.uuidString)
            return try await runner.run(input)
        }
        humanBridge.bindScheduler(RustResidentSchedulerClient(worldID:"scheduler-test",residentScope:"host-human",endpointFile:endpoint.path,hostSessionID:"human-session"),backend:"codex")
        humanBridge.start();humanBridge.humanTurnWillBegin()
        humanBridge.loop.receiveUserMessage("真实宿主人类入口",imageURLs:[image],submissionID:UUID())
        try await wait("actual Host human claim") {runner.inputs.count == 8}
        precondition(!runner.inputs[7].isBackground && runner.inputs[7].imageURLs == [image])
        humanBridge.loop.cancel()
        try await Task.sleep(for:.milliseconds(30))
        rows=try await events(transport,"host-human")
        precondition(rows.last?["state"] as? String == "cancel_requested","UI cancellation cannot acknowledge provider stopping")
        runner.finish()
        for _ in 0..<100 {
            rows=try await events(transport,"host-human")
            if rows.last?["state"] as? String == "completed" {break}
            try await Task.sleep(for:.milliseconds(5))
        }
        precondition(rows.last?["state"] as? String == "completed","actual late provider completion settles original human claim")
        humanBridge.close()
        defaults.set(true,forKey:UnityResidentAgentLoopBridge.enabledKey)
        let stableRunner=SchedulerRunner()
        let stableBridge=UnityResidentAgentLoopBridge(context:WorldAgentContext(),defaults:defaults,now:{clock.date},
            available:{true},run:{try await stableRunner.run($0)},cancelRun:{},onReply:{_ in})
        func stableClient() -> RustResidentSchedulerClient {
            RustResidentSchedulerClient(worldID:"scheduler-test",residentScope:"stable-owner",endpointFile:endpoint.path,hostSessionID:"shared-wish-host")
        }
        stableBridge.bindScheduler(stableClient(),backend:"codex");stableBridge.start()
        try await wait("stable owner first claim") {stableRunner.inputs.count == 1}
        stableBridge.bindScheduler(stableClient(),backend:"dsh")
        for _ in 0..<30 {clock.date += 1;stableBridge.refresh();try await Task.sleep(for:.milliseconds(5))}
        rows=try await events(transport,"stable-owner")
        precondition(stableRunner.inputs.count == 1 && rows.first?["state"] as? String == "cancel_requested",
            "backend rebinding with shared host session must retain the old execution barrier")
        stableRunner.finish()
        for _ in 0..<100 {
            clock.date += 1;stableBridge.refresh();try await Task.sleep(for:.milliseconds(5))
            if stableRunner.inputs.count == 2 {break}
        }
        rows=try await events(transport,"stable-owner")
        precondition(rows.first?["state"] as? String == "completed" && stableRunner.inputs.count == 2,
            "same host backend change accepts actual old receipt before granting new execution")
        stableBridge.close();stableRunner.finish()
        print("PASS: real private daemon -> durable background/human claim, no raw memory, budget exemption, FIFO images, guide unknown no replay, stop/late receipts, scope/session gates, actual Host bridge single scheduler")
    }
}
