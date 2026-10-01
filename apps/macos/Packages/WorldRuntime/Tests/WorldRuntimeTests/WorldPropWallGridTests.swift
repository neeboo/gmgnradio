import Foundation
import Testing

@testable import WorldRuntime

// ===========================================================================
// 靠墙：竖直面派生的判据（合成几何，不依赖真实 GLB）
// ===========================================================================

/// 水平四边形（地板），拆成两个三角形。
private func floorQuad(
    minimumX: Float, maximumX: Float, minimumZ: Float, maximumZ: Float, y: Float
) -> [WorldTriangle] {
    let a = SIMD3<Float>(minimumX, y, minimumZ)
    let b = SIMD3<Float>(maximumX, y, minimumZ)
    let c = SIMD3<Float>(maximumX, y, maximumZ)
    let d = SIMD3<Float>(minimumX, y, maximumZ)
    return [WorldTriangle(a, b, c), WorldTriangle(a, c, d)]
}

/// 竖直四边形（墙），位于平面 x = x，z ∈ [minimumZ, maximumZ]，y ∈ [minimumY, maximumY]。
private func wallQuadX(
    x: Float, minimumY: Float, maximumY: Float, minimumZ: Float, maximumZ: Float
) -> [WorldTriangle] {
    let a = SIMD3<Float>(x, minimumY, minimumZ)
    let b = SIMD3<Float>(x, maximumY, minimumZ)
    let c = SIMD3<Float>(x, maximumY, maximumZ)
    let d = SIMD3<Float>(x, minimumY, maximumZ)
    return [WorldTriangle(a, b, c), WorldTriangle(a, c, d)]
}

/// 房间：地板 x ∈ [-1.9, 2]、z ∈ [-2, 2]（**墙脚下面的地板多伸出一点** —— 现实里的墙是
/// 坐在地板上的）；墙在 `wallX`。
///
/// 为什么地板要比墙多伸 0.15 m：承托网格的列扫描在**列的最小角**采样
/// （`PropSupportGridBuilder.build`：`Float(x) * spacing`），所以地板刚好在墙面处截止时，
/// 贴着墙那一列会采到地板之外、判成"没有承托层"。真实舱体的地板一直铺到墙线上，
/// 这里如实照做。
private func room(wallX: Float) -> (world: TriangleMeshCollisionWorld, bounds: WorldPlanarBounds) {
    let triangles = floorQuad(minimumX: -1.9, maximumX: 2, minimumZ: -2, maximumZ: 2, y: 0)
        + wallQuadX(x: wallX, minimumY: 0, maximumY: 2.4, minimumZ: -2, maximumZ: 2)
    return (
        TriangleMeshCollisionWorld(triangles: triangles, cellSize: 0.25),
        WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2)
    )
}

private func grid(
    _ world: any WorldPropSupportQuerying,
    bounds: WorldPlanarBounds
) -> PropSupportGrid {
    PropSupportGridBuilder.build(
        collision: world, bounds: bounds, seed: WorldVector3(x: 0, y: 0.1, z: 0)
    )
}

@Test("竖直面从既有几何里派生：外墙只朝房间出一份，且位置吸附到格边界")
func derivesVerticalFaceFromExistingGeometry() throws {
    let scene = room(wallX: -1.75)
    let support = grid(scene.world, bounds: scene.bounds)
    #expect(support.layers.count > 20, "地板派生出来了（实测 \(support.layers.count) 层）")

    let patches = WorldPropWallGrid.derive(
        triangles: scene.world.triangles(in: scene.bounds), bounds: scene.bounds, grid: support
    )
    let walls = patches.filter { $0.axis == .x }
    #expect(walls.count == 1, "外墙只该朝**房间里**出一份（实测 \(walls.count) 份：\(walls.map(\.id))）")
    let wall = try #require(walls.first)
    #expect(abs(wall.coordinate - (-1.75)) < 1e-5, "墙面坐标（实测 \(wall.coordinate)）")
    #expect(wall.normalSign == 1, "房间在 x > 墙面那一侧")
    #expect(abs(wall.minimumHeight - 0) < 1e-5 && abs(wall.maximumHeight - 2.4) < 1e-5)
    #expect(wall.columns.contains(PropSupportColumn(x: -7, z: 0)), "贴墙锚定列 = 覆盖 [-1.75,-1.5] 的那一列")
    // 房间侧那一列有地板 ⇒ 这一面墙可以被"靠"。
    #expect(!wall.columns.isEmpty)
    #expect(wall.normal == SIMD2<Float>(1, 0))
}

