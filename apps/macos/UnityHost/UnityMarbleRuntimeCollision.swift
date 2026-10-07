import Foundation
import WorldRuntime

/// Navigation reads the exact resource-bound collider used by the renderer.
/// A Marble package never receives a synthetic floor when its mesh is absent.
enum UnityMarbleRuntimeCollision {
    static func load(package: BundledLivingWorldPackage) throws -> TriangleMeshCollisionWorld? {
        guard let document = try UnityMarbleRuntimeDocument.load(package: package) else { return nil }
        let triangles = try GLBColliderDecoder().decode(
            data: Data(contentsOf: document.colliderURL(package: package), options: .mappedIfSafe),
            transform: document.colliderTransform)
        guard !triangles.isEmpty else { throw WorldAgentContextError.noWalkablePlacement }
        let collision = TriangleMeshCollisionWorld(triangles: triangles)
        let spawn = package.manifest.spawn.position
        let capsule = WorldCapsule(radius: 0.2, height: 1.8)
        guard collision.groundHeight(at: SIMD3(spawn.x, spawn.y + 0.05, spawn.z)) != nil,
              collision.canOccupy(capsule, at: SIMD3(spawn.x, spawn.y, spawn.z)) else {
            throw WorldAgentContextError.noWalkablePlacement
        }
        return collision
    }
}
