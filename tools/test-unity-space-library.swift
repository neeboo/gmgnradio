import Foundation
import WorldRuntime

// The bridge depends only on these value shapes; WorldPackageValidator below is real.
struct BundledLivingWorldPackage: Sendable { let manifest: WorldManifest; let packageRoot: URL }
struct MarbleWorld: Sendable { let id: String; let name: String }

@main struct SpaceLibraryRegression {
    @MainActor static func main() throws {
        let name = "unity-space-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let keyRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let productKeys = TestProductKeys(root: keyRoot)
        precondition(productKeys.command(["op":"space.key.save", "apiKey":"isolated-product-value"]))
        precondition(productKeys.snapshot["credentialConfigured"] as? Bool == true)
        precondition(productKeys.snapshot["marbleMutationRevision"] as? UInt64 == 1)
        precondition(!productKeys.command(["op":"space.key.save", "apiKey":" "]))
        precondition(productKeys.snapshot["marbleMutationRevision"] as? UInt64 == 1, "failed saves must not clear the pending UI draft")
        precondition(productKeys.command(["op":"space.key.clear"]))
        precondition(productKeys.snapshot["credentialConfigured"] as? Bool == false)
        let keyProvider = MarbleAPIKeyProvider(fileURL: keyRoot.appendingPathComponent("secrets/world-labs-api-key"))
        let keyModel = MarbleAPIKeySettingsModel(provider: keyProvider)
        precondition(!keyModel.isConfigured)
        keyModel.replacementKey = "  isolated-test-value  "
        keyModel.save()
        precondition(keyModel.isConfigured && !keyModel.hasError && keyModel.replacementKey.isEmpty)
        let savedKey = try keyProvider.read()
        precondition(savedKey == "isolated-test-value")
        let permissions = try FileManager.default.attributesOfItem(atPath: keyProvider.fileURL.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        keyModel.replacementKey = " "
        keyModel.save()
        precondition(keyModel.hasError && keyModel.isConfigured)
        let retainedKey = try keyProvider.read()
        precondition(retainedKey == "isolated-test-value")
        keyModel.clear(); precondition(!keyModel.isConfigured && !keyProvider.isConfigured)
        var current: String?
        var requested: (BundledLivingWorldPackage, UInt64)?
        let bridge = UnitySpaceLibraryBridge(registeredPackageRoots: [root], defaults: defaults,
            selectedWorldID: { current }, requestSelection: { package, revision in requested = (package, revision); return true }, livingPodWorldID: "bundled-cabin")
        precondition(bridge.startupSelectionIDs() == ["bundled-cabin"])
        precondition(bridge.defaultSpaceSnapshot["defaultSpace"] as? String == "living-pod")
        precondition(!bridge.settingsCommand(["op":"space.default", "value":"unknown"]))
        let worlds = bridge.snapshot["worlds"] as! [[String: Any]]
        precondition(worlds.count == 1, "real package must validate")
        let id = worlds[0]["id"] as! String
        precondition(bridge.settingsCommand(["op":"space.library.select", "id":id]))
        precondition(bridge.savedSelectionID == nil, "request acceptance must not persist")
        precondition(!bridge.completeSelection(revision: requested!.1 + 1, worldID: id, success: true))
        precondition(!bridge.completeSelection(revision: requested!.1, worldID: id, success: true), "actual session readback must match")
        precondition(bridge.savedSelectionID == nil)
        precondition(bridge.settingsCommand(["op":"space.library.select", "id":id]))
        current = id
        precondition(bridge.completeSelection(revision: requested!.1, worldID: id, success: true))
        precondition(bridge.savedSelectionID == id)
        precondition(defaults.string(forKey: "marble.selected-world-id") == id)
        precondition(bridge.startupSelectionIDs() == ["bundled-cabin"], "explicit cabin preference must beat last selected world")
        precondition(bridge.settingsCommand(["op":"space.default", "value":"last-marble-world"]))
        precondition(bridge.startupSelectionIDs().first == id)
        let reopened = UnitySpaceLibraryBridge(registeredPackageRoots: [root], defaults: defaults,
            selectedWorldID: { current }, requestSelection: { _, _ in true }, livingPodWorldID: "bundled-cabin")
        precondition(reopened.defaultSpaceSnapshot["defaultSpace"] as? String == "last-marble-world")
        precondition(reopened.startupSelectionIDs().first == id)
        reopened.close()
        let inheritedName = "unity-space-inherit-" + UUID().uuidString
        let inheritedDefaults = UserDefaults(suiteName: inheritedName)!
        defer { inheritedDefaults.removePersistentDomain(forName: inheritedName) }
        let inherited = UnitySpaceLibraryBridge(registeredPackageRoots: [root], defaults: inheritedDefaults,
            selectedWorldID: { current }, requestSelection: { _, _ in true }, productDefaults: defaults, livingPodWorldID: "bundled-cabin")
        precondition(inherited.defaultSpaceSnapshot["defaultSpace"] as? String == "last-marble-world")
        precondition(inherited.startupSelectionIDs() == [id])
        precondition(inherited.settingsCommand(["op":"space.default", "value":"living-pod"]))
        precondition(inherited.startupSelectionIDs() == ["bundled-cabin"])
        precondition(defaults.string(forKey: DefaultSpacePreference.defaultsKey) == "last-marble-world", "Unity must not modify product preferences")
        inherited.close()
        let invalid = UnitySpaceLibraryBridge(registeredPackageRoots: [root.appendingPathComponent("missing")], defaults: defaults,
            selectedWorldID: { current }, requestSelection: { _, _ in preconditionFailure("invalid package dispatched") })
        precondition((invalid.snapshot["worlds"] as! [[String: Any]]).isEmpty)
        precondition(!invalid.settingsCommand(["op":"space.library.select", "id":id]))
        bridge.close(); precondition(!bridge.settingsCommand(["op":"space.library.load"]))
        print("Unity spaces: actual package validation, request/ack isolation, stale receipt, session readback, persisted default selection and isolated API key save/read/clear passed; no UI/authority/external calls")
    }
}
