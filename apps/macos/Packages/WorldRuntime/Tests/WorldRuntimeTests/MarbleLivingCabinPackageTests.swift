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

/// 真实几何守卫（工作项 4）：连通性过滤必须在真实生活舱上真的把屋顶/天花板剔掉。
///
/// 这是"派生出来的格子会铺满屋顶"这个可见缺陷的回归测试：只用列扫描（工作项 1–3）会得到
/// 9,737 层（含 5.31 m 的屋顶外表面与 2.5 m 的天花板），装修模式一进去整个屋子都是格子。
@Test("Real cabin support grid drops the roof: connectivity filter cuts the 9,737 scanned layers")
func marbleCabinSupportGridIsConnectivityFiltered() throws {
    let root = marbleCabinPackageRoot()
    let manifest = try JSONDecoder().decode(
        WorldManifest.self,
        from: Data(contentsOf: root.appendingPathComponent("world.json"))
    )
    let config = try JSONDecoder().decode(
        MarbleCabinResourceConfiguration.self,
        from: Data(contentsOf: root.appendingPathComponent("marble.json"))
    )
    let origin = SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
    let triangles = try GLBColliderDecoder().decode(
        data: Data(contentsOf: root.appendingPathComponent("collider.glb")),
        transform: WorldMeshTransform(
            axisConversion: .flipYAndZ,
            origin: origin,
            uniformScale: config.framing.scale
        )
    )
    #expect(triangles.count == 161_600)
    let mesh = TriangleMeshCollisionWorld(triangles: triangles)

    var minimumX = Float.greatestFiniteMagnitude
    var maximumX = -Float.greatestFiniteMagnitude
    var minimumZ = Float.greatestFiniteMagnitude
    var maximumZ = -Float.greatestFiniteMagnitude
    for triangle in triangles {
        for vertex in [triangle.first, triangle.second, triangle.third] {
            minimumX = min(minimumX, vertex.x)
            maximumX = max(maximumX, vertex.x)
            minimumZ = min(minimumZ, vertex.z)
            maximumZ = max(maximumZ, vertex.z)
        }
    }

    // 默认参数 = 0.25 m 网格 + 站立胶囊(0.2 / 1.8) + maximumStepHeight 0.3 + band 1.6。
    let parameters = PropSupportGridParameters()
    let seed = manifest.spawn.position
    let clock = ContinuousClock()
    let start = clock.now
    let grid = PropSupportGridBuilder.build(
        collision: mesh,
        bounds: WorldPlanarBounds(
            minimumX: minimumX,
            maximumX: maximumX,
            minimumZ: minimumZ,
            maximumZ: maximumZ
        ),
        seed: seed,
        parameters: parameters
    )
    let elapsed = start.duration(to: clock.now)

    let report = grid.report
    let highest = grid.layers.map(\.supportHeight).max() ?? 0
    let ground = try #require(mesh.groundHeight(at: seed.simd3 + SIMD3(0, 0.05, 0)))
    print(
        "[真实生活舱承托网格] 过滤前 \(report.layersBeforeFilter) 层 → 过滤后 \(report.layersAfterFilter) 层；"
            + "站立胶囊可容纳 \(report.standableLayers)、家具下地面 "
            + "\(report.coveredGroundLayers)、可达 \(report.reachableLayers)、"
            + "band \(report.furnitureBandLayers)；最高保留层 \(highest) m、地面 \(ground) m；"
            + "派生耗时 \(elapsed)"
    )

    #expect(report.seeded)
    // 过滤前的两个实测值：列扫描 9,737 层；其中 6,763 层"站立胶囊可容纳"——
    // 屋顶上方没有东西，站上去完全合法，所以 canOccupy 挡不住屋顶（反例就钉在这里）。
    #expect(report.layersBeforeFilter == 9_737, "实测 9,737 @0.25 m")
    // 站立判据改用**格心**后，站立可容纳的层数从 6,763 升到 7,012：
    // 列角点会向后擦到相邻几何，格心不会。这条数字仍然是确定性守卫。
    #expect(report.standableLayers == 7_012, "实测 7,012 / 9,737 站立可容纳")
    #expect(
        report.standableLayers > report.layersAfterFilter,
        "只按'站立胶囊可容纳'过滤挡不住屋顶：它留下 \(report.standableLayers) 层"
    )
    #expect(report.coveredGroundLayers > 0, "桌面/家具顶面靠'家具下地面层'拿到 band 锚点")
    // 过滤后实测 3,185 层（可达 2,976 + 家具带 209），不到过滤前的一半。
    #expect(report.layersAfterFilter < 4_000, "实测 \(report.layersAfterFilter)")
    #expect(report.reachableLayers < report.layersAfterFilter, "家具顶面是 band 补进来的，不是可达层")
    #expect(grid.layers.count == report.layersAfterFilter)
    // 没有 3–5 米的层：屋顶外表面 5.31 m、天花板 2.5 m 都被剔除。
    #expect(!grid.layers.contains { $0.supportHeight >= 3 }, "3–5 m 的屋顶层必须被剔除")
    #expect(highest < 3.0, "最高保留层必须低于天花板平面，实测 \(highest)")
    // **比魔数更强的结构性质**（取代原来的"地面 + band + 容差"）：每一个保留层，要么是它所在列
    // 的最低保留层，要么与它**下面那一层**的间距 ≤ furnitureBandHeight。
    //
    // 这条恰好把"家具顶面"和"天花板/屋顶那种独立平面"分开：2.5–2.9 m 那 8 层实测都长在
    // 更低的可达面之上（例：`L0@1.36 L1@2.54`），是"高台之上再叠一层家具顶面"，
    // 而不是悬空的一片天花板。任何一层如果离下面那层超过家具带，就是独立平面 —— 必须被剔除。
    var violations: [String] = []
    for (column, layers) in Dictionary(grouping: grid.layers, by: \.column) {
        let heights = layers.map(\.supportHeight).sorted()
        for index in heights.indices.dropFirst()
        where heights[index] - heights[index - 1] > parameters.furnitureBandHeight + 0.001 {
            violations.append(
                "列(\(column.x),\(column.z)) 的 \(heights[index - 1]) → \(heights[index])"
            )
        }
    }
    #expect(
        violations.isEmpty,
        "保留层之间不能出现超过家具带的空隙（那是独立平面）：\(violations.prefix(4))"
    )
}
