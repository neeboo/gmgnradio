import Foundation
import CryptoKit
import WorldRuntime

struct BundledLivingWorldPackage: Sendable { let manifest: WorldManifest; let packageRoot: URL }

@main struct MarbleRuntimeCollisionRegression {
    @MainActor static func main() throws {
        let original = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-marble-runtime-" + UUID().uuidString)
        try FileManager.default.copyItem(at: original, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let manifestURL = temporary.appendingPathComponent("world.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        json["worldID"] = "marble.new-world-collision-fixture"
        json["packageID"] = "marble-generic-collision-fixture"
        let legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.appendingPathComponent("marble.json"))) as! [String: Any]
        let framing = legacy["framing"] as! [String: Any]
        let document = UnityMarbleRuntimeDocument(schemaVersion: 1, worldID: json["worldID"] as! String,
            splatPath: "scene-500k.spz", colliderPath: "collider.glb", colliderAxisConversion: "flipYAndZ",
            origin: (framing["origin"] as! [NSNumber]).map(\.floatValue), uniformScale: (framing["scale"] as! NSNumber).floatValue,
            minimum: (framing["minimum"] as! [NSNumber]).map(\.floatValue), maximum: (framing["maximum"] as! [NSNumber]).map(\.floatValue))
        let metadata = try JSONEncoder().encode(document)
        try metadata.write(to: temporary.appendingPathComponent("marble-runtime.json"))
        var resources = json["resources"] as! [[String: Any]]
        for i in resources.indices {
            if resources[i]["kind"] as? String == "scene.spz" { resources[i]["kind"] = "environment.spz" }
            if resources[i]["kind"] as? String == "collision.glb" { resources[i]["kind"] = "environment.collider" }
        }
        resources.append(["id": "marble.runtime", "path": "marble-runtime.json", "kind": "environment.marble",
            "sha256": SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()])
        json["resources"] = resources
        let manifestData = try JSONSerialization.data(withJSONObject: json)
        try manifestData.write(to: manifestURL)
        let package = BundledLivingWorldPackage(manifest: try JSONDecoder().decode(WorldManifest.self, from: manifestData), packageRoot: temporary)
        precondition(WorldPackageValidator().validate(package.manifest, packageRoot: temporary).isEmpty)
        let loaded = try UnityMarbleRuntimeDocument.load(package: package)
        precondition(loaded == document, "new world consumes its own resource-bound metadata")
        let collision = try UnityMarbleRuntimeCollision.load(package: package)!
        let context = try WorldAgentContext(manifest: package.manifest, initialCollisionWorld: collision)
        precondition(context.state.worldID == document.worldID, "context preserves generic world identity")
        let spawn = package.manifest.spawn.position
        precondition(context.propSupportQuerying?.groundHeight(at: SIMD3(spawn.x, spawn.y + 0.05, spawn.z)) != nil,
            "context uses real Marble floor rather than manifest volumes")
        let restored = try WorldAgentContext(manifest: package.manifest,
            persistence: SnapshotPersistence(state: context.state), initialCollisionWorld: collision)
        precondition(restored.state == context.state, "authority projection reload uses the same package identity and geometry")
        let legacyPackage = BundledLivingWorldPackage(manifest: try JSONDecoder().decode(WorldManifest.self,
            from: Data(contentsOf: original.appendingPathComponent("world.json"))), packageRoot: original)
        let legacyCollision = try UnityMarbleRuntimeCollision.load(package: legacyPackage)
        precondition(legacyCollision == nil, "legacy cabin stays on its established path")
        try Data("corrupt collider".utf8).write(to: temporary.appendingPathComponent("collider.glb"))
        do {
            _ = try UnityMarbleRuntimeCollision.load(package: package)
            preconditionFailure("corrupt mesh must not produce a synthetic collision world")
        } catch {}
        precondition(context.state == restored.state, "failed later package read cannot mutate the loaded state")
        print("PASS: generic Marble resource validation, real collider, context load/reload, legacy isolation, corruption rejection")
    }
    struct SnapshotPersistence: WorldStatePersisting {
        let state: WorldState
        func load() throws -> WorldState? { state }
        func save(_ state: WorldState) throws { throw SaveForbidden.forbidden }
        enum SaveForbidden: Error { case forbidden }
    }
}
