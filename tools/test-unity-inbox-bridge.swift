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
struct ResidentSystemDelivery {
    let eventID, taskID, kind, title, status, detail: String
    let terminal: Bool
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
    var messages: [ResidentStateJSON] = []
    init() throws {
        value = try ResidentSystemInboxStateStorage.stateValue([
            .init(taskKey: "task", lastEventID: "event", kind: "completed", title: "Ready", status: "ready", detail: "Detail", terminal: true, isRead: false, readAt: nil, deliveredAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))])
    }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        precondition(params["domain"] == .string("inbox") && params["key"] == .string("entries"))
        guard params["scope"] == ResidentStateScope(worldID: "isolated", residentScope: "resident.world.test").nestedParam else {
            throw ResidentStateError.daemon("scope_rejected")
        }
        if method == "state_read" {
            if failRead { throw ResidentStateError.daemon("transport_unavailable") }
            return ["record": .object(["revision": .number(Double(revision)), "value": .object(value)])]
        }
        precondition(method == "state_commit")
        guard params["expectedRevision"] == .number(Double(revision)) else { throw ResidentStateError.daemon("revision_conflict") }
        guard case let .object(next)? = params["value"] else { fatalError() }
        value = next; revision += 1; commits += 1
        if case let .array(posted)? = params["messages"] { messages += posted }
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
        let agentAuthority = try InboxAuthority(), agentBridge = make(agentAuthority)
        let beforeLoad = try await agentBridge.readForAgent()
        precondition(beforeLoad.first?.title == "Ready" && !beforeLoad[0].isRead && agentAuthority.commits == 0)
        let noticeID = UUID()
        let posted = try await agentBridge.postForAgent(id: noticeID, title: "Agent notice", detail: "Read this real notice")
        precondition(posted && agentAuthority.commits == 1 && agentAuthority.messages.count == 1)
        let agentRead = try await agentBridge.readForAgent()
        let notice = agentRead.first { $0.taskKey == "agent-message:" + noticeID.uuidString }!
        precondition(notice.lastEventID == noticeID.uuidString && notice.title == "Agent notice" && notice.detail == "Read this real notice" && notice.status == "pending" && !notice.isRead && notice.readAt == nil)
        precondition(agentAuthority.messages[0] == .object(["id": .string(noticeID.uuidString), "kind": .string("system_inbox"), "payload": .object(["taskKey": .string(notice.taskKey), "eventID": .string(noticeID.uuidString)])]))
        let postedAgain = try await agentBridge.postForAgent(id: noticeID, title: notice.title, detail: notice.detail)
        precondition(postedAgain && agentAuthority.commits == 1 && agentAuthority.messages.count == 1)
        do {
            _ = try await agentBridge.postForAgent(id: noticeID, title: "Changed", detail: notice.detail)
            fatalError("Reusing a message ID for changed content must fail")
        } catch {}
        precondition(agentAuthority.commits == 1)
        let commandID = UUID()
        precondition(!agentBridge.command(["op": "inbox.post", "messageID": "invalid", "title": "Notice", "detail": "Content"]))
        precondition(agentBridge.command(["op": "inbox.post", "messageID": commandID.uuidString, "title": "Command notice", "detail": "Command content", "requestID": "post-test"]))
        // Agent access remains available during the UI command reservation.
        _ = try await agentBridge.readForAgent()
        var completedPost = false
        for _ in 0..<100 {
            let output = agentBridge.snapshot()
            if output["requestID"] as? String == "post-test" {
                precondition(output["status"] as? String == "completed" && output["pending"] as? Bool == false)
                completedPost = true; break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(completedPost && agentAuthority.commits == 2 && agentAuthority.messages.count == 2)
        let commandNotice = try await agentBridge.readForAgent().first { $0.lastEventID == commandID.uuidString }
        precondition(commandNotice?.title == "Command notice" && commandNotice?.isRead == false)
        for invalid in [make(agentAuthority, scope: nil), make(agentAuthority, scope: .init(worldID: "other", residentScope: "resident.world.test"))] {
            do { _ = try await invalid.readForAgent(); fatalError("Invalid scope must fail") } catch {}
        }
        agentBridge.close()
        do { _ = try await agentBridge.readForAgent(); fatalError("Closed read must fail") } catch {}
        do { _ = try await agentBridge.postForAgent(id: UUID(), title: "Closed", detail: "Closed"); fatalError("Closed post must fail") } catch {}
        let failedPostAuthority = try InboxAuthority(), failedPostBridge = make(failedPostAuthority)
        failedPostAuthority.failReadAfterCommit = true
        do {
            _ = try await failedPostBridge.postForAgent(id: UUID(), title: "Unconfirmed", detail: "Committed but read unavailable")
            fatalError("Posting must require authoritative readback")
        } catch {}
        precondition(failedPostAuthority.commits == 1 && failedPostAuthority.messages.count == 1)
        precondition(failedPostBridge.snapshot()["generation"] as? UInt64 == 0)
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
        let same = ResidentSystemDelivery(eventID: "event", taskID: "task", kind: "completed", title: "Ready", status: "ready", detail: "Detail", terminal: true)
        let deliveredSame = try await restarted.deliver([same])
        precondition(deliveredSame && authority.commits == 1)
        precondition(restarted.snapshot()["unreadCount"] as? Int == 0)
        let next = ResidentSystemDelivery(eventID: "event-next", taskID: "task", kind: "completed", title: "Placed", status: "placed", detail: "Detail", terminal: true)
        let deliveredNext = try await restarted.deliver([next])
        precondition(deliveredNext && authority.commits == 2)
        precondition(restarted.snapshot()["unreadCount"] as? Int == 1)
        let restoredProducer = try await run(make(authority), "inbox.list")
        precondition(restoredProducer["unreadCount"] as? Int == 1)
        let uncertainAuthority = try InboxAuthority(), uncertainProducer = make(uncertainAuthority)
        _ = try await run(uncertainProducer, "inbox.list")
        uncertainAuthority.failReadAfterCommit = true
        do {
            _ = try await uncertainProducer.deliver([next])
            fatalError("Producer must reject an unconfirmed readback")
        } catch {}
        precondition(uncertainAuthority.commits == 1)
        let unchangedProjection = uncertainProducer.snapshot()
        precondition(unchangedProjection["generation"] as? UInt64 == 1 && unchangedProjection["entries"] == nil)
        uncertainAuthority.failRead = false; uncertainAuthority.failReadAfterCommit = false
        let confirmedProducer = make(uncertainAuthority)
        let restoredUncertain = try await run(confirmedProducer, "inbox.list")
        precondition((restoredUncertain["entries"] as? [[String: Any]])?.first?["lastEventID"] as? String == "event-next")
        _ = try await confirmedProducer.deliver([next])
        precondition(uncertainAuthority.commits == 1)
        let conflictAuthority = try InboxAuthority(), conflictBridge = make(conflictAuthority)
        _ = try await run(conflictBridge, "inbox.list")
        conflictAuthority.revision += 1
        // Reserve a UI write, then read as agent before it dispatches. The agent
        // sees authority revision 2 but must leave the UI CAS owner at revision 1.
        precondition(conflictBridge.command(["op": "inbox.read", "taskKey": "task", "expectedEventID": "event"]))
        let concurrentAgentRead = try await conflictBridge.readForAgent()
        precondition(concurrentAgentRead.first?.isRead == false)
        var pendingConflict: [String: Any] = [:]
        for _ in 0..<100 {
            let output = conflictBridge.snapshot()
            if output["status"] as? String == "failed" { pendingConflict = output; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(pendingConflict["code"] as? String == "revision_conflict" && conflictAuthority.commits == 0)
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
        print("PASS: agent authority read/atomic notice and message/dedup/scope/close; producer dedup/new state/restart; list/readback failure/CAS conflict/stale event/scope/close")
    }
}
