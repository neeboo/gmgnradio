import Foundation
import simd
import WorldRuntime
@testable import UnityMediaHost

final class SeatSnapshot: WorldStatePersisting, @unchecked Sendable {
    let state: WorldState
    init(_ state: WorldState) { self.state = state }
    func load() throws -> WorldState? { state }
    func save(_ state: WorldState) throws {}
}

@main struct SofaSeatChecks {
    @MainActor static func main() throws {
        let package = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: package.appendingPathComponent("world.json")))
        let framing = (try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("marble.json"))) as! [String: Any])["framing"] as! [String: Any]
        let origin = framing["origin"] as! [NSNumber]
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: package.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ,
                origin: SIMD3(origin[0].floatValue, origin[1].floatValue, origin[2].floatValue),
                uniformScale: (framing["scale"] as! NSNumber).floatValue))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let input = CommandLine.arguments[2]
        let stateData: Data
        if input.hasSuffix(".sqlite3") {
            let endpoint = URL(fileURLWithPath: input).deletingLastPathComponent()
                .appendingPathComponent("taskd.endpoint.json")
            let client = WorldAuthorityClient(worldID: manifest.worldID, endpointFile: endpoint.path,
                helperPath: URL(fileURLWithPath: "target/release/gmgn-taskd").path, allowsLaunching: false)
            guard let record = try client.snapshot() else { fatalError("Current authority snapshot is missing") }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            stateData = try encoder.encode(record.state)
        } else {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as! [String: Any]
            let record = root["record"] as! [String: Any]
            stateData = try JSONSerialization.data(withJSONObject: record["state"]!)
        }
        var state = try decoder.decode(WorldState.self, from: stateData)
        state.activeActivity = nil // An isolated test cannot adopt a running renderer lease.
        let sofaID = "wish-prop-72c0e260-3789-4bd7-8fc3-0ecbcb3867b1"
        var sofa = state.objectStates[sofaID]!
        sofa.isEnabled = true
        state.objectStates[sofaID] = sofa
        let calibrated = sofa.seatCalibration!.resolve(objectID: sofaID, state: sofa)!
        precondition(calibrated.contactPoint.y > sofa.transform.position.y + 0.4)
        var moved = sofa
        moved.transform = WorldTransform(position: .init(x: 9,y: 2,z: -11),
            rotation: .init(x: 0,y: sin(.pi/4),z: 0,w: cos(.pi/4)), scale: .init(x: 99,y: 99,z: 99))
        let rotated = moved.seatCalibration!.resolve(objectID: sofaID, state: moved)!
        let local = WorldPropSeatCalibration.inspectedThreeSeatSofa.contactPoint
        let sourceSize = WorldPropSeatCalibration.inspectedThreeSeatSofa.sourceSize
        let size = sofa.generatedProp!.effectiveSize
        precondition(abs(rotated.contactPoint.x-(9+local.z*size.z/sourceSize.z)) < 0.001)
        precondition(abs(rotated.contactPoint.z-(-11-local.x*size.x/sourceSize.x)) < 0.001)
        precondition(abs(rotated.facingYaw - .pi * 1.5) < 0.001)
        let resizedProp = moved.generatedProp!.withSize(.init(x: size.x*2,y: size.y*2,z: size.z*2))
        moved.metadata["gmgn.generated-prop.v1"] = String(data: try JSONEncoder().encode(resizedProp), encoding: .utf8)!
        let resized = moved.seatCalibration!.resolve(objectID: sofaID, state: moved)!
        precondition(abs(resized.contactPoint.y-(2+local.y*size.y*2/sourceSize.y)) < 0.001)
        moved.isEnabled = false
        precondition(moved.seatCalibration!.resolve(objectID: sofaID, state: moved) == nil)
        let collision = MarbleLivingCabinCollisionWorld(environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes))
        let context = try WorldAgentContext(manifest: manifest, persistence: SeatSnapshot(state), initialCollisionWorld: collision)
        precondition(context.snapshot.activities.contains { $0.id == calibrated.activityID && $0.seat == calibrated })
        let start = context.state.agentTransform.position
        try context.startActivity(id: calibrated.activityID)
        precondition(context.activeSeatProjection == nil, "Never seat before the actual approach has completed")
        for _ in 0..<2400 {
            if context.runningActivity?.phase == .loop { break }
            try context.tick(deltaTime: 1.0/30)
        }
        precondition(context.runningActivity?.phase == .loop)
        precondition(context.activeSeatProjection == calibrated)
        let end = context.state.agentTransform.position
        precondition(hypot(end.x-calibrated.approachPoint.x,end.z-calibrated.approachPoint.z) < 0.06)
        precondition(hypot(end.x-start.x,end.z-start.z) > 0.1, "Movement must go to current sofa, not replay spawn sit")
        let bridge = UnityActivityBridge(context: context)
        precondition(bridge.snapshot()["seatObjectID"] as? String == sofaID)
        var receipt: [String: Any] = ["worldID": manifest.worldID, "requestID": context.currentActivityRequestID!,
            "phase": "loop", "position": [Double(end.x),Double(end.y),Double(end.z)],
            "seatReady": true, "seatObjectID": sofaID, "seatPosition": [0.0,0.0,0.0]]
        precondition(!bridge.acknowledgeProjection(receipt), "An old/spawn pelvis cannot authorize seated completion")
        receipt["seatPosition"] = [Double(calibrated.contactPoint.x),Double(calibrated.contactPoint.y),Double(calibrated.contactPoint.z)]
        precondition(bridge.acknowledgeProjection(receipt))
        try context.stopActivity()
        precondition(context.activeSeatProjection == nil)
        state.objectStates[sofaID]!.isEnabled = false
        let withdrawn = try WorldAgentContext(manifest: manifest, persistence: SeatSnapshot(state), initialCollisionWorld: collision)
        precondition(!withdrawn.snapshot.activities.contains { $0.id == calibrated.activityID })
        do { try withdrawn.startActivity(id: calibrated.activityID); fatalError("Withdrawn sofa must reject") }
        catch WorldAgentContextError.unknownActivity(_) { }
        print("PASS: immutable sofa identity, actual seat height, relocated/rotated sizing, collision-checked approach, real pelvis receipt gate, withdrawal and stop cleanup")
    }
}
