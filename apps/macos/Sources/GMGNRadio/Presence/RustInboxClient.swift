import Foundation

/// Raw typed commands; only taskd may merge entries, set read flags or anchor clocks.
@MainActor
public final class RustInboxClient {
    public typealias Call = @MainActor (String, Data) async throws -> Data
    public struct Snapshot: Codable, Sendable {
        public let revision: Int64
        public let entries: [ResidentSystemInboxEntry]
        public let unreadCount: Int
        public let promptExpiries: [String: Date]
        public let changed: Bool
        public let replayed: Bool
        public let legacyImported: Bool
    }
    private struct Attempt { let fingerprint: Data; let data: Data }
    private let call: Call
    private var snapshots: [ResidentSystemInboxScope: Snapshot] = [:]
    private var attempts: [ResidentSystemInboxScope: Attempt] = [:]
    private var chains: [ResidentSystemInboxScope: Task<Snapshot, Error>] = [:]
    private var chainIDs: [ResidentSystemInboxScope: UUID] = [:]
    public init(call: @escaping Call) { self.call = call }
    convenience init(root: URL, allowsLaunching: Bool = false) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path,
            allowsLaunching: allowsLaunching, timeout: 5)
        self.init(call: { method, data in
            do {
                return try await Task.detached {
                    guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ResidentStateError.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
                }.value
            } catch let TaskdHTTPError.rejected(code) { throw ResidentStateError.daemon(code) }
        })
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func request(_ method: String, data: Data, scope: ResidentSystemInboxScope) async throws -> Snapshot {
        let output = try await call(method, data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(Snapshot.self, from: output)
        guard snapshot.revision >= 0, snapshot.unreadCount >= 0 else { throw ResidentStateError.invalidResponse }
        if snapshot.revision >= (snapshots[scope]?.revision ?? 0) { snapshots[scope] = snapshot }
        return snapshots[scope] ?? snapshot
    }
    public func read(scope: ResidentSystemInboxScope) async throws -> Snapshot {
        try await request("inbox_control_read", data: encode(["scope": scope]), scope: scope)
    }
    private func mutate(_ method: String, scope: ResidentSystemInboxScope, payload: [String: ResidentStateJSON]) async throws -> Snapshot {
        let previous = chains[scope], id = UUID()
        let operation = Task { [self] in
            if let previous { _ = try? await previous.value }
            if snapshots[scope] == nil { _ = try await read(scope: scope) }
            var body = payload
            body["scope"] = .object(["worldID": .string(scope.worldID), "residentScope": .string(scope.residentScope)])
            let fingerprint = try encode(ResidentStateJSON.object(["method": .string(method), "params": .object(body)]))
            let data: Data
            if let attempt = attempts[scope], attempt.fingerprint == fingerprint { data = attempt.data }
            else {
                body["expectedRevision"] = .number(Double(snapshots[scope]!.revision))
                body["requestID"] = .string(id.uuidString)
                data = try encode(body); attempts[scope] = Attempt(fingerprint: fingerprint, data: data)
            }
            do {
                let result = try await request(method, data: data, scope: scope)
                attempts[scope] = nil; return result
            } catch let error as ResidentStateError {
                if error == .daemon("request_id_conflict") || error == .daemon("revision_conflict") { attempts[scope] = nil }
                throw error
            }
        }
        chains[scope] = operation; chainIDs[scope] = id
        defer { if chainIDs[scope] == id { chains[scope] = nil; chainIDs[scope] = nil } }
        return try await operation.value
    }
    private func json<T: Encodable>(_ value: T) throws -> ResidentStateJSON {
        try JSONDecoder().decode(ResidentStateJSON.self, from: encode(value))
    }
    public func deliver(_ deliveries: [ResidentSystemDelivery], scope: ResidentSystemInboxScope) async throws -> Snapshot {
        try await mutate("inbox_control_deliver", scope: scope, payload: ["deliveries": json(deliveries)])
    }
    public func markRead(taskKey: String, expectedEventID: String, scope: ResidentSystemInboxScope) async throws -> Snapshot {
        try await mutate("inbox_control_mark_read", scope: scope, payload: ["taskKey": .string(taskKey), "expectedEventID": .string(expectedEventID)])
    }
    public func post(messageID: String, title: String, detail: String, scope: ResidentSystemInboxScope) async throws -> Snapshot {
        try await mutate("inbox_control_post", scope: scope, payload: ["messageID": .string(messageID), "title": .string(title), "detail": .string(detail)])
    }
    public func importLegacy(_ entries: [ResidentSystemInboxEntry], scope: ResidentSystemInboxScope) async throws -> Snapshot {
        try await mutate("inbox_control_import", scope: scope, payload: ["entries": json(entries)])
    }
}
