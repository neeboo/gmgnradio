import Foundation
import Testing

@testable import WorldRuntime

// MARK: - 合成几何助手
//
// 全部用例都用手写的简单几何，不依赖真实的 161,600 三角形 GLB：
// 派生算法的问题要能一眼定位，而不是淹没在重建网格的噪声里。

/// 水平四边形（地面 / 桌面 / 台阶面），拆成两个三角形。
private func horizontalQuad(
    minimumX: Float,
    maximumX: Float,
    minimumZ: Float,
    maximumZ: Float,
    y: Float
) -> [WorldTriangle] {
    let first = SIMD3<Float>(minimumX, y, minimumZ)
    let second = SIMD3<Float>(maximumX, y, minimumZ)
    let third = SIMD3<Float>(maximumX, y, maximumZ)
    let fourth = SIMD3<Float>(minimumX, y, maximumZ)
    return [WorldTriangle(first, second, third), WorldTriangle(first, third, fourth)]
}

/// 竖直四边形（墙 / 立柱），位于平面 x = x，z ∈ [minimumZ, maximumZ]，y ∈ [minimumY, maximumY]。
private func verticalQuad(
    x: Float,
    minimumY: Float,
    maximumY: Float,
    minimumZ: Float,
    maximumZ: Float
) -> [WorldTriangle] {
    let first = SIMD3<Float>(x, minimumY, minimumZ)
    let second = SIMD3<Float>(x, maximumY, minimumZ)
    let third = SIMD3<Float>(x, maximumY, maximumZ)
    let fourth = SIMD3<Float>(x, minimumY, maximumZ)
    return [WorldTriangle(first, second, third), WorldTriangle(first, third, fourth)]
}

private func flatFloor(
    minimumX: Float = -2,
    maximumX: Float = 2,
    minimumZ: Float = -2,
    maximumZ: Float = 2
) -> [WorldTriangle] {
    horizontalQuad(
        minimumX: minimumX,
        maximumX: maximumX,
        minimumZ: minimumZ,
        maximumZ: maximumZ,
        y: 0
    )
}

private func supportRef(
    _ grid: PropSupportGrid,
    x: Int,
    z: Int,
    layer: Int = 0
) -> PropSupportLayerRef? {
    guard let value = grid.layers(at: PropSupportColumn(x: x, z: z))
        .first(where: { $0.layer == layer })
    else {
        return nil
    }
    return PropSupportLayerRef(column: PropSupportColumn(x: x, z: z), layer: value)
}

private func evaluate(
    _ footprint: WorldPlanarFootprint,
    height: Float = 0.3,
    at anchor: PropSupportLayerRef,
    grid: PropSupportGrid,
    collision: any WorldPropSupportQuerying,
    blockingVolumes: [WorldCollisionVolume] = [],
    placedProps: [WorldCollisionVolume] = []
) -> PropSupportBlockReason? {
    PropPlacementEvaluator.evaluate(
        footprint: footprint,
        height: height,
        at: anchor,
        grid: grid,
        collision: collision,
        blockingVolumes: blockingVolumes,
        placedProps: placedProps
    )
}

// MARK: - 工作项 1：范围查询

@Test("triangles(in:) 与暴力遍历全量三角形按包围盒筛选一致，且去重、升序")
func planarRangeQueryMatchesBruteForce() {
    // 几何故意大小不一：有横跨多个空间哈希 cell 的大地板，也有小碎块，还有竖直面。
    let largeFloor = horizontalQuad(minimumX: -6, maximumX: 6, minimumZ: -6, maximumZ: 6, y: 0)
    let table = horizontalQuad(minimumX: 0.4, maximumX: 1.6, minimumZ: 0.4, maximumZ: 1.6, y: 0.75)
    let step = horizontalQuad(minimumX: 2, maximumX: 2.625, minimumZ: -0.125, maximumZ: 0.125, y: 0.3)
    let wall = verticalQuad(x: -1.7, minimumY: 0, maximumY: 2.4, minimumZ: -3, maximumZ: 3)
    let pillar = verticalQuad(x: 0.9, minimumY: 0, maximumY: 1.2, minimumZ: 1.9, maximumZ: 2.1)
    let triangles = largeFloor + table + step + wall + pillar
    let world = TriangleMeshCollisionWorld(triangles: triangles, cellSize: 0.25)

    // 暴力对照：按内部索引升序（因为范围查询也承诺升序），不做任何空间哈希。
    let probes: [WorldPlanarBounds] = [
        WorldPlanarBounds(minimumX: -6, maximumX: 6, minimumZ: -6, maximumZ: 6),
        WorldPlanarBounds(minimumX: 0.5, maximumX: 0.5, minimumZ: 0.5, maximumZ: 0.5),
        WorldPlanarBounds(minimumX: 0.4, maximumX: 1.6, minimumZ: 0.4, maximumZ: 1.6),
        WorldPlanarBounds(minimumX: 2.1, maximumX: 2.3, minimumZ: -0.1, maximumZ: 0.1),
        WorldPlanarBounds(minimumX: -1.75, maximumX: -1.65, minimumZ: -3, maximumZ: 3),
        WorldPlanarBounds(minimumX: 100, maximumX: 101, minimumZ: 100, maximumZ: 101),
        WorldPlanarBounds(minimumX: 0.25, maximumX: 0.25, minimumZ: -6, maximumZ: 6),
    ]

    for bounds in probes {
        let expected = triangles.enumerated()
            .filter { $0.element.intersects(bounds) }
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        let actual = world.triangles(in: bounds)
        #expect(actual == expected, "范围查询必须与暴力筛选逐项一致：\(bounds)")
        #expect(actual.count == expected.count)
    }

    // 相切也算相交：只碰到边界的三角形不能被漏掉。
    let touching = WorldPlanarBounds(minimumX: 6, maximumX: 8, minimumZ: 6, maximumZ: 8)
    #expect(world.triangles(in: touching).count == 2, "地板右上角的两个三角形与范围相切")

    // 不合法的范围返回空数组（不是"全都可以放"）。
    #expect(world.triangles(in: WorldPlanarBounds(minimumX: 2, maximumX: 1, minimumZ: 0, maximumZ: 1)).isEmpty)
    #expect(world.triangles(in: WorldPlanarBounds(minimumX: .nan, maximumX: 1, minimumZ: 0, maximumZ: 1)).isEmpty)
}

// MARK: - 工作项 2：承托结构派生

