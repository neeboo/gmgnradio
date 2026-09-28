import Foundation

// ResidentConversationMemory.swift — VoiceMem 双路记忆编排的薄 Swift 适配层
// 合同：docs/plans/2026-09-08-voicemem-rust-orchestration.md（冻结）
//
// 职责边界（本文件必须保持"薄"）：
// - 只转发 memory_recall / memory_ingest（本地记忆；外部 provider 接线已整体移除）。
// - 绝不调用 memory_query / memory_read / memory_turn，绝不
//   在 Swift 侧做双路排序、二次融合或安排/调度整理。
// - 恢复上下文只取 Rust 已融合好的 `context`：Swift 只做 ≤8000 字符的硬限制
//   并把结果当不透明数据使用；`freshSession` 由调用方显式传入（全新会话 true，
//   原生续聊/同一会话追加查询 false，避免反复整段恢复）。bind/reset 表达会话
//   边界并推进 generation，供调用方安排"每会话只整段恢复一次"。
// - recordDeliveredTurn 只接受调用方已确认真实交付的 userText/agentReply
//   （空文本拒绝），通过一条有界、串行的 IPC 交付队列转发 memory_ingest：
//   调用不阻塞 UI，同 scope 顺序由 FIFO 保证。这是 IPC 交付队列，不是记忆/
//   compact 调度器；已被 Rust 接受的回合不可撤回，按合同由 Rust 后台继续。
// - onStatus/onError 事件都携带 scope + generation，且只在事件仍属于当前
//   scope/generation 时才投递，防止晚到串写。

// MARK: - 值类型

/// 记忆恢复上下文：Rust 双路融合后的有界纯文本 + 最小元数据。
///
/// `text` 已经过本适配器 ≤8000 字符硬限制（`contextCharacterLimit`），只作为
/// 数据使用——不注入 prompt 之外的任何宿主/工具指令，Swift 不做双路排序或
/// 二次融合。`status` 为 ok/empty/unconfigured：unconfigured 下 `text` 可能仍
/// 带回 freshSession 的本地恢复段，但绝不代表语义检索可用。
struct ResidentConversationMemoryContext: Equatable, Sendable {
    let status: ResidentMemoryQueryStatus
    let text: String
    let pendingTurns: UInt64
}

/// memory_ingest 成功进入 Rust 易失缓冲后的状态事件。
///
/// 只代表"已交付回合被 Rust 接受进 volatile 缓冲"——不冒充 durable 落库：
/// 落库由 Rust 后台整理完成，长期状态以 `consolidation` 为准
/// 的 orchestration 为准。事件携带 scope + generation 供消费方防晚到串写。
struct ResidentConversationMemoryStatusEvent: Equatable, Sendable {
    let scope: ResidentStateScope
    let generation: UInt64
    let requestID: String
    let replayed: Bool
    let pendingTurns: UInt64
}

/// 交付失败事件（daemon 拒绝、畸形响应、传输错误、队列满等）。
/// 同样携带 scope + generation + requestID，供消费方关联具体回合。
struct ResidentConversationMemoryErrorEvent: Equatable, Sendable {
    let scope: ResidentStateScope
    let generation: UInt64
    let requestID: String
    let code: ResidentConversationMemoryError
}

enum ResidentConversationMemoryError: LocalizedError, Equatable, Sendable {
    case notBound
    case emptyText
    case queueFull
    case daemon(String)
    case invalidResponse
    case transport

    var errorDescription: String? {
        switch self {
        case .notBound: "尚未绑定记忆 scope（bind 后再恢复/查询/入队）。"
        case .emptyText: "已交付回合的 userText/agentReply 不能为空。"
        case .queueFull: "记忆交付队列已满；该已交付回合未入队，需重试或降级。"
        case let .daemon(code): "记忆后台拒绝了请求（\(code)）。"
        case .invalidResponse: "记忆后台返回了无法识别的数据。"
        case .transport: "记忆传输失败。"
        }
    }
}

// MARK: - 适配器

/// VoiceMem 编排合同的薄适配器。@MainActor 单线程访问：队列、generation 与
/// 回调都在主 actor 上读写，无锁即可保证同 scope 顺序。
@MainActor
final class ResidentConversationMemory {
    /// Rust 融合 context 的硬上限（编排合同：context ≤8000 Unicode 字符）。
    /// Swift 侧只做防御性截断，不重新组织内容。
    static let contextCharacterLimit = 8000

