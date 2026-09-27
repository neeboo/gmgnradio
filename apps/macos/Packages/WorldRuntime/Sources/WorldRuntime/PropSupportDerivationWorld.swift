import Foundation
import simd

/// 摆放**派生**用的碰撞世界：在基础世界之上，把一组阻挡体积的**顶面**也当作可承托面。
///
/// 为什么需要单独一个类型，而不是让 App 的 `MarbleLivingCabinCollisionWorld.groundHeight`
/// 也去问家具：`groundHeight` 同时决定**居民落地**。让居民把家具顶面当成地面，居民就会站到
/// 桌子上、柜子上。而"这里有一块面可以放东西"和"人能站在这里"是两件事：
///
/// - **摆放派生**需要看到家具顶面 —— 否则桌面、柜顶永远不成为承托层，
///   "把咖啡机放在展示台上"这条路就没了（这是 §12 记录的回归 2）；
/// - **居民落地**必须看不到家具顶面。
///
/// 组合方式：
/// - `canOccupy`：两边都要能容纳（体积仍然挡住居民，所以桌子正下方的列不是站立层）；
/// - `groundHeight`：取两边**较高者**（网格地面在家具底下时，家具顶面胜出）；
/// - `canTraverse`：沿用基础世界的判定，并额外保证沿途不被体积挡住；
/// - `triangles(in:)`：转发给基础世界，拿不到就返回空数组（派生器会因此得到空网格，
///   与 `MarbleLivingCabinCollisionWorld` 的 conformance 同一套 fail-closed 理由）。
public struct PropSupportDerivationWorld: WorldCollisionQuerying, WorldPropSupportQuerying {
    public let base: any WorldPropSupportQuerying
    /// 这些体积的**顶面**会被当作承托面（同时它们仍然挡人）。
    public let topVolumes: [WorldCollisionVolume]
    private let tops: CollisionVolumeWorld

    public init(base: any WorldPropSupportQuerying, topVolumes: [WorldCollisionVolume]) {
        self.base = base
        self.topVolumes = topVolumes
        self.tops = CollisionVolumeWorld(volumes: topVolumes)
    }

    public func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        base.canOccupy(capsule, at: position) && tops.canOccupy(capsule, at: position)
    }

    /// **必须遵守 `groundHeight` 的 y 受限契约**：返回"不高于 `position.y + 0.05` 的
    /// 最高承托面"。派生器正是靠这个契约逐层下降、把一列里的地面与桌面都收进来。
    ///
    /// `CollisionVolumeWorld.groundHeight` **不**遵守它（它返回体积顶面，与查询高度无关），
    /// 所以这里要自己加上限：天花板还没压到桌面以下时，桌面就是这一列的承托面；压下去之后
    /// 桌面必须"消失"，否则同一高度会被反复取到、把地面层永远挡掉。
    public func groundHeight(at position: SIMD3<Float>) -> Float? {
        let ground = base.groundHeight(at: position)
        let top = tops.groundHeight(at: position)
        let reachableTop = (top.map { $0 <= position.y + 0.05 } ?? false) ? top : nil
        switch (ground, reachableTop) {
        case (nil, nil): return nil
        case (let ground?, nil): return ground
        case (nil, let top?): return top
        case (let ground?, let top?): return max(ground, top)
        }
    }

    public func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        guard base.canTraverse(capsule, from: start, to: destination, maximumStepHeight: maximumStepHeight)
        else { return false }
        // 沿途也要能容纳：与 `PropLayoutCollisionWorld` 同样的采样口径。
        let delta = destination - start
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        guard distance.isFinite, distance < 10_000 else { return false }
        let steps = max(1, Int(ceil(distance / max(0.01, capsule.radius / 2))))
        for index in 0...steps {
            let point = start + delta * (Float(index) / Float(steps))
            guard tops.canOccupy(capsule, at: point) else { return false }
        }
        return true
    }

    /// 基础几何 + **体积顶面合成出来的三角形**。
    ///
    /// 为什么要合成顶面，而不是只让 `groundHeight` 返回它：派生器的列扫描**天花板来自
    /// 三角形的最高点**（见 `PropSupportGridBuilder.build`）。碰撞体积没有三角形，所以
    /// 只改 `groundHeight` 的话，天花板仍然停在地面高度，扫描永远到不了桌面 ——
    /// 顶面必须作为几何真的存在。
    ///
    /// 合成顶面还顺带让评估器的网格净空判定把桌面当成"可站立面"（和地板一样跳过），
    /// 而桌子的**侧面**由 `blockingVolumes` 那条检查覆盖，两者不重不漏。
    public func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        let base = (self.base as? any WorldPropSupportQuerying)?.triangles(in: bounds) ?? []
        return base + topVolumes.flatMap { topFaceTriangles(of: $0, in: bounds) }
    }

    /// 一个体积顶面的两个三角形（只考虑 yaw，与放置判定的 `WorldPropBoxOverlap` 同口径）。
    /// 顶面与范围完全不相交时不产出，避免把远处家具的顶面也塞进这次范围查询。
    private func topFaceTriangles(
        of volume: WorldCollisionVolume,
        in bounds: WorldPlanarBounds
    ) -> [WorldTriangle] {
        let half = volume.halfExtents
        guard half.x.isFinite, half.y.isFinite, half.z.isFinite,
              half.x > 0, half.y > 0, half.z > 0,
              volume.center.x.isFinite, volume.center.y.isFinite, volume.center.z.isFinite
        else { return [] }
        let top = volume.center.y + half.y
        // 平面范围不相交就跳过（包围盒判断，保守即可）。
        guard volume.center.x + half.x >= bounds.minimumX,
              volume.center.x - half.x <= bounds.maximumX,
              volume.center.z + half.z >= bounds.minimumZ,
              volume.center.z - half.z <= bounds.maximumZ
        else { return [] }

        let q = volume.rotation
        let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        let cosine = cos(yaw), sine = sin(yaw)
        func corner(_ dx: Float, _ dz: Float) -> SIMD3<Float> {
            SIMD3(
                volume.center.x + cosine * dx + sine * dz,
                top,
                volume.center.z - sine * dx + cosine * dz
            )
        }
        let a = corner(-half.x, -half.z)
        let b = corner(half.x, -half.z)
        let c = corner(half.x, half.z)
        let d = corner(-half.x, half.z)
        return [WorldTriangle(a, b, c), WorldTriangle(a, c, d)]
    }
}
