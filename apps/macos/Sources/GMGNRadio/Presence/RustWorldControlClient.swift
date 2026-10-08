import Foundation
import WorldRuntime

/// Authenticated typed controls. No world rules or completed-state candidate is built here.
actor RustWorldControlClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Identity: Sendable, Equatable {
        let worldID: String
        let residentScope: String
        let hostSessionID: String
    }
    struct Receipt: Decodable, Sendable {
        struct Snapshot: Decodable, Sendable {
            struct Record: Decodable, Sendable { let state: WorldState; let recordRevision: UInt64 }
            let record: Record
        }
        let worldID: String
        let residentScope: String
        let hostSessionID: String
        let requestID: String
        let snapshot: Snapshot
        let events: [WorldEvent]
    }
    enum Failure: Error { case invalidReceipt, unavailable }
    private let call: Call
    init(call: @escaping Call) { self.call = call }
    init(endpointFile: String, helperPath: String) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: false, timeout: 5)
        call = { method, input in
            guard let params = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw Failure.invalidReceipt }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        let call = self.call
        return try await Task.detached(priority: .utility) { try call(method, input) }.value
    }
    private func values(_ identity: Identity) -> [String: Any] {
        ["worldID": identity.worldID, "residentScope": identity.residentScope, "hostSessionID": identity.hostSessionID]
    }
    func perform(identity: Identity, cameras: [WorldCameraAnchor], expectedRevision: UInt64,
                 requestID: String, command: Data, agent: ResidentWorldToolSession.RustDispatchAuthority?, uiRequested: Bool) async throws -> Receipt {
        guard agent != nil || uiRequested else { throw Failure.unavailable }
        var params = values(identity)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        params["cameras"] = try JSONSerialization.jsonObject(with: encoder.encode(cameras))
        let bound = try await rpc("world_control_bind_catalog", params)
        guard let binding = try JSONSerialization.jsonObject(with: bound) as? [String: Any],
              binding["worldID"] as? String == identity.worldID,
              binding["residentScope"] as? String == identity.residentScope,
              binding["hostSessionID"] as? String == identity.hostSessionID,
              let capability = binding["capability"] as? String else { throw Failure.invalidReceipt }
        params = values(identity)
        params["expectedRevision"] = expectedRevision
        params["command"] = try JSONSerialization.jsonObject(with: command)
        if let agent {
            guard agent.worldID == identity.worldID, agent.residentScope == identity.residentScope,
                  agent.hostSessionID == identity.hostSessionID else { throw Failure.invalidReceipt }
            params["authority"] = ["kind": "agent", "runID": agent.runID, "callID": agent.callID, "operationID": agent.operationID]
        } else {
            params["bindingCapability"] = capability
            let intent = try await rpc("world_control_ui_intent", params)
            guard let approved = try JSONSerialization.jsonObject(with: intent) as? [String: Any],
                  let id = approved["intentID"] as? String, let cap = approved["capability"] as? String else { throw Failure.invalidReceipt }
            params.removeValue(forKey: "bindingCapability")
            params["authority"] = ["kind": "ui", "intentID": id, "capability": cap]
        }
        params["requestID"] = requestID
        let output = try await rpc("world_control_command", params)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let receipt = try decoder.decode(Receipt.self, from: output)
        guard receipt.worldID == identity.worldID, receipt.residentScope == identity.residentScope,
              receipt.hostSessionID == identity.hostSessionID, receipt.requestID == requestID,
              receipt.snapshot.record.state.worldID == identity.worldID else { throw Failure.invalidReceipt }
        return receipt
    }
}
