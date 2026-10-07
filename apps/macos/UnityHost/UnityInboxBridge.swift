import Foundation

/// Shared human and agent inbox access. Never ACKs the task delivery consumer, imports
/// legacy files, starts taskd, or creates a second inbox database.
@MainActor
final class UnityInboxBridge {
    private let storage: ResidentSystemInboxStateStorage
    private let scope: ResidentStateScope?
    private var entries: [ResidentSystemInboxEntry] = []
    private var loaded = false
    private var pending = false
    private var closed = false
    private var generation: UInt64 = 0
    private var emittedGeneration: UInt64?
    private var response: [String: Any] = ["status": "idle", "version": 1]
    private var work: Task<Void, Never>?

    convenience init(root: URL, worldID: String? = nil, residentScope: String? = nil) {
        let taskRoot = root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true)
        let client = ResidentStateClient(transport: ResidentTaskDaemonStateTransport(client:
            PropTaskDaemonClient(root: taskRoot, allowsLaunching: false)))
        let world = worldID ?? ProcessInfo.processInfo.environment["GMGN_UNITY_WORLD_ID"]
        let resident = residentScope ?? ProcessInfo.processInfo.environment["GMGN_UNITY_RESIDENT_SCOPE"]
        let scope = world.flatMap { world in resident.map { ResidentStateScope(worldID: world, residentScope: $0) } }
        self.init(storage: ResidentSystemInboxStateStorage(client: client), scope: scope)
    }

    init(storage: ResidentSystemInboxStateStorage, scope: ResidentStateScope?) {
        self.storage = storage
        self.scope = scope
    }

    /// Reads authority directly without changing the human projection or read flags.
    func readForAgent() async throws -> [ResidentSystemInboxEntry] {
        guard !closed else { throw CancellationError() }
        guard let scope, !scope.worldID.isEmpty, !scope.residentScope.isEmpty else {
            throw InboxFailure(code: "scope_not_configured", message: "尚未指定当前角色的通知范围。")
        }
        let durable = try await storage.readOnly(scope: scope) ?? []
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return durable.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Publishes the notice and its agent wake-up message in one authority commit.
    func postForAgent(id: UUID, title: String, detail: String) async throws -> Bool {
        guard !closed else { throw CancellationError() }
        guard let scope, !scope.worldID.isEmpty, !scope.residentScope.isEmpty else {
            throw InboxFailure(code: "scope_not_configured", message: "尚未指定当前角色的通知范围。")
        }
        guard !pending else { return false }
        pending = true
        defer { pending = false }
        let taskKey = "agent-message:" + id.uuidString
        var durable = try await storage.restore(scope: scope) ?? []
        if let existing = durable.first(where: { $0.taskKey == taskKey }) {
            guard existing.title == title, existing.detail == detail else {
                throw InboxFailure(code: "request_id_conflict", message: "同一消息标识已有不同内容。")
            }
        } else {
            let now = Date()
            let entry = ResidentSystemInboxEntry(taskKey: taskKey, lastEventID: id.uuidString,
                kind: "agent_message", title: title, status: "pending", detail: detail,
                terminal: false, isRead: false, readAt: nil, deliveredAt: now, updatedAt: now)
            durable.append(entry)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try await storage.persist(scope: scope, entries: durable, messages: [
                ResidentStateFact(id: id.uuidString, kind: "system_inbox", payload: [
                    "taskKey": .string(taskKey), "eventID": .string(id.uuidString)])])
            durable = try await storage.restore(scope: scope) ?? []
            guard durable.contains(where: { $0.taskKey == taskKey && $0.lastEventID == id.uuidString && $0.title == title && $0.detail == detail && $0.kind == "agent_message" && !$0.isRead }) else {
                throw InboxFailure(code: "readback_not_confirmed", message: "通知保存尚未确认。")
            }
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        entries = durable; loaded = true; generation &+= 1
        response = ["version": 1, "status": "completed", "operation": "inbox.post"]
        return true
    }

    /// Durable producer shares the same scope/CAS owner as list and read.
    /// A busy reader leaves the event pending with its caller for a later sync.
    func deliver(_ deliveries: [ResidentSystemDelivery]) async throws -> Bool {
        guard !closed, !pending, let scope else { return false }
        pending = true
        defer { pending = false }
        var durable = try await storage.restore(scope: scope) ?? []
        var proposed = durable
        for delivery in deliveries {
            if let index = proposed.firstIndex(where: { $0.taskKey == delivery.taskID }) {
                let old = proposed[index]
                guard old.lastEventID != delivery.eventID else { continue }
                guard old.title != delivery.title || old.status != delivery.status || old.detail != delivery.detail || old.kind != delivery.kind || old.terminal != delivery.terminal else { continue }
                proposed[index].lastEventID = delivery.eventID
                proposed[index].kind = delivery.kind; proposed[index].title = delivery.title
                proposed[index].status = delivery.status; proposed[index].detail = delivery.detail
                proposed[index].terminal = delivery.terminal; proposed[index].isRead = false
                proposed[index].readAt = nil; proposed[index].updatedAt = Date()
            } else {
                let now = Date()
                proposed.append(.init(taskKey: delivery.taskID, lastEventID: delivery.eventID,
                    kind: delivery.kind, title: delivery.title, status: delivery.status,
                    detail: delivery.detail, terminal: delivery.terminal, isRead: false,
                    readAt: nil, deliveredAt: now, updatedAt: now))
            }
        }
        try Task.checkCancellation()
        guard !closed else { return false }
        if proposed != durable {
            try await storage.persist(scope: scope, entries: proposed)
            durable = try await storage.restore(scope: scope) ?? []
            guard proposed.allSatisfy({ expected in durable.contains { actual in
                var normalized = expected
                normalized.deliveredAt = actual.deliveredAt; normalized.updatedAt = actual.updatedAt
                normalized.readAt = actual.readAt
                let readTimeMatches = expected.readAt == nil ? actual.readAt == nil : actual.readAt.map { abs($0.timeIntervalSince(expected.readAt!)) < 0.000001 } == true
                return normalized == actual && readTimeMatches &&
                    abs(expected.deliveredAt.timeIntervalSince(actual.deliveredAt)) < 0.000001 &&
                    abs(expected.updatedAt.timeIntervalSince(actual.updatedAt)) < 0.000001
            } }) else {
                throw InboxFailure(code: "readback_not_confirmed", message: "通知保存尚未确认。")
            }
        }
        guard !closed else { return false }
        entries = durable; loaded = true; generation &+= 1
        response = ["version": 1, "status": "completed", "operation": "inbox.deliver"]
        return true
    }

    /// Accepted is not read: only persist plus authoritative readback may
    /// change the entries exposed by snapshot().
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, !pending, let operation = value["op"] as? String,
              ["inbox.list", "inbox.read", "inbox.post"].contains(operation) else { return false }
        let requestID = value["requestID"] as? String ?? UUID().uuidString
        guard requestID.utf8.count <= 256 else { return false }
        if operation == "inbox.post" {
            guard let rawID = value["messageID"] as? String, let id = UUID(uuidString: rawID),
                  let title = value["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
                  let detail = value["detail"] as? String, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, detail.utf8.count <= 16_384 else { return false }
            pending = true
            work = Task { [weak self] in
                guard let self, !closed else { return }
                // Transfer the command reservation to the shared producer on this actor.
                pending = false
                do {
                    guard try await postForAgent(id: id, title: title, detail: detail) else { return }
                    response["requestID"] = requestID
                    response["messageID"] = id.uuidString
                } catch {
                    guard !closed else { return }
                    response = ["version": 1, "operation": operation, "requestID": requestID,
                        "status": "failed", "code": (error as? InboxFailure)?.code ?? "inbox_unavailable",
                        "message": "通知状态未能确认，请稍后重试。"]
                    generation &+= 1
                }
            }
            return true
        }
        pending = true
        work = Task { [weak self] in
            guard let self else { return }
            var result: [String: Any] = ["version": 1, "operation": operation, "requestID": requestID]
            do {
                try Task.checkCancellation()
                guard let scope, !scope.worldID.isEmpty, !scope.residentScope.isEmpty else {
                    throw InboxFailure(code: "scope_not_configured", message: "尚未指定当前角色的通知范围。")
                }
                if operation == "inbox.list" {
                    let restored = try await storage.restore(scope: scope) ?? []
                    try Task.checkCancellation()
                    entries = restored; loaded = true
                } else {
                    guard loaded else { throw InboxFailure(code: "inbox_not_loaded", message: "请先刷新通知，再打开详情。") }
                    guard let taskKey = value["taskKey"] as? String,
                          let expectedEvent = value["expectedEventID"] as? String,
                          let index = entries.firstIndex(where: { $0.taskKey == taskKey }) else {
                        throw InboxFailure(code: "notification_missing", message: "这条通知已变化，请刷新后重试。")
                    }
                    guard entries[index].lastEventID == expectedEvent else {
                        throw InboxFailure(code: "notification_changed", message: "这条通知已有新内容，请刷新后查看。")
                    }
                    var proposed = entries
                    if !proposed[index].isRead {
                        proposed[index].isRead = true; proposed[index].readAt = Date()
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        try await storage.persist(scope: scope, entries: proposed)
                    }
                    try Task.checkCancellation()
                    let durable = try await storage.restore(scope: scope) ?? []
                    try Task.checkCancellation()
                    guard let actual = durable.first(where: { $0.taskKey == taskKey }),
                          actual.lastEventID == expectedEvent, actual.isRead else {
                        throw InboxFailure(code: "readback_not_confirmed", message: "已读状态尚未确认，未读提示已保留，请刷新后重试。")
                    }
                    // Concurrently delivered entries come from the readback,
                    // never from the optimistic proposed list.
                    entries = durable; result["taskKey"] = taskKey
                }
                result["status"] = "completed"
            } catch {
                result["status"] = "failed"
                let failure = error as? InboxFailure
                let code: String
                if let failure { code = failure.code }
                else if case let ResidentStateError.daemon(remote) = error { code = remote }
                else { code = "inbox_unavailable" }
                result["code"] = code
                result["message"] = failure?.message ?? (code == "revision_conflict"
                    ? "通知已在其他地方更新，未读提示已保留，请刷新后重试。"
                    : "通知状态未能确认，未读提示已保留，请稍后刷新。")
                let safeCodes: Set<String> = ["scope_not_configured", "inbox_not_loaded", "notification_missing", "notification_changed", "readback_not_confirmed", "revision_conflict", "request_id_conflict", "inbox_unavailable"]
                NSLog("[UnityInbox] operation=%@ code=%@", operation, safeCodes.contains(code) ? code : "daemon_rejected")
            }
            if closed { return }
            response = result; generation &+= 1; pending = false
        }
        return true
    }

    func snapshot() -> [String: Any] {
        var output: [String: Any] = ["generation": generation, "pending": pending]
        guard emittedGeneration != generation else { return output }
        emittedGeneration = generation
        output.merge(response) { _, new in new }
        output["entries"] = entries.sorted { $0.updatedAt > $1.updatedAt }.map { entry in
            ["taskKey": entry.taskKey, "lastEventID": entry.lastEventID, "kind": entry.kind,
             "title": entry.title, "status": entry.status, "detail": entry.detail,
             "terminal": entry.terminal, "isRead": entry.isRead,
             "readAt": entry.readAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
             "updatedAt": entry.updatedAt.timeIntervalSince1970] as [String: Any]
        }
        output["unreadCount"] = entries.filter { !$0.isRead }.count
        return output
    }

    // Cancels queued/new work. An authority commit already dispatched may
    // finish durably; cancellation never claims to roll that write back.
    func close() { closed = true; work?.cancel(); work = nil; pending = false }
    private struct InboxFailure: Error { let code: String; let message: String }
}
