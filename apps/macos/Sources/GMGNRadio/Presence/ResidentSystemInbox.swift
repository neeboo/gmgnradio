import Foundation
import Combine
import os

/// One user-readable system delivery (wish task progress/completion/failure).
/// This is a projection only: applying it never acknowledges the background
/// consumer, whose ACK semantics stay in the delivery pipeline.
public struct ResidentSystemDelivery: Equatable, Sendable {
    public let eventID: String
    public let taskID: String
    public let kind: String
    public let title: String
    public let status: String
    public let detail: String
    public let terminal: Bool

    public init(eventID: String, taskID: String, kind: String,
                title: String, status: String, detail: String, terminal: Bool) {
        self.eventID = eventID
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.status = status
        self.detail = detail
        self.terminal = terminal
    }
}

/// One merged inbox record per task. Updates to the same task fold into this
/// entry; a genuinely new state flips it back to unread and re-anchors the
/// on-site prompt clock. `updatedAt` — not wall time — is that anchor, so
/// refreshes, window reopenings and restarts never extend or reset a terminal
/// prompt's 30-second lifetime.
public struct ResidentSystemInboxEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { taskKey }
    public let taskKey: String
    public var lastEventID: String
    public var kind: String
    public var title: String
    public var status: String
    public var detail: String
    public var terminal: Bool
    public var isRead: Bool
    public var readAt: Date?
    public var deliveredAt: Date
    public var updatedAt: Date
}

public struct ResidentSystemInboxScope: Codable, Hashable, Sendable {
    public let worldID: String
    public let residentScope: String

    public init(worldID: String, residentScope: String) {
        self.worldID = worldID
        self.residentScope = residentScope
    }
}

public struct ResidentSystemInboxArchive: Codable, Equatable, Sendable {
    public struct Bucket: Codable, Equatable, Sendable {
        public var scope: ResidentSystemInboxScope
        public var entries: [ResidentSystemInboxEntry]

        public init(scope: ResidentSystemInboxScope, entries: [ResidentSystemInboxEntry]) {
            self.scope = scope
            self.entries = entries
        }
    }

    public var buckets: [Bucket]

    public init(buckets: [Bucket]) {
        self.buckets = buckets
    }
}

/// The shared unread truth for system task deliveries across the stage and
/// Live Cam windows. Content comes only from formal projection data; reading
/// is a separate, explicit user action and is never implied by the background
/// consumer's acknowledgement.
///
/// 持久化走统一状态合同（gmgn-taskd inbox 域，由注入的 restore/persist 闭包
/// 承担）。保存是等待式的：apply/markRead 只在可靠落库后才返回 true，失败
/// 如实出现在 persistenceError 且绝不静默重试——同内容的下一次正式投递或
/// 显式读取才是重试入口。读取是独立的显式动作，永远不与后台消费者的确认
/// （ACK）混淆。
@MainActor
public final class ResidentSystemInboxStore: ObservableObject {
    /// 界面只留**一句人话**；失败原因（哪一段、什么错）一条不少地进日志。
    nonisolated static let diagnosticLog = Logger(subsystem: "ai.gmgn.radio", category: "ResidentSystemInbox")
    /// Terminal task prompts hide this many seconds after their last actual
    /// state change; the record itself stays in history and in the badge.
    public static let terminalPromptLifetime: TimeInterval = 30

    @Published private(set) var buckets: [ResidentSystemInboxScope: [ResidentSystemInboxEntry]] = [:]
    @Published public private(set) var persistenceError: String?

    public typealias Restore = (ResidentSystemInboxScope) async throws -> [ResidentSystemInboxEntry]?
    public typealias Persist = (ResidentSystemInboxScope, [ResidentSystemInboxEntry]) async throws -> Void

    private let clock: () -> Date
    private let restoreHandler: Restore?
    private let persistHandler: Persist?
    /// 仍有未落库失败的作用域：错误保持可见，其内存真相不被恢复覆盖。
    private var failedScopes: Set<ResidentSystemInboxScope> = []
    /// 每作用域串行提交链：后一次提交排在前一次之后，始终携带最新内存内容
    /// 与最新 revision，自身并发不会互相打出 revision_conflict。
    private var commitChains: [ResidentSystemInboxScope: Task<Bool, Never>] = [:]
    private var restoreTasks: [ResidentSystemInboxScope: Task<Void, Never>] = [:]

    public init(clock: @escaping () -> Date = Date.init,
                restore: Restore? = nil,
                persist: Persist? = nil) {
        self.clock = clock
        self.restoreHandler = restore
        self.persistHandler = persist
    }

