// ResidentConversationMemory 与编排合同
// （docs/plans/2026-09-08-voicemem-rust-orchestration.md）的离线直接核对：
// StubTransport / GatedTransport 只记录请求并回放 fixture，绝不启动 taskd/
// 宿主、不读数据库。覆盖：薄适配器只转发 memory_recall/ingest（绝无
// memory_compact/query/read/turn、绝无 state_commit）；fresh/resume 由
// 调用方显式传入 freshSession；恢复 context 的 ≤8000 硬限制；recordDeliveredTurn
// 空文本拒绝与 source=voice 转发；有界串行交付队列的顺序/背压/cancelPending；
// bind/reset 推进 generation，scope 切换后旧 scope 的未发送任务失效、晚到
// onStatus/onError 被门控丢弃；ingest accepted 不冒充 durable；daemon/
// invalidResponse/transport 错误可见。外部记忆 provider 接线（适配器的配置/
// 状态转发及状态方法里的 orchestration 字段）已从生产整体移除，
// 这里不再覆盖。并发场景用受控 continuation（GatedTransport）推进，不做
// 无限 sleep/轮询。
import Foundation
import Darwin

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-conversation-memory-\(UUID())")
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

enum StubError: Error { case exhausted }

func scope(_ world: String = "world-a", _ resident: String = "resident-a") -> ResidentStateScope {
    ResidentStateScope(worldID: world, residentScope: resident)
}

/// 立即回放型传输：按序回放预设响应并记录每次请求（直接 await 的转发用）。
@MainActor final class StubTransport: ResidentStateTransport, @unchecked Sendable {
    var responses: [[String: ResidentStateJSON]]
    var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var thrownError: Error?
    init(_ responses: [[String: ResidentStateJSON]]) { self.responses = responses }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        if let thrownError { throw thrownError }
        guard !responses.isEmpty else { throw StubError.exhausted }
        return responses.removeFirst()
    }
}

/// 受控 continuation 型传输：没有预置响应时挂起等待，由测试显式 stage 响应/
/// 错误推进。并发场景用它实现确定性推进。
@MainActor final class GatedTransport: ResidentStateTransport, @unchecked Sendable {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    private var staged: [[String: ResidentStateJSON]] = []
    private var gates: [CheckedContinuation<[String: ResidentStateJSON], Error>] = []
    private var nextThrow: Error?

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        return try await withCheckedThrowingContinuation { continuation in
            if let error = self.nextThrow {
                self.nextThrow = nil
                continuation.resume(throwing: error)
            } else if !self.staged.isEmpty {
                let response = self.staged.removeFirst()
                continuation.resume(returning: response)
            } else {
                self.gates.append(continuation)
            }
        }
    }

    /// 放行最早一个挂起调用；没有挂起调用则预留给下一次调用。
    func stage(_ response: [String: ResidentStateJSON]) {
        if gates.isEmpty {
            staged.append(response)
        } else {
            gates.removeFirst().resume(returning: response)
        }
    }

    func stageFailure(_ error: Error) {
        if gates.isEmpty {
            nextThrow = error
        } else {
            gates.removeFirst().resume(throwing: error)
        }
    }

    var pendingGateCount: Int { gates.count }
}

/// 有限次让出主 actor，让 drain 任务/被 resume 的 continuation 得到推进。
@MainActor func pump(_ times: Int = 8) async {
    for _ in 0..<times { await Task.yield() }
}

// MARK: - fixture 构造器

func recallFixture(context: String, status: String = "ok", pendingTurns: Double = 0) -> [String: ResidentStateJSON] {
    ["status": .string(status), "revision": .number(0), "vectorGeneration": .number(0),
     "facts": .array([]), "notes": .array([]), "context": .string(context),
     "pendingTurns": .number(pendingTurns)]
}

/// daemon 的 `memory_ingest` 回复：外部 provider 移除后**不再有 `consolidation`**。
func ingestFixture(replayed: Bool = false, pendingTurns: Double = 4) -> [String: ResidentStateJSON] {
    ["accepted": .bool(true), "replayed": .bool(replayed),
     "pendingTurns": .number(pendingTurns)]
}

