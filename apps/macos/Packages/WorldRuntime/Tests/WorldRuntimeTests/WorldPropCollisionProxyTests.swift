import Foundation
import Testing
@testable import WorldRuntime

// ===========================================================================
// 生成工作流自带的碰撞数据：**缺失/存在/非法/解不出** 四态的行为
// ===========================================================================
//
// 这四条断言是这一轮验收的核心，每一条都对应一种"悄悄变坏"的方式：
//
// 1. **缺失** ⇒ 与今天逐字节一致（元数据 JSON 不变、形状仍是 yaw 盒子、尺寸仍读 `size`）；
// 2. **存在** ⇒ 碰撞用代理、尺寸以权威值为准，而且判定只有**一条**通路；
// 3. **非法** ⇒ 明确错误（形不成 `WorldPropCollisionProxy`，元数据判无效）；
// 4. **解不出** ⇒ 可见拒绝（进 `unmodelledObjectIDs`，不是"这里没有东西"）。

private let proxySHA = String(repeating: "a", count: 64)

/// 一份**归一化**的代理：底面 y=0、顶面 y=1、X/Z 居中。
///
/// `outline` 给的是 X/Z 上的轮廓点（单位正方形坐标），高度固定 0..1。
/// 用一个"方柱"或一个"U 形柱"就能分别演示"实心"与"凹形"。
private func normalizedProxy(_ outline: [(Float, Float)], top: Float = 1) -> [WorldTriangle] {
    let insetOutline = outline.map { SIMD2<Float>($0.0 * 0.5, $0.1 * 0.5) }
    var triangles: [WorldTriangle] = []
    let base = SIMD3<Float>(0, 0, 0)
    // 侧面
    for index in insetOutline.indices {
        let a = insetOutline[index]
        let b = insetOutline[(index + 1) % insetOutline.count]
        let bottomA = SIMD3<Float>(a.x, 0, a.y)
        let bottomB = SIMD3<Float>(b.x, 0, b.y)
        let topA = SIMD3<Float>(a.x, top, a.y)
        let topB = SIMD3<Float>(b.x, top, b.y)
        triangles.append(WorldTriangle(bottomA, bottomB, topB))
        triangles.append(WorldTriangle(bottomA, topB, topA))
    }
    // 顶面 / 底面（扇形三角化；轮廓是凸的或"U"形时都够用）
    for index in 1 ..< (insetOutline.count - 1) {
        let a = insetOutline[0], b = insetOutline[index], c = insetOutline[index + 1]
        triangles.append(WorldTriangle(SIMD3(a.x, top, a.y), SIMD3(b.x, top, b.y), SIMD3(c.x, top, c.y)))
        triangles.append(WorldTriangle(SIMD3(a.x, 0, a.y), SIMD3(c.x, 0, c.y), SIMD3(b.x, 0, b.y)))
    }
    _ = base
    return triangles
}

/// 造一个唯一且形状合法的 64 位十六进制摘要（测试用）。
private func testSHA(_ seed: UInt8) -> String {
    String(repeating: String(format: "%02x", seed), count: 32)
}

private let objectID = "wish.object.1"

/// 实心方柱：X/Z 半宽 `half`，y 从 0 到 `top`。归一化（底面 y=0、X/Z 居中）自动成立。
private func solidBlock(half: Float, top: Float = 1) -> [WorldTriangle] {
    let corners: [(Float, Float)] = [(-half, -half), (half, -half), (half, half), (-half, half)]
    var triangles: [WorldTriangle] = []
    for index in corners.indices {
        let a = corners[index], b = corners[(index + 1) % corners.count]
        triangles.append(WorldTriangle(SIMD3(a.0, 0, a.1), SIMD3(b.0, 0, b.1), SIMD3(b.0, top, b.1)))
        triangles.append(WorldTriangle(SIMD3(a.0, 0, a.1), SIMD3(b.0, top, b.1), SIMD3(a.0, top, a.1)))
    }
    // 顶面 + 底面
    triangles.append(WorldTriangle(SIMD3(-half, top, -half), SIMD3(half, top, -half), SIMD3(half, top, half)))
    triangles.append(WorldTriangle(SIMD3(-half, top, -half), SIMD3(half, top, half), SIMD3(-half, top, half)))
    triangles.append(WorldTriangle(SIMD3(-half, 0, -half), SIMD3(half, 0, half), SIMD3(half, 0, -half)))
    triangles.append(WorldTriangle(SIMD3(-half, 0, -half), SIMD3(-half, 0, half), SIMD3(half, 0, half)))
    return triangles
}

