import Foundation

// ResidentConversationMemory.swift — VoiceMem 记忆编排的薄 Swift 适配层
// 合同：docs/plans/2026-09-08-voicemem-rust-orchestration.md（冻结）
//
// 职责边界（本文件必须保持"薄"）：
// - **只转发 `memory_recall`**（本地记忆；外部 provider 接线已整体移除）。
// - 绝不调用 `memory_read` / `memory_query`，绝不在 Swift 侧做双路排序、二次融合
//   或安排/调度整理。
// - 恢复上下文只取 Rust 已融合好的 `context`：Swift 只做 ≤8000 字符的硬限制
//   并把结果当不透明数据使用；`freshSession` 由调用方显式传入（全新会话 true，
//   原生续聊/同一会话追加查询 false，避免反复整段恢复）。bind/reset 表达会话
//   边界并推进 generation，供调用方安排"每会话只整段恢复一次"。
//
// **原文层已整体移除（2026-10-01）**：本类原先还负责
// `recordDeliveredTurn` → 有界 IPC 队列 → `memory_ingest`，以及 `onStatus`/`onError`
// 回调与 `cancelPending`。这些都删了，理由与出处见
// `docs/plans/2026-09-08-voicemem-rust-contract.md` 的「已移除」一节：真机
// `pendingTurns` 恒为 0、三张记忆表 0 行、`memory_compact` 从未有 dispatch，
// 原文层唯一的生产用途（`freshSession` 恢复段）恒为空转。
// **因此本类现在只读**：它不再向后台写入任何东西。

// MARK: - 值类型

/// 记忆恢复上下文：Rust 融合后的有界纯文本 + 最小元数据。
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

// MARK: - 适配器

/// VoiceMem 编排合同的薄适配器。@MainActor 单线程访问：队列、generation 与
/// 回调都在主 actor 上读写，无锁即可保证同 scope 顺序。
@MainActor
final class ResidentConversationMemory {
    /// Rust 融合 context 的硬上限（编排合同：context ≤8000 Unicode 字符）。
    /// Swift 侧只做防御性截断，不重新组织内容。
    static let contextCharacterLimit = 8000

    private let client: ResidentMemoryClient

    init(transport: ResidentStateTransport) {
        self.client = ResidentMemoryClient(transport: transport)
    }

    /// 当前绑定的 scope：所有转发（`restore`）都以它为 scope。bind 设置、reset 清空。
    private(set) var activeScope: ResidentStateScope?

    /// 单调递增的代次：bind/reset 推进；用于让旧 scope 的晚到结果失效
    /// （`ensureStillCurrent` 在事件与当前 scope/generation 不符时按取消处理）。
    private(set) var generation: UInt64 = 0

    // MARK: - 会话生命周期

    /// 绑定到 scope（新原生会话或世界/居民切换）：推进 generation，使旧 scope
    /// 尚未发送的交付失效。已被 Rust 接受的已交付回合按合同由 Rust 后台继续，
    /// 不因本调用撤回。返回新 generation。
    @discardableResult
    func bind(scope: ResidentStateScope) -> UInt64 {
        activeScope = scope
        generation &+= 1
        return generation
    }

    /// 解绑并清空未发送交付（例如离开该居民/世界）：scope 置空、推进
    /// generation。返回新 generation。
    @discardableResult
    func reset() -> UInt64 {
        activeScope = nil
        generation &+= 1
        return generation
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

    /// 对 Rust 返回的 context 做 ≤8000 字符硬限制（按 Unicode 字符/grapheme
    /// 边界截断），只防御不重组。
    static func cappedContext(_ context: String) -> String {
        guard context.count > contextCharacterLimit else { return context }
        return String(context.prefix(contextCharacterLimit))
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
}

/// 本适配器现在只剩"读"这一条路，所以错误类型也只剩它需要的那几个。
///
/// 原先还有 `emptyText` / `queueFull`（都属已移除的交付队列）。`daemon` /
/// `invalidResponse` / `transport` 保留：`restore` 把后台错误码原样透传，
/// 调用方据此区分"后台拒绝了"与"传输失败"。
enum ResidentConversationMemoryError: LocalizedError, Equatable, Sendable {
    case notBound
    case daemon(String)
    case invalidResponse
    case transport

    var errorDescription: String? {
        switch self {
        case .notBound: "尚未绑定记忆 scope（bind 后再恢复/查询）。"
        case let .daemon(code): "记忆后台拒绝了请求（\(code)）。"
        case .invalidResponse: "记忆后台返回了无法识别的数据。"
        case .transport: "记忆传输失败。"
        }
    }
}
