// ResidentMemoryStore + ResidentAgentLoop 记忆语义与真实 gmgn-taskd daemon 的
// 核对：跨重启恢复计划/暂停/事实、nil 新作用域不继承旧计划、restore await 期间
// 新计划不被旧快照覆盖、同作用域 save 并集不丢未落库事件、跨作用域草稿/revision
// 隔离、CAS 冲突可见不自动覆盖、幂等 requestID 在"不确定结果"重试保留（回放）、
// 永久失败有限调用（绝不空转）。daemon 用明确临时 root/socket（工作区内），
// 不启动用户 TaskService。所有等待都有界。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-memory-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation
import Darwin

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}
enum FakeError: Error { case message(String) }

let binaryPath = ProcessInfo.processInfo.environment["TASKD_BIN"]
    ?? "target/debug/gmgn-taskd"

// MARK: - 真实 daemon 与 socket 运输

final class HTTPFixtureResult: @unchecked Sendable {
    let lock = NSLock()
    var response: Data?
    var failure: Error?
    func set(_ data: Data) { lock.lock(); response = data; lock.unlock() }
    func set(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
}
private func fixtureRequest(socketPath: String, path: String, body: Data?) throws -> URLRequest {
    struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    let descriptor = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: URL(fileURLWithPath: socketPath)))
    let parts = descriptor.address.split(separator: ":")
    guard descriptor.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
          let port = UInt16(parts[1]), port > 0, let token = UUID(uuidString: descriptor.token),
          token.uuidString.dropFirst(14).first == "4",
          let origin = URL(string: "http://\(descriptor.address)") else { throw FakeError.message("invalid HTTP endpoint") }
    var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 8)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
    if let body {
        guard body.count <= TaskdHTTPTransport.maxBytes else { throw FakeError.message("request exceeds limit") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
    }
    return request
}
final class TaskdProcess {
    let root: String
    let socketPath: String
    private var process: Process?
    init(root: String) { self.root = root; self.socketPath = root + "/taskd.endpoint.json" }
    func start() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--root", root, "--endpoint-file", socketPath, "--concurrency", "2"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            if let request = try? fixtureRequest(socketPath: socketPath, path: "health", body: nil) {
                let semaphore = DispatchSemaphore(value: 0), result = HTTPFixtureResult()
                let transport = TaskdHTTPTransport(streaming: false, receive: { result.set($0) },
                    completion: { error in if let error { result.set(error) }; semaphore.signal() })
                transport.start(request)
                if semaphore.wait(timeout: .now() + 8) != .success { transport.cancel(); throw FakeError.message("health timed out") }
                if let data = result.response,
                   let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   health["version"] as? Int == 2, health["transport"] as? String == "http" { return }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw FakeError.message("daemon did not expose HTTP at \(socketPath)")
    }
    func stop() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil
    }
    deinit { stop() }
}
@MainActor class TaskdTransport: ResidentStateTransport, @unchecked Sendable {
    struct Request: Encodable { let id: String; let method: String; let params: [String: ResidentStateJSON] }
    private struct Envelope: Decodable {
        struct Err: Decodable { let code: String }
        let id: String?
        let result: [String: ResidentStateJSON]?
        let error: Err?
    }
    let socketPath: String
    init(socketPath: String) { self.socketPath = socketPath }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        let id = UUID().uuidString
        let body = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let request = try fixtureRequest(socketPath: socketPath, path: "rpc", body: body)
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let transport = TaskdHTTPTransport(streaming: false, receive: { continuation.resume(returning: $0) },
                completion: { error in if let error { continuation.resume(throwing: error) } })
            transport.start(request)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: response)
        if let error = envelope.error { throw ResidentStateError.daemon(error.code) }
        guard envelope.id == id, let result = envelope.result else { throw ResidentStateError.invalidResponse }
        return result
    }
}

// MARK: - 测试专用运输包装（只做传输层故障/延迟/计数，不改合同）

/// 计数 + 可关闭的故障开关（simulate daemon down）。
@MainActor final class SwitchableTransport: ResidentStateTransport, @unchecked Sendable {
    let inner: TaskdTransport
    var fail = false
    private(set) var calls: [(method: String, params: [String: ResidentStateJSON])] = []
    init(inner: TaskdTransport) { self.inner = inner }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        calls.append((method, params))
        if fail { throw FakeError.message("transport down") }
        return try await inner.call(method: method, params: params)
    }
}

