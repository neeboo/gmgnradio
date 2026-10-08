import Foundation
import CryptoKit
import WorldRuntime

/// Presentation and orchestration over the existing wish coordinator and Rust
/// task service. No new job/ownership archive and no implicit submission/claim.
@MainActor final class UnityWishMachineBridge {
    typealias InventoryRegistration = @MainActor (WishMachineJob) async throws -> WorldGeneratedProp
    private let coordinator: WishMachineCoordinator
    private let worldID: String
    private let residentScope: String
    private let registerInventory: InventoryRegistration
    private let inventoryReadback: @MainActor (String) async throws -> WorldGeneratedProp?
    private var work: Task<Void, Never>?
    private var closed = false
    private var generation: UInt64 = 0
    private var emittedGeneration: UInt64?
    private var response: [String: Any] = ["status": "idle"]
    private var confirmedInventory: [String: WorldGeneratedProp] = [:]
    /// Main host refreshes world.snapshot only after this callback. A claimed
    /// job, accepted command or commit receipt alone never triggers success.
    var onInventoryConfirmed: (@MainActor (String) -> Void)?
    var onStateChanged: (@MainActor () -> Void)?

    init(coordinator: WishMachineCoordinator, worldID: String, residentScope: String,
         registerInventory: @escaping InventoryRegistration,
         inventoryReadback: @escaping @MainActor (String) async throws -> WorldGeneratedProp?) {
        self.coordinator = coordinator; self.worldID = worldID; self.residentScope = residentScope
        self.registerInventory = registerInventory; self.inventoryReadback = inventoryReadback
    }

