import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift")
guard FileManager.default.fileExists(atPath: source.path) else {
    print("FAIL: resident has no general serial intent/event loop")
    exit(1)
}
let harness = #"""
import Foundation
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}
@MainActor final class Clock {
    var date = Date(timeIntervalSince1970: 1000)
    func advance(_ seconds: Double) { date += seconds }
}
@MainActor final class Runner {
    var inputs: [ResidentAgentLoop.Input] = []
    var continuations: [CheckedContinuation<String, Error>] = []
    var replies: [String] = []
    var errors: [String] = []
    var steered: [String] = []
    var delivery = ResidentSteeringDelivery.notDelivered
    var holdSteering = false
    var steeringContinuations: [CheckedContinuation<ResidentSteeringDelivery, Never>] = []
    func run(_ input: ResidentAgentLoop.Input) async throws -> String {
        inputs.append(input)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(_ value: String = "done") { continuations.removeFirst().resume(returning: value) }
    func steer(_ text: String) async -> ResidentSteeringDelivery {
        steered.append(text)
        if holdSteering { return await withCheckedContinuation { steeringContinuations.append($0) } }
        return delivery
    }
}
@MainActor func settle() async { for _ in 0..<30 { await Task.yield() } }
@main struct Tests {
    @MainActor static func main() async throws {
        let clock = Clock(), runner = Runner()
        let loop = ResidentAgentLoop(now: { clock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 2, maximumQueuedEvents: 3),
            run: { try await runner.run($0) },
            steer: { runner.steered.append($0); return runner.delivery },
            onReply: { runner.replies.append($0) }, onFailure: { runner.errors.append($0) })
        loop.receiveEvent(.init(id: "arrival", kind: "world.changed", summary: "arrived"))
        await settle()
        check(runner.inputs.isEmpty, "background model calls default off")
        loop.receiveUserMessage("听点歌")
        await settle()
        check(runner.inputs.count == 1 && runner.inputs[0].userMessages == ["听点歌"], "user starts a serial turn")
        check(runner.inputs[0].events.count == 1, "user turn also observes pending environment")
        loop.receiveUserMessage("今天有点累")
        await settle()
        check(runner.steered == ["今天有点累"], "active ordinary input attempts steer without keyword intent parsing")
        check(runner.inputs.count == 1 && loop.snapshot.pendingUserMessages == ["今天有点累"], "unavailable steer queues instead of restarting")
        runner.finish()
        await settle()
        check(runner.inputs.count == 2 && runner.inputs[1].userMessages == ["今天有点累"], "undelivered guidance continues next serial turn")
        runner.delivery = .delivered
        loop.receiveUserMessage("换舒缓的")
        await settle()
        check(loop.snapshot.pendingUserMessages.isEmpty, "delivered steering is not replayed next turn")
        try loop.updateIntent(summary: "找舒缓歌单", status: .waitingUser, wakeAfterSeconds: nil)
        runner.finish("")
        await settle()
        check(runner.replies == ["done"], "explicit intent control allows a silent finish")
        check(loop.snapshot.intent?.summary == "找舒缓歌单", "intent retained across turns")
        loop.setBackgroundEnabled(true)
        clock.advance(20)
        loop.tick()
        await settle()
        check(runner.inputs.count == 2, "waiting for user does not poll model automatically")

        loop.receiveUserMessage("你自己决定")
        await settle()
        try loop.updateIntent(summary: "了解房间", status: .waitingEvent, wakeAfterSeconds: 10)
        runner.finish("")
        await settle()
        loop.tick(); await settle()
        check(runner.inputs.count == 3, "wake respects requested time")
        clock.advance(10); loop.tick(); await settle()
        check(runner.inputs.count == 4 && runner.inputs[3].isBackground, "scheduled wake invokes same loop")
        try loop.updateIntent(summary: "继续观察", status: .active, wakeAfterSeconds: nil)
        runner.finish(""); await settle()
        loop.tick(); await settle()
        check(runner.inputs.count == 4, "no tight autonomous retry loop")
        clock.advance(10); loop.tick(); await settle()
        check(runner.inputs.count == 5, "active intent resumes on bounded tick")
        try loop.updateIntent(summary: "继续观察", status: .active, wakeAfterSeconds: nil)
        runner.finish(""); await settle()
        clock.advance(20); loop.tick(); await settle()
        check(runner.inputs.count == 5, "background hourly budget caps calls")

        loop.receiveUserMessage("继续刚才的"); await settle()
        check(runner.inputs.count == 6 && !runner.inputs[5].isBackground, "human guidance bypasses autonomous budget")
        loop.stop()
        check(!loop.snapshot.isRunning && loop.snapshot.isStopped, "stop changes state immediately")
        check(loop.snapshot.intent?.summary == "继续观察", "stop preserves intent summary")
        runner.finish("late answer"); await settle()
        check(!runner.replies.contains("late answer"), "late result after stop is ignored")
        clock.advance(4000); loop.tick(); await settle()
        check(runner.inputs.count == 6, "explicit stop suppresses autonomous restart")
        loop.receiveUserMessage("继续"); await settle()
        check(runner.inputs.count == 7, "new guidance resumes stopped loop")
        loop.invalidate()
        runner.finish("old room answer"); await settle()
        loop.receiveUserMessage("not accepted"); await settle()
        check(runner.inputs.count == 7 && !runner.replies.contains("old room answer"), "invalidated scope never publishes or starts another turn")

        let events = Runner()
        let eventLoop = ResidentAgentLoop(now: { clock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 3, maximumQueuedEvents: 3),
            run: { try await events.run($0) })
        eventLoop.receiveEvent(.init(id: "same", kind: "weather", summary: "sunny"))
        eventLoop.receiveEvent(.init(id: "same", kind: "weather", summary: "duplicate"))
        eventLoop.receiveEvent(.init(id: "new", kind: "weather", summary: "rainy"))
        eventLoop.receiveEvent(.init(id: "door", kind: "door", summary: "open"))
        eventLoop.receiveEvent(.init(id: "music", kind: "music", summary: "ended"))
        eventLoop.receiveEvent(.init(id: "light", kind: "light", summary: "off"))
        eventLoop.receiveUserMessage("看看周围"); await settle()
        check(events.inputs[0].events.count == 3, "event queue bounded and latest environment kinds coalesced")
        check(!events.inputs[0].events.contains { $0.summary == "duplicate" }, "event IDs deduplicate")
        do {
            try eventLoop.updateIntent(summary: String(repeating: "a", count: 2001), status: .active, wakeAfterSeconds: nil)
            check(false, "oversized intent rejected")
        } catch { check(true, "oversized intent rejected") }
        do {
            try eventLoop.updateIntent(summary: "plan", status: .waitingEvent, wakeAfterSeconds: .nan)
            check(false, "nonfinite wake rejected")
        } catch { check(true, "nonfinite wake rejected") }
        events.finish(""); await settle()
        check(eventLoop.snapshot.lastFailure != nil, "uncontrolled empty result is an error, not silent success")

        let racing = Runner()
        racing.holdSteering = true
        let raceLoop = ResidentAgentLoop(run: { try await racing.run($0) },
            steer: { await racing.steer($0) }, onReply: { racing.replies.append($0) })
        raceLoop.receiveUserMessage("读一本书"); await settle()
        let lease = ResidentLoopTools(loop: raceLoop, runID: racing.inputs[0].runID)
        check(!lease.handle(name: "read_resident_state", argumentsJSON: Data("{}".utf8)).isError, "current turn can inspect intent state")
        let control = lease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"等环境变化","status":"waiting_event"}"#.utf8))
        let controlJSON = try JSONSerialization.jsonObject(with: control.data) as! [String: Any]
        check(!control.isError && controlJSON["intent_is_verified_world_fact"] as? Bool == false, "plan control never claims verified world success")
        check(lease.allowsSilentCompletion, "successful explicit control enables silence for this run")
        check(lease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"bad","status":"active","wake_after_seconds":true}"#.utf8)).isError, "tool rejects boolean as numeric wake")
        raceLoop.receiveUserMessage("窗外是什么"); await settle()
        racing.finish("first answer"); await settle()
        check(racing.inputs.count == 1 && raceLoop.snapshot.isRunning, "completion waits for outstanding steering acknowledgement")
        racing.steeringContinuations.removeFirst().resume(returning: .delivered); await settle()
        check(racing.inputs.count == 1 && raceLoop.snapshot.pendingUserMessages.isEmpty, "acknowledged guidance is not duplicated when run completed first")
        check(lease.handle(name: "read_resident_state", argumentsJSON: Data("{}".utf8)).isError && !lease.allowsSilentCompletion, "ended turn lease cannot read or authorize later silence")
        raceLoop.receiveUserMessage("看看门口"); await settle()
        raceLoop.receiveUserMessage("要走了吗"); await settle()
        racing.steeringContinuations.removeFirst().resume(returning: .unknown); await settle()
        racing.finish("second answer"); await settle()
        check(racing.inputs.count == 2 && raceLoop.snapshot.unconfirmedUserMessages == ["要走了吗"], "unknown delivery is visible but never automatically replayed")
        raceLoop.receiveUserMessage("继续"); await settle()
        check(racing.inputs[2].userMessages == ["继续"], "unconfirmed input is not resent with next human turn")
        check(racing.inputs[2].promptText.contains("要走了吗") && racing.inputs[2].promptText.contains("unconfirmedUserMessages"), "next turn observes uncertain delivery without a fresh instruction")
        raceLoop.receiveUserMessage("不用去"); await settle()
        raceLoop.stop()
        racing.steeringContinuations.removeFirst().resume(returning: .delivered)
        racing.finish("cancelled answer"); await settle()
        check(!racing.replies.contains("cancelled answer") && raceLoop.snapshot.unconfirmedUserMessages.contains("不用去"), "stop during steer retains uncertain delivery and rejects old completion")

