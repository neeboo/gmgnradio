import Foundation
@MainActor final class RustResidentIntentClient {
    private let client: ResidentStateClient
    init(client: ResidentStateClient) { self.client = client }
    private func call(_ method: String, scope: ResidentStateScope, extra: [String: ResidentStateJSON] = [:]) async throws -> [String: ResidentStateJSON] {
        var params = extra; params["scope"] = scope.nestedParam
        return try await client.residentIntentCall(method: method, params: params)
    }
    func restore(scope: ResidentStateScope) async throws -> ResidentMemoryStore.PlanValue? {
        let reply = try await call("resident_intent_restore", scope: scope)
        guard let record = reply["record"] else { throw ResidentStateError.invalidResponse }
        if record == .null { return nil }
        let object = try client.requireObject(record); _ = try client.strictUInt64(object["revision"])
        return try ResidentMemoryStore.decodePlan(client.requireObject(object["value"]))
    }
    func enqueue(scope: ResidentStateScope, events: [ResidentAgentLoop.Event]) async throws {
        let tree = try JSONDecoder().decode(ResidentStateJSON.self, from: JSONEncoder().encode(events))
        let response = try await call("resident_intent_enqueue", scope: scope, extra: ["groundedEvents": tree])
        guard response["queued"] == .bool(true) else { throw ResidentStateError.invalidResponse }
    }
    func drain(scope: ResidentStateScope) async throws -> Bool {
        let response = try await call("resident_intent_drain", scope: scope)
        if case let .string(code) = response["errorCode"] { throw ResidentStateError.daemon(code) }
        if response["empty"] == .bool(true) && response["drained"] == .bool(false) { return false }
        guard response["drained"] == .bool(true) else { throw ResidentStateError.invalidResponse }
        let receipt = try client.requireObject(response["receipt"]); _ = try client.strictUInt64(receipt["revision"])
        return true
    }
    func pause(scope: ResidentStateScope, action: String) async throws -> ResidentMemoryStore.PlanValue {
        try await mutation("resident_intent_pause", scope: scope, params: ["action": .string(action), "requestID": .string(UUID().uuidString)])
    }
    func update(scope: ResidentStateScope, runID: UUID, hostSessionID: String, summary: String, status: ResidentAgentLoop.IntentStatus, wakeAfterSeconds: Double?, resumePausedIntent: Bool, plan: ResidentAgentLoop.IntentPlanRevision?, now: Date) async throws -> ResidentMemoryStore.PlanValue {
        var update: [String: ResidentStateJSON] = ["summary": .string(summary), "status": .string(status.rawValue)]
        if let wakeAfterSeconds { update["wakeAfterSeconds"] = .number(wakeAfterSeconds) }
        for (key, value) in [("goal", plan?.goal), ("currentStep", plan?.currentStep), ("advanceWhen", plan?.advanceWhen), ("adjustReason", plan?.adjustReason)] { if let value { update[key] = .string(value) } }
        if let next = plan?.nextSteps { update["nextSteps"] = .array(next.map(ResidentStateJSON.string)) }
        if let source = plan?.source { update["source"] = .string(source.rawValue) }
        return try await mutation("resident_intent_update", scope: scope, params: ["runID": .string(runID.uuidString), "hostSessionID": .string(hostSessionID), "requestID": .string(UUID().uuidString), "resumePausedIntent": .bool(resumePausedIntent), "nowMillis": .number(floor(now.timeIntervalSince1970 * 1000)), "update": .object(update)])
    }
    private func mutation(_ method: String, scope: ResidentStateScope, params: [String: ResidentStateJSON]) async throws -> ResidentMemoryStore.PlanValue {
        let reply = try await call(method, scope: scope, extra: params); let record = try client.requireObject(reply["record"])
        _ = try client.strictUInt64(record["revision"])
        return try ResidentMemoryStore.decodePlan(client.requireObject(record["value"]))
    }
}
