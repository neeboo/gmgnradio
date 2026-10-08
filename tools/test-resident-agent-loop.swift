import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift")
guard (try String(contentsOf: source, encoding: .utf8)).contains("func recordToolProgress(") else {
    print("FAIL: resident loop has no run-scoped visible tool progress")
    exit(1)
}
guard FileManager.default.fileExists(atPath: source.path) else {
    print("FAIL: resident has no general serial intent/event loop")
    exit(1)
}
guard (try String(contentsOf: source, encoding: .utf8)).contains("func setBackgroundTurnsPerHour(") else {
    print("FAIL: resident loop exposes no runtime background turn budget")
    exit(1)
}
let loopToolsSource = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentLoopTools.swift")
let loopToolsSourceText = try String(contentsOf: loopToolsSource, encoding: .utf8)
guard loopToolsSourceText.contains("只表示本循环实例会话内真正发起、失败与取消的模型轮次"),
      loopToolsSourceText.contains("不是 HTTP 请求数、Token 用量或计费数据"),
      loopToolsSourceText.contains("不写入记忆或其他持久存储") else {
    print("FAIL: read_resident_state schema does not document model-round statistics semantics")
    exit(1)
}
let harness = #"""
import Foundation
import Darwin
enum PictureFailure: LocalizedError {
    case providerUnsupported
    var errorDescription: String? { "当前后端不支持图片" }
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
    else if ProcessInfo.processInfo.environment["GMGN_FIXTURE_TRACE"] == "1" { print("PASS[\(checks)]: \(message)") }
    fflush(nil)
}
@MainActor final class Clock {
    var date = Date(timeIntervalSince1970: 1000)
    func advance(_ seconds: Double) { date += seconds }
}
@MainActor final class Runner {
    var inputs: [ResidentAgentLoop.Input] = []
    var continuations: [CheckedContinuation<String, Error>] = []
    var executingRunIDs: [UUID] = []
    var replies: [String] = []
    var errors: [String] = []
    var steered: [String] = []
    var delivery = ResidentSteeringDelivery.notDelivered
    var holdSteering = false
    var steeringContinuations: [CheckedContinuation<ResidentSteeringDelivery, Never>] = []
    func run(_ input: ResidentAgentLoop.Input) async throws -> String {
        inputs.append(input)
        executingRunIDs.append(input.runID)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(_ value: String = "done") { executingRunIDs.removeFirst(); continuations.removeFirst().resume(returning: value) }
    func fail(_ error: Error = PictureFailure.providerUnsupported) async {
        let runID = executingRunIDs.removeFirst()
        continuations.removeFirst().resume(throwing: error)
        if error is CancellationError {
            do { try await fixtureNativeCancellationReturned(runID: runID, awaitProjection: steeringContinuations.isEmpty) }
            catch { failures += 1; print("FAIL: actual private provider cancellation receipt: \(error)"); fflush(nil) }
        }
    }
    func steer(_ text: String) async -> ResidentSteeringDelivery {
        steered.append(text)
        if holdSteering { return await withCheckedContinuation { steeringContinuations.append($0) } }
        return delivery
    }
}
// A real private HTTP claim/intent transaction crosses detached workers.
// Bounded wall-clock settling does not advance any injected business clock.
@MainActor func settle() async {
    for _ in 0..<30 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(150))
}
@MainActor func checkDurableEventBacklog(silent: Bool) async throws {
    let runner = Runner()
    let loop = await fixtureResidentLoop(run: { try await runner.run($0) })
    let events = (24...76).map { sequence in
        let id = "wish.stable-message-\(sequence)"
        return ResidentAgentLoop.Event(id: id, kind: "task.stateChanged.task.\(id)", summary: "\(sequence)")
    }
    var acknowledged: Set<String> = []
    var batchCounts: [Int] = []
    for pass in 1...3 {
        for event in events where !acknowledged.contains(event.id) { loop.receiveEvent(event) }
        loop.receiveUserMessage("处理已投递结果 \(pass)"); await settle()
        let input = runner.inputs.last!
        batchCounts.append(input.events.count)
        check(input.events.count <= 24, "durable redelivery keeps each model input bounded")
        if silent {
            try await loop.updateIntent(summary: "结果已观察，继续等待", status: .waitingEvent,
                                  wakeAfterSeconds: nil, runID: input.runID)
            check(loop.allowsSilentCompletion(runID: input.runID), "backlog silent completion is licensed by this run's intent update")
        }
        runner.finish(silent ? "" : "结果已处理"); await settle()
        // Only successful turns are acknowledged, mirroring the App's input.events boundary.
        if loop.snapshot.lastFailure == nil { acknowledged.formUnion(input.events.map(\.id)) }
    }
    check(acknowledged.count == 53, "53 durable IDs all remain deliverable after capacity eviction and successful \(silent ? "silent" : "visible") turns; observed \(acknowledged.count)")
    check(batchCounts == [24, 24, 5], "bounded durable backlog drains in three batches, observed \(batchCounts)")
    print("BACKLOG \(silent ? "silent" : "visible"): batches=\(batchCounts), acknowledged=\(acknowledged.count)/53")
    for event in events { loop.receiveEvent(event) }
    loop.receiveUserMessage("确认已处理结果没有重复"); await settle()
    check(runner.inputs.last!.events.isEmpty, "successful durable observations remain deduplicated")
    runner.finish(); await settle()
}
/// 取消的**成因**必须能被宿主区分：只有真实用户停止才是"用户意图"，它可以持久停用
/// 自主续办并要求一次显式恢复；换空间、退出、自主可用性/网络回收、后台预算回收都只是
/// 宿主回收本轮，绝不能写出一个只有人工能解除的状态。旧代码把这两件事都塞进 `onCancel`，
/// 于是"网络抖动"最终变成许愿面板上的「[自主行动已停止] (恢复自动领取)」。
@MainActor func checkCancellationProvenance() async throws {
    let provenanceRunner = Runner()
    var cancels = 0, userStops = 0
    let provenanceClock = Clock()
    let provenanceLoop = await fixtureResidentLoop(now: { provenanceClock.date },
        configuration: .init(minimumWakeInterval: 1, backgroundTurnsPerHour: 2),
        run: { try await provenanceRunner.run($0) },
        onCancel: { cancels += 1 },
        onUserStop: { userStops += 1 })
    provenanceLoop.setBackgroundEnabled(true)
    provenanceLoop.tick(); await settle()
    check(provenanceRunner.inputs.count == 1 && provenanceLoop.snapshot.isBackgroundRun,
          "provenance fixture really started a background turn")
    // 自主可用性/网络回收：取消本轮，但绝不是用户停止。
    provenanceLoop.setBackgroundEnabled(false); await settle()
    check(cancels == 1 && userStops == 0,
          "availability/network reclamation cancels the turn without claiming a user stop")
    check(!provenanceLoop.snapshot.isStopped && !provenanceLoop.snapshot.intentPausedByUser,
          "availability/network reclamation never leaves a durable user-stop state")
    // 换空间/退出走 invalidate()：同样不是用户停止。
    provenanceLoop.invalidate(); await settle()
    check(cancels == 2 && userStops == 0,
          "world switch or app quit cancels the turn without claiming a user stop")
    // 真实用户停止：两条通道都报，且只有它报用户意图。
    let stopLoop = await fixtureResidentLoop(run: { _ in "done" }, onCancel: { cancels += 1 }, onUserStop: { userStops += 1 })
    stopLoop.stop()
    await settle()
    check(userStops == 1 && stopLoop.snapshot.isStopped && stopLoop.snapshot.intentPausedByUser,
          "only an explicit user stop reports user intent and leaves the resident stopped")
    stopLoop.stop()
    check(userStops == 2, "each explicit user stop is reported (host may repeat the durable pause)")
}

