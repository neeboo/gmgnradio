import Foundation

/// HTTP carries only the real ledger dispatch identity captured by the host.
/// Provider secrets never enter tool arguments or this public-image protocol.
@MainActor
final class RustWishReferenceClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    private let call: Call
    init(call: @escaping Call) { self.call = call }
    convenience init() {
        let root = WorldAuthorityEndpoint.taskServiceRoot()
        let transport = TaskdHTTPAuthorityClient(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path,
            allowsLaunching: false, timeout: 15)
        self.init { method, data in
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidProtocol }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
    }
    enum ClientError: Error { case missingClaim, invalidProtocol }
    func request(_ method: String, authority: ResidentWorldToolSession.RustDispatchAuthority,
                 fields: [String: Any]) async throws -> [String: Any] {
        var params = fields
        params["worldID"] = authority.worldID; params["residentScope"] = authority.residentScope
        params["hostSessionID"] = authority.hostSessionID; params["runID"] = authority.runID
        params["callID"] = authority.callID; params["operationID"] = authority.operationID
        params["toolName"] = authority.toolName
        let data = try JSONSerialization.data(withJSONObject: params)
        let call = self.call
        let output = try await Task.detached { try call(method, data) }.value
        guard let value = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw ClientError.invalidProtocol }
        return value
    }
}