@Test("靠墙候选：背面朝墙、正面朝房间，落在**能站的最近一格**上并被同一个判据接受")
func wallAttachmentIsBackToTheWallAndPlaceable() throws {
    let scene = room(wallX: -1.75)
    let support = grid(scene.world, bounds: scene.bounds)
    let patches = WorldPropWallGrid.derive(
        triangles: scene.world.triangles(in: scene.bounds), bounds: scene.bounds, grid: support
    )
    let wall = try #require(patches.first { $0.axis == .x })
    let size = WorldVector3(x: 0.4, y: 0.5, z: 0.2)

    let candidates = WorldPropWallGrid.candidateAttachments(patch: wall, grid: support, size: size)
    let candidate = try #require(candidates.first { $0.position.z > -1 && $0.position.z < 1 })
    // yaw：把本地 +Z 转到外法线（+X）⇒ π/2。背面（本地 -Z）因此朝 -X = 墙。
    #expect(abs(candidate.yaw - .pi / 2) < 1e-5, "实测 yaw=\(candidate.yaw)")
    // ⚠️ 贴墙那一格**没有承托层**（站立胶囊半径 0.2 m 把贴墙一圈剔掉了，见下一个用例），
    //    所以最近的可放锚定列退了一格：背面落在 x = -1.5（离墙面 0.25 m）。
    #expect(abs((candidate.position.x - size.z / 2) - (-1.5)) < 1e-5,
            "最近的**可放**背面（实测 \(candidate.position.x - size.z / 2)）")

    // 判定：走**既有那一条**通路（`PropPlacementEvaluator`），一个字都没改。
    let yaw = atan2(wall.normal.x, wall.normal.y)
    let reason = PropPlacementEvaluator.evaluate(
        footprint: WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw),
        height: size.y,
        at: candidate.layer,
        grid: support,
        collision: scene.world,
        blockingVolumes: [],
        placedProps: []
    )
    #expect(reason == nil, "背朝墙的候选必须能放（实测 \(String(describing: reason))）")
}

@Test("承托网格**刻意剔除了贴墙那一圈**：贴墙候选因此被既有判据判成 noSupport（可见拒绝）")
func flushAgainstTheWallIsRefusedByTheExistingSupportCriterion() throws {
    let scene = room(wallX: -1.75)
    let support = grid(scene.world, bounds: scene.bounds)
    let patches = WorldPropWallGrid.derive(
        triangles: scene.world.triangles(in: scene.bounds), bounds: scene.bounds, grid: support
    )
    let wall = try #require(patches.first { $0.axis == .x })
    let size = WorldVector3(x: 0.4, y: 0.5, z: 0.2)

    // 扫描**看见**了贴墙那一列（列扫描在列最小角采样，-1.75 就在地板上），
    // 但连通性/站立判据把它滤掉了 —— 这就是"靠墙放不下"的结构性原因。
    #expect(support.report.layersBeforeFilter > support.report.layersAfterFilter,
            "过滤前后层数必须不同（实测 \(support.report.layersBeforeFilter) → \(support.report.layersAfterFilter)）")
    let ringColumn = PropSupportColumn(x: -7, z: 0)
    #expect(support.contains(ringColumn), "边界内")
    #expect(support.layers(at: ringColumn).isEmpty,
            "贴墙那一列**没有承托层**（站立胶囊半径 0.2 m 进不去 ⇒ 被剔除）")

    // 强行把锚定列放在贴墙那一列上：判定必须**可见拒绝**，而不是"勉强能放"。
    let ringLayer = PropSupportLayer(
        layer: 0, supportHeight: 0,
        center: WorldVector3(x: -1.75, y: 0, z: 0)
    )
    let flush = try #require(WorldPropWallGrid.attachment(
        patch: wall,
        layer: PropSupportLayerRef(column: ringColumn, layer: ringLayer),
        anchorColumn: ringColumn,
        size: size,
        spacing: support.spacing
    ))
    #expect(abs((flush.position.x - size.z / 2) - (-1.75)) < 1e-5,
            "贴墙候选的背面本来就在墙面上（实测 \(flush.position.x - size.z / 2)）")
    let reason = PropPlacementEvaluator.evaluate(
        footprint: WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: flush.yaw),
        height: size.y,
        at: flush.layer,
        grid: support,
        collision: scene.world,
        blockingVolumes: [],
        placedProps: []
    )
    #expect(reason == .noSupport,
            "贴墙那一格没有承托层 ⇒ 必须是 .noSupport 可见拒绝，实测 \(String(describing: reason))")
}

