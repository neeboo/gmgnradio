import Foundation
import WorldRuntime

/// Rust owns submission, polling, recovery and registration. Native work consumes one claimed action.
@MainActor final class UnityMarbleWorldBridge: UnityMarbleWorldCommands {
    struct Services: Sendable {
        var http: @Sendable (RustMarbleControlClient.Action) async throws -> RustMarbleControlClient.HTTPFact
        var prepare: @Sendable (RustMarbleControlClient.World) async throws -> String
        static func live(root: URL, geometry: RustMarbleGeometryClient, blobRoot: URL) -> Self {
            let client = MarbleWorldClient(apiKeyProvider: MarbleAPIKeyProvider(fileURL: root.appendingPathComponent("secrets/world-labs-api-key")))
            let cache = MarbleWorldCache(rootURL: root.appendingPathComponent("gmgn radio/MarbleCache", isDirectory: true))
            return Self(http: { action in
                guard let method = action.method, let path = action.path else { throw RustMarbleControlError.invalidResponse }
                let fact = await client.executePlannedHTTP(method: method, path: path, body: try action.bodyData)
                if let status = fact.statusCode, let body = fact.body { return .init(statusCode: status, body: body) }
                return .init(transportErrorCode: fact.transportErrorCode ?? "transport_error")
            }, prepare: { world in
                try await UnityMarblePackageBuilder.prepare(world: try world.nativeWorld(), root: root, cache: cache,
                    geometry: geometry, blobRoot: blobRoot)
            })
        }
    }
    private let root: URL
    private let authority: RustMarbleControlClient
    private let services: Services
    private let runtimeReady: @MainActor () -> Bool
    private let register: @MainActor (BundledLivingWorldPackage) async throws -> Bool
    private let onRegistered: @MainActor (BundledLivingWorldPackage) -> Bool
    private var task: Task<Void, Never>?
    private var taskEpoch: UInt64 = 0
    private var confirmed: RustMarbleControlClient.Snapshot?
    private var lastRegisteredPackage: BundledLivingWorldPackage?
    private var localError: String?
    private var closed = false
    static let supportedCommands = ["space.marble.generate", "space.marble.resume", "space.marble.import", "space.marble.cancel"]