        let immediate = Runner()
        let immediateLoop = ResidentAgentLoop(run: { try await immediate.run($0) })
        immediateLoop.receiveUserMessage("马上出发")
        immediateLoop.stop()
        await settle()
        check(immediate.inputs.isEmpty, "stop before scheduled task starts never invokes provider")
        if !immediate.continuations.isEmpty { immediate.finish(); await settle() }

        let stoppedQueue = Runner()
        let stoppedQueueLoop = ResidentAgentLoop(run: { try await stoppedQueue.run($0) })
        stoppedQueueLoop.receiveUserMessage("第一件事"); await settle()
        stoppedQueueLoop.receiveUserMessage("旧排队操作"); await settle()
        stoppedQueueLoop.stop()
        stoppedQueue.finish(); await settle()
        stoppedQueueLoop.receiveUserMessage("新的方向"); await settle()
        check(stoppedQueue.inputs[1].userMessages == ["新的方向"], "stop drops automatic replay of old queued actions")
        check(stoppedQueue.inputs[1].lastTurnInterrupted && stoppedQueue.inputs[1].lastTurnUserMessages == ["第一件事", "旧排队操作"], "interrupted messages remain context without becoming fresh instructions")
        stoppedQueue.finish(); await settle()
        let immediateSteer = Runner()
        let immediateSteerLoop = ResidentAgentLoop(run: { try await immediateSteer.run($0) },
            steer: { await immediateSteer.steer($0) })
        immediateSteerLoop.receiveUserMessage("观察房间"); await settle()
        immediateSteerLoop.receiveUserMessage("旧方向")
        immediateSteerLoop.stop()
        await settle()
        check(immediateSteer.steered.isEmpty, "stop before queued steer starts never writes to provider")
        immediateSteer.finish(); await settle()

