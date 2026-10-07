import Foundation
enum ProductIdentity { static let displayName = "gmgn radio" }

// Asset DTOs only; validation, installation, activation and readback are the
// unchanged production PresencePackageStore compiled alongside this harness.
enum StageAvatarFormat: String, Codable, CaseIterable, Sendable { case vrm, pmx }
struct StageAvatarAsset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let format: StageAvatarFormat
    let modelURL: URL
    let resourceRootURL: URL
}

@main
struct CheckVRMImport {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-vrm-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PresencePackageStore(rootURL: root, builtInVRMs: [])
        let installed = try store.installPackage(from: source)
        guard installed.manifest.engine == .vrm, installed.rendererAvailable else { fatalError("VRM unavailable") }
        try store.activate(id: installed.manifest.id)
        guard let active = try store.activeAvatar(), active.id == installed.manifest.id,
              try Data(contentsOf: active.modelURL) == Data(contentsOf: source) else { fatalError("VRM readback mismatch") }
        print("PASS production PresencePackageStore VRM import, activation and byte-identical readback in isolated temporary root")
    }
}