@Test("墙前净空/穿墙：贴墙的盒子可放，插进墙里的盒子**必须被拒**")
func penetratingTheWallIsRejected() {
    let scene = room(wallX: -1.75)
    let triangles = scene.world.triangles(in: scene.bounds)
    let yaw: Float = .pi / 2
    func volume(centreX: Float) -> WorldCollisionVolume {
        WorldCollisionVolume(
            id: "probe",
            center: WorldVector3(x: centreX, y: 0.25, z: 0),
            halfExtents: WorldVector3(x: 0.2, y: 0.25, z: 0.1),
            rotation: WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
            isBlocking: true
        )
    }
    #expect(WorldPropMeshClearance.canPlace(volume(centreX: -1.65), supportHeight: 0, triangles: triangles),
            "背面正好贴在 x=-1.75 的墙面上 ⇒ 允许（接触不算插入）")
    #expect(!WorldPropMeshClearance.canPlace(volume(centreX: -1.75), supportHeight: 0, triangles: triangles),
            "中心压到墙面上 ⇒ 一半插进墙里 ⇒ **必须拒绝**（这一条就是'不许穿墙'）")
    // 整个盒子都在墙**背后**：净空判据看不到相交（它只判"插进几何"），
    // 所以那一条由承托判据回答 —— 墙背后没有承托层 ⇒ `.noSupport` 可见拒绝。
    let behind = PropPlacementEvaluator.evaluate(
        footprint: WorldPlanarFootprint(size: SIMD2(0.4, 0.2), yaw: yaw),
        height: 0.5,
        at: PropSupportLayerRef(
            column: PropSupportColumn(x: -7, z: 0),
            layer: PropSupportLayer(layer: 0, supportHeight: 0, center: WorldVector3(x: -1.75, y: 0, z: 0))
        ),
        grid: PropSupportGridBuilder.build(
            collision: scene.world, bounds: scene.bounds,
            seed: WorldVector3(x: 0, y: 0.1, z: 0)
        ),
        collision: scene.world,
        blockingVolumes: []
    )
    #expect(behind != nil, "墙背后没有承托层 ⇒ 必须可见拒绝（实测 \(String(describing: behind))）")
}

@Test("墙面吸附的量化方向是 fail-closed：墙不在格边界上时不会摆出穿墙的候选")
func quantizationNeverProducesAPenetratingCandidate() throws {
    // 墙在 x = -1.65：离格边界 -1.75 有 0.1 m。吸附（四舍五入）会落在 **-1.75**，
    // 也就是**墙里**——这一格必须被判据拒掉（红色），而不是画成"能靠墙"。
    let scene = room(wallX: -1.65)
    let support = grid(scene.world, bounds: scene.bounds)
    let patches = WorldPropWallGrid.derive(
        triangles: scene.world.triangles(in: scene.bounds), bounds: scene.bounds, grid: support
    )
    guard let wall = patches.first(where: { $0.axis == .x }) else { return }
    let size = WorldVector3(x: 0.4, y: 0.5, z: 0.2)
    let yaw = atan2(wall.normal.x, wall.normal.y)
    let candidates = WorldPropWallGrid.candidateAttachments(patch: wall, grid: support, size: size)
    for candidate in candidates {
        let reason = PropPlacementEvaluator.evaluate(
            footprint: WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw),
            height: size.y,
            at: candidate.layer,
            grid: support,
            collision: scene.world,
            blockingVolumes: [],
            placedProps: []
        )
        // 判据接受的那些，必须**真的**没有插进墙里 —— 用一个独立的直接探针复核。
        if reason == nil {
            let volume = WorldCollisionVolume(
                id: "candidate",
                center: WorldVector3(x: candidate.position.x, y: candidate.position.y + size.y / 2,
                                     z: candidate.position.z),
                halfExtents: WorldVector3(x: 0.2, y: 0.25, z: 0.1),
                rotation: WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
                isBlocking: true
            )
            #expect(WorldPropMeshClearance.canPlace(
                volume, supportHeight: candidate.position.y,
                triangles: scene.world.triangles(in: scene.bounds)
            ), "判定接受的候选绝不允许插进墙里（实测候选 \(candidate.position)）")
        }
    }
}

@Test("没有竖直面时派生出空集（地板不会冒充墙）")
func flatFloorHasNoWalls() {
    let triangles = floorQuad(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2, y: 0)
    let world = TriangleMeshCollisionWorld(triangles: triangles, cellSize: 0.25)
    let bounds = WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2)
    let support = grid(world, bounds: bounds)
    let patches = WorldPropWallGrid.derive(
        triangles: world.triangles(in: bounds), bounds: bounds, grid: support
    )
    #expect(patches.isEmpty, "平的房间里一个竖直面都不该有（实测 \(patches.map(\.id))）")
}

@Test("墙面 id 稳定、顺序确定（红/绿格与面板读数必须可复现）")
func wallDerivationIsDeterministic() {
    let scene = room(wallX: -1.75)
    let support = grid(scene.world, bounds: scene.bounds)
    let triangles = scene.world.triangles(in: scene.bounds)
    let first = WorldPropWallGrid.derive(triangles: triangles, bounds: scene.bounds, grid: support)
    let second = WorldPropWallGrid.derive(triangles: triangles, bounds: scene.bounds, grid: support)
    #expect(first == second)
    #expect(first.map(\.id) == first.map(\.id).sorted(), "id 顺序确定")
}