    /// 恢复一个作用域：优先读已落库记录；闭包也可能返回旧 JSON 归档的导入
    /// 条目（由闭包保证只在该作用域尚无落库记录时返回）。导入内容会立即
    /// 持久化，重复恢复天然幂等。恢复不覆盖仍有未保存失败的作用域。
    public func restore(worldID: String, residentScope: String) async {
        let scope = ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)
        if let running = restoreTasks[scope] { await running.value; return }
        let task = Task<Void, Never> { [weak self] in
            guard let self, let restoreHandler = self.restoreHandler else { return }
            do {
                let entries = try await restoreHandler(scope)
                if let entries, !entries.isEmpty, !self.failedScopes.contains(scope) {
                    self.buckets[scope] = entries.sorted { $0.updatedAt > $1.updatedAt }
                    if self.failedScopes.isEmpty { _ = await self.persistIfNeeded(scope) }
                }
            } catch {
                self.failedScopes.insert(scope)
                self.persistenceError = "系统消息恢复失败：\(error.localizedDescription)；已显示的内容保留在内存。"
            }
        }
        restoreTasks[scope] = task
        await task.value
    }

    /// Applies one delivery. Duplicate or content-identical projections are
    /// no-ops: they never reset read state and never re-anchor the prompt
    /// (unless a previous save failed — then the identical projection retries
    /// it). A genuinely new state merges in place, flips the entry unread and
    /// only reports success once the merged state is durably persisted.
    @discardableResult
    public func apply(_ delivery: ResidentSystemDelivery, worldID: String, residentScope: String) async -> Bool {
        let scope = ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)
        var bucket = buckets[scope] ?? []
        let now = clock()
        if let index = bucket.firstIndex(where: { $0.taskKey == delivery.taskID }) {
            let entry = bucket[index]
            let unchanged = entry.title == delivery.title && entry.status == delivery.status
                && entry.detail == delivery.detail && entry.kind == delivery.kind
                && entry.terminal == delivery.terminal
            guard !unchanged else {
                guard failedScopes.contains(scope) else { return false }
                return await persistIfNeeded(scope)
            }
            var updated = entry
            updated.lastEventID = delivery.eventID
            updated.kind = delivery.kind
            updated.title = delivery.title
            updated.status = delivery.status
            updated.detail = delivery.detail
            updated.terminal = delivery.terminal
            updated.isRead = false
            updated.readAt = nil
            updated.updatedAt = now
            bucket[index] = updated
        } else {
            bucket.insert(ResidentSystemInboxEntry(
                taskKey: delivery.taskID, lastEventID: delivery.eventID, kind: delivery.kind,
                title: delivery.title, status: delivery.status, detail: delivery.detail,
                terminal: delivery.terminal, isRead: false, readAt: nil,
                deliveredAt: now, updatedAt: now), at: 0)
        }
        bucket.sort { $0.updatedAt > $1.updatedAt }
        buckets[scope] = bucket
        return await persistIfNeeded(scope)
    }

    public func entries(worldID: String, residentScope: String) -> [ResidentSystemInboxEntry] {
        buckets[ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)] ?? []
    }

    public func entry(taskKey: String, worldID: String, residentScope: String) -> ResidentSystemInboxEntry? {
        entries(worldID: worldID, residentScope: residentScope).first { $0.taskKey == taskKey }
    }

    public func unreadCount(worldID: String, residentScope: String) -> Int {
        entries(worldID: worldID, residentScope: residentScope).filter { !$0.isRead }.count
    }

    /// Reading is explicit: only the inbox detail's deliberate open calls this.
    /// Success means the read state is durably persisted, not merely applied.
    @discardableResult
    public func markRead(taskKey: String, worldID: String, residentScope: String) async -> Bool {
        let scope = ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)
        guard var bucket = buckets[scope],
              let index = bucket.firstIndex(where: { $0.taskKey == taskKey }),
              !bucket[index].isRead else { return false }
        bucket[index].isRead = true
        bucket[index].readAt = clock()
        buckets[scope] = bucket
        return await persistIfNeeded(scope)
    }

    /// When the task's on-site prompt stops showing: `nil` for non-terminal
    /// tasks (they persist), or 30s after the last actual change for terminal
    /// ones. Expiry only hides the prompt; history and the badge are unaffected.
    public func promptExpiry(taskKey: String, worldID: String, residentScope: String) -> Date? {
        guard let entry = entry(taskKey: taskKey, worldID: worldID, residentScope: residentScope),
              entry.terminal else { return nil }
        return entry.updatedAt.addingTimeInterval(Self.terminalPromptLifetime)
    }

    public func visibleEntries(worldID: String, residentScope: String, now: Date? = nil) -> [ResidentSystemInboxEntry] {
        let now = now ?? clock()
        return entries(worldID: worldID, residentScope: residentScope).filter { entry in
            !entry.terminal || now < entry.updatedAt.addingTimeInterval(Self.terminalPromptLifetime)
        }
    }

    /// 提交该作用域的当前内存内容。同作用域提交串行化；任何一次失败可见、
    /// 记入 failedScopes，由下一次显式投递/读取重试——绝不空转重试。
    private func persistIfNeeded(_ scope: ResidentSystemInboxScope) async -> Bool {
        guard persistHandler != nil else { return true }
        let previous = commitChains[scope]
        let task = Task<Bool, Never> { [weak self] in
            guard let self, let persistHandler = self.persistHandler else { return false }
            _ = await previous?.value
            do {
                try await persistHandler(scope, self.buckets[scope] ?? [])
                self.failedScopes.remove(scope)
                if self.failedScopes.isEmpty { self.persistenceError = nil }
                return true
            } catch {
                self.failedScopes.insert(scope)
                // 界面上只有一句人话；哪一段没存上、原始错误是什么，全部进日志。
                Self.diagnosticLog.error(
                    "收件箱落盘失败：scope=\(String(describing: scope), privacy: .public) 条数=\(self.buckets[scope]?.count ?? 0) error=\(error.localizedDescription, privacy: .public)"
                )
                self.persistenceError = "这条系统消息暂时没存上，稍后会自动重试。"
                return false
            }
        }
        commitChains[scope] = task
        return await task.value
    }
}