    private let client: ResidentMemoryClient
    private let capacity: Int

    /// 当前绑定的 scope：所有转发（restore/status/recordDeliveredTurn）都以它为
    /// scope。bind 设置、reset 清空。
    private(set) var activeScope: ResidentStateScope?

    /// 单调递增的代次：bind/reset 推进；用于让旧 scope 的未发送任务失效，并
    /// 门控 onStatus/onError 的晚到投递（事件 scope+generation 与当前不符即丢弃）。
    private(set) var generation: UInt64 = 0

    /// 有界、串行的 IPC 交付队列（只承载 memory_ingest）。元素带入队时的
    /// scope+generation；bind/reset/cancelPending 丢弃未发送元素，正在传输的
    /// 元素不受影响。
    private var pendingDeliveries: [Delivery] = []
    private var isDraining = false
    private var inFlight = false

    /// 成功进入 Rust 易失缓冲的状态事件（scope+generation 已门控）。
    var onStatus: ((ResidentConversationMemoryStatusEvent) -> Void)?
    /// 失败事件（scope+generation 已门控）。
    var onError: ((ResidentConversationMemoryErrorEvent) -> Void)?

    init(transport: ResidentStateTransport, queueCapacity: Int = 64) {
        self.client = ResidentMemoryClient(transport: transport)
        self.capacity = max(1, queueCapacity)
    }

    // MARK: - 会话生命周期

    /// 绑定到 scope（新原生会话或世界/居民切换）：推进 generation，使旧 scope
    /// 尚未发送的交付失效。已被 Rust 接受的已交付回合按合同由 Rust 后台继续，
    /// 不因本调用撤回。返回新 generation。
    @discardableResult
    func bind(scope: ResidentStateScope) -> UInt64 {
        activeScope = scope
        generation &+= 1
        pendingDeliveries.removeAll()
        return generation
    }

    /// 解绑并清空未发送交付（例如离开该居民/世界）：scope 置空、推进
    /// generation。返回新 generation。
    @discardableResult
    func reset() -> UInt64 {
        activeScope = nil
        generation &+= 1
        pendingDeliveries.removeAll()
        return generation
    }

    /// 显式取消"尚未发送"的已入队交付，返回被丢弃条数。正在传输/已被 Rust
    /// 接受的回合不受影响（不推进 generation，同 scope 的在途事件仍会投递）。
    @discardableResult
    func cancelPending() -> Int {
        let count = pendingDeliveries.count
        pendingDeliveries.removeAll()
        return count
    }

    // MARK: - 转发：memory_recall

    /// 转发 `memory_recall` 并只取 Rust 融合的 context。freshSession 由调用方
    /// 显式传入：全新会话 true；原生续聊/同一会话追加查询 false（避免反复整段
    /// 恢复）。context 经 ≤8000 字符硬限制后按数据返回；status=empty/
    /// unconfigured 时 text 可能为空，仍正常返回、不当作错误。await 期间的
    /// scope/generation 校验同 status()：切换/取消即抛 CancellationError。
    func restore(query: String, freshSession: Bool, factLimit: Int = 6,
                 noteLimit: Int = 4) async throws -> ResidentConversationMemoryContext {
        let bound = try boundIdentity()
        let result = try await client.memoryRecall(scope: bound.scope, query: query,
                                                   freshSession: freshSession,
                                                   factLimit: factLimit, noteLimit: noteLimit)
        try ensureStillCurrent(bound)
        return ResidentConversationMemoryContext(status: result.status,
                                                 text: Self.cappedContext(result.context),
                                                 pendingTurns: result.pendingTurns)
    }

    // MARK: - 交付写入（有界 IPC 队列 → memory_ingest）