/// **空心管**：外壁 `outer`、内壁 `inner`（`inner < outer`），两端**不封口**。
///
/// 这是"凹形/薄壁"物件的模型：它的世界轴包围盒是 `[-outer, outer]²`（与同尺寸实心块
/// **完全一样**），但管腔里什么都没有。盒子（只按尺寸猜）会把管腔整块挡死 ——
/// 那正是"挡空气"。代理把它留空。
private func hollowTube(outer: Float, inner: Float, top: Float = 1) -> [WorldTriangle] {
    let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    var triangles: [WorldTriangle] = []
    for index in corners.indices {
        let next = corners[(index + 1) % corners.count]
        for (firstHalf, secondHalf, flip) in [(outer, inner, false), (inner, outer, true)] {
            let a = SIMD3(corners[index].0 * firstHalf, 0, corners[index].1 * firstHalf)
            let b = SIMD3(next.0 * firstHalf, 0, next.1 * firstHalf)
            let c = SIMD3(next.0 * secondHalf, top, next.1 * secondHalf)
            let d = SIMD3(corners[index].0 * secondHalf, top, corners[index].1 * secondHalf)
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

private func installed(
    _ seed: UInt8,
    triangles: [WorldTriangle]
) -> (String, WorldPropCollisionProxyMesh) {
    let sha = testSHA(seed)
    let mesh = WorldPropCollisionProxyMesh(triangles: triangles, sourceSHA256: sha)!
    WorldPropCollisionProxyStore.shared.install(mesh)
    return (sha, mesh)
}

private func installedProxy(_ seed: UInt8, outline: [(Float, Float)]) -> (String, WorldPropCollisionProxyMesh) {
    // 兼容旧的调用点：`outline` 是单位正方形的轮廓点，半宽取 1（与 solidBlock 同）。
    _ = outline
    return installed(seed, triangles: solidBlock(half: 1))
}

private func prop(
    collision: WorldPropCollisionProxy? = nil,
    authoritativeSize: WorldPropAuthoritativeSize? = nil,
    size: WorldVector3 = .init(x: 0.3, y: 0.42, z: 0.4),
    yaw: Float = 0,
    position: WorldVector3 = .init(x: 1, y: 0.5, z: 1),
    id: String = objectID
) -> WorldObjectState {
    let value = WorldGeneratedProp(
        objectID: id, sourceWishID: "wish1", assetID: "asset1",
        displayName: "斧头", size: size, sourceHeight: 1,
        collision: collision, authoritativeSize: authoritativeSize
    )
    return WorldObjectState(
        isEnabled: true,
        transform: WorldTransform(
            position: position,
            rotation: WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
            scale: .init(x: 1, y: 1, z: 1)
        ),
        metadata: ["gmgn.generated-prop.v1": String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)]
    )
}

/// 一块够大的平地，用来派生承托网格（移动图需要它）。
private struct FlatSupportPlane: WorldPropSupportQuerying {
    let height: Float = 0.5
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
    func groundHeight(at position: SIMD3<Float>) -> Float? { height }
    func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>,
                     to destination: SIMD3<Float>, maximumStepHeight: Float) -> Bool { true }
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        guard let xRange = propSupportColumnRange(minimum: bounds.minimumX, maximum: bounds.maximumX, spacing: 0.25),
              let zRange = propSupportColumnRange(minimum: bounds.minimumZ, maximum: bounds.maximumZ, spacing: 0.25)
        else { return [] }
        var result: [WorldTriangle] = []
        for x in xRange {
            for z in zRange {
                let x0 = Float(x) * 0.25, x1 = x0 + 0.25
                let z0 = Float(z) * 0.25, z1 = z0 + 0.25
                result.append(WorldTriangle(SIMD3(x0, height, z0), SIMD3(x1, height, z0), SIMD3(x1, height, z1)))
                result.append(WorldTriangle(SIMD3(x0, height, z0), SIMD3(x1, height, z1), SIMD3(x0, height, z1)))
            }
        }
        return result
    }
}

private func state(_ objects: [WorldObjectState]) -> WorldState {
    var state = WorldState(
        revision: 1, worldID: "room", worldTime: .distantPast,
        lastObservedWallTime: .distantPast, weather: .clear,
        agentTransform: WorldTransform(
            position: .init(x: 0, y: 0, z: 0),
            rotation: .init(x: 0, y: 0, z: 0, w: 1),
            scale: .init(x: 1, y: 1, z: 1)
        )
    )
    for (index, object) in objects.enumerated() {
        state.objectStates[index == 0 ? objectID : "\(objectID).\(index)"] = object
    }
    return state
}

// MARK: - 断言 1：缺失 ⇒ 与今天逐字节一致