@Test("10×10 平地：每列恰好一层，高度正确")
func gridDerivesSingleGroundLayer() {
    let world = TriangleMeshCollisionWorld(
        triangles: horizontalQuad(minimumX: -5, maximumX: 5, minimumZ: -5, maximumZ: 5, y: 0)
    )
    let bounds = WorldPlanarBounds(minimumX: -5, maximumX: 5, minimumZ: -5, maximumZ: 5)
    // 种子取世界原点：它落在平地内，且这一列只有地面层。
    let grid = PropSupportGridBuilder.build(
        collision: world, bounds: bounds, seed: WorldVector3(x: 0, y: 0, z: 0))
    #expect(grid.parameters.algorithmVersion >= 1)
    #expect(grid.spacing == 0.25)
    #expect(grid.bounds == bounds)
    // 0.25 m 间距、-5…5 → 41 × 41 列，每列一层。
    #expect(grid.layers.count == 41 * 41)

    for ref in grid.layers {
        #expect(ref.layer.layer == 0)
        #expect(abs(ref.layer.supportHeight) < 0.0001)
        #expect(abs(ref.layer.center.y) < 0.0001)
        #expect(abs(ref.layer.center.x - Float(ref.column.x) * grid.spacing) < 0.0001)
        #expect(abs(ref.layer.center.z - Float(ref.column.z) * grid.spacing) < 0.0001)
    }
    #expect(grid.layers(at: PropSupportColumn(x: 0, z: 0)).count == 1)
    #expect(grid.layers(at: PropSupportColumn(x: 100, z: 0)).isEmpty)
    #expect(grid.contains(PropSupportColumn(x: 20, z: -20)))
    #expect(!grid.contains(PropSupportColumn(x: 21, z: 0)))
}

@Test("地面 + 桌子：桌子覆盖的列有两层，layer 按高度升序")
func gridDerivesMultipleLayersUnderATable() {
    let tableHeight: Float = 1.2
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0, maximumX: 1, minimumZ: 0, maximumZ: 1, y: tableHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let bounds = WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2)
    // 种子取 (-1, 0, -1)：桌子盖住 0…1，原点在桌子正下方，故意避开它。
    let grid = PropSupportGridBuilder.build(
        collision: world, bounds: bounds, seed: WorldVector3(x: -1, y: 0, z: -1))
    let underTable = grid.layers(at: PropSupportColumn(x: 2, z: 2))
    #expect(underTable.count == 2)
    #expect(underTable[0].layer == 0)
    #expect(abs(underTable[0].supportHeight) < 0.0001)
    #expect(underTable[1].layer == 1)
    #expect(abs(underTable[1].supportHeight - tableHeight) < 0.0001)
    #expect(abs(underTable[1].center.y - tableHeight) < 0.0001)

    // 桌子之外只有地面一层（注意桌子边界那一列的角点算在桌面上，所以取 (1.5, 1.5)）。
    let besideTable = grid.layers(at: PropSupportColumn(x: 6, z: 6))
    #expect(besideTable.count == 1)
    #expect(abs(besideTable[0].supportHeight) < 0.0001)

    // 桌子盖住的 5 × 5 列（世界 0…1）各多出一层。
    #expect(grid.layers.count == 17 * 17 + 25)

    // 扁平数组顺序确定：先 x 升 → 再 z 升 → 再 layer 升。
    let sortedKeys = grid.layers.map { [$0.column.x, $0.column.z, $0.layer.layer] }
    #expect(sortedKeys == sortedKeys.sorted { $0.lexicographicallyPrecedes($1) })
}

@Test("同一份几何连续派生两次逐项相等；三角形构造顺序不同也不影响结果")
func gridDerivationIsDeterministic() {
    let wall = verticalQuad(x: -0.6, minimumY: 0, maximumY: 2, minimumZ: -1, maximumZ: 1)
    let table = horizontalQuad(minimumX: 0.4, maximumX: 1.4, minimumZ: 0.4, maximumZ: 1.4, y: 0.8)
    let triangles = flatFloor() + table + wall
    let bounds = WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2)

    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let first = PropSupportGridBuilder.build(collision: world, bounds: bounds, seed: WorldVector3(x: 0, y: 0, z: 0))
    let second = PropSupportGridBuilder.build(collision: world, bounds: bounds, seed: WorldVector3(x: 0, y: 0, z: 0))
    #expect(first.layers == second.layers)
    #expect(!first.layers.isEmpty)

    let reordered = TriangleMeshCollisionWorld(triangles: triangles.reversed())
    let third = PropSupportGridBuilder.build(collision: reordered, bounds: bounds, seed: WorldVector3(x: 0, y: 0, z: 0))
    #expect(third.layers == first.layers)
}

@Test("nearestLayer 取最近的一层，超出距离或没有承托面时返回 nil")
func nearestLayerPicksClosestLayer() throws {
    let tableHeight: Float = 0.8
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0.5, maximumX: 1.5, minimumZ: 0.5, maximumZ: 1.5, y: tableHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )

    // 桌面上方 0.1 m：最近的是桌面层。
    let above = try #require(
        grid.nearestLayer(to: WorldVector3(x: 0.5, y: 0.7, z: 0.5), maximumDistance: 1)
    )
    #expect(above.layer.layer == 1)
    #expect(abs(above.supportHeight - tableHeight) < 0.0001)
    #expect(above.column == PropSupportColumn(x: 2, z: 2))

    // 桌面下方 0.1 m：最近的是地面层。
    let below = try #require(
        grid.nearestLayer(to: WorldVector3(x: 0.5, y: 0.1, z: 0.5), maximumDistance: 1)
    )
    #expect(below.layer.layer == 0)
    #expect(abs(below.supportHeight) < 0.0001)

    #expect(grid.nearestLayer(to: WorldVector3(x: 100, y: 0, z: 100), maximumDistance: 0.5) == nil)
    #expect(grid.nearestLayer(to: WorldVector3(x: 100, y: 0, z: 100), maximumDistance: .nan) == nil)
}

@Test("范围内没有几何时不产出承托面，也不判定为可放")
func emptyGeometryProducesNoSupport() {
    let world = TriangleMeshCollisionWorld(triangles: [])
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: 0, maximumX: 1, minimumZ: 0, maximumZ: 1),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    #expect(grid.layers.isEmpty)
    #expect(grid.contains(PropSupportColumn(x: 0, z: 0)))

    let anchor = PropSupportLayerRef(
        column: PropSupportColumn(x: 0, z: 0),
        layer: PropSupportLayer(
            layer: 0,
            supportHeight: 0,
            center: WorldVector3(x: 0, y: 0, z: 0)
        )
    )
    #expect(
        evaluate(
            WorldPlanarFootprint(size: SIMD2(0.25, 0.25)),
            at: anchor,
            grid: grid,
            collision: world
        ) == .noSupport
    )
}

