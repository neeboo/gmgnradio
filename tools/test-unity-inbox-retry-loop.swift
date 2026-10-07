import Foundation
@testable import UnityMediaHost

// Mock run results verify real loop retry scheduling, not a paid provider.
@MainActor final class RetryLoopTransport: ResidentStateTransport {
    let id = UUID().uuidString
    var acked = false
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        precondition(params["consumer"] == .string("agent"))
        precondition(params["scope"] == .object(["worldID": .string("retry.world"), "residentScope": .string("retry.resident")]))
        if method == "message_ack" {
            guard case let .string(ackID)? = params["id"] else { fatalError() }
            precondition(UUID(uuidString: ackID) == UUID(uuidString: id)); acked = true
            return ["acknowledged": .bool(true)]
        }
        precondition(method == "message_read")
        guard case let .number(after)? = params["after"] else { fatalError() }
        let messages: [ResidentStateJSON] = acked || after >= 1 ? [] : [
            .object(["id": .string(id.lowercased()), "sequence": .number(1), "kind": .string("system_inbox"),
                "payload": .object(["eventID": .string(id), "taskKey": .string("agent-message:" + id)])])]
        return ["messages": .array(messages), "nextCursor": .number(messages.isEmpty ? after : 1)]
    }
}

@main struct InboxRetryLoopTests {
    enum MockFailure: Error { case firstAttempt }
    @MainActor final class CoordinatorBox { var value: UnityResidentInboxAgent! }
    @MainActor static func settle() async { for _ in 0..<150 { await Task.yield() } }
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { print("FAIL: \(label)"); exit(1) }
        }
        var clock = Date(timeIntervalSince1970: 1000)
        let transport = RetryLoopTransport()
        let box = CoordinatorBox()
        var inputs: [ResidentAgentLoop.Input] = []
        var replies: [String] = []
        let loop = ResidentAgentLoop(now: { clock },
            configuration: .init(minimumWakeInterval: 1, backgroundTurnsPerHour: 6),
            run: { input in
                inputs.append(input)
                if inputs.count == 1 {
                    box.value.failed(events: input.events, runID: input.runID)
                    throw MockFailure.firstAttempt
                }
                let entry = ResidentSystemInboxEntry(taskKey: "agent-message:" + transport.id,
                    lastEventID: transport.id, kind: "agent_message", title: "重试测试", status: "pending",
                    detail: "返回确认", terminal: false, isRead: false, readAt: nil,
                    deliveredAt: clock, updatedAt: clock)
                box.value.noteRead(entries: [entry], runID: input.runID)
                try await box.value.complete(events: input.events, runID: input.runID)
                return "已读取并确认消息"
            }, onReply: { replies.append($0) })
        var submissions = 0
        let coordinator = UnityResidentInboxAgent(client: ResidentStateClient(transport: transport),
            scope: .init(worldID: "retry.world", residentScope: "retry.resident"), now: { clock }) { event in
                guard !loop.snapshot.isRunning, !loop.snapshot.isStopped else { return false }
                submissions += 1
                loop.receiveContinuationEvent(event)
                return true
            }
        box.value = coordinator
        try await coordinator.refresh(); loop.tick(); await settle()
        check(inputs.count == 1 && loop.snapshot.lastFailure != nil, "first real scheduler run fails")
        check(inputs[0].events.map(\.id) == [transport.id] && !transport.acked, "failure preserves same durable ID without ACK")
        clock.addTimeInterval(4)
        try await coordinator.refresh(); loop.tick(); await settle()
        check(submissions == 1 && inputs.count == 1, "retry waits until deadline")
        clock.addTimeInterval(1)
        try await coordinator.refresh(); loop.tick(); await settle()
        check(submissions == 2 && inputs.count == 2, "due retry resubmits and real loop launches second run")
        check(inputs[1].events.map(\.id) == [transport.id], "second run receives identical durable event ID")
        check(transport.acked && replies == ["已读取并确认消息"], "second mock run reads proof and emits reply with successful ACK")
        clock.addTimeInterval(61)
        try await coordinator.refresh(); loop.tick(); await settle()
        check(submissions == 2 && inputs.count == 2, "successful consumption prevents further execution")
        coordinator.close(); loop.invalidate()
        print("PASS: \(checks) real loop inbox retry checks (mock run; no provider)")
    }
}
