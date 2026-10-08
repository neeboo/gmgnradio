import Foundation

enum RustMarbleControlError: Error { case invalidResponse, unavailable, executionUnknown }

/// Projection and authenticated transport only. Polling and completion are Rust decisions.
actor RustMarbleControlClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct World: Codable, Sendable, Equatable {
        struct Semantics: Codable, Sendable, Equatable { let metricScale: Double; let groundPlaneOffset: Double }
        struct Splat: Codable, Sendable, Equatable { let quality: String; let url: URL }
        let id: String
        let name: String
        let model: String?
        let thumbnailURL: URL?
        let colliderURL: URL?
        let colliderCoordinates: String
        let semantics: Semantics
        let splatFallbacks: [Splat]
    }
    struct Package: Decodable, Sendable, Equatable {
        let worldID: String
        let manifestSHA256: String
        let packageID: String
        let packageVersion: String
    }
    struct TaskState: Decodable, Sendable {
        let taskID: String
        let hostSessionID: String
        let generation: UInt64
        let status: String
        let phase: String
        let presetID: String?
        let operationID: String?
        let worldID: String?
        let world: World?
        let progress: Int?
        let errorCode: String?
        let errorMessage: String?
        let package: Package?
    }
    struct Action: Decodable, Sendable {
        let actionID: String
        let taskID: String
        let hostSessionID: String
        let generation: UInt64
        let kind: String
        let method: String?
        let path: String?
        private let body: RustMarbleJSON?
        let world: World?
        let dueAtMS: UInt64
        let status: String
        var bodyData: Data? { get throws { try body.map { try JSONEncoder().encode($0) } } }
    }
    struct Snapshot: Decodable, Sendable {
        let revision: UInt64
        let worlds: [World]
        let selectedWorldID: String?
        let presetWorldIDs: [String: String]
        let presetPackages: [String: Package]
        let task: TaskState?
        let action: Action?
        let waitMS: UInt64?
        let duplicate: Bool?
    }
    struct HTTPFact: Encodable, Sendable {
        let statusCode: Int?
        let bodyBase64: String?
        let transportErrorCode: String?
        init(statusCode: Int, body: Data) {
            self.statusCode = statusCode; bodyBase64 = body.base64EncodedString(); transportErrorCode = nil
        }
        init(transportErrorCode: String) {
            statusCode = nil; bodyBase64 = nil; self.transportErrorCode = transportErrorCode
        }
    }
    struct PackageFact: Encodable, Sendable { let manifestSHA256: String }
    struct PackageFailureFact: Encodable, Sendable { let preparationErrorCode: String }
    let owner: String
    let hostSessionID: String
    private let call: Call
    nonisolated func makeGeometryClient() -> RustMarbleGeometryClient {
        RustMarbleGeometryClient(call: call)
    }
    init(call: @escaping Call, owner: String = "marble.worlds", hostSessionID: String) {
        self.call = call; self.owner = owner; self.hostSessionID = hostSessionID
    }
    init(root: URL, helperPath: String, allowsLaunching: Bool, owner: String = "marble.worlds", hostSessionID: String) {
        self.init(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: helperPath, allowsLaunching: allowsLaunching, owner: owner, hostSessionID: hostSessionID)
    }
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool,
         owner: String = "marble.worlds", hostSessionID: String) {
        self.owner = owner; self.hostSessionID = hostSessionID
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile,
            helperPath: helperPath, allowsLaunching: allowsLaunching, timeout: 5)
        call = { method, bytes in
            guard let params = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw RustMarbleControlError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
    }
    private func request(_ method: String, _ params: [String: Any]) async throws -> Snapshot {
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]), call = self.call
        let raw = try await Task.detached { try call(method, data) }.value
        return try JSONDecoder().decode(Snapshot.self, from: raw)
    }
    func read() async throws -> Snapshot { try await request("marble_control_read", ["owner": owner, "hostSessionID": hostSessionID]) }
    func command(_ op: String, expectedRevision: UInt64, requestID: String = UUID().uuidString,
                 presetID: String? = nil, worldID: String? = nil, pageSize: Int? = nil,
                 savedSelectedWorldID: String? = nil) async throws -> Snapshot {
        var p: [String: Any] = ["owner":owner,"hostSessionID":hostSessionID,"requestID":requestID,
            "expectedRevision":expectedRevision,"op":op]
        p["presetID"] = presetID; p["worldID"] = worldID; p["pageSize"] = pageSize; p["savedSelectedWorldID"] = savedSelectedWorldID
        return try await request("marble_control_command", p)
    }
    func claim(taskID: String, expectedRevision: UInt64, requestID: String? = nil) async throws -> Snapshot {
        try await request("marble_control_action_claim", ["owner":owner,"hostSessionID":hostSessionID,
            "taskID":taskID,"requestID":requestID ?? "marble-claim-\(taskID)-\(expectedRevision)","expectedRevision":expectedRevision])
    }
    func receipt<F: Encodable & Sendable>(_ action: Action, fact: F, requestID: String? = nil) async throws -> Snapshot {
        // Use the original action identity, including after a cancellation/host restart.
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fact))
        return try await request("marble_control_action_receipt", ["owner":owner,"hostSessionID":action.hostSessionID,
            "taskID":action.taskID,"actionID":action.actionID,"generation":action.generation,
            "requestID":requestID ?? "marble-receipt-\(action.actionID)","fact":value])
    }
}

private enum RustMarbleJSON: Codable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([Self]), object([String: Self])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
}
