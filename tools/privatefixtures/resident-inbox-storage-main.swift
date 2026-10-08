import Foundation
@main struct ResidentInboxStorageRegression {
    @MainActor static func main() async throws {
        let fixture = try InboxHTTPFixture(); defer { fixture.cleanup() }; try await fixture.start()
        let scope = ResidentStateScope(worldID: "wish-world", residentScope: "resident-a")
        let inboxScope = ResidentSystemInboxScope(worldID: scope.worldID, residentScope: scope.residentScope)
        let writer = ResidentSystemInboxStateStorage(client: fixture.client())
        let reader = ResidentSystemInboxStateStorage(client: fixture.client())
        try require(try await writer.restore(scope: scope) == nil, "empty scope restores nil")
        let beforeDelivery = Date()
        let first = try await writer.deliver(scope: scope, deliveries: [fixtureDelivery()])
        try require(first.revision == 1 && first.changed && first.unreadCount == 1, "durable delivery revision 1")
        try require(first.entries[0].deliveredAt >= beforeDelivery && first.entries[0].updatedAt <= Date(), "server stamps real delivery clock")
        try require(first.promptExpiries["task"] == first.entries[0].updatedAt.addingTimeInterval(30), "terminal prompt expiry is exactly server anchor plus thirty seconds")
        try require(try await reader.restore(scope: scope) == first.entries, "restored entries and server timestamps exactly preserved")
        let repeated = try await writer.deliver(scope: scope, deliveries: [fixtureDelivery()])
        try require(!repeated.changed && repeated.revision == first.revision && repeated.entries == first.entries, "identical raw event does not advance revision or clocks")
        let marked = try await writer.markRead(scope: scope, taskKey: "task", expectedEventID: "event")
        try require(marked.changed && marked.entries[0].isRead && marked.entries[0].readAt != nil && marked.entries[0].deliveredAt == first.entries[0].deliveredAt && marked.entries[0].updatedAt == first.entries[0].updatedAt, "mark read preserves original daemon timestamps")
        fixture.stop(); try await fixture.start()
        try require(try await reader.restore(scope: scope) == marked.entries, "read state and timestamps survive daemon restart")
        // A stale CAS owner cannot overwrite the winner; same request replays current snapshot.
        let stale = fixture.client(); _ = try await stale.read(scope: inboxScope)
        _ = try await writer.deliver(scope: scope, deliveries: [fixtureDelivery("next", title: "Placed")])
        do { _ = try await stale.markRead(taskKey: "task", expectedEventID: "event", scope: inboxScope); throw InboxFixtureError.verification("stale CAS accepted") }
        catch ResidentStateError.daemon("revision_conflict") {}
        let winner = try await reader.restore(scope: scope)
        try require(winner?.first?.lastEventID == "next" && winner?.first?.isRead == false, "CAS winner remains intact")
        let retryClient = fixture.client(); _ = try await retryClient.read(scope: inboxScope)
        fixture.loseNextMutationReceipt = true
        do { _ = try await retryClient.markRead(taskKey: "task", expectedEventID: "next", scope: inboxScope); throw InboxFixtureError.verification("lost receipt reported success") }
        catch InboxFixtureError.lostReceipt {}
        let recovered = try await retryClient.markRead(taskKey: "task", expectedEventID: "next", scope: inboxScope)
        try require(recovered.replayed && recovered.entries[0].isRead, "unknown receipt retries exact request ID and returns durable read")
        let revision = recovered.revision
        let noOp = try await retryClient.markRead(taskKey: "task", expectedEventID: "next", scope: inboxScope)
        try require(!noOp.changed && noOp.revision == revision, "already read no-op")
        // Read-only legacy migration retains exact subsecond clocks and both read flags.
        let legacyURL = fixture.root.appendingPathComponent("ResidentSystemInbox.json")
        let legacyScope = ResidentSystemInboxScope(worldID: "wish-world", residentScope: "resident-b")
        let legacy = ResidentSystemInboxEntry(taskKey: "task-old", lastEventID: "e0", kind: "wish.task", title: "E2E 咖啡机", status: "已摆放", detail: "网格缺失", terminal: true, isRead: true, readAt: Date(timeIntervalSince1970: 5002.75), deliveredAt: Date(timeIntervalSince1970: 5000.5), updatedAt: Date(timeIntervalSince1970: 5001.25))
        let other = ResidentSystemInboxScope(worldID: "another-world", residentScope: "resident-b")
        try JSONEncoder().encode(ResidentSystemInboxArchive(buckets: [.init(scope: legacyScope, entries: [legacy]), .init(scope: other, entries: first.entries)])).write(to: legacyURL)
        let bytes = try Data(contentsOf: legacyURL)
        let imported = ResidentSystemInboxStateStorage.legacyEntries(from: ResidentSystemInboxStateStorage.legacyArchive(at: legacyURL)!, worldID: legacyScope.worldID, residentScope: legacyScope.residentScope)
        try require(imported == [legacy], "legacy bucket selection preserves read state and subsecond timestamps")
        let importer = fixture.client()
        let importSnapshot = try await importer.importLegacy(imported, scope: legacyScope)
        try require(importSnapshot.legacyImported && importSnapshot.entries == [legacy], "legacy import durably preserves exact DTO")
        let again = try await fixture.client().importLegacy(first.entries, scope: legacyScope)
        try require(again.entries == [legacy] && again.revision == importSnapshot.revision, "durable record wins on reimport without revision inflation")
        try require(try Data(contentsOf: legacyURL) == bytes, "legacy file never rewritten")
        let broken = fixture.root.appendingPathComponent("broken.json"); try Data("not json".utf8).write(to: broken)
        try require(ResidentSystemInboxStateStorage.legacyArchive(at: broken) == nil, "corrupt archive imports nothing")
        let isolated = try await fixture.client().read(scope: other)
        try require(isolated.entries.isEmpty && isolated.revision == 0, "world scopes remain isolated")
        // Outage leaves projection confirmed-only and explicit retry lands durably.
        let outage = fixture.client(); _ = try await outage.read(scope: inboxScope)
        fixture.stop()
        do { _ = try await outage.deliver([fixtureDelivery("after-outage")], scope: inboxScope); throw InboxFixtureError.verification("outage reported durable success") } catch InboxFixtureError.verification(let message) { throw InboxFixtureError.verification(message) } catch {}
        try await fixture.start()
        let afterOutage = try await outage.deliver([fixtureDelivery("after-outage")], scope: inboxScope)
        try require(afterOutage.entries[0].lastEventID == "after-outage", "explicit retry after outage succeeds")
        // Eight independently shaped events, human read, restart, terminal drift.
        let relaunch = ResidentSystemInboxScope(worldID: "wish-world", residentScope: "resident-relaunch")
        let shape: [(String, String, String, String, Bool)] = [
            ("F9682580-DA52-47B5-B10A-B549F09CD23B", "placed", "已摆放", "超大荧幕电视", true),
            ("AEFC68E1-91D4-42F6-AA6A-ED35EDDF9613", "ended", "已删除", "超大荧幕电视", false),
            ("0C285296-9164-4A2B-8FB7-6648E549A4AE", "ended", "已删除", "超大荧幕电视", false),
            ("2F633C0F-A868-4442-AD2A-C73D2A1D04E1", "ended", "已删除", "超大荧幕电视", false),
            ("4210DB95-9253-4CAF-83A3-3C45F090B099", "placed", "已摆放", "2B 白色长剑（外形摆件）", true),
            ("02BFEE6E-82AD-4680-8525-DB2D86791BF1", "placed", "已摆放", "斧头", true),
            ("B8594EB9-AD6C-46D4-A754-99BE7F510042", "placed", "已摆放", "暖光落地灯", true),
            ("EBFC07BE-6AF3-4E25-AF6C-9E795C6E28C6", "placed", "已摆放", "E2E-0907 咖啡机", true),
        ]
        let eight = shape.map { id, state, sentence, name, terminal in
            ResidentSystemDelivery(eventID: "\(id)/wish-prop-\(id.lowercased())#\(state)|\(sentence)", taskID: id, kind: "wish.task", title: "「\(name)」\(sentence)。", status: "", detail: "", terminal: terminal)
        }
        let initial = try await fixture.client().deliver(eight, scope: relaunch)
        try require(initial.entries.count == 8 && initial.unreadCount == 8, "first launch exactly eight distinct unread messages")
        let read = try await fixture.client().markRead(taskKey: eight[0].taskID, expectedEventID: eight[0].eventID, scope: relaunch)
        try require(read.unreadCount == 7, "first launch human read reduces badge to seven")
        fixture.stop(); try await fixture.start()
        let second = try await fixture.client().read(scope: relaunch)
        try require(second.entries == read.entries && second.entries.count == 8 && second.unreadCount == 7, "second launch preserves all entries and read state")
        let drift = eight.map { ResidentSystemDelivery(eventID: $0.eventID, taskID: $0.taskID, kind: $0.kind, title: $0.title, status: $0.status, detail: $0.detail, terminal: !$0.terminal) }
        let redelivered = try await fixture.client().deliver(drift, scope: relaunch)
        try require(redelivered.entries.count == second.entries.count && redelivered.unreadCount == 7, "terminal drift same ID preserves entry count and read count")
        for entry in redelivered.entries {
            let prior = second.entries.first { $0.taskKey == entry.taskKey }!
            try require(entry.lastEventID == prior.lastEventID && entry.isRead == prior.isRead && entry.readAt == prior.readAt && entry.deliveredAt == prior.deliveredAt && entry.updatedAt == prior.updatedAt, "terminal drift preserves exact identity, human flags and original prompt clock")
            try require(entry.terminal != prior.terminal, "host terminal presentation can update without re-anchoring")
            if entry.terminal { try require(redelivered.promptExpiries[entry.taskKey] == prior.updatedAt.addingTimeInterval(30), "new terminal presentation uses original prompt anchor") }
        }
        let third = try await fixture.client().read(scope: relaunch)
        try require(third.entries == redelivered.entries && third.unreadCount == 7, "third launch remains durable")
        try require(try fixture.sqlite("SELECT MAX(version) FROM schema_migrations;") == "29", "real SQLite schema 29")
        try require(Int(try fixture.sqlite("SELECT count(*) FROM inbox_control_requests;"))! > 0, "raw command receipts are persisted in actual SQLite")
        print("PASS: storage raw delivery/read/import; clocks/restart/CAS/unknown-receipt/outage/isolation/eight-message drift; real HTTP and SQLite schema 29")
    }
}
