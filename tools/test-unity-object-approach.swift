import Foundation
import simd
import WorldRuntime
@testable import UnityMediaHost

// Formal snapshot and actual packaged collider are read-only. All movement is local.
final class ApproachSnapshot: WorldStatePersisting, @unchecked Sendable {
    let state: WorldState
    init(_ state: WorldState) { self.state = state }
    func load() throws -> WorldState? { state }
    func save(_ state: WorldState) throws {}
}
@main struct ObjectApproachChecks {
    @MainActor static func main() throws {
        let package = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = URL(fileURLWithPath: CommandLine.arguments[2])
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: package.appendingPathComponent("world.json")))
        let framing = (try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("marble.json"))) as! [String: Any])["framing"] as! [String: Any]
        let origin = framing["origin"] as! [NSNumber]
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: package.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ,
                origin: SIMD3(origin[0].floatValue, origin[1].floatValue, origin[2].floatValue),
                uniformScale: (framing["scale"] as! NSNumber).floatValue))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot)) as! [String: Any]
        let record = root["record"] as! [String: Any]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(WorldState.self, from: JSONSerialization.data(withJSONObject: record["state"]!))
        let tvID = "wish-prop-f9682580-da52-47b5-b10a-b549f09cd23b"
        let item = state.objectStates[tvID]!, prop = item.generatedProp!
        let collision = MarbleLivingCabinCollisionWorld(environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes))
        let context = try WorldAgentContext(manifest: manifest, persistence: ApproachSnapshot(state),
            initialCollisionWorld: collision)
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { print("FAIL: \(label)"); exit(1) }
        }
        check(context.snapshot.places.contains { $0.id == tvID && $0.displayName == prop.displayName },
              "actual generated television is discoverable by its saved display name and object destination")
        let route = try context.move(to: tvID)
        check(route.destinationID == tvID && route.arrivalTolerance <= 0.05, "route binds actual object with strict arrival")
        let start = context.state.agentTransform.position
        for _ in 0..<1800 {
            if context.currentMovementRequestID == nil { break }
            try context.tick(deltaTime: 1.0 / 30)
        }
        let end = context.state.agentTransform.position
        check(context.currentMovementRequestID == nil &&
            simd_distance(SIMD3(start.x, start.y, start.z), SIMD3(end.x, end.y, end.z)) > 1,
            "real navigation actually moves and completes")
        let rotation = item.transform.rotation
        let propYaw = atan2(2 * rotation.w * rotation.y, 1 - 2 * rotation.y * rotation.y)
        let size = prop.effectiveSize
        let half = WorldVector3(x: size.x * abs(item.transform.scale.x) / 2,
            y: size.y * abs(item.transform.scale.y) / 2, z: size.z * abs(item.transform.scale.z) / 2)
        let edge = WorldPropActivityTemplate.footprintEdgeDistance(from: end,
            propCenter: item.transform.position, propYaw: propYaw, propHalfExtents: half)
        check(edge >= 0.25 && edge <= WorldPropActivityTemplate.interactionReach + 0.001,
            "arrival clears the 0.2m capsule plus margin and is within 0.6m of actual scaled television bounds")
        let yaw = atan2(2 * context.state.agentTransform.rotation.w * context.state.agentTransform.rotation.y,
            1 - 2 * context.state.agentTransform.rotation.y * context.state.agentTransform.rotation.y)
        let expected = atan2(item.transform.position.x - end.x, item.transform.position.z - end.z)
        check(abs(atan2(sin(yaw - expected), cos(yaw - expected))) < 0.01, "arrival faces actual television")
        print("PASS: \(checks) isolated formal-world approach checks; start=\(start) end=\(end) edge=\(edge)m triangles=\(triangles.count)")
    }
}