// MARK: - 工作项 4：连通性过滤（可达性）
//
// 这些用例全部是合成几何：过滤规则要能一眼看懂"哪一层为什么被留下/剔除"。
// 真实 161,600 三角形的守卫在 `MarbleLivingCabinPackageTests` 里。

@Test("地面 + 桌子：桌面层（在 band 内）保留，地面保留")
func gridKeepsFurnitureTopWithinBand() {
    // 0.75 m 的真实餐桌高度：站立胶囊在这个高度**进不去桌子下面**，
    // 但桌面正下方就是可达地面，band 把桌面留下来。
    let tableHeight: Float = 0.75
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0.5, maximumX: 1.5, minimumZ: 0.5, maximumZ: 1.5, y: tableHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: -1, y: 0, z: -1)
    )

    // 桌下（世界 0.5, 0.5）两层都在：地面层 + 桌面层。
    let underTable = grid.layers(at: PropSupportColumn(x: 2, z: 2))
    #expect(underTable.count == 2)
    #expect(abs(underTable[0].supportHeight) < 0.0001)
    #expect(abs(underTable[1].supportHeight - tableHeight) < 0.0001)
    // 桌子之外只有地面。
    #expect(grid.layers(at: PropSupportColumn(x: -4, z: -4)).count == 1)

    // 报告把"为什么留下"写清楚：桌面不是靠站立/连通留下的，是靠 band。
    let report = grid.report
    print(
        "[地面+桌子] 过滤前 \(report.layersBeforeFilter) → 过滤后 \(report.layersAfterFilter)；"
            + "站立 \(report.standableLayers)、家具下地面 \(report.coveredGroundLayers)、"
            + "可达 \(report.reachableLayers)、band \(report.furnitureBandLayers)"
    )
    #expect(report.seeded)
    #expect(report.layersBeforeFilter == 17 * 17 + 25)
    #expect(report.layersAfterFilter == 17 * 17 + 25)
    #expect(report.coveredGroundLayers == 25, "桌子盖住的 25 列，地面被桌面挡住站立")
    #expect(report.reachableLayers == 17 * 17, "可达的是地面（含家具下地面）")
    #expect(report.furnitureBandLayers == 25, "桌面层靠 furnitureBandHeight 保留")
    #expect(report.standableLayers == 17 * 17, "264 个空地地面 + 25 个桌面自己可站立")
}

@Test("悬浮面在 band 内且正下方有可达地面：作为家具顶面保留（不连通，见 report）")
func gridKeepsFloatingSurfaceWithinBandAsFurnitureTop() {
    // 与上一条同样的规则，只是"家具"没有腿：0.5 m 悬浮面。
    // 高差 0.5 > maximumStepHeight 迈不上去（不连通），但它在可达地面正上方 1.6 m 内。
    // 这条边界是刻意的：格子只回答"哪一层能放东西"，家具顶面本来就不需要走得到。
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0.5, maximumX: 1.5, minimumZ: 0.5, maximumZ: 1.5, y: 0.5)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: -1, y: 0, z: -1)
    )
    #expect(grid.layers(at: PropSupportColumn(x: 2, z: 2)).count == 2)
    #expect(grid.report.reachableLayers == 17 * 17, "悬浮面不在可达集里（不连通）")
    #expect(grid.report.furnitureBandLayers == 25, "但它在 band 内，作为家具顶面保留")
}

@Test("地面 + 天花板（2.5 m，与地面不连通）：天花板被剔除")
func gridDropsDisconnectedCeiling() {
    let ceilingHeight: Float = 2.5
    let triangles = flatFloor()
        + horizontalQuad(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2, y: ceilingHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )

    // 列扫描枚举出 289 地面 + 289 天花板；两个面**站立胶囊都能容纳**
    // （天花板朝上朝下都算"可行走面"，屋顶外表面更是朝上的）——
    // 这正是 `isWalkableSurface` / `canOccupy` 挡不住天花板的反例，只有连通性挡得住。
    #expect(grid.report.layersBeforeFilter == 289 * 2)
    #expect(grid.report.standableLayers == 289 * 2)
    #expect(grid.report.seeded)
    #expect(grid.report.layersAfterFilter == 289)
    #expect(grid.report.reachableLayers == 289)
    #expect(grid.report.furnitureBandLayers == 0, "2.5 m 远在 band(1.6) 之外")
    #expect(grid.layers.count == 289)
    #expect(grid.layers.allSatisfy { abs($0.supportHeight) < 0.0001 }, "天花板 2.5 m 必须被剔除")
}

@Test("两块互不连通的地面（中间一道墙）：种子那块保留，另一块被剔除")
func gridDropsFloorIslandBehindAWall() {
    // 连续地面 x ∈ [-2, 2]、z ∈ [-1, 1]；x = 0.25 的墙把 z ∈ [-1, 1] 整段封死。
    // 墙脚下那一列（世界 x = 0.25）站立胶囊进不去，墙又是竖直几何、列里没有横向承托层
    // → 既不是站立层也不是家具下地面层 → 整列从候选里消失，BFS 无法穿过。
    let triangles = horizontalQuad(minimumX: -2, maximumX: 2, minimumZ: -1, maximumZ: 1, y: 0)
        + verticalQuad(x: 0.25, minimumY: 0, maximumY: 2, minimumZ: -1, maximumZ: 1)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -1, maximumZ: 1),
        seed: WorldVector3(x: -1, y: 0, z: 0)
    )

    // 17 × 9 = 153 列都枚举出了地面；墙那一列被剔除后只剩左半 9 × 9 = 81 列。
    #expect(grid.report.layersBeforeFilter == 153)
    #expect(grid.report.seeded)
    #expect(grid.report.layersAfterFilter == 81)
    #expect(grid.layers.allSatisfy { $0.column.x <= 0 }, "种子在左半，右半是孤岛")
    #expect(grid.layers(at: PropSupportColumn(x: 1, z: 0)).isEmpty, "墙脚下的列不存在")
    #expect(grid.layers(at: PropSupportColumn(x: 2, z: 0)).isEmpty, "墙右侧的孤岛被剔除")
    #expect(grid.layers(at: PropSupportColumn(x: 0, z: 0)).count == 1)
}

