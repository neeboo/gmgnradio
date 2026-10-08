import Foundation

/// Plain conversations own scopes, never world execution claims. Rust owns
/// the native CLI, durable continuation/history and process cancellation.
actor RustChatClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Identity: Sendable, Equatable {
        let backend: String; let scopeID: String; let hostSessionID: String; let requestID: String
    }
    struct Snapshot: Decodable, Sendable {
        let state: String; let reply: String?; let error: String?; let sessionID: String?
    }
    enum ClientError: Error { case busy, invalidProtocol, unknownExecution, failed(String) }
    private let call: Call
    private var active: Identity?
    private var cancelling = false
    private var imports = Set<String>()
    var hasActiveExecution: Bool { active != nil }
    init(call: @escaping Call) { self.call = call }
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool = true) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: allowsLaunching, timeout: 360)
        call = { method, data in
            let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
    }
    private func fields(_ identity: Identity) -> [String: Any] {
        ["backend": identity.backend, "scopeID": identity.scopeID,
         "hostSessionID": identity.hostSessionID, "requestID": identity.requestID]
    }
    private func request(_ method: String, _ values: [String: Any]) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: values); let call = self.call
        return try await Task.detached { try call(method, input) }.value
    }
    func importLegacy(backend: String, scopeID: String, hostSessionID: String, sessionID: String?) async throws {
        let key = backend + "|" + scopeID
        guard !imports.contains(key) else { return }
        let data = try await request("agent_chat_import", ["backend": backend, "scopeID": scopeID,
            "hostSessionID": hostSessionID, "sessionID": sessionID as Any? ?? NSNull()])
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["imported"] is Bool else { throw ClientError.invalidProtocol }
        imports.insert(key)
    }
    struct Continuity: Decodable, Sendable { let sessionID: String?; let historyCount: Int; let freshSession: Bool }
    func continuity(backend: String, scopeID: String, hostSessionID: String) async throws -> Continuity {
        let data = try await request("agent_chat_read", ["backend":backend,"scopeID":scopeID,"hostSessionID":hostSessionID])
        let value = try JSONDecoder().decode(Continuity.self, from: data)
        guard value.historyCount >= 0, value.historyCount <= 6,
              value.freshSession == (value.sessionID == nil && value.historyCount == 0) else { throw ClientError.invalidProtocol }
        return value
    }
    func run(identity: Identity, executable: String, environment: [String: String],
             input: String, userText: String, images: [String] = [],
             dshEntryPoint: String? = nil, persona: String? = nil) async throws -> Snapshot {
        guard active == nil else { throw ClientError.busy }
        active = identity; cancelling = false
        var values = fields(identity)
        values.merge(["executable": executable, "environment": environment, "input": input,
                      "userText": userText, "images": images], uniquingKeysWith: { _, value in value })
        if let dshEntryPoint { values["dshEntryPoint"] = dshEntryPoint }
        if let persona { values["persona"] = persona }
        let started = try JSONSerialization.jsonObject(with: await request("agent_chat_start", values)) as? [String: Any]
        guard started?["requestID"] as? String == identity.requestID,
              let state = started?["state"] as? String,
              ["running", "completed", "failed", "cancelled", "unknown"].contains(state) else { throw ClientError.invalidProtocol }
        while true {
            if Task.isCancelled && !cancelling { try await cancel() }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: await request("agent_chat_read", fields(identity)))
            switch snapshot.state {
            case "completed", "failed", "cancelled":
                if active == identity { active = nil }; return snapshot
            case "unknown": throw ClientError.unknownExecution
            case "running": break
            default: throw ClientError.invalidProtocol
            }
            // Cancellation requests wait for Rust's actual owned runner reap.
            // A locally cancelled sleep never releases this execution lease.
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
    func cancel() async throws {
        guard let identity = active, !cancelling else { return }
        cancelling = true
        do {
        let data = try await request("agent_chat_cancel", fields(identity))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["cancelled"] as? Bool == true else {
            throw ClientError.invalidProtocol
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: await request("agent_chat_read", fields(identity)))
        guard ["completed", "cancelled", "failed"].contains(snapshot.state) else { throw ClientError.unknownExecution }
        // Release only after the cancel RPC reaped its owned runner and a real
        // terminal read confirmed it. A late old read cannot clear a new run.
        if active == identity { active = nil }
        } catch {
            // A start acknowledgement can race an external cancellation. Keep
            // the lease, but allow the same request's idempotent cancel retry.
            if active == identity { cancelling = false }
            throw error
        }
    }
    func reset(backend: String, scopeID: String, hostSessionID: String) async throws {
        let data = try await request("agent_chat_reset", ["backend": backend, "scopeID": scopeID, "hostSessionID": hostSessionID])
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["reset"] as? Bool == true else { throw ClientError.invalidProtocol }
        if active?.scopeID == scopeID { active = nil }
        imports.insert(backend + "|" + scopeID)
    }
}
