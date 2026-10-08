import Foundation

extension RustResidentSchedulerClient {
    /// No helper launch and no formal configuration mutation; caller explicitly
    /// supplies the endpoint and the world/resident binding being migrated.
    convenience init(worldID: String, residentScope: String, endpointFile: String,
                     hostSessionID: String = UUID().uuidString) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: "",
            allowsLaunching: false, timeout: 5)
        self.init(worldID: worldID, residentScope: residentScope, hostSessionID: hostSessionID) { method, data in
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClientError.receiptMismatch
            }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
    }
}
