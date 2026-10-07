import CryptoKit
import Foundation
import SplatIO
import WorldRuntime

enum UnityMarbleError: LocalizedError {
    case identityMissing, assetMissing, invalidGeometry, invalidPackage, registrationRejected, packageConflict
    case busy, runtimeUnavailable, selectionRejected, selectionTimedOut
    case operationFailed(String)
    var errorDescription: String? {
        switch self {
        case .identityMissing: "Marble 操作没有返回确切的空间编号。"
        case .assetMissing: "Marble 空间缺少 SPZ 或碰撞资源。"
        case .invalidGeometry: "Marble 资源无法解码，或找不到可安全站立的位置。"
        case .invalidPackage: "Marble 正式空间包校验失败。"
        case .registrationRejected: "空间权威注册未通过读回验证。"
        case .packageConflict: "已有同编号的不同空间包，未覆盖原空间。"
        case .busy: "另一个 Marble 操作仍在处理中，请先处理该操作。"
        case .runtimeUnavailable: "当前 Unity 渲染器尚未确认 Marble 空间支持。"
        case .selectionRejected: "空间载入未通过实际运行回执，原空间已保留。"
        case .selectionTimedOut: "等待空间载入回执超时，尚未确认切换完成。"
        case let .operationFailed(message): message
        }
    }
}

/// Explicit commands only. Construction/restart never submits a generation.
/// Registered markers are written only after the host confirms authority readback.
@MainActor final class UnityMarbleWorldBridge: UnityMarbleWorldCommands {
    struct Services: Sendable {
        var generate: @Sendable (SpatialScenePreset) async throws -> MarbleOperation
        var operation: @Sendable (String) async throws -> MarbleOperation
        var world: @Sendable (String) async throws -> MarbleWorld
        var splat: @Sendable (MarbleWorld, MarbleSplatAsset) async throws -> URL
        var collider: @Sendable (MarbleWorld) async throws -> URL?
        var sleep: @Sendable () async throws -> Void
        static func live(root: URL) -> Self {
            let client = MarbleWorldClient(apiKeyProvider: MarbleAPIKeyProvider(fileURL: root.appendingPathComponent("secrets/world-labs-api-key")))
            let cache = MarbleWorldCache(rootURL: root.appendingPathComponent("gmgn radio/MarbleCache", isDirectory: true))
            return Self(generate: { try await client.generateWorld(preset: $0) }, operation: { try await client.operation(id: $0) },
                world: { try await client.world(id: $0) }, splat: { try await cache.localSplat(for: $0, asset: $1) },
                collider: { try await cache.localCollider(for: $0) }, sleep: { try await Task.sleep(for: .seconds(3)) })
        }
    }
    private struct OperationReceipt: Codable {
        let operationID: String
        let presetID: String
    }
    private struct PresetReceipt: Codable {
        let worldID: String
        let manifestSHA256: String
    }
    private let root: URL
    private let services: Services
    private let runtimeReady: @MainActor () -> Bool
    private let register: @MainActor (BundledLivingWorldPackage) async throws -> Bool
    private let onRegistered: @MainActor (BundledLivingWorldPackage) -> Bool
    private var task: Task<Void, Never>?
    private var lease: UInt64 = 0
    private var phase = "idle"
    private var operationID: String?
    private var activePresetID: String?
    private var lastRegisteredPackage: BundledLivingWorldPackage?
    private var worldID: String?
    private var errorMessage: String?
    private var progress: Int?
    private var closed = false
    private var receiptURL: URL { root.appendingPathComponent("gmgn radio/MarbleOperations/pending.json") }
    static let supportedCommands = ["space.marble.generate", "space.marble.resume", "space.marble.import", "space.marble.cancel"]

