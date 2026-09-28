import Foundation
import simd

/// 建造模式里"光标点到哪一件**已经摆出来的**物件"的命中判定。
///
/// 为什么用 yaw 包围盒而不是模型三角形：摆放与碰撞用的就是
/// `WorldObjectState.generatedCollisionVolume` 这个盒子（`PropPlacementEvaluator` 判定的 OBB）。
/// 用它做命中，用户"能点中的范围"和系统"认为它占的地方"是同一个事实，不需要为拾取再加载
/// 一份几何、也不会有"点得中但放不下"的两套口径。
///
/// 命中判据与 `WorldPropMeshClearance.canPlace` 的 `local()` **互逆**（世界 → 局部绕 y 反向
/// 旋转），所以同一件物件在两处的朝向解释一致。
///
/// 本文件**刻意只依赖 Foundation + simd，不 import WorldRuntime**：沿用 `PropSupportGridPicker`
/// 的做法，离线 harness 只编译这几个纯文件就能逐项验证（射线求交最容易错的就是朝向与容差）。
enum ResidentPropHitTest {
    /// 一个可命中的物件：它的 yaw 包围盒。
    struct Target: Equatable, Sendable {
        let objectID: String
        let center: SIMD3<Float>
        let halfExtents: SIMD3<Float>
        /// 绕 y 轴的朝向（与 `WorldCollisionVolume.rotation` 的 yaw 同口径）。
        let yaw: Float

        init(objectID: String, center: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float) {
            self.objectID = objectID
            self.center = center
            self.halfExtents = halfExtents
            self.yaw = yaw
        }
    }

    /// 光标下**最近**的那件物件；没命中返回 nil。
    ///
    /// `normalized` 与 `inverseViewProjection` 与 `PropSupportGridPicker` 同一套约定
    /// （归一化、左上原点），所以"点格子"和"点物件"用同一支射线。
    static func hit(
        normalized: SIMD2<Float>,
        inverseViewProjection: simd_float4x4,
        targets: [Target],
        maximumDistance: Float = 30
    ) -> String? {
        guard !targets.isEmpty,
              maximumDistance.isFinite, maximumDistance > 0,
              let ray = PropSupportGridPicker.ray(normalized: normalized, inverseViewProjection: inverseViewProjection)
        else { return nil }
        let directionLength = simd_length(ray.direction)
        guard directionLength > 0.000001 else { return nil }
        var best: (distance: Float, objectID: String)?
        for target in targets {
            guard let parameter = distance(rayOrigin: ray.origin, rayDirection: ray.direction, target: target) else { continue }
            let distance = parameter * directionLength
            guard distance <= maximumDistance else { continue }
            // 取最近的：两件物件前后重叠时，命中的是离相机更近的那件。
            if let current = best, current.distance <= distance { continue }
            best = (distance, target.objectID)
        }
        return best?.objectID
    }

    /// 射线 → yaw 包围盒的**入射参数**：命中点是 `rayOrigin + t * rayDirection`。
    /// 射线起点在盒内时返回 0；不相交返回 nil。
    static func distance(rayOrigin: SIMD3<Float>, rayDirection: SIMD3<Float>, target: Target) -> Float? {
        let center = target.center, half = target.halfExtents
        guard [center.x, center.y, center.z, half.x, half.y, half.z, target.yaw].allSatisfy(\.isFinite),
              half.x > 0, half.y > 0, half.z > 0,
              [rayOrigin.x, rayOrigin.y, rayOrigin.z,
               rayDirection.x, rayDirection.y, rayDirection.z].allSatisfy(\.isFinite)
        else { return nil }

        // 世界 → 局部：绕 y 反向旋转（与 `WorldPropMeshClearance.canPlace` 的 local() 同一式子）。
        let cosine = cos(target.yaw), sine = sin(target.yaw)
        func local(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let d = point - center
            return SIMD3(cosine * d.x - sine * d.z, d.y, sine * d.x + cosine * d.z)
        }
        let origin = local(rayOrigin)
        let direction = local(rayOrigin + rayDirection) - origin

        var entry = -Float.greatestFiniteMagnitude
        var exit = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = origin[axis], d = direction[axis], h = half[axis]
            if abs(d) < 0.000001 {
                // 与该轴平行：这一轴上必须在盒内，否则永不相交。
                guard o >= -h, o <= h else { return nil }
                continue
            }
            let near = (-h - o) / d, far = (h - o) / d
            entry = max(entry, min(near, far))
            exit = min(exit, max(near, far))
            guard entry <= exit else { return nil }
        }
        guard exit >= 0, entry.isFinite else { return nil }
        return max(entry, 0)
    }
}