/// 没有 `collision` / `authoritativeSize` 时：
/// - 元数据 JSON 里**不出现**新键（旧库/旧客户端读到的字节不变）；
/// - 尺寸仍然就是 app 量的那一份（`effectiveSize == size`，来源 = `app-measured`）；
/// - 形状仍然是**今天那个** yaw 盒子，逐字段相等。
@Test func aPropWithoutWorkflowCollisionDataIsByteForByteTodaysProp() throws {
    let object = prop()
    let previous = WorldGeneratedProp(
        objectID: "wish.object.1", sourceWishID: "wish1", assetID: "asset1",
        displayName: "斧头", size: .init(x: 0.3, y: 0.42, z: 0.4), sourceHeight: 1
    )
    let decoded = object.generatedProp!
    #expect(decoded == previous, "没有新字段时解码出来的物件必须与改造前逐字段相等")
    let json = object.metadata["gmgn.generated-prop.v1"]!
    #expect(!json.contains("collision"), "缺失时不得编码 collision：元数据 JSON 必须与改造前一致")
    #expect(!json.contains("authoritativeSize"), "缺失时不得编码 authoritativeSize")
    // 今天那条路上的形状逐字段不变。
    #expect(decoded.effectiveSize == decoded.size)
    #expect(decoded.sizeSource == .appMeasured)
    let expected = WorldCollisionVolume(
        id: "wish.object.1",
        center: .init(x: 1, y: 0.5 + 0.21, z: 1),
        halfExtents: .init(x: 0.15, y: 0.21, z: 0.2),
        rotation: .init(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    #expect(object.generatedCollisionVolume == expected)
    let resolution = WorldLayoutObstacles.resolve(state([object]))
    #expect(resolution.unmodelledObjectIDs.isEmpty)
    #expect(resolution.obstacles.map(\.shape) == [.orientedBox(expected)])
    #expect(resolution.volumes == [expected], "只认盒子的旧投影必须与今天那个盒子逐字段一致")
}

// MARK: - 断言 2：存在 ⇒ 用代理、尺寸以权威值为准、判定只有一条通路

/// 两个**包围盒完全相同**的代理（实心方柱 vs 凹形 U 柱）：
/// - 盒子那条路给两者**同一个**答案（因为盒子只看尺寸）；
/// - 代理那条路给两者**不同**的答案。
///
/// 这就是"换生成后端 ⇒ 轮廓不同 ⇒ 碰撞不同"被修好的**可观测**证据：碰撞由工作流给的
/// 代理决定，而不是由 app 猜的盒子决定。
@Test func twoBackendsWithTheSameBoundsGetDifferentCollisionOnlyThroughTheProxy() throws {
    // 两个**后端**：实心块 vs 空心管。它们的归一化包围盒完全一样（都是 half=1），
    // 于是"按尺寸猜出来的盒子"给不出任何区别 —— 这正是跨后端不一致的根源。
    let solid = installed(0x3, triangles: solidBlock(half: 1))
    let hollow = installed(0x7, triangles: hollowTube(outer: 1, inner: 0.85))
    #expect(solid.1.minimum == hollow.1.minimum)
    #expect(solid.1.maximum == hollow.1.maximum, "两个代理必须共享同一个包围盒，否则这条对照不成立")

    // 目标高度 3 m（最长边上限）⇒ 归一化半宽 1 → 世界半宽 1.5 m，底面 y=0.5。
    let height: Float = 3
    let boxWorld = WorldCollisionVolume(
        id: objectID, center: .init(x: 1, y: 0.5 + height / 2, z: 1),
        halfExtents: .init(x: 1.5, y: height / 2, z: 1.5),
        rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
    )
    // 一个站在"盒子正中央、管腔里"的落点：盒子挡、空心管不挡。
    let inTheHollow = SIMD3<Float>(1, 0.5, 1)
    let capsule = WorldCapsule(radius: 0.25, height: 1.8)
    #expect(!WorldCapsuleClearance.isClear(capsule, at: inTheHollow, of: WorldPropObstacle(volume: boxWorld)), "盒子必须挡住管腔里的落点（这就是挡空气）")

    let solidObstacle = WorldPropObstacle(
        id: objectID, isBlocking: true,
        shape: .proxyMesh(solid.1.placed(id: objectID, format: .glbHull, position: .init(x: 1, y: 0.5, z: 1), yaw: 0, heightMeters: height)!)
    )
    let hollowObstacle = WorldPropObstacle(
        id: objectID, isBlocking: true,
        shape: .proxyMesh(hollow.1.placed(id: objectID, format: .glbDecimated, position: .init(x: 1, y: 0.5, z: 1), yaw: 0, heightMeters: height)!)
    )
    // 代理这一侧：实心挡、空心管不挡 —— 两个后端给出**不同**答案。
    #expect(!WorldCapsuleClearance.isClear(capsule, at: inTheHollow, of: solidObstacle), "实心代理必须挡住它")
    #expect(WorldCapsuleClearance.isClear(capsule, at: inTheHollow, of: hollowObstacle), "空心代理必须放行管腔里的落点（盒子会挡空气）")
    // 而"按尺寸猜的盒子"对这两个后端只能给出**同一个**答案（都挡）。
    #expect(
        !WorldCapsuleClearance.isClear(capsule, at: inTheHollow, of: WorldPropObstacle(volume: boxWorld)),
        "同一尺寸下盒子对两个后端给出同一个答案 —— 这就是要修掉的跨后端不一致"
    )
    // 完全落在实体里的候选盒子必须判重叠（否则小物件能整个塞进大物件）。
    let inside = WorldCollisionVolume(
        id: "prop.preview", center: .init(x: 1, y: 0.5 + height / 2, z: 1),
        halfExtents: .init(x: 0.05, y: 0.05, z: 0.05),
        rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
    )
    #expect(WorldPropObstacleOverlap.overlaps(box: inside, obstacle: solidObstacle), "完全落在实心代理里的盒子必须判重叠")
    #expect(!WorldPropObstacleOverlap.overlaps(box: inside, obstacle: hollowObstacle), "完全落在管腔里的盒子不得判重叠")
}

/// 断言"只有一条判定通路"：三个消费者（运行时胶囊世界、通路预检、互斥预检）
/// 与 `WorldCapsuleClearance` 对同一批落点给出**逐点相同**的答案。
@Test func everyConsumerGetsItsAnswerFromTheOneClearanceFunction() throws {
    let proxy = installed(0xb, triangles: hollowTube(outer: 1, inner: 0.9))
    let object = prop(
        collision: .init(url: "/v1/jobs/x/collider.glb", format: .glbDecimated, sha256: proxy.0, bytes: 1024, triangles: proxy.1.triangles.count),
        size: .init(x: 1, y: 1, z: 1)
    )
    let resolution = WorldLayoutObstacles.resolve(state([object]))
    #expect(resolution.unmodelledObjectIDs.isEmpty)
    guard case .proxyMesh(let mesh)? = resolution.obstacles.first?.shape else {
        Issue.record("元数据声明了代理，形状必须是 .proxyMesh（实测 \(String(describing: resolution.obstacles.first?.shape))）")
        return
    }
    // 代理确实被摆到了世界坐标：包围盒中心应当落在物件的 X/Z 与底面之上。
    #expect(abs((mesh.minimum.z + mesh.maximum.z) / 2 - 1) <= 0.001)
    #expect(abs(mesh.minimum.y - 0.5) <= 0.001, "代理的底面必须落在物件的底面（y=0.5）上")

    let capsule = WorldCapsule(radius: 0.25, height: 1.8)
    let world = CollisionVolumeWorld(obstacles: resolution.obstacles)
    var checked = 0
    var blockedByWorld = 0
    var blockedByFunction = 0
    for x in stride(from: Float(-0.5), through: 2.5, by: 0.1) {
        for z in stride(from: Float(-0.5), through: 2.5, by: 0.1) {
            let position = SIMD3<Float>(x, 0.5, z)
            let viaWorld = world.canOccupy(capsule, at: position)
            let viaFunction = resolution.obstacles.allSatisfy {
                WorldCapsuleClearance.isClear(capsule, at: position, of: $0)
            }
            #expect(viaWorld == viaFunction, "运行时世界与判据函数在 (\(x),\(z)) 上分叉了")
            checked += 1
            if !viaWorld { blockedByWorld += 1 }
            if !viaFunction { blockedByFunction += 1 }
        }
    }
    #expect(checked > 300)
    #expect(blockedByWorld > 0 && blockedByWorld == blockedByFunction, "这批落点里必须有被挡住的，否则断言没被真正跑到")

    // 通路预检：同一个障碍，同一个答案。
    let grid = PropSupportGridBuilder.build(
        collision: FlatSupportPlane(),
        bounds: WorldPlanarBounds(minimumX: 0, maximumX: 2, minimumZ: 0, maximumZ: 2),
        seed: WorldVector3(x: 0.5, y: 0.5, z: 0.5),
        parameters: PropSupportGridParameters(spacing: 0.5)
    )
    let map = WorldPlacementRouteMap(grid: grid, lowerHeight: 0.0, upperHeight: 1.4)
    let viaMap = map.blockedNodes(obstacle: resolution.obstacles[0])
    let viaMapLegacy = map.blockedNodes(volume: resolution.obstacles[0].conservativeBoxProjection)
    var expectedNodes: Set<Int> = []
    // 用判据函数直接复算：只有"站在这根节点上会被挡"的节点才算被占。
    for x in 0 ..< 4 {
        for z in 0 ..< 4 {
            let column = PropSupportColumn(x: x, z: z)
            guard let height = grid.layers(at: column).first?.supportHeight else { continue }
            let cx = (Float(x) + 0.5) * 0.5
            let cz = (Float(z) + 0.5) * 0.5
            guard let node = map.node(at: WorldVector3(x: cx, y: height, z: cz)) else { continue }
            if !WorldCapsuleClearance.isClear(capsule, at: SIMD3(cx, height, cz), of: resolution.obstacles[0]) {
                expectedNodes.insert(node)
            }
        }
    }
    #expect(viaMap == expectedNodes, "通路预检的被占节点必须与判据函数逐点一致")
    #expect(!viaMap.isEmpty, "这件代理必须真的占掉一些节点，否则断言没被跑到")
    #expect(viaMap != viaMapLegacy, "空心代理与它的保守包围盒必须给出不同的节点集（否则代理没被真正用上）")

    // 互斥预检：候选盒子 × 代理障碍。
    // 空心管的外半宽是 1.0、内半宽 0.9（物件的目标高度就是 1 m），所以"管壁"落在
    // |x-1| ≈ 0.95 上。候选盒子放两个位置：管壁里（重叠）与管腔里（不重叠）。
    let inTheWall = WorldCollisionVolume(
        id: "prop.preview", center: .init(x: 1.95, y: 0.7, z: 1),
        halfExtents: .init(x: 0.03, y: 0.2, z: 0.03),
        rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
    )
    #expect(
        WorldPropObstacleOverlap.overlaps(box: inTheWall, obstacle: resolution.obstacles[0]),
        "落在管壁里的候选盒子必须判重叠"
    )
    let inTheCavity = WorldCollisionVolume(
        id: "prop.preview", center: .init(x: 1, y: 0.7, z: 1),
        halfExtents: .init(x: 0.1, y: 0.2, z: 0.1),
        rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
    )
    #expect(
        !WorldPropObstacleOverlap.overlaps(box: inTheCavity, obstacle: resolution.obstacles[0]),
        "落在管腔（空的那一块）里的候选盒子不得判重叠（盒子会假拒绝）"
    )
    let farAway = WorldCollisionVolume(
        id: "prop.preview", center: .init(x: 5, y: 0.7, z: 5),
        halfExtents: .init(x: 0.1, y: 0.2, z: 0.1),
        rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
    )
    #expect(
        !WorldPropObstacleOverlap.overlaps(box: farAway, obstacle: resolution.obstacles[0]),
        "离得很远的候选盒子不得判重叠"
    )
}