    init(root: URL, authority: RustMarbleControlClient, blobRoot: URL, services: Services? = nil,
         runtimeReady: @escaping @MainActor () -> Bool,
         register: @escaping @MainActor (BundledLivingWorldPackage) async throws -> Bool,
         onRegistered: @escaping @MainActor (BundledLivingWorldPackage) -> Bool) {
        self.root = root; self.authority = authority
        self.services = services ?? .live(root: root, geometry: authority.makeGeometryClient(), blobRoot: blobRoot)
        self.runtimeReady = runtimeReady; self.register = register; self.onRegistered = onRegistered
        // Read-only startup, never an implicit provider submission or resume.
        task = Task { [weak self] in
            guard let self else { return }
            let epoch = self.taskEpoch
            defer { if self.taskEpoch == epoch { self.task = nil } }
            do { self.confirmed = try await authority.read() }
            catch { self.localError = error.localizedDescription }
        }
    }
    var snapshot: [String: Any] {
        let state = confirmed?.task
        return ["generationSupported": runtimeReady(), "marbleWorking": task != nil,
            "marblePhase": state?.phase ?? (localError == nil ? (confirmed == nil ? "loading" : "idle") : "unavailable"),
            "marbleOperationID": state?.operationID as Any? ?? NSNull(),
            "marbleWorldID": state?.worldID as Any? ?? NSNull(),
            "marbleProgress": state?.progress as Any? ?? NSNull(),
            "marbleError": (localError ?? state?.errorMessage ?? state?.errorCode) as Any? ?? NSNull(),
            "marblePresets": SpatialScenePreset.allCases.map { ["id": $0.rawValue, "name": $0.displayName] }]
    }
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String, Self.supportedCommands.contains(op) else { return false }
        if op == "space.marble.cancel" {
            task?.cancel()
            taskEpoch &+= 1
            let epoch = taskEpoch
            task = Task { [weak self] in
                guard let self else { return }
                defer { if self.taskEpoch == epoch { self.task = nil } }
                do {
                    let current = try await authority.read()
                    confirmed = try await authority.command("space.marble.cancel", expectedRevision: current.revision)
                } catch { localError = error.localizedDescription }
            }
            return true
        }
        guard runtimeReady(), task == nil else { return false }
        let preset = value["presetID"] as? String, world = value["worldID"] as? String
        let operation: String
        switch op {
        case "space.marble.generate": guard preset != nil else { return false }; operation = op
        case "space.marble.resume": operation = op
        case "space.marble.import": guard world != nil else { return false }; operation = op
        default: return false
        }
        taskEpoch &+= 1
        let epoch = taskEpoch
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.taskEpoch == epoch { self.task = nil } }
            do { try await run(operation, preset: preset, world: world) }
            catch { localError = error.localizedDescription }
        }
        return true
    }
    func close() { closed = true; taskEpoch &+= 1; task?.cancel(); task = nil }

    func activatePreset(_ preset: SpatialScenePreset) async throws -> BundledLivingWorldPackage {
        guard !closed else { throw CancellationError() }
        guard runtimeReady() else { throw UnityMarbleError.runtimeUnavailable }
        if let existing = task { await existing.value }
        let current = try await authority.read()
        // Joining the same persisted task is read/claim only, never another paid command.
        if let state = current.task, state.presetID == preset.rawValue, ["pending", "inflight"].contains(state.status) {
            try await drain(current)
        } else {
            try await run("activate_preset", preset: preset.rawValue, world: nil)
        }
        guard let package = lastRegisteredPackage else { throw UnityMarbleError.registrationRejected }
        return package
    }
    private func run(_ op: String, preset: String?, world: String?) async throws {
        localError = nil; lastRegisteredPackage = nil
        let current = try await authority.read()
        let value = try await authority.command(op, expectedRevision: current.revision, presetID: preset, worldID: world)
        if op == "activate_preset", let preset, let selected = value.selectedWorldID {
            confirmed = value
            if let package = value.presetPackages[preset], package.worldID == selected {
                try await publish(package); return
            }
            // A catalog world needs native package preparation, not another generation.
            if value.task?.worldID != selected || value.task?.package == nil {
                try await drain(try await authority.command("space.marble.import", expectedRevision: value.revision, worldID: selected))
                return
            }
        }
        try await drain(value)
    }
    private func drain(_ initial: RustMarbleControlClient.Snapshot) async throws {
        var value = initial
        while true {
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            confirmed = value
            guard let state = value.task else { return }
            if state.status == "completed" {
                if let receipt = state.package { try await publish(receipt) }
                return
            }
            guard state.status == "pending" else {
                throw UnityMarbleError.operationFailed(state.errorMessage ?? state.errorCode ?? state.status)
            }
            let claimed = try await authority.claim(taskID: state.taskID, expectedRevision: value.revision)
            confirmed = claimed
            guard let action = claimed.action else {
                if let wait = claimed.waitMS, wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
                value = try await authority.read(); continue
            }
            // Receipt failure leaves the action unknown/inflight. Never execute it again locally.
            if action.kind == "prepare_package" {
                guard let world = action.world else { throw RustMarbleControlError.invalidResponse }
                let hash: String
                do { hash = try await services.prepare(world) }
                catch {
                    value = try await authority.receipt(action, fact: RustMarbleControlClient.PackageFailureFact(
                        preparationErrorCode: error is CancellationError ? "native_cancelled" : "native_preparation_failed"))
                    continue
                }
                value = try await authority.receipt(action, fact: RustMarbleControlClient.PackageFact(manifestSHA256: hash))
            } else {
                let fact = try await services.http(action)
                value = try await authority.receipt(action, fact: fact)
            }
        }
    }
    private func publish(_ receipt: RustMarbleControlClient.Package) async throws {
        let directory = UnityMarblePackageBuilder.packageRoot(root: root, worldID: receipt.worldID)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("world.json"))
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: bytes)
        guard manifest.worldID == receipt.worldID, manifest.packageID == receipt.packageID,
            manifest.packageVersion == receipt.packageVersion,
            UnityMarblePackageBuilder.digest(bytes) == receipt.manifestSHA256 else { throw UnityMarbleError.packageConflict }
        let package = BundledLivingWorldPackage(manifest: manifest, packageRoot: directory)
        guard try await register(package) else { throw UnityMarbleError.registrationRejected }
        // A discovery projection only; authoritative registration already committed in Rust.
        try Data(receipt.manifestSHA256.utf8).write(to: directory.appendingPathComponent("registered.sha256"), options: .atomic)
        guard onRegistered(package) else { throw UnityMarbleError.registrationRejected }
        lastRegisteredPackage = package
    }
}
