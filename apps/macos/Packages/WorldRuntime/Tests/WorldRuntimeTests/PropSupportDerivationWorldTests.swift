import Foundation
import Testing
import simd

@testable import WorldRuntime

/// 合成场景：4×4 m 平地 + 一张顶面在 0.5 m 的桌子。
private func derivationFixture() -> (
    floor: [WorldTriangle],
    table: WorldCollisionVolume,
    bounds: WorldPlanarBounds,
    seed: WorldVector3
) {
    let floor = [
        WorldTriangle(SIMD3<Float>(-2, 0, -2), SIMD3<Float>(2, 0, -2), SIMD3<Float>(2, 0, 2)),
        WorldTriangle(SIMD3<Float>(-2, 0, -2), SIMD3<Float>(2, 0, 2), SIMD3<Float>(-2, 0, 2)),
    ]
    let table = WorldCollisionVolume(
        id: "fixture.table",
        center: WorldVector3(x: 0, y: 0.25, z: 0),
        halfExtents: WorldVector3(x: 0.4, y: 0.25, z: 0.4),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        isBlocking: true
    )
    return (
        floor,
        table,
        WorldPlanarBounds(minimumX: -2, maximumX: 2, minimumZ: -2, maximumZ: 2),
        WorldVector3(x: 1.5, y: 0, z: 1.5)
    )
}

@Test("Derivation world raises the ground to a furniture top, and keeps blocking the capsule")
func derivationWorldRaisesGroundAndStillBlocks() {
    let fixture = derivationFixture()
    let mesh = TriangleMeshCollisionWorld(triangles: fixture.floor)
    let world = PropSupportDerivationWorld(base: mesh, topVolumes: [fixture.table])
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)

    // `groundHeight` 的 y 受限契约：查询高度在桌面之上时，桌面就是这一列的承托面。
    // 派生器正是靠这个契约逐层下降，把一列里的地面与桌面都收进来。
    let atTop = world.groundHeight(at: SIMD3(0, 0.6, 0))
    #expect(atTop != nil)
    #expect(abs((atTop ?? 0) - 0.5) < 0.001, "above the table, the table top is the ground")

    // 而查询高度在地面时，返回的是**地面**：桌面属于更高的一层，不能在这里就冒出来，
    // 否则同一高度会被反复取到、把地面层永远挡掉（这条是实测踩过的坑）。
    let atFloor = world.groundHeight(at: SIMD3(0, 0, 0))
    #expect(atFloor != nil)
    #expect(abs((atFloor ?? 1)) < 0.001, "at floor level the floor is the ground, not the table top")

    // 但体积仍然挡住人：脚底落在地面、身体穿进桌子，所以那一列不是"站立层"，
    // 居民不会站到桌子上。（胶囊的 position 是**脚底**，脚底抬到 0.5 就是站在桌面上了。）
    #expect(world.canOccupy(capsule, at: SIMD3(0, 0, 0)) == false, "the table still blocks a capsule standing inside it")

    // 桌子外面地面不变。
    let outside = world.groundHeight(at: SIMD3(1.5, 0, 1.5))
    #expect(outside != nil)
    #expect(abs((outside ?? 0)) < 0.001, "ground away from the table stays at zero")
}

@Test("Derivation world turns a furniture top into a support layer the mesh alone never has")
func derivationWorldTurnsFurnitureTopIntoASupportLayer() {
    let fixture = derivationFixture()
    let mesh = TriangleMeshCollisionWorld(triangles: fixture.floor)
    let parameters = PropSupportGridParameters()

    let meshOnly = PropSupportGridBuilder.build(
        collision: mesh, bounds: fixture.bounds, seed: fixture.seed, parameters: parameters
    )
    // 只用网格时，桌子顶面**不存在**——这正是 §12 回归 2 的成因。
    #expect(
        !meshOnly.layers.contains { abs($0.supportHeight - 0.5) < 0.01 },
        "the mesh alone has no layer at the table top"
    )

    let world = PropSupportDerivationWorld(base: mesh, topVolumes: [fixture.table])
    let withTops = PropSupportGridBuilder.build(
        collision: world, bounds: fixture.bounds, seed: fixture.seed, parameters: parameters
    )
    // 派生世界这一侧是好的：桌面既成了"地面"，也成了几何（下面两条断言是真的）。
    #expect(world.triangles(in: fixture.bounds).count == 4, "the table top is supplied as geometry")
    #expect(withTops.report.coveredGroundLayers > 0, "the table columns are recognised as furniture-covered ground")

    // 但**过滤器**还有一环没接上，所以桌面仍然到不了最终网格。见设计文档 §12 回归 2。
    // 用 `withKnownIssue` 记录：修好之后这条会**主动失败**（"known issue was not recorded"），
    // 逼着把它翻成真断言，而不是让缺口悄悄留着。
    withKnownIssue("""
    候选判定是"站立层 ∪ 家具下地面层"。家具 footprint 外面有一圈列：格子压在家具上、    但列角点落在外面 —— 它们既不可站立、列里又没有第二层，于是不在候选里，把 footprint     内部的列整个隔离，BFS 进不去，桌面（以及家具底下的地面）一起被剔除。    修法要让站立判据与格子对齐（或换一种标记），会改变"墙靠不在候选里被排除"这条性质，    需要连同墙用例与真实舱体数字一起重新验证。见 docs/plans/2026-09-27-p2-decoration-design.md §12。
    """) {
        let tableTop = withTops.layers.filter {
            abs($0.supportHeight - 0.5) < 0.01
                && abs(Float($0.column.x) * withTops.spacing) <= 0.4
                && abs(Float($0.column.z) * withTops.spacing) <= 0.4
        }
        #expect(!tableTop.isEmpty, "the table top becomes a placeable support layer")
        #expect(withTops.report.furnitureBandLayers > 0, "the top is retained through the furniture band")
    }
}

/// 声称支持派生、但给不出任何三角形的世界。用来覆盖"拿不到几何"这条路径：
/// `CollisionVolumeWorld` 刻意**不**实现 `WorldPropSupportQuerying`，所以它做不了这个替身。
private struct NoTrianglesWorld: WorldCollisionQuerying, WorldPropSupportQuerying {
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { false }
    func groundHeight(at position: SIMD3<Float>) -> Float? { nil }
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] { [] }
}

@Test("Derivation world without triangles derives an empty grid rather than allowing everything")
func derivationWorldWithoutTrianglesIsFailClosed() {
    let fixture = derivationFixture()
    // 刻意给**空**的 topVolumes：只要还有家具顶面，就还有合成的三角形，
    // 那就不是"拿不到几何"这条路径了。
    let world = PropSupportDerivationWorld(base: NoTrianglesWorld(), topVolumes: [])
    #expect(world.triangles(in: fixture.bounds).isEmpty)

    let grid = PropSupportGridBuilder.build(
        collision: world, bounds: fixture.bounds, seed: fixture.seed,
        parameters: PropSupportGridParameters()
    )
    #expect(grid.layers.isEmpty, "no geometry means no placeable cell, never 'placeable everywhere'")
}