/// 有权威尺寸时**不再**从网格量：`effectiveSize` 就是权威值，盒子按它构造，
/// 而且来源可查（审计）。
@Test func authoritativeSizeOverridesTheMeasuredSizeAndRecordsItsSource() throws {
    let authoritative = WorldPropAuthoritativeSize(
        dimensions: .init(x: 0.9, y: 0.42, z: 0.1), units: "m", upAxis: "+Y", forwardAxis: "-Z"
    )
    let object = prop(authoritativeSize: authoritative, size: .init(x: 0.3, y: 0.42, z: 0.4))
    let decoded = object.generatedProp!
    #expect(decoded.effectiveSize == authoritative.dimensions, "有权威尺寸时尺寸必须以它为准")
    #expect(decoded.sizeSource == .workflowAuthoritative, "来源必须可查（审计字段）")
    #expect(decoded.size == .init(x: 0.3, y: 0.42, z: 0.4), "app 量的那一份仍然留着，只是不再当权威值")
    // 盒子按权威尺寸构造，而不是 app 量的那一份。
    let volume = object.generatedCollisionVolume!
    #expect(abs(volume.halfExtents.x - 0.45) < 0.0001, "碰撞盒必须用权威宽度 0.9/2")
    #expect(abs(volume.halfExtents.z - 0.05) < 0.0001, "碰撞盒必须用权威厚度 0.1/2")
}