    init(root: URL, services: Services? = nil,
         runtimeReady: @escaping @MainActor () -> Bool,
         register: @escaping @MainActor (BundledLivingWorldPackage) async throws -> Bool,
         onRegistered: @escaping @MainActor (BundledLivingWorldPackage) -> Bool) {
        self.root = root; self.services = services ?? .live(root: root)
        self.runtimeReady = runtimeReady; self.register = register; self.onRegistered = onRegistered
        if let data = try? Data(contentsOf: receiptURL), let receipt = try? JSONDecoder().decode(OperationReceipt.self, from: data) {
            operationID = receipt.operationID; phase = "resume_available"
            activePresetID = receipt.presetID
        }
    }
    var snapshot: [String: Any] {
        ["generationSupported": runtimeReady(), "marbleWorking": task != nil, "marblePhase": phase,
         "marbleOperationID": operationID as Any? ?? NSNull(), "marbleWorldID": worldID as Any? ?? NSNull(),
         "marbleProgress": progress as Any? ?? NSNull(), "marbleError": errorMessage as Any? ?? NSNull(),
         "marblePresets": SpatialScenePreset.allCases.map { ["id": $0.rawValue, "name": $0.displayName] }]
    }
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        if op == "space.marble.cancel" {
            guard task != nil else { return false }
            task?.cancel(); phase = operationID == nil ? "cancelled" : "cancelled_remote_operation_may_continue"
            return true
        }
        guard runtimeReady(), task == nil else { return false }
        switch op {
        case "space.marble.generate":
            // A pending remote operation must be resumed/cancelled explicitly;
            // never create a second paid operation during recovery.
            guard operationID == nil, let id = value["presetID"] as? String, let preset = SpatialScenePreset(rawValue: id) else { return false }
            activePresetID = id
            begin { [self] in
                phase = "generating"
                let operation = try await services.generate(preset)
                operationID = operation.id
                try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(OperationReceipt(operationID: operation.id, presetID: id)).write(to: receiptURL, options: .atomic)
                try Task.checkCancellation()
                try await finish(operation)
            }
        case "space.marble.resume":
            guard let operationID else { return false }
            begin { [self] in try await finish(services.operation(operationID)) }
        case "space.marble.import":
            guard let id = value["worldID"] as? String, !id.isEmpty else { return false }
            activePresetID = nil
            begin { [self] in
                let world = try await services.world(id)
                guard world.id == id else { throw UnityMarbleError.identityMissing }
                try await adopt(world)
            }
        default: return false
        }
        return true
    }
    func close() { closed = true; lease &+= 1; task?.cancel(); task = nil }
    /// Foreground scene requests share their exact pending operation. A successful
    /// generated preset has a manifest-bound receipt, so reactivation is free of
    /// new generation calls and still revalidates every formal resource.
    func activatePreset(_ preset: SpatialScenePreset) async throws -> BundledLivingWorldPackage {
        guard !closed else { throw CancellationError() }
        guard runtimeReady() else { throw UnityMarbleError.runtimeUnavailable }
        if let package = try packageForPreset(preset) {
            guard onRegistered(package) else { throw UnityMarbleError.registrationRejected }
            return package
        }
        if task != nil {
            guard activePresetID == preset.rawValue else { throw UnityMarbleError.busy }
        } else if operationID != nil {
            guard activePresetID == preset.rawValue, command(["op": "space.marble.resume"]) else { throw UnityMarbleError.busy }
        } else {
            guard command(["op": "space.marble.generate", "presetID": preset.rawValue]) else { throw UnityMarbleError.busy }
        }
        guard let pending = task else { throw UnityMarbleError.registrationRejected }
        let currentLease = lease
        await withTaskCancellationHandler {
            await pending.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.lease == currentLease else { return }
                self.task?.cancel()
            }
        }
        try Task.checkCancellation()
        guard !closed, lease == currentLease, phase == "registered", let package = lastRegisteredPackage else {
            if phase.hasPrefix("cancelled") { throw CancellationError() }
            if let errorMessage { throw UnityMarbleError.operationFailed(errorMessage) }
            throw UnityMarbleError.registrationRejected
        }
        return package
    }
    private func begin(_ action: @escaping @MainActor () async throws -> Void) {
        lease &+= 1; let current = lease; errorMessage = nil; progress = nil
        lastRegisteredPackage = nil
        task = Task { [weak self] in
            do {
                try await action(); try Task.checkCancellation()
                guard let self, !closed, lease == current else { return }
                phase = "registered"; task = nil
            } catch is CancellationError {
                guard let self, !closed, lease == current else { return }
                phase = operationID == nil ? "cancelled" : "cancelled_remote_operation_may_continue"; task = nil
            } catch {
                guard let self, !closed, lease == current else { return }
                if case let MarbleWorldClientError.rejected(statusCode, _) = error {
                    errorMessage = "Marble 请求失败（\(statusCode)）。"
                } else { errorMessage = error.localizedDescription }
                phase = "failed"; task = nil
            }
        }
    }
    private func finish(_ initial: MarbleOperation) async throws {
        var operation = initial
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let error = operation.errorMessage { throw MarbleWorldClientError.generationFailed(error) }
            if operation.isDone { break }
            phase = "generating"; progress = operation.progressPercentage
            try await services.sleep(); try Task.checkCancellation()
            let next = try await services.operation(operation.id)
            guard next.id == operation.id else { throw UnityMarbleError.identityMissing }
            operation = next
        }
        guard operation.isDone else { throw MarbleWorldClientError.generationTimedOut }
        guard let id = operation.worldID, !id.isEmpty else { throw UnityMarbleError.identityMissing }
        let world = try await services.world(id)
        guard world.id == id else { throw UnityMarbleError.identityMissing }
        try await adopt(world)
        if let activePresetID, let package = lastRegisteredPackage {
            let receipt = PresetReceipt(worldID: world.id, manifestSHA256: try digestManifest(package))
            let url = presetReceiptURL(activePresetID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        }
        // Receipt retirement follows registration, never merely generation done.
        if FileManager.default.fileExists(atPath: receiptURL.path) { try FileManager.default.removeItem(at: receiptURL) }
        operationID = nil
    }
    private func adopt(_ world: MarbleWorld) async throws {
        guard let asset = world.preferredSplat, world.colliderURL != nil else { throw UnityMarbleError.assetMissing }
        try Task.checkCancellation(); worldID = world.id; phase = "downloading"
        let splat = try await services.splat(world, asset)
        guard let collider = try await services.collider(world) else { throw UnityMarbleError.assetMissing }
        try Task.checkCancellation(); phase = "validating"
        let package = try await UnityMarblePackageBuilder.publish(world: world, splat: splat, collider: collider, root: root)
        try Task.checkCancellation(); phase = "registering"
        guard try await register(package) else { throw UnityMarbleError.registrationRejected }
        try Task.checkCancellation()
        // Store manifest digest rather than an unchecked boolean registration.
        let manifestData = try Data(contentsOf: package.packageRoot.appendingPathComponent("world.json"))
        try Data(UnityMarblePackageBuilder.digest(manifestData).utf8).write(to: package.packageRoot.appendingPathComponent("registered.sha256"), options: .atomic)
        guard onRegistered(package) else { throw UnityMarbleError.registrationRejected }
        lastRegisteredPackage = package
    }
    private func presetReceiptURL(_ id: String) -> URL {
        root.appendingPathComponent("gmgn radio/MarbleOperations/Presets", isDirectory: true).appendingPathComponent(id + ".json")
    }
    private func digestManifest(_ package: BundledLivingWorldPackage) throws -> String {
        UnityMarblePackageBuilder.digest(try Data(contentsOf: package.packageRoot.appendingPathComponent("world.json")))
    }
    private func packageForPreset(_ preset: SpatialScenePreset) throws -> BundledLivingWorldPackage? {
        let url = presetReceiptURL(preset.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try JSONDecoder().decode(PresetReceipt.self, from: Data(contentsOf: url))
        let packageRoot = UnityMarblePackageBuilder.packageRoot(root: root, worldID: receipt.worldID)
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("world.json"))
        guard UnityMarblePackageBuilder.digest(data) == receipt.manifestSHA256,
              UnityMarblePackageBuilder.registeredRoots(root: root).contains(packageRoot) else { throw UnityMarbleError.invalidPackage }
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: data)
        guard manifest.worldID == receipt.worldID else { throw UnityMarbleError.identityMissing }
        return BundledLivingWorldPackage(manifest: manifest, packageRoot: packageRoot)
    }
}

