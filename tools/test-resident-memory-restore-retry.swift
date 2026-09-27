// 居民计划恢复失败后的重试与迟到结果污染提示的回归测试。
//
// 覆盖（全部跑真实生产代码，注入假 transport 与可注入 clock，不用 daemon）：
// - 当前 scope 恢复失败可见且可沿既有调度按 30 秒节流重试（重试真调 transport）；
// - 失败未就绪前 tick 不启动自主；成功或确实空记录才放行/允许自主；
// - 用户先输入（回合已执行完）不被晚到的成功/失败恢复覆盖，也不产生提示；
// - 切 scope / invalidate / A→B→A（ABA）后迟到的失败 0 提示且不污染新绑定状态；
// - 直接取消恢复 Task（transport 不响应取消）：入口取消与迟到成功/失败一律作废、
//   不提示、不覆盖计划，同绑定退出 restoring 后新 Task 可立即重试；
// - 当前 scope 真实失败提示去重；
// - ResidentMemoryStore：恢复失败如实抛出、不吞错不缓存 inflight，重试真调
//   transport；初次恢复失败后（revision 未知）保存按 CAS 不覆写旧数据。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let loopSource = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift")
let storeSource = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryStore.swift")
let deliverySource = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentSteeringDelivery.swift")
let stateSource = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift")
for source in [loopSource, storeSource, deliverySource, stateSource] {
    guard FileManager.default.fileExists(atPath: source.path) else {
        print("FAIL: missing production source \(source.path)")
        exit(1)
    }
}

let harness = #"""
import Foundation

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

enum FakeError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

@MainActor func isFailed(_ attempt: ResidentAgentLoop.MemoryRestoreAttempt) -> Bool {
    if case .failed = attempt { return true }
    return false
}

@MainActor final class Clock {
    var date = Date(timeIntervalSince1970: 20_000)
    func advance(_ seconds: Double) { date += seconds }
}

/// 内存态统一状态合同运输：真实 CAS（expectedRevision 不符 → revision_conflict）、
/// requestID 回放、读取失败注入、以及把 state_read 挂起以制造"迟到结果"。
@MainActor final class MemoryTransport: ResidentStateTransport, @unchecked Sendable {
    struct Record { var revision: UInt64; var value: [String: ResidentStateJSON]; var requestID: String }
    var records: [ResidentStateScope: Record] = [:]
    private(set) var readCalls = 0
    private(set) var commitCalls = 0
    var failReads = false
    var failCommits = false
    var holdReads = false
    private var parked: [(continuation: CheckedContinuation<[String: ResidentStateJSON], Error>,
                         scope: ResidentStateScope?, shouldFail: Bool)] = []
    private(set) var parkedCount = 0

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        switch method {
        case "state_read":
            readCalls += 1
            let scope = Self.scope(params)
            if holdReads {
                let shouldFail = failReads
                return try await withCheckedThrowingContinuation { continuation in
                    parked.append((continuation, scope, shouldFail))
                    parkedCount += 1
                }
            }
            if failReads { throw FakeError.message("read down") }
            return Self.readResponse(scope.flatMap { records[$0] })
        case "state_commit":
            commitCalls += 1
            if failCommits { throw FakeError.message("commit down") }
            return try Self.commit(params, records: &records)
        default:
            throw ResidentStateError.invalidResponse
        }
    }

    func releaseAll() {
        let pending = parked
        parked.removeAll()
        parkedCount = 0
        for entry in pending {
            if entry.shouldFail {
                entry.continuation.resume(throwing: FakeError.message("read down"))
            } else {
                entry.continuation.resume(returning: Self.readResponse(entry.scope.flatMap { records[$0] }))
            }
        }
    }

    static func scope(_ params: [String: ResidentStateJSON]) -> ResidentStateScope? {
        guard case let .object(object)? = params["scope"],
              case let .string(worldID)? = object["worldID"],
              case let .string(residentScope)? = object["residentScope"] else { return nil }
        return ResidentStateScope(worldID: worldID, residentScope: residentScope)
    }

    static func readResponse(_ record: Record?) -> [String: ResidentStateJSON] {
        guard let record else { return ["record": .null] }
        return ["record": .object(["revision": .number(Double(record.revision)),
                                   "value": .object(record.value)])]
    }

    static func commit(_ params: [String: ResidentStateJSON],
                       records: inout [ResidentStateScope: Record]) throws -> [String: ResidentStateJSON] {
        guard let scope = scope(params),
              case let .number(expected)? = params["expectedRevision"],
              let expectedRevision = UInt64(exactly: expected),
              case let .string(requestID)? = params["requestID"],
              case let .object(value)? = params["value"] else { throw ResidentStateError.invalidResponse }
        if let existing = records[scope], existing.requestID == requestID {
            return ["revision": .number(Double(existing.revision)), "replayed": .bool(true)]
        }
        let currentRevision = records[scope]?.revision ?? 0
        guard expectedRevision == currentRevision else { throw ResidentStateError.daemon("revision_conflict") }
        let revision = currentRevision + 1
        records[scope] = Record(revision: revision, value: value, requestID: requestID)
        return ["revision": .number(Double(revision)), "replayed": .bool(false)]
    }
}

