import Foundation
import Combine

/// 居民跨重启记忆：按统一状态合同（gmgn-taskd `state_read`/`state_commit`）
/// 持久化当前计划（意图+暂停标记）与有依据事实，scope={worldID,residentScope}。
/// 这里只保存阶段变化（回合结束/意图更新/停止），不保存 30Hz 坐标或时间流；
/// 恢复的是上下文与事实——不重放人类消息、委托或身体动作，也不与 wish/taskd
/// 持久化重复。保存失败明确可见（persistenceError + 错误回调），恢复后由
/// 模型重新观察真实世界。
///
/// 提交点边界：本存储是「尽力而为、失败可见」的上下文层，不是同步提交点。
/// WorldStatePersisting.save 与 WishMachineCoordinator.persist 这类崩溃即丢
/// 委托/布局的域，必须等 Rust 回执到达后才能发布成功，不得接入本类的
/// 异步合并提交。
///
/// 写入语义：
/// - 每次 save 合并进**该作用域自己的待写草稿**；草稿不可变地携带作用域，
///   await 期间切换/并存的作用域不会串写；revision 按作用域隔离。
/// - 同一作用域连续 saveA/saveB（在排水任务开始前）不会用 B 覆盖掉 A：
///   状态（intent/暂停）取最新，**未落库的正式事件**按 id 并集保留——内存里的
///   24 条 recent 窗口不会剪掉尚未写进事件流的旧事实。
/// - 串行排水：一次排水顺序提交各作用域的待写草稿；任何一次失败即停
///   （保留未保存值，绝不空转/无限重试），下一次显式 save 用最新内存状态恢复
///   排水。requestID 是内容版本的幂等键：内容不变的重试保留同一 requestID
///   （不确定结果可被后台回放），内容一变就换新 ID；同 ID 不同内容被后台
///   拒绝（request_id_conflict）时丢弃该 ID。
/// - CAS 冲突（revision_conflict）可见报告并停止：**绝不**静默读新 revision
///   后覆盖他人的独立更新；显式 restore / 下次 save 后才重试。
@MainActor
final class ResidentMemoryStore: ObservableObject {
    static let maximumGroundedEvents = 24
    static let planKey = "plan"
    /// 待写草稿中未落库正式事件并集的上限（只在实际排水长期受阻时才会触顶；
    /// 顶掉的是最旧、仍会以最新内存 recent 窗口为准重试的内容）。
    static let maximumPendingFacts = 200

    struct Snapshot: Equatable, Sendable {
        var intent: ResidentAgentLoop.Intent?
        var intentPausedByUser: Bool
        var groundedEvents: [ResidentAgentLoop.Event]
    }

    struct PlanValue: Codable, Equatable, Sendable {
        var intent: ResidentAgentLoop.Intent?
        var intentPausedByUser: Bool
        var groundedEvents: [ResidentAgentLoop.Event]
    }

    @Published private(set) var persistenceError: String?
    var onPersistenceError: ((String) -> Void)?

    private let client: ResidentStateClient
    private let clock: () -> Date
    private var scope_: ResidentStateScope?
    /// 每个作用域独立的乐观 CAS revision；只由成功回执/读取推进。
    private var revisions: [ResidentStateScope: UInt64] = [:]
    /// 本进程已确认落库（state_commit 成功/回放、restore 读到）的事件 id，
    /// 用于避免同一 id 换内容重挂导致 event_id_conflict 或重复挂载。
    private var durableFactIDs: [ResidentStateScope: Set<String>] = [:]

    /// 每个作用域一个待写草稿：最新状态 + 尚未落库的正式事件并集。
    private struct Draft {
        var intent: ResidentAgentLoop.Intent?
        var intentPausedByUser: Bool
        /// 写入 value 的最近事实（≤ maximumGroundedEvents，内存语义）。
        var groundedEvents: [ResidentAgentLoop.Event]
        /// 需要随提交挂为正式事件的未落库事实并集（按 id，最新内容优先）。
        var pendingFacts: [ResidentAgentLoop.Event]
        var requestID: String
    }

    private var drafts: [ResidentStateScope: Draft] = [:]
    /// 待排水作用域的到达顺序（先入先出）。
    private var pendingOrder: [ResidentStateScope] = []
    private var drainTask: Task<Void, Never>?
    private var bindGeneration = 0

    init(client: ResidentStateClient, clock: @escaping () -> Date = Date.init) {
        self.client = client
        self.clock = clock
    }

    /// 声明当前绑定作用域。初次绑定时把该作用域当作"未知 revision（0）"，
    /// 已有乐观值则不动（不把已推进的 revision 拉回 0）。
    func bind(scope: ResidentStateScope) {
        scope_ = scope
        if revisions[scope] == nil { revisions[scope] = 0 }
        bindGeneration += 1
    }

