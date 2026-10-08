import Foundation

/// Explicit migration seam; never installed by default. Rust authorizes background
/// and human model turns, not completion of world actions emitted by those turns.
@MainActor
final class RustResidentSchedulerClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Claim: Decodable, Sendable {
        let claimed: Bool
        let eventID: String?
        let runID: String?
        let hostSessionID: String?
    }
    struct Ticket: Sendable {
        let eventID: String
        let runID: UUID
        let hostSessionID: String
    }
    struct SteeringInput: Sendable {
        let ticket: Ticket
        let messageID: String
        let inputSHA256: String
        let text: String
        var inputRef: [String: Any] {
            ["submissionID": messageID, "inputSHA256": inputSHA256, "imageReferences": [String]()]
        }
    }
    let worldID: String
    let residentScope: String
    let hostSessionID: String
    private let call: Call
    private var queuedEventID: String?

    init(worldID: String, residentScope: String, hostSessionID: String = UUID().uuidString,
         call: @escaping Call) {
        self.worldID = worldID; self.residentScope = residentScope
        self.hostSessionID = hostSessionID; self.call = call
    }

    private func request(_ method: String, _ values: [String: Any]) async throws -> Data {
        var values = values
        values["worldID"] = worldID; values["residentScope"] = residentScope
        let input = try JSONSerialization.data(withJSONObject: values)
        let call = self.call
        return try await Task.detached { try call(method, input) }.value
    }

    func claim(eventID: String, configuration: [String: Any], opportunity: [String: Any],
               nowMillis: Int64) async throws -> Ticket? {
        var configuration = configuration
        configuration["hostSessionID"] = hostSessionID
        _ = try await request("agent_loop_configure", configuration)
        var opportunity = opportunity
        opportunity["eventID"] = eventID
        opportunity["command"] = ["type": "resident_model_turn"]
        let enqueued = try await request("agent_loop_enqueue", opportunity)
        guard let reply = try JSONSerialization.jsonObject(with: enqueued) as? [String: Any],
              reply["enqueued"] as? Bool == true,
              let effectiveEventID = reply["eventID"] as? String, !effectiveEventID.isEmpty else {
            throw ClientError.receiptMismatch
        }
        if let old = queuedEventID, old != effectiveEventID {
            _ = try await request("agent_loop_cancel", ["eventID": old])
        }
        queuedEventID = effectiveEventID
        let runID = UUID()
        let data = try await request("agent_loop_claim", ["runID": runID.uuidString,
            "hostSessionID": hostSessionID, "nowMillis": nowMillis, "eventID": effectiveEventID])
        let claim = try JSONDecoder().decode(Claim.self, from: data)
        guard claim.claimed else { return nil }
        guard claim.eventID == effectiveEventID, claim.runID == runID.uuidString,
              claim.hostSessionID == hostSessionID else {
            // A different pending event is not this host's execution input.
            throw ClientError.receiptMismatch
        }
        return Ticket(eventID: effectiveEventID, runID: runID, hostSessionID: hostSessionID)
    }

    enum ClientError: Error { case receiptMismatch }

    func claimHuman(eventID: String, messageIDs: [String], inputRefs: [String: Any],
                    configuration: [String: Any], nowMillis: Int64) async throws -> Ticket? {
        var configuration = configuration
        configuration["hostSessionID"] = hostSessionID
        configuration["humanTurn"] = true
        _ = try await request("agent_loop_configure", configuration)
        _ = try await request("agent_loop_enqueue", ["eventID": eventID, "intentID": "human-batch",
            "kind": "human", "intentState": "active", "messageIDs": messageIDs,
            "inputRefs": inputRefs, "command": ["type": "resident_human_turn", "messageIDs": messageIDs]])
        let id = UUID()
        let data = try await request("agent_loop_claim", ["runID": id.uuidString,
            "hostSessionID": hostSessionID, "nowMillis": nowMillis, "eventID": eventID])
        let claim = try JSONDecoder().decode(Claim.self, from: data)
        guard claim.claimed else { return nil }
        guard claim.eventID == eventID, claim.runID == id.uuidString, claim.hostSessionID == hostSessionID else {
            throw ClientError.receiptMismatch
        }
        return Ticket(eventID: eventID, runID: id, hostSessionID: hostSessionID)
    }

    func cancelPending(eventID: String) async throws {
        _ = try await request("agent_loop_cancel", ["eventID": eventID])
    }

    private struct SteeringAdmission: Decodable { let admitted: Bool; let delivery: String }
    func admitSteering(_ ticket: Ticket, messageID: String, inputRef: Any) async throws -> (Bool, ResidentSteeringDelivery) {
        let data = try await request("agent_loop_steer_admit", ["eventID": ticket.eventID,
            "runID": ticket.runID.uuidString, "hostSessionID": ticket.hostSessionID,
            "messageID": messageID, "inputRef": inputRef])
        let result = try JSONDecoder().decode(SteeringAdmission.self, from: data)
        let delivery: ResidentSteeringDelivery
        switch result.delivery {
        case "delivered": delivery = .delivered
        case "not_delivered": delivery = .notDelivered
        default: delivery = .unknown
        }
        return (result.admitted, delivery)
    }
    func finishSteering(_ ticket: Ticket, messageID: String, delivery: ResidentSteeringDelivery) async throws {
        let wire = delivery == .notDelivered ? "not_delivered" : delivery.rawValue
        _ = try await request("agent_loop_steer_finish", ["eventID": ticket.eventID,
            "runID": ticket.runID.uuidString, "hostSessionID": ticket.hostSessionID,
            "messageID": messageID, "delivery": wire,
            "receipt": ["providerDelivery": wire]])
    }

    func requestCancellation(_ ticket: Ticket) async throws {
        _ = try await request("agent_loop_cancel", ["eventID": ticket.eventID])
    }

    enum FinishReceipt: Sendable { case terminal, cancellationRequested }

    /// Only call after the invocation has returned, or before it ever started.
    @discardableResult
    func finish(_ ticket: Ticket, outcome: String, invocationStarted: Bool, cancellationConfirmed: Bool = false) async throws -> FinishReceipt {
        if outcome == "cancelled", invocationStarted, !cancellationConfirmed {
            // A local CancellationError cannot confirm remote side effects stopped.
            try await requestCancellation(ticket)
            // A separate trusted native termination receipt may already have
            // confirmed this exact execution. A cancel request is not that receipt.
            let data = try await request("agent_loop_read", [:])
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = value["events"] as? [[String: Any]],
                  events.contains(where: {
                      $0["eventID"] as? String == ticket.eventID
                          && ($0["runID"] as? String).flatMap(UUID.init(uuidString:)) == ticket.runID
                          && $0["hostSessionID"] as? String == ticket.hostSessionID
                          && $0["state"] as? String == "cancelled"
                          && $0["receipt"] as? [String: Any] != nil
                  }) else { return .cancellationRequested }
            if queuedEventID == ticket.eventID { queuedEventID = nil }
            return .terminal
        }
        var values: [String: Any] = ["eventID": ticket.eventID, "runID": ticket.runID.uuidString,
            "hostSessionID": ticket.hostSessionID,
            "receipt": ["kind": "resident_model_turn", "invocationReturned": invocationStarted,
                        "executionNotStarted": !invocationStarted,
                        "invocationStarted": invocationStarted, "outcome": outcome]]
        let method: String
        if outcome == "cancelled" { method = "agent_loop_confirm_cancel" }
        else { method = "agent_loop_complete"; values["status"] = outcome }
        let data = try await request(method, values)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["accepted"] as? Bool == true else { throw ClientError.receiptMismatch }
        if queuedEventID == ticket.eventID { queuedEventID = nil }
        return .terminal
    }
}
