import Foundation

/// Native action executor's projection. All stage and compensation decisions are Rust-owned.
actor RustJukeboxClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Action: Decodable, Sendable { let actionID: String; let kind: String; let status: String }
    struct RunFence: Decodable, Sendable {
        let runRequestID: String
        let generation: UInt64
        let phaseGeneration: UInt64
        let phase: String
    }
    struct View: Decodable, Sendable {
        let compoundID: String
        let state: String
        let action: Action?
        let waitMS: UInt64?
        let errorCode: String?
        let runFence: RunFence?
    }
    enum Fault: Error { case rejected(String), unknown }
    private let call: Call
    private let identity: [String: String]
    init(endpointFile: String, helperPath: String, worldID: String, scopeID: String, hostSessionID: String) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: false, timeout: 30)
        call = { method, data in
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorldAuthorityError.invalidResponse
            }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
        identity = ["worldID": worldID, "scopeID": scopeID, "hostSessionID": hostSessionID]
    }
    init(call: @escaping Call, worldID: String, scopeID: String, hostSessionID: String) {
        self.call = call
        identity = ["worldID": worldID, "scopeID": scopeID, "hostSessionID": hostSessionID]
    }
    private func request(_ method: String, extra: Data) async throws -> View {
        guard var params = try JSONSerialization.jsonObject(with: extra) as? [String: Any] else {
            throw WorldAuthorityError.invalidResponse
        }
        for (key, value) in identity { params[key] = value }
        let encoded = try JSONSerialization.data(withJSONObject: params)
        let call = self.call
        let output = try await Task.detached { try call(method, encoded) }.value
        return try JSONDecoder().decode(View.self, from: output)
    }
    func begin(operation: Data, requestID: String) async throws -> View {
        let fields: [String: Any] = ["requestID": requestID,
            "operation": try JSONSerialization.jsonObject(with: operation)]
        return try await request("jukebox_begin", extra: JSONSerialization.data(withJSONObject: fields))
    }
    func observeActivity() async throws -> RunFence {
        let data = try JSONSerialization.data(withJSONObject: ["worldID": identity["worldID"]!])
        let call = self.call
        let output = try await Task.detached { try call("world_activity_read", data) }.value
        guard let reply = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              let activity = reply["activity"] as? [String: Any],
              let run = activity["run"] as? [String: Any],
              let request = run["requestID"] else { throw WorldAuthorityError.invalidResponse }
        var fields = run; fields["runRequestID"] = request
        return try JSONDecoder().decode(RunFence.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func read(compoundID: String, renderFacts: Data? = nil, cancelRequested: Bool = false) async throws -> View {
        var fields: [String: Any] = ["compoundID": compoundID]
        if let renderFacts { fields["renderFacts"] = try JSONSerialization.jsonObject(with: renderFacts) }
        if cancelRequested { fields["cancelRequested"] = true }
        return try await request("jukebox_read", extra: JSONSerialization.data(withJSONObject: fields))
    }
    func claim(compoundID: String, actionID: String) async throws -> View {
        try await request("jukebox_claim", extra: JSONSerialization.data(withJSONObject:
            ["compoundID": compoundID, "actionID": actionID]))
    }
    func receipt(compoundID: String, actionID: String, outcome: String, facts: Data? = nil,
                 errorCode: String? = nil) async throws -> View {
        var fields: [String: Any] = ["compoundID": compoundID, "actionID": actionID, "outcome": outcome]
        if let facts { fields["facts"] = try JSONSerialization.jsonObject(with: facts) }
        if let errorCode { fields["errorCode"] = errorCode }
        return try await request("jukebox_receipt", extra: JSONSerialization.data(withJSONObject: fields))
    }
}
