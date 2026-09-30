import Foundation
import Testing
@testable import WorldRuntime

/// 移动图（"居民还走不走得到活动锚点"）的单元验证。
///
/// 判据本身是收窄规则的核心：**只有把唯一通路切断才拒绝**。这里用合成平面把四种情形
/// 各自钉住 —— 尤其"堵死唯一一列"必须被拒，而"旁边还有路"必须放行。
private struct FlatPlane: WorldPropSupportQuerying {
    let minimumX: Float
    let maximumX: Float
    let minimumZ: Float
    let maximumZ: Float
    let height: Float

    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        position.x >= minimumX - 1 && position.x <= maximumX + 1
            && position.z >= minimumZ - 1 && position.z <= maximumZ + 1
    }
    func groundHeight(at position: SIMD3<Float>) -> Float? {
        guard position.x >= minimumX, position.x <= maximumX,
              position.z >= minimumZ, position.z <= maximumZ,
              position.y >= height - 0.5 else { return nil }
        return height
    }
    func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>,
                     to destination: SIMD3<Float>, maximumStepHeight: Float) -> Bool {
        groundHeight(at: start) != nil && groundHeight(at: destination) != nil
    }
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        guard let xRange = propSupportColumnRange(minimum: bounds.minimumX, maximum: bounds.maximumX, spacing: 0.25),
              let zRange = propSupportColumnRange(minimum: bounds.minimumZ, maximum: bounds.maximumZ, spacing: 0.25)
        else { return [] }
        var result: [WorldTriangle] = []
        for x in xRange {
            for z in zRange {
                let x0 = Float(x) * 0.25, x1 = x0 + 0.25
                let z0 = Float(z) * 0.25, z1 = z0 + 0.25
                guard x1 >= minimumX, x0 <= maximumX, z1 >= minimumZ, z0 <= maximumZ else { continue }
                guard x1 > minimumX, x0 < maximumX, z1 > minimumZ, z0 < maximumZ else { continue }
                result.append(WorldTriangle(SIMD3(x0, height, z0), SIMD3(x1, height, z0), SIMD3(x1, height, z1)))
                result.append(WorldTriangle(SIMD3(x0, height, z0), SIMD3(x1, height, z1), SIMD3(x0, height, z1)))
            }
        }
        return result
    }
}

private func makeGrid() -> PropSupportGrid {
    let collision = FlatPlane(minimumX: 0.25, maximumX: 5, minimumZ: 0.25, maximumZ: 5, height: 0)
    let parameters = PropSupportGridParameters(spacing: 0.25)
    return PropSupportGridBuilder.build(
        collision: collision,
        bounds: WorldPlanarBounds(minimumX: 0, maximumX: 5.25, minimumZ: 0, maximumZ: 5.25),
        seed: WorldVector3(x: 0.5, y: 0, z: 0.5),
        parameters: parameters
    )
}

private func makeMap(_ grid: PropSupportGrid) -> WorldPlacementRouteMap {
    WorldPlacementRouteMap(grid: grid, lowerHeight: -0.2, upperHeight: 0.4)
}

/// 与运行时**同一个**体积来源：`generatedCollisionVolume` 就是 `WorldCollisionVolume`
/// （底心 + 尺寸 + yaw 四元数）。这里按同一口径造一件。
private func propVolume(
    size: SIMD2<Float>,
    yaw: Float = 0,
    height: Float,
    center: SIMD2<Float>,
    bottom: Float
) -> WorldCollisionVolume {
    WorldCollisionVolume(
        id: "prop.test",
        center: WorldVector3(x: center.x, y: bottom + height / 2, z: center.y),
        halfExtents: WorldVector3(x: size.x / 2, y: height / 2, z: size.y / 2),
        rotation: WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
        isBlocking: true
    )
}

@Test("移动图只收可站带内的承托层，并且锚点能落在节点上")
func routeMapCoversStandableBand() throws {
    let grid = makeGrid()
    #expect(!grid.layers.isEmpty, "合成平面必须派生出承托层")
    let map = makeMap(grid)
    #expect(map.standableNodeCount > 100, "10×10 格的平面至少上百个可站节点（实测 \(map.standableNodeCount)）")
    #expect(map.node(at: WorldVector3(x: 0.6, y: 0, z: 0.6)) != nil)
    #expect(map.node(at: WorldVector3(x: 0.6, y: 3.0, z: 0.6)) == nil, "带外的高度不是可站节点")
}

