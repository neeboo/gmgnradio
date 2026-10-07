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
                        if operation == "wish.claim" { job = try coordinator.claim(id: id, worldID: worldID, residentScope: residentScope) }
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

/// Required preparation is the real renderer's GLB measurement/normalization,
/// reusing WorldPropOrientationPolicy and WorldPropSizePolicy. It is explicitly
/// injected; a model height or task completion is never treated as mesh bounds.
@MainActor final class UnityWishInventoryRegistrar {
    private let store: PropGenerationStore
    private let authority: WorldAuthorityClient
    private let prepare: @MainActor (WishMachineJob, PropGenerationRecord) async throws -> WorldGeneratedProp
    convenience init(root: URL, worldID: String, store: PropGenerationStore) {
        self.init(root: root, worldID: worldID, store: store, prepare: Self.prepareEmbeddedGLB)
    }
    init(root: URL, worldID: String, store: PropGenerationStore,
         prepare: @escaping @MainActor (WishMachineJob, PropGenerationRecord) async throws -> WorldGeneratedProp) {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        authority = WorldAuthorityClient(worldID: worldID, endpointFile: endpoint.endpointFile,
            helperPath: endpoint.helperPath, allowsLaunching: false)
        self.store = store; self.prepare = prepare
    }
    /// Same actual GLB node transforms and same size/orientation policies as
    /// the old host, without depending on a displayed SceneKit/Metal frame.
    /// Unsupported/compressed geometry fails visibly rather than inventing size.
    static func prepareEmbeddedGLB(_ job: WishMachineJob, _ record: PropGenerationRecord) async throws -> WorldGeneratedProp {
        guard let path = record.localModelPath, let result = record.receipt?.result else { throw WishMachineError.notReady }
        let inspection = result.inspection
        let raw = try await Task.detached(priority: .utility) {
            let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: URL(fileURLWithPath: path)))
            guard !triangles.isEmpty else { throw WishMachineError.unavailable }
            var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
            for triangle in triangles {
                for vertex in [triangle.first, triangle.second, triangle.third] {
                    guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { throw WishMachineError.unavailable }
                    minimum = SIMD3(min(minimum.x, vertex.x), min(minimum.y, vertex.y), min(minimum.z, vertex.z))
                    maximum = SIMD3(max(maximum.x, vertex.x), max(maximum.y, vertex.y), max(maximum.z, vertex.z))
                }
            }
            return maximum - minimum
        }.value
        let declared = result.workflowAuthoritativeSize
        let orientation = WorldPropOrientationPolicy.resolve(sourceExtent: .init(x: raw.x, y: raw.y, z: raw.z),
            declaredUpAxis: declared?.upAxis, declaredForwardAxis: declared?.forwardAxis)
        let extent = WorldPropOrientationPolicy.orientedExtent(of: .init(x: raw.x, y: raw.y, z: raw.z), by: orientation)
        let intent = job.sizeIntent.flatMap { WorldPropSizeIntent(axis: $0.axis.rawValue, meters: $0.meters, source: $0.source.rawValue) }
        var size: WorldPropSizePolicy.Resolution?
        if let requested = job.sizeIntent, requested.mode == .dimensions, let mm = requested.millimeters {
            guard let spec = WorldPropSizeMillimeters(x: Float(mm.x), y: Float(mm.y), z: Float(mm.z)) else { throw WishMachineError.unavailable }
            size = WorldPropSizePolicy.intended(sourceExtent: extent, millimeters: spec)
            guard size != nil else { throw WishMachineError.unavailable }
        } else if let intent {
            size = WorldPropSizePolicy.intended(sourceExtent: extent, axis: intent.axis, meters: intent.meters)
        }
        guard let resolved = size ?? WorldPropSizePolicy.automatic(sourceExtent: extent, requestedHeight: Float(job.heightMeters)) else { throw WishMachineError.unavailable }
        guard !result.declaresWorkflowCollision || result.workflowCollision != nil else { throw WishMachineError.unavailable }
        return WorldGeneratedProp(objectID: job.objectID, sourceWishID: job.id.uuidString,
            assetID: "sha256:" + inspection.sha256.lowercased(), displayName: job.name,
            size: resolved.size, sourceHeight: extent.y, collision: result.workflowCollision,
            // WorldPropSizeIntent archives only a single axis. Full dimensions
            // are already materialized in size, so do not let provider dimensions
            // override the user's three explicit numbers via effectiveSize.
            authoritativeSize: job.sizeIntent?.mode == .dimensions ? nil : declared,
            sizeIntent: intent, orientation: orientation.shouldArchive ? orientation : nil)
    }
    func readback(objectID: String) async throws -> WorldGeneratedProp? {
        let client = authority
        return try await Task.detached(priority: .utility) {
            guard let record = try client.snapshot() else { throw WorldAuthorityError.noAuthorityRecord }
            return record.state.objectStates[objectID]?.generatedProp
        }.value
    }
    func register(_ job: WishMachineJob) async throws -> WorldGeneratedProp {
        guard job.stage == .claimed, job.worldID == authority.worldID,
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
        let prop = try await prepare(job, record)
        guard prop.isValid, prop.objectID == job.objectID, prop.sourceWishID == job.id.uuidString,
              prop.assetID == "sha256:" + hash else { throw WishMachineError.conflictingCall }
        if let collision = prop.collision {
            guard let collisionPath = record.localCollisionPath else { throw WishMachineError.notReady }
            try await Task.detached(priority: .utility) {
                let url = URL(fileURLWithPath: collisionPath)
                let facts = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard collision.isValid, facts.isRegularFile == true, facts.isSymbolicLink != true,
                      facts.fileSize == collision.bytes else { throw WishMachineError.unavailable }
                let data = try Data(contentsOf: url)
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == collision.sha256.lowercased(),
                      try GLBColliderDecoder().decode(data: data).count == collision.triangles else { throw WishMachineError.unavailable }
            }.value
        }
        try Task.checkCancellation()
        let client = authority
        let commitWork = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let baseline = try client.snapshot() else { throw WorldAuthorityError.noAuthorityRecord }
            // A deleted item remains deleted; retry cannot resurrect it.
            guard baseline.state.propTombstones?[prop.objectID] == nil else { throw WishMachineError.unavailable }
            if let existing = baseline.state.objectStates[prop.objectID]?.generatedProp {
                guard existing.sourceWishID == prop.sourceWishID, existing.assetID == prop.assetID else { throw WishMachineError.conflictingCall }
                return existing // Preserves user-edited size/placement and avoids duplicate commit.
            }
            var simulation = WorldSimulation(restoring: baseline.state)
            try simulation.applyPropLayout(.register(prop), expectedLayoutRevision: baseline.state.layoutRevision,
                requestID: "claimed." + job.id.uuidString)
            try Task.checkCancellation()
            _ = try client.commit(state: simulation.state, expectedRevision: baseline.recordRevision,
                intent: ["kind": "prop.inventory.register", "objectID": prop.objectID, "wishID": job.id.uuidString])
            guard let durable = try client.snapshot()?.state.objectStates[prop.objectID]?.generatedProp,
                  durable == prop else { throw WorldAuthorityError.invalidResponse }
            return durable
        }
        return try await withTaskCancellationHandler(operation: { try await commitWork.value },
            onCancel: { commitWork.cancel() })
    }
}
