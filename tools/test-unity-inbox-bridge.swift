import Foundation

struct ResidentSystemInboxScope: Codable, Equatable { let worldID, residentScope: String }
struct ResidentSystemInboxArchive: Codable {
    struct Bucket: Codable { let scope: ResidentSystemInboxScope; let entries: [ResidentSystemInboxEntry] }
    let buckets: [Bucket]
}

// Contract-only entry/transport stubs; bridge, CAS storage and state client
// are the actual production sources. This is not real-App acceptance.
struct ResidentSystemInboxEntry: Codable, Equatable, Sendable {
    let taskKey: String
    var lastEventID, kind, title, status, detail: String
    var terminal, isRead: Bool
    var readAt: Date?
    var deliveredAt, updatedAt: Date
}
@MainActor final class PropTaskDaemonClient {
    init(root: URL, allowsLaunching: Bool) {}
}
@MainActor final class ResidentTaskDaemonStateTransport: ResidentStateTransport {
    init(client: PropTaskDaemonClient) {}
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        fatalError("Regression must not contact taskd")
    }
}
@MainActor final class InboxAuthority: ResidentStateTransport {
    var revision: UInt64 = 1
    var value: [String: ResidentStateJSON]
    var commits = 0
    var failRead = false
    var failReadAfterCommit = false
    init() throws {
        value = try ResidentSystemInboxStateStorage.stateValue([
            .init(taskKey: "task", lastEventID: "event", kind: "completed", title: "Ready", status: "ready", detail: "Detail", terminal: true, isRead: false, readAt: nil, deliveredAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))])
    }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        precondition(params["domain"] == .string("inbox") && params["key"] == .string("entries"))
        if method == "state_read" {
            if failRead { throw ResidentStateError.daemon("transport_unavailable") }
            return ["record": .object(["revision": .number(Double(revision)), "value": .object(value)])]
        }
        precondition(method == "state_commit")
        guard params["expectedRevision"] == .number(Double(revision)) else { throw ResidentStateError.daemon("revision_conflict") }
        guard case let .object(next)? = params["value"] else { fatalError() }
        value = next; revision += 1; commits += 1
        failRead = failReadAfterCommit
        return ["revision": .number(Double(revision)), "replayed": .bool(false)]
    }
}
@main struct InboxRegression {
    @MainActor static func make(_ authority: InboxAuthority, scope: ResidentStateScope? = .init(worldID: "isolated", residentScope: "resident.world.test")) -> UnityInboxBridge {
        UnityInboxBridge(storage: ResidentSystemInboxStateStorage(client: ResidentStateClient(transport: authority)), scope: scope)
    }
    @MainActor static func run(_ bridge: UnityInboxBridge, _ op: String, event: String = "event") async throws -> [String: Any] {
        precondition(bridge.command(["op": op, "taskKey": "task", "expectedEventID": event]))
        for _ in 0..<100 {
            let result = bridge.snapshot()
            if result["status"] as? String == "completed" || result["status"] as? String == "failed" { return result }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Operation did not complete")
    }
    @MainActor static func main() async throws {
        let authority = try InboxAuthority(), bridge = make(authority)
        let initial = try await run(bridge, "inbox.list")
        precondition(initial["unreadCount"] as? Int == 1 && authority.commits == 0)
        authority.failReadAfterCommit = true
        let failed = try await run(bridge, "inbox.read")
        precondition(failed["status"] as? String == "failed" && failed["unreadCount"] as? Int == 1 && authority.commits == 1)
        authority.failRead = false; authority.failReadAfterCommit = false
        let restarted = make(authority)
        let restored = try await run(restarted, "inbox.list")
        precondition(restored["unreadCount"] as? Int == 0 && authority.revision == 2)
        let conflictAuthority = try InboxAuthority(), conflictBridge = make(conflictAuthority)
        _ = try await run(conflictBridge, "inbox.list")
        conflictAuthority.revision += 1
        let conflict = try await run(conflictBridge, "inbox.read")
        precondition(conflict["code"] as? String == "revision_conflict" && conflict["unreadCount"] as? Int == 1 && conflictAuthority.commits == 0)
        let stale = try await run(conflictBridge, "inbox.read", event: "old")
        precondition(stale["code"] as? String == "notification_changed" && conflictAuthority.commits == 0)
        let missing = try await run(make(conflictAuthority, scope: nil), "inbox.list")
        precondition(missing["code"] as? String == "scope_not_configured")
        let closing = make(conflictAuthority)
        _ = try await run(closing, "inbox.list")
        precondition(closing.command(["op": "inbox.read", "taskKey": "task", "expectedEventID": "event"]))
        closing.close()
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(conflictAuthority.commits == 0 && !closing.command(["op": "inbox.list"]))
        print("PASS: list/readback failure/CAS conflict/stale event/scope/close; new bridge restores durable read state")
    }
}
