import Foundation

/// Read-only projection of the validated bundled package. Never seeds or edits state.
enum UnityBuiltinDevicesBridge {
    static func snapshot(worldID: String?, bundle: Bundle = .main) -> [[String: Any]] {
        guard let worldID,
              let package = try? LivingWorldBootstrap.loadBundledCanary(bundle: bundle),
              package.manifest.worldID == worldID else { return [] }
        return snapshot(package: package)
    }
    static func snapshot(package: BundledLivingWorldPackage) -> [[String:Any]] {
        return package.manifest.resources.compactMap { resource in
            guard resource.kind == "prop.procedural",
                  LivingWorldBootstrap.proceduralDeclaration(id: resource.id, in: package) != nil,
                  let data = try? Data(contentsOf: package.packageRoot.appendingPathComponent(resource.path)),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["builtin.jukebox", "builtin.wish_machine"].contains(value["renderer"] as? String ?? "") else { return nil }
            var template = value
            // Provenance is the authored resource's exact manifest collision ID.
            // No nearest-volume or coordinate matching is permitted.
            guard let sourceID = template["collisionSourceID"] as? String,
                  let collision = package.manifest.collisionVolumes.first(where: { $0.id == sourceID }) else { return nil }
            if template["size"] == nil,
               !sourceID.isEmpty {
                template["size"] = [collision.halfExtents.x * 2, collision.halfExtents.y * 2, collision.halfExtents.z * 2]
            }
            return template
        }
    }
}