// MARK: - 断言 3：非法 ⇒ 明确错误，不静默

/// 非法的代理描述与权威尺寸**不得**被当成"没有这一块"。
///
/// 做法：整件物件的 `isValid` 直接为 false ⇒ `generatedProp` 返回 nil ⇒ 摆放判据把它
/// 记成 `unmodelledObjectIDs`（可见拒绝）。这正是"不静默"的落点。
@Test func malformedWorkflowCollisionDataIsNeverSilentlyIgnored() throws {
    let badProxy = WorldPropCollisionProxy(
        url: "/v1/jobs/x/collider.glb", format: .glbHull,
        sha256: "not-a-digest", bytes: 1024, triangles: 512
    )
    #expect(!badProxy.isValid)
    let object = prop(collision: badProxy)
    #expect(object.generatedProp == nil, "非法代理必须让整件物件的资料判为无效")
    let resolution = WorldLayoutObstacles.resolve(state([object]))
    #expect(resolution.obstacles.isEmpty)
    #expect(resolution.unmodelledObjectIDs == ["wish.object.1"], "非法代理必须可见地拒绝，而不是当成没有代理")

    // 三角形数超上限 / 字节数超上限 / 路径指到别处：都不合法。
    for invalid in [
        WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: proxySHA, bytes: 1024, triangles: WorldPropCollisionProxy.maximumTriangles + 1),
        WorldPropCollisionProxy(url: "/v1/jobs/x/collider.glb", format: .glbHull, sha256: proxySHA, bytes: WorldPropCollisionProxy.maximumBytes + 1, triangles: 512),
        WorldPropCollisionProxy(url: "https://evil.invalid/collider.glb", format: .glbHull, sha256: proxySHA, bytes: 1024, triangles: 512),
        WorldPropCollisionProxy(url: "/v1/jobs/x/model.glb", format: .glbHull, sha256: proxySHA, bytes: 1024, triangles: 512),
    ] {
        #expect(!invalid.isValid, "\(invalid) 不该被接受")
        #expect(WorldLayoutObstacles.resolve(state([prop(collision: invalid)])).unmodelledObjectIDs == ["wish.object.1"])
    }

    // 非法的权威尺寸同理。
    for invalid in [
        WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 0, z: 1), units: "m", upAxis: "+Y", forwardAxis: "-Z"),
        WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 1, z: 1), units: "cm", upAxis: "+Y", forwardAxis: "-Z"),
        WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 1, z: 1), units: "m", upAxis: "up", forwardAxis: "-Z"),
        WorldPropAuthoritativeSize(dimensions: .init(x: 1, y: 1, z: 101), units: "m", upAxis: "+Y", forwardAxis: "-Z"),
    ] {
        #expect(!invalid.isValid, "\(invalid) 不该被接受")
        #expect(WorldLayoutObstacles.resolve(state([prop(authoritativeSize: invalid)])).unmodelledObjectIDs == ["wish.object.1"])
    }
}

