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
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let environment = ProcessInfo.processInfo.environment
        guard environment["GMGN_TEST_ENABLE_VRM_IMPORT"] == "1",
              let binary = environment["GMGN_TASKD_TEST_BINARY"],
              FileManager.default.isExecutableFile(atPath: binary) else { exit(78) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("gmgn-vrm-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = root.appendingPathComponent("TaskService")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        let child = Process(); child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = ["--root", service.path, "--endpoint-file", service.appendingPathComponent("taskd.endpoint.json").path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: service.appendingPathComponent("taskd.endpoint.json").path) { break }
            guard child.isRunning else { throw RustPresenceSelectionClient.SelectionError.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
        let client = RustPresenceSelectionClient(scope: root.path, serviceRoot: service)
        let store = PresencePackageStore(rootURL: root.appendingPathComponent("PresencePackages"), builtInVRMs: [], selectionAuthority: client)
        let installed = try store.installPackage(from: source)
        guard installed.manifest.engine == .vrm else { fatalError("VRM unavailable") }
        // Controlled renderer leaf only. Rust still validates the installed file,
        // owns selection and accepts the raw renderer ACK through the real RPC.
        let packages = try store.listPackages().map { package in
            PresencePackage(manifest: package.manifest, installPath: package.installPath,
                thumbnailPath: package.thumbnailPath, isActive: package.isActive,
                isBuiltIn: package.isBuiltIn, rendererAvailable: true)
        }
        let idle = StageMotionAsset(id: "builtin.motion.natural-idle", name: "Idle", format: .procedural, url: nil)
        _ = try await client.bind(packages: packages, motions: [idle], packageRoot: store.rootURL,
            motionRoot: root.appendingPathComponent("MotionPackages"), policy: "unity",
            supportedEngines: ["orb", "vrm"], builtInMotionIDs: [idle.id])
        try await store.activateAsync(id: installed.manifest.id)
        if client.confirmed?.pendingRenderer == true { _ = try await client.event("renderer_ack", success: true) }
        guard let active = try store.activeAvatar(), active.id == installed.manifest.id,
              try Data(contentsOf: active.modelURL) == Data(contentsOf: source) else { fatalError("VRM readback mismatch") }
        print("PASS production PresencePackageStore VRM import, activation and byte-identical readback in isolated temporary root")
    }
}
