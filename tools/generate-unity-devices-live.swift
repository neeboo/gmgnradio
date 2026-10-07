import Foundation
import CryptoKit

// Attachment DTO used by the production coordinator; no transport/provider substitute.
struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID; let url: URL; let displayName: String
}

@main struct DeviceGenerationLive {
    @MainActor static func main() async throws {
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--wish-tray-v2") else {
            throw NSError(domain: "device-live", code: 64, userInfo: [NSLocalizedDescriptionKey: "Expected helper path and optional --wish-tray-v2"])
        }
        let trayV2 = CommandLine.arguments.count == 3
        let version = trayV2 ? "v2" : "v1"
        let root = repo.appendingPathComponent(trayV2 ? "tmp/device-generation-wish-tray-v2" : "tmp/device-generation-live-v1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let config = try PropGenerationConfigurationStore().load() else {
            throw NSError(domain: "device-live", code: 1, userInfo: [NSLocalizedDescriptionKey: "Product generation configuration is absent"])
        }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let daemon = PropTaskDaemonClient(root: root.appendingPathComponent("TaskService"), helperURL: helper)
        let store = PropGenerationStore(daemonClient: daemon)
        try store.configure(endpoint: config.endpoint, token: config.token)
        let coordinator = WishMachineCoordinator(store: store, directory: root.appendingPathComponent("WishMachine"), canClaim: { _ in nil })
        let world = trayV2 ? "unity-device-generation-wish-tray-v2" : "unity-device-generation-acceptance-v1"
        let scope = "resident.world." + Data(world.utf8).base64EncodedString()
        let devices: [(String, Double, String)] = trayV2 ? [
            ("wish-tray", 0.12, "C514C390-793A-44FC-9E3A-407942DF09C3")
        ] : [
            ("jukebox", 1.2, "C514C390-793A-44FC-9E3A-407942DF09C1"),
            ("wish-machine", 1.1, "C514C390-793A-44FC-9E3A-407942DF09C2")]
        var ids: [(String, UUID)] = []
        for (name, height, stableID) in devices {
            let id = UUID(uuidString: stableID)!
            let image = ResidentImageAttachment(id: id, url: repo.appendingPathComponent("assets/device-designs/\(name)-\(version).png"), displayName: name)
            try coordinator.registerImages([image], worldID: world, residentScope: scope, conversationID: "user-device-design-\(version)")
            try coordinator.authorize(registeredImageIDs: [id], worldID: world, residentScope: scope, conversationID: "user-device-design-\(version)", authorizationID: id,
                source: .init(author: "User-directed imagegen device design", license: "user-authorized-reference"))
            let job = try await coordinator.submit(requestID: "unity-device-design-\(name)-\(version)", authorizationID: id, attachmentID: id,
                name: name, heightMeters: height, sizeIntent: PropSizeIntent(axis: .height, meters: height, source: .suggested), worldID: world, residentScope: scope)
            ids.append((name, job.id))
            print("accepted name=\(name) task=\(job.id) stage=\(job.stage.rawValue)")
        }
        var verified = Set<UUID>()
        for _ in 0..<1440 {
            await store.refreshSnapshot()
            var completed = 0
            for (name, id) in ids {
                if verified.contains(id) { completed += 1; continue }
                guard let record = store.jobs.first(where: { $0.id == id }) else { continue }
                if ["failed", "cancelled", "interrupted"].contains(record.backendStage ?? "") {
                    print("terminal name=\(name) stage=\(record.backendStage ?? "") reason=\(record.receipt?.reason ?? "unknown")")
                    throw NSError(domain: "device-live", code: 2)
                }
                if record.backendStage == "ready", let path = record.localModelPath, let expected = record.receipt?.result?.inspection.sha256 {
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    guard hash == expected else { throw NSError(domain: "device-live", code: 3) }
                    let output = repo.appendingPathComponent("assets/device-designs/\(name)-\(version).glb")
                    if trayV2, FileManager.default.fileExists(atPath: output.path) {
                        let existing = try Data(contentsOf: output)
                        guard SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined() == hash else {
                            throw NSError(domain: "device-live", code: 6, userInfo: [NSLocalizedDescriptionKey: "Existing v2 asset differs; preserved without overwrite"])
                        }
                    }
                    try bytes.write(to: output, options: .atomic)
                    let readback = try Data(contentsOf: output)
                    guard readback.count == bytes.count,
                          SHA256.hash(data: readback).map({ String(format: "%02x", $0) }).joined() == expected else {
                        throw NSError(domain: "device-live", code: 7)
                    }
                    if let collisionPath = record.localCollisionPath, let collisionHash = record.receipt?.result?.collisionSHA256 {
                        let collision = try Data(contentsOf: URL(fileURLWithPath: collisionPath))
                        guard SHA256.hash(data: collision).map({ String(format: "%02x", $0) }).joined() == collisionHash else {
                            throw NSError(domain: "device-live", code: 5)
                        }
                        try collision.write(to: repo.appendingPathComponent("assets/device-designs/\(name)-\(version).collider.glb"), options: .atomic)
                    }
                    try JSONEncoder().encode(record.receipt).write(to: repo.appendingPathComponent("assets/device-designs/\(name)-\(version).receipt.json"), options: .atomic)
                    print("verified name=\(name) sha256=\(hash) bytes=\(bytes.count)")
                    verified.insert(id)
                    completed += 1
                } else { print("pending name=\(name) stage=\(record.backendStage ?? "unknown")") }
            }
            fflush(stdout)
            if completed == ids.count { return }
            try await Task.sleep(for: .seconds(5))
        }
        throw NSError(domain: "device-live", code: 4, userInfo: [NSLocalizedDescriptionKey: "Observation budget exhausted; durable tasks remain, do not resubmit"])
    }
}