// MARK: - 断言 4：代理解不出 ⇒ 可见拒绝（不放宽）

/// 元数据**声明了**代理，但注册表里没有那一份（文件丢了 / 解码失败 / 没归一化）：
/// 必须进 `unmodelledObjectIDs`，**不能**退回盒子。
@Test func aDeclaredProxyThatCannotBeResolvedIsVisiblyRefused() throws {
    let absent = WorldPropCollisionProxy(
        url: "/v1/jobs/x/collider.glb", format: .glbDecimated,
        sha256: String(repeating: "9", count: 64), bytes: 2048, triangles: 900
    )
    #expect(absent.isValid)
    // 每个测试用**自己那个摘要**，所以并行跑也不会互相干扰（共享注册表是线程安全的，
    // 但绝不能靠"清空整个注册表"来隔离 —— swift-testing 默认并行）。
    #expect(WorldPropCollisionProxyStore.shared.mesh(forSHA256: absent.sha256) == nil)
    let object = prop(collision: absent)
    #expect(object.generatedProp != nil, "代理描述本身合法 ⇒ 物件资料有效")
    #expect(object.generatedCollisionObstacle == nil, "解不出代理时**不得**退回盒子")
    let resolution = WorldLayoutObstacles.resolve(state([object]))
    #expect(resolution.obstacles.isEmpty)
    #expect(resolution.unmodelledObjectIDs == ["wish.object.1"], "解不出代理必须可见拒绝（unmodelledPlacedProp）")
    // 保守投影只在**解得出**形状时才有意义；解不出就一个体积都不该给。
    #expect(resolution.volumes.isEmpty)
}