    /// 保存当前快照（阶段变化时调用）。提交串行化并合并；失败即停，
    /// 保留未保存值，仅在下次显式 save 时带最新状态重试——绝不空转。
    func save(scope: ResidentStateScope, intent: ResidentAgentLoop.Intent?,
              intentPausedByUser: Bool, groundedEvents: [ResidentAgentLoop.Event]) {
        scope_ = scope
        let newestEvents = Array(groundedEvents.suffix(Self.maximumGroundedEvents))
        let pending = pendingFactsMerge(scope: scope, intent: intent, intentPausedByUser: intentPausedByUser,
                                        newestEvents: newestEvents)
        drafts[scope] = pending
        if !pendingOrder.contains(scope) { pendingOrder.append(scope) }
        startDrainIfIdle()
    }

    /// 把一次显式 save 合并成（该作用域）最新草稿：状态取最新，
    /// 值内 recent 事件取最新，未落库正式事件取并集。
    private func pendingFactsMerge(scope: ResidentStateScope,
                                   intent: ResidentAgentLoop.Intent?,
                                   intentPausedByUser: Bool,
                                   newestEvents: [ResidentAgentLoop.Event]) -> Draft {
        let valueEvents = Self.dedupePreservingNewest(newestEvents)
        let pendingUnion: [ResidentAgentLoop.Event]
        if let existing = drafts[scope] {
            pendingUnion = Self.unionEvents(preferred: newestEvents, retained: existing.pendingFacts,
                                            cap: Self.maximumPendingFacts)
        } else {
            pendingUnion = valueEvents
        }
        if let existing = drafts[scope] {
            let changed = existing.intent != intent
                || existing.intentPausedByUser != intentPausedByUser
                || Self.eventsByID(existing.groundedEvents) != Self.eventsByID(valueEvents)
                || Self.eventsByID(existing.pendingFacts) != Self.eventsByID(pendingUnion)
            let requestID = changed ? UUID().uuidString : existing.requestID
            return Draft(intent: intent, intentPausedByUser: intentPausedByUser,
                         groundedEvents: valueEvents, pendingFacts: pendingUnion, requestID: requestID)
        }
        return Draft(intent: intent, intentPausedByUser: intentPausedByUser,
                     groundedEvents: valueEvents, pendingFacts: pendingUnion,
                     requestID: UUID().uuidString)
    }