let forbiddenMethods = ["memory_compact", "memory_query", "memory_read", "memory_turn",
                        "state_commit", "state_read", "event_read", "message_read", "message_ack"]

@MainActor func checkNoForbidden(_ recorded: [(method: String, params: [String: ResidentStateJSON])],
                                 _ message: String) {
    check(!recorded.contains(where: { forbiddenMethods.contains($0.method) }), message)
}

@MainActor func run() async throws {
    // MARK: - 1. bind/reset：scope 生命周期、generation 单调、未绑定拒绝
    do {
        let transport = StubTransport([])
        let adapter = ResidentConversationMemory(transport: transport)
        check(adapter.activeScope == nil && adapter.generation == 0, "fresh adapter starts unbound at generation 0")
        let g1 = adapter.bind(scope: scope("w-a", "r-1"))
        check(g1 == 1 && adapter.activeScope == scope("w-a", "r-1"), "bind sets scope and advances generation")
        let g2 = adapter.bind(scope: scope("w-b", "r-2"))
        check(g2 == 2 && adapter.activeScope == scope("w-b", "r-2"), "rebind replaces scope and advances generation")
        let g3 = adapter.reset()
        check(g3 == 3 && adapter.activeScope == nil, "reset unbinds and advances generation")
        check(!adapter.recordDeliveredTurn(requestID: "r", userText: "u", agentReply: "a"),
              "recordDeliveredTurn without bound scope returns false")
        check(transport.recorded.isEmpty, "unbound calls never reach the transport")
    }
    do {
        let adapter = ResidentConversationMemory(transport: StubTransport([]))
        do {
            _ = try await adapter.restore(query: "q", freshSession: true)
            check(false, "restore without bound scope must throw notBound")
        } catch ResidentConversationMemoryError.notBound {
            check(true, "restore without bound scope throws notBound")
        } catch {
            check(false, "restore unbound must throw notBound (got \(error))")
        }
    }

    // MARK: - 2. 薄适配器只转发 memory_recall/ingest
    do {
        let transport = StubTransport([
            recallFixture(context: "融合上下文", status: "ok", pendingTurns: 2),
            ingestFixture(pendingTurns: 3),
        ])
        var statusEvents: [ResidentConversationMemoryStatusEvent] = []
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onStatus = { statusEvents.append($0) }
        adapter.onError = { errorEvents.append($0) }
        adapter.bind(scope: scope())
        let context = try await adapter.restore(query: "居民偏好", freshSession: false)
        check(context.status == .ok && context.text == "融合上下文" && context.pendingTurns == 2,
              "adapter restore() returns Rust context as data")
        let accepted = adapter.recordDeliveredTurn(requestID: "uuid-1", userText: "用户文字", agentReply: "已播回复")
        check(accepted, "recordDeliveredTurn accepts a confirmed delivered turn")
        await pump()
        check(transport.recorded.map(\.method) == ["memory_recall", "memory_ingest"],
              "adapter forwards exactly recall/ingest in call order")
        checkNoForbidden(transport.recorded, "adapter never calls compact/query/read/turn/state_commit/...")
        check(statusEvents.count == 1 && errorEvents.isEmpty, "one status event for the accepted ingest, no errors")
        let recallParams = transport.recorded[0].params
        check(recallParams["query"]?.stringValue == "居民偏好" && recallParams["freshSession"]?.boolValue == false,
              "restore forwards explicit query + freshSession=false")
        let ingestParams = transport.recorded[1].params
        check(ingestParams["requestID"]?.stringValue == "uuid-1"
              && ingestParams["userText"]?.stringValue == "用户文字"
              && ingestParams["agentReply"]?.stringValue == "已播回复",
              "recordDeliveredTurn forwards requestID/userText/agentReply")
    }

    // MARK: - 3. fresh/resume：freshSession 显式透传，bind/reset 划分会话边界
    do {
        let transport = StubTransport([
            recallFixture(context: "新会话整段恢复", status: "ok", pendingTurns: 1),
            recallFixture(context: "本轮相关记忆", status: "ok", pendingTurns: 1),
            recallFixture(context: "新对话再恢复", status: "ok", pendingTurns: 1),
        ])
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.bind(scope: scope())
        let fresh = try await adapter.restore(query: "开场", freshSession: true)
        check(fresh.text == "新会话整段恢复", "freshSession=true restore returns fresh restore context")
        let resume = try await adapter.restore(query: "续聊追问", freshSession: false)
        check(resume.text == "本轮相关记忆", "native resume uses freshSession=false (no repeated full restore)")
        let recorded = transport.recorded.map { $0.params["freshSession"]?.boolValue }
        check(recorded == [true, false], "restore forwards caller-decided freshSession (true then false)")
        // 新会话边界：reset + bind 后再次允许整段恢复（fresh=true）。
        adapter.reset()
        adapter.bind(scope: scope())
        let freshAgain = try await adapter.restore(query: "又开场", freshSession: true)
        check(freshAgain.text == "新对话再恢复", "reset+bind opens a new session allowing a fresh restore again")
        check(transport.recorded.count == 3, "no duplicate/extra recall calls across session boundaries")
    }

    // MARK: - 4. 恢复 context 的 ≤8000 字符硬限制（数据透传，Swift 不重组）
    do {
        let longContext = String(repeating: "长", count: 8005)
        let transport = StubTransport([
            recallFixture(context: longContext, status: "ok", pendingTurns: 9),
            recallFixture(context: "短", status: "empty", pendingTurns: 0),
        ])
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.bind(scope: scope())
        let capped = try await adapter.restore(query: "q", freshSession: true)
        check(capped.text.count == ResidentConversationMemory.contextCharacterLimit,
              "Rust context longer than 8000 characters is hard-capped to 8000 by the adapter")
        check(String(longContext.prefix(8000)) == capped.text, "cap keeps the first 8000 characters")
        check(capped.pendingTurns == 9, "capped context still carries Rust metadata")
        let short = try await adapter.restore(query: "q", freshSession: false)
        check(short.status == .empty && short.text == "短",
              "short/empty context passes through untouched (empty is not an error)")
    }

    // MARK: - 5. source=voice 与时间转发；不夹带 prompt/图片/工具内容
    do {
        let transport = StubTransport([ingestFixture(pendingTurns: 1), ingestFixture(pendingTurns: 2)])
        var events: [ResidentConversationMemoryStatusEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onStatus = { events.append($0) }
        adapter.bind(scope: scope())
        check(adapter.recordDeliveredTurn(requestID: "uuid-v", userText: "转写文本", agentReply: "语音回复",
                                          source: .voice, observedAt: "2026-09-08T11:00:00+08:00"),
              "voice turn is accepted into the delivery queue")
        check(adapter.recordDeliveredTurn(requestID: "uuid-t", userText: "打字", agentReply: "文字回复"),
              "text turn is accepted into the delivery queue")
        await pump()
        check(transport.recorded.count == 2, "both deliveries reach memory_ingest")
        let voiceParams = transport.recorded[0].params
        check(voiceParams["source"]?.stringValue == "voice"
              && voiceParams["observedAt"]?.stringValue == "2026-09-08T11:00:00+08:00",
              "voice delivery forwards source=voice and observedAt time")
        let textParams = transport.recorded[1].params
        check(textParams["source"]?.stringValue == "text" && textParams["observedAt"] == nil,
              "text delivery defaults source=text and omits observedAt when caller provides none")
        let keys = Set(textParams.keys)
        check(keys == ["scope", "requestID", "userText", "agentReply", "source"],
              "ingest carries exactly scope/requestID/userText/agentReply/source (no prompt/image/tool payload)")
        check(events.map(\.requestID) == ["uuid-v", "uuid-t"],
              "status events arrive in enqueue order for the same scope")
    }

    // MARK: - 6. accepted ≠ durable：多次成功入队也只走 memory_ingest，绝不自行 compact
    do {
        let transport = StubTransport([
            ingestFixture(replayed: false, pendingTurns: 4),
            ingestFixture(replayed: true, pendingTurns: 3),
            ingestFixture(replayed: false, pendingTurns: 6),
        ])
        var events: [ResidentConversationMemoryStatusEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onStatus = { events.append($0) }
        adapter.bind(scope: scope())
        _ = adapter.recordDeliveredTurn(requestID: "a", userText: "u1", agentReply: "a1")
        _ = adapter.recordDeliveredTurn(requestID: "b", userText: "u2", agentReply: "a2")
        _ = adapter.recordDeliveredTurn(requestID: "c", userText: "u3", agentReply: "a3")
        await pump()
        check(transport.recorded.map(\.method) == ["memory_ingest", "memory_ingest", "memory_ingest"],
              "three accepted deliveries invoke memory_ingest only")
        checkNoForbidden(transport.recorded, "accepted ingest never triggers any method other than memory_ingest")
        check(events.count == 3, "one status event per accepted ingest")
        if events.count == 3 {
            check(events[0].replayed == false,
                  "first accepted event is a fresh delivery, not a replay")
            check(events[1].replayed == true,
                  "replayed ingest is reported via replayed=true (idempotent replay, not a duplicate write)")
            check(events[2].replayed == false && events[2].pendingTurns == 6,
                  "each event carries its own pendingTurns (third fixture is 6, not a carried-over value)")
            check(events.allSatisfy { $0.scope == scope() && $0.generation == 1 },
                  "status events carry the delivering scope and generation")
        }
    }

    // MARK: - 7. recordDeliveredTurn 空文本拒绝（不产生任何 transport 调用）
    do {
        let transport = StubTransport([ingestFixture()])
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onError = { errorEvents.append($0) }
        adapter.bind(scope: scope())
        check(!adapter.recordDeliveredTurn(requestID: "e1", userText: "", agentReply: "回复"),
              "empty userText is rejected")
        check(!adapter.recordDeliveredTurn(requestID: "e2", userText: "   ", agentReply: "回复"),
              "whitespace-only userText is rejected")
        check(!adapter.recordDeliveredTurn(requestID: "e3", userText: "提问", agentReply: ""),
              "empty agentReply is rejected")
        await pump()
        check(transport.recorded.isEmpty, "rejected empty turns never reach the transport")
        check(errorEvents.count == 3 && errorEvents.allSatisfy { $0.code == .emptyText },
              "each rejected empty turn surfaces onError(.emptyText)")
        if let first = errorEvents.first {
            check(first.scope == scope() && first.generation == 1 && first.requestID == "e1",
                  "emptyText error event carries scope + generation + requestID")
        }
        check(adapter.recordDeliveredTurn(requestID: "ok", userText: "提问", agentReply: "回复"),
              "non-empty delivered turn is accepted")
        await pump()
        check(transport.recorded.count == 1, "valid delivery proceeds after rejections")
    }

    // MARK: - 8. 有界串行队列：顺序 + 背压（queueFull）+ 恢复
    do {
        let transport = GatedTransport()
        var statusEvents: [ResidentConversationMemoryStatusEvent] = []
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let adapter = ResidentConversationMemory(transport: transport, queueCapacity: 2)
        adapter.onStatus = { statusEvents.append($0) }
        adapter.onError = { errorEvents.append($0) }
        adapter.bind(scope: scope())
        check(adapter.recordDeliveredTurn(requestID: "u1", userText: "第一个", agentReply: "a"),
              "first delivery enqueued")
        check(adapter.recordDeliveredTurn(requestID: "u2", userText: "第二个", agentReply: "a"),
              "second delivery enqueued")
        await pump()
        check(transport.recorded.count == 1, "serial queue starts delivering the first item (one in flight)")
        check(transport.pendingGateCount == 1, "first ingest is in flight awaiting its gate")
        // 队列容量 2 已占满（1 在途 + 1 排队）→ 第三个被背压拒绝。
        check(!adapter.recordDeliveredTurn(requestID: "u3", userText: "第三个", agentReply: "a"),
              "third delivery is rejected when the bounded queue is full")
        check(errorEvents.last?.code == .queueFull && errorEvents.last?.requestID == "u3",
              "queue overflow surfaces onError(.queueFull) with the rejected requestID")
        // 放行第一个：事件到达，drain 继续到第二个。
        transport.stage(ingestFixture(pendingTurns: 1))
        await pump()
        check(statusEvents.map(\.requestID) == ["u1"], "first ingest completes with a status event")
        check(transport.recorded.count == 2 && transport.pendingGateCount == 1,
              "drain proceeds to the second item after the first settles")
        // 空间释放后新交付可再次入队（顺序仍为入队序）。
        check(adapter.recordDeliveredTurn(requestID: "u4", userText: "第四个", agentReply: "a"),
              "delivery accepted again once capacity frees")
        transport.stage(ingestFixture(pendingTurns: 2))
        await pump()
        transport.stage(ingestFixture(pendingTurns: 3))
        await pump()
        check(transport.recorded.map { $0.params["userText"]?.stringValue } == ["第一个", "第二个", "第四个"],
              "same-scope ingest requests leave the queue in enqueue order")
        check(statusEvents.map(\.requestID) == ["u1", "u2", "u4"],
              "status events preserve same-scope FIFO order")
        check(transport.pendingGateCount == 0, "no ingest left in flight at the end of the scenario")
    }

    // MARK: - 9. scope 切换：旧 scope 未发送任务失效；晚到 onStatus 被门控丢弃
    do {
        let transport = GatedTransport()
        var statusEvents: [ResidentConversationMemoryStatusEvent] = []
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onStatus = { statusEvents.append($0) }
        adapter.onError = { errorEvents.append($0) }
        let genA = adapter.bind(scope: scope("w-a", "r-1"))
        check(adapter.recordDeliveredTurn(requestID: "a1", userText: "A 回合一", agentReply: "a"),
              "scope A first delivery enqueued")
        await pump()
        check(transport.recorded.count == 1 && transport.pendingGateCount == 1,
              "scope A first ingest is in flight")
        check(adapter.recordDeliveredTurn(requestID: "a2", userText: "A 回合二", agentReply: "a"),
              "scope A second delivery enqueued behind the first")
        let genB = adapter.bind(scope: scope("w-b", "r-2"))
        check(genB == genA + 1, "bind to a new scope advances generation")
        check(adapter.recordDeliveredTurn(requestID: "b1", userText: "B 回合", agentReply: "a"),
              "scope B delivery enqueued after the switch")
        // 放行 A 回合一：它已被 Rust 接受（不可撤回），但事件是旧 scope/代次 → 门控丢弃。
        transport.stage(ingestFixture(pendingTurns: 1))
        await pump()
        check(statusEvents.isEmpty && errorEvents.isEmpty,
              "late status/error from the old scope is gated out after the switch")
        check(transport.recorded.count == 2 && transport.pendingGateCount == 1,
              "drain skipped the invalidated scope A queued turn and moved to scope B")
        check(transport.recorded.map { $0.params["userText"]?.stringValue } == ["A 回合一", "B 回合"],
              "invalidated unsent old-scope turn (A 回合二) never reaches the transport")
        transport.stage(ingestFixture(pendingTurns: 2))
        await pump()
        check(statusEvents.count == 1, "scope B delivery completes with exactly one status event")
        if let event = statusEvents.first {
            check(event.scope == scope("w-b", "r-2") && event.generation == genB && event.requestID == "b1",
                  "delivered event carries the new scope and generation")
        }
        check(transport.pendingGateCount == 0, "no ingest left in flight at the end of the scenario")
    }

    // MARK: - 10. scope 切换同样门控晚到 onError（daemon 拒绝旧 scope 在途回合）
    do {
        let transport = GatedTransport()
        var statusEvents: [ResidentConversationMemoryStatusEvent] = []
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onStatus = { statusEvents.append($0) }
        adapter.onError = { errorEvents.append($0) }
        _ = adapter.bind(scope: scope("w-a", "r-1"))
        _ = adapter.recordDeliveredTurn(requestID: "a1", userText: "旧回合", agentReply: "a")
        await pump()
        _ = adapter.bind(scope: scope("w-b", "r-2"))
        transport.stageFailure(ResidentStateError.daemon("invalid_memory_ingest"))
        await pump()
        check(errorEvents.isEmpty && statusEvents.isEmpty,
              "old-scope daemon rejection is gated out after switching scope")
        check(transport.recorded.count == 1, "only the old in-flight ingest reached the transport")
        _ = adapter.recordDeliveredTurn(requestID: "b1", userText: "新回合", agentReply: "a")
        await pump()
        transport.stage(ingestFixture(pendingTurns: 1))
        await pump()
        check(statusEvents.count == 1 && statusEvents.first?.scope == scope("w-b", "r-2"),
              "new-scope delivery still completes with a status event after the switch")
    }

    // MARK: - 11. cancelPending：只取消未发送队列，不撤销已在途/已接受回合
    do {
        let transport = GatedTransport()
        var statusEvents: [ResidentConversationMemoryStatusEvent] = []
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.onStatus = { statusEvents.append($0) }
        adapter.bind(scope: scope())
        _ = adapter.recordDeliveredTurn(requestID: "c1", userText: "在途", agentReply: "a")
        await pump()
        check(transport.pendingGateCount == 1, "first delivery is in flight before cancel")
        _ = adapter.recordDeliveredTurn(requestID: "c2", userText: "排队二", agentReply: "a")
        _ = adapter.recordDeliveredTurn(requestID: "c3", userText: "排队三", agentReply: "a")
        let dropped = adapter.cancelPending()
        check(dropped == 2, "cancelPending drops the two unsent queued deliveries")
        transport.stage(ingestFixture(pendingTurns: 1))
        await pump()
        check(transport.recorded.count == 1 && statusEvents.map(\.requestID) == ["c1"],
              "in-flight delivery already accepted by Rust completes; cancelled ones are never sent")
        check(transport.pendingGateCount == 0, "no ingest left in flight at the end of the scenario")
    }

    // MARK: - 12. reset 清空未发送队列并解绑；恢复需重新 bind
    do {
        let transport = GatedTransport()
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.bind(scope: scope())
        _ = adapter.recordDeliveredTurn(requestID: "d1", userText: "未发送", agentReply: "a")
        adapter.reset()
        await pump()
        check(adapter.activeScope == nil, "reset unbinds the adapter")
        check(transport.recorded.isEmpty, "reset drops queued unsent deliveries before any transport call")
        check(!adapter.recordDeliveredTurn(requestID: "d2", userText: "x", agentReply: "y"),
              "recordDeliveredTurn is refused after reset until rebind")
        adapter.bind(scope: scope())
        _ = adapter.recordDeliveredTurn(requestID: "d3", userText: "新会话", agentReply: "a")
        await pump()
        check(transport.recorded.count == 1, "deliveries work again after rebind")
    }

    // MARK: - 13. 交付错误可见性：daemon code / invalidResponse / transport 错误
    do {
        let daemonGate = GatedTransport()
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let daemonAdapter = ResidentConversationMemory(transport: daemonGate)
        daemonAdapter.onError = { errorEvents.append($0) }
        daemonAdapter.bind(scope: scope())
        _ = daemonAdapter.recordDeliveredTurn(requestID: "d1", userText: "u", agentReply: "a")
        await pump()
        daemonGate.stageFailure(ResidentStateError.daemon("invalid_memory_ingest"))
        await pump()
        check(errorEvents.last?.code == .daemon("invalid_memory_ingest"), "daemon error code surfaces through onError")
        check(errorEvents.last?.scope == scope() && errorEvents.last?.requestID == "d1",
              "daemon error event carries scope/generation/requestID")
    }
    do {
        let badGate = GatedTransport()
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let badAdapter = ResidentConversationMemory(transport: badGate)
        badAdapter.onError = { errorEvents.append($0) }
        badAdapter.bind(scope: scope())
        _ = badAdapter.recordDeliveredTurn(requestID: "b1", userText: "u", agentReply: "a")
        await pump()
        badGate.stage(["accepted": .bool(true)])  // 缺 replayed/pendingTurns → 畸形
        await pump()
        check(errorEvents.last?.code == .invalidResponse,
              "malformed ingest response surfaces as invalidResponse, never as a fake success")
        check(errorEvents.last?.requestID == "b1", "invalidResponse error event carries requestID")
    }
    do {
        let throwGate = GatedTransport()
        var errorEvents: [ResidentConversationMemoryErrorEvent] = []
        let throwAdapter = ResidentConversationMemory(transport: throwGate)
        throwAdapter.onError = { errorEvents.append($0) }
        throwAdapter.bind(scope: scope())
        _ = throwAdapter.recordDeliveredTurn(requestID: "t1", userText: "u", agentReply: "a")
        await pump()
        throwGate.stageFailure(StubError.exhausted)
        await pump()
        check(errorEvents.last?.code == .transport, "non-daemon transport error surfaces as .transport")
    }

    // MARK: - 14. restore await 期间 scope/generation 切换：旧结果不返回给新调用方
    do {
        // restore：请求挂起期间 bind 到新 scope，旧 scope 的回复必须抛取消类错误，
        // 绝不把旧 scope 的整段恢复注入到新 scope 调用方。
        let transport = GatedTransport()
        let adapter = ResidentConversationMemory(transport: transport)
        var caught: Error?
        adapter.bind(scope: scope("w-a", "r-1"))
        let restoreTask = Task { @MainActor in
            do {
                _ = try await adapter.restore(query: "旧 scope 查询", freshSession: true)
                return "returned"
            } catch {
                caught = error
                return "threw"
            }
        }
        await pump()
        check(transport.pendingGateCount == 1, "stale-scope regression: restore request is in flight")
        adapter.bind(scope: scope("w-b", "r-2"))  // await 期间切换到新 scope
        transport.stage(recallFixture(context: "旧 scope 整段恢复", status: "ok", pendingTurns: 3))
        let outcome = await restoreTask.value
        check(outcome == "threw" && caught is CancellationError,
              "stale-scope regression: old-scope restore result is not returned to the new-scope caller")
        check(transport.pendingGateCount == 0, "stale-scope regression: no restore left in flight")
    }
    do {
        // restore + reset：请求挂起期间 reset 解绑，旧 scope 的 memory_recall 结果
        // 同样不能返回给调用方（与上面的 bind 切换共用 ensureStillCurrent 门控）。
        let transport = GatedTransport()
        let adapter = ResidentConversationMemory(transport: transport)
        var caught: Error?
        adapter.bind(scope: scope("w-a", "r-1"))
        let resetTask = Task { @MainActor in
            do {
                _ = try await adapter.restore(query: "解绑前查询", freshSession: true)
                return "returned"
            } catch {
                caught = error
                return "threw"
            }
        }
        await pump()
        check(transport.pendingGateCount == 1, "stale-scope regression: restore request is in flight before reset")
        adapter.reset()  // await 期间解绑
        transport.stage(recallFixture(context: "解绑前整段恢复", status: "ok", pendingTurns: 9))
        let outcome = await resetTask.value
        check(outcome == "threw" && caught is CancellationError,
              "stale-scope regression: old-scope restore result is not returned after reset")
        check(transport.pendingGateCount == 0, "stale-scope regression: no restore left in flight after reset")
    }
    do {
        // 没有切换时 restore 正常返回（防回归：不因校验误伤正常路径）。
        let transport = GatedTransport()
        let adapter = ResidentConversationMemory(transport: transport)
        adapter.bind(scope: scope())
        let restoreTask = Task { @MainActor in
            try await adapter.restore(query: "正常查询", freshSession: false)
        }
        await pump()
        transport.stage(recallFixture(context: "正常上下文", status: "ok", pendingTurns: 1))
        let context = try await restoreTask.value
        check(context.text == "正常上下文", "unchanged-scope restore still returns its result")
    }

    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident conversation memory checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

@main struct Tests {
    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
            print("FAIL: \(checks) resident conversation memory checks, \(failures) failures")
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
compile.arguments = ["-swift-version", "6", "-j1", "-parse-as-library", "-warnings-as-errors",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryClient.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentConversationMemory.swift").path,
    main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