@Test("台阶（高差 = maximumStepHeight）：保留且连通，不是靠 band 摆上去的")
func gridKeepsStepConnected() {
    // 0.3 m 的踏步，正好等于 maximumStepHeight：横向 canTraverse + 同列纵向都连通。
    let stepHeight: Float = 0.3
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0.5, maximumX: 1.5, minimumZ: -2, maximumZ: 2, y: stepHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: -1, y: 0, z: 0)
    )

    let onStep = grid.layers(at: PropSupportColumn(x: 2, z: 0))
    #expect(onStep.count == 2)
    #expect(abs(onStep[1].supportHeight - stepHeight) < 0.0001)
    #expect(grid.report.seeded)
    // 踏步层在**可达集**里（不是 band 摆上去的）：这是"连通"的判据。
    #expect(grid.report.furnitureBandLayers == 0)
    #expect(grid.report.reachableLayers == grid.report.layersAfterFilter)
    #expect(grid.report.layersAfterFilter == grid.report.layersBeforeFilter)
}

@Test("高差大于 maximumStepHeight 的平台：不连通，整层被剔除")
func gridDropsPlatformAboveStepHeight() {
    // 地面在 x = 0.25 结束，紧接着 0.5 m 高的实心平台（x ∈ [0.5, 1.5]）。
    // 0.5 > maximumStepHeight(0.3) 迈不上去；平台自己那一列没有可达层在下方的 band 锚点
    // （地板不铺到平台下面）→ 平台顶面整层被剔除。
    let platformHeight: Float = 0.5
    let triangles = horizontalQuad(minimumX: -2, maximumX: 0.25, minimumZ: -1, maximumZ: 1, y: 0)
        + horizontalQuad(
            minimumX: 0.5,
            maximumX: 1.5,
            minimumZ: -1,
            maximumZ: 1,
            y: platformHeight
        )
        + verticalQuad(x: 0.5, minimumY: 0, maximumY: platformHeight, minimumZ: -1, maximumZ: 1)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 1.5, minimumZ: -1, maximumZ: 1),
        seed: WorldVector3(x: -1, y: 0, z: 0)
    )

    print(
        "[0.5 m 平台] 过滤前 \(grid.report.layersBeforeFilter) → 过滤后 \(grid.report.layersAfterFilter)"
            + "（可达 \(grid.report.reachableLayers)、band \(grid.report.furnitureBandLayers)）"
    )
    #expect(grid.report.seeded)
    #expect(grid.report.layersBeforeFilter == 10 * 9 + 5 * 9, "地板 10 列 + 平台 5 列，各 9 行")
    #expect(grid.layers.allSatisfy { abs($0.supportHeight) < 0.0001 }, "平台顶面必须被剔除")
    #expect(grid.layers(at: PropSupportColumn(x: 2, z: 0)).isEmpty, "世界 x = 0.5 是平台列")
    #expect(grid.layers.count == 10 * 9)
}

@Test("家具顶面高出可达地面超过 furnitureBandHeight：被剔除")
func gridDropsFurnitureTopAboveBand() {
    // 与「地面 + 桌子」同样的形态，只是顶面在 2.0 m：超过 band(1.6) 就被剔除。
    let topHeight: Float = 2.0
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0.5, maximumX: 1.5, minimumZ: 0.5, maximumZ: 1.5, y: topHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: -1, y: 0, z: -1)
    )

    #expect(grid.report.layersBeforeFilter == 17 * 17 + 25)
    #expect(grid.report.seeded)
    #expect(grid.report.furnitureBandLayers == 0)
    #expect(grid.report.layersAfterFilter == 17 * 17)
    // 顶面下面的地面本身能站人（2.0 m 远在胶囊头顶之上），所以它照常保留。
    #expect(grid.layers(at: PropSupportColumn(x: 2, z: 2)).count == 1)
    #expect(grid.layers.allSatisfy { abs($0.supportHeight) < 0.0001 }, "2.0 m 的顶面必须被剔除")
}

@Test("种子在 bounds 外 / 没有候选层：空网格 + report 说明（不崩溃）")
func gridWithoutUsableSeedIsEmpty() throws {
    let world = TriangleMeshCollisionWorld(triangles: flatFloor())
    let bounds = WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2)

    // 1) 种子在边界外：不猜、不放行，返回空网格，但 report 仍然说清楚扫到了什么。
    let outside = PropSupportGridBuilder.build(
        collision: world,
        bounds: bounds,
        seed: WorldVector3(x: 100, y: 0, z: 100)
    )
    #expect(outside.layers.isEmpty)
    #expect(!outside.report.seeded)
    #expect(outside.report.layersBeforeFilter == 289, "列扫描照常发生，report 不撒谎")
    #expect(outside.report.layersAfterFilter == 0)
    #expect(outside.report.standableLayers == 289)
    #expect(outside.contains(PropSupportColumn(x: 0, z: 0)), "越界与'这里没有承托面'仍可区分")

    // 2) 没有候选层：0.25 m 宽的竖井（四面墙 + 地面）。扫描得到 1 层，但站立胶囊进不去，
    //    墙又不在列里产生横向承托层 → 没有站立层、也没有家具下地面层。
    let shaft: Float = 0.125
    let shaftTriangles = horizontalQuad(
        minimumX: -shaft,
        maximumX: shaft,
        minimumZ: -shaft,
        maximumZ: shaft,
        y: 0
    )
        + verticalQuad(x: shaft, minimumY: 0, maximumY: 2, minimumZ: -shaft, maximumZ: shaft)
        + verticalQuad(x: -shaft, minimumY: 0, maximumY: 2, minimumZ: -shaft, maximumZ: shaft)
        + verticalQuad(x: 0, minimumY: 0, maximumY: 2, minimumZ: shaft, maximumZ: shaft)
        + verticalQuad(x: 0, minimumY: 0, maximumY: 2, minimumZ: -shaft, maximumZ: -shaft)
    let sealed = PropSupportGridBuilder.build(
        collision: TriangleMeshCollisionWorld(triangles: shaftTriangles),
        bounds: WorldPlanarBounds(minimumX: -shaft, maximumX: shaft, minimumZ: -shaft, maximumZ: shaft),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    #expect(sealed.layers.isEmpty)
    #expect(!sealed.report.seeded)
    #expect(sealed.report.layersBeforeFilter == 1)
    #expect(sealed.report.standableLayers == 0)
    #expect(sealed.report.coveredGroundLayers == 0)
    #expect(sealed.report.layersAfterFilter == 0)
}

