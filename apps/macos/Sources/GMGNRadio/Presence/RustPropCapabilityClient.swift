import Foundation
import WorldRuntime

/// Rust owns every rule and candidate position. Native supplies only measured physics.
actor RustPropCapabilityClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Probe: Decodable, Sendable {
        let key: String
        let position: WorldVector3
        let from: WorldVector3?
    }
    struct Measurement: Encodable, Sendable {
        let key: String
        let position: WorldVector3
        let grounded: WorldVector3?
        let canTraverse: Bool
    }
    typealias BatchPhysics = @MainActor @Sendable ([Probe]) async throws -> [Measurement]
    struct Target: Decodable, Sendable {
        let waypointID: String
        let approachPoint: WorldVector3?
        let standPoint: WorldVector3
        let targetYaw: Float
    }
    struct Resolution: Decodable, Sendable {
        let geometryID: String
        let layoutRevision: UInt64
        let definition: LifeActivityDefinition?
        let usageBinding: [String: String]?
        let target: Target?
        let seatProjection: WorldPropSeatProjection?
        let position: WorldVector3?
    }
    struct PlaceBinding: Decodable, Sendable {
        let objectID: String
        let role: String
        let anchorID: String
        let activityID: String?
        let position: WorldVector3?
        let targetYaw: Float?
    }
    private struct Places: Decodable {
        let worldID: String
        let hostSessionID: String
        let layoutRevision: UInt64
        let places: [String: PlaceBinding]
    }
    private struct Plan: Decodable { let geometryID: String; let probes: [Probe] }
    private struct Catalog: Decodable { let definitions: [LifeActivityDefinition] }
    private struct Seat: Decodable { let definition: LifeActivityDefinition }
    enum Failure: Error { case invalidReceipt, unavailable }
    private let call: Call
    init(call: @escaping Call) { self.call = call }
    init(endpointFile: String, helperPath: String) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: false, timeout: 5)
        call = { method, data in
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidReceipt }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    private func request<T: Decodable>(_ method: String, _ params: [String: Any], as: T.Type) async throws -> T {
        try Task.checkCancellation()
        let input = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]), call = self.call
        let output = try await Task.detached { try call(method, input) }.value
        try Task.checkCancellation()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: output)
    }
    func resolve(worldID: String, hostSessionID: String, objectID: String, layoutRevision: UInt64,
                 kind: String, capsuleRadius: Float, waypoints: [WorldWaypoint],
                 physics: @MainActor @Sendable (Probe) -> Measurement,
                 batchPhysics: BatchPhysics? = nil) async throws -> Resolution {
        var input: [String: Any] = ["worldID":worldID,"hostSessionID":hostSessionID,"objectID":objectID,
            "expectedLayoutRevision":layoutRevision,"kind":kind,"capsuleRadius":capsuleRadius,"waypoints":try json(waypoints)]
        let plan = try await request("world_prop_capability_plan", input, as: Plan.self)
        guard plan.probes.count <= 2688 else { throw Failure.invalidReceipt }
        var measured: [Measurement] = []
        if let batchPhysics { measured = try await batchPhysics(plan.probes) }
        else { for probe in plan.probes {
            try Task.checkCancellation()
            measured.append(await physics(probe))
            if measured.count.isMultiple(of: 16) { await Task.yield() }
        } }
        input["geometryID"] = plan.geometryID; input["physics"] = try json(measured)
        let receipt = try await request("world_prop_capability_resolve", input, as: Resolution.self)
        guard receipt.geometryID == plan.geometryID, receipt.layoutRevision == layoutRevision else { throw Failure.invalidReceipt }
        return receipt
    }
    func seat(activityID: String, objectID: String, displayName: String?) async throws -> LifeActivityDefinition {
        var input: [String: Any] = ["activityID":activityID,"objectID":objectID]
        if let displayName { input["displayName"] = displayName }
        return try await request("activity_seat_definition", input, as: Seat.self).definition
    }
    func places(worldID: String, hostSessionID: String, layoutRevision: UInt64) async throws -> [String: PlaceBinding] {
        let receipt = try await request("world_activity_approach_places", ["worldID":worldID,
            "hostSessionID":hostSessionID,"expectedLayoutRevision":layoutRevision], as: Places.self)
        guard receipt.worldID == worldID, receipt.hostSessionID == hostSessionID,
              receipt.layoutRevision == layoutRevision, receipt.places.count <= 1024,
              receipt.places.allSatisfy({ !$0.key.isEmpty && $0.value.anchorID == "\($0.value.objectID)#\($0.value.role)" })
        else { throw Failure.invalidReceipt }
        return receipt.places
    }
    /// Only identifiers cross this boundary: Rust derives the anchor from authority metadata.
    func approach(worldID: String, hostSessionID: String, objectID: String, layoutRevision: UInt64,
                  kind: String, role: String?, activityID: String?, waypoints: [WorldWaypoint],
                  physics: @MainActor @Sendable (Probe) -> Measurement,
                  batchPhysics: BatchPhysics? = nil) async throws -> Resolution {
        var input: [String: Any] = ["worldID":worldID,"hostSessionID":hostSessionID,"objectID":objectID,
            "expectedLayoutRevision":layoutRevision,"kind":kind,"waypoints":try json(waypoints)]
        if let role { input["role"] = role }
        if let activityID { input["activityID"] = activityID }
        let plan = try await request("world_activity_approach_plan", input, as: Plan.self)
        guard plan.probes.count <= 1025 else { throw Failure.invalidReceipt }
        var measured: [Measurement] = []
        if let batchPhysics { measured = try await batchPhysics(plan.probes) }
        else { for probe in plan.probes {
            try Task.checkCancellation()
            measured.append(await physics(probe))
            if measured.count.isMultiple(of: 16) { await Task.yield() }
        } }
        input["geometryID"] = plan.geometryID; input["physics"] = try json(measured)
        let receipt = try await request("world_activity_approach_resolve", input, as: Resolution.self)
        guard receipt.geometryID == plan.geometryID, receipt.layoutRevision == layoutRevision else { throw Failure.invalidReceipt }
        return receipt
    }
    func merge(authored: [LifeActivityDefinition], dynamic: [LifeActivityDefinition]) async throws -> [LifeActivityDefinition] {
        try await request("activity_catalog_build", ["authoredDefinitions":try json(authored),
            "dynamicDefinitions":try json(dynamic)], as: Catalog.self).definitions
    }
    func prepareActivity(_ input: Data) async throws -> Data {
        try await activityTransport("world_activity_prepare", input)
    }
    func startActivity(_ input: Data) async throws -> Data {
        try await activityTransport("world_activity_start", input)
    }
    private func activityTransport(_ method: String, _ input: Data) async throws -> Data {
        try Task.checkCancellation(); let call=self.call
        let output=try await Task.detached { try call(method,input) }.value
        try Task.checkCancellation(); return output
    }
    func bindCatalog(worldID: String, hostSessionID: String, definitions: [LifeActivityDefinition],
                     waypoints: [WorldWaypoint], usageBindings: [String: [String: String]],
                     routes: [WorldRoute], authoredActivities: [WorldActivityAnchor]) async throws -> RustWorldActivityClient.Mutation {
        try await request("world_activity_bind_catalog", ["worldID":worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"definitions":try json(definitions),"waypoints":try json(waypoints),
            "routes":try json(routes),"authoredActivities":try json(authoredActivities),
            "usageBindings":usageBindings], as: RustWorldActivityClient.Mutation.self)
    }
}