/// 归一化校验：不归一的代理（底面不在 y=0、XZ 没居中、高度不是 1）**不安装**。
@Test func anUnnormalizedProxyIsRefusedAtInstallTime() throws {
    // 底面在 y=0.3、顶面在 y=1.3 ⇒ 没归零。
    let lifted = WorldPropCollisionProxyMesh(
        triangles: normalizedProxy([(-1, -1), (1, -1), (1, 1), (-1, 1)]).map {
            WorldTriangle($0.first + SIMD3(0, 0.3, 0), $0.second + SIMD3(0, 0.3, 0), $0.third + SIMD3(0, 0.3, 0))
        },
        sourceSHA256: proxySHA
    )
    #expect(lifted == nil, "底面不在 y=0 的代理必须被拒（否则代理与渲染会错位）")
    // X/Z 没居中。
    let offCenter = WorldPropCollisionProxyMesh(
        triangles: normalizedProxy([(-1, -1), (1, -1), (1, 1), (-1, 1)]).map {
            WorldTriangle($0.first + SIMD3(0.5, 0, 0), $0.second + SIMD3(0.5, 0, 0), $0.third + SIMD3(0.5, 0, 0))
        },
        sourceSHA256: proxySHA
    )
    #expect(offCenter == nil, "X/Z 没居中的代理必须被拒")
    // 高度不是 1。
    let squashed = WorldPropCollisionProxyMesh(
        triangles: normalizedProxy([(-1, -1), (1, -1), (1, 1), (-1, 1)], top: 0.5),
        sourceSHA256: proxySHA
    )
    #expect(squashed == nil, "高度不是 1 个单位的代理必须被拒")
    // 三角形数超上限。
    let tooMany = WorldPropCollisionProxyMesh(
        triangles: Array(repeating: normalizedProxy([(-1, -1), (1, -1), (1, 1), (-1, 1)]), count: 2000).flatMap { $0 },
        sourceSHA256: proxySHA
    )
    #expect(tooMany == nil, "三角形数超上限的代理必须被拒（性能有界是契约的一部分）")
    // 合法的那个能装上、也能取回。
    let good = WorldPropCollisionProxyMesh(
        triangles: normalizedProxy([(-1, -1), (1, -1), (1, 1), (-1, 1)]), sourceSHA256: proxySHA
    )
    #expect(good != nil)
    #expect(WorldPropCollisionProxyStore.shared.install(good!))
    #expect(WorldPropCollisionProxyStore.shared.mesh(forSHA256: proxySHA) != nil)
}

/// 保守投影**只会多挡、不会漏挡**：任何被代理挡住的胶囊一定也被投影盒子挡住。
///
/// 这是"只认盒子的旧消费者不会 fail-open"的形式化保证 —— 也是为什么可以先把
/// `volumes` 留着而不同时改所有旧调用点。
@Test func theLegacyBoxProjectionNeverUnderBlocksTheProxy() throws {
    let proxy = installed(0xe, triangles: hollowTube(outer: 1, inner: 0.9))
    let obstacle = WorldPropObstacle(
        id: "wish.object.1", isBlocking: true,
        shape: .proxyMesh(proxy.1.placed(id: objectID, format: .glbDecimated, position: .init(x: 1, y: 0.5, z: 1), yaw: 0.7, heightMeters: 3)!)
    )
    let projection = WorldPropObstacle(volume: obstacle.conservativeBoxProjection)
    let capsule = WorldCapsule(radius: 0.25, height: 1.8)
    var underBlocked = 0
    var overBlocked = 0
    var total = 0
    for x in stride(from: Float(-2.5), through: 4.5, by: 0.05) {
        for z in stride(from: Float(-2.5), through: 4.5, by: 0.05) {
            let position = SIMD3<Float>(x, 0.5, z)
            let proxyBlocked = !WorldCapsuleClearance.isClear(capsule, at: position, of: obstacle)
            let projectionBlocked = !WorldCapsuleClearance.isClear(capsule, at: position, of: projection)
            if proxyBlocked && !projectionBlocked { underBlocked += 1 }
            if projectionBlocked && !proxyBlocked { overBlocked += 1 }
            if proxyBlocked { total += 1 }
        }
    }
    #expect(total > 0, "这批落点里必须有被代理挡住的，否则断言没被真正跑到")
    #expect(underBlocked == 0, "保守投影漏挡了 \(underBlocked) 个落点（fail-open）")
    #expect(overBlocked > 0, "保守投影必须比空心代理多挡一些落点（否则这条投影的说明是空话）")

    // 投影必须保住**物件的偏航角**：旧消费者（`ResidentPropPlacementService`）从盒子的
    // 四元数反推 footprint 的 yaw。给一个恒等旋转的盒子会让转过的物件 footprint 不转 ——
    // 那正是 2026-09-30 斧头那个"摆放预检与运行时两个答案"的老毛病。
    let projectionYaw = atan2(
        2 * (projection.conservativeBoxProjection.rotation.w * projection.conservativeBoxProjection.rotation.y),
        1 - 2 * projection.conservativeBoxProjection.rotation.y * projection.conservativeBoxProjection.rotation.y
    )
    #expect(abs(projectionYaw - 0.7) < 0.0001,
            "保守投影必须沿用物件的偏航角 0.7，实测 \(projectionYaw)")
    // 投影必须真的**包含**代理：任何被代理挡住的胶囊一定也被投影挡住（上面已逐点验证），
    // 另外再钉一次包围关系（代理的 AABB 必须落在投影的盒子里）。
    #expect(projection.conservativeBoxProjection.halfExtents.x > 0
        && projection.conservativeBoxProjection.halfExtents.y > 0
        && projection.conservativeBoxProjection.halfExtents.z > 0,
        "投影的半尺寸必须严格为正（否则 OrientedBox 判它无法表示）")
}


