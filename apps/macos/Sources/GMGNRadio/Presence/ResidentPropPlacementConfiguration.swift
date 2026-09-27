import Foundation
import simd
import WorldRuntime

/// Small authored support areas verified against this cabin's shipped collider.
enum ResidentPropPlacementConfiguration {
    static let tablePosition = SIMD3<Float>(-2.7, -0.03, -5)
    static let tableSize = SIMD3<Float>(0.9, 0.55, 0.65)
    static let tableCollisionID = "resident.display_table.collision"
    static let surfaces: [ResidentPropSupportSurface] = [
        .init(id: "resident.floor", center: .init(x: -2.6, y: -0.03, z: -3),
              halfExtents: .init(x: 0.4, y: 0, z: 0.5), yaw: 0, excludedCollisionID: nil),
        .init(id: "resident.display_table", center: .init(x: tablePosition.x, y: tablePosition.y + tableSize.y, z: tablePosition.z),
              halfExtents: .init(x: tableSize.x / 2, y: 0, z: tableSize.z / 2), yaw: 0,
              excludedCollisionID: tableCollisionID)
    ]
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
    static func name(for surfaceID: String) -> String {
        surfaceID == "resident.display_table" ? "展示台" : "地面摆放区"
    }
    static func nearbyTriangles(_ triangles: [WorldTriangle]) -> [WorldTriangle] {
        triangles.filter { triangle in
            let vertices = [triangle.first, triangle.second, triangle.third]
            let lowX = vertices.map(\.x).min()!, highX = vertices.map(\.x).max()!
            let lowZ = vertices.map(\.z).min()!, highZ = vertices.map(\.z).max()!
            return surfaces.contains { surface in
                lowX <= surface.center.x + surface.halfExtents.x && highX >= surface.center.x - surface.halfExtents.x
                    && lowZ <= surface.center.z + surface.halfExtents.z && highZ >= surface.center.z - surface.halfExtents.z
            }
        }
    }
}
