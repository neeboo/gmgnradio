import Foundation
import simd
import WorldRuntime

/// 展示台与独立物件的碰撞体。
///
/// 这里**不再**有"具名摆放面"表：摆放的承托面由 `PropSupportGrid` 从真实几何派生，
/// 判定由 `PropPlacementEvaluator` 用局部三角形完成。
enum ResidentPropPlacementConfiguration {
    static let tablePosition = SIMD3<Float>(-2.7, -0.03, -5)
    static let tableSize = SIMD3<Float>(0.9, 0.55, 0.65)
    static let tableCollisionID = "resident.display_table.collision"
    static var tableCollision: WorldCollisionVolume {
        let half = tableSize * Float(0.5)
        let center = WorldVector3(x: tablePosition.x, y: tablePosition.y + half.y, z: tablePosition.z)
        let extents = WorldVector3(x: half.x, y: half.y, z: half.z)
        return WorldCollisionVolume(id: tableCollisionID, center: center, halfExtents: extents,
                                    rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true)
    }
    static func independentCollisionVolumes(_ manifest: WorldManifest) -> [WorldCollisionVolume] {
        manifest.collisionVolumes.filter { ["collision.jukebox", "wish_machine.collision"].contains($0.id) } + [tableCollision]
    }
}