// MARK: - 回执 → 契约类型 的换算（宿主那一行要用的唯一入口）

/// 回执那一组字段是**平铺**的、可选的。三种输入必须得到三种明确结果。
@Test func theReceiptToContractMappingIsExplicitAboutMissingAndIllegal() {
    // 全缺 ⇒ nil（"这个后端没有代理"，行为与今天一致）。
    #expect(WorldPropCollisionProxy.fromReceipt(url: nil, format: nil, sha256: nil, bytes: nil, triangles: nil) == nil)
    #expect(WorldPropAuthoritativeSize.fromReceipt(dimensions: nil, units: nil, upAxis: nil, forwardAxis: nil) == nil)

    // 全在且合法 ⇒ 构造出来。
    let proxy = WorldPropCollisionProxy.fromReceipt(
        url: "/v1/jobs/00000000000000000000000000000000/collider.glb",
        format: "glb-hull", sha256: String(repeating: "a", count: 64), bytes: 4096, triangles: 512
    )
    #expect(proxy != nil)
    #expect(proxy?.format == .glbHull)
    let size = WorldPropAuthoritativeSize.fromReceipt(
        dimensions: [0.35, 0.42, 0.57], units: "m", upAxis: "+Y", forwardAxis: "-Z"
    )
    #expect(size != nil)
    #expect(size?.dimensions.y == 0.42)

    // 部分缺 / 格式不在白名单 / 值越界 ⇒ nil（宿主据此退回今天的行为，不静默用半份数据）。
    for (url, format, sha, bytes, triangles) in [
        (String?.none, String?.some("glb-hull"), String?.some(String(repeating: "a", count: 64)), Int?.some(4096), Int?.some(512)),
        (String?.some("/v1/jobs/x/collider.glb"), String?.none, String?.some(String(repeating: "a", count: 64)), Int?.some(4096), Int?.some(512)),
        (String?.some("/v1/jobs/x/collider.glb"), String?.some("obj-mesh"), String?.some(String(repeating: "a", count: 64)), Int?.some(4096), Int?.some(512)),
        (String?.some("/v1/jobs/x/collider.glb"), String?.some("glb-hull"), String?.some("nope"), Int?.some(4096), Int?.some(512)),
        (String?.some("/v1/jobs/x/collider.glb"), String?.some("glb-hull"), String?.some(String(repeating: "a", count: 64)), Int?.some(0), Int?.some(512)),
        (String?.some("/v1/jobs/x/collider.glb"), String?.some("glb-hull"), String?.some(String(repeating: "a", count: 64)), Int?.some(4096), Int?.some(WorldPropCollisionProxy.maximumTriangles + 1)),
        (String?.some("https://evil.invalid/collider.glb"), String?.some("glb-hull"), String?.some(String(repeating: "a", count: 64)), Int?.some(4096), Int?.some(512)),
    ] {
        #expect(
            WorldPropCollisionProxy.fromReceipt(url: url, format: format, sha256: sha, bytes: bytes, triangles: triangles) == nil,
            "非法组合必须得到 nil：\(url ?? "-")/\(format ?? "-")/\(bytes ?? -1)/\(triangles ?? -1)"
        )
    }
    for (dimensions, units, up, forward) in [
        ([Double]?.some([1, 2]), String?.some("m"), String?.some("+Y"), String?.some("-Z")),
        ([Double]?.some([1, 2, 3]), String?.some("cm"), String?.some("+Y"), String?.some("-Z")),
        ([Double]?.some([1, 2, 3]), String?.some("m"), String?.some("up"), String?.some("-Z")),
        ([Double]?.some([1, 2, 3]), String?.some("m"), String?.some("+Y"), String?.some("-W")),
        ([Double]?.some([1, 0, 3]), String?.some("m"), String?.some("+Y"), String?.some("-Z")),
    ] {
        #expect(
            WorldPropAuthoritativeSize.fromReceipt(dimensions: dimensions, units: units, upAxis: up, forwardAxis: forward) == nil,
            "非法权威尺寸必须得到 nil：\(dimensions ?? [])/\(units ?? "-")"
        )
    }
}