enum UnityMarblePackageBuilder {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func packageRoot(root: URL, worldID: String) -> URL {
        root.appendingPathComponent("gmgn radio/WorldPackages", isDirectory: true).appendingPathComponent(digest(Data(worldID.utf8)), isDirectory: true)
    }
    static func registeredRoots(root: URL) -> [URL] {
        let parent = root.appendingPathComponent("gmgn radio/WorldPackages", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []).filter { url in
            guard url.standardizedFileURL == url.resolvingSymlinksInPath(),
                  let data = try? Data(contentsOf: url.appendingPathComponent("world.json")),
                  let marker = try? String(contentsOf: url.appendingPathComponent("registered.sha256"), encoding: .utf8),
                  marker == digest(data), let manifest = try? JSONDecoder().decode(WorldManifest.self, from: data),
                  WorldPackageValidator().validate(manifest, packageRoot: url).isEmpty else { return false }
            return (try? UnityMarbleRuntimeDocument.load(package: BundledLivingWorldPackage(manifest: manifest, packageRoot: url))) != nil
        }
    }
    static func publish(world: MarbleWorld, splat: URL, collider: URL, root: URL) async throws -> BundledLivingWorldPackage {
        try UnityMarbleSPZFormat.requireRuntimeSupported(splat)
        let points = try await SPZSceneReader(splat).readAll()
        try Task.checkCancellation()
        guard !points.isEmpty, points.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }) else { throw UnityMarbleError.invalidGeometry }
        let strideSize = max(points.count / 40_000, 1)
        let positions: [SIMD3<Float>] = stride(from: 0, to: points.count, by: strideSize).map { index in points[index].position }
        let framing = MarbleSceneFraming(positions: positions)
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: collider), transform: framing.colliderTransform(sourceCoordinates: world.colliderSourceCoordinates))
        let collision = TriangleMeshCollisionWorld(triangles: triangles)
        let capsule = WorldCapsule(radius: 0.2, height: 1.8)
        let centroids: [SIMD3<Float>] = triangles.map { triangle in (triangle.first + triangle.second + triangle.third) / Float(3) }
        let candidates = centroids.sorted { first, second in
            let firstDistance: Float = first.x * first.x + first.z * first.z
            let secondDistance: Float = second.x * second.x + second.z * second.z
            return firstDistance < secondDistance
        }
        guard let spawn = candidates.first(where: { candidate in
            guard let ground = collision.groundHeight(at: candidate), abs(ground - candidate.y) < 0.05 else { return false }
            return collision.canOccupy(capsule, at: candidate)
        }) else { throw UnityMarbleError.invalidGeometry }
        let origin = framing.groundedOrigin
        let minimum = framing.normalizedMinimum / framing.uniformScale + origin
        let maximum = framing.normalizedMaximum / framing.uniformScale + origin
        let document = UnityMarbleRuntimeDocument(schemaVersion: 1, worldID: world.id, splatPath: "scene.spz", colliderPath: "collider.glb",
            colliderAxisConversion: world.colliderSourceCoordinates == .glTF ? "identity" : "flipYAndZ",
            origin: [origin.x, origin.y, origin.z], uniformScale: framing.uniformScale,
            minimum: [minimum.x, minimum.y, minimum.z], maximum: [maximum.x, maximum.y, maximum.z])
        let destination = packageRoot(root: root, worldID: world.id)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: splat, to: stage.appendingPathComponent("scene.spz"))
        try FileManager.default.copyItem(at: collider, to: stage.appendingPathComponent("collider.glb"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: stage.appendingPathComponent("marble-runtime.json"), options: .atomic)
        let rotation = WorldQuaternion(x: 0, y: 0, z: 0, w: 1), scale = WorldVector3(x: 1, y: 1, z: 1)
        let transform = WorldTransform(position: WorldVector3(x: spawn.x, y: spawn.y, z: spawn.z), rotation: rotation, scale: scale)
        let camera = WorldTransform(position: WorldVector3(x: spawn.x, y: spawn.y + 1.5, z: spawn.z), rotation: rotation, scale: scale)
        let resources = try [("environment.spz", "scene.spz"), ("environment.collider", "collider.glb"), ("environment.marble", "marble-runtime.json")].map { kind, path in
            WorldResource(id: kind, path: path, sha256: digest(try Data(contentsOf: stage.appendingPathComponent(path))), kind: kind)
        }
        let manifest = WorldManifest(schemaVersion: 1, packageID: "marble-" + digest(Data(world.id.utf8)), packageVersion: "1.0.0", worldID: world.id,
            displayName: world.name, calibration: WorldCalibration(visualToGameplay: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1], metersPerUnit: 1),
            spawn: transform, collisionVolumes: [], waypoints: [WorldWaypoint(id: "wp.spawn", position: transform.position, arrivalRadius: 0.2, enabled: true)],
            routes: [], activities: [], cameras: [WorldCameraAnchor(id: "camera.home", transform: camera, fieldOfViewDegrees: 60, nearPlane: 0.01, farPlane: 100)],
            capabilities: [], resources: resources)
        guard WorldPackageValidator().validate(manifest, packageRoot: stage).isEmpty else { throw UnityMarbleError.invalidPackage }
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stage.appendingPathComponent("world.json"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination.appendingPathComponent("world.json")) == manifestData,
                  WorldPackageValidator().validate(manifest, packageRoot: destination).isEmpty else { throw UnityMarbleError.packageConflict }
        } else { try FileManager.default.moveItem(at: stage, to: destination) }
        return BundledLivingWorldPackage(manifest: manifest, packageRoot: destination)
    }
}