@Test("没有任何障碍时放行")
func routeMapAllowsWhenNothingIsBlocked() throws {
    let map = makeMap(makeGrid())
    let decision = map.decision(
        blockedNodes: [],
        anchorIDs: ["far"],
        anchorPositions: ["far": WorldVector3(x: 5.0, y: 0, z: 5.0)],
        residentPosition: WorldVector3(x: 0.5, y: 0, z: 0.5)
    )
    #expect(decision == .allowed)
}

@Test("占掉锚点自己那一格必须被拒（那次活动没有地方站）")
func routeMapRejectsOccupiedAnchor() throws {
    let map = makeMap(makeGrid())
    let anchor = WorldVector3(x: 5.0, y: 0, z: 5.0)
    let node = try #require(map.node(at: anchor))
    let decision = map.decision(
        blockedNodes: [node],
        anchorIDs: ["far"],
        anchorPositions: ["far": anchor],
        residentPosition: WorldVector3(x: 0.5, y: 0, z: 0.5)
    )
    #expect(decision == .blockedAnchor("far"))
}

@Test("把整片可站节点都堵死 ⇒ 拒绝（先撞上锚点被占：居民连站的地方都没有）")
func routeMapRejectsWhenEverythingIsBlocked() throws {
    let map = makeMap(makeGrid())
    let everything = Set(0..<map.standableNodeCount)
    let decision = map.decision(
        blockedNodes: everything,
        anchorIDs: ["far"],
        anchorPositions: ["far": WorldVector3(x: 5.0, y: 0, z: 5.0)],
        residentPosition: WorldVector3(x: 0.5, y: 0, z: 0.5)
    )
    // 全堵死时"锚点自己被占"这条先命中 —— 两种拒绝都算拒绝，**绝不能是 allowed**。
    #expect(decision == .blockedAnchor("far"))
}

@Test("锚点没被占、但通往它的路被切断 ⇒ blockedRoute")
func routeMapRejectsSeveredRoute() throws {
    let map = makeMap(makeGrid())
    // 居民与锚点对角相望。把"锚点所在行"之外的**唯一一条**通道切断做不到（平面是 2D 的），
    // 所以这里换成判据真正会遇到的形状：家具横跨走道 —— 把锚点那一侧与居民之间
    // 的那一圈节点全部占掉。判据必须说 blockedRoute，而不是 allowed。
    let anchor = WorldVector3(x: 5.0, y: 0, z: 5.0)
    let anchorNode = try #require(map.node(at: anchor))
    let resident = WorldVector3(x: 0.5, y: 0, z: 0.5)
    // 把锚点周围一圈（不含锚点自己）全部当障碍。
    var blocked: Set<Int> = []
    for dx in -2...2 {
        for dz in -2...2 where dx != 0 || dz != 0 {
            let column = PropSupportColumn(
                x: Int(floor(anchor.x / map.spacing)) + dx,
                z: Int(floor(anchor.z / map.spacing)) + dz
            )
            let position = WorldVector3(
                x: (Float(column.x) + 0.5) * map.spacing,
                y: 0,
                z: (Float(column.z) + 0.5) * map.spacing
            )
            if let node = map.node(at: position) { blocked.insert(node) }
        }
    }
    #expect(!blocked.contains(anchorNode))
    let decision = map.decision(
        blockedNodes: blocked,
        anchorIDs: ["far"],
        anchorPositions: ["far": anchor],
        residentPosition: resident
    )
    #expect(decision == .blockedRoute("far"))
}

@Test("锚点落在承托带外（找不到节点）⇒ unavailable（fail-closed，不放行）")
func routeMapFailsClosedWithoutAnchorNode() throws {
    let map = makeMap(makeGrid())
    let decision = map.decision(
        blockedNodes: [],
        anchorIDs: ["floating"],
        anchorPositions: ["floating": WorldVector3(x: 2.0, y: 9.0, z: 2.0)],
        residentPosition: WorldVector3(x: 0.5, y: 0, z: 0.5)
    )
    #expect(decision == .unavailable)
}

@Test("被占节点 = 运行时站立判定的真值：同一份几何只有一个答案")
func routeMapBlockedNodesMatchRuntimeOccupancy() throws {
    let map = makeMap(makeGrid())
    let volume = propVolume(size: SIMD2(0.35, 0.57), height: 0.4,
                            center: SIMD2(2.625, 2.625), bottom: 0)
    let blocked = map.blockedNodes(volume: volume)
    #expect(!blocked.isEmpty, "地面上的物件必须挡住脚下的节点")
    #expect(blocked == truthNodes(map, volume: volume),
            "移动图的被占节点必须与运行时站立判定逐节点一致")
}