@MainActor func checkModelTurnStatistics() async throws {
    // ---- 每次模型轮次只计一次开始；成功、失败、取消是彼此区分的终态。
    let statsClock = Clock(), stats = Runner()
    let statsLoop = await fixtureResidentLoop(now: { statsClock.date },
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 2),
        run: { try await stats.run($0) },
        onFailure: { stats.errors.append($0) })
    let fresh = statsLoop.snapshot
    check(fresh.modelTurnsStarted == 0 && fresh.backgroundModelTurnsStarted == 0
          && fresh.failedModelTurns == 0 && fresh.cancelledModelTurns == 0
          && fresh.backgroundTurnsInLastHour == 0 && fresh.backgroundTurnsPerHour == 2,
          "a fresh loop reports zero model round statistics and its configured background budget")

    statsLoop.receiveUserMessage("成功的事"); await settle()
    check(statsLoop.snapshot.modelTurnsStarted == 1 && statsLoop.snapshot.backgroundModelTurnsStarted == 0,
          "one human turn counts exactly one invocation start")
    stats.finish("好"); await settle()
    check(statsLoop.snapshot.modelTurnsStarted == 1 && statsLoop.snapshot.failedModelTurns == 0
          && statsLoop.snapshot.cancelledModelTurns == 0,
          "a successful turn stays counted once and is neither failed nor cancelled")

    statsLoop.receiveUserMessage("失败的事"); await settle()
    await stats.fail(); await settle()
    check(statsLoop.snapshot.modelTurnsStarted == 2 && statsLoop.snapshot.failedModelTurns == 1
          && statsLoop.snapshot.cancelledModelTurns == 0,
          "provider failure counts as failed without also counting as cancelled")

    statsLoop.receiveUserMessage("取消的事"); await settle()
    await stats.fail(CancellationError()); await settle()
    check(statsLoop.snapshot.modelTurnsStarted == 3 && statsLoop.snapshot.failedModelTurns == 1
          && statsLoop.snapshot.cancelledModelTurns == 1,
          "provider cancellation counts as cancelled without also counting as failed")

    statsLoop.receiveUserMessage("被停止的事"); await settle()
    statsLoop.stop()
    check(statsLoop.snapshot.modelTurnsStarted == 4 && statsLoop.snapshot.failedModelTurns == 1
          && statsLoop.snapshot.cancelledModelTurns == 2,
          "explicit stop cancels exactly one in-flight invocation")

    statsLoop.receiveUserMessage("停后的新事"); await settle()
    // Rust retains the cancelled invocation until this native leaf really
    // returns. Its stale failure is discarded before the next serial claim.
    await stats.fail()
    await settle()
    check(statsLoop.snapshot.modelTurnsStarted == 5 && statsLoop.snapshot.isRunning,
          "new human guidance starts the next invocation while the stale one stays superseded")
    check(statsLoop.snapshot.modelTurnsStarted == 5 && statsLoop.snapshot.failedModelTurns == 1
          && statsLoop.snapshot.cancelledModelTurns == 2 && statsLoop.snapshot.isRunning,
          "a stale completion never changes the newer run or duplicates the outcome counts")
    check(stats.errors.count == 1,
          "a stale failure never surfaces as a fresh resident failure")
    stats.finish("新结果"); await settle()
    check(statsLoop.snapshot.modelTurnsStarted == 5 && statsLoop.snapshot.failedModelTurns == 1
          && statsLoop.snapshot.cancelledModelTurns == 2 && !statsLoop.snapshot.isRunning,
          "the current run still ends normally after a stale completion was discarded")

    // ---- 空结果沿用既有失败定义：无控制权的空回复是失败轮次，获准的静默完成不是。
    let outcomes = Runner()
    let outcomesLoop = await fixtureResidentLoop(run: { try await outcomes.run($0) })
    let failedSubmission = UUID()
    outcomesLoop.receiveUserMessage("空结果", submissionID: failedSubmission); await settle()
    outcomes.finish(""); await settle()
    check(outcomesLoop.snapshot.modelTurnsStarted == 1 && outcomesLoop.snapshot.failedModelTurns == 1
          && outcomesLoop.snapshot.cancelledModelTurns == 0,
          "an uncontrolled empty reply counts as a failed round, never as cancellation")
    check(outcomesLoop.lastFinishedTurnWasSilent == false
          && outcomesLoop.lastFinishedTurnSubmissionIDs == [failedSubmission],
          "a failed empty round reports its covered submission without claiming a silent completion")
    let silentSubmission = UUID()
    outcomesLoop.receiveUserMessage("静默完成", submissionID: silentSubmission); await settle()
    try await outcomesLoop.updateIntent(summary: "已记录，等待事件", status: .waitingEvent, wakeAfterSeconds: 60)
    outcomes.finish(""); await settle()
    check(outcomesLoop.snapshot.modelTurnsStarted == 2 && outcomesLoop.snapshot.failedModelTurns == 1
          && outcomesLoop.snapshot.cancelledModelTurns == 0,
          "an explicitly silent completion is not a failed round")
    check(outcomesLoop.lastFinishedTurnWasSilent == true
          && outcomesLoop.lastFinishedTurnSubmissionIDs == [silentSubmission],
          "an allowed silent completion reports the covered submission for the visible history")

    // ---- 滚动一小时直接从既有 backgroundTurnDates 推导。
    let deferred = Runner()
    deferred.holdSteering = true
    let deferredLoop = await fixtureResidentLoop(run: { try await deferred.run($0) },
        steer: { await deferred.steer($0) })
    deferredLoop.receiveUserMessage("先开始"); await settle()
    deferredLoop.receiveUserMessage("追加引导"); await settle()
    await deferred.fail(); await settle()
    deferredLoop.stop()
    check(deferredLoop.snapshot.failedModelTurns == 1 && deferredLoop.snapshot.cancelledModelTurns == 0,
          "a model failure already returned while steering waits remains counted after stop")
    deferred.steeringContinuations.removeFirst().resume(returning: .delivered); await settle()
    check(deferredLoop.snapshot.failedModelTurns == 1 && deferredLoop.snapshot.cancelledModelTurns == 0,
          "late steering cannot duplicate the already recorded model failure")

    let deferredCancellation = Runner()
    deferredCancellation.holdSteering = true
    let deferredCancellationLoop = await fixtureResidentLoop(run: { try await deferredCancellation.run($0) },
        steer: { await deferredCancellation.steer($0) })
    deferredCancellationLoop.receiveUserMessage("先开始取消"); await settle()
    deferredCancellationLoop.receiveUserMessage("追加引导取消"); await settle()
    await deferredCancellation.fail(CancellationError()); await settle()
    deferredCancellationLoop.stop()
    check(deferredCancellationLoop.snapshot.cancelledModelTurns == 1
          && deferredCancellationLoop.snapshot.failedModelTurns == 0,
          "a provider cancellation already returned while steering waits remains counted once after stop")
    deferredCancellation.steeringContinuations.removeFirst().resume(returning: .delivered); await settle()
    check(deferredCancellationLoop.snapshot.cancelledModelTurns == 1
          && deferredCancellationLoop.snapshot.failedModelTurns == 0,
          "late steering cannot duplicate the already recorded model cancellation")

    let deferredEmpty = Runner()
    deferredEmpty.holdSteering = true
    let deferredEmptyLoop = await fixtureResidentLoop(run: { try await deferredEmpty.run($0) },
        steer: { await deferredEmpty.steer($0) })
    deferredEmptyLoop.receiveUserMessage("先开始空回复"); await settle()
    deferredEmptyLoop.receiveUserMessage("追加引导"); await settle()
    deferredEmpty.finish(""); await settle()
    deferredEmptyLoop.stop()
    check(deferredEmptyLoop.snapshot.modelTurnsStarted == 1
          && deferredEmptyLoop.snapshot.failedModelTurns == 1
          && deferredEmptyLoop.snapshot.cancelledModelTurns == 0,
          "an uncontrolled empty result waiting on steering remains failed after stop")
    deferredEmpty.steeringContinuations.removeFirst().resume(returning: .delivered); await settle()
    check(deferredEmptyLoop.snapshot.failedModelTurns == 1 && deferredEmptyLoop.snapshot.cancelledModelTurns == 0,
          "late steering cannot duplicate the empty-result failure")

    let queuedBudget = Runner()
    let queuedBudgetLoop = await fixtureResidentLoop(run: { try await queuedBudget.run($0) })
    queuedBudgetLoop.setBackgroundEnabled(true)
    queuedBudgetLoop.tick()
    queuedBudgetLoop.setBackgroundTurnsPerHour(0)
    await settle()
    check(queuedBudget.inputs.isEmpty && queuedBudgetLoop.snapshot.modelTurnsStarted == 0
          && queuedBudgetLoop.snapshot.backgroundTurnsInLastHour == 0,
          "zero budget before actual invocation blocks a queued background model call")
    queuedBudgetLoop.stop()
    if !queuedBudget.continuations.isEmpty { queuedBudget.finish(); await settle() }

    // ---- 调度后、真正调用前把预算降为 0：不得调用、不得计开始或用量；已经取走的
    // 待办（事件与 continuation）必须保留，预算恢复后恰好交付一次。
    let restoredClock = Clock(), restoredBudget = Runner()
    let restoredBudgetLoop = await fixtureResidentLoop(now: { restoredClock.date },
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 1, maximumQueuedEvents: 3),
        run: { try await restoredBudget.run($0) })
    let retainedReady = ResidentAgentLoop.Event(id: "budget-zero-continuation", kind: "wish.ready.retained", summary: "预算恢复后应交付的产物")
    let retainedEvent = ResidentAgentLoop.Event(id: "budget-zero-event", kind: "world.changed.retained", summary: "预算恢复后应交付的现场事实")
    restoredBudgetLoop.receiveContinuationEvent(retainedReady)
    restoredBudgetLoop.receiveEvent(retainedEvent)
    // 先按既有预算调度这一轮（captured 已经取走事件与 continuation），再把预算
    // 降为 0，让回滚发生在真正调用模型之前。
    restoredBudgetLoop.tick()
    restoredBudgetLoop.setBackgroundTurnsPerHour(0)
    await settle()
    check(restoredBudget.inputs.isEmpty && restoredBudgetLoop.snapshot.modelTurnsStarted == 0
          && restoredBudgetLoop.snapshot.backgroundModelTurnsStarted == 0
          && restoredBudgetLoop.snapshot.backgroundTurnsInLastHour == 0
          && !restoredBudgetLoop.snapshot.isRunning,
          "zero budget at invocation time rolls back the queued turn without a model call or usage")
    restoredClock.advance(10)
    restoredBudgetLoop.tick(); await settle()
    check(restoredBudget.inputs.isEmpty,
          "a rolled-back background turn keeps waiting while the budget stays zero")
    restoredBudgetLoop.setBackgroundTurnsPerHour(1)
    restoredBudgetLoop.tick(); await settle()
    check(restoredBudget.inputs.count == 1 && restoredBudget.inputs[0].isBackground
          && Set(restoredBudget.inputs[0].events.map(\.id)) == [retainedReady.id, retainedEvent.id],
          "restoring the budget delivers the retained continuation and event exactly once; observed \(restoredBudget.inputs.count) call(s)")
    restoredBudget.finish("已领取"); await settle()
    restoredClock.advance(10)
    restoredBudgetLoop.tick(); await settle()
    check(restoredBudget.inputs.count == 1,
          "a retained continuation that was finally delivered is not redelivered")
    restoredBudgetLoop.stop()
    if !restoredBudget.continuations.isEmpty { restoredBudget.finish(); await settle() }

    // ---- 预算降为 0 绝不能取消已经开始或已有结果的调用。
    let invokedClock = Clock(), invokedBudget = Runner()
    let invokedBudgetLoop = await fixtureResidentLoop(now: { invokedClock.date },
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 1),
        run: { try await invokedBudget.run($0) })
    invokedBudgetLoop.setBackgroundEnabled(true)
    invokedBudgetLoop.receiveEvent(.init(id: "budget-invoked-event", kind: "world.changed.invoked", summary: "已经开始的后台轮次"))
    invokedBudgetLoop.tick(); await settle()
    check(invokedBudget.inputs.count == 1 && invokedBudgetLoop.snapshot.backgroundModelTurnsStarted == 1,
          "the in-flight background invocation started before the budget changed")
    invokedBudgetLoop.setBackgroundTurnsPerHour(0)
    check(invokedBudgetLoop.snapshot.isRunning && invokedBudgetLoop.snapshot.cancelledModelTurns == 0,
          "lowering the budget to zero never cancels an already invoked background call")
    invokedBudget.finish("观察到现场变化"); await settle()
    check(invokedBudget.inputs.count == 1 && invokedBudgetLoop.snapshot.backgroundModelTurnsStarted == 1
          && invokedBudgetLoop.snapshot.cancelledModelTurns == 0
          && !invokedBudgetLoop.snapshot.isRunning,
          "the already invoked background call still finishes normally under a zero budget")
    invokedBudgetLoop.stop()
    if !invokedBudget.continuations.isEmpty { invokedBudget.finish(); await settle() }

    // ---- 预算为 0 只关闭自主后台，人类优先不受影响。
    let humanClock = Clock(), humanBudget = Runner()
    let humanBudgetLoop = await fixtureResidentLoop(now: { humanClock.date },
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 1),
        run: { try await humanBudget.run($0) })
    humanBudgetLoop.setBackgroundTurnsPerHour(0)
    humanBudgetLoop.tick(); await settle()
    check(humanBudget.inputs.isEmpty, "zero budget blocks a scheduled autonomous turn")
    humanClock.advance(10)
    humanBudgetLoop.receiveUserMessage("人来说一句"); await settle()
    check(humanBudget.inputs.count == 1 && !humanBudget.inputs[0].isBackground
          && humanBudget.inputs[0].userMessages == ["人来说一句"],
          "zero budget never blocks or delays a human turn")
    humanBudget.finish("回应人类"); await settle()
    humanBudgetLoop.stop()
    if !humanBudget.continuations.isEmpty { humanBudget.finish(); await settle() }

    let callbackOrder = Runner()
    callbackOrder.holdSteering = true
    let callbackLoop = await fixtureResidentLoop(run: { try await callbackOrder.run($0) },
        steer: { await callbackOrder.steer($0) }, onFailure: { callbackOrder.errors.append($0) })
    callbackLoop.receiveUserMessage("保留回调时序"); await settle()
    callbackLoop.receiveUserMessage("等待引导"); await settle()
    await callbackOrder.fail(); await settle()
    check(callbackOrder.errors.isEmpty && callbackLoop.snapshot.failedModelTurns == 1,
          "failure count is immediate but reporting still waits for steering completion")
    callbackOrder.steeringContinuations.removeFirst().resume(returning: .delivered); await settle()
    check(callbackOrder.errors.count == 1, "failure reports once at the original finish boundary")

    // ---- 回合归属留给宿主回调：finishIfReady 在回调前已把 activeRunIsBackground 清零，
    // 宿主只能靠 lastFinishedRunWasBackground 区分后台/用户回合，避免后台回合抢开聊天。
    let ownershipClock = Clock(), ownership = Runner()
    var ownershipFlags: [Bool] = []
    var ownershipLoop: ResidentAgentLoop!
    ownershipLoop = await fixtureResidentLoop(now: { ownershipClock.date },
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 3),
        run: { try await ownership.run($0) },
        onReply: { _ in ownershipFlags.append(ownershipLoop.lastFinishedRunWasBackground) })
    ownershipLoop.setBackgroundEnabled(true)
    ownershipLoop.tick(); await settle()
    check(ownership.inputs.count == 1 && ownership.inputs[0].isBackground,
          "background turn starts for the ownership check")
    check(ownershipLoop.snapshot.isBackgroundRun,
          "a running background turn is still reported as background to the presentation layer")
    ownership.finish("后台回复"); await settle()
    check(ownershipFlags == [true],
          "background reply tells the host it was autonomous before presentation")
    ownershipLoop.receiveUserMessage("人来一句"); await settle()
    check(ownership.inputs.count == 2 && !ownership.inputs[1].isBackground,
          "human turn starts for the ownership check")
    ownership.finish("人类回复"); await settle()
    check(ownershipFlags == [true, false],
          "user reply tells the host it was foreground so the chat may open")
    ownershipLoop.stop()
    if !ownership.continuations.isEmpty { ownership.finish(); await settle() }

    let ownershipFailure = Runner()
    var failureFlags: [Bool] = []
    var failureLoop: ResidentAgentLoop!
    failureLoop = await fixtureResidentLoop(
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 3),
        run: { try await ownershipFailure.run($0) },
        onFailure: { _ in failureFlags.append(failureLoop.lastFinishedRunWasBackground) })
    failureLoop.setBackgroundEnabled(true)
    failureLoop.tick(); await settle()
    await ownershipFailure.fail(); await settle()
    check(failureFlags == [true],
          "background failure tells the host it was autonomous before presentation")

    let budgetHuman = Runner()
    let budgetHumanLoop = await fixtureResidentLoop(run: { try await budgetHuman.run($0) },
        steer: { await budgetHuman.steer($0) })
    budgetHumanLoop.setBackgroundEnabled(true)
    budgetHumanLoop.tick()
    budgetHumanLoop.setBackgroundTurnsPerHour(0)
    budgetHumanLoop.receiveUserMessage("排队时人类来了")
    await settle()
    check(budgetHuman.inputs.count == 1 && budgetHuman.inputs.first?.userMessages == ["排队时人类来了"]
          && budgetHuman.inputs.first?.isBackground == false && budgetHuman.steered.isEmpty,
          "a human arriving before zero-budget rollback runs once as foreground without stale steering")
    budgetHumanLoop.stop()
    if !budgetHuman.continuations.isEmpty { budgetHuman.finish(); await settle() }

    let budgetClock = Clock(), budget = Runner()
    let budgetLoop = await fixtureResidentLoop(now: { budgetClock.date },
        configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 3),
        run: { try await budget.run($0) })
    budgetLoop.setBackgroundEnabled(true)
    budgetLoop.receiveEvent(.init(id: "turn-a", kind: "world.a", summary: "变化一"))
    budgetClock.advance(10); budgetLoop.tick(); await settle()
    check(budget.inputs.count == 1 && budget.inputs[0].isBackground
          && budgetLoop.snapshot.backgroundModelTurnsStarted == 1
          && budgetLoop.snapshot.modelTurnsStarted == 1,
          "a background invocation counts once in both total and background starts")
    check(budgetLoop.snapshot.backgroundTurnsInLastHour == 1, "recent background usage is inside the rolling hour")
    budget.finish("观察到一"); await settle()
    budgetLoop.receiveEvent(.init(id: "turn-b", kind: "world.b", summary: "变化二"))
    budgetClock.advance(10); budgetLoop.tick(); await settle()
    budget.finish("观察到二"); await settle()
    check(budget.inputs.count == 2 && budgetLoop.snapshot.backgroundTurnsInLastHour == 2,
          "the rolling hour accumulates each started background turn")

    // ---- 运行时下调预算不清空使用历史，且立即生效。
    budgetLoop.setBackgroundTurnsPerHour(1)
    check(budgetLoop.snapshot.backgroundTurnsPerHour == 1, "runtime budget exposes the updated limit")
    check(budgetLoop.snapshot.backgroundTurnsInLastHour == 2,
          "changing the runtime budget never clears background usage history")
    budgetLoop.receiveEvent(.init(id: "turn-c", kind: "world.c", summary: "变化三"))
    budgetClock.advance(10); budgetLoop.tick(); await settle()
    check(budget.inputs.count == 2, "a decreased budget immediately blocks further background turns")

    // ---- 过期使用量释放新一轮。
    budgetClock.advance(3_601)
    check(budgetLoop.snapshot.backgroundTurnsInLastHour == 0, "background usage older than one hour is no longer counted")
    budgetClock.advance(10); budgetLoop.tick(); await settle()
    check(budget.inputs.count == 3 && budget.inputs.last!.events.contains { $0.id == "turn-c" },
          "expired usage frees a new background turn within the reduced budget")
    budget.finish("观察到三"); await settle()
    check(budgetLoop.snapshot.backgroundTurnsInLastHour == 1, "the rolling hour reflects only fresh background usage")

    // ---- 0 只关闭自主后台，人类优先不受影响。
    budgetLoop.setBackgroundTurnsPerHour(0)
    check(budgetLoop.snapshot.backgroundTurnsPerHour == 0, "zero runtime budget is allowed")
    budgetLoop.receiveEvent(.init(id: "turn-d", kind: "world.d", summary: "变化四"))
    budgetClock.advance(10); budgetLoop.tick(); await settle()
    check(budget.inputs.count == 3, "zero background budget disables autonomous model turns")
    budgetLoop.receiveUserMessage("人来说一句"); await settle()
    check(budget.inputs.count == 4 && !budget.inputs.last!.isBackground
          && budget.inputs.last!.userMessages == ["人来说一句"],
          "zero background budget never blocks human priority")
    budget.finish("回应人类"); await settle()

    // ---- 运行时预算钳制在 0...6。
    budgetLoop.setBackgroundTurnsPerHour(-3)
    check(budgetLoop.snapshot.backgroundTurnsPerHour == 0, "negative runtime budget clamps to zero")
    budgetLoop.setBackgroundTurnsPerHour(99)
    check(budgetLoop.snapshot.backgroundTurnsPerHour == 6, "runtime budget never exceeds six background turns per hour")
    budgetLoop.stop()
}
@main struct Tests {
    @MainActor static func main() async throws {
        residentIntentFixtureDaemon = try ResidentIntentDaemonFixture()
        defer { residentIntentFixtureDaemon?.stop(); residentIntentFixtureDaemon = nil }
        let queuedPictures = Runner()
        var returnedDrafts: [String] = []
        var returnedImages: [URL] = []
        var stoppedBeforeReturning = true
        var ordinaryFailureCallbacks = 0
        let queuedPictureLoop = await fixtureResidentLoop(run: { try await queuedPictures.run($0) })
        queuedPictureLoop.setBackgroundEnabled(true)
        queuedPictureLoop.tick(); await settle()
        let queuedImageA = URL(fileURLWithPath: "/fixture/first-image.png")
        let queuedImageB = URL(fileURLWithPath: "/fixture/second-image.png")
        queuedPictureLoop.receiveUserMessage("第一张图片", imageURLs: [queuedImageA], onUndelivered: {
            returnedDrafts.append("第一张图片"); returnedImages.append(queuedImageA)
            stoppedBeforeReturning = stoppedBeforeReturning && queuedPictureLoop.snapshot.isStopped && !queuedPictureLoop.snapshot.isRunning
        }, onFailure: { _ in ordinaryFailureCallbacks += 1 })
        queuedPictureLoop.receiveUserMessage("", imageURLs: [queuedImageB], onUndelivered: {
            returnedDrafts.append("仅图片"); returnedImages.append(queuedImageB)
        })
        queuedPictureLoop.receiveUserMessage("最后的补充", onUndelivered: { returnedDrafts.append("最后的补充") })
        await settle()
        check(queuedPictures.inputs.count == 1 && queuedPictureLoop.snapshot.isRunning && queuedPictureLoop.snapshot.pendingUserMessages.count == 3,
              "queued images and ordered follow-ups do not cancel an authorized background transaction")
        queuedPictureLoop.stop()
        check(returnedDrafts == ["最后的补充", "仅图片", "第一张图片"] && returnedImages == [queuedImageB, queuedImageA],
              "stop returns each unsent text/image submission in reverse order so prepending restores the original draft order")
        check(stoppedBeforeReturning && ordinaryFailureCallbacks == 0,
              "undelivered drafts use their own callback after stop completes, never the failure path")
        queuedPictureLoop.stop(); queuedPictures.finish("过期后台回复"); await settle()
        queuedPictureLoop.tick(); await settle()
        check(returnedDrafts.count == 3 && queuedPictures.inputs.count == 1 && queuedPictureLoop.snapshot.pendingUserMessages.isEmpty,
              "returned drafts are not automatically resent and repeated stop cannot return them twice")

        for delivery in [ResidentSteeringDelivery.notDelivered, .delivered, .unknown] {
            let steeringDrafts = Runner(); steeringDrafts.delivery = delivery
            var returned: [String] = []
            let steeringDraftLoop = await fixtureResidentLoop(run: { try await steeringDrafts.run($0) }, steer: { await steeringDrafts.steer($0) })
            steeringDraftLoop.receiveUserMessage("已经开始的主消息", onUndelivered: { returned.append("active") }); await settle()
            steeringDraftLoop.receiveUserMessage("文本补充", onUndelivered: { returned.append("text") }); await settle()
            steeringDraftLoop.receiveUserMessage("图片补充", imageURLs: [queuedImageA], onUndelivered: { returned.append("image") })
            steeringDraftLoop.stop()
            check(returned == (delivery == .notDelivered ? ["image", "text"] : ["image"]),
                  "stop returns only confirmed-undelivered queued submissions for steering outcome \(delivery)")
            if delivery == .unknown {
                check(steeringDraftLoop.snapshot.unconfirmedUserMessages == ["文本补充"],
                      "unknown delivery stays an uncertainty record rather than a resubmittable draft")
            }
            steeringDrafts.finish("已停止的结果"); await settle()
        }

        let pendingSteering = Runner(); pendingSteering.holdSteering = true
        var pendingReturned: [String] = []
        let pendingSteeringLoop = await fixtureResidentLoop(run: { try await pendingSteering.run($0) }, steer: { await pendingSteering.steer($0) })
        pendingSteeringLoop.receiveUserMessage("主消息"); await settle()
        pendingSteeringLoop.receiveUserMessage("写入中补充", onUndelivered: { pendingReturned.append("in-flight") }); await settle()
        pendingSteeringLoop.receiveUserMessage("排队图片", imageURLs: [queuedImageB], onUndelivered: { pendingReturned.append("image") })
        pendingSteeringLoop.stop()
        check(pendingReturned == ["image"] && pendingSteeringLoop.snapshot.unconfirmedUserMessages == ["写入中补充"],
              "stop treats in-flight steering as unknown while returning later unsent pictures")
        pendingSteering.steeringContinuations.removeFirst().resume(returning: .notDelivered)
        pendingSteering.finish("过期结果"); await settle()
        check(pendingReturned == ["image"], "late steering results cannot reclassify a stopped unknown message as an unsent draft")

        let oldScopeDrafts = Runner()
        var oldScopeReturns = 0
        let oldScopeDraftLoop = await fixtureResidentLoop(run: { try await oldScopeDrafts.run($0) })
        oldScopeDraftLoop.receiveUserMessage("旧空间主消息"); await settle()
        oldScopeDraftLoop.receiveUserMessage("旧空间图片", imageURLs: [queuedImageA], onUndelivered: { oldScopeReturns += 1 })
        oldScopeDraftLoop.invalidate()
        oldScopeDrafts.finish("旧空间过期结果"); await settle()
        check(oldScopeReturns == 0 && oldScopeDraftLoop.snapshot.pendingUserMessages.isEmpty,
              "invalidation clears old-scope queues without restoring their drafts into the new scope")

        let callbackScope = Runner()
        var callbackOrder: [String] = []
        let callbackScopeLoop = await fixtureResidentLoop(run: { try await callbackScope.run($0) })
        callbackScopeLoop.receiveUserMessage("主消息"); await settle()
        callbackScopeLoop.receiveUserMessage("较早图片", imageURLs: [queuedImageA], onUndelivered: { callbackOrder.append("older") })
        callbackScopeLoop.receiveUserMessage("最后图片", imageURLs: [queuedImageB], onUndelivered: {
            callbackOrder.append("newest"); callbackScopeLoop.invalidate()
        })
        callbackScopeLoop.stop()
        callbackScope.finish("过期结果"); await settle()
        check(callbackOrder == ["newest"], "scope invalidation during draft restoration prevents remaining old-scope callbacks")

        let progressRunner = Runner()
        let progressLoop = await fixtureResidentLoop(run: { try await progressRunner.run($0) },
            onReply: { progressRunner.replies.append($0) })
        progressLoop.receiveUserMessage("看看空间"); await settle()
        let oldRun = progressRunner.inputs[0].runID
        check(progressLoop.snapshot.progress == "等待居民回应…", "new turn exposes truthful waiting state")
        progressLoop.recordToolProgress(runID: oldRun, toolName: "inspect_world", phase: .started)
        check(progressLoop.snapshot.progress == "正在看看现在的空间…", "actual tool start is visible in plain language")
        progressLoop.recordToolProgress(runID: oldRun, toolName: "move_to", phase: .returned)
        check(progressLoop.snapshot.progress == "移动请求已返回，等待居民回应…", "async acceptance never claims movement completed")
        // Regression: tools outside the original short allowlist must still read as human
        // language instead of the mechanical default "正在调用工具…".
        for (tool, expected) in [
            ("read_radio_state", "正在看看电台状态…"),
            ("previous_track", "正在切回上一首…"),
            ("capture_space_photo", "正在看一眼当前画面…"),
            ("submit_wish_generation", "正在开始生成愿望…"),
            ("read_wish_generation", "正在看看生成进度…"),
            ("hold_prop", "正在拿起物件…"),
        ] {
            progressLoop.recordToolProgress(runID: oldRun, toolName: tool, phase: .started)
            check(progressLoop.snapshot.progress == expected,
                  "\(tool) start is narrated in plain language")
            check(progressLoop.snapshot.progress?.contains("调用工具") == false,
                  "\(tool) never falls back to mechanical narration")
        }
        progressLoop.recordToolProgress(runID: oldRun, toolName: "submit_wish_generation", phase: .returned)
        check(progressLoop.snapshot.progress == "生成请求已返回，等待居民回应…", "wish request return stays non-committal")
        check(progressRunner.replies.isEmpty, "progress does not become a reply or speech")
        progressLoop.recordToolProgress(runID: oldRun, toolName: "untrusted_raw_name", phase: .failed)
        check(progressLoop.snapshot.progress == "这次操作失败，等待居民回应…", "unknown names cannot leak into displayed progress")
        progressLoop.receiveUserMessage("还有一件事"); await settle()
        check(progressLoop.snapshot.pendingUserMessages.count == 1, "undelivered follow-up is visibly countable")
        progressLoop.stop()
        check(progressLoop.snapshot.progress == nil && progressLoop.snapshot.pendingUserMessages.isEmpty, "stop clears progress and queue")
        // The cancellation request is not a native completion receipt. Release
        // the actual old invocation before Rust may admit the new serial run.
        progressRunner.finish("旧回复"); await settle()
        progressLoop.receiveUserMessage("新问题"); await settle()
        progressLoop.recordToolProgress(runID: oldRun, toolName: "inspect_world", phase: .returned)
        check(progressLoop.snapshot.progress == "等待居民回应…", "late prior-run update cannot overwrite new turn")
        progressRunner.finish("新回复"); await settle()
        check(progressLoop.snapshot.progress == nil && progressRunner.replies == ["新回复"], "completion clears progress while preserving only current final reply")
        progressLoop.receiveUserMessage("失败测试"); await settle()
        await progressRunner.fail(); await settle()
        check(progressLoop.snapshot.progress == nil, "failure clears progress")
        progressLoop.receiveUserMessage("取消测试"); await settle()
        await progressRunner.fail(CancellationError()); await settle()
        check(progressLoop.snapshot.progress == nil, "provider cancellation clears progress")

        let pictures = Runner()
        let pictureLoop = await fixtureResidentLoop(run: { try await pictures.run($0) },
            steer: { await pictures.steer($0) })
        let firstImage = URL(fileURLWithPath: "/test/selected-image.png")
        let secondImage = URL(fileURLWithPath: "/test/pasted-image.png")
        pictureLoop.receiveUserMessage("", imageURLs: [firstImage]); await settle()
        check(pictures.inputs.count == 1 && pictures.inputs[0].imageURLs == [firstImage], "image-only human message starts a turn with image input")
        pictureLoop.receiveUserMessage("按这张图制作", imageURLs: [secondImage]); await settle()
        pictureLoop.receiveUserMessage("高度四十厘米"); await settle()
        check(pictures.steered.isEmpty, "image guidance stays queued, and later text cannot overtake it through text-only steering")
        pictures.finish(); await settle()

        let recovery = Runner()
        var recovered: [String] = []
        let recoveryLoop = await fixtureResidentLoop(run: { try await recovery.run($0) }, steer: { await recovery.steer($0) })
        recoveryLoop.receiveUserMessage("第一张", imageURLs: [firstImage], onFailure: { recovered.append("first:" + $0) })
        await settle()
        recoveryLoop.receiveUserMessage("第二张", imageURLs: [secondImage], onFailure: { recovered.append("second:" + $0) })
        recoveryLoop.receiveUserMessage("补充尺寸", onFailure: { recovered.append("size:" + $0) })
        await recovery.fail(); await settle()
        check(recovered.count == 1 && recovered[0].hasPrefix("first:"), "real failed run restores only its original submission")
        check(recovery.inputs.count == 2 && recovery.inputs[1].imageURLs == [secondImage], "queued picture remains in its own subsequent turn")
        await recovery.fail(); await settle()
        check(recovered.count == 3 && recovered[1].hasPrefix("size:") && recovered[2].hasPrefix("second:"), "failed batch restores each message once, newest first for prepending to original draft order")
        recoveryLoop.tick(); await settle()
        check(recovered.count == 3 && recovery.inputs.count == 2, "failed pictures are not automatically resent or restored twice")
        recoveryLoop.receiveUserMessage("被取消", imageURLs: [firstImage], onFailure: { recovered.append("cancelled:" + $0) })
        await settle(); await recovery.fail(CancellationError()); await settle()
        check(recovered.count == 3, "provider cancellation does not restore a discarded submission")
        recoveryLoop.receiveUserMessage("已停止", imageURLs: [firstImage], onFailure: { recovered.append("stopped:" + $0) })
        await settle()
        if recovery.continuations.isEmpty {
            print("RECOVERY NEXT: inputs=\(recovery.inputs.count) running=\(recoveryLoop.snapshot.isRunning) pending=\(recoveryLoop.snapshot.pendingUserMessages) failure=\(String(describing: recoveryLoop.snapshot.lastFailure))")
            fflush(nil)
        }
        recoveryLoop.stop(); await recovery.fail(); await settle()
        check(recovered.count == 3, "late failure after stop cannot restore drafts")
        recoveryLoop.receiveUserMessage("旧世界", imageURLs: [firstImage], onFailure: { recovered.append("old-world:" + $0) })
        await settle(); recoveryLoop.invalidate(); await recovery.fail(); await settle()
        check(recovered.count == 3, "invalidated world failure cannot restore into another world")

        let changingProvider = Runner()
        var providerSupportsPictures = true
        var providerRecovered = 0
        let changingProviderLoop = await fixtureResidentLoop(run: { input in
            if !input.imageURLs.isEmpty && !providerSupportsPictures { throw PictureFailure.providerUnsupported }
            return try await changingProvider.run(input)
        })
        changingProviderLoop.receiveUserMessage("正在做事"); await settle()
        changingProviderLoop.receiveUserMessage("排队图片", imageURLs: [firstImage], onFailure: { _ in providerRecovered += 1 })
        providerSupportsPictures = false
        changingProvider.finish(); await settle()
        check(providerRecovered == 1 && !changingProviderLoop.snapshot.isRunning, "picture queued before unsupported provider switch is restored when actual run rejects it")
        check(pictures.inputs.count == 2 && pictures.inputs[1].imageURLs == [secondImage], "queued image reaches the next turn exactly once")
        check(pictures.inputs[1].userMessages == ["按这张图制作", "高度四十厘米"], "queued image description keeps ordered human guidance")
        pictures.finish(); await settle()
        pictureLoop.receiveUserMessage("谢谢"); await settle()
        check(pictures.inputs[2].imageURLs.isEmpty, "later unrelated turn does not replay previous attachments")
        pictureLoop.receiveUserMessage("不要发这张", imageURLs: [firstImage])
        pictureLoop.stop(); pictures.finish(); await settle()
        pictureLoop.receiveUserMessage("你好"); await settle()
        check(pictures.inputs.last?.imageURLs.isEmpty == true, "stop clears queued images and cannot leak them into a new turn")
        pictures.finish(); await settle()

        let clock = Clock(), runner = Runner()
        let continuationClock = Clock(), continued = Runner()
        let continuationLoop = await fixtureResidentLoop(now: { continuationClock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 1, maximumQueuedEvents: 3),
            run: { try await continued.run($0) })
        continuationLoop.receiveEvent(.init(id: "ordinary", kind: "world.weather", summary: "天气变化"))
        continuationLoop.tick(); await settle()
        check(continued.inputs.isEmpty, "ordinary environment events do not wake a default-off resident")
        let ready = ResidentAgentLoop.Event(id: "wish-ready-1", kind: "wish.ready.1", summary: "正式产物可领取")
        continuationLoop.receiveContinuationEvent(ready)
        continuationLoop.tick(); await settle()
        check(continued.inputs.count == 1 && continued.inputs[0].isBackground, "host completion permits one bounded continuation while ambient autonomy remains off")
        check(!continuationLoop.snapshot.backgroundEnabled && continued.inputs[0].imageURLs.isEmpty,
              "delegated continuation grants neither ambient autonomy nor a new image generation request")
        continuationLoop.receiveContinuationEvent(ready)
        continued.finish(); await settle()
        continuationClock.advance(20); continuationLoop.tick(); await settle()
        check(continued.inputs.count == 1, "duplicate completion event cannot create another continuation")
        continuationLoop.receiveContinuationEvent(.init(id: "wish-ready-2", kind: "wish.ready.2", summary: "第二件待领"))
        continuationLoop.tick(); await settle()
        check(continued.inputs.count == 1, "continuation obeys the same hourly model budget")
        continuationClock.advance(3_600); continuationLoop.tick(); await settle()
        check(continued.inputs.count == 2 && continued.inputs[1].events.contains { $0.id == "wish-ready-2" },
              "budget-exhausted completion is retained until the budget allows it")
        continued.finish(); await settle()
        continuationClock.advance(3_600)
        continuationLoop.receiveContinuationEvent(.init(id: "wish-ready-3", kind: "wish.ready.3", summary: "用户停止时待领"))
        continuationLoop.stop(); continuationLoop.tick(); await settle()
        check(continued.inputs.count == 2, "completion never bypasses explicit stop")
        continuationLoop.receiveUserMessage("你好"); await settle()
        continued.finish(); await settle()
        continuationLoop.receiveContinuationEvent(.init(id: "wish-ready-4", kind: "wish.ready.4", summary: "仍暂停"))
        continuationClock.advance(20); continuationLoop.tick(); await settle()
        check(continued.inputs.count == 3 && continuationLoop.snapshot.intentPausedByUser,
              "ordinary greeting does not permit a later completion to bypass paused intent")
        continuationLoop.invalidate()
        continuationLoop.receiveContinuationEvent(.init(id: "wish-ready-5", kind: "wish.ready.5", summary: "旧世界"))
        continuationClock.advance(3_600); continuationLoop.tick(); await settle()
        check(continued.inputs.count == 3, "old world completion cannot wake an invalidated loop")

        let retryClock = Clock(), retry = Runner()
        let retryLoop = await fixtureResidentLoop(now: { retryClock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 2),
            run: { try await retry.run($0) })
        let retryEvent = ResidentAgentLoop.Event(id: "wish-failed-delivery", kind: "wish.failed", summary: "生成失败，解释结果即可")
        retryLoop.receiveContinuationEvent(retryEvent); retryLoop.tick(); await settle()
        retryLoop.receiveContinuationEvent(retryEvent)
        await retry.fail(); await settle()
        retryLoop.receiveContinuationEvent(retryEvent); retryLoop.tick(); await settle()
        check(retry.inputs.count == 1, "failed continuation cannot immediately consume another model call")
        retryClock.advance(9); retryLoop.receiveContinuationEvent(retryEvent); retryLoop.tick(); await settle()
        check(retry.inputs.count == 1, "host redelivery obeys the minimum wake interval")
        retryClock.advance(1); retryLoop.receiveContinuationEvent(retryEvent); retryLoop.tick(); await settle()
        check(retry.inputs.count == 2 && retry.inputs.last?.events == [retryEvent], "failed continuation is deliverable again in the same process after the wake interval")
        if !retry.continuations.isEmpty { retry.finish(); await settle() }
        retryLoop.receiveContinuationEvent(retryEvent)
        retryClock.advance(20); retryLoop.tick(); await settle()
        check(retry.inputs.count == 2, "successful continuation is not redelivered")
        let nextEvent = ResidentAgentLoop.Event(id: "wish-next-delivery", kind: "wish.cancelled", summary: "任务已取消")
        retryLoop.receiveContinuationEvent(nextEvent); retryLoop.tick(); await settle()
        check(retry.inputs.count == 2, "failed attempts count against the hourly continuation budget")
        retryClock.advance(3600); retryLoop.tick(); await settle()
        check(retry.inputs.count == 3 && retry.inputs.last?.events == [nextEvent], "pending continuation resumes when the hourly budget renews")
        if !retry.continuations.isEmpty { retry.finish(); await settle() }
        check(retry.inputs.first?.promptText.contains("failed/cancelled/interrupted") == true,
              "failed or cancelled async outcomes explicitly grant no regeneration authority")

        let toggle = Runner()
        var toggleCancellations = 0
        let toggleLoop = await fixtureResidentLoop(run: { try await toggle.run($0) },
            onReply: { toggle.replies.append($0) }, onCancel: { toggleCancellations += 1 })
        toggleLoop.setBackgroundEnabled(true)
        toggleLoop.receiveContinuationEvent(.init(id: "delegated-ready", kind: "wish.outputReady", summary: "已经完成"))
        toggleLoop.tick(); await settle()
        toggleLoop.setBackgroundEnabled(false)
        check(toggleLoop.snapshot.isRunning && toggleCancellations == 0,
              "disabling ambient autonomy cannot cancel an authorized async outcome continuation")
        toggle.finish("产物已经就绪"); await settle()
        check(toggle.replies == ["产物已经就绪"], "authorized result reply still arrives after ambient autonomy is disabled")

        let emptyClock = Clock(), emptyContinuation = Runner()
        let emptyContinuationLoop = await fixtureResidentLoop(now: { emptyClock.date },
            run: { try await emptyContinuation.run($0) })
        let emptyEvent = ResidentAgentLoop.Event(id: "wish-empty-delivery", kind: "wish.outputReady", summary: "待报告")
        emptyContinuationLoop.receiveContinuationEvent(emptyEvent); emptyContinuationLoop.tick(); await settle()
        emptyContinuation.finish("  "); await settle()
        emptyClock.advance(60)
        emptyContinuationLoop.receiveContinuationEvent(emptyEvent); emptyContinuationLoop.tick(); await settle()
        check(emptyContinuation.inputs.count == 2 && emptyContinuation.inputs.last?.previousTurnFailed == true,
              "empty reply without explicit silent completion leaves the event retryable with failure context")
        if emptyContinuationLoop.snapshot.isRunning {
            let runID = emptyContinuation.inputs.last!.runID
            try await emptyContinuationLoop.updateIntent(summary: "已记录现有产物，等待用户", status: .waitingEvent, wakeAfterSeconds: 60, runID: runID)
            check(emptyContinuationLoop.allowsSilentCompletion(runID: runID), "host can use the same run-scoped silent completion criterion before durable acknowledgement")
            emptyContinuation.finish(""); await settle()
        }
        emptyClock.advance(60)
        emptyContinuationLoop.receiveContinuationEvent(emptyEvent); emptyContinuationLoop.tick(); await settle()
        check(emptyContinuation.inputs.count == 2, "explicit silent success consumes a continuation exactly once")

        let cancelClock = Clock(), cancelledContinuation = Runner()
        let cancelledContinuationLoop = await fixtureResidentLoop(now: { cancelClock.date },
            configuration: .init(minimumWakeInterval: 10), run: { try await cancelledContinuation.run($0) })
        let cancelledEvent = ResidentAgentLoop.Event(id: "wish-provider-cancel", kind: "wish.interrupted", summary: "已有任务被中断，只解释终态")
        cancelledContinuationLoop.receiveContinuationEvent(cancelledEvent); cancelledContinuationLoop.tick(); await settle()
        await cancelledContinuation.fail(CancellationError()); await settle()
        cancelClock.advance(10)
        cancelledContinuationLoop.receiveContinuationEvent(cancelledEvent); cancelledContinuationLoop.tick(); await settle()
        check(cancelledContinuation.inputs.count == 2, "provider cancellation alone leaves an unacknowledged outcome retryable")
        cancelledContinuationLoop.stop()
        cancelledContinuationLoop.receiveContinuationEvent(cancelledEvent)
        cancelClock.advance(3600); cancelledContinuationLoop.tick(); await settle()
        check(cancelledContinuation.inputs.count == 2 && cancelledContinuationLoop.snapshot.intentPausedByUser,
              "explicit user stop overrides retry eligibility even after budget renewal")
        if !cancelledContinuation.continuations.isEmpty { cancelledContinuation.finish("stale delivery"); await settle() }
        cancelledContinuationLoop.receiveUserMessage("继续处理这个结果"); await settle()
        check(cancelledContinuation.inputs.count == 3 && cancelledContinuation.inputs.last?.events == [cancelledEvent],
              "new human guidance can recover the outcome interrupted by explicit stop")
        try await cancelledContinuationLoop.updateIntent(summary: "已解释既有结果", status: .completed, wakeAfterSeconds: nil, resumePausedIntent: true)
        cancelledContinuation.finish(); await settle()
        let invalidEvent = ResidentAgentLoop.Event(id: "wish-invalidated", kind: "wish.failed", summary: "旧空间任务终态")
        cancelClock.advance(10)
        cancelledContinuationLoop.receiveContinuationEvent(invalidEvent); cancelledContinuationLoop.tick(); await settle()
        cancelledContinuationLoop.invalidate()
        if !cancelledContinuation.continuations.isEmpty { await cancelledContinuation.fail(); await settle() }
        cancelledContinuationLoop.receiveContinuationEvent(invalidEvent)
        cancelClock.advance(3600); cancelledContinuationLoop.tick(); await settle()
        check(cancelledContinuation.inputs.count == 4, "invalidation rejects outcome redelivery and ignores late model failure from the old world")

        let waiting = Runner(), waitingClock = Clock()
        let waitingLoop = await fixtureResidentLoop(now: { waitingClock.date }, run: { try await waiting.run($0) })
        waitingLoop.receiveUserMessage("等我决定"); await settle()
        try await waitingLoop.updateIntent(summary: "等用户确认", status: .waitingUser, wakeAfterSeconds: nil)
        waiting.finish(); await settle()
        waitingClock.advance(61)
        waitingLoop.setBackgroundEnabled(true)
        waitingLoop.receiveEvent(.init(id: "ordinary-while-waiting", kind: "world.weather", summary: "普通空间变化"))
        waitingLoop.tick(); await settle()
        check(waiting.inputs.count == 1, "ordinary background observations remain blocked while waiting for a user decision")
        waitingLoop.setBackgroundEnabled(false)
        waitingLoop.receiveContinuationEvent(.init(id: "ready-but-wait", kind: "wish.ready", summary: "物件已就绪"))
        waitingLoop.tick(); await settle()
        check(waiting.inputs.count == 2 && waiting.inputs.last?.events.contains { $0.id == "ready-but-wait" } == true,
              "authorized completion can be reported while the resident waits for a separate user decision")
        if !waiting.continuations.isEmpty { waiting.finish(); await settle() }

        let loop = await fixtureResidentLoop(now: { clock.date },
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
        try await loop.updateIntent(summary: "找舒缓歌单", status: .waitingUser, wakeAfterSeconds: nil)
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
        try await loop.updateIntent(summary: "了解房间", status: .waitingEvent, wakeAfterSeconds: 10)
        runner.finish("")
        await settle()
        loop.tick(); await settle()
        check(runner.inputs.count == 3, "wake respects requested time")
        clock.advance(10); loop.tick(); await settle()
        check(runner.inputs.count == 4 && runner.inputs[3].isBackground, "scheduled wake invokes same loop")
        try await loop.updateIntent(summary: "继续观察", status: .active, wakeAfterSeconds: nil)
        runner.finish(""); await settle()
        loop.tick(); await settle()
        check(runner.inputs.count == 4, "no tight autonomous retry loop")
        clock.advance(10); loop.tick(); await settle()
        check(runner.inputs.count == 5, "active intent resumes on bounded tick")
        try await loop.updateIntent(summary: "继续观察", status: .active, wakeAfterSeconds: nil)
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
        let eventLoop = await fixtureResidentLoop(now: { clock.date },
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
            try await eventLoop.updateIntent(summary: String(repeating: "a", count: 2001), status: .active, wakeAfterSeconds: nil)
            check(false, "oversized intent rejected")
        } catch { check(true, "oversized intent rejected") }
        do {
            try await eventLoop.updateIntent(summary: "plan", status: .waitingEvent, wakeAfterSeconds: .nan)
            check(false, "nonfinite wake rejected")
        } catch { check(true, "nonfinite wake rejected") }
        events.finish(""); await settle()
        check(eventLoop.snapshot.lastFailure != nil, "uncontrolled empty result is an error, not silent success")

        let racing = Runner()
        racing.holdSteering = true
        let raceLoop = await fixtureResidentLoop(run: { try await racing.run($0) },
            steer: { await racing.steer($0) }, onReply: { racing.replies.append($0) })
        raceLoop.receiveUserMessage("读一本书"); await settle()
        let lease = ResidentLoopTools(loop: raceLoop, runID: racing.inputs[0].runID)
        check(!(await lease.handle(name: "read_resident_state", argumentsJSON: Data("{}".utf8))).isError, "current turn can inspect intent state")
        let control = await lease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"等环境变化","status":"waiting_event"}"#.utf8))
        let controlJSON = try JSONSerialization.jsonObject(with: control.data) as! [String: Any]
        check(!control.isError && controlJSON["intent_is_verified_world_fact"] as? Bool == false, "plan control never claims verified world success")
        check(lease.allowsSilentCompletion, "successful explicit control enables silence for this run")
        check(await lease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"bad","status":"active","wake_after_seconds":true}"#.utf8)).isError, "tool rejects boolean as numeric wake")
        raceLoop.receiveUserMessage("窗外是什么"); await settle()
        racing.finish("first answer"); await settle()
        check(racing.inputs.count == 1 && raceLoop.snapshot.isRunning, "completion waits for outstanding steering acknowledgement")
        racing.steeringContinuations.removeFirst().resume(returning: .delivered); await settle()
        check(racing.inputs.count == 1 && raceLoop.snapshot.pendingUserMessages.isEmpty, "acknowledged guidance is not duplicated when run completed first")
        check(await lease.handle(name: "read_resident_state", argumentsJSON: Data("{}".utf8)).isError && !lease.allowsSilentCompletion, "ended turn lease cannot read or authorize later silence")
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
        let immediateLoop = await fixtureResidentLoop(run: { try await immediate.run($0) })
        immediateLoop.receiveUserMessage("马上出发")
        immediateLoop.stop()
        await settle()
        check(immediate.inputs.isEmpty, "stop before scheduled task starts never invokes provider")
        check(immediateLoop.snapshot.modelTurnsStarted == 0 && immediateLoop.snapshot.cancelledModelTurns == 0,
              "stop before invocation does not count a model start or cancellation")
        if !immediate.continuations.isEmpty { immediate.finish(); await settle() }

        // ---- 后台轮次的开始与滚动用量同样只在真实调用时计数：调度后、调用前
        // 停止的调度不得留下开始、取消或一小时用量。
        let immediateBackground = Runner(), immediateBackgroundClock = Clock()
        let immediateBackgroundLoop = await fixtureResidentLoop(now: { immediateBackgroundClock.date },
            run: { try await immediateBackground.run($0) })
        immediateBackgroundLoop.setBackgroundEnabled(true)
        immediateBackgroundLoop.tick()
        immediateBackgroundLoop.stop()
        await settle()
        check(immediateBackground.inputs.isEmpty
              && immediateBackgroundLoop.snapshot.modelTurnsStarted == 0
              && immediateBackgroundLoop.snapshot.backgroundModelTurnsStarted == 0
              && immediateBackgroundLoop.snapshot.cancelledModelTurns == 0
              && immediateBackgroundLoop.snapshot.backgroundTurnsInLastHour == 0,
              "stop before a background invocation consumes no start, cancellation or hourly budget")

        let stoppedQueue = Runner()
        let stoppedQueueLoop = await fixtureResidentLoop(run: { try await stoppedQueue.run($0) })
        stoppedQueueLoop.receiveUserMessage("第一件事"); await settle()
        stoppedQueueLoop.receiveUserMessage("旧排队操作"); await settle()
        stoppedQueueLoop.stop()
        stoppedQueue.finish(); await settle()
        stoppedQueueLoop.receiveUserMessage("新的方向"); await settle()
        check(stoppedQueue.inputs[1].userMessages == ["新的方向"], "stop drops automatic replay of old queued actions")
        check(stoppedQueue.inputs[1].lastTurnInterrupted && stoppedQueue.inputs[1].lastTurnUserMessages == ["第一件事", "旧排队操作"], "interrupted messages remain context without becoming fresh instructions")
        stoppedQueue.finish(); await settle()
        let immediateSteer = Runner()
        let immediateSteerLoop = await fixtureResidentLoop(run: { try await immediateSteer.run($0) },
            steer: { await immediateSteer.steer($0) })
        immediateSteerLoop.receiveUserMessage("观察房间"); await settle()
        immediateSteerLoop.receiveUserMessage("旧方向")
        immediateSteerLoop.stop()
        await settle()
        check(immediateSteer.steered.isEmpty, "stop before queued steer starts never writes to provider")
        immediateSteer.finish(); await settle()

        let background = Runner(), backgroundClock = Clock()
        var backgroundChanges = 0, backgroundCancels = 0
        let backgroundLoop = await fixtureResidentLoop(now: { backgroundClock.date },
            run: { try await background.run($0) }, steer: { await background.steer($0) },
            onReply: { background.replies.append($0) },
            onChange: { backgroundChanges += 1 }, onCancel: { backgroundCancels += 1 })
        let restoredBackgroundChanges = backgroundChanges
        backgroundLoop.setBackgroundEnabled(false)
        check(backgroundChanges == restoredBackgroundChanges, "unchanged background permission does not publish state")
        backgroundLoop.setBackgroundEnabled(true)
        backgroundLoop.tick(); await settle()
        check(background.inputs.count == 1 && background.inputs[0].isBackground, "enabled idle tick starts a background turn")
        try await backgroundLoop.updateIntent(summary: "日常观察", status: .active, wakeAfterSeconds: nil)
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
        let orderedLoop = await fixtureResidentLoop(run: { try await ordered.run($0) },
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
        let pausedLoop = await fixtureResidentLoop(now: { pausedClock.date }, run: { try await paused.run($0) }, steer: { await paused.steer($0) })
        pausedLoop.receiveUserMessage("去窗边看看"); await settle()
        try await pausedLoop.updateIntent(summary: "去窗边观察", status: .active, wakeAfterSeconds: nil)
        paused.finish("正在去窗边"); await settle()
        pausedLoop.stop()
        pausedLoop.receiveUserMessage("你好"); await settle()
        check(paused.inputs[1].promptText.contains(#""intentPausedByUser":true"#), "stop after completed turn marks existing intent paused in later input")
        let pausedLease = ResidentLoopTools(loop: pausedLoop, runID: paused.inputs[1].runID)
        let accidentalResume = await pausedLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"继续去窗边","status":"active"}"#.utf8))
        check(accidentalResume.isError, "ordinary intent update cannot silently resume paused work")
        paused.finish("你好"); await settle()
        pausedLoop.setBackgroundEnabled(true)
        pausedClock.advance(70); pausedLoop.tick(); await settle()
        check(paused.inputs.count == 2, "greeting does not let old intent restart autonomously")
        if !paused.continuations.isEmpty { paused.finish(); await settle() }
        pausedLoop.receiveUserMessage("继续刚才观察窗外"); await settle()
        let resumeLease = ResidentLoopTools(loop: pausedLoop, runID: paused.inputs.last!.runID)
        let explicitResume = await resumeLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"检查位置后继续观察","status":"active","resume_paused_intent":true}"#.utf8))
        check(!explicitResume.isError, "fresh human guidance may explicitly resume or replace paused intent")
        paused.finish("继续"); await settle()
        pausedClock.advance(70); pausedLoop.tick(); await settle()
        check(paused.inputs.last!.isBackground, "explicit resumption restores autonomous continuation")
        let backgroundLease = ResidentLoopTools(loop: pausedLoop, runID: paused.inputs.last!.runID)
        check(await backgroundLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"自动恢复","status":"active","resume_paused_intent":true}"#.utf8)).isError, "autonomous turn cannot assert human-authorized resumption")
        paused.delivery = .delivered
        pausedLoop.receiveUserMessage("换个新目标"); await settle()
        check(!(await backgroundLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"按新指导换目标","status":"active","resume_paused_intent":true}"#.utf8))).isError, "successfully delivered human steering authorizes explicit intent replacement")
        check(await backgroundLease.handle(name: "update_resident_intent", argumentsJSON: Data(#"{"summary":"invalid","status":"active","resume_paused_intent":1}"#.utf8)).isError, "intent resume flag rejects numeric booleans")
        pausedLoop.stop()
        if !paused.continuations.isEmpty { paused.finish(); await settle() }

        let idleClock = Clock(), idle = Runner()
        let idleLoop = await fixtureResidentLoop(now: { idleClock.date },
            run: { try await idle.run($0) })
        idleLoop.setBackgroundEnabled(true)
        idleLoop.tick(); await settle()
        try await idleLoop.updateIntent(summary: "已经观察完房间", status: .completed, wakeAfterSeconds: nil)
        idleClock.advance(180)
        idle.finish(""); await settle()
        idleClock.advance(599); idleLoop.tick(); await settle()
        check(idle.inputs.count == 1, "completed intent rests ten minutes from turn finish, not start")
        idleClock.advance(1); idleLoop.tick(); await settle()
        check(idle.inputs.count == 2, "completed resident wakes for a low-frequency new choice without external events")
        if !idle.continuations.isEmpty {
            try await idleLoop.updateIntent(summary: "等用户选择", status: .waitingUser, wakeAfterSeconds: nil)
            idle.finish(""); await settle()
        }
        idleClock.advance(3600); idleLoop.tick(); await settle()
        check(idle.inputs.count == 2, "idle review never overrides waiting for human")
        idleLoop.receiveUserMessage("先歇着，等条件变化"); await settle()
        try await idleLoop.updateIntent(summary: "等待环境", status: .waitingEvent, wakeAfterSeconds: nil)
        idle.finish(""); await settle()
        idleClock.advance(3600); idleLoop.tick(); await settle()
        check(idle.inputs.count == 3, "idle review never overrides deliberate event wait")
        idleLoop.receiveEvent(.init(id: "lamp-on", kind: "light", summary: "灯已打开"))
        idleLoop.tick(); await settle()
        check(idle.inputs.count == 4, "real event wakes deliberate wait")
        try await idleLoop.updateIntent(summary: "看完灯了", status: .completed, wakeAfterSeconds: nil)
        idle.finish(""); await settle()
        idleLoop.stop()
        idleClock.advance(3600); idleLoop.tick(); await settle()
        check(idle.inputs.count == 4, "explicit stop blocks idle review even after completed intent")
        idleLoop.receiveUserMessage("你好"); await settle()
        idle.finish("你好"); await settle()
        idleClock.advance(3600); idleLoop.tick(); await settle()
        check(idle.inputs.count == 5, "ordinary greeting cannot undo stop after a completed intent")
        if !idle.continuations.isEmpty { idle.finish(); await settle() }

        let emptyStopped = Runner(), emptyStoppedClock = Clock()
        let emptyStoppedLoop = await fixtureResidentLoop(now: { emptyStoppedClock.date }, run: { try await emptyStopped.run($0) })
        emptyStoppedLoop.setBackgroundEnabled(true)
        emptyStoppedLoop.stop()
        emptyStoppedLoop.receiveUserMessage("你好"); await settle()
        emptyStopped.finish("你好"); await settle()
        emptyStoppedClock.advance(3600); emptyStoppedLoop.tick(); await settle()
        check(emptyStopped.inputs.count == 1, "ordinary greeting cannot undo stop before an intent exists")
        if !emptyStopped.continuations.isEmpty { emptyStopped.finish(); await settle() }

        try await checkDurableEventBacklog(silent: false)
        try await checkDurableEventBacklog(silent: true)

        for failureMode in ["failure", "empty", "stop"] {
            let retry = Runner()
            let retryLoop = await fixtureResidentLoop(run: { try await retry.run($0) })
            let event = ResidentAgentLoop.Event(id: "retry-\(failureMode)", kind: "task.\(failureMode)", summary: "未确认结果")
            retryLoop.receiveEvent(event)
            retryLoop.receiveUserMessage("处理结果"); await settle()
            switch failureMode {
            case "failure": await retry.fail()
            case "empty": retry.finish("")
            default: retryLoop.stop(); retry.finish("过期结果")
            }
            await settle()
            retryLoop.receiveEvent(event)
            retryLoop.tick(); await settle()
            check(retry.inputs.count == 1, "redelivered ordinary observation does not wake itself after \(failureMode)")
            retryLoop.receiveUserMessage("继续核对这个结果"); await settle()
            check(retry.inputs.last!.events == [event], "unsuccessful \(failureMode) observation is eligible for explicit host redelivery")
            retry.finish(); await settle()
        }

        let activeDuplicate = Runner()
        let activeDuplicateLoop = await fixtureResidentLoop(run: { try await activeDuplicate.run($0) })
        let activeEvent = ResidentAgentLoop.Event(id: "active-durable", kind: "task.active", summary: "本轮正在处理")
        activeDuplicateLoop.receiveEvent(activeEvent)
        activeDuplicateLoop.receiveUserMessage("处理这个结果"); await settle()
        for index in 0..<120 {
            activeDuplicateLoop.receiveEvent(.init(id: "busy-\(index)", kind: "busy.\(index)", summary: "运行中接收"))
        }
        activeDuplicateLoop.receiveEvent(activeEvent)
        activeDuplicateLoop.receiveContinuationEvent(activeEvent)
        activeDuplicate.finish(); await settle()
        activeDuplicateLoop.receiveEvent(activeEvent)
        activeDuplicateLoop.receiveUserMessage("处理后续消息"); await settle()
        check(!activeDuplicate.inputs.last!.events.contains { $0.id == activeEvent.id },
              "active event cannot be redelivered or promoted even after the bounded seen-ID window rotates")
        activeDuplicate.finish(); await settle()

        let protected = Runner()
        let protectedLoop = await fixtureResidentLoop(configuration: .init(maximumQueuedEvents: 3), run: { try await protected.run($0) })
        let grants = (0..<3).map { ResidentAgentLoop.Event(id: "grant-\($0)", kind: "grant.\($0)", summary: "授权续办") }
        for event in grants { protectedLoop.receiveContinuationEvent(event) }
        let deferred = ResidentAgentLoop.Event(id: "ordinary-deferred", kind: "ordinary", summary: "普通结果")
        protectedLoop.receiveEvent(deferred)
        protectedLoop.receiveUserMessage("先核对授权结果"); await settle()
        check(protected.inputs.last!.events == grants, "ordinary delivery never evicts protected continuations")
        protected.finish(); await settle()
        protectedLoop.receiveEvent(deferred)
        protectedLoop.receiveUserMessage("再核对其他结果"); await settle()
        check(protected.inputs.last!.events == [deferred], "ordinary event excluded by protected capacity is retryable later")
        protected.finish(); await settle()

        let pausedDelivery = Runner()
        let pausedDeliveryLoop = await fixtureResidentLoop(run: { try await pausedDelivery.run($0) })
        pausedDeliveryLoop.stop()
        pausedDeliveryLoop.receiveUserMessage("你好"); await settle()
        pausedDelivery.finish(); await settle()
        check(pausedDeliveryLoop.snapshot.intentPausedByUser && !pausedDeliveryLoop.snapshot.isStopped,
              "ordinary foreground greeting keeps autonomy paused while allowing event reception")
        let pausedOrdinary = ResidentAgentLoop.Event(id: "paused-state", kind: "task.paused", summary: "后台状态")
        let pausedTerminal = ResidentAgentLoop.Event(id: "paused-terminal", kind: "wish.failed", summary: "后台失败结果")
        pausedDeliveryLoop.receiveEvent(pausedOrdinary)
        pausedDeliveryLoop.receiveContinuationEvent(pausedTerminal)
        pausedDeliveryLoop.tick(); await settle()
        check(pausedDelivery.inputs.count == 1, "paused ordinary and continuation events only queue, never wake a run")
        pausedDeliveryLoop.receiveUserMessage("告诉我后台任务的结果"); await settle()
        check(pausedDelivery.inputs.last!.events == [pausedOrdinary, pausedTerminal],
              "paused queued events are available to an explicit foreground turn without resuming autonomy")
        // ── 停止的语义边界：只停自主，不停人类当轮明确指令 ──────────────────
        // 被停止之后的奉命轮必须拿到"照令执行"的口径；旧措辞让居民在用户明确
        // 说"去把斧头领了"时也保持暂停、只回答不做。
        check(pausedDelivery.inputs.last!.isHumanOrderedTurn
              && pausedDelivery.inputs.last!.promptText.contains("人类明确下令的动作")
              && pausedDelivery.inputs.last!.promptText.contains("必须照令执行")
              && !pausedDelivery.inputs.last!.promptText.contains("本轮没有人类输入"),
              "a human-ordered turn after a stop is told to execute explicit orders, not to stay paused")
        check(pausedDeliveryLoop.snapshot.isAutonomyPausedByUser
              && !pausedDeliveryLoop.runHasHumanInput(runID: UUID()),
              "run stop and autonomy pause stay observable while another run has no human input")
        check(pausedDeliveryLoop.runHasHumanInput(runID: pausedDelivery.inputs.last!.runID),
              "the ordered run itself reports human input")
        pausedDelivery.finish(); await settle()

        // 停止后没有明确指令 ⇒ 后台轮不得自行跑起来；解除必须是一个明确动作
        // （宿主的恢复），而不是靠猜措辞。
        let released = Runner(), releasedClock = Clock()
        let releasedLoop = await fixtureResidentLoop(now: { releasedClock.date },
            run: { try await released.run($0) }, steer: { await released.steer($0) })
        releasedLoop.setBackgroundEnabled(true)
        releasedLoop.receiveUserMessage("先看看窗外"); await settle()
        if !released.continuations.isEmpty { released.finish("看过了"); await settle() }
        releasedLoop.stop()
        check(releasedLoop.snapshot.isAutonomyPausedByUser && releasedLoop.snapshot.isStopped,
              "an explicit stop marks both the run stop and the autonomy pause")
        releasedClock.advance(70); releasedLoop.tick(); await settle()
        check(released.inputs.count == 1, "after a stop no background turn may start without a human release")
        let releaseRequested = releasedLoop.resumeAutonomyByUser()
        await settle()
        check(releaseRequested && releasedLoop.snapshot.isAutonomyPausedByUser == false,
              "one explicit host release clears the stop without any phrasing")
        releasedClock.advance(70); releasedLoop.tick(); await settle()
        check(released.inputs.count == 2 && released.inputs.last!.isBackground
              && !released.inputs.last!.isHumanOrderedTurn
              && released.inputs.last!.promptText.contains("本轮没有人类输入"),
              "only after the human release does autonomy really resume, and that wake is not an ordered turn")
        check(releasedLoop.resumeAutonomyByUser() == false, "releasing an already-released stop is a no-op")
        // 注入式回归时不能让 harness 自己崩掉：拿不到预期轮次就到此为止，
        // 失败的断言已经逐条打印，剩下的检查没有可观测对象。
        if released.inputs.count > 1 {
            released.finish("自主观察"); await settle()
            check(releasedLoop.runHasHumanInput(runID: released.inputs.last!.runID) == false,
                  "a background wake never reports human input by itself")
            releasedLoop.receiveEvent(.init(id: "released-wake", kind: "task.stateChanged", summary: "后台新状态"))
            releasedClock.advance(70); releasedLoop.tick(); await settle()
            check(released.inputs.count == 3 && released.inputs.last!.isBackground,
                  "the released resident can start another background turn")
            released.delivery = .delivered
            releasedLoop.receiveUserMessage("去把斧头领了"); await settle()
            check(releasedLoop.runHasHumanInput(runID: released.inputs.last!.runID)
                  && released.inputs.count == 3,
                  "human steering delivered into a live background run makes that run an ordered run")
            if !released.continuations.isEmpty { released.finish("去领取"); await settle() }
        }

        let recover = Runner(), recoverClock = Clock()
        let recoverLoop = await fixtureResidentLoop(now: { recoverClock.date },
            run: { try await recover.run($0) })
        recoverLoop.receiveEvent(.init(id: "failed-walk", kind: "activity_failed", summary: "路线受阻"))
        recoverLoop.receiveUserMessage("看看周围"); await settle()
        recover.continuations.removeFirst().resume(throwing: NSError(domain: "fixture", code: 1))
        await settle()
        recoverLoop.receiveUserMessage("继续查看实际状态"); await settle()
        check(recover.inputs[1].promptText.contains(#""previousTurnFailed":true"#), "next turn knows previous provider result was not completed")
        check(recover.inputs[1].promptText.contains("路线受阻"), "consumed observation remains in bounded recent context after failed turn")
        check(recover.inputs[1].promptText.contains("recentObservations"), "recent facts separate from newly pending events")
        recover.finish("已检查"); await settle()
        recoverLoop.receiveUserMessage("再看一下"); await settle()
        check(recover.inputs[2].promptText.contains(#""previousTurnFailed":false"#), "successful turn clears uncertain previous-turn marker")
        recover.finish(); await settle()

        // Free periodic autonomous wakes require a meaningful trigger. A background turn that
        // consumes no event and leaves the resident's intent unchanged is a declined decision;
        // re-waking the same state on a pure time cadence only repeats the same model call and
        // the same broadcast (resident says the same line / redoes the same completed thing).
        let quietClock = Clock(), quiet = Runner()
        let quietLoop = await fixtureResidentLoop(now: { quietClock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 100, maximumQueuedEvents: 3, idleReviewInterval: 30),
            run: { try await quiet.run($0) }, onReply: { quiet.replies.append($0) })
        quietLoop.setBackgroundEnabled(true)
        quietLoop.receiveUserMessage("帮我巡游一圈后休息"); await settle()
        try await quietLoop.updateIntent(summary: "巡游已完成，无事可做", status: .completed, wakeAfterSeconds: nil)
        quiet.finish("巡游完成啦"); await settle()
        quietClock.advance(30); quietLoop.tick(); await settle()
        check(quiet.inputs.count == 2 && quiet.inputs[1].isBackground,
              "completed resident is still offered one low-frequency idle review for a new choice")
        try await quietLoop.updateIntent(summary: "巡游已完成，无事可做", status: .completed, wakeAfterSeconds: nil)
        quiet.finish("巡游完成啦"); await settle()
        for _ in 0..<36 {
            quietClock.advance(10); quietLoop.tick(); await settle()
            if !quiet.continuations.isEmpty {
                try await quietLoop.updateIntent(summary: "巡游已完成，无事可做", status: .completed, wakeAfterSeconds: nil)
                quiet.finish("巡游完成啦"); await settle()
            }
        }
        check(quiet.inputs.count == 2, "declining the idle review rests the resident: no repeated model calls without a trigger")
        check(quiet.replies.count == 2, "completed work never repeats the same broadcast on a free cadence")

        // Resting never blocks an authorized completion: it wakes once, is genuinely consumed,
        // and a redelivered duplicate of that event is not executed again.
        let quietReady = ResidentAgentLoop.Event(id: "quiet-wish-ready", kind: "wish.outputReady.quiet-task", summary: "产物已就绪可领取")
        quietLoop.receiveContinuationEvent(quietReady)
        quietClock.advance(10); quietLoop.tick(); await settle()
        check(quiet.inputs.count == 3 && quiet.inputs.last!.events == [quietReady] && quiet.inputs.last!.isBackground,
              "resting resident still wakes exactly once for a new authorized completion")
        try await quietLoop.updateIntent(summary: "去许愿机领取产物", status: .waitingEvent, wakeAfterSeconds: nil)
        quiet.finish("这就去领取"); await settle()
        quietLoop.receiveContinuationEvent(quietReady)
        quietClock.advance(20); quietLoop.tick(); await settle()
        check(quiet.inputs.count == 3, "completion consumed during rest is not re-executed on redelivery")

        // Explicit continuous patrol is carried by the local executor: one bounded periodic
        // check is granted, then a stable active intent is not re-pinged with nothing new.
        let patrolClock = Clock(), patrol = Runner()
        let patrolLoop = await fixtureResidentLoop(now: { patrolClock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 100, maximumQueuedEvents: 3, idleReviewInterval: 600),
            run: { try await patrol.run($0) }, onReply: { patrol.replies.append($0) })
        patrolLoop.setBackgroundEnabled(true)
        patrolLoop.receiveUserMessage("持续巡游客厅，不用等我"); await settle()
        try await patrolLoop.updateIntent(summary: "正在巡游客厅", status: .active, wakeAfterSeconds: nil)
        patrol.finish("好，我持续巡游中"); await settle()
        patrolClock.advance(10); patrolLoop.tick(); await settle()
        check(patrol.inputs.count == 2 && patrol.inputs[1].isBackground,
              "active resident keeps one bounded periodic check of its ongoing arrangement")
        try await patrolLoop.updateIntent(summary: "正在巡游客厅", status: .active, wakeAfterSeconds: nil)
        patrol.finish(""); await settle()
        for _ in 0..<40 {
            patrolClock.advance(10); patrolLoop.tick(); await settle()
            if !patrol.continuations.isEmpty {
                try await patrolLoop.updateIntent(summary: "正在巡游客厅", status: .active, wakeAfterSeconds: nil)
                patrol.finish(""); await settle()
            }
        }
        check(patrol.inputs.count == 2, "continuous patrol continuity is left to the executor, not repeated model pings")
        let milestone = ResidentAgentLoop.Event(id: "patrol-round-done", kind: "activity_completed", summary: "巡游一圈完成")
        patrolLoop.receiveEvent(milestone)
        patrolClock.advance(10); patrolLoop.tick(); await settle()
        check(patrol.inputs.count == 3 && patrol.inputs.last!.events == [milestone],
              "a real world milestone still wakes the resting resident exactly once")
        if !patrol.continuations.isEmpty { patrol.finish("到一圈了"); await settle() }

        // Deliberately repeated identical user requests are each a fresh human instruction:
        // resting autonomy must never deduplicate new user input or swallow a genuine re-request.
        let requestClock = Clock(), requested = Runner()
        let requestLoop = await fixtureResidentLoop(now: { requestClock.date },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 100, maximumQueuedEvents: 3, idleReviewInterval: 30),
            run: { try await requested.run($0) }, onReply: { requested.replies.append($0) })
        requestLoop.setBackgroundEnabled(true)
        requestLoop.receiveUserMessage("帮我放一首舒缓的歌"); await settle()
        try await requestLoop.updateIntent(summary: "歌已放完", status: .completed, wakeAfterSeconds: nil)
        requested.finish("放完啦"); await settle()
        requestClock.advance(30); requestLoop.tick(); await settle()
        try await requestLoop.updateIntent(summary: "歌已放完", status: .completed, wakeAfterSeconds: nil)
        requested.finish("放完啦"); await settle()
        requestClock.advance(10); requestLoop.tick(); await settle()
        check(requested.inputs.count == 2, "declined completed resident rests before the repeated identical request arrives")
        requestLoop.receiveUserMessage("帮我放一首舒缓的歌"); await settle()
        requestLoop.receiveUserMessage("帮我放一首舒缓的歌"); await settle()
        requested.finish("好的，再放一遍"); await settle()
        requested.finish("好的，再放一遍"); await settle()
        check(requested.inputs.count == 4
              && requested.inputs[2].userMessages == ["帮我放一首舒缓的歌"]
              && requested.inputs[3].userMessages == ["帮我放一首舒缓的歌"],
              "two identical user requests are never deduplicated by the resting resident loop")
        check(requested.replies.filter { $0 == "好的，再放一遍" }.count == 2,
              "each deliberately repeated identical request receives its own genuine reply")

        // A genuinely new intent renews periodic eligibility: periodic autonomy survives, but
        // only after meaningful progress, never on an empty free cadence.
        requestClock.advance(120); requestLoop.tick(); await settle()
        check(requested.inputs.count == 4, "fruitless replies to repeated requests do not renew free periodic wakes")
        requestLoop.receiveUserMessage("去窗边看看风景吧"); await settle()
        try await requestLoop.updateIntent(summary: "去窗边看风景", status: .active, wakeAfterSeconds: nil)
        requested.finish("这就去窗边"); await settle()
        requestClock.advance(10); requestLoop.tick(); await settle()
        check(requested.inputs.count == 6 && requested.inputs.last!.isBackground,
              "a real change of intent restores one bounded periodic check")
        if !requested.continuations.isEmpty {
            try await requestLoop.updateIntent(summary: "去窗边看风景", status: .active, wakeAfterSeconds: nil)
            requested.finish(""); await settle()
        }
        // A self-scheduled deadline is a single opportunity, not a subscription: once an
        // expired schedule fires and the resident leaves the same plan (whether it stays
        // silent or merely re-writes the same wording with a renewed wakeAt), the resident
        // rests instead of re-firing the stale or rolling deadline on every later tick.
        for renew in [false, true] {
            let wakeClock = Clock()
            var wakeTurns = 0
            var wakeInputs: [ResidentAgentLoop.Event] = []
            var wakeLoop: ResidentAgentLoop!
            wakeLoop = await fixtureResidentLoop(now: { wakeClock.date },
                configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 100, maximumQueuedEvents: 3),
                run: { input in
                    wakeTurns += 1
                    wakeInputs = input.events
                    if wakeTurns == 1 || renew {
                        try await wakeLoop.updateIntent(summary: "留在点唱机旁，没有新安排", status: .waitingEvent,
                                                  wakeAfterSeconds: 10, runID: input.runID)
                    }
                    return "我在点唱机旁安静听歌，没有新的安排。"
                })
            wakeLoop.setBackgroundEnabled(true)
            for _ in 0..<6 { wakeLoop.tick(); await settle(); wakeClock.date += 10 }
            check(wakeTurns == 2,
                  "\(renew ? "renewed same-plan deadline" : "stale expired deadline") wakes at most once with no event or plan change; observed \(wakeTurns)")
            let arrival = ResidentAgentLoop.Event(id: "arrival-\(renew)", kind: "world.changed", summary: "新客人走进点唱机")
            wakeLoop.receiveEvent(arrival)
            wakeClock.date += 10; wakeLoop.tick(); await settle()
            check(wakeTurns == 3 && wakeInputs.map(\.id) == [arrival.id],
                  "a real new event still wakes the resting self-scheduled wait exactly once (\(renew))")
            wakeLoop.stop()
        }

        // Failure and empty background replies are no progress either: an expired or renewed
        // self-deadline must not retry them on a free cadence. The loop rests after the single
        // fired opportunity, while a manual retry keeps running.
        for outcome in ["failure", "empty"] {
            let failClock = Clock()
            var failTurns = 0
            var failLoop: ResidentAgentLoop!
            failLoop = await fixtureResidentLoop(now: { failClock.date },
                configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 100),
                run: { input in
                    failTurns += 1
                    if !input.userMessages.isEmpty {
                        try await failLoop.updateIntent(summary: "现在去看看饭好了没", status: .active,
                                                  wakeAfterSeconds: nil, runID: input.runID)
                        return "我去看看"
                    }
                    if failTurns == 1 {
                        try await failLoop.updateIntent(summary: "等一锅饭煮好", status: .waitingEvent,
                                                  wakeAfterSeconds: 10, runID: input.runID)
                        return "开始等待"
                    }
                    if outcome == "failure" { throw PictureFailure.providerUnsupported }
                    return ""
                })
            failLoop.setBackgroundEnabled(true)
            failLoop.tick(); await settle()
            check(failTurns == 1 && failLoop.snapshot.intent?.status == .waitingEvent,
                  "\(outcome) probe arms a self-scheduled wait")
            failClock.date += 10
            for _ in 0..<6 { failLoop.tick(); await settle(); failClock.date += 10 }
            check(failTurns == 2 && failLoop.snapshot.lastFailure != nil,
                  "a \(outcome) background turn is not retried on the expired deadline; observed \(failTurns)")
            failLoop.receiveUserMessage("饭好了吗？再去看看"); await settle()
            check(failTurns == 3 && failLoop.snapshot.intent?.status == .active,
                  "manual user request still retries after the resting \(outcome) turn")
            failLoop.stop()
        }

        try await checkCancellationProvenance()
        try await checkModelTurnStatistics()

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
let memorySource = source.deletingLastPathComponent().appendingPathComponent("ResidentMemoryStore.swift")
let stateSource = source.deletingLastPathComponent().appendingPathComponent("ResidentStateClient.swift")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", "tools/fixtures/ResidentIntentDaemonFixture.swift", "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift", "apps/macos/Sources/GMGNRadio/Agent/RustResidentIntentClient.swift", "apps/macos/Sources/GMGNRadio/Presence/RustResidentSchedulerClient.swift", deliverySource.path, source.path, memorySource.path, stateSource.path, toolsSource.path, program.path, "-o", executable.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
if ProcessInfo.processInfo.environment["GMGN_FIXTURE_COMPILE_ONLY"] == "1" { print("PASS: resident loop consumer compiled (not run)"); exit(0) }
let test = Process(); test.executableURL = executable
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
