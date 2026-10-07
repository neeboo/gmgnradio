import Foundation

// Compile with the real ResidentStateClient.swift and UnityResidentInboxAgent.swift.
struct ResidentAgentLoop {
    struct Event: Equatable { let id: String; let kind: String; let summary: String }
}
struct ResidentSystemInboxEntry { let taskKey: String; let lastEventID: String }

@MainActor final class InboxTransport: ResidentStateTransport {
    var messages: [ResidentStateCommittedFact] = []
    var acknowledgements: [String] = []
    var failAck = false
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        precondition(params["scope"] == .object(["worldID": .string("world-a"), "residentScope": .string("resident-a")]))
        precondition(params["consumer"] == .string("agent"))
        if method == "message_ack" {
            if failAck { throw ResidentStateError.daemon("test_ack_failed") }
            guard case let .string(id)? = params["id"] else { fatalError() }
            precondition(messages.contains { UUID(uuidString: $0.id) == UUID(uuidString: id) })
            acknowledgements.append(id)
            return ["acknowledged": .bool(true)]
        }
        precondition(method == "message_read")
        guard case let .number(after)? = params["after"] else { fatalError() }
        let page = messages.filter { message in
            Double(message.sequence) > after && !acknowledgements.contains {
                UUID(uuidString: $0) == UUID(uuidString: message.id)
            }
        }
        return ["messages": .array(page.map {
            .object(["sequence": .number(Double($0.sequence)), "id": .string($0.id),
                     "kind": .string($0.kind), "payload": .object($0.payload)])
        }), "nextCursor": .number(page.last.map { Double($0.sequence) } ?? after)]
    }
}

@main struct InboxAgentTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { print("FAIL: \(label)"); exit(1) }
        }
        let transport = InboxTransport(), id = UUID().uuidString
        let key = "agent-message:" + id
        transport.messages = [.init(sequence: 1, id: id.lowercased(), kind: "system_inbox",
            payload: ["eventID": .string(id), "taskKey": .string(key)]),
            .init(sequence: 2, id: UUID().uuidString, kind: "wish.outputReady", payload: [:])]
        var accepted = false, events: [ResidentAgentLoop.Event] = []
        var clock = Date(timeIntervalSince1970: 100)
        let agent = UnityResidentInboxAgent(client: ResidentStateClient(transport: transport),
            scope: .init(worldID: "world-a", residentScope: "resident-a"), now: { clock }) {
                if !accepted { return false }; events.append($0); return true
            }
        try await agent.refresh()
        check(events.isEmpty, "rejected delivery remains retryable")
        accepted = true
        clock.addTimeInterval(5)
        try await agent.refresh(); try await agent.refresh()
        check(events.count == 1 && events[0].kind == "system_inbox", "pending suppresses duplicates and ignores other kinds")
        check(events[0].id == id, "lowercase Rust message ID matches uppercase inbox identity")
        let run = UUID(), otherRun = UUID()
        agent.noteRead(entries: [.init(taskKey: key, lastEventID: id)], runID: otherRun)
        do { try await agent.complete(events: events, runID: run); fatalError("expected missing read failure") }
        catch UnityResidentInboxAgent.ConsumptionError.inboxNotRead {}
        agent.failed(events: events, runID: run)
        check(transport.acknowledgements.isEmpty, "another run read cannot ACK")
        try await agent.refresh()
        check(events.count == 1, "failure retry waits five seconds")
        clock.addTimeInterval(5)
        try await agent.refresh()
        check(events.count == 2, "successful unread run redelivers")
        agent.noteRead(entries: [.init(taskKey: key, lastEventID: id)], runID: run)
        agent.failed(events: [events.last!], runID: run)
        // Duplicate failure callbacks for the same run do not count twice.
        let failedAgain = UUID()
        agent.failed(events: [events.last!], runID: failedAgain)
        try await agent.refresh()
        check(events.count == 2, "second failure waits fifteen seconds")
        clock.addTimeInterval(15)
        try await agent.refresh()
        check(events.count == 3 && transport.acknowledgements.isEmpty, "failed run retries without ACK")
        let retry = UUID()
        agent.noteRead(entries: [.init(taskKey: "wrong", lastEventID: id)], runID: retry)
        do { try await agent.complete(events: [events.last!], runID: retry); fatalError("expected task mismatch failure") }
        catch UnityResidentInboxAgent.ConsumptionError.inboxNotRead {}
        agent.failed(events: [events.last!], runID: retry)
        check(transport.acknowledgements.isEmpty, "task key must match actual read")
        clock.addTimeInterval(29)
        try await agent.refresh()
        check(events.count == 3, "third failure waits thirty seconds")
        clock.addTimeInterval(1)
        try await agent.refresh()
        agent.noteRead(entries: [.init(taskKey: key, lastEventID: id)], runID: retry)
        transport.failAck = true
        try await agent.complete(events: [events.last!], runID: retry)
        check(agent.snapshot()["awaitingAckCount"] as? Int == 1, "successful consumption retained when ACK fails")
        let count = events.count
        transport.failAck = false
        clock.addTimeInterval(5)
        try await agent.refresh()
        check(events.count == count && transport.acknowledgements == [id], "ACK retry does not reexecute consumed message")
        clock.addTimeInterval(120)
        try await agent.refresh()
        check(events.count == count, "successful ACK stops retries")
        agent.close()
        try await agent.refresh()
        check(agent.snapshot()["status"] as? String == "closed", "closed coordinator stops")
        print("PASS: \(checks) durable inbox agent checks")
    }
}
