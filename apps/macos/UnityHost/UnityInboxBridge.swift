import Foundation

/// Human-read projection only. Never ACKs the task delivery consumer, imports
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

    /// Accepted is not read: only persist plus authoritative readback may
    /// change the entries exposed by snapshot().
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, !pending, let operation = value["op"] as? String,
              ["inbox.list", "inbox.read"].contains(operation) else { return false }
        let requestID = value["requestID"] as? String ?? UUID().uuidString
        guard requestID.utf8.count <= 256 else { return false }
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