/// 给指定方法注入"到达后丢弃应答"（模拟响应丢失：请求可能已落库）。
@MainActor final class DropOnceTransport: ResidentStateTransport, @unchecked Sendable {
    let inner: TaskdTransport
    let dropMethod: String
    var dropNext = false
    private(set) var calls = 0
    init(inner: TaskdTransport, dropMethod: String) { self.inner = inner; self.dropMethod = dropMethod }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        calls += 1
        let response = try await inner.call(method: method, params: params)
        if dropNext && method == dropMethod {
            dropNext = false
            throw ResidentStateError.invalidResponse
        }
        return response
    }
}

/// 挂起指定方法的应答直到 release（保持 daemon 已服务的真实应答）。
@MainActor final class HoldTransport: ResidentStateTransport, @unchecked Sendable {
    let inner: TaskdTransport
    let heldMethod: String
    private var parked: [(CheckedContinuation<[String: ResidentStateJSON], Error>, [String: ResidentStateJSON])] = []
    private(set) var parkedCount = 0
    init(inner: TaskdTransport, heldMethod: String) { self.inner = inner; self.heldMethod = heldMethod }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        try await withCheckedThrowingContinuation { outer in
            Task { @MainActor in
                do {
                    let response = try await self.inner.call(method: method, params: params)
                    if method == self.heldMethod {
                        self.parked.append((outer, response))
                        self.parkedCount += 1
                    } else {
                        outer.resume(returning: response)
                    }
                } catch {
                    outer.resume(throwing: error)
                }
            }
        }
    }
    func releaseNext() {
        guard !parked.isEmpty else { return }
        let (continuation, response) = parked.removeFirst()
        parkedCount -= 1
        continuation.resume(returning: response)
    }
    func releaseAll() {
        while !parked.isEmpty { releaseNext() }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(15)
    while !(await condition()) {
        if Date() >= deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func event(_ id: String, _ kind: String = "world.changed", _ summary: String = "事实") -> ResidentAgentLoop.Event {
    ResidentAgentLoop.Event(id: id, kind: kind, summary: summary)
}

func makeIntent(_ summary: String, _ step: String, _ pausedWake: Bool = false) -> ResidentAgentLoop.Intent {
    ResidentAgentLoop.Intent(
        summary: summary, status: pausedWake ? .waitingEvent : .active,
        wakeAt: pausedWake ? Date().addingTimeInterval(120) : nil,
        goal: "目标-" + summary, currentStep: step, nextSteps: ["下一步1", "下一步2"],
        advanceWhen: pausedWake ? "等待某个事件" : nil, lastOutcome: "最近结果", adjustReason: "调整原因",
        source: .userDelegated)
}

@MainActor func run() async throws {
    guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
        print("SKIP: gmgn-taskd binary not found at \(binaryPath)")
        return
    }
    // daemon root/socket 必须落在工作区内（沙箱只允许派生进程在工作区绑定 socket）。
    let base = FileManager.default.currentDirectoryPath + "/tmp/gmgn-memory-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: base) }
    let daemon = TaskdProcess(root: base)
    try daemon.start()
    defer { daemon.stop() }
    func transport() -> TaskdTransport { TaskdTransport(socketPath: daemon.socketPath) }
    func rawClient() -> ResidentStateClient { ResidentStateClient(transport: transport()) }

    // ---- 1. 循环端到端：回合结束提交计划与事实；重启 daemon 后恢复为上下文。
    do {
        let s = ResidentStateScope(worldID: "w1", residentScope: "r1")
        var loopRef: ResidentAgentLoop!
        let loop = ResidentAgentLoop(run: { input in
            try loopRef.updateIntent(summary: "去点唱机听歌", status: .active, wakeAfterSeconds: nil,
                runID: input.runID,
                plan: ResidentAgentLoop.IntentPlanRevision(
                    goal: "用点唱机放用户想听的歌", currentStep: "列出歌单并准备曲目",
                    nextSteps: ["start_activity music.listen", "确认真实播放"],
                    advanceWhen: "music.listen 完成或失败事件", adjustReason: "按用户委托",
                    source: .userDelegated))
            return "好的"
        }, onFailure: { _ in })
        loopRef = loop
        let store = ResidentMemoryStore(client: rawClient())
        loop.bindMemory(store: store, scope: s)
        loop.receiveEvent(event("evt-turn1", "activity_completed", "music.listen 已完成"))
        loop.receiveUserMessage("去点唱机听歌")
        await waitUntil { !loopRef.snapshot.isRunning }
        await waitUntil { (try? await rawClient().stateRead(scope: s, domain: .resident, key: "plan")) != nil }
        check(loop.snapshot.intent?.currentStep == "列出歌单并准备曲目", "plan fields recorded on the live loop")
        check(store.persistenceError == nil, "first save has no error")

        // 重启 daemon：新循环从统一状态恢复计划/暂停/事实，作为下一轮上下文。
        daemon.stop(); try daemon.start()
        var restoredRuns = 0
        let restored = ResidentAgentLoop(run: { _ in restoredRuns += 1; return "" }, onFailure: { _ in })
        let store2 = ResidentMemoryStore(client: rawClient())
        restored.bindMemory(store: store2, scope: s)
        await restored.restoreMemory()
        check(restored.snapshot.intent?.goal == "用点唱机放用户想听的歌"
            && restored.snapshot.intent?.currentStep == "列出歌单并准备曲目"
            && restored.snapshot.intent?.advanceWhen == "music.listen 完成或失败事件"
            && restored.snapshot.intent?.adjustReason == "按用户委托",
            "goal/currentStep/advanceWhen/adjustReason survive a restart")
        check(restored.snapshot.intent?.nextSteps == ["start_activity music.listen", "确认真实播放"]
            && restored.snapshot.intent?.source == .userDelegated,
            "nextSteps/source survive a restart")
        check(restored.snapshot.recentEvents.map(\.id) == ["evt-turn1"], "grounded facts survive a restart")
        check(restored.snapshot.pendingUserMessages.isEmpty
            && restored.snapshot.isRunning == false && restored.snapshot.isStopped == false,
            "restore never replays messages or actions")
        check(restoredRuns == 0, "restoring alone starts no run")
        restored.stop()
    }

    // ---- 1b. wakeAt Date 走 iso8601 往返：encode/decode 策略一致，重开后仍接近原值。
    do {
        let s = ResidentStateScope(worldID: "w1b", residentScope: "r")
        let wakeAtDate = Date().addingTimeInterval(120)
        let seed = try ResidentMemoryStore.stateValue(ResidentMemoryStore.PlanValue(
            intent: ResidentAgentLoop.Intent(summary: "等待计划", status: .waitingEvent,
                wakeAt: wakeAtDate, goal: nil, currentStep: nil, nextSteps: nil,
                advanceWhen: nil, lastOutcome: nil, adjustReason: nil, source: nil),
            intentPausedByUser: false, groundedEvents: [event("evt-wake-\(UUID().uuidString)")]))
        _ = try await rawClient().stateCommit(scope: s, domain: .resident, key: "plan",
            expectedRevision: 0, requestID: "wake-seed-\(UUID().uuidString)", value: seed)
        let restoredWake = ResidentAgentLoop(run: { _ in "" }, onFailure: { _ in })
        restoredWake.bindMemory(store: ResidentMemoryStore(client: rawClient()), scope: s)
        await restoredWake.restoreMemory()
        if let wake = restoredWake.snapshot.intent?.wakeAt {
            check(abs(wake.timeIntervalSince(wakeAtDate)) < 2, "wakeAt Date survives the iso8601 round trip")
        } else { check(false, "wakeAt survives a restart") }
        check(restoredWake.snapshot.intent?.status == .waitingEvent, "status survives alongside the Date")
    }

    // ---- 2. nil 新作用域不得继承旧作用域计划/事实。
    do {
        let sA = ResidentStateScope(worldID: "w2", residentScope: "a")
        let sB = ResidentStateScope(worldID: "w2", residentScope: "b")
        let store = ResidentMemoryStore(client: rawClient())
        var loopRef: ResidentAgentLoop!
        let loop = ResidentAgentLoop(run: { input in
            try loopRef.updateIntent(summary: "旧世界安排", status: .active, wakeAfterSeconds: nil,
                runID: input.runID,
                plan: ResidentAgentLoop.IntentPlanRevision(currentStep: "旧步骤", adjustReason: nil, source: .userDelegated))
            return ""
        }, onFailure: { _ in })
        loopRef = loop
        loop.bindMemory(store: store, scope: sA)
        loop.receiveEvent(event("evt-A", "world.changed", "旧世界事实"))
        loop.receiveUserMessage("安排")
        await waitUntil { !loopRef.snapshot.isRunning }
        await waitUntil { (try? await rawClient().stateRead(scope: sA, domain: .resident, key: "plan")) != nil }
        check(loop.snapshot.intent?.summary == "旧世界安排", "scope A plan recorded")
        // 切到还没有任何记录的 scope B（空闲切换）。
        loop.bindMemory(store: store, scope: sB)
        check(loop.snapshot.intent == nil && loop.snapshot.recentEvents.isEmpty,
            "binding a new scope never inherits the old scope's plan or facts")
        await loop.restoreMemory()
        check(loop.snapshot.intent == nil && loop.snapshot.recentEvents.isEmpty
            && loop.snapshot.intentPausedByUser == false,
            "nil restore on the new scope leaves no inherited plan")
        // 切回 A：恢复 A 自己的计划。
        loop.bindMemory(store: store, scope: sA)
        await loop.restoreMemory()
        check(loop.snapshot.intent?.summary == "旧世界安排", "switching back restores scope A's own plan")
        loop.stop()
    }

    // ---- 3. restore await 期间用户消息已执行完：旧快照不得覆盖新计划。
    do {
        let s = ResidentStateScope(worldID: "w3", residentScope: "r")
        // 先直接落一个 P1 记录（revision 1）。
        let seed = try ResidentMemoryStore.stateValue(ResidentMemoryStore.PlanValue(
            intent: makeIntent("P1 计划", "P1-step"), intentPausedByUser: false,
            groundedEvents: [event("evt-p1")]))
        _ = try await rawClient().stateCommit(scope: s, domain: .resident, key: "plan",
            expectedRevision: 0, requestID: "seed-p1", value: seed)
        // (a) 无竞争的普通 restore 会应用快照（正例）。
        let plainLoop = ResidentAgentLoop(run: { _ in "" }, onFailure: { _ in })
        plainLoop.bindMemory(store: ResidentMemoryStore(client: rawClient()), scope: s)
        await plainLoop.restoreMemory()
        check(plainLoop.snapshot.intent?.summary == "P1 计划" && plainLoop.snapshot.intent?.currentStep == "P1-step",
            "an uncontended restore applies the durable snapshot")
        plainLoop.stop()
        // (b) restore 在 await（state_read 应答挂起）期间，用户消息到达并完整执行：
        //     旧 P1 快照不得把内存里的 P2 新计划覆盖掉。
        let gate = HoldTransport(inner: transport(), heldMethod: "state_read")
        var raceRef: ResidentAgentLoop!
        let raceLoop = ResidentAgentLoop(run: { input in
            try raceRef.updateIntent(summary: "P2 计划", status: .active, wakeAfterSeconds: nil,
                runID: input.runID,
                plan: ResidentAgentLoop.IntentPlanRevision(currentStep: "P2-step", source: .userDelegated))
            return ""
        }, onFailure: { _ in })
        raceRef = raceLoop
        raceLoop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: gate)), scope: s)
        let raceRestore = Task { await raceLoop.restoreMemory() }
        try? await Task.sleep(for: .milliseconds(150))   // restore 停在挂起的 state_read（读到的还是 P1）
        raceLoop.receiveUserMessage("改主意了")
        await waitUntil { !raceRef.snapshot.isRunning }
        gate.releaseAll()
        await raceRestore.value
        check(raceLoop.snapshot.intent?.summary == "P2 计划" && raceLoop.snapshot.intent?.currentStep == "P2-step",
            "an executed user message during restoreMemory wins over the stale snapshot")
        raceLoop.stop()
    }

    // ---- 4. 同一 actor 连续 saveA/saveB/saveC（排水任务开始前）：只提交一次，
    //        未落库正式事件按 id 并集，24 条 recent 窗口不会剪掉旧事件。
    do {
        let s = ResidentStateScope(worldID: "w4", residentScope: "r")
        let gate = SwitchableTransport(inner: transport())
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: gate))
        let ids = (0..<26).map { "union-\($0)-\(UUID().uuidString.prefix(6))" }
        // 同一同步回合里连续三次保存：A 带 e0..e23，B 带 e1..e24，C 带 e2..e25。
        store.save(scope: s, intent: makeIntent("意图A", "step-A"),
            intentPausedByUser: false, groundedEvents: (0..<24).map { event(ids[$0]) })
        store.save(scope: s, intent: makeIntent("意图B", "step-B"),
            intentPausedByUser: false, groundedEvents: (1..<25).map { event(ids[$0]) })
        store.save(scope: s, intent: makeIntent("意图C", "step-C"),
            intentPausedByUser: true, groundedEvents: (2..<26).map { event(ids[$0]) })
        await waitUntil { gate.calls.filter { $0.method == "state_commit" }.count >= 1 }
        try? await Task.sleep(for: .milliseconds(150))
        let commitCalls = gate.calls.filter { $0.method == "state_commit" }.count
        check(commitCalls == 1, "same-turn saves coalesce into a single commit; observed \(commitCalls)")
        let reader = rawClient()
        let page = try await reader.eventRead(scope: s, after: 0, limit: 500)
        let durable = Set(page.events.map(\.id))
        check(durable.isSuperset(of: Set(ids)), "not-yet-durable facts from earlier saves are never trimmed by the 24-recent window")
        let record = try await reader.stateRead(scope: s, domain: .resident, key: "plan")
        check(record?.revision == 1, "coalesced commit revision is 1")
        // 状态取最新：C 的意图与暂停标记。
        let snapshot = try await store.restore(scope: s)
        check(snapshot?.intent?.summary == "意图C" && snapshot?.intentPausedByUser == true
            && snapshot?.intent?.currentStep == "step-C",
            "merged state keeps the newest intent and pause marker")
    }

    // ---- 5. A 的提交在途时，B/C 的同/跨作用域保存不丢（revision 按 scope 隔离）。
    do {
        let sX = ResidentStateScope(worldID: "w5", residentScope: "x")
        let sY = ResidentStateScope(worldID: "w5", residentScope: "y")
        let gate = HoldTransport(inner: transport(), heldMethod: "state_commit")
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: gate))
        let x1 = "x1-\(UUID().uuidString)"; let x2 = "x2-\(UUID().uuidString)"
        let x3 = "x3-\(UUID().uuidString)"; let x4 = "x4-\(UUID().uuidString)"
        let y1 = "y1-\(UUID().uuidString)"
        store.save(scope: sX, intent: makeIntent("X1", "s1"), intentPausedByUser: false,
            groundedEvents: [event(x1), event(x2), event(x3)])
        await waitUntil { gate.parkedCount >= 1 }   // X1 的 state_commit 已到达 daemon、应答被挂起（提交在途）
        store.save(scope: sX, intent: makeIntent("X2", "s2"), intentPausedByUser: false,
            groundedEvents: [event(x2), event(x3), event(x4)])
        store.save(scope: sY, intent: makeIntent("Y1", "s1"), intentPausedByUser: false,
            groundedEvents: [event(y1)])
        gate.releaseNext()
        await waitUntil { gate.parkedCount >= 1 }
        gate.releaseNext()
        await waitUntil { gate.parkedCount >= 1 }
        gate.releaseNext()
        await waitUntil { gate.parkedCount == 0 }
        let reader = rawClient()
        let xRecord = try await reader.stateRead(scope: sX, domain: .resident, key: "plan")
        let yRecord = try await reader.stateRead(scope: sY, domain: .resident, key: "plan")
        check(xRecord?.revision == 2, "scope X advanced through two isolated commits")
        check(yRecord?.revision == 1, "scope Y revision is independent of scope X")
        let xEvents = try await reader.eventRead(scope: sX, after: 0, limit: 500)
        let xIDs = Set(xEvents.events.map(\.id))
        check(xIDs.isSuperset(of: [x1, x2, x3, x4]), "facts from the first in-flight save are not lost")
        let yEvents = try await reader.eventRead(scope: sY, after: 0, limit: 500)
        check(yEvents.events.map(\.id) == [y1], "cross-scope pending write lands too")
    }

    // ---- 6. 永久失败：每次显式 save 最多一次尝试，绝不空转；恢复后清除。
    do {
        let s = ResidentStateScope(worldID: "w6", residentScope: "r")
        let gate = SwitchableTransport(inner: transport())
        gate.fail = true
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: gate))
        var reported: [String] = []
        store.onPersistenceError = { reported.append($0) }
        store.save(scope: s, intent: makeIntent("要保存的安排", "step"), intentPausedByUser: false,
            groundedEvents: [event("evt-fail-\(UUID().uuidString)")])
        await waitUntil { store.persistenceError != nil }
        let afterFirst = gate.calls.filter { $0.method == "state_commit" }.count
        check(afterFirst == 1, "a failed save attempts exactly one commit; observed \(afterFirst)")
        check(reported.contains { $0.contains("保存") }, "failure is visibly surfaced")
        try? await Task.sleep(for: .milliseconds(400))
        let afterIdle = gate.calls.filter { $0.method == "state_commit" }.count
        check(afterIdle == afterFirst, "no background retry spins while the daemon is down")
        // 第二次显式 save：带最新内存状态再试一次（仍失败，仍只一次）。
        store.save(scope: s, intent: makeIntent("要保存的安排", "step"), intentPausedByUser: false,
            groundedEvents: [event("evt-fail-\(UUID().uuidString)")])
        await waitUntil { gate.calls.filter { $0.method == "state_commit" }.count == 2 }
        check(store.persistenceError != nil, "second explicit save retries once and keeps the visible failure")
        gate.fail = false
        store.save(scope: s, intent: makeIntent("要保存的安排", "step"), intentPausedByUser: false,
            groundedEvents: [event("evt-fail-\(UUID().uuidString)")])
        await waitUntil { store.persistenceError == nil }
        let record = try await rawClient().stateRead(scope: s, domain: .resident, key: "plan")
        check(record != nil && store.persistenceError == nil, "recovery on the next explicit save clears the error")
    }

    // ---- 7. 不确定结果（应答丢失但已落库）：同内容重试保留 requestID → 回放，
    //         不推进 revision、不重复挂事件；内容变更才换新 ID 提交。
    do {
        let s = ResidentStateScope(worldID: "w7", residentScope: "r")
        let drop = DropOnceTransport(inner: transport(), dropMethod: "state_commit")
        drop.dropNext = true
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: drop))
        let evt = event("evt-lost-\(UUID().uuidString)", "activity_completed", "完成")
        store.save(scope: s, intent: makeIntent("内容C", "c1"), intentPausedByUser: false,
            groundedEvents: [evt])
        await waitUntil { store.persistenceError != nil }
        // 请求其实已落库（应答被丢弃）。
        var record = try await rawClient().stateRead(scope: s, domain: .resident, key: "plan")
        check(record?.revision == 1, "the lost-response commit actually landed at revision 1")
        // 同内容显式保存：保留同一 requestID → daemon 回放，revision 仍是 1。
        store.save(scope: s, intent: makeIntent("内容C", "c1"), intentPausedByUser: false,
            groundedEvents: [evt])
        await waitUntil { store.persistenceError == nil }
        record = try await rawClient().stateRead(scope: s, domain: .resident, key: "plan")
        check(record?.revision == 1, "the identical-content retry replays without advancing the revision")
        let events = try await rawClient().eventRead(scope: s, after: 0, limit: 500)
        check(events.events.filter { $0.id == evt.id }.count == 1, "the replayed commit does not append the event twice")
        // 内容变更 → 新 requestID → 正常提交推进 revision。
        store.save(scope: s, intent: makeIntent("内容D", "d1"), intentPausedByUser: false,
            groundedEvents: [evt])
        await waitUntil { (try? await rawClient().stateRead(scope: s, domain: .resident, key: "plan"))?.revision == 2 }
        check(true, "a content change commits under a fresh requestID")
    }

    // ---- 8. CAS 冲突可见：不读新 revision 自动覆盖；显式 restore 后才重试。
    do {
        let s = ResidentStateScope(worldID: "w8", residentScope: "r")
        // 独立写入者先落一个合法 plan 记录（revision 1）。
        let other = try ResidentMemoryStore.stateValue(ResidentMemoryStore.PlanValue(
            intent: makeIntent("他人计划", "other-step"), intentPausedByUser: false, groundedEvents: []))
        _ = try await rawClient().stateCommit(scope: s, domain: .resident, key: "plan",
            expectedRevision: 0, requestID: "other-1", value: other)
        let gate = SwitchableTransport(inner: transport())
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: gate))
        store.save(scope: s, intent: makeIntent("我的计划", "my-step"), intentPausedByUser: false,
            groundedEvents: [event("evt-mine-\(UUID().uuidString)")])
        await waitUntil { store.persistenceError != nil }
        check(store.persistenceError?.contains("revision_conflict") == true
            || store.persistenceError?.contains("冲突") == true,
            "a stale CAS is reported visibly as a conflict")
        let still = try await rawClient().stateRead(scope: s, domain: .resident, key: "plan")
        check(still?.revision == 1 && still?.value["intent"]?.objectValue?["summary"]?.stringValue == "他人计划",
            "the conflict never silently overwrites the other writer's record")
        try? await Task.sleep(for: .milliseconds(300))
        check(gate.calls.filter { $0.method == "state_commit" }.count == 1,
            "a CAS conflict stops the drain without automatic retries")
        // 显式 restore 刷新乐观 revision（返回他人记录，不自动覆盖）。
        let snapshot = try await store.restore(scope: s)
        check(snapshot?.intent?.summary == "他人计划", "explicit restore surfaces the other writer's record")
        // 下次显式 save 在正确 revision 上提交自己的最新状态。
        store.save(scope: s, intent: makeIntent("我的计划", "my-step"), intentPausedByUser: false,
            groundedEvents: [event("evt-mine2-\(UUID().uuidString)")])
        await waitUntil { (try? await rawClient().stateRead(scope: s, domain: .resident, key: "plan"))?.revision == 2 }
        check(store.persistenceError == nil, "an explicit save after restore commits and clears the error")
    }

    // ---- 9. 暂停标记跨重启：恢复后不启动旧动作，普通问候不解除暂停。
    do {
        let s = ResidentStateScope(worldID: "w9", residentScope: "r")
        var loopRef: ResidentAgentLoop!
        let loop = ResidentAgentLoop(run: { input in
            try loopRef.updateIntent(summary: "整理书架", status: .active, wakeAfterSeconds: nil, runID: input.runID)
            return "好的"
        }, onFailure: { _ in })
        loopRef = loop
        let store = ResidentMemoryStore(client: rawClient())
        loop.bindMemory(store: store, scope: s)
        loop.receiveUserMessage("整理书架")
        await waitUntil { !loopRef.snapshot.isRunning }
        loop.stop()
        // 等 stop 的暂停标记真正落库（值里 intentPausedByUser == true）。
        await waitUntil {
            guard let record = try? await rawClient().stateRead(scope: s, domain: .resident, key: "plan") else { return false }
            return record.value["intentPausedByUser"]?.boolValue == true
        }
        daemon.stop(); try daemon.start()
        var runs = 0
        let restored = ResidentAgentLoop(run: { _ in runs += 1; return "你好" }, onFailure: { _ in })
        let restoredStore = ResidentMemoryStore(client: rawClient())
        restored.bindMemory(store: restoredStore, scope: s)
        await restored.restoreMemory()
        check(restored.snapshot.intentPausedByUser, "the pause marker survives a restart")
        restored.setBackgroundEnabled(true)
        restored.tick()
        try? await Task.sleep(for: .milliseconds(120))
        check(restored.snapshot.isRunning == false && runs == 0,
            "a paused resident never starts old actions after a restart")
        var greetingRuns = 0
        let greeting = ResidentAgentLoop(run: { _ in greetingRuns += 1; return "你好" }, onFailure: { _ in })
        greeting.bindMemory(store: ResidentMemoryStore(client: rawClient()), scope: s)
        await greeting.restoreMemory()
        greeting.receiveUserMessage("你好")
        await waitUntil { greetingRuns == 1 && !greeting.snapshot.isRunning }
        check(greeting.snapshot.intentPausedByUser, "a plain greeting never resumes the pause")
        greeting.setBackgroundEnabled(true)
        greeting.tick()
        try? await Task.sleep(for: .milliseconds(120))
        check(greeting.snapshot.isRunning == false, "tick after a greeting still cannot start paused autonomy")
        greeting.stop()
    }

    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident memory checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

@main struct Tests {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
            print("FAIL: \(checks) resident memory checks, \(failures) failures")
            exit(1)
        }
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentSteeringDelivery.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryStore.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift").path,
    main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