    /// Preserve the official schemas, validation, grant, scope and call identity.
    /// A lease owner must construct ResidentWishMachineTools for that human turn;
    /// this bridge never invents an authorization or synthetic arrival evidence.
    func tools(for lease: ResidentWishMachineTools) -> [ResidentWorldToolSession.AdditionalTool] {
        lease.tools.map { tool in
            .init(name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
                  validate: tool.validate, handle: { [weak self] callID, arguments in
                let result = await tool.handle(callID, arguments)
                guard let self, !result.isError, !self.closed else { return result }
                if tool.name == "claim_wish_output",
                   let input = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any],
                   let id = (input["wish_id"] as? String).flatMap(UUID.init(uuidString:)) {
                    do {
                        let job = try self.coordinator.read(id: id, worldID: self.worldID, residentScope: self.residentScope)
                        try await self.confirmInventory(job)
                    } catch {
                        return Self.failure(callID: callID, code: "inventory_not_confirmed",
                            message: "已经领取，入库尚未确认。请重试入库，无需重新生成或领取。")
                    }
                }
                self.generation &+= 1
                self.onStateChanged?()
                return result
            })
        }
    }

    /// UI can read, explicitly claim, retry the original task or retry inventory.
    /// Generation is through the official per-human-turn tool lease above.
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, work == nil, let operation = value["op"] as? String,
              ["wish.status", "wish.claim", "wish.retry", "wish.inventory.retry"].contains(operation),
              let requestID = value["requestID"] as? String, !requestID.isEmpty, requestID.utf8.count <= 256 else { return false }
        work = Task { [weak self] in
            guard let self else { return }
            var reply: [String: Any] = ["operation": operation, "requestID": requestID]
            do {
                try Task.checkCancellation()
                guard !worldID.isEmpty, !residentScope.isEmpty else { throw WishMachineError.wrongScope }
                if operation == "wish.status" {
                    // Read/refresh never submits a new request or consumes a grant.
                    for job in coordinator.residentJobs(worldID: worldID, residentScope: residentScope)
                        .filter({ $0.stage != .claimed }).prefix(2) {
                        _ = try await coordinator.refresh(id: job.id, worldID: worldID, residentScope: residentScope)
                    }
                    for job in coordinator.residentJobs(worldID: worldID, residentScope: residentScope) where job.stage == .claimed {
                        if let prop = try await inventoryReadback(job.objectID), prop.objectID == job.objectID,
                           prop.sourceWishID == job.id.uuidString {
                            try Task.checkCancellation()
                            guard !closed else { throw CancellationError() }
                            confirmedInventory[job.objectID] = prop
                            onInventoryConfirmed?(job.objectID)
                        } else {
                            confirmedInventory.removeValue(forKey: job.objectID)
                        }
                    }
                } else {
                    guard let id = (value["wishID"] as? String).flatMap(UUID.init(uuidString:)) else { throw WishMachineError.wrongScope }
                    var job = try coordinator.read(id: id, worldID: worldID, residentScope: residentScope)
                    if operation == "wish.retry" {
                        job = try await coordinator.retry(id: id, worldID: worldID, residentScope: residentScope)
                    } else {
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        if operation == "wish.claim" { job = try await coordinator.claim(id: id, worldID: worldID, residentScope: residentScope) }
                        try await confirmInventory(job)
                    }
                    reply["wishID"] = job.id.uuidString; reply["objectID"] = job.objectID
                }
                try Task.checkCancellation()
                reply["status"] = "completed"
            } catch {
                reply["status"] = "failed"
                reply["code"] = "wish_not_confirmed"
                reply["message"] = error is CancellationError ? "操作已停止。" : error.localizedDescription
            }
            guard !closed else { return }
            response = reply; generation &+= 1; work = nil
            onStateChanged?()
        }
        return true
    }

    private func confirmInventory(_ job: WishMachineJob) async throws {
        guard job.worldID == worldID, job.residentScope == residentScope, job.stage == .claimed else { throw WishMachineError.notReady }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let existing = try await inventoryReadback(job.objectID) {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard existing.sourceWishID == job.id.uuidString else { throw WishMachineError.conflictingCall }
            confirmedInventory[job.objectID] = existing
            onInventoryConfirmed?(job.objectID)
            return
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let registered = try await registerInventory(job)
        try Task.checkCancellation()
        guard let durable = try await inventoryReadback(job.objectID), durable == registered,
              durable.objectID == job.objectID, durable.sourceWishID == job.id.uuidString else { throw WishMachineError.unavailable }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        confirmedInventory[job.objectID] = durable
        onInventoryConfirmed?(job.objectID)
    }

    func snapshot() -> [String: Any] {
        var output: [String: Any] = ["generation": generation, "pending": work != nil]
        guard emittedGeneration != generation else { return output }
        emittedGeneration = generation
        output.merge(response) { _, value in value }
        output["entries"] = coordinator.residentJobs(worldID: worldID, residentScope: residentScope).map { job in
            let available: Bool
            if case .success = coordinator.claimAvailability(id: job.id, worldID: worldID, residentScope: residentScope) { available = true } else { available = false }
            return ["wishID": job.id.uuidString, "objectID": job.objectID, "name": job.name,
                    "stage": job.stage.rawValue, "claimAvailable": available,
                    "inventoryRegistered": confirmedInventory[job.objectID] != nil] as [String: Any]
        }
        return output
    }
    func close() { closed = true; work?.cancel(); work = nil }
    private static func failure(callID: String, code: String, message: String) -> RealtimeDJToolResult {
        .init(callID: callID, resultJSON: (try? JSONSerialization.data(withJSONObject:
            ["ok": false, "code": code, "message": message])) ?? Data(), isError: true)
    }
}

