// 「生成工作流自带的碰撞数据被真正用起来」——真实舱体几何 + 实测耗时（无宿主、无窗口、无 GPU）。
//
// 背景：物件的碰撞形状到今天为止是 app **猜**的（尺寸 × 朝向的偏航盒子）。后果是薄/凹/细长
// 物件要么挡空气、要么漏，而且**换一个生成后端就换一套碰撞**。用户的要求是「碰撞在工作流里面
// 自动加」。本 harness 把接收端这一半钉死：
//
//   A1 回执**缺失**碰撞字段 ⇒ 逐字节一致（元数据 JSON 不多键；形状仍是今天那个盒子；
//      尺寸仍读 app 量的那一份；同一批落点上答案逐点相同）；
//   A2 回执**存在**碰撞字段 ⇒ 碰撞走代理（凹形/空心物件不再挡空气），尺寸以权威值为准；
//   A3 字段**类型非法** ⇒ 明确错误（整件物件判无效 ⇒ 可见拒绝），绝不静默当成"没有代理"；
//   A4 **代理解不出** ⇒ 可见拒绝（进 `unmodelledObjectIDs`），不退回盒子、不放宽；
//   A5 判定只有**一条**通路（运行时世界 / 通路预检 / 互斥预检 / 判据函数逐点一致）；
//   A6 性能**有界**：代理的三角形规模被契约卡住，实测单次 canOccupy / canTraverse 的代价。
//
// 数据来源：真实舱体 `collider.glb`（161,600 三角形）派生出的真实承托网格与移动图，
// 加上合成出来的碰撞代理（凹形/空心），不需要真机存档。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = #"""
import Foundation
import WorldRuntime

