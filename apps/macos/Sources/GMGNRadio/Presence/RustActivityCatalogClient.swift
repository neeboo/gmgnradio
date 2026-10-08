import Foundation
import WorldRuntime

/// Rust owns catalog decisions. This adapter only encodes/decodes the existing wire models.
final class RustActivityCatalogClient {
    typealias Call = (String, [String: Any]) throws -> [String: Any]
    private let call: Call
    private var cached: [String: (Data, Data)] = [:]

    init(call: @escaping Call) { self.call = call }

    convenience init(endpointFile: String, helperPath: String) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: false, timeout: 1)
        self.init { try transport.call(method: $0, params: $1) }
    }

    private func request<T: Decodable>(_ method: String, params: [String: Any], as: T.Type,
                                      cacheKey: String? = nil) throws -> T {
        let key = cacheKey ?? method
        let input = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        let output: Data
        if let entry = cached[key], entry.0 == input { output = entry.1 }
        else {
            output = try JSONSerialization.data(withJSONObject: call(method, params))
            // Never cache a failed/undecodable receipt.
            let decoded = try JSONDecoder().decode(T.self, from: output)
            if cached.count >= 256 { cached.removeAll() }
            cached[key] = (input, output)
            return decoded
        }
        return try JSONDecoder().decode(T.self, from: output)
    }

    private func value<T: Encodable>(_ model: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(model))
    }

    private struct CatalogReceipt: Decodable { let definitions: [LifeActivityDefinition] }
    private struct SeatReceipt: Decodable { let definition: LifeActivityDefinition }

    func manifest(_ manifest: WorldManifest) throws -> ActivityCatalog {
        let receipt = try request("activity_manifest_build", params: [
            "activities": value(manifest.activities), "activityDefinitions": value(manifest.activityDefinitions)
        ], as: CatalogReceipt.self)
        return try ActivityCatalog(definitions: receipt.definitions)
    }

    func merge(authored: [LifeActivityDefinition], dynamic: [LifeActivityDefinition]) throws -> ActivityCatalog {
        let receipt = try request("activity_catalog_build", params: [
            "authoredDefinitions": value(authored), "dynamicDefinitions": value(dynamic)
        ], as: CatalogReceipt.self)
        return try ActivityCatalog(definitions: receipt.definitions)
    }

    func seat(activityID: String, objectID: String, displayName: String?) throws -> LifeActivityDefinition {
        var params: [String: Any] = ["activityID": activityID, "objectID": objectID]
        if let displayName { params["displayName"] = displayName }
        return try request("activity_seat_definition", params: params, as: SeatReceipt.self,
            cacheKey: "seat." + activityID).definition
    }
}