        let background = Runner(), backgroundClock = Clock()
        var backgroundChanges = 0, backgroundCancels = 0
        let backgroundLoop = ResidentAgentLoop(now: { backgroundClock.date },
            run: { try await background.run($0) }, steer: { await background.steer($0) },
            onReply: { background.replies.append($0) },
            onChange: { backgroundChanges += 1 }, onCancel: { backgroundCancels += 1 })
        backgroundLoop.setBackgroundEnabled(false)
        check(backgroundChanges == 0, "unchanged background permission does not publish state")
        backgroundLoop.setBackgroundEnabled(true)
        backgroundLoop.tick(); await settle()
        check(background.inputs.count == 1 && background.inputs[0].isBackground, "enabled idle tick starts a background turn")
        try backgroundLoop.updateIntent(summary: "日常观察", status: .active, wakeAfterSeconds: nil)
        backgroundLoop.setBackgroundEnabled(false)
        check(!backgroundLoop.snapshot.isRunning && backgroundCancels == 1, "disabling background immediately cancels pure background work")
        check(!backgroundLoop.snapshot.intentPausedByUser, "background permission change is not an explicit intent stop")
        background.finish("late autonomous answer"); await settle()
        check(background.replies.isEmpty, "disabled background cannot publish late completion")
        backgroundClock.advance(70)
        backgroundLoop.setBackgroundEnabled(true)
        backgroundLoop.tick(); await settle()
        check(background.inputs.count == 2, "reenabling background can wake after permission cancellation")
        background.delivery = .delivered
        backgroundLoop.receiveUserMessage("你看到什么了"); await settle()
        backgroundLoop.setBackgroundEnabled(false)
        check(backgroundLoop.snapshot.isRunning && backgroundCancels == 1, "human steering promotes background turn so permission change does not kill it")
        background.finish("human answer"); await settle()
        check(background.replies == ["human answer"], "promoted human turn finishes normally")
        backgroundLoop.receiveUserMessage("再说一句"); await settle()
        backgroundLoop.setBackgroundEnabled(true)
        backgroundLoop.setBackgroundEnabled(false)
        check(backgroundLoop.snapshot.isRunning && backgroundCancels == 1, "disabling background never cancels an original foreground turn")
        backgroundLoop.stop()
        background.finish(); await settle()
        backgroundLoop.setBackgroundEnabled(true)
        backgroundClock.advance(70); backgroundLoop.tick(); await settle()
        check(background.inputs.count == 3, "background permission toggles do not undo explicit user stop")