@Test("同几何两次派生逐项相等，report 也相等；三角形顺序无关")
func connectivityFilterIsDeterministic() {
    let triangles = flatFloor(minimumX: -3, maximumX: 3, minimumZ: -3, maximumZ: 3)
        + horizontalQuad(minimumX: 0.4, maximumX: 1.4, minimumZ: 0.4, maximumZ: 1.4, y: 0.8)
        + horizontalQuad(minimumX: -2, maximumX: -1.2, minimumZ: -2, maximumZ: -1.2, y: 0.3)
        + verticalQuad(x: 0.6, minimumY: 0, maximumY: 2, minimumZ: -2, maximumZ: 0.2)
    let bounds = WorldPlanarBounds(minimumX: -3, maximumX: 3, minimumZ: -3, maximumZ: 3)
    let seed = WorldVector3(x: -1, y: 0, z: -1)

    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let first = PropSupportGridBuilder.build(collision: world, bounds: bounds, seed: seed)
    let second = PropSupportGridBuilder.build(collision: world, bounds: bounds, seed: seed)
    #expect(first.layers == second.layers)
    #expect(first.report == second.report)
    #expect(first.report.seeded)
    #expect(!first.layers.isEmpty)

    let reordered = TriangleMeshCollisionWorld(triangles: triangles.reversed())
    let third = PropSupportGridBuilder.build(collision: reordered, bounds: bounds, seed: seed)
    #expect(third.layers == first.layers)
    #expect(third.report == first.report)
}

// MARK: - 工作项 3：footprint 与放置判定

@Test("插墙的格子被判定为 blockedByMesh，空地仍然可放")
func wallInsideColumnIsRejectedByMesh() throws {
    // **语义变化（连通性过滤落地时改断言，理由见下）**：墙所在的那一列现在**在派生阶段
    // 就被剔除**——站立胶囊进不去墙里（`canOccupy` 为假），墙又是竖直几何、不会在列里
    // 产生横向承托层，所以它既不是"站立层"也不是"家具下地面层"。
    // 于是"占地压到墙"的失败原因从 `.blockedByMesh` 变成 `.noSupport`
    // （`PropPlacementEvaluator` 先查整块占地的承托层，再查网格；它的语义没动）。
    // 这条用例保留下来钉住新语义：过滤后的网格里**不存在**"能站进墙里"的锚点。
    // `.blockedByMesh` 的覆盖由紧随其后的 `footprintInsideFurnitureLegIsBlockedByMesh` 保住
    // （桌腿所在的列因为有桌面这个 band 内的上层而保留，网格判定照旧拒绝）。
    let wall = verticalQuad(x: 0.6, minimumY: 0, maximumY: 2, minimumZ: -0.5, maximumZ: 0.5)
    let world = TriangleMeshCollisionWorld(triangles: flatFloor() + wall)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -1, maximumX: 1, minimumZ: -1, maximumZ: 1),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )

    // 墙脚那两列（世界 x = 0.5 / 0.75，z ∈ [-0.5, 0.5]）整列消失。
    #expect(grid.layers(at: PropSupportColumn(x: 2, z: 0)).isEmpty)
    #expect(grid.layers(at: PropSupportColumn(x: 3, z: 0)).isEmpty)

    // 离墙足够远的列还在，而且能放。
    let clear = try #require(supportRef(grid, x: -2, z: 0))
    let footprint = WorldPlanarFootprint(size: SIMD2(0.25, 0.25))
    #expect(evaluate(footprint, at: clear, grid: grid, collision: world) == nil)
}

@Test("桌腿插进占地仍然是 blockedByMesh：家具下的地面层保留，网格判定照旧")
func footprintInsideFurnitureLegIsBlockedByMesh() throws {
    // 桌子 = 桌面（0.8 m，在 furnitureBandHeight 内）+ 一根桌腿。
    // 桌面下面的地面站不住人（桌面就在躯干高度上），但它属于"家具下地面层"，
    // 所以这一列仍然存在，`.blockedByMesh` 这条路径不会因为过滤而失效。
    let top = horizontalQuad(minimumX: 0.4, maximumX: 1.4, minimumZ: -0.2, maximumZ: 0.6, y: 0.8)
    let leg = verticalQuad(x: 0.9, minimumY: 0, maximumY: 0.8, minimumZ: 0, maximumZ: 0.2)
    let world = TriangleMeshCollisionWorld(triangles: flatFloor() + top + leg)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )

    // 世界 (0.5, 0)：桌面盖住这一列 → 地面层（家具下）+ 桌面层（band）。
    let underTable = PropSupportColumn(x: 2, z: 0)
    #expect(grid.layers(at: underTable).count == 2)
    let anchor = try #require(supportRef(grid, x: 2, z: 0, layer: 0))

    // 0.5 m footprint 锚定在 (0.5, 0) → 占地 x ∈ [0.5,1.0]、z ∈ [0,0.5]，桌腿 x = 0.9 插在里面。
    let footprint = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    #expect(evaluate(footprint, at: anchor, grid: grid, collision: world) == .blockedByMesh)
}

@Test("阻挡体积重叠的格子被判定为 blockedByBlockingVolume(id)")
func blockingVolumeIsRejected() throws {
    let world = TriangleMeshCollisionWorld(triangles: flatFloor())
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    let footprint = WorldPlanarFootprint(size: SIMD2(0.25, 0.25))
    let anchor = try #require(supportRef(grid, x: 0, z: 0))

    let overlapping = WorldCollisionVolume(
        id: "collision.jukebox",
        center: WorldVector3(x: 0.1, y: 0.2, z: 0.1),
        halfExtents: WorldVector3(x: 0.2, y: 0.2, z: 0.2),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    #expect(
        evaluate(footprint, at: anchor, grid: grid, collision: world, blockingVolumes: [overlapping])
            == .blockedByBlockingVolume("collision.jukebox")
    )

    // 同样尺寸但离得远：不挡。
    let distant = WorldCollisionVolume(
        id: "collision.wish_machine",
        center: WorldVector3(x: 5, y: 0.2, z: 5),
        halfExtents: WorldVector3(x: 0.2, y: 0.2, z: 0.2),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    #expect(
        evaluate(footprint, at: anchor, grid: grid, collision: world, blockingVolumes: [distant]) == nil
    )
    // 高度上完全错开（悬在头顶且够不到）：也不挡。
    let above = WorldCollisionVolume(
        id: "collision.lamp",
        center: WorldVector3(x: 0.1, y: 3, z: 0.1),
        halfExtents: WorldVector3(x: 0.2, y: 0.2, z: 0.2),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    #expect(
        evaluate(footprint, at: anchor, grid: grid, collision: world, blockingVolumes: [above]) == nil
    )
}