/// Native imports verified raw GLB bytes and triangles. Rust reads the claimed
/// wish in its real store and owns measurement, orientation and registration.
@MainActor final class UnityWishInventoryRegistrar {
    private let store: PropGenerationStore
    private let authority: RustWorldPropClient
    private let identity: RustWorldPropClient.Identity
    private let sample: @Sendable (URL) async throws -> RustPropNativeMeshSampler.Sample
    convenience init(root: URL, worldID: String, residentScope: String, hostSessionID: String, store: PropGenerationStore) {
        self.init(root: root, identity: .init(worldID: worldID, residentScope: residentScope, hostSessionID: hostSessionID),
            store: store, sample: { try await RustPropNativeMeshSampler.sample(modelURL: $0) })
    }
    init(root: URL, identity: RustWorldPropClient.Identity, store: PropGenerationStore,
         sample: @escaping @Sendable (URL) async throws -> RustPropNativeMeshSampler.Sample) {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        authority = RustWorldPropClient(endpointFile: URL(fileURLWithPath: endpoint.endpointFile))
        self.identity = identity; self.store = store; self.sample = sample
    }
    private struct Snapshot: Decodable {
        struct Record: Decodable { let state: WorldState; let recordRevision: UInt64 }
        let record: Record
    }
    private func snapshot() async throws -> Snapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let result = try decoder.decode(Snapshot.self, from: await authority.snapshot(identity))
        guard result.record.state.worldID == identity.worldID else { throw RustWorldPropError.invalidResponse }
        return result
    }
    func readback(objectID: String) async throws -> WorldGeneratedProp? {
        try await snapshot().record.state.objectStates[objectID]?.generatedProp
    }
    func register(_ job: WishMachineJob) async throws -> WorldGeneratedProp {
        guard job.stage == .claimed, job.worldID == identity.worldID, job.residentScope == identity.residentScope,
              let record = store.jobs.first(where: { $0.id == job.jobID }),
              let receipt = record.receipt, receipt.state == .completed,
              let inspection = receipt.result?.inspection, let path = record.localModelPath,
              path == job.modelPath, inspection.sha256.count == 64,
              inspection.sha256.allSatisfy(\.isHexDigit), inspection.bytes > 0,
              inspection.bytes <= 32 * 1024 * 1024 else { throw WishMachineError.notReady }
        let url = URL(fileURLWithPath: path), hash = inspection.sha256.lowercased(), bytes = inspection.bytes
        try await Task.detached(priority: .utility) {
            let facts = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard facts.isRegularFile == true, facts.isSymbolicLink != true, facts.fileSize == bytes else { throw WishMachineError.unavailable }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == bytes, actual == hash else { throw WishMachineError.unavailable }
        }.value
        try Task.checkCancellation()
        let measured = try await sample(url)
        guard measured.modelURL.standardizedFileURL == url.standardizedFileURL, measured.sha256 == hash else { throw WishMachineError.conflictingCall }
        try await authority.putBlob(localPath: url.path, sha256: hash)
        // Collision bytes are an actual provider receipt, not a host-computed
        // prop shape. Rust validates and adopts the stored authoritative receipt.
        if let collisionPath = record.localCollisionPath {
            let measuredCollision = try await sample(URL(fileURLWithPath: collisionPath))
            try await authority.putBlob(localPath: collisionPath, sha256: measuredCollision.sha256)
        }
        try Task.checkCancellation()
        let baseline = try await snapshot()
        let rebase = baseline.record.state.objectStates[job.objectID] != nil
        let receiptData = try await authority.register(identity, wishID: job.id.uuidString,
            expectedRevision: baseline.record.recordRevision, layoutRevision: baseline.record.state.layoutRevision,
            requestID: (rebase ? "rebase." : "claimed.") + job.id.uuidString + "." + hash + "." + identity.hostSessionID,
            blobRef: "sha256:" + hash, triangles: measured.trianglesJSON, rebase: rebase)
        struct Receipt: Decodable { let snapshot: Snapshot }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let registrationReceipt = try decoder.decode(Receipt.self, from: receiptData)
        guard registrationReceipt.snapshot.record.state.worldID == identity.worldID,
              let registered = registrationReceipt.snapshot.record.state.objectStates[job.objectID]?.generatedProp,
              registered.objectID == job.objectID, registered.sourceWishID == job.id.uuidString,
              registered.assetID == "sha256:" + hash else { throw RustWorldPropError.executionUnknown }
        // Accepted/claim/registration submission is not inventory success.
        guard let durable = try await readback(objectID: job.objectID), durable == registered else { throw RustWorldPropError.executionUnknown }
        return durable
    }
}