@Test("yaw 旋转的物件按真实朝向挡人：轴向搞反会让摆放预检与运行时给出两个答案")
func routeMapBlockedNodesRespectYaw() throws {
    let map = makeMap(makeGrid())
    // 与真机那把斧头同形状：0.885 × 0.0865 m，绕 Y 转 90°。
    let rotated = propVolume(size: SIMD2(0.885, 0.0865), yaw: .pi / 2, height: 0.7,
                             center: SIMD2(2.625, 2.625), bottom: 0)
    let blocked = map.blockedNodes(volume: rotated)
    #expect(blocked == truthNodes(map, volume: rotated),
            "yaw 旋转的物件必须与运行时逐节点一致（图 \(blocked.count) / 运行时 \(truthNodes(map, volume: rotated).count)）")
    // 方向性：转 90° 之后被占节点应沿世界 Z 铺开，而不是沿世界 X。
    var columns: [PropSupportColumn] = []
    for x in 0 ..< 22 {
        for z in 0 ..< 22 {
            let position = WorldVector3(x: (Float(x) + 0.5) * map.spacing, y: 0,
                                        z: (Float(z) + 0.5) * map.spacing)
            guard let node = map.node(at: position), blocked.contains(node) else { continue }
            columns.append(PropSupportColumn(x: x, z: z))
        }
    }
    if !columns.isEmpty {
        let spanX = (columns.map(\.x).max() ?? 0) - (columns.map(\.x).min() ?? 0)
        let spanZ = (columns.map(\.z).max() ?? 0) - (columns.map(\.z).min() ?? 0)
        #expect(spanZ > spanX,
                "0.885 m 的那条边转到 90° 之后必须沿 Z 铺开（实测 spanX=\(spanX) spanZ=\(spanZ)）")
    }
}

@Test("物件只挡住它自己那一段高度：高处的物件不挡脚下的节点")
func routeMapBlockedNodesRespectVerticalExtent() throws {
    let map = makeMap(makeGrid())
    // 头顶之上（底 2.2 m、高 0.4 m）的物件不该挡任何地面节点：站姿胶囊只到 1.8 m。
    let above = map.blockedNodes(volume: propVolume(size: SIMD2(0.35, 0.57), height: 0.4,
                                                    center: SIMD2(2.625, 2.625), bottom: 2.2))
    #expect(above.isEmpty, "高处的物件不得挡地面（实测 \(above.count) 个节点）")
    let onFloor = map.blockedNodes(volume: propVolume(size: SIMD2(0.35, 0.57), height: 0.4,
                                                      center: SIMD2(2.625, 2.625), bottom: 0))
    #expect(!onFloor.isEmpty, "地面上的物件必须挡住脚下的节点")
}

@Test("footprint 越大挡得越多（判据随物件尺寸单调）")
func routeMapScalesWithFootprint() throws {
    let map = makeMap(makeGrid())
    let small = map.blockedNodes(volume: propVolume(size: SIMD2(0.2, 0.2), height: 0.3,
                                                    center: SIMD2(2.625, 2.625), bottom: 0))
    let large = map.blockedNodes(volume: propVolume(size: SIMD2(0.9, 0.9), height: 0.3,
                                                    center: SIMD2(2.625, 2.625), bottom: 0))
    #expect(small.count < large.count, "大 footprint 必须挡住更多节点（小 \(small.count) / 大 \(large.count)）")
}

/// 与运行时同一条判据的真值集合：`CollisionVolumeWorld.canOccupy` 在每个可站节点上问一遍。
private func truthNodes(_ map: WorldPlacementRouteMap, volume: WorldCollisionVolume) -> Set<Int> {
    let runtime = CollisionVolumeWorld(volumes: [volume])
    var truth: Set<Int> = []
    for x in 0 ..< 22 {
        for z in 0 ..< 22 {
            let position = WorldVector3(x: (Float(x) + 0.5) * map.spacing, y: 0,
                                        z: (Float(z) + 0.5) * map.spacing)
            guard let node = map.node(at: position) else { continue }
            guard !runtime.canOccupy(map.capsule, at: SIMD3(position.x, position.y, position.z)) else { continue }
            truth.insert(node)
        }
    }
    return truth
}
