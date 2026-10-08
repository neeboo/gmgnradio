import Foundation
import Combine

/// One user-readable system delivery (wish task progress/completion/failure).
/// This is a projection only: applying it never acknowledges the background
/// consumer, whose ACK semantics stay in the delivery pipeline.
public struct ResidentSystemDelivery: Codable, Equatable, Sendable {
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
/// prompt's 30-second lifetime. `lastEventID` 是那条消息**自己**的幂等键：
/// 同一个 id 就是同一个状态，哪怕文案/终态这一轮漂移了，也不翻回未读、不重锚
/// —— 这正是"重启之后不许再变成未读"的判据。
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

/// Confirmed inbox projection. Raw delivery/read events are resolved by Rust.
@MainActor
public final class ResidentSystemInboxStore: ObservableObject {
    @Published private(set) var buckets: [ResidentSystemInboxScope: [ResidentSystemInboxEntry]] = [:]
    @Published public private(set) var persistenceError: String?
    public typealias Legacy = (ResidentSystemInboxScope) async throws -> [ResidentSystemInboxEntry]?
    private let client: RustInboxClient
    private let clock: () -> Date
    private let legacy: Legacy?
    private var snapshots: [ResidentSystemInboxScope: RustInboxClient.Snapshot] = [:]
    private var restores: [ResidentSystemInboxScope: Task<Void, Never>] = [:]
    public init(client: RustInboxClient? = nil, clock: @escaping () -> Date = Date.init, legacy: Legacy? = nil) {
        self.client = client ?? RustInboxClient(root: WorldAuthorityEndpoint.taskServiceRoot())
        self.clock = clock; self.legacy = legacy
    }
    private func adopt(_ value: RustInboxClient.Snapshot, scope: ResidentSystemInboxScope) {
        guard value.revision >= (snapshots[scope]?.revision ?? 0) else { return }
        snapshots[scope] = value; buckets[scope] = value.entries; persistenceError = nil
    }
    public func restore(worldID: String, residentScope: String) async {
        let scope = ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)
        if let prior = restores[scope] { await prior.value; return }
        let operation = Task { [weak self] in
            guard let self else { return }
            do {
                var value = try await client.read(scope: scope)
                if !value.legacyImported {
                    let entries = try await legacy?(scope) ?? []
                    value = try await client.importLegacy(entries, scope: scope)
                }
                adopt(value, scope: scope)
            } catch { persistenceError = "系统消息读取未能确认，请稍后重试。" }
        }
        restores[scope] = operation
        await operation.value
        restores[scope] = nil
    }
    @discardableResult
    public func apply(_ delivery: ResidentSystemDelivery, worldID: String, residentScope: String) async -> Bool {
        let scope = ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)
        do {
            let value = try await client.deliver([delivery], scope: scope)
            adopt(value, scope: scope); return value.changed
        } catch { persistenceError = "这条系统消息尚未确认保存，请稍后重试。"; return false }
    }
    public func entries(worldID: String, residentScope: String) -> [ResidentSystemInboxEntry] {
        buckets[ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)] ?? []
    }
    public func entry(taskKey: String, worldID: String, residentScope: String) -> ResidentSystemInboxEntry? {
        entries(worldID: worldID, residentScope: residentScope).first { $0.taskKey == taskKey }
    }
    public func unreadCount(worldID: String, residentScope: String) -> Int {
        snapshots[ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)]?.unreadCount ?? 0
    }
    @discardableResult
    public func markRead(taskKey: String, worldID: String, residentScope: String, expectedEventID: String? = nil) async -> Bool {
        let scope = ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)
        guard let event = expectedEventID ?? entry(taskKey: taskKey, worldID: worldID, residentScope: residentScope)?.lastEventID else { return false }
        do {
            let value = try await client.markRead(taskKey: taskKey, expectedEventID: event, scope: scope)
            adopt(value, scope: scope); return value.changed
        } catch { persistenceError = "已读状态未能确认，未读提示已保留，请刷新后重试。"; return false }
    }
    public func promptExpiry(taskKey: String, worldID: String, residentScope: String) -> Date? {
        snapshots[ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)]?.promptExpiries[taskKey]
    }
    public func visibleEntries(worldID: String, residentScope: String, now: Date? = nil) -> [ResidentSystemInboxEntry] {
        let now = now ?? clock()
        return entries(worldID: worldID, residentScope: residentScope).filter {
            guard let expiry = promptExpiry(taskKey: $0.taskKey, worldID: worldID, residentScope: residentScope) else { return true }
            return now < expiry
        }
    }
}
