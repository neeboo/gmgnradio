import Foundation
import simd
import WorldRuntime

private struct CacheCabinCollision: WorldCollisionQuerying {
    let environment: any WorldCollisionQuerying
    let props: CollisionVolumeWorld
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        environment.canOccupy(capsule, at: position) && props.canOccupy(capsule, at: position)
    }
    func groundHeight(at position: SIMD3<Float>) -> Float? { environment.groundHeight(at: position) }
}

private final class CacheFixturePersistence: WorldStatePersisting, @unchecked Sendable {
    let value: WorldState
    init(_ value: WorldState) { self.value = value }
    func load() throws -> WorldState? { value }
    func save(_ state: WorldState) throws {}
}

private final class CountingCollision: WorldCollisionQuerying, @unchecked Sendable {
    let base: any WorldCollisionQuerying
    var queries = 0
    var blocked = false
    init(_ base: any WorldCollisionQuerying) { self.base = base }
    func groundHeight(at position: SIMD3<Float>) -> Float? {
        queries += 1; return base.groundHeight(at: position)
    }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        queries += 1; return !blocked && base.canOccupy(capsule, at: position)
    }
    func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>, to end: SIMD3<Float>, maximumStepHeight: Float) -> Bool {
        queries += 1; return !blocked && base.canTraverse(capsule, from: start, to: end, maximumStepHeight: maximumStepHeight)
    }
}

// Compile with WorldAgentContext.swift and the arguments from
// tools/world-runtime-harness-flags.sh. Uses exported state, never the database.
@main struct GeneratedPlaceCacheChecks {
    @MainActor static func main() throws {
        let package = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: package.appendingPathComponent("world.json")))
        let framing = (try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("marble.json"))) as! [String: Any])["framing"] as! [String: Any]
        let origin = framing["origin"] as! [NSNumber]
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: package.appendingPathComponent("collider.glb")), transform:
            WorldMeshTransform(axisConversion: .flipYAndZ, origin: SIMD3(origin[0].floatValue, origin[1].floatValue, origin[2].floatValue), uniformScale: (framing["scale"] as! NSNumber).floatValue))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let record = json["record"] as! [String: Any]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var state = try decoder.decode(WorldState.self, from: JSONSerialization.data(withJSONObject: record["state"]!))
        state.activeActivity = nil
        let base = CacheCabinCollision(environment: TriangleMeshCollisionWorld(triangles: triangles), props: CollisionVolumeWorld(volumes: manifest.collisionVolumes))
        let counter = CountingCollision(base)
        let context = try WorldAgentContext(manifest: manifest, persistence: CacheFixturePersistence(state), initialCollisionWorld: counter)
        func check(_ condition: Bool, _ label: String) {
            if !condition { print("FAIL: \(label)"); exit(1) }
        }
        context.installCollisionWorld(counter)
        counter.queries = 0
        let start = ContinuousClock.now
        let places = context.snapshot.places
        let cold = start.duration(to: .now)
        let coldQueries = counter.queries
        let warmStart = ContinuousClock.now
        for _ in 0..<1000 { check(context.snapshot.places == places, "same layout projection") }
        let warm = warmStart.duration(to: .now)
        check(counter.queries == coldQueries, "1000 snapshots must perform zero new collision queries")
        let tvID = "wish-prop-f9682580-da52-47b5-b10a-b549f09cd23b"
        check(places.contains { $0.id == tvID }, "actual television destination exists")

        func assertFresh(_ candidate: WorldState, _ label: String) throws {
            try context.adoptAuthorityState(candidate, propFunctionSources: context.propFunctionSources, replacingUncommittedProjection: true)
            let fresh = try WorldAgentContext(manifest: manifest, persistence: CacheFixturePersistence(candidate), initialCollisionWorld: base)
            check(context.snapshot.places == fresh.snapshot.places, label)
        }
        var changed = state
        var transform = changed.objectStates[tvID]!.transform
        changed.objectStates[tvID]!.transform = WorldTransform(position: WorldVector3(x: transform.position.x + 0.35, y: transform.position.y, z: transform.position.z), rotation: transform.rotation, scale: transform.scale)
        try assertFresh(changed, "translated target matches fresh computation")
        transform = changed.objectStates[tvID]!.transform
        changed.objectStates[tvID]!.transform = WorldTransform(position: transform.position, rotation: WorldQuaternion(x: 0, y: sin(Float.pi / 4), z: 0, w: cos(Float.pi / 4)), scale: transform.scale)
        try assertFresh(changed, "rotated target matches fresh computation")
        transform = changed.objectStates[tvID]!.transform
        changed.objectStates[tvID]!.transform = WorldTransform(position: transform.position, rotation: transform.rotation, scale: WorldVector3(x: transform.scale.x * 1.5, y: transform.scale.y, z: transform.scale.z))
        try assertFresh(changed, "scaled footprint matches fresh computation")
        var metadata = try JSONSerialization.jsonObject(with: Data(changed.objectStates[tvID]!.metadata["gmgn.generated-prop.v1"]!.utf8)) as! [String: Any]
        metadata["displayName"] = "Changed television"
        metadata["size"] = ["x": 1.8, "y": 0.862, "z": 0.302]
        changed.objectStates[tvID]!.metadata["gmgn.generated-prop.v1"] = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
        try assertFresh(changed, "metadata invalidates discovery")
        changed.objectStates[tvID]!.isEnabled = false
        try assertFresh(changed, "disabled target disappears")
        check(!context.snapshot.places.contains { $0.id == tvID }, "disabled cached target cannot remain")
        changed.objectStates[tvID]!.isEnabled = true
        try assertFresh(changed, "reenabled target recomputes")
        let blocked = CountingCollision(base); blocked.blocked = true
        context.collisionWorld.replace(with: blocked)
        let denied = context.snapshot.places
        check(blocked.queries > 0 && !denied.contains { $0.id == tvID }, "direct collision replacement invalidates even without layout change")
        let deniedQueries = blocked.queries
        for _ in 0..<10 { _ = context.snapshot }
        check(blocked.queries == deniedQueries, "unavailable places are cached without retry work")
        context.installCollisionWorld(base)
        check(context.snapshot.places.contains { $0.id == tvID }, "installed collision restores target")
        check(context.activeActivitySnapshot == context.snapshot.activeActivity, "lightweight activity preserves full projection")
        print("PASS generated-place cache: real triangles=\(triangles.count), cold=\(cold), coldQueries=\(coldQueries), 1000 warm=\(warm), extraQueries=0; translation/rotation/scale/metadata/enabled/collision invalidation")
    }
}