        let ordered = Runner()
        let orderedLoop = ResidentAgentLoop(run: { try await ordered.run($0) },
            steer: { await ordered.steer($0) })
        orderedLoop.receiveUserMessage("看看有什么歌"); await settle()
        orderedLoop.receiveUserMessage("先放爵士"); await settle()
        ordered.delivery = .delivered
        orderedLoop.receiveUserMessage("改成古典"); await settle()
        check(ordered.steered == ["先放爵士"], "later guidance cannot overtake an earlier undelivered message")
        check(orderedLoop.snapshot.pendingUserMessages == ["先放爵士", "改成古典"], "undelivered guidance retains chronological context")
        ordered.finish(); await settle()
        check(ordered.inputs[1].userMessages == ["先放爵士", "改成古典"], "next turn receives original instruction before its correction")
        ordered.finish(); await settle()

        let paused = Runner(), pausedClock = Clock()
        let pausedLoop = ResidentAgentLoop(now: { pausedClock.date }, run: { try await paused.run($0) }, steer: { await paused.steer($0) })
        pausedLoop.receiveUserMessage("去窗边看看"); await settle()
        try pausedLoop.updateIntent(summary: "去窗边观察", status: .active, wakeAfterSeconds: nil)
        paused.finish("正在去窗边"); await settle()
        pausedLoop.stop()
        pausedLoop.receiveUserMessage("你好"); await settle()
        check(paused.inputs[1].promptText.contains(#""intentPausedByUser":true"#), "stop after completed turn marks existing intent paused in later input")
        let pausedLease = ResidentLoopTools(loop: pausedLoop, runID: paused.inputs[1].runID)
        let accidentalResume = pausedLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"继续去窗边","status":"active"}"#.utf8))
        check(accidentalResume.isError, "ordinary intent update cannot silently resume paused work")
        paused.finish("你好"); await settle()
        pausedLoop.setBackgroundEnabled(true)
        pausedClock.advance(70); pausedLoop.tick(); await settle()
        check(paused.inputs.count == 2, "greeting does not let old intent restart autonomously")
        if !paused.continuations.isEmpty { paused.finish(); await settle() }
        pausedLoop.receiveUserMessage("继续刚才观察窗外"); await settle()
        let resumeLease = ResidentLoopTools(loop: pausedLoop, runID: paused.inputs.last!.runID)
        let explicitResume = resumeLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"检查位置后继续观察","status":"active","resume_paused_intent":true}"#.utf8))
        check(!explicitResume.isError, "fresh human guidance may explicitly resume or replace paused intent")
        paused.finish("继续"); await settle()
        pausedClock.advance(70); pausedLoop.tick(); await settle()
        check(paused.inputs.last!.isBackground, "explicit resumption restores autonomous continuation")
        let backgroundLease = ResidentLoopTools(loop: pausedLoop, runID: paused.inputs.last!.runID)
        check(backgroundLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"自动恢复","status":"active","resume_paused_intent":true}"#.utf8)).isError, "autonomous turn cannot assert human-authorized resumption")
        paused.delivery = .delivered
        pausedLoop.receiveUserMessage("换个新目标"); await settle()
        check(!backgroundLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"按新指导换目标","status":"active","resume_paused_intent":true}"#.utf8)).isError, "successfully delivered human steering authorizes explicit intent replacement")
        check(backgroundLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"invalid","status":"active","resume_paused_intent":1}"#.utf8)).isError, "intent resume flag rejects numeric booleans")
        pausedLoop.stop()
        if !paused.continuations.isEmpty { paused.finish(); await settle() }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident loop checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-agent-loop-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("LoopTests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("loop-tests")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let deliverySource = source.deletingLastPathComponent().appendingPathComponent("ResidentSteeringDelivery.swift")
let toolsSource = source.deletingLastPathComponent().appendingPathComponent("ResidentLoopTools.swift")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", deliverySource.path, source.path, toolsSource.path, program.path, "-o", executable.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = executable
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