@Test("已放物件互斥：重叠格得到 blockedByPlacedProp(id)")
func placedPropOverlapIsRejected() throws {
    let world = TriangleMeshCollisionWorld(triangles: flatFloor())
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    let footprint = WorldPlanarFootprint(size: SIMD2(0.25, 0.25))
    let anchor = try #require(supportRef(grid, x: 0, z: 0))

    let placed = WorldCollisionVolume(
        id: "prop.coffee_mug",
        center: WorldVector3(x: 0.1, y: 0.1, z: 0.1),
        halfExtents: WorldVector3(x: 0.1, y: 0.1, z: 0.1),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    #expect(
        evaluate(footprint, at: anchor, grid: grid, collision: world, placedProps: [placed])
            == .blockedByPlacedProp("prop.coffee_mug")
    )

    // 正好贴边不重叠（相切算分开）：可放。
    let touching = WorldCollisionVolume(
        id: "prop.edge",
        center: WorldVector3(x: 0.4, y: 0.1, z: 0.125),
        halfExtents: WorldVector3(x: 0.1, y: 0.1, z: 0.1),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    #expect(evaluate(footprint, at: anchor, grid: grid, collision: world, placedProps: [touching]) == nil)
}

@Test("2×2 footprint 覆盖正确的 4 列；yaw 90° 时覆盖块做 x/z 互换")
func footprintColumnsFollowYaw() {
    let spacing: Float = 0.25
    let anchor = PropSupportColumn(x: 0, z: 0)

    let square = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    #expect(
        Set(square.columns(anchoredAt: anchor, spacing: spacing)) == Set([
            PropSupportColumn(x: 0, z: 0),
            PropSupportColumn(x: 1, z: 0),
            PropSupportColumn(x: 0, z: 1),
            PropSupportColumn(x: 1, z: 1),
        ])
    )
    // 设计文档 §5.2：0.45 m 的物件在 0.25 m 格上同样占 2×2。
    #expect(
        WorldPlanarFootprint(size: SIMD2(0.45, 0.45))
            .columns(anchoredAt: anchor, spacing: spacing).count == 4
    )
    // 0.25 m 恰好一格（相切不算覆盖）。
    #expect(
        WorldPlanarFootprint(size: SIMD2(0.25, 0.25))
            .columns(anchoredAt: anchor, spacing: spacing) == [PropSupportColumn(x: 0, z: 0)]
    )

    // 非正方：0.75 × 0.5 在 yaw 0 覆盖 3 × 2 格，yaw 90° 覆盖 2 × 3 格。
    let base = WorldPlanarFootprint(size: SIMD2(0.75, 0.5))
    let rotated = WorldPlanarFootprint(size: SIMD2(0.75, 0.5), yaw: .pi / 2)
    let baseColumns = base.columns(anchoredAt: anchor, spacing: spacing)
    let rotatedColumns = rotated.columns(anchoredAt: anchor, spacing: spacing)
    #expect(baseColumns.count == 6)
    #expect(rotatedColumns.count == 6)

    func extents(_ column: [PropSupportColumn]) -> (Int, Int) {
        let xs = column.map(\.x)
        let zs = column.map(\.z)
        return (xs.max()! - xs.min()! + 1, zs.max()! - zs.min()! + 1)
    }
    #expect(extents(baseColumns).0 == 3 && extents(baseColumns).1 == 2)
    #expect(extents(rotatedColumns).0 == 2 && extents(rotatedColumns).1 == 3)

    // 相对 footprint 中心的覆盖偏移在 yaw 90° 时正好交换 x / z。
    func centerOffsets(_ footprint: WorldPlanarFootprint) -> Set<SIMD2<Float>> {
        let center = footprint.center(anchoredAt: anchor, spacing: spacing)
        return Set(
            footprint.columns(anchoredAt: anchor, spacing: spacing).map { column in
                let offsetX = (Float(column.x) + 0.5) * spacing - center.x
                let offsetZ = (Float(column.z) + 0.5) * spacing - center.y
                // 量化到 0.1 mm：cos(π/2) 之类的浮点噪声不该影响集合比较。
                return SIMD2((offsetX * 10_000).rounded() / 10_000, (offsetZ * 10_000).rounded() / 10_000)
            }
        )
    }
    let baseOffsets = centerOffsets(base)
    let rotatedOffsets = centerOffsets(rotated)
    #expect(rotatedOffsets == Set(baseOffsets.map { SIMD2($0.y, $0.x) }))

    // 不合法输入不返回任何格子。
    #expect(WorldPlanarFootprint(size: SIMD2(0, 0.5)).columns(anchoredAt: anchor, spacing: spacing).isEmpty)
    #expect(square.columns(anchoredAt: anchor, spacing: 0).isEmpty)
}

@Test("footprint 锚定在边缘列时越界 → outsideBounds")
func footprintAtEdgeIsOutsideBounds() throws {
    let world = TriangleMeshCollisionWorld(
        triangles: horizontalQuad(minimumX: -1, maximumX: 1, minimumZ: -1, maximumZ: 1, y: 0)
    )
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -1, maximumX: 1, minimumZ: -1, maximumZ: 1),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )

    // 上边界：0.75 m 的 footprint 锚定在 x = 1.0 的列上会越过边界。
    let wide = WorldPlanarFootprint(size: SIMD2(0.75, 0.75))
    let high = try #require(supportRef(grid, x: 4, z: 4))
    #expect(
        evaluate(wide, at: high, grid: grid, collision: world) == .outsideBounds
    )

    // 下边界：yaw 180° 时 footprint 朝 -x / -z 长出去，同样越界。
    let reversed = WorldPlanarFootprint(size: SIMD2(0.5, 0.5), yaw: .pi)
    let low = try #require(supportRef(grid, x: -4, z: -4))
    #expect(
        evaluate(reversed, at: low, grid: grid, collision: world) == .outsideBounds
    )

    // 同一列朝内放就没事。
    let inward = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    #expect(evaluate(inward, at: low, grid: grid, collision: world) == nil)
}

@Test("整块占地的高度必须一致：跨桌面 / 地面的 footprint 被 noSupport 拒绝")
func footprintRequiresOneConsistentSupportLayer() throws {
    let tableHeight: Float = 0.8
    let triangles = flatFloor()
        + horizontalQuad(minimumX: 0.5, maximumX: 1.5, minimumZ: 0.5, maximumZ: 1.5, y: tableHeight)
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    // 世界坐标 (1.5, 0.5)：桌子边缘那一列，同时有地面层（0）和桌面层（0.8）。
    let edge = PropSupportColumn(x: 6, z: 2)
    #expect(grid.layers(at: edge).count == 2)

    let footprint = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    // 站在桌面层：右边那列只有地面层 → 整块变红。
    let onTable = try #require(supportRef(grid, x: 6, z: 2, layer: 1))
    #expect(evaluate(footprint, at: onTable, grid: grid, collision: world) == .noSupport)

    // 站在地面层：桌面在 0.8 m 高处，不挡地面上的矮物件 → 可放。
    let onFloor = try #require(supportRef(grid, x: 6, z: 2, layer: 0))
    #expect(evaluate(footprint, at: onFloor, grid: grid, collision: world) == nil)
}