func q(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func medianMicros(_ iterations: Int, _ body: () -> Void) -> (median: Double, p95: Double) {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0 ..< iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    return (q(samples, 0.5), q(samples, 0.95))
}

// MARK: - 碰撞代理的构造（生成侧会导出的那种几何）

/// 实心方柱：X/Z 半宽 `half`，y 从 0 到 1（归一化自动成立）。
func solidBlock(half: Float) -> [WorldTriangle] {
    let corners: [(Float, Float)] = [(-half, -half), (half, -half), (half, half), (-half, half)]
    var triangles: [WorldTriangle] = []
    for index in corners.indices {
        let a = corners[index], b = corners[(index + 1) % corners.count]
        triangles.append(WorldTriangle(SIMD3(a.0, 0, a.1), SIMD3(b.0, 0, b.1), SIMD3(b.0, 1, b.1)))
        triangles.append(WorldTriangle(SIMD3(a.0, 0, a.1), SIMD3(b.0, 1, b.1), SIMD3(a.0, 1, a.1)))
    }
    triangles.append(WorldTriangle(SIMD3(-half, 1, -half), SIMD3(half, 1, -half), SIMD3(half, 1, half)))
    triangles.append(WorldTriangle(SIMD3(-half, 1, -half), SIMD3(half, 1, half), SIMD3(-half, 1, half)))
    triangles.append(WorldTriangle(SIMD3(-half, 0, -half), SIMD3(half, 0, half), SIMD3(half, 0, -half)))
    triangles.append(WorldTriangle(SIMD3(-half, 0, -half), SIMD3(-half, 0, half), SIMD3(half, 0, half)))
    return triangles
}

/// **空心管**：外壁 `outer`、内壁 `inner`，两端不封口。包围盒与同尺寸实心块**完全一样**，
/// 但管腔里什么都没有 —— 盒子会把它整块挡死（挡空气），代理不会。
func hollowTube(outer: Float, inner: Float) -> [WorldTriangle] {
    let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    var triangles: [WorldTriangle] = []
    for index in corners.indices {
        let next = corners[(index + 1) % corners.count]
        for (firstHalf, secondHalf, flip) in [(outer, inner, false), (inner, outer, true)] {
            let a = SIMD3(corners[index].0 * firstHalf, 0, corners[index].1 * firstHalf)
            let b = SIMD3(next.0 * firstHalf, 0, next.1 * firstHalf)
            let c = SIMD3(next.0 * secondHalf, 1, next.1 * secondHalf)
            let d = SIMD3(corners[index].0 * secondHalf, 1, corners[index].1 * secondHalf)
            if flip {
                triangles.append(WorldTriangle(a, c, b))
                triangles.append(WorldTriangle(a, d, c))
            } else {
                triangles.append(WorldTriangle(a, b, c))
                triangles.append(WorldTriangle(a, c, d))
            }
        }
    }
    return triangles
}

/// 一段**降面后的细长板**（斜着放）：演示"薄/细长物件"的代理。长度 1（对角），厚度很小。
func diagonalPlank(thickness: Float) -> [WorldTriangle] {
    let half = Float(0.5)
    let direct = Float(0.7071067811865476)
    let corners: [((Float, Float), (Float, Float))] = [
        ((-half * direct, -half * direct), (half * direct, half * direct)),
    ]
    var triangles: [WorldTriangle] = []
    for (from, to) in corners {
        let dx = (to.0 - from.0), dz = (to.1 - from.1)
        let length = (dx * dx + dz * dz).squareRoot()
        let nx = -dz / length * thickness, nz = dx / length * thickness
        let a = (from.0 + nx, from.1 + nz), b = (to.0 + nx, to.1 + nz)
        let c = (to.0 - nx, to.1 - nz), d = (from.0 - nx, from.1 - nz)
        for (p, r, s) in [(a, b, c), (a, c, d)] {
            triangles.append(WorldTriangle(SIMD3(p.0, 0, p.1), SIMD3(r.0, 0, r.1), SIMD3(s.0, 1, s.1)))
            triangles.append(WorldTriangle(SIMD3(p.0, 0, p.1), SIMD3(s.0, 1, s.1), SIMD3(p.0, 1, p.1)))
            triangles.append(WorldTriangle(SIMD3(r.0, 0, r.1), SIMD3(s.0, 0, s.1), SIMD3(s.0, 1, s.1)))
        }
        triangles.append(WorldTriangle(SIMD3(a.0, 1, a.1), SIMD3(b.0, 1, b.1), SIMD3(c.0, 1, c.1)))
        triangles.append(WorldTriangle(SIMD3(a.0, 1, a.1), SIMD3(c.0, 1, c.1), SIMD3(d.0, 1, d.1)))
        triangles.append(WorldTriangle(SIMD3(a.0, 0, a.1), SIMD3(c.0, 0, c.1), SIMD3(b.0, 0, b.1)))
        triangles.append(WorldTriangle(SIMD3(a.0, 0, a.1), SIMD3(d.0, 0, d.1), SIMD3(c.0, 0, c.1)))
    }
    return triangles
}

private func sha(_ seed: UInt8) -> String { String(repeating: String(format: "%02x", seed), count: 32) }

struct Fixture {
    let objectID: String
    let prop: WorldGeneratedProp
    let object: WorldObjectState
}

/// 造一件物件（含可选的工作流碰撞数据）。
func fixture(
    objectID: String,
    size: WorldVector3,
    position: WorldVector3,
    yaw: Float = 0,
    collision: WorldPropCollisionProxy?,
    authoritativeSize: WorldPropAuthoritativeSize? = nil
) -> Fixture {
    let prop = WorldGeneratedProp(
        objectID: objectID, sourceWishID: objectID, assetID: "asset." + objectID,
        displayName: objectID, size: size, sourceHeight: 1,
        collision: collision, authoritativeSize: authoritativeSize
    )
    let object = WorldObjectState(
        isEnabled: true,
        transform: WorldTransform(
            position: position,
            rotation: WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
            scale: .init(x: 1, y: 1, z: 1)
        ),
        metadata: ["gmgn.generated-prop.v1": String(decoding: try! JSONEncoder().encode(prop), as: UTF8.self)]
    )
    return Fixture(objectID: objectID, prop: prop, object: object)
}

func proxyDescriptor(_ seed: UInt8, triangles: Int, format: WorldPropCollisionFormat = .glbHull) -> WorldPropCollisionProxy {
    WorldPropCollisionProxy(
        url: "/v1/jobs/00000000000000000000000000000000/collider.glb",
        format: format, sha256: sha(seed), bytes: 4096, triangles: triangles
    )
}

@main struct CollisionProxy {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            guard ok else { print("FAIL: \(message)"); exit(1) }
        }

        // ---- 真实舱体几何：碰撞网格 → 承托网格 → 移动图（摆放预检用的那一套）----
        let wr = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: wr.appendingPathComponent("world.json")))
        struct C: Decodable { struct F: Decodable { let origin: [Float]; let scale: Float }; let framing: F }
        let cfg = try JSONDecoder().decode(C.self, from: Data(contentsOf: wr.appendingPathComponent("marble.json")))
        let origin = SIMD3(cfg.framing.origin[0], cfg.framing.origin[1], cfg.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(
            data: Data(contentsOf: wr.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin, uniformScale: cfg.framing.scale))
        let room = TriangleMeshCollisionWorld(triangles: triangles)
        check(triangles.count > 100_000, "真实舱体碰撞网格必须是十万级三角形（实测 \(triangles.count)）")

        let parameters = PropSupportGridParameters()
        let positions = manifest.waypoints.filter(\.enabled).map(\.position)
        check(!positions.isEmpty, "真实舱体必须有可用路点")
        var minimumX = positions[0].x, maximumX = positions[0].x
        var minimumZ = positions[0].z, maximumZ = positions[0].z
        for p in positions {
            minimumX = min(minimumX, p.x); maximumX = max(maximumX, p.x)
            minimumZ = min(minimumZ, p.z); maximumZ = max(maximumZ, p.z)
        }
        let margin = parameters.spacing + parameters.capsuleRadius
        let derivation = PropSupportDerivationWorld(base: room, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
        let grid = PropSupportGridBuilder.build(collision: derivation,
            bounds: WorldPlanarBounds(minimumX: minimumX - margin, maximumX: maximumX + margin,
                                      minimumZ: minimumZ - margin, maximumZ: maximumZ + margin),
            seed: manifest.spawn.position, parameters: parameters)
        check(grid.layers.count > 1000, "真实舱体必须派生出上千个承托层（实测 \(grid.layers.count)）")
        let heights = positions.map(\.y)
        let map = WorldPlacementRouteMap(grid: grid, lowerHeight: heights.min()! - 0.2, upperHeight: heights.max()! + 0.2)
        check(map.standableNodeCount > 1000, "移动图必须有上千个可站节点（实测 \(map.standableNodeCount)）")
        let capsule = WorldCapsule(radius: parameters.capsuleRadius, height: 1.8)
        print("真实舱体：\(triangles.count) 三角形、\(grid.layers.count) 承托层、\(map.standableNodeCount) 可站节点、\(positions.count) 路点")

        // 一个落在真实地面上的落点（用门口附近的第一层地面格）。
        let floorHeight = grid.layers.map(\.supportHeight).min()!
        guard let floorLayer = grid.layers.first(where: { $0.supportHeight < floorHeight + 0.05 }) else {
            print("FAIL: 真实舱体必须有一层地面"); exit(1)
        }
        let floorX = (Float(floorLayer.column.x) + 0.5) * grid.spacing
        let floorZ = (Float(floorLayer.column.z) + 0.5) * grid.spacing

        // ---- 代理注册表 ----
        let store = WorldPropCollisionProxyStore.shared
        store.removeAll()

        // =====================================================================
        // A1 回执缺失碰撞字段 ⇒ 逐字节一致
        // =====================================================================
        let plain = fixture(objectID: "plain.axe", size: .init(x: 0.3, y: 0.42, z: 0.12),
                            position: .init(x: floorX, y: floorHeight, z: floorZ), collision: nil)
        let plainJSON = plain.object.metadata["gmgn.generated-prop.v1"]!
        check(!plainJSON.contains("collision") && !plainJSON.contains("authoritativeSize"),
              "缺失时元数据里不得出现新键（实测 \(plainJSON)）")
        let decoded = plain.object.generatedProp!
        check(decoded.effectiveSize == decoded.size && decoded.sizeSource == .appMeasured,
              "缺失时尺寸仍然读 app 量的那一份（来源=\(decoded.sizeSource)）")
        let plainVolume = plain.object.generatedCollisionVolume!
        let expectedVolume = WorldCollisionVolume(
            id: "plain.axe",
            center: .init(x: floorX, y: floorHeight + 0.21, z: floorZ),
            halfExtents: .init(x: 0.15, y: 0.21, z: 0.06),
            rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true)
        check(plainVolume == expectedVolume, "缺失时形状必须逐字段等于今天那个 yaw 盒子")
        var plainState = WorldState(revision: 1, worldID: manifest.worldID, worldTime: .distantPast,
            lastObservedWallTime: .distantPast, weather: .clear,
            agentTransform: manifest.spawn)
        plainState.objectStates[plain.objectID] = plain.object
        let plainResolution = WorldLayoutObstacles.resolve(plainState)
        check(plainResolution.unmodelledObjectIDs.isEmpty, "缺失时不得有 unmodelled（实测 \(plainResolution.unmodelledObjectIDs)）")
        check(plainResolution.volumes == [expectedVolume], "缺失时旧投影必须逐字段等于今天那个盒子")
        guard case .orientedBox = plainResolution.obstacles.first?.shape else {
            print("FAIL: 缺失时形状必须是 .orientedBox，实测 \(String(describing: plainResolution.obstacles.first?.shape))"); exit(1)
        }
        // 同一批落点上，新旧两条路给出**逐点相同**的答案。
        let plainWorld = CollisionVolumeWorld(obstacles: plainResolution.obstacles)
        let legacyWorld = CollisionVolumeWorld(volumes: [expectedVolume])
        var disagreements = 0
        for x in stride(from: floorX - 0.6, through: floorX + 0.6, by: 0.05) {
            for z in stride(from: floorZ - 0.6, through: floorZ + 0.6, by: 0.05) {
                let p = SIMD3(x, floorHeight, z)
                if plainWorld.canOccupy(capsule, at: p) != legacyWorld.canOccupy(capsule, at: p) { disagreements += 1 }
            }
        }
        check(disagreements == 0, "缺失时新通路与旧通路必须逐点一致（实测分歧 \(disagreements)）")
        print("PASS[1]: 回执缺失碰撞字段 ⇒ 与今天逐字节一致（元数据不多键、形状=\(plainResolution.volumes[0].halfExtents)、625 个落点零分歧）")

        // =====================================================================
        // A2 回执存在碰撞字段 ⇒ 碰撞走代理
        // =====================================================================
        // 两个"后端"：实心块与空心管，归一化包围盒完全一样。
        let solidTriangles = solidBlock(half: 1)
        let hollowTriangles = hollowTube(outer: 1, inner: 0.85)
        let plankTriangles = diagonalPlank(thickness: 0.05)
        for (seed, set) in [(UInt8(0x11), solidTriangles), (UInt8(0x22), hollowTriangles), (UInt8(0x33), plankTriangles)] {
            let mesh = WorldPropCollisionProxyMesh(triangles: set, sourceSHA256: sha(seed))
            check(mesh != nil, "归一化校验必须接受生成侧导出的代理（seed=\(seed)）")
            check(store.install(mesh!), "代理必须能装进注册表")
        }
        // 目标高度 1 m ⇒ 归一化半宽 1 → 世界半宽 1 m（管腔 1.7 m，足够放下 0.25 m 的胶囊；
        // 也让"贴着物件走一趟"的路径在**盒子与代理都放行**的地方量 canTraverse，两边可比）。
        let targetHeight: Float = 1
        let hollow = fixture(objectID: "workflow.hollow", size: .init(x: 2, y: targetHeight, z: 2),
                             position: .init(x: floorX, y: floorHeight, z: floorZ),
                             collision: proxyDescriptor(0x22, triangles: hollowTriangles.count, format: .glbDecimated))
        let solid = fixture(objectID: "workflow.solid", size: .init(x: 2, y: targetHeight, z: 2),
                            position: .init(x: floorX, y: floorHeight, z: floorZ),
                            collision: proxyDescriptor(0x11, triangles: solidTriangles.count))
        var state = WorldState(revision: 1, worldID: manifest.worldID, worldTime: .distantPast,
            lastObservedWallTime: .distantPast, weather: .clear, agentTransform: manifest.spawn)
        state.objectStates[hollow.objectID] = hollow.object
        let hollowResolution = WorldLayoutObstacles.resolve(state)
        check(hollowResolution.unmodelledObjectIDs.isEmpty, "代理解得出时不得进 unmodelled（实测 \(hollowResolution.unmodelledObjectIDs)）")
        guard case .proxyMesh(let hollowMesh)? = hollowResolution.obstacles.first?.shape else {
            print("FAIL: 声明了代理就必须走 .proxyMesh，实测 \(String(describing: hollowResolution.obstacles.first?.shape))"); exit(1)
        }
        check(hollowMesh.format == WorldPropCollisionFormat.glbDecimated, "格式必须从回执带过来（审计：\(hollowMesh.format)）")
        check(hollowMesh.proxySHA256 == sha(0x22), "代理摘要必须可查（审计：这份碰撞来自哪一份代理）")

        state.objectStates[solid.objectID] = solid.object
        // 细长物件（斜着放的长剑/斧头）：它的代理是一条**斜带**，而"按尺寸猜的盒子"是那条
        // 斜带的包围盒 —— 这正是"薄/细长物件用盒子表示会挡空气"的真实形状。
        let plank = fixture(objectID: "workflow.plank", size: .init(x: 0.8, y: 3, z: 0.8),
                            position: .init(x: floorX, y: floorHeight, z: floorZ),
                            collision: proxyDescriptor(0x33, triangles: plankTriangles.count, format: .glbDecimated))
        state.objectStates[plank.objectID] = plank.object
        let bothResolution = WorldLayoutObstacles.resolve(state)
        let hollowObstacle = bothResolution.obstacles.first { $0.id == hollow.objectID }!
        let solidObstacle = bothResolution.obstacles.first { $0.id == solid.objectID }!
        let cavity = SIMD3<Float>(floorX, floorHeight, floorZ)
        // 盒子只能按尺寸猜 ⇒ 管腔里的落点被挡（挡空气）。
        let guessedBox = hollow.object.generatedCollisionVolume!
        check(!WorldCapsuleClearance.isClear(capsule, at: cavity, of: WorldPropObstacle(volume: guessedBox)),
              "按尺寸猜的盒子必须挡住管腔（这就是挡空气）")
        // 代理这一侧：空心管不挡、实心块挡 —— 两个后端给出**不同**答案，而盒子给不出区别。
        check(WorldCapsuleClearance.isClear(capsule, at: cavity, of: hollowObstacle),
              "空心代理必须放行管腔里的落点")
        check(!WorldCapsuleClearance.isClear(capsule, at: cavity, of: solidObstacle),
              "实心代理必须挡住管腔里的落点")
        let runtimeWithHollow = CollisionVolumeWorld(obstacles: [hollowObstacle])
        let runtimeWithSolid = CollisionVolumeWorld(obstacles: [solidObstacle])
        check(runtimeWithHollow.canOccupy(capsule, at: cavity) != runtimeWithSolid.canOccupy(capsule, at: cavity),
              "同一尺寸、不同后端 ⇒ 运行时碰撞必须不同（跨后端一致性由代理给，不再由盒子猜）")
        // 管壁里必须挡住。
        let inTheWall = SIMD3<Float>(floorX + 0.925, floorHeight, floorZ)
        check(!runtimeWithHollow.canOccupy(capsule, at: inTheWall), "管壁必须挡住（代理不是'什么都不挡'）")

        // 权威尺寸：以它为准，且来源可查。
        let authoritative = WorldPropAuthoritativeSize(
            dimensions: .init(x: 0.9, y: 0.42, z: 0.1), units: "m", upAxis: "+Y", forwardAxis: "-Z")
        let sized = fixture(objectID: "workflow.sized", size: .init(x: 0.3, y: 0.42, z: 0.4),
                            position: .init(x: floorX, y: floorHeight, z: floorZ),
                            collision: proxyDescriptor(0x11, triangles: solidTriangles.count),
                            authoritativeSize: authoritative)
        let sizedProp = sized.object.generatedProp!
        check(sizedProp.effectiveSize == authoritative.dimensions, "有权威尺寸时尺寸必须以它为准")
        check(sizedProp.sizeSource == .workflowAuthoritative, "尺寸来源必须可查（实测 \(sizedProp.sizeSource)）")
        let sizedVolume = sized.object.generatedCollisionVolume!
        check(abs(sizedVolume.halfExtents.x - 0.45) < 0.0001 && abs(sizedVolume.halfExtents.z - 0.05) < 0.0001,
              "盒子必须按权威尺寸构造（实测 \(sizedVolume.halfExtents)）")
        print("PASS[2]: 回执存在碰撞字段 ⇒ 碰撞走代理（同一包围盒的两个后端给出不同碰撞）、尺寸以权威值为准（来源=\(sizedProp.sizeSource)）")

        // =====================================================================
        // A3 字段类型非法 ⇒ 明确错误，不静默
        // =====================================================================
        var illegalRejections = 0
        var illegalCases = 0
        for bad in [
            WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: "not-hex", bytes: 4096, triangles: 12),
            WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: sha(1), bytes: 4096, triangles: 0),
            WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: sha(1), bytes: 0, triangles: 12),
            WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: sha(1), bytes: 4096, triangles: WorldPropCollisionProxy.maximumTriangles + 1),
            WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: sha(1), bytes: WorldPropCollisionProxy.maximumBytes + 1, triangles: 12),
            WorldPropCollisionProxy(url: "/v1/jobs/x/model.glb", format: .glbHull, sha256: sha(1), bytes: 4096, triangles: 12),
            WorldPropCollisionProxy(url: "https://evil.invalid/x/collider.glb", format: .glbHull, sha256: sha(1), bytes: 4096, triangles: 12),
        ] {
            illegalCases += 1
            let broken = fixture(objectID: "illegal", size: .init(x: 0.3, y: 0.42, z: 0.4),
                                 position: .init(x: floorX, y: floorHeight, z: floorZ), collision: bad)
            check(broken.object.generatedProp == nil, "非法代理必须让整件物件判无效（\(bad)）")
            var brokenState = state
            brokenState.objectStates = [broken.objectID: broken.object]
            let resolution = WorldLayoutObstacles.resolve(brokenState)
            check(resolution.unmodelledObjectIDs == ["illegal"],
                  "非法代理必须可见拒绝，而不是静默当成没有代理（实测 \(resolution.unmodelledObjectIDs)）")
            illegalRejections += 1
        }
        for badSize in [
            WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 0, z: 1), units: "m", upAxis: "+Y", forwardAxis: "-Z"),
            WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 1, z: 1), units: "cm", upAxis: "+Y", forwardAxis: "-Z"),
            WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 1, z: 1), units: "m", upAxis: "up", forwardAxis: "-Z"),
            WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 1, z: 1), units: "m", upAxis: "+Y", forwardAxis: "-W"),
            WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 101, z: 1), units: "m", upAxis: "+Y", forwardAxis: "-Z"),
        ] {
            illegalCases += 1
            let broken = fixture(objectID: "illegal", size: .init(x: 0.3, y: 0.42, z: 0.4),
                                 position: .init(x: floorX, y: floorHeight, z: floorZ),
                                 collision: nil, authoritativeSize: badSize)
            check(broken.object.generatedProp == nil, "非法权威尺寸必须让整件物件判无效（\(badSize)）")
            var brokenState = state
            brokenState.objectStates = [broken.objectID: broken.object]
            check(WorldLayoutObstacles.resolve(brokenState).unmodelledObjectIDs == ["illegal"],
                  "非法权威尺寸必须可见拒绝")
            illegalRejections += 1
        }
        print("PASS[3]: 字段类型/形状非法 ⇒ 明确错误（\(illegalRejections)/\(illegalCases) 个非法输入全部可见拒绝，无一静默）")

        // =====================================================================
        // A4 代理解不出 ⇒ 可见拒绝（不放宽）
        // =====================================================================
        let absent = fixture(objectID: "workflow.missing",
                             size: .init(x: 0.3, y: 0.42, z: 0.4),
                             position: .init(x: floorX, y: floorHeight, z: floorZ),
                             collision: proxyDescriptor(0xEE, triangles: 64))
        check(absent.object.generatedProp != nil, "代理描述本身合法 ⇒ 物件资料有效")
        check(absent.object.generatedCollisionObstacle == nil, "解不出代理时**不得**退回盒子")
        var absentState = state
        absentState.objectStates = [absent.objectID: absent.object]
        let absentResolution = WorldLayoutObstacles.resolve(absentState)
        check(absentResolution.obstacles.isEmpty && absentResolution.unmodelledObjectIDs == [absent.objectID],
              "解不出代理必须可见拒绝（实测 obstacles=\(absentResolution.obstacles.count) unmodelled=\(absentResolution.unmodelledObjectIDs)）")
        check(absentResolution.volumes.isEmpty, "解不出代理时旧投影也必须为空（不给任何体积）")
        print("PASS[4]: 代理解不出 ⇒ 可见拒绝（unmodelledPlacedProp 会点名 \(absent.objectID)），既不退回盒子也不放宽")

        // =====================================================================
        // A5 判定只有一条通路
        // =====================================================================
        let mixedResolution = bothResolution
        let obstaclesWorld = CollisionVolumeWorld(obstacles: mixedResolution.obstacles)
        // 运行时那一份：底座（房间网格）+ 物件障碍（`PropLayoutCollisionWorld` 就是这两者相与）。
        let base = room
        func runtimeCanOccupy(_ p: SIMD3<Float>) -> Bool {
            base.canOccupy(capsule, at: p) && obstaclesWorld.canOccupy(capsule, at: p)
        }
        var checked5 = 0
        var blocked5 = 0
        for x in stride(from: floorX - 2.0, through: floorX + 2.0, by: 0.1) {
            for z in stride(from: floorZ - 2.0, through: floorZ + 2.0, by: 0.1) {
                let p = SIMD3(x, floorHeight, z)
                let viaFunction = mixedResolution.obstacles.allSatisfy {
                    WorldCapsuleClearance.isClear(capsule, at: p, of: $0)
                }
                check(runtimeCanOccupy(p) == (viaFunction && base.canOccupy(capsule, at: p)),
                      "运行时世界与判据函数在 (\(x),\(z)) 上分叉")
                checked5 += 1
                if !viaFunction { blocked5 += 1 }
            }
        }
        check(checked5 > 1000 && blocked5 > 0, "这批落点必须有上千个且存在被挡的（被挡 \(blocked5)/\(checked5)）")

        // 通路预检：同一个障碍 ⇒ 同一批被占节点（判据函数逐点复算）。
        var occupied: Set<Int> = []
        for obstacle in mixedResolution.obstacles { occupied.formUnion(map.blockedNodes(obstacle: obstacle)) }
        var truth: Set<Int> = []
        for obstacle in mixedResolution.obstacles {
            for layer in grid.layers {
                let column = layer.column
                let cx = (Float(column.x) + 0.5) * grid.spacing
                let cz = (Float(column.z) + 0.5) * grid.spacing
                guard abs(cx - floorX) < 3.5, abs(cz - floorZ) < 3.5 else { continue }
                // 必须用**可站高度**（`supportHeight`），而不是这一列最低的那一层：
                // `blockedNodes` 判的就是可站高度上的胶囊。
                guard let height = map.supportHeight(at: column),
                      let node = map.node(at: WorldVector3(x: cx, y: height, z: cz)) else { continue }
                if !WorldCapsuleClearance.isClear(map.capsule, at: SIMD3(cx, height, cz), of: obstacle) {
                    truth.insert(node)
                }
            }
        }
        // 注意胶囊口径：通路预检用的是**移动图自己那一份**（`map.capsule`，半径 0.25），
        // 不是承托网格参数里那个（0.2）。用错了口径会凭空多出十几个"假"节点。
        check(occupied == truth, "通路预检的被占节点必须与判据函数逐点一致（漏 \(truth.subtracting(occupied).count) / 假 \(occupied.subtracting(truth).count)）")
        check(!occupied.isEmpty, "这批代理必须真的占掉一些节点，否则断言没被跑到")
        // 「代理真的被用上了」+「旧投影不会漏挡」两条一起钉：
        //   1. 细长物件的代理（斜带）与它的保守包围盒必须给出**不同**的被占节点；
        //   2. 对**每一个**障碍，代理的被占节点必须是保守包围盒被占节点的**子集**
        //      —— 这就是"保守投影只会多挡、不会漏挡"在节点层面的表述。
        // 注意：必须在**单个障碍**上比对。几件物件一起求并集时，大件物件的节点会把
        // 小件物件的差异淹没 —— 那样"代理没被用上"就测不出来了（第一版就是这么写的）。
        for obstacle in mixedResolution.obstacles {
            let viaProxy = map.blockedNodes(obstacle: obstacle)
            let viaBox = map.blockedNodes(volume: obstacle.conservativeBoxProjection)
            check(viaProxy.isSubset(of: viaBox),
                  "\(obstacle.id)：保守投影漏挡了 \(viaProxy.subtracting(viaBox).count) 个节点（fail-open）")
        }
        // 细长物件单独看：差异必须明显（斜带 vs 它的包围盒）。
        if let plankObstacle = mixedResolution.obstacles.first(where: { $0.id == "workflow.plank" }) {
            let viaProxy = map.blockedNodes(obstacle: plankObstacle)
            let viaBox = map.blockedNodes(volume: plankObstacle.conservativeBoxProjection)
            check(!viaProxy.isEmpty, "细长物件的代理必须真的占掉一些节点")
            check(viaBox.count > viaProxy.count,
                  "细长物件的包围盒必须比代理多挡一些节点（盒子 \(viaBox.count) / 代理 \(viaProxy.count)）")
        } else {
            print("FAIL: 状态里必须有 workflow.plank 这件细长物件"); exit(1)
        }

        // 互斥预检：候选盒子 × 代理障碍，与判据函数同源。
        let candidate = WorldCollisionVolume(id: "prop.preview",
            center: .init(x: floorX, y: floorHeight + 0.5, z: floorZ),
            halfExtents: .init(x: 0.05, y: 0.05, z: 0.05),
            rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true)
        check(WorldPropObstacleOverlap.overlaps(box: candidate, obstacle: solidObstacle),
              "完全落在实心代理里的候选盒子必须判重叠（否则小物件能整个塞进大物件）")
        let farCandidate = WorldCollisionVolume(id: "prop.preview",
            center: .init(x: floorX + 8, y: floorHeight + 0.5, z: floorZ),
            halfExtents: .init(x: 0.05, y: 0.05, z: 0.05),
            rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true)
        check(!WorldPropObstacleOverlap.overlaps(box: farCandidate, obstacle: solidObstacle),
              "离得很远的候选盒子不得判重叠")
        print("PASS[5]: 判定只有一条通路 —— 运行时世界/通路预检/互斥预检/判据函数在 \(checked5) 个落点与 \(occupied.count) 个节点上零分歧")

        // =====================================================================
        // A6 性能有界（贴数字）
        // =====================================================================
        let obstacleBox = WorldPropObstacle(volume: guessedBox)
        let probe = SIMD3<Float>(floorX, floorHeight, floorZ)
        let boxWorld = CollisionVolumeWorld(obstacles: [obstacleBox])
        let proxyWorld = CollisionVolumeWorld(obstacles: [hollowObstacle])
        let solidWorld = CollisionVolumeWorld(obstacles: [solidObstacle])
        let boxOccupy = medianMicros(400) { _ = boxWorld.canOccupy(capsule, at: probe) }
        let hollowOccupy = medianMicros(400) { _ = proxyWorld.canOccupy(capsule, at: probe) }
        let solidOccupy = medianMicros(400) { _ = solidWorld.canOccupy(capsule, at: probe) }
        // 远处落点：整体 AABB 剔除应当让它几乎免费。
        let far = SIMD3<Float>(floorX + 20, floorHeight, floorZ)
        let farOccupy = medianMicros(400) { _ = proxyWorld.canOccupy(capsule, at: far) }
        // canTraverse 的真实代价 = 沿途每 `radius` 采样一次 canOccupy（`PropLayoutCollisionWorld` 就是这条）。
        // 路径刻意贴着物件走：既在两者的 AABB 之外（于是**全部**采样点都要跑，
        // 不是第一个点就被挡掉的提前退出），又是真实行走会发生的那段距离。
        let pathStart = SIMD3<Float>(floorX + 1.5, floorHeight, floorZ)
        let pathLength: Float = 2
        let steps = Int(ceil(pathLength / capsule.radius))
        let pathEnd = SIMD3<Float>(floorX + 1.5 + pathLength, floorHeight, floorZ)
        func propsTraverse(_ world: CollisionVolumeWorld) -> Bool {
            let delta: SIMD3<Float> = pathEnd - pathStart
            for index in 0 ... steps {
                let progress: Float = Float(index) / Float(steps)
                let p: SIMD3<Float> = pathStart + delta * progress
                guard world.canOccupy(capsule, at: p) else { return false }
            }
            return true
        }
        let boxTraverse = medianMicros(200) { _ = propsTraverse(boxWorld) }
        let solidTraverse = medianMicros(200) { _ = propsTraverse(solidWorld) }
        // 对照组：路径**穿过**物件（两者都在第一个采样点就被挡），量的是 fail-fast 的代价。
        func crossingsTraverse(_ world: CollisionVolumeWorld) -> Bool {
            let from = SIMD3<Float>(floorX - 3, floorHeight, floorZ)
            let to = SIMD3<Float>(floorX + 3, floorHeight, floorZ)
            let delta: SIMD3<Float> = to - from
            for index in 0 ... steps {
                let progress: Float = Float(index) / Float(steps)
                let p: SIMD3<Float> = from + delta * progress
                guard world.canOccupy(capsule, at: p) else { return false }
            }
            return true
        }
        let boxCrossing = medianMicros(200) { _ = crossingsTraverse(boxWorld) }
        let solidCrossing = medianMicros(200) { _ = crossingsTraverse(solidWorld) }
        let solidTriangleCount = solidTriangles.count
        let hollowTriangleCount = hollowTriangles.count
        print(String(format: "        代理规模：实心 %d 三角形、空心 %d 三角形（契约上限 %d），代理字节上限 %d KiB",
                     solidTriangleCount, hollowTriangleCount, WorldPropCollisionProxy.maximumTriangles,
                     WorldPropCollisionProxy.maximumBytes / 1024))
        print(String(format: "        单次 canOccupy（含整体 AABB 剔除）：盒子 中位 %.1f µs p95 %.1f µs；实心代理 中位 %.1f µs p95 %.1f µs；空心代理 中位 %.1f µs p95 %.1f µs；远处代理（整体剔除）中位 %.1f µs",
                     boxOccupy.median, boxOccupy.p95, solidOccupy.median, solidOccupy.p95,
                     hollowOccupy.median, hollowOccupy.p95, farOccupy.median))
        check(propsTraverse(boxWorld) && propsTraverse(solidWorld),
              "量 canTraverse 的这条路径必须对盒子与代理都放行（否则量到的是提前退出）")
        print(String(format: "        canTraverse（2 m 路径、%d 次采样、只算物件那一侧）：全程放行 盒子 中位 %.1f µs / 实心代理 中位 %.1f µs（每个落点 ~%.2f / %.2f µs）；穿过物件（首个采样点即挡）盒子 %.1f µs / 代理 %.1f µs",
                     steps + 1, boxTraverse.median, solidTraverse.median,
                     boxTraverse.median / Double(steps + 1), solidTraverse.median / Double(steps + 1),
                     boxCrossing.median, solidCrossing.median))
        check(boxOccupy.median < 100, "盒子单次 canOccupy 必须是几十微秒以内（实测中位 \(boxOccupy.median) µs）")
        // 代理的三角形上限是契约的一部分：几千个三角形必须仍然是**微秒/几十微秒**量级。
        check(solidOccupy.median < 500 && hollowOccupy.median < 500,
              "代理单次 canOccupy 必须有界（实测中位 实心 \(solidOccupy.median) µs / 空心 \(hollowOccupy.median) µs）")
        check(farOccupy.median <= max(solidOccupy.median, 20),
              "远处落点必须被整体 AABB 剔除（实测中位 \(farOccupy.median) µs，实心代理 \(solidOccupy.median) µs）")
        check(solidTraverse.median < 4000, "代理的 canTraverse（物件侧）必须有界（实测中位 \(solidTraverse.median) µs）")
        check(solidCrossing.median < 4000, "穿过物件的 canTraverse 必须有界（实测中位 \(solidCrossing.median) µs）")
        print(String(format: "PASS[6]: 性能有界 —— 单次 canOccupy 盒子 %.1f µs → 实心代理 %.1f µs（%.2f×）/ 空心代理 %.1f µs（%.2f×）；实测耗时都随代理的三角形数有界（契约上限 %d 个三角形 / %d KiB）",
                     boxOccupy.median, solidOccupy.median,
                     solidOccupy.median / max(boxOccupy.median, 0.001), hollowOccupy.median,
                     hollowOccupy.median / max(boxOccupy.median, 0.001),
                     WorldPropCollisionProxy.maximumTriangles, WorldPropCollisionProxy.maximumBytes / 1024))

        // =====================================================================
        // A7「保守盒子 vs 真代理」的**假拒绝率**（真实地面格，贴数字）
        // =====================================================================
        //
        // 交接期（摆放服务还在用 `.volumes` 的保守 yaw OBB）与接线后（用 `.obstacles` 的
        // 真代理）差多少？对每一格真实地面格问同一个问题：
        // 「这间房里已经放着这件细长物件，还能不能再放一只小杯子？」
        // —— 两次只差"已放障碍用包围盒还是用代理"，别的输入逐字相同。
        var plankOnlyState = state
        plankOnlyState.objectStates = [plank.objectID: plank.object]
        let plankResolution = WorldLayoutObstacles.resolve(plankOnlyState)
        check(plankResolution.obstacles.count == 1 && plankResolution.unmodelledObjectIDs.isEmpty,
              "细长物件的代理必须解得出来（否则这条测量没有意义）")
        let plankObstacle = plankResolution.obstacles[0]
        let plankBoxObstacle = WorldPropObstacle(volume: plankObstacle.conservativeBoxProjection)
        let candidateFootprint = WorldPlanarFootprint(size: SIMD2<Float>(0.2, 0.2), yaw: 0)
        let candidateHeight: Float = 0.15
        let blockingVolumes = manifest.collisionVolumes.filter(\.isBlocking)
        let floors = grid.layers.filter { $0.supportHeight < floorHeight + 0.3 }
        func verdict(_ placedObstacle: WorldPropObstacle, _ layer: PropSupportLayerRef) -> Bool {
            PropPlacementEvaluator.evaluate(
                footprint: candidateFootprint, height: candidateHeight, at: layer,
                grid: grid, collision: derivation,
                blockingVolumes: blockingVolumes, placedObstacles: [placedObstacle]
            ) == nil
        }
        var boxAllowed = 0, proxyAllowed = 0, falseRejections = 0, affected = 0
        var example: String? = nil
        for layer in floors {
            let cx = (Float(layer.column.x) + 0.5) * grid.spacing
            let cz = (Float(layer.column.z) + 0.5) * grid.spacing
            let reach = plankObstacle.conservativeBoxProjection.halfExtents
            let withinBox = abs(cx - Float(plankObstacle.conservativeBoxProjection.center.x)) <= Float(reach.x) + 0.5
                && abs(cz - Float(plankObstacle.conservativeBoxProjection.center.z)) <= Float(reach.z) + 0.5
            if withinBox { affected += 1 }
            let viaProxy = verdict(plankObstacle, layer)
            let viaBox = verdict(plankBoxObstacle, layer)
            if viaProxy { proxyAllowed += 1 }
            if viaBox { boxAllowed += 1 }
            if viaProxy && !viaBox {
                falseRejections += 1
                if example == nil {
                    example = "cell=(\(layer.column.x),\(layer.column.z)) 保守盒=拒绝 → 真代理=可放"
                }
            }
        }
        // 反方向必须是**零**：保守盒放行的地方，代理也必须放行（包围盒包含代理）。
        // 这一条是"保守投影不会漏挡"在真实地面格上的表述；非零就是 fail-open。
        var boxAllowsProxyRejects = 0
        for layer in floors {
            if verdict(plankBoxObstacle, layer) && !verdict(plankObstacle, layer) {
                boxAllowsProxyRejects += 1
            }
        }
        check(boxAllowsProxyRejects == 0,
              "保守盒放行而代理拒绝的格子必须为 0（实测 \(boxAllowsProxyRejects) 格 —— 包围盒没有包含代理）")
        let rate = affected > 0 ? 100.0 * Double(falseRejections) / Double(affected) : 0
        print(String(format: "PASS[7]: 保守 yaw OBB 的假拒绝 —— 真实地面 %d 格里，落在细长物件包围盒影响圈内的 %d 格中，%d 格从「保守盒说不可放」变成「真代理说可放」（该圈内 %.1f%%）；例：%@",
                     floors.count, affected, falseRejections, rate, example ?? "-"))
        check(falseRejections > 0,
              "细长物件必须能实测出保守盒的假拒绝（实测 \(falseRejections) 格），否则「分两步落地」的收尾证据是空的")

        print("PASS: \(checks) 项断言全部通过（真实舱体 \(triangles.count) 三角形、\(grid.layers.count) 承托层、\(map.standableNodeCount) 可站节点）")
    }
}

"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-collproxy-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("CollisionProxy.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let worldRuntimeModules = worldRuntimeFlags[1]
let objects = Array(worldRuntimeFlags.dropFirst(2))
let executable = temporary.appendingPathComponent("collproxy")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-parse-as-library", "-O", "-I", worldRuntimeModules,
    program.path, "-o", executable.path] + objects
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { print("FAIL: 编译失败（swiftc 退出码 \(process.terminationStatus)）"); exit(1) }
let run = Process()
run.executableURL = executable
run.arguments = []
try run.run()
run.waitUntilExit()
exit(run.terminationStatus)