    /// 只接受调用方已确认真实交付的成对 userText/agentReply（空文本拒绝）。
    /// 转发 requestID、source（text/voice）与时间 observedAt；不传宿主 prompt、
    /// 图片/工具内容、被打断/未播完的回复。同步入队后立即返回、不阻塞 UI；同
    /// scope 顺序由串行 FIFO 队列保证。返回 true 表示已入队；未绑定、空文本或
    /// 队列满返回 false（已绑定场景同时投递 onError）。
    @discardableResult
    func recordDeliveredTurn(requestID: String, userText: String, agentReply: String,
                             source: ResidentMemorySource = .text,
                             observedAt: String? = nil) -> Bool {
        guard let scope = activeScope else { return false }
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !agentReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onError?(ResidentConversationMemoryErrorEvent(scope: scope, generation: generation,
                                                          requestID: requestID, code: .emptyText))
            return false
        }
        let occupied = pendingDeliveries.count + (inFlight ? 1 : 0)
        guard occupied < capacity else {
            onError?(ResidentConversationMemoryErrorEvent(scope: scope, generation: generation,
                                                          requestID: requestID, code: .queueFull))
            return false
        }
        pendingDeliveries.append(Delivery(scope: scope, generation: generation,
                                          requestID: requestID, userText: userText,
                                          agentReply: agentReply, source: source,
                                          observedAt: observedAt))
        startDrainingIfNeeded()
        return true
    }

    /// 对 Rust 返回的 context 做 ≤8000 字符硬限制（按 Unicode 字符/grapheme
    /// 边界截断），只防御不重组。
    static func cappedContext(_ context: String) -> String {
        guard context.count > contextCharacterLimit else { return context }
        return String(context.prefix(contextCharacterLimit))
    }

    // MARK: - 队列内部

    private struct Delivery {
        let scope: ResidentStateScope
        let generation: UInt64
        let requestID: String
        let userText: String
        let agentReply: String
        let source: ResidentMemorySource
        let observedAt: String?
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor in
            await self.drainQueue()
            self.isDraining = false
            // drain 期间不会丢新入队项（循环在每次 await 后重查）；此兜底防止
            // 恰好排空后才入队的竞态。
            if !self.pendingDeliveries.isEmpty {
                self.startDrainingIfNeeded()
            }
        }
    }

    private func drainQueue() async {
        while !pendingDeliveries.isEmpty {
            let item = pendingDeliveries.removeFirst()
            guard isCurrent(item) else { continue }  // 旧代/旧 scope：不发传输、无回调
            inFlight = true
            await deliver(item)
            inFlight = false
        }
    }

    private func deliver(_ item: Delivery) async {
        do {
            let result = try await client.memoryIngest(scope: item.scope, requestID: item.requestID,
                                                       userText: item.userText, agentReply: item.agentReply,
                                                       source: item.source, observedAt: item.observedAt)
            guard isCurrent(item) else { return }
            onStatus?(ResidentConversationMemoryStatusEvent(
                scope: item.scope, generation: item.generation, requestID: item.requestID,
                replayed: result.replayed, pendingTurns: result.pendingTurns))
        } catch let error as ResidentStateError {
            guard isCurrent(item) else { return }
            onError?(ResidentConversationMemoryErrorEvent(
                scope: item.scope, generation: item.generation, requestID: item.requestID,
                code: Self.map(error)))
        } catch {
            guard isCurrent(item) else { return }
            onError?(ResidentConversationMemoryErrorEvent(
                scope: item.scope, generation: item.generation, requestID: item.requestID,
                code: .transport))
        }
    }

    /// 门控：事件只投递仍属于当前 scope + 当前 generation 的交付。
    private func isCurrent(_ item: Delivery) -> Bool {
        item.scope == activeScope && item.generation == generation
    }

    // MARK: - 发起时身份与返回前校验

    /// 发起一次转发时捕获 (scope, generation)：即使绑定对象后续被 bind/reset
    /// 替换，本次请求仍能用旧身份识别它是否已失效。
    private struct BoundIdentity: Equatable {
        let scope: ResidentStateScope
        let generation: UInt64
    }

    private func boundIdentity() throws -> BoundIdentity {
        guard let scope = activeScope else { throw ResidentConversationMemoryError.notBound }
        return BoundIdentity(scope: scope, generation: generation)
    }

    /// await 之后、返回给调用方之前校验：仍绑定同一 scope 且同一代次，且外层
    /// 任务未被取消。不符即抛 CancellationError——取消/切换都按取消处理，绝不
    /// 把旧 scope 的结果注入新 scope 调用方。
    private func ensureStillCurrent(_ identity: BoundIdentity) throws {
        try Task.checkCancellation()
        guard identity.scope == activeScope, identity.generation == generation else {
            throw CancellationError()
        }
    }

    private static func map(_ error: ResidentStateError) -> ResidentConversationMemoryError {
        switch error {
        case let .daemon(code): return .daemon(code)
        case .invalidResponse: return .invalidResponse
        case .unreadableArchive: return .invalidResponse  // memory 路径不会产生，保守归类
        }
    }
}
