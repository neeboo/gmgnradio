import Foundation
import WorldRuntime

/// No navigation decisions live here. Native collision measurements answer the
/// Rust router's bounded candidate probes; this is never called by frame ticks.
final class RustWorldActivityClient {
    typealias Call = (String, [String: Any]) throws -> [String: Any]
    private let call: Call
    let hostSessionID = UUID().uuidString
    struct Run: Decodable, Sendable {
        let requestID: String
        let hostSessionID: String
        let generation: UInt64
        let phaseGeneration: UInt64
        let definition: LifeActivityDefinition
        let status: String
        let phase: LifeActivityPhase
        let path: WorldPath
        let target: WorldVector3
        let targetYaw: Float?
        let alignmentYaw: Float?
        let deadlineMs: UInt64?
        let deadlineEligible: Bool
        let activity: LifeActivity?
        let patrolCandidates: [String]?
        let kind: String?
        let coordinateTarget: WorldVector3?
    }
    struct ActivityState: Decodable, Sendable { let generation: UInt64; let hostSessionID: String; let run: Run? }
    struct Mutation: Decodable, Sendable {
        struct Snapshot: Decodable, Sendable {
            struct Record: Decodable, Sendable { let recordRevision: UInt64; let state: WorldState }
            let record: Record?
        }
        let activity: ActivityState
        let snapshot: Snapshot?
        let events: [WorldEvent]?
    }
    private(set) var activityState: ActivityState?
    func acceptConfirmedCatalog(_ receipt: Mutation) throws {
        guard receipt.activity.hostSessionID == hostSessionID else { throw Fault.invalidReceipt }
        activityState = receipt.activity
    }
    var running: Run? { activityState?.run.flatMap { $0.status == "running" && $0.hostSessionID == hostSessionID && $0.kind != "movement" ? $0 : nil } }
    var movement: Run? { activityState?.run.flatMap {
        ($0.status == "running" || $0.status == "replanRequired") && $0.hostSessionID == hostSessionID && $0.kind == "movement" ? $0 : nil
    } }
    init(call: @escaping Call) { self.call = call }
    convenience init(endpointFile: String, helperPath: String) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: false, timeout: 1)
        self.init { try transport.call(method: $0, params: $1) }
    }
    private struct Probe: Decodable { let key: String; let from: WorldVector3; let to: WorldVector3 }
    private struct Receipt: Decodable { let route: WorldPath?; let probes: [Probe]? }
    private enum Fault: Error { case invalidReceipt, unboundedEvidence }
    func finalizeRoute(_ path: WorldPath, start: WorldVector3, destinationID: String,
                       finalTarget: WorldVector3?, destinationKind: String) throws -> WorldPath {
        var input: [String: Any] = ["baseRoute":try json(path),"start":try json(start),
            "destinationID":destinationID,"destinationKind":destinationKind]
        if let finalTarget { input["finalTarget"] = try json(finalTarget) }
        let output = try JSONSerialization.data(withJSONObject:call("world_activity_route",input))
        let receipt = try JSONDecoder().decode(Receipt.self,from:output)
        guard let route = receipt.route, route.destinationID == destinationID else { throw Fault.invalidReceipt }
        return route
    }
    private func json<T: Encodable>(_ v: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return try JSONSerialization.jsonObject(with: encoder.encode(v))
    }
    private func activity(_ method: String, input: [String: Any]) throws -> Mutation {
        let output = try JSONSerialization.data(withJSONObject: call(method, input))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let result = try decoder.decode(Mutation.self, from: output)
        activityState = result.activity
        return result
    }
    @discardableResult
    func bindCatalog(worldID: String, definitions: [LifeActivityDefinition], waypoints: [WorldWaypoint] = [],
                     usageBindings: [String: [String: String]] = [:]) throws -> Mutation {
        try activity("world_activity_bind_catalog", input: ["worldID":worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"definitions":json(definitions),"waypoints":json(waypoints),"usageBindings":usageBindings])
    }
    func start(world: WorldState, expectedRevision: UInt64, definitionID: String,
               capsuleRadius: Float, waitsForRenderedCompletion: Bool,
               measureApproach: (RustPropCapabilityClient.Probe) throws -> RustPropCapabilityClient.Measurement,
               canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool) throws -> Mutation {
        var input: [String: Any] = ["worldID":world.worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"expectedRevision":expectedRevision,"checkpoint":try json(world),
            "expectedLayoutRevision":world.layoutRevision,"definitionID":definitionID,"priority":0,
            "capsuleRadius":capsuleRadius,"traversal":[],
            "waitsForRenderedCompletion":waitsForRenderedCompletion]
        var measuredKeys = Set<String>()
        var traversal: [[String: Any]] = []
        for _ in 0..<4097 {
            let response = try call("world_activity_prepare", input)
            switch response["stage"] as? String {
            case "approach":
                guard input["approachPhysics"] == nil, let geometryID = response["geometryID"] as? String else { throw Fault.invalidReceipt }
                let probes = try JSONDecoder().decode([RustPropCapabilityClient.Probe].self,
                    from: JSONSerialization.data(withJSONObject:response["probes"] ?? NSNull()))
                guard !probes.isEmpty, probes.count <= 4096 else { throw Fault.unboundedEvidence }
                let measurements = try probes.map(measureApproach)
                input["approachPhysics"] = ["geometryID":geometryID,"physics":try json(measurements)]
            case "route":
                let probes = try JSONDecoder().decode([Probe].self,
                    from: JSONSerialization.data(withJSONObject:response["probes"] ?? NSNull()))
                guard !probes.isEmpty, traversal.count + probes.count <= 4096 else { throw Fault.unboundedEvidence }
                for probe in probes {
                    guard measuredKeys.insert(probe.key).inserted else { throw Fault.invalidReceipt }
                    traversal.append(["key":probe.key,"from":try json(probe.from),"to":try json(probe.to),
                        "canTraverse":canTraverse(SIMD3(probe.from.x,probe.from.y,probe.from.z),
                            SIMD3(probe.to.x,probe.to.y,probe.to.z))])
                }
                input["traversal"] = traversal
            case "ready":
                guard let digest = response["planSHA256"] as? String, digest.count == 64,
                      let timestamp = response["preparedAtMS"] as? NSNumber else { throw Fault.invalidReceipt }
                input["planSHA256"] = digest; input["preparedAtMS"] = timestamp
                return try activity("world_activity_start", input:input)
            default: throw Fault.invalidReceipt
            }
        }
        throw Fault.unboundedEvidence
    }
    @MainActor
    func startMeasured(world: WorldState, expectedRevision: UInt64, definitionID: String,
                       capsuleRadius: Float, waitsForRenderedCompletion: Bool,
                       transport: RustPropCapabilityClient,
                       measure: RustPropCapabilityClient.BatchPhysics,
                       validate: () throws -> Void = {}) async throws -> Mutation {
        var input: [String:Any] = ["worldID":world.worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"expectedRevision":expectedRevision,"expectedLayoutRevision":world.layoutRevision,
            "checkpoint":try json(world),"definitionID":definitionID,"priority":0,"capsuleRadius":capsuleRadius,
            "traversal":[],"waitsForRenderedCompletion":waitsForRenderedCompletion]
        var keys=Set<String>(), traversal:[[String:Any]]=[]
        for _ in 0..<4097 {
            try Task.checkCancellation(); try validate()
            let bytes=try JSONSerialization.data(withJSONObject:input,options:[.sortedKeys])
            let output=try await transport.prepareActivity(bytes)
            guard let response=try JSONSerialization.jsonObject(with:output) as? [String:Any] else { throw Fault.invalidReceipt }
            switch response["stage"] as? String {
            case "approach":
                guard input["approachPhysics"] == nil,let geometry=response["geometryID"] as? String else { throw Fault.invalidReceipt }
                let probes=try JSONDecoder().decode([RustPropCapabilityClient.Probe].self,
                    from:JSONSerialization.data(withJSONObject:response["probes"] ?? NSNull()))
                guard !probes.isEmpty,probes.count <= 4096 else { throw Fault.unboundedEvidence }
                let measurements=try await measure(probes)
                guard measurements.count == probes.count,
                      zip(measurements,probes).allSatisfy({$0.key == $1.key && $0.position == $1.position}) else { throw Fault.invalidReceipt }
                input["approachPhysics"]=["geometryID":geometry,"physics":try json(measurements)]
            case "route":
                let probes=try JSONDecoder().decode([Probe].self,
                    from:JSONSerialization.data(withJSONObject:response["probes"] ?? NSNull()))
                guard !probes.isEmpty,traversal.count + probes.count <= 4096 else { throw Fault.unboundedEvidence }
                for probe in probes { guard keys.insert(probe.key).inserted else { throw Fault.invalidReceipt } }
                let raw=probes.map { RustPropCapabilityClient.Probe(key:$0.key,position:$0.to,from:$0.from) }
                let measurements=try await measure(raw)
                guard measurements.count == raw.count,
                      zip(measurements,raw).allSatisfy({$0.key == $1.key && $0.position == $1.position}) else { throw Fault.invalidReceipt }
                for (probe,fact) in zip(probes,measurements) {
                    traversal.append(["key":probe.key,"from":try json(probe.from),"to":try json(probe.to),
                        "canTraverse":fact.grounded != nil && fact.canTraverse])
                }
                input["traversal"]=traversal
            case "ready":
                guard let digest=response["planSHA256"] as? String,digest.count == 64,
                      let timestamp=response["preparedAtMS"] as? NSNumber else { throw Fault.invalidReceipt }
                input["planSHA256"]=digest; input["preparedAtMS"]=timestamp
                try Task.checkCancellation(); try validate()
                let payload=try JSONSerialization.data(withJSONObject:input,options:[.sortedKeys])
                let output=try await transport.startActivity(payload)
                let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                let result=try decoder.decode(Mutation.self,from:output)
                guard result.activity.hostSessionID == hostSessionID else { throw Fault.invalidReceipt }
                activityState=result.activity; return result
            default: throw Fault.invalidReceipt
            }
        }
        throw Fault.unboundedEvidence
    }
    func receipt(world: WorldState, expectedRevision: UInt64, run: Run, kind: String,
                 stop: Bool = false) throws -> Mutation {
        try activity(stop ? "world_activity_stop" : "world_activity_receipt", input:[
            "worldID":world.worldID,"hostSessionID":hostSessionID,"requestID":UUID().uuidString,
            "expectedRevision":expectedRevision,"checkpoint":json(world),"runRequestID":run.requestID,
            "generation":run.generation,"phaseGeneration":run.phaseGeneration,"phase":run.phase.rawValue,"kind":kind])
    }
    func stopUnknown(world: WorldState, expectedRevision: UInt64) throws -> Mutation {
        guard let activityState else { throw Fault.invalidReceipt }
        return try activity("world_activity_stop", input:["worldID":world.worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"expectedRevision":expectedRevision,"checkpoint":json(world),
            "generation":activityState.generation,"reconcileUnknown":true])
    }
    func continuePatrol(world: WorldState, expectedRevision: UInt64, run: Run, targetID: String,
                        path: WorldPath, rejectedTargets: [String]) throws -> Mutation {
        try activity("world_activity_continue", input:["worldID":world.worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"expectedRevision":expectedRevision,"checkpoint":json(world),
            "runRequestID":run.requestID,"generation":run.generation,"phaseGeneration":run.phaseGeneration,
            "phase":run.phase.rawValue,"targetID":targetID,"path":json(path),"rejectedTargets":rejectedTargets])
    }
    func move(world: WorldState, expectedRevision: UInt64, path: WorldPath, movementRequestID: String,
              coordinateTarget: WorldVector3? = nil) throws -> Mutation {
        var input:[String:Any] = ["worldID":world.worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"expectedRevision":expectedRevision,"checkpoint":try json(world),
            "priority":0,"path":try json(path),"movementRequestID":movementRequestID]
        if let coordinateTarget { input["coordinateTarget"] = try json(coordinateTarget) }
        return try activity("world_activity_move",input:input)
    }
    func replan(world: WorldState, expectedRevision: UInt64, run: Run, path: WorldPath) throws -> Mutation {
        try activity("world_activity_replan",input:["worldID":world.worldID,"hostSessionID":hostSessionID,
            "requestID":UUID().uuidString,"expectedRevision":expectedRevision,"checkpoint":json(world),
            "runRequestID":run.requestID,"generation":run.generation,"phaseGeneration":run.phaseGeneration,
            "phase":run.phase.rawValue,"path":json(path)])
    }
    func route(manifest: WorldManifest, start: WorldVector3, destinationID: String,
               canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool) throws -> WorldPath {
        try measuredRoute(manifest: manifest, start: start, destinationID: destinationID, canTraverse: canTraverse)
    }
    func coordinateRoute(manifest: WorldManifest, start: WorldVector3, target: WorldVector3,
                         destinationID: String, ground: Float?, occupable: Bool, startOccupable: Bool,
                         canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool) throws -> WorldPath {
        let groundValue: Any = ground.flatMap { $0.isFinite ? $0 : nil }.map { $0 as Any } ?? NSNull()
        return try measuredRoute(manifest:manifest,start:start,destinationID:destinationID,
            extra:["coordinateTarget":json(target),"coordinateGroundHeight":groundValue,
                "coordinateOccupable":occupable,"startOccupable":startOccupable],canTraverse:canTraverse)
    }
    private func measuredRoute(manifest: WorldManifest, start: WorldVector3, destinationID: String,
                              extra: [String: Any] = [:], canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool) throws -> WorldPath {
        func value<T: Encodable>(_ v: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(v))
        }
        var facts: [String: Bool] = [:]
        var base: [String: Any] = ["start": try value(start), "destinationID": destinationID,
            "waypoints": try value(manifest.waypoints), "routes": try value(manifest.routes)]
        base.merge(extra) { _, new in new }
        // Every reply must introduce a new measured segment. The graph has at
        // most N entries plus two directed edges per authored adjacent pair.
        let coordinate = extra["coordinateTarget"] != nil
        let budget = manifest.waypoints.count * (coordinate ? 2 : 1) + manifest.routes.reduce(0) { $0 + max(0, $1.waypointIDs.count - 1) * 2 } + 2
        for _ in 0..<budget {
            var input = base; input["facts"] = facts
            let output = try JSONSerialization.data(withJSONObject: call("world_activity_route", input))
            let receipt = try JSONDecoder().decode(Receipt.self, from: output)
            if let path = receipt.route {
                guard path.destinationID == destinationID, receipt.probes == nil,
                      path.points.count == path.waypointIDs.count + (coordinate ? 1 : 0),
                      path.totalLength.isFinite, path.totalLength >= 0,
                      path.arrivalTolerance.isFinite, path.arrivalTolerance >= 0 else { throw Fault.invalidReceipt }
                return path
            }
            guard let probes = receipt.probes, !probes.isEmpty,
                  probes.allSatisfy({ facts[$0.key] == nil }) else { throw Fault.invalidReceipt }
            for probe in probes {
                facts[probe.key] = canTraverse(SIMD3(probe.from.x, probe.from.y, probe.from.z),
                    SIMD3(probe.to.x, probe.to.y, probe.to.z))
            }
        }
        throw Fault.unboundedEvidence
    }
}