@MainActor func settle() async { for _ in 0..<40 { await Task.yield() } }

@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(15)
    while !condition() {
        if Date() >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
func makeIntent(_ summary: String, _ step: String) -> ResidentAgentLoop.Intent {
    ResidentAgentLoop.Intent(summary: summary, status: .active, wakeAt: nil, goal: nil,
        currentStep: step, nextSteps: nil, advanceWhen: nil, lastOutcome: nil,
        adjustReason: nil, source: .userDelegated)
}

@MainActor
func seedPlan(_ summary: String, _ step: String = "step") throws -> [String: ResidentStateJSON] {
    try ResidentMemoryStore.stateValue(ResidentMemoryStore.PlanValue(
        intent: makeIntent(summary, step), intentPausedByUser: false, groundedEvents: []))
}

@MainActor func run() async throws {
    let scopeA = ResidentStateScope(worldID: "w-restore", residentScope: "a")
    let scopeB = ResidentStateScope(worldID: "w-restore", residentScope: "b")

    // ---- 1. 当前 scope 失败可见、同 scope 节流重试真调 transport、成功后才放行。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("旧计划", "旧步骤"), requestID: "seed-a")
        transport.failReads = true
        var notices: [String] = []
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: transport))
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "unused" },
                                     onFailure: { notices.append($0) })
        loop.bindMemory(store: store, scope: scopeA)
        check(loop.memoryRestoreBlocksAutonomy, "a bound scope blocks autonomy until the restore settles")

        let first = await loop.restoreMemory()
        check(isFailed(first), "a current-scope transport failure is reported as failed; got \(first)")
        check(notices.count == 1 && notices[0].contains("未能恢复"),
              "the current-scope failure is visible exactly once; got \(notices)")
        check(loop.memoryRestoreBlocksAutonomy, "a failed restore keeps autonomy blocked")
        check(transport.readCalls == 1, "the failed attempt called the transport once; got \(transport.readCalls)")

        let throttled = await loop.restoreMemory()
        check(throttled == .skipped && transport.readCalls == 1,
              "within the 30s window the scheduler cannot re-hit the transport; got \(throttled)/\(transport.readCalls)")

        clock.advance(ResidentAgentLoop.memoryRestoreRetryInterval + 0.1)
        transport.failReads = false
        let second = await loop.restoreMemory()
        check(second == .restored, "the throttled same-scope retry restores the saved plan; got \(second)")
        check(transport.readCalls == 2, "the retry really called the transport again; got \(transport.readCalls)")
        check(loop.snapshot.intent?.summary == "旧计划" && loop.snapshot.intent?.currentStep == "旧步骤",
              "the retried snapshot is applied to the loop")
        check(!loop.memoryRestoreBlocksAutonomy, "a successful restore releases autonomy")
        check(notices.count == 1, "the failure notice is not repeated after recovery; got \(notices.count)")
        loop.stop()
    }

    // ---- 2. 初次失败后重试读到"确实无记录"：nil 快照也是明确就绪态，允许自主。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.failReads = true
        var notices = 0
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "ran" }, onFailure: { _ in notices += 1 })
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        _ = await loop.restoreMemory()
        check(loop.memoryRestoreBlocksAutonomy, "a failed first restore blocks autonomy")
        clock.advance(ResidentAgentLoop.memoryRestoreRetryInterval + 0.1)
        transport.failReads = false
        let outcome = await loop.restoreMemory()
        check(outcome == .empty, "a genuinely empty record is an explicit ready state; got \(outcome)")
        check(!loop.memoryRestoreBlocksAutonomy && loop.snapshot.intent == nil,
              "an empty record releases autonomy with no inherited plan")
        check(notices == 1, "the failure was still surfaced once before the empty retry; got \(notices)")
        loop.stop()
    }

    // ---- 3. 恢复未就绪不得启动自主；成功后才启动；用户消息不受影响。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("恢复的计划"), requestID: "seed-a")
        transport.failReads = true
        var runs = 0
        let loop = ResidentAgentLoop(now: { clock.date },
            configuration: .init(minimumWakeInterval: 0, backgroundTurnsPerHour: 100),
            run: { _ in runs += 1; return "自主一轮" })
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        _ = await loop.restoreMemory()
        loop.setBackgroundEnabled(true)
        for _ in 0..<5 { loop.tick(); await settle(); clock.advance(10) }
        check(runs == 0 && !loop.snapshot.isRunning,
              "a failed restore never starts autonomous planning; runs=\(runs)")

        transport.failReads = false
        clock.advance(ResidentAgentLoop.memoryRestoreRetryInterval + 0.1)
        let retried = await loop.restoreMemory()
        check(retried == .restored, "the retry after the failure restores; got \(retried)")
        loop.tick(); await settle()
        check(runs == 1, "autonomy starts only after the restore succeeds; runs=\(runs)")
        loop.stop()
    }

    // ---- 4. 失败未重试期间用户消息照常执行并让旧恢复作废，不卡死自主。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("P1 旧计划"), requestID: "seed-a")
        transport.failReads = true
        var loopRef: ResidentAgentLoop!
        var runs = 0
        let loop = ResidentAgentLoop(now: { clock.date }, run: { input in
            runs += 1
            try loopRef.updateIntent(summary: "P2 新计划", status: .active, wakeAfterSeconds: nil,
                runID: input.runID, plan: .init(currentStep: "P2-step", source: .userDelegated))
            return "好的"
        })
        loopRef = loop
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        _ = await loop.restoreMemory()
        check(loop.memoryRestoreBlocksAutonomy, "the failed restore still blocks before the user takes over")
        loop.receiveUserMessage("改主意了")
        await waitUntil { !loop.snapshot.isRunning && loop.snapshot.intent?.summary == "P2 新计划" }
        check(runs == 1 && loop.snapshot.intent?.currentStep == "P2-step",
              "a user message still runs and records the new plan while restore is unsettled")
        check(!loop.memoryRestoreBlocksAutonomy,
              "user takeover supersedes the stale restore instead of deadlocking autonomy")
        let stale = await loop.restoreMemory()
        check(stale == .superseded, "the superseded restore is never retried; got \(stale)")
        check(loop.snapshot.intent?.summary == "P2 新计划", "the stale snapshot cannot overwrite the user plan")
        loop.stop()
    }

    // ---- 5. restore 挂在 await、用户回合已执行完：迟到的成功与失败都不得覆盖/提示。
    for lateFailure in [false, true] {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("P1 旧计划"), requestID: "seed-a")
        transport.holdReads = true
        transport.failReads = lateFailure
        var notices: [String] = []
        var loopRef: ResidentAgentLoop!
        let loop = ResidentAgentLoop(now: { clock.date }, run: { input in
            try loopRef.updateIntent(summary: "P2 新计划", status: .active, wakeAfterSeconds: nil,
                runID: input.runID, plan: .init(currentStep: "P2-step", source: .userDelegated))
            return "好的"
        }, onFailure: { notices.append($0) })
        loopRef = loop
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        let restore = Task { await loop.restoreMemory() }
        await waitUntil { transport.parkedCount >= 1 }
        loop.receiveUserMessage("改主意了")
        await waitUntil { !loop.snapshot.isRunning && loop.snapshot.intent?.summary == "P2 新计划" }
        transport.holdReads = false
        transport.releaseAll()
        let outcome = await restore.value
        check(outcome == .superseded,
              "a user turn during restore supersedes the late \(lateFailure ? "failure" : "success"); got \(outcome)")
        check(loop.snapshot.intent?.summary == "P2 新计划",
              "the late \(lateFailure ? "failure" : "success") never overwrites the user plan")
        check(notices.isEmpty,
              "a superseded late \(lateFailure ? "failure" : "success") produces no notice; got \(notices)")
        check(!loop.memoryRestoreBlocksAutonomy,
              "user takeover after the late \(lateFailure ? "failure" : "success") keeps autonomy unblocked")
        loop.stop()
    }

    // ---- 6. 切 scope 后迟到的失败 0 提示，且不污染新 scope 的恢复状态。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("A 计划"), requestID: "seed-a")
        transport.holdReads = true
        transport.failReads = true
        var notices: [String] = []
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: transport))
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "unused" }, onFailure: { notices.append($0) })
        loop.bindMemory(store: store, scope: scopeA)
        let restore = Task { await loop.restoreMemory() }
        await waitUntil { transport.parkedCount >= 1 }
        loop.bindMemory(store: store, scope: scopeB)
        transport.holdReads = false
        transport.failReads = false
        transport.releaseAll()
        let outcome = await restore.value
        check(outcome == .superseded, "a scope switch supersedes the late failure; got \(outcome)")
        check(notices.isEmpty, "an old-scope late failure produces no notice; got \(notices)")
        check(loop.memoryRestoreBlocksAutonomy, "the new scope still waits for its own restore")
        let fresh = await loop.restoreMemory()
        check(fresh == .empty && !loop.memoryRestoreBlocksAutonomy,
              "the new scope restores independently and releases autonomy; got \(fresh)")
        loop.stop()
    }

    // ---- 7. invalidate 后迟到的失败 0 提示。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("A 计划"), requestID: "seed-a")
        transport.holdReads = true
        transport.failReads = true
        var notices: [String] = []
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "unused" }, onFailure: { notices.append($0) })
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        let restore = Task { await loop.restoreMemory() }
        await waitUntil { transport.parkedCount >= 1 }
        loop.invalidate()
        transport.holdReads = false
        transport.releaseAll()
        let outcome = await restore.value
        check(outcome == .superseded, "invalidate supersedes the late failure; got \(outcome)")
        check(notices.isEmpty, "an invalidated late failure produces no notice; got \(notices)")
        check(!loop.memoryRestoreBlocksAutonomy, "an invalidated loop never holds autonomy")
    }

    // ---- 8. ABA（A→B→A）：旧尝试的迟到失败不得把重回的 A 标成 failed 或写节流。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("A 计划"), requestID: "seed-a")
        transport.holdReads = true
        transport.failReads = true
        var notices: [String] = []
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: transport))
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "unused" }, onFailure: { notices.append($0) })
        loop.bindMemory(store: store, scope: scopeA)
        let restore = Task { await loop.restoreMemory() }
        await waitUntil { transport.parkedCount >= 1 }
        loop.bindMemory(store: store, scope: scopeB)
        loop.bindMemory(store: store, scope: scopeA)
        transport.holdReads = false
        transport.failReads = false
        transport.releaseAll()
        let outcome = await restore.value
        check(outcome == .superseded, "the ABA stale attempt is discarded; got \(outcome)")
        check(notices.isEmpty, "the ABA stale failure produces no notice; got \(notices)")
        check(loop.memoryRestoreBlocksAutonomy,
              "the stale failure never marks the re-bound scope as settled")
        let fresh = await loop.restoreMemory()
        check(fresh == .restored, "the re-bound scope can still restore immediately (no stale throttle); got \(fresh)")
        check(loop.snapshot.intent?.summary == "A 计划", "the ABA re-bind restores scope A's own plan")
        loop.stop()
    }

    // ---- 9. Store：失败如实抛出、不缓存 inflight、重试真调 transport；
    //         初次恢复失败后保存按 CAS 不覆写旧数据。
    do {
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("他人计划", "other-step"), requestID: "other-1")
        transport.failReads = true
        var reported: [String] = []
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: transport))
        store.onPersistenceError = { reported.append($0) }
        var threw = false
        do { _ = try await store.restore(scope: scopeA) } catch { threw = true }
        check(threw, "a failed restore throws instead of being swallowed (no silent partial state)")
        check(transport.readCalls == 1, "the failed restore called the transport once")

        // 初次恢复失败 → revision 未知(0)；保存不得覆写已存在的 revision 1 记录。
        store.save(scope: scopeA, intent: makeIntent("我的计划", "my-step"),
            intentPausedByUser: false, groundedEvents: [])
        await waitUntil { store.persistenceError != nil }
        check(transport.commitCalls == 1, "the save attempted exactly one commit; got \(transport.commitCalls)")
        check(store.persistenceError?.contains("revision_conflict") == true
            || store.persistenceError?.contains("冲突") == true,
            "a save after an unknown-revision restore is reported as a CAS conflict; got \(store.persistenceError ?? "nil")")
        check(reported.contains { $0.contains("revision_conflict") || $0.contains("冲突") },
            "the CAS conflict is also surfaced through the store's error callback")
        let still = transport.records[scopeA]
        check(still?.revision == 1
            && still?.value["intent"]?.objectValue?["summary"]?.stringValue == "他人计划",
            "the other writer's record is never silently overwritten")

        // 重试恢复真的再次调用 transport（没有缓存 inflight 或吞掉失败）。
        transport.failReads = false
        let snapshot = try await store.restore(scope: scopeA)
        check(transport.readCalls == 2, "the retry calls the transport again; got \(transport.readCalls)")
        check(snapshot?.intent?.summary == "他人计划", "the retry surfaces the other writer's record")
        store.save(scope: scopeA, intent: makeIntent("我的计划", "my-step"),
            intentPausedByUser: false, groundedEvents: [])
        await waitUntil { transport.records[scopeA]?.revision == 2 }
        check(transport.records[scopeA]?.value["intent"]?.objectValue?["summary"]?.stringValue == "我的计划",
            "after an explicit restore the next save commits at the correct revision")
    }

    // ---- 10. 直接取消恢复 Task（transport 不响应取消）：迟到的成功/失败都作废，
    //          不覆盖计划、不提示；同绑定退出 restoring 后新 Task 可立即重试。
    for lateFailure in [false, true] {
        let label = lateFailure ? "failure" : "success"
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("P1 旧计划"), requestID: "seed-a")
        transport.holdReads = true
        transport.failReads = lateFailure
        var notices: [String] = []
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "unused" },
                                     onFailure: { notices.append($0) })
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        let restore = Task { await loop.restoreMemory() }
        await waitUntil { transport.parkedCount >= 1 }
        restore.cancel()
        transport.holdReads = false
        transport.failReads = false
        transport.releaseAll()
        let outcome = await restore.value
        check(outcome == .superseded,
              "cancelling the restore task discards its late \(label) even though the transport ignores cancellation; got \(outcome)")
        check(loop.snapshot.intent == nil,
              "a cancelled late \(label) never applies the saved plan; got \(String(describing: loop.snapshot.intent?.summary))")
        check(notices.isEmpty, "a cancelled late \(label) produces no failure notice; got \(notices)")
        check(loop.memoryRestoreBlocksAutonomy,
              "a cancelled attempt leaves the same binding unrestored and blocking")
        let fresh = await loop.restoreMemory()
        check(fresh == .restored,
              "the same binding retries immediately after the cancel exits restoring; got \(fresh)")
        check(loop.snapshot.intent?.summary == "P1 旧计划",
              "the retry after the cancel applies the real saved plan")
        check(transport.readCalls == 2,
              "the cancelled attempt hit the transport once and the retry once; got \(transport.readCalls)")
        loop.stop()
    }

    // ---- 11. 任务在进入恢复前就被取消：入口即作废，不触碰 transport、不写状态、不提示。
    do {
        let clock = Clock()
        let transport = MemoryTransport()
        transport.records[scopeA] = MemoryTransport.Record(
            revision: 1, value: try seedPlan("P1 旧计划"), requestID: "seed-a")
        var notices: [String] = []
        let loop = ResidentAgentLoop(now: { clock.date }, run: { _ in "unused" },
                                     onFailure: { notices.append($0) })
        loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: transport)), scope: scopeA)
        let restore = Task { await loop.restoreMemory() }
        restore.cancel()
        let outcome = await restore.value
        check(outcome == .superseded,
              "a task cancelled before entry voids the restore immediately; got \(outcome)")
        check(transport.readCalls == 0,
              "an entry-cancelled restore never touches the transport; got \(transport.readCalls)")
        check(notices.isEmpty, "an entry-cancelled restore produces no notice; got \(notices)")
        check(loop.memoryRestoreBlocksAutonomy,
              "an entry-cancelled restore leaves the binding unrestored and blocking")
        let fresh = await loop.restoreMemory()
        check(fresh == .restored && loop.snapshot.intent?.summary == "P1 旧计划",
              "the entry-cancelled attempt does not wedge the binding; got \(fresh)")
        loop.stop()
    }

    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident memory restore-retry checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

@main struct Tests {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
            print("FAIL: \(checks) resident memory restore-retry checks, \(failures) failures")
            exit(1)
        }
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-restore-retry-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Main.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("restore-retry-tests")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-parse-as-library", deliverySource.path, loopSource.path,
                      storeSource.path, stateSource.path, program.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