    private func startDrainIfIdle() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
            self.drainTask = nil
            if self.drafts.isEmpty { self.persistenceError = nil }
        }
    }

    /// 串行排水：先入先出提交各作用域草稿；任一失败即停并保留未保存值。
    private func drain() async {
        while let scope = nextPendingScope(), let draft = drafts.removeValue(forKey: scope) {
            let success = await commit(scope, draft: draft)
            if !success {
                // 失败即停：把失败的草稿并回（与 await 期间新到的同作用域草稿合并），
                // 不自动重试；显式的下一次 save 才会恢复排水。
                if var newer = drafts[scope] {
                    newer.pendingFacts = Self.unionEvents(preferred: newer.pendingFacts,
                        retained: draft.pendingFacts, cap: Self.maximumPendingFacts)
                    drafts[scope] = newer
                } else {
                    drafts[scope] = draft
                    if !pendingOrder.contains(scope) { pendingOrder.append(scope) }
                }
                return
            }
        }
    }

    private func nextPendingScope() -> ResidentStateScope? {
        while let first = pendingOrder.first {
            pendingOrder.removeFirst()
            if drafts[first] != nil { return first }
        }
        return nil
    }

    private func commit(_ scope: ResidentStateScope, draft: Draft) async -> Bool {
        let planValue = PlanValue(intent: draft.intent, intentPausedByUser: draft.intentPausedByUser,
            groundedEvents: draft.groundedEvents)
        do {
            let value = try Self.stateValue(planValue)
            let knownDurable = durableFactIDs[scope] ?? []
            let facts = draft.pendingFacts
                .filter { !knownDurable.contains($0.id) }
                .map { ResidentStateFact(id: $0.id, kind: $0.kind, payload: ["summary": .string($0.summary)]) }
            let result = try await client.stateCommit(scope: scope, domain: .resident,
                key: Self.planKey, expectedRevision: revisions[scope] ?? 0,
                requestID: draft.requestID, value: value, events: facts)
            revisions[scope] = result.revision
            if !facts.isEmpty { durableFactIDs[scope, default: []].formUnion(facts.map(\.id)) }
            return true
        } catch ResidentStateError.daemon("request_id_conflict") {
            // 该 requestID 已被（异内容）占用：内容版本的幂等键作废，丢弃后由
            // 排水失败路径以新 ID 保留待写。
            var replacement = draft
            replacement.requestID = UUID().uuidString
            if drafts[scope] == nil {
                drafts[scope] = replacement
                if !pendingOrder.contains(scope) { pendingOrder.append(scope) }
            } else {
                var newer = drafts[scope]!
                newer.pendingFacts = Self.unionEvents(preferred: newer.pendingFacts,
                    retained: draft.pendingFacts, cap: Self.maximumPendingFacts)
                drafts[scope] = newer
            }
            report(ResidentStateError.daemon("request_id_conflict"))
            return false
        } catch {
            report(error)
            return false
        }
    }

    /// 读取已保存快照；无记录返回 nil；读取/解码失败如实抛出并可见。
    /// 成功后把该作用域的 revision 与已落库事实 id 记录下来，供后续 CAS/去重。
    func restore(scope: ResidentStateScope) async throws -> Snapshot? {
        scope_ = scope
        let current = try await client.stateRead(scope: scope, domain: .resident, key: Self.planKey)
        if let current {
            revisions[scope] = current.revision
            let planValue = try Self.decodePlan(current.value)
            durableFactIDs[scope, default: []].formUnion(planValue.groundedEvents.map(\.id))
            if drafts.isEmpty { persistenceError = nil }
            return Snapshot(intent: planValue.intent, intentPausedByUser: planValue.intentPausedByUser,
                groundedEvents: Array(planValue.groundedEvents.suffix(Self.maximumGroundedEvents)))
        }
        revisions[scope] = 0
        if drafts.isEmpty { persistenceError = nil }
        return nil
    }

    private func report(_ error: Error) {
        let message: String
        switch error {
        case ResidentStateError.daemon(let code) where code == "revision_conflict":
            message = "居民记忆保存冲突（revision_conflict）：另一处写入已推进版本；未保存的安排保留在内存并已报告，未自动覆盖他人写入。请以显式恢复/下一次保存重试。"
        case ResidentStateError.daemon(let code) where code == "request_id_conflict":
            message = "居民记忆保存冲突（request_id_conflict）：该幂等键已被不同内容占用；已换新键保留未保存安排，等待下次显式保存。"
        case ResidentStateError.daemon(let code):
            message = "居民记忆保存被后台拒绝（\(code)）；未保存的安排保留在内存，稍后显式重试。"
        case ResidentStateError.unreadableArchive:
            message = "居民记忆快照无法解码（可能是旧格式或已损坏）；未注入任何状态。"
        default:
            message = "居民记忆未能保存：\(error.localizedDescription)；未保存的安排保留在内存。"
        }
        persistenceError = message
        onPersistenceError?(message)
    }

    // MARK: - 可靠 Codable JSON 路径（不经 [String: Any]/NSNumber 桥接）

    static func stateValue(_ plan: PlanValue) throws -> [String: ResidentStateJSON] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(plan)
        guard let tree = try? JSONDecoder().decode(ResidentStateJSON.self, from: data),
              case let .object(object) = tree else {
            throw ResidentStateError.unreadableArchive
        }
        return object
    }

    static func decodePlan(_ value: [String: ResidentStateJSON]) throws -> PlanValue {
        let data: Data
        do { data = try JSONEncoder().encode(ResidentStateJSON.object(value)) }
        catch { throw ResidentStateError.unreadableArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(PlanValue.self, from: data) }
        catch { throw ResidentStateError.unreadableArchive }
    }

    // MARK: - 事件并集/去重工具

    /// 按 id 保留最后一次内容（快照内同 id 只留最新）。
    static func dedupePreservingNewest(_ events: [ResidentAgentLoop.Event]) -> [ResidentAgentLoop.Event] {
        var seen: Set<String> = []
        var result: [ResidentAgentLoop.Event] = []
        for event in events.reversed() {
            if seen.insert(event.id).inserted { result.append(event) }
        }
        return result.reversed()
    }

    /// 并集：preferred（更新的一方）先入、同 id 内容优先；retained 只补
    /// preferred 没有的 id。超 cap 时保留最新部分。
    static func unionEvents(preferred: [ResidentAgentLoop.Event],
                            retained: [ResidentAgentLoop.Event],
                            cap: Int) -> [ResidentAgentLoop.Event] {
        var seen: Set<String> = []
        var result: [ResidentAgentLoop.Event] = []
        func append(_ event: ResidentAgentLoop.Event) {
            if seen.insert(event.id).inserted {
                result.append(event)
            } else if let index = result.firstIndex(where: { $0.id == event.id }) {
                result[index] = event
            }
        }
        for event in dedupePreservingNewest(preferred) { append(event) }
        for event in dedupePreservingNewest(retained) { append(event) }
        if result.count > cap { result = Array(result.suffix(cap)) }
        return result
    }

    static func eventsByID(_ events: [ResidentAgentLoop.Event]) -> [String: ResidentAgentLoop.Event] {
        var map: [String: ResidentAgentLoop.Event] = [:]
        for event in events { map[event.id] = event }
        return map
    }
}