@Test("WorldPropBoxOverlap 的 yaw 轴约定与 canPlace 一致；退化输入按相交处理")
func boxOverlapHonoursYawRotation() {
    let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
    // yaw = 90°：本地 +X 轴指向世界 -Z。
    let yawQuarterTurn = WorldQuaternion(x: 0, y: sin(.pi / 4), z: 0, w: cos(.pi / 4))
    func thin(rotation: WorldQuaternion, center: SIMD3<Float>, id: String) -> WorldCollisionVolume {
        WorldCollisionVolume(
            id: id,
            center: WorldVector3(x: center.x, y: center.y, z: center.z),
            halfExtents: WorldVector3(x: 0.5, y: 0.25, z: 0.05),
            rotation: rotation,
            isBlocking: true
        )
    }
    let reference = thin(rotation: identity, center: SIMD3(0, 0, 0), id: "thin")
    let rotated = thin(rotation: yawQuarterTurn, center: SIMD3(0, 0, 0), id: "rotated")
    let shiftedAlongZ = thin(rotation: identity, center: SIMD3(0, 0, 0.4), id: "shiftedZ")
    let shiftedAlongX = thin(rotation: identity, center: SIMD3(0.4, 0, 0), id: "shiftedX")

    // 未旋转时 z 方向半长只有 0.05 → 0.4 m 外必然分开；转 90° 后长边指向 z → 相交。
    #expect(!WorldPropBoxOverlap.overlaps(reference, shiftedAlongZ))
    #expect(WorldPropBoxOverlap.overlaps(rotated, shiftedAlongZ))
    // x 方向长边 0.5 → 0.4 m 外仍然相交。
    #expect(WorldPropBoxOverlap.overlaps(reference, shiftedAlongX))

    // 高度错开 → 分开。
    #expect(
        !WorldPropBoxOverlap.overlaps(
            reference,
            thin(rotation: identity, center: SIMD3(0, 3, 0), id: "high")
        )
    )

    // 退化输入（零尺寸）按"相交"处理，宁可多拒绝也不放行。
    let degenerate = WorldCollisionVolume(
        id: "degenerate",
        center: WorldVector3(x: 100, y: 0, z: 100),
        halfExtents: WorldVector3(x: 0, y: 0.2, z: 0.2),
        rotation: identity,
        isBlocking: true
    )
    #expect(WorldPropBoxOverlap.overlaps(reference, degenerate))
}

// MARK: - 局部三角形分桶
@Test("局部三角形能覆盖只与 footprint 一部分相交的三角形")
func localTrianglesCatchPartialIntersections() throws {
    // 一根细柱只穿过 0.5 × 0.5 footprint 的左半边。
    //
    // 柱子必须带一个 0.6 m 的顶盖：柱脚那一列（世界 0, 0 离柱面只有 0.15 m）站立胶囊进不去，
    // 而柱子本身是竖直几何、不会在列里产生横向承托层；没有顶盖这一列会被连通性过滤整列剔除
    // （`supportRef` 拿不到锚点）。加了顶盖之后它是"家具下地面层"，被保留 ——
    // 这正好也是真实家具的形态（桌腿 + 桌面）。
    let peg = verticalQuad(x: 0.15, minimumY: 0, maximumY: 0.6, minimumZ: 0, maximumZ: 0.3)
    let pegCap = horizontalQuad(
        minimumX: -0.05,
        maximumX: 0.3,
        minimumZ: -0.05,
        maximumZ: 0.3,
        y: 0.6
    )
    let triangles = flatFloor() + peg + pegCap
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    let footprint = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    let anchor = try #require(supportRef(grid, x: 0, z: 0))

    #expect(evaluate(footprint, at: anchor, grid: grid, collision: world) == .blockedByMesh)

    // footprint 的局部范围里有这根柱子……
    let wholeFootprint = world.triangles(
        in: WorldPlanarBounds(minimumX: 0, maximumX: 0.5, minimumZ: 0, maximumZ: 0.5)
    )
    #expect(peg.allSatisfy { wholeFootprint.contains($0) })
    // ……而只取右半格时取不到它（说明"部分相交"确实靠范围查询边界，而不是靠全量兜底）。
    let rightHalf = world.triangles(
        in: WorldPlanarBounds(minimumX: 0.25, maximumX: 0.5, minimumZ: 0, maximumZ: 0.5)
    )
    #expect(peg.allSatisfy { !rightHalf.contains($0) })

    // 局部结果与全量结果必须一致。
    let box = PropPlacementEvaluator.placementVolume(
        footprint: footprint,
        height: 0.3,
        at: anchor,
        spacing: grid.spacing
    )
    #expect(
        WorldPropMeshClearance.canPlace(box, supportHeight: 0, triangles: wholeFootprint)
            == WorldPropMeshClearance.canPlace(box, supportHeight: 0, triangles: triangles)
    )
}

