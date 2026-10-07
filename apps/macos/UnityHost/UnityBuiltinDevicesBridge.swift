import Foundation

/// Read-only projection of the validated bundled package. Never seeds or edits state.
enum UnityBuiltinDevicesBridge {
    static func snapshot(worldID: String?, bundle: Bundle = .main) -> [[String: Any]] {
        guard let worldID,
              let package = try? LivingWorldBootstrap.loadBundledCanary(bundle: bundle),
              package.manifest.worldID == worldID else { return [] }
        return package.manifest.resources.compactMap { resource in
            guard resource.kind == "prop.procedural",
                  LivingWorldBootstrap.proceduralDeclaration(id: resource.id, in: package) != nil,
                  let data = try? Data(contentsOf: package.packageRoot.appendingPathComponent(resource.path)),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["builtin.jukebox", "builtin.wish_machine"].contains(value["renderer"] as? String ?? "") else { return nil }
            var template = value
            if template["size"] == nil,
               let collision = package.manifest.collisionVolumes.first(where: { $0.id == "collision." + resource.id.replacingOccurrences(of: "prop.", with: "") }) {
                template["size"] = [collision.halfExtents.x * 2, collision.halfExtents.y * 2, collision.halfExtents.z * 2]
            }
            return template
        }
    }
}
