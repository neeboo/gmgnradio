import Foundation

enum RustScreenStateError: Error, Sendable {
    case unavailable, invalidResponse, daemon(String)
    var code: String {
        switch self { case .unavailable: return "screen_state_unavailable"
        case .invalidResponse: return "screen_state_invalid_response"
        case .daemon(let value): return value.utf8.count <= 96 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 } ? value : "screen_state_failed" }
    }
}
actor RustScreenStateClient {
    struct Snapshot: Decodable, Sendable { let worldID: String; let revision: UInt64; let record: WorldScreenPersistence.Record }
    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    private struct Failure: Decodable { let code: String }
    private struct Envelope<T: Decodable>: Decodable { let id: String; let result: T?; let error: Failure? }
    private struct ImportReceipt: Decodable, Sendable { let importedWorlds: Int; let alreadyImported: Bool; let legacyMissing: Bool }
    private let endpointFile: URL
    init(endpointFile: URL) { self.endpointFile = endpointFile }
    private func call<T: Decodable & Sendable>(_ method: String, params: [String: Any], as: T.Type) async throws -> T {
        guard let data = try? Data(contentsOf: endpointFile), let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data) else { throw RustScreenStateError.unavailable }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1", let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4" else { throw RustScreenStateError.invalidResponse }
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/rpc")!, timeoutInterval: 10)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id":id,"method":method,"params":params])
        let body: Data
        do {
            body = try await withCheckedThrowingContinuation { continuation in
                let transport = TaskdHTTPTransport(streaming: false, maximumBytes: 2 * 1024 * 1024,
                    receive: { continuation.resume(returning: $0) }, completion: { error in if let error { continuation.resume(throwing: error) } })
                transport.start(request)
            }
        } catch { throw RustScreenStateError.unavailable }
        guard let reply = try? JSONDecoder().decode(Envelope<T>.self, from: body), reply.id == id else { throw RustScreenStateError.invalidResponse }
        if let failure = reply.error { throw RustScreenStateError.daemon(failure.code) }
        guard let result = reply.result else { throw RustScreenStateError.invalidResponse }
        return result
    }
    func importLegacy(_ url: URL) async throws { _ = try await call("screen_state_import", params: ["legacyPath":url.path], as: ImportReceipt.self) }
    func read(worldID: String) async throws -> Snapshot {
        let snapshot = try await call("screen_state_read", params: ["worldID":worldID], as: Snapshot.self)
        guard snapshot.worldID == worldID else { throw RustScreenStateError.invalidResponse }; return snapshot
    }
    func mutate(worldID: String, objectID: String, expectedRevision: UInt64, requestID: String,
                operation: String, value: Data?) async throws -> Snapshot {
        guard expectedRevision < UInt64(Int64.max) else { throw RustScreenStateError.invalidResponse }
        var params: [String: Any] = ["worldID":worldID,"objectID":objectID,"expectedRevision":expectedRevision,"requestID":requestID,"operation":operation,"value":NSNull()]
        if let value { params["value"] = try JSONSerialization.jsonObject(with: value) }
        let snapshot = try await call("screen_state_mutate", params: params, as: Snapshot.self)
        guard snapshot.worldID == worldID, snapshot.revision == expectedRevision + 1 else { throw RustScreenStateError.invalidResponse }; return snapshot
    }
}
