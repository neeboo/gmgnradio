import Foundation
import simd
import WorldRuntime

/// 展示台的几何与独立物件碰撞体。
///
/// 这里**不再**有"具名摆放面"表：摆放的承托面由 `PropSupportGrid` 从真实几何派生，
/// 判定由 `PropPlacementEvaluator` 用局部三角形完成。
///
/// 展示台的几何也**不再硬编码**：它是世界里一件真实家具，几何随 `world.json` 的
/// `collisionVolumes` 一起分发（`layout.json` 是它的作者源头）。之前硬编码在 App 里导致
/// 一个实测回归：烘焙器只用 `manifest.collisionVolumes` 当障碍，看不见硬编码的展示台，
/// 于是会穿过它布线（见设计文档 §12）。
enum ResidentPropPlacementConfiguration {
    static let tableCollisionID = "resident.display_table.collision"

    /// 独立物件的碰撞体 = manifest 里声明的全部体积。
    ///
    /// 以前这里按 id 白名单过滤，把"世界声明的家具"和"App 硬编码的展示台"拼在一起；
    /// 现在展示台也在 manifest 里，白名单没有意义了 —— 世界里声明了什么，就挡什么。
    static func independentCollisionVolumes(_ manifest: WorldManifest) -> [WorldCollisionVolume] {
        manifest.collisionVolumes
    }

    /// 展示台的碰撞体（从 manifest 取）。世界没有声明它时返回 nil。
    static func tableCollision(in manifest: WorldManifest) -> WorldCollisionVolume? {
        manifest.collisionVolumes.first { $0.id == tableCollisionID }
    }

    /// 展示台的视觉变换（底心 + 尺寸），由碰撞体反推。
    ///
    /// 反推而不是另存一份常量：两份几何一旦漂移，视觉与碰撞就对不上，而且没人会发现。
    static func tableTransform(in manifest: WorldManifest) -> (position: SIMD3<Float>, size: SIMD3<Float>)? {
        guard let volume = tableCollision(in: manifest) else { return nil }
        let half = volume.halfExtents
        return (
            SIMD3(volume.center.x, volume.center.y - half.y, volume.center.z),
            SIMD3(half.x * 2, half.y * 2, half.z * 2)
        )
    }
}
