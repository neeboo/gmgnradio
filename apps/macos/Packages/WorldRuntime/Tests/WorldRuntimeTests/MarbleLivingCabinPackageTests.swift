import Foundation
import Testing
@testable import WorldRuntime

private func marbleCabinPackageRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("Resources/Worlds/marble-living-cabin")
}

@Test("Adopted Marble cabin has real assets and matching interaction anchors")
func marbleCabinPackageUsesGeneratedAssets() throws {
    let root = marbleCabinPackageRoot()
    let data = try Data(contentsOf: root.appendingPathComponent("world.json"))
    let manifest = try JSONDecoder().decode(WorldManifest.self, from: data)
    #expect(UUID(uuidString: manifest.worldID) != nil)
    #expect(manifest.packageID == "marble-living-cabin")
    #expect(manifest.packageVersion == "1.2.0", "Wish-machine package uses its versioned state migration")
    #expect(manifest.calibration.metersPerUnit == 1)
    #expect(WorldPackageValidator().validate(manifest, packageRoot: root).isEmpty)
    #expect(Set(manifest.activities.map(\.id)) == ["home.idle", "home.walk", "music.listen", "wish_machine.collect", "performance.backflip", "performance.jumping_jacks"])
    #expect(manifest.resources.contains { $0.path == "scene-500k.spz" })
    #expect(manifest.resources.contains { $0.path == "collider.glb" })
    #expect(manifest.collisionVolumes.contains { $0.id == "collision.jukebox" })
    let music = try #require(manifest.activities.first { $0.id == "music.listen" })
    let waypoint = try #require(manifest.waypoints.first { $0.id == music.entryWaypointID })
    #expect(music.transform.position == waypoint.position)
    #expect(manifest.activityDefinitions.first { $0.id == "music.listen" }?.activity.typeID == "listenMusic")
    let enterDuration = try #require(manifest.activityDefinitions.first { $0.id == "music.listen" }?.contract(for: .enter)?.durationSeconds)
    #expect(enterDuration > 0 && enterDuration < 3)
}

private struct MarbleCabinResourceConfiguration: Decodable {
    struct Framing: Decodable {
        let origin: [Float]
        let scale: Float
    }
    struct Camera: Decodable { let position: [Float] }
    struct Jukebox: Decodable { let position: [Float] }
    let framing: Framing
    let camera: Camera
    let jukebox: Jukebox
}

@Test("Real generated cabin mesh grounds the resident and reaches the independent jukebox")
func marbleCabinRealMeshSupportsAuthoredTour() throws {
    let root = marbleCabinPackageRoot()
    let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: root.appendingPathComponent("world.json")))
    let config = try JSONDecoder().decode(MarbleCabinResourceConfiguration.self, from: Data(contentsOf: root.appendingPathComponent("marble.json")))
    #expect(config.framing.origin.count == 3)
    #expect(abs(config.framing.scale - 2.4251628) < 0.0001, "Door reference calibration doubles the generated environment only")
    let origin = SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
    #expect(abs(origin.y + 1.432358) < 0.0001)
    let triangles = try GLBColliderDecoder().decode(
        data: Data(contentsOf: root.appendingPathComponent("collider.glb")),
        transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin, uniformScale: config.framing.scale)
    )
    #expect(triangles.count == 161_600)
    let mesh = TriangleMeshCollisionWorld(triangles: triangles)
    let props = CollisionVolumeWorld(volumes: manifest.collisionVolumes.filter { $0.id == "collision.jukebox" })
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let spawn = manifest.spawn.position.simd3
    let spawnGround = try #require(mesh.groundHeight(at: spawn + SIMD3(0, 0.05, 0)))
    #expect(abs(spawnGround - spawn.y) < 0.01)
    #expect(abs(spawnGround) < 0.1)
    #expect(mesh.canOccupy(capsule, at: spawn))
    #expect(props.canOccupy(capsule, at: spawn))

    let graph = WaypointNavigationGraph(manifest: manifest)
    let music = try #require(manifest.activities.first { $0.id == "music.listen" })
    let path = try graph.route(from: spawn, to: music.entryWaypointID)
    #expect(path.waypointIDs.last == music.entryWaypointID)
    #expect(!path.points.isEmpty)
    var previous = spawn
    for waypoint in path.points {
        let destination = waypoint.simd3
        #expect(mesh.canTraverse(capsule, from: previous, to: destination, maximumStepHeight: 0.25))
        // The real generated mesh and the independent object must both permit
        // every sampled body location, including the final interaction pose.
        for index in 0...20 {
            let sample = previous + (destination - previous) * (Float(index) / 20)
            let ground = try #require(mesh.groundHeight(at: sample + SIMD3(0, 0.05, 0)))
            let grounded = SIMD3(sample.x, ground, sample.z)
            #expect(mesh.canOccupy(capsule, at: grounded))
            #expect(props.canOccupy(capsule, at: grounded))
        }
        previous = destination
    }
    #expect(worldDistance(previous, music.transform.position.simd3) < 0.01)

    let jukebox = SIMD3(config.jukebox.position[0], config.jukebox.position[1], config.jukebox.position[2])
    let deviceCollision = try #require(manifest.collisionVolumes.first { $0.id == "collision.jukebox" })
    #expect(abs(deviceCollision.halfExtents.y * 2 - 1.23) < 0.001, "Independent equipment keeps its physical size")
    #expect(abs(jukebox.x - music.transform.position.x - 0.7) < 0.001, "Interaction reach must not grow with the environment")
    let musicGround = try #require(mesh.groundHeight(at: music.transform.position.simd3 + SIMD3(0, 0.05, 0)))
    #expect(abs(musicGround - music.transform.position.y) < 0.01)
    #expect(!props.canOccupy(capsule, at: jukebox))
    let deviceGround = try #require(mesh.groundHeight(at: jukebox + SIMD3(0, 0.05, 0)))
    #expect(abs(deviceGround - jukebox.y) < 0.01)

    let camera = SIMD3(config.camera.position[0], config.camera.position[1], config.camera.position[2])
    #expect(abs(camera.y - 1.65) < 0.01, "Default cabin camera starts at standing eye height")
    let cameraProbe = WorldCapsule(radius: 0.05, height: 0.1)
    #expect(mesh.canOccupy(cameraProbe, at: camera - SIMD3(0, 0.05, 0)))
    #expect(mesh.canOccupy(cameraProbe, at: camera + SIMD3(0, 0.15, 0)))
    #expect(worldDistance(camera, spawn) > 4)
}
