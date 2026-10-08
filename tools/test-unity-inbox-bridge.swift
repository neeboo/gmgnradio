import Foundation
// Compile/run via: swift tools/test-resident-inbox-state-storage.swift --unity
// Every authority operation is real private taskd HTTP; SQLite confirms receipts.
@main struct InboxRegression {
    @MainActor static func make(_ fixture: InboxHTTPFixture, scope: ResidentStateScope? = .init(worldID: "isolated", residentScope: "resident.world.test")) -> UnityInboxBridge {
        UnityInboxBridge(storage: ResidentSystemInboxStateStorage(client: fixture.client()), scope: scope)
    }
    @MainActor static func run(_ bridge: UnityInboxBridge, _ op: String, event: String = "event") async throws -> [String: Any] {
        try require(bridge.command(["op": op, "taskKey": "task", "expectedEventID": event]), "UI operation accepted")
        return try await completed(bridge)
    }
    @MainActor static func completed(_ bridge: UnityInboxBridge) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let result = bridge.snapshot()
            if result["pending"] as? Bool == false,
               result["status"] as? String == "completed" || result["status"] as? String == "failed" { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw InboxFixtureError.timeout
    }
    @MainActor static func main() async throws {
        let fixture = try InboxHTTPFixture(); defer { fixture.cleanup() }; try await fixture.start()
        let scope = ResidentSystemInboxScope(worldID: "isolated", residentScope: "resident.world.test")
        _ = try await fixture.client().deliver([fixtureDelivery()], scope: scope)
        let bridge = make(fixture)
        let before = try await bridge.readForAgent()
        try require(before.first?.title == "Ready" && before.first?.isRead == false, "agent reads before UI load without human mark")
        let baseline = try fixture.sqlite("SELECT count(*) FROM inbox_control_requests;")
        let id = UUID()
        try require(try await bridge.postForAgent(id: id, title: "Agent notice", detail: "Read this real notice"), "agent atomic post")
        let posted = try await bridge.readForAgent()
        let notice = posted.first { $0.taskKey == "agent-message:" + id.uuidString }
        try require(notice?.lastEventID == id.uuidString && notice?.title == "Agent notice" && notice?.detail == "Read this real notice" && notice?.status == "pending" && notice?.isRead == false && notice?.readAt == nil, "atomic notice complete fields")
        let postRevision = try await fixture.client().read(scope: scope).revision
        try require(try await bridge.postForAgent(id: id, title: "Agent notice", detail: "Read this real notice"), "same message post accepted")
        try require(try await fixture.client().read(scope: scope).revision == postRevision, "same post does not create new revision")
        do { _ = try await bridge.postForAgent(id: id, title: "Changed", detail: "Read this real notice"); throw InboxFixtureError.verification("changed reuse accepted") }
        catch ResidentStateError.daemon("request_id_conflict") {}
        try require(try await fixture.client().read(scope: scope).revision == postRevision, "changed reuse leaves authority intact")
        let commandID = UUID()
        try require(!bridge.command(["op": "inbox.post", "messageID": "invalid", "title": "Notice", "detail": "Content"]), "malformed message ID rejected")
        try require(bridge.command(["op": "inbox.post", "messageID": commandID.uuidString, "title": "Command notice", "detail": "Command content", "requestID": "post-test"]), "UI post accepted")
        _ = try await bridge.readForAgent()
        let command = try await completed(bridge)
        try require(command["requestID"] as? String == "post-test" && command["status"] as? String == "completed" && command["pending"] as? Bool == false, "UI post completed while agent can read")
        let commandNotice = try await bridge.readForAgent().first { $0.lastEventID == commandID.uuidString }
        try require(commandNotice?.title == "Command notice" && commandNotice?.isRead == false, "command notice durable")
        try require(try fixture.sqlite("SELECT count(*) FROM resident_messages WHERE kind='system_inbox';") == "2", "two atomic wake messages; duplicate and conflict add none")
        let messagePayload = try fixture.sqlite("SELECT payload FROM resident_messages WHERE id='" + id.uuidString.lowercased() + "';")
        let payload = try JSONSerialization.jsonObject(with: Data(messagePayload.utf8)) as? [String: String]
        try require(payload == ["taskKey": "agent-message:" + id.uuidString, "eventID": id.uuidString], "atomic wake message exact original task/event payload")
        try require(try fixture.sqlite("SELECT count(*) FROM inbox_control_requests;") != baseline, "real SQLite durable command receipts")
        for invalid in [make(fixture, scope: nil), make(fixture, scope: .init(worldID: "", residentScope: "resident.world.test"))] {
            do { _ = try await invalid.readForAgent(); throw InboxFixtureError.verification("invalid scope read accepted") } catch InboxFixtureError.verification(let m) { throw InboxFixtureError.verification(m) } catch {}
        }
        let other = try await make(fixture, scope: .init(worldID: "other", residentScope: "resident.world.test")).readForAgent()
        try require(other.isEmpty, "other world isolated")
        bridge.close()
        do { _ = try await bridge.readForAgent(); throw InboxFixtureError.verification("closed read accepted") } catch is CancellationError {}
        do { _ = try await bridge.postForAgent(id: UUID(), title: "Closed", detail: "Closed"); throw InboxFixtureError.verification("closed post accepted") } catch is CancellationError {}
        // Lose the transport receipt only AFTER the real durable commit, leaving UI unconfirmed.
        let failedPost = make(fixture); let lostID = UUID(); fixture.loseNextMutationReceipt = true
        do { _ = try await failedPost.postForAgent(id: lostID, title: "Unconfirmed", detail: "Committed, receipt unavailable"); throw InboxFixtureError.verification("lost receipt post accepted") } catch InboxFixtureError.lostReceipt {}
        try require(failedPost.snapshot()["generation"] as? UInt64 == 0, "lost post receipt cannot advance projection")
        try require(try await fixture.client().read(scope: scope).entries.contains { $0.lastEventID == lostID.uuidString }, "unconfirmed post still durable")
        let reader = make(fixture); let initial = try await run(reader, "inbox.list")
        try require(initial["unreadCount"] as? Int == 4, "list includes every actual unread message")
        fixture.loseNextMutationReceipt = true
        let failedRead = try await run(reader, "inbox.read")
        try require(failedRead["status"] as? String == "failed" && failedRead["unreadCount"] as? Int == 4, "lost mark receipt leaves human projection unchanged")
        fixture.stop(); try await fixture.start()
        let restarted = make(fixture); let restored = try await run(restarted, "inbox.list")
        try require(restored["unreadCount"] as? Int == 3, "restart recovers actual committed read")
        let prior = try await fixture.client().read(scope: scope)
        try require(try await restarted.deliver([fixtureDelivery()]), "producer same event accepted")
        let same = try await fixture.client().read(scope: scope)
        try require(same.entries == prior.entries && same.revision == prior.revision, "producer same event preserves human read and clocks")
        try require(try await restarted.deliver([fixtureDelivery("event-next", title: "Placed")]), "producer new state committed")
        let next = try await fixture.client().read(scope: scope)
        try require(next.unreadCount == 4 && next.entries.first { $0.taskKey == "task" }?.lastEventID == "event-next", "new event resets unread")
        let uncertain = make(fixture); _ = try await run(uncertain, "inbox.list"); fixture.loseNextMutationReceipt = true
        do { _ = try await uncertain.deliver([fixtureDelivery("event-third", title: "Third")]); throw InboxFixtureError.verification("producer lost receipt accepted") } catch InboxFixtureError.lostReceipt {}
        let unchanged = uncertain.snapshot()
        try require(unchanged["generation"] as? UInt64 == 1 && unchanged["entries"] == nil, "producer projection not advanced without receipt")
        let confirmed = make(fixture); let third = try await run(confirmed, "inbox.list")
        try require((third["entries"] as? [[String: Any]])?.contains { $0["lastEventID"] as? String == "event-third" } == true, "fresh producer restores uncertain durable event")
        let confirmedRevision = try await fixture.client().read(scope: scope).revision
        _ = try await confirmed.deliver([fixtureDelivery("event-third", title: "Third")])
        try require(try await fixture.client().read(scope: scope).revision == confirmedRevision, "confirmed producer replay does not commit twice")
        let conflict = make(fixture); _ = try await run(conflict, "inbox.list")
        _ = try await fixture.client().deliver([fixtureDelivery("event-fourth", title: "Fourth")], scope: scope)
        let failed = try await run(conflict, "inbox.read", event: "event-third")
        try require(failed["code"] as? String == "revision_conflict", "stale CAS owner fails visibly")
        let failedAgain = try await run(conflict, "inbox.read", event: "event-third")
        try require(failedAgain["code"] as? String == "revision_conflict", "UI stale owner cannot overwrite winner")
        let stale = try await run(conflict, "inbox.read", event: "old")
        try require(stale["code"] as? String == "notification_changed", "stale notification rejected before mutation")
        let refreshedAgent = try await conflict.readForAgent()
        try require(refreshedAgent.first { $0.taskKey == "task" }?.lastEventID == "event-fourth", "agent reads current winner independently of stale display")
        let staleAfterRefresh = try await run(conflict, "inbox.read", event: "event-third")
        try require(staleAfterRefresh["code"] as? String == "notification_changed", "Rust rejects stale displayed event even after agent refresh advances CAS")
        let missing = try await run(make(fixture, scope: nil), "inbox.list")
        try require(missing["code"] as? String == "scope_not_configured", "missing scope fails visibly")
        let closing = make(fixture); _ = try await run(closing, "inbox.list")
        let beforeClose = try await fixture.client().read(scope: scope).revision
        try require(closing.command(["op": "inbox.read", "taskKey": "task", "expectedEventID": "event-fourth"]), "closing UI reserved")
        closing.close(); try await Task.sleep(for: .milliseconds(20))
        let afterClose = try await fixture.client().read(scope: scope).revision
        try require(!closing.command(["op": "inbox.list"]) && afterClose == beforeClose, "close cancels queued operation before dispatch")
        print("PASS: real HTTP/SQLite bridge agent atomic post/dedup/conflict/scope/close; producer/read lost receipts/restart/CAS/stale-event")
    }
}