@Test("网格里每个格子：局部三角形判定与全量三角形判定完全一致")
func localTrianglesNeverMissACollision() {
    // 一个有点"家具"的房间：地面、桌面、两级台阶、三面墙/柱子。
    let triangles = flatFloor(minimumX: -3, maximumX: 3, minimumZ: -3, maximumZ: 3)
        + horizontalQuad(minimumX: 0.4, maximumX: 1.4, minimumZ: 0.4, maximumZ: 1.4, y: 0.8)
        + horizontalQuad(minimumX: -2, maximumX: -1.2, minimumZ: -2, maximumZ: -1.2, y: 0.3)
        + horizontalQuad(minimumX: -2, maximumX: -1.2, minimumZ: -1.2, maximumZ: -0.4, y: 0.6)
        + verticalQuad(x: 0.6, minimumY: 0, maximumY: 2, minimumZ: -2, maximumZ: 0.2)
        + verticalQuad(x: -0.75, minimumY: 0, maximumY: 2, minimumZ: 1, maximumZ: 2.5)
        + verticalQuad(x: 2.1, minimumY: 0, maximumY: 1.2, minimumZ: -0.5, maximumZ: 0.5)
    let world = TriangleMeshCollisionWorld(triangles: triangles, cellSize: 0.25)
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: -3, maximumX: 3, minimumZ: -3, maximumZ: 3),
        seed: WorldVector3(x: 0, y: 0, z: 0)
    )
    #expect(!grid.layers.isEmpty)

    let footprint = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    var blockedByMeshCount = 0
    var comparisons = 0
    for ref in grid.layers {
        let box = PropPlacementEvaluator.placementVolume(
            footprint: footprint,
            height: 0.4,
            at: ref,
            spacing: grid.spacing
        )
        let center = SIMD2<Float>(Float(box.center.x), Float(box.center.z))
        let half = footprint.halfExtents
        let localBounds = WorldPlanarBounds(
            centerX: center.x,
            centerZ: center.y,
            halfExtentX: half.x,
            halfExtentZ: half.y
        ).expanded(by: PropPlacementEvaluator.triangleQueryMargin)
        let local = world.triangles(in: localBounds)
        let localVerdict = WorldPropMeshClearance.canPlace(
            box,
            supportHeight: ref.supportHeight,
            triangles: local
        )
        let fullVerdict = WorldPropMeshClearance.canPlace(
            box,
            supportHeight: ref.supportHeight,
            triangles: triangles
        )
        #expect(localVerdict == fullVerdict, "格 \(ref.column) 层 \(ref.layer.layer) 的局部判定与全量不一致")
        comparisons += 1
        if !localVerdict { blockedByMeshCount += 1 }
    }
    // 用例本身要有意义：确实存在被网格挡住、也存在可放的格子。
    #expect(comparisons > 400)
    #expect(blockedByMeshCount > 0)
    #expect(blockedByMeshCount < comparisons)
}

@Test("空间分桶让放置判定只吃局部三角形（对比全量）")
func triangleBucketingKeepsPlacementCheap() {
    // 合成一块 20 m × 20 m、0.0625 m 细分的连续地面：320 × 320 四边形 = 204,800 三角形，
    // 与真实房间的 161,600 个三角形同一量级。
    let spacing: Float = 0.0625
    let side = 320
    var triangles: [WorldTriangle] = []
    triangles.reserveCapacity(side * side * 2)
    for x in 0 ..< side {
        for z in 0 ..< side {
            let minimumX = Float(x) * spacing
            let minimumZ = Float(z) * spacing
            triangles.append(contentsOf: horizontalQuad(
                minimumX: minimumX,
                maximumX: minimumX + spacing,
                minimumZ: minimumZ,
                maximumZ: minimumZ + spacing,
                y: 0
            ))
        }
    }
    let world = TriangleMeshCollisionWorld(triangles: triangles, cellSize: 0.25)
    #expect(triangles.count == 204_800)

    // 单个 footprint 的范围查询只拿到一小撮三角形。
    let footprint = WorldPlanarFootprint(size: SIMD2(0.5, 0.5))
    let localBounds = WorldPlanarBounds(
        centerX: 1,
        centerZ: 1,
        halfExtentX: footprint.halfExtents.x,
        halfExtentZ: footprint.halfExtents.y
    ).expanded(by: PropPlacementEvaluator.triangleQueryMargin)
    let local = world.triangles(in: localBounds)
    #expect(local.count >= 2)
    #expect(local.count <= 256, "footprint 局部三角形必须是个位/几十个量级，实际 \(local.count)")
    #expect(local.count * 100 < triangles.count)

    // 小范围派生一张网格用于反复评估（网格本身不是这次要测的开销）。
    let grid = PropSupportGridBuilder.build(
        collision: world,
        bounds: WorldPlanarBounds(minimumX: 0.5, maximumX: 2.5, minimumZ: 0.5, maximumZ: 2.5),
        seed: WorldVector3(x: 1, y: 0, z: 1)
    )
    #expect(grid.layers.count == 81)

    let clock = ContinuousClock()
    let box = PropPlacementEvaluator.placementVolume(
        footprint: footprint,
        height: 0.3,
        at: grid.layers[0],
        spacing: grid.spacing
    )
    let fullStart = clock.now
    let fullVerdict = WorldPropMeshClearance.canPlace(
        box,
        supportHeight: 0,
        triangles: triangles
    )
    let fullElapsed = fullStart.duration(to: clock.now)
    #expect(fullVerdict)

    let repeats = 20
    let evaluateStart = clock.now
    var rejected = 0
    var outsideBounds = 0
    for _ in 0 ..< repeats {
        for ref in grid.layers {
            guard let reason = evaluate(footprint, at: ref, grid: grid, collision: world) else {
                continue
            }
            // 锚定列是 footprint 的最小角，所以贴边列的占地必然伸到网格外：这部分不算失败。
            if reason == .outsideBounds {
                outsideBounds += 1
            } else {
                rejected += 1
            }
        }
    }
    let evaluateElapsed = evaluateStart.duration(to: clock.now)
    #expect(rejected == 0)
    #expect(outsideBounds > 0)
    let evaluateCount = repeats * grid.layers.count
    print(
        "[分桶证据] 全量三角形 \(triangles.count)，单格局部三角形 \(local.count)；"
            + "单次全量 canPlace \(fullElapsed)，"
            + "\(evaluateCount) 次放置判定（含范围查询）共 \(evaluateElapsed)，"
            + "其中越界拒绝 \(outsideBounds) 次（贴边列，符合预期）"
    )
    #expect(evaluateElapsed < .seconds(20))
}

// MARK: - fail-closed

@Test("拿不到三角形几何时明确失败，不会 fail-open")
func propSupportGeometryFailsClosed() throws {
    // 只持有阻挡体积的碰撞世界给不出三角形，因此不实现 WorldPropSupportQuerying。
    let replaceable = ReplaceableCollisionWorld(
        initial: CollisionVolumeWorld(volumes: [])
    )
    #expect(replaceable.propSupportQuerying() == nil)
    #expect(throws: WorldPropSupportGeometryError.geometryUnavailable) {
        _ = try replaceable.requirePropSupportQuerying()
    }

    // 换成持有网格几何的世界之后才拿得到三角形。
    let mesh = TriangleMeshCollisionWorld(
        triangles: flatFloor(minimumX: -1, maximumX: 1, minimumZ: -1, maximumZ: 1)
    )
    replaceable.replace(with: mesh)
    let support = try #require(replaceable.propSupportQuerying())
    #expect(
        support.triangles(
            in: WorldPlanarBounds(minimumX: -1, maximumX: 1, minimumZ: -1, maximumZ: 1)
        ).count == 2
    )

    // 反向确认：CollisionVolumeWorld 自己根本没有 triangles(in:)，无法被当成几何来源。
    let volumesOnly: any WorldCollisionQuerying = CollisionVolumeWorld(volumes: [])
    #expect(!(volumesOnly is any WorldPropSupportQuerying))
}
