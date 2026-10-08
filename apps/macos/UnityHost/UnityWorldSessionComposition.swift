import Foundation
import WorldRuntime

@MainActor
private final class UnityWishClaimOutputGate {
    var check: (WishMachineJob) -> Bool = { _ in false }
}

/// Business services for one selected world and one resident. All persistence
/// uses the same root and the original authority; construction replays no jobs.
@MainActor
final class UnityWorldSessionComposition {
    let residentHostSessionID = UUID().uuidString
    enum CompositionError: Error, LocalizedError {
        case selectedWorldMismatch, jukeboxNotPlaced, sessionClosed, authorityReadBehind
        var errorDescription: String? {
            switch self {
            case .selectedWorldMismatch: "当前空间已更换，请重新打开。"
            case .jukeboxNotPlaced: "请先在空间放置点唱机，再让角色播放音乐。"
            case .sessionClosed: "当前空间会话已结束，请重新打开。"
            case .authorityReadBehind: "空间状态尚未同步，请稍后重试。"
            }
        }
    }
    let context: WorldAgentContext
    let activity: UnityActivityBridge
    let generationStore: PropGenerationStore
    let wishCoordinator: WishMachineCoordinator
    let wish: UnityWishMachineBridge
    let registrar: UnityWishInventoryRegistrar
    let residentScope: String
    let dispatcher: WorldAgentToolDispatcher
    private var closed = false
    private var approvedMotions: [String: StageMotionAsset]
    private var avatarFormat: StageAvatarFormat?
    private var renderedAvatarAssetID: String?
    private var attachmentReadiness = UnityAttachmentReadiness()
    private var renderedCharacterSelectionRevision: UInt64 = 0
    private var pendingHeldAvatarRebinding: UnityHeldAvatarRebinding?
    private(set) var heldAvatarBindingNotice: String?
    private var heldRebindingRequestID: String?
    func adoptAttachmentReadiness(_ receipt: [String: Any]) -> Bool {
        guard !closed else { return false }
        let expectedAssets = Dictionary(uniqueKeysWithValues: context.state.objectStates.compactMap { id,item in
            item.generatedProp.map { (id,$0.assetID) }
        })
        let accepted = attachmentReadiness.adopt(receipt,worldID: context.manifest.worldID,avatarID: renderedAvatarAssetID,
            avatarFormat: avatarFormat?.rawValue ?? "orb",selectionRevision: renderedCharacterSelectionRevision,
            layoutRevision: context.state.layoutRevision,expectedAssets: expectedAssets)
        if accepted { attemptHeldAvatarRebinding() }
        return accepted
    }
    private let motionStore: MotionPackageStore
    private let worldPackage: BundledLivingWorldPackage
    private var humanImageGrants: [UUID: UUID] = [:]
    private var humanReferenceWindows: [UUID: UUID] = [:]
    private let referenceDirectory: URL
    private let authority: WorldAuthorityClient
    private let applicationSupportBase: URL
    typealias NativePropFacts = @Sendable (RustWorldPropClient.Identity) async throws -> Data
    private let nativePropFacts: NativePropFacts?
    private let propAuthority: RustWorldPropClient
    var onPropLayoutChanged: (() -> Void)?
    private var inventoryMutation: [String: Any] = ["generation": UInt64(0)]
    private var inventoryMutationBusy = false
    private let propGrid = ResidentPropGridEditorModel()
    private var propSupportWork: Task<Void, Never>?
    // MARK: - Unified notification owner
    let inbox: UnityInboxBridge
    private var notifications: UnityWorldNotifications?
    private var notificationWork: Task<Void, Never>?
    private var notificationDirty = false
    private var notificationError: String?
    private var notificationRetry = UnityNotificationRetry()
    private var wishOutputReceipts = UnityWishOutputReceipts()
    var wishProjectionSessionID: String { wishOutputReceipts.sessionID }

    init(applicationSupportBase root: URL, selectedWorldID: String,
         validatedPackage: BundledLivingWorldPackage? = nil,
         bundle: Bundle = .main,
         avatarFormat: StageAvatarFormat = .pmx,
         nativePropFacts: NativePropFacts? = nil,
         nativePhysicsClient: UnityWorldPhysicsClient? = nil,
         takeoverEnabled: @escaping @MainActor () -> Bool = { true },
         claimEvidence: (@MainActor (WishMachineJob, WorldAgentContext) -> WishMachineClaimEvidence?)? = nil) throws {
        applicationSupportBase = root
        self.nativePropFacts = nativePropFacts
        propAuthority = RustWorldPropClient(endpointFile: URL(fileURLWithPath: WorldAuthorityEndpoint(applicationSupportBase: root).endpointFile))
        let package = try validatedPackage ?? LivingWorldBootstrap.loadBundledCanary(bundle: bundle)
        guard package.manifest.worldID == selectedWorldID else {
            throw CompositionError.selectedWorldMismatch
        }
        let initialCollisionWorld: (any WorldCollisionQuerying)?
        let physicsProvider = nativePhysicsClient.map { UnityWorldPhysicsProvider(client:$0,worldID:selectedWorldID) }
        if let physicsProvider {
            initialCollisionWorld=physicsProvider
        } else if let marble = try UnityMarbleRuntimeCollision.load(package: package) {
            initialCollisionWorld = MarbleLivingCabinCollisionWorld(environment: marble,
                props: CollisionVolumeWorld(volumes:
                    ResidentPropPlacementConfiguration.independentCollisionVolumes(package.manifest)))
        } else if let cabin = try LivingWorldBootstrap.loadMarbleCabin(package: package) {
            let transform = cabin.presentation.sceneFraming.colliderTransform(
                sourceCoordinates: cabin.world.colliderSourceCoordinates)
            let triangles = try GLBColliderDecoder().decode(
                data: Data(contentsOf: cabin.colliderURL, options: .mappedIfSafe), transform: transform)
            guard !triangles.isEmpty else { throw WorldAgentContextError.noWalkablePlacement }
            initialCollisionWorld = MarbleLivingCabinCollisionWorld(
                environment: TriangleMeshCollisionWorld(triangles: triangles),
                props: CollisionVolumeWorld(volumes:
                    ResidentPropPlacementConfiguration.independentCollisionVolumes(package.manifest)))
            NSLog("[UnityNavigation] collider installed triangles=%ld", triangles.count)
        } else { initialCollisionWorld = nil }
        let nativePhysics: WorldAgentContext.NativePhysics?
        if let physicsProvider {
            nativePhysics = { @MainActor @Sendable request in
                try await physicsProvider.measure(request)
            }
        } else {
            nativePhysics = nil
        }
        context = try LivingWorldBootstrap.makeContext(package: package, applicationSupportBase: root,
            initialCollisionWorld: initialCollisionWorld,
            nativePhysics: nativePhysics)
        try context.adoptAuthorityState(context.state, propFunctionSources: context.propFunctionSources)
        activity = UnityActivityBridge(context: context)
        dispatcher = WorldAgentToolDispatcher(takeoverEnabled: takeoverEnabled, context: context)
        residentScope = "resident.world." + Data(selectedWorldID.utf8).base64EncodedString()
        let support = root.appendingPathComponent("gmgn radio", isDirectory: true)
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        context.bindWorldControl(client: RustWorldControlClient(endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath),
            identity: .init(worldID: selectedWorldID, residentScope: residentScope, hostSessionID: residentHostSessionID))
        authority = WorldAuthorityClient(worldID: selectedWorldID, endpointFile: endpoint.endpointFile,
            helperPath: endpoint.helperPath, allowsLaunching: false)
        referenceDirectory = support.appendingPathComponent("WishMachine/ReferenceImages", isDirectory: true)
        self.avatarFormat = avatarFormat
        worldPackage = package
        motionStore = MotionPackageStore(rootURL: support.appendingPathComponent("MotionPackages", isDirectory: true))
        let installed = try motionStore.listMotions()
        var supplemental = LivingWorldBootstrap.approvedInstalledMotions(installed)
        if let music = installed.first(where: { $0.id == MotionPackageStore.iluvSlapBassID }) {
            supplemental["listen.music"] = music
        }
        approvedMotions = try LivingWorldBootstrap.approvedMotions(resources: package.manifest.resources,
            packageRoot: package.packageRoot, supplementalMotions: supplemental)
        let daemon = PropTaskDaemonClient(root: support.appendingPathComponent("TaskService", isDirectory: true),
            legacyRoot: support.appendingPathComponent("PropGeneration", isDirectory: true), allowsLaunching: false)
        generationStore = PropGenerationStore(directory: support.appendingPathComponent("PropGeneration", isDirectory: true), daemonClient: daemon)
        let sharedContext = context, projection = activity, store = generationStore
        let scope = residentScope
        let outputGate = UnityWishClaimOutputGate()
        inbox = UnityInboxBridge(root: root, worldID: selectedWorldID, residentScope: scope)
        wishCoordinator = WishMachineCoordinator(store: generationStore,
            directory: support.appendingPathComponent("WishMachine", isDirectory: true),
            wishControlHostSessionID: residentHostSessionID,
            canClaim: { job in
                guard job.residentScope == scope, outputGate.check(job),
                      let evidence = claimEvidence.map({ $0(job, sharedContext) })
                        ?? Self.authoritativeClaimEvidence(job, sharedContext, store: store),
                      evidence.worldID == selectedWorldID,
                      evidence.activityID == "wish_machine.collect",
                      evidence.distanceMeters.isFinite,
                      evidence.distanceMeters >= 0, evidence.outputAvailable else { return nil }
                // The official claim tool waits for an already-started approach.
                // Absence of a visual loop receipt is unknown phase, not absence
                // of the actual collection activity. Final claim still requires
                // loop + actual <= 0.25 m + verified output in the coordinator.
                return WishMachineClaimEvidence(worldID: evidence.worldID, activityID: evidence.activityID,
                    phase: evidence.phase == "loop" && !projection.hasRenderedLoop(activityID: "wish_machine.collect")
                        ? nil : evidence.phase,
                    distanceMeters: evidence.distanceMeters, outputAvailable: evidence.outputAvailable,
                    activityRequestID: evidence.activityRequestID, activityGeneration: evidence.activityGeneration,
                    phaseGeneration: evidence.phaseGeneration, activityHostSessionID: evidence.activityHostSessionID,
                    objectID: evidence.objectID)
            })
        registrar = UnityWishInventoryRegistrar(root: root, worldID: selectedWorldID, residentScope: scope,
            hostSessionID: residentHostSessionID, store: generationStore)
        let inventory = registrar
        wish = UnityWishMachineBridge(coordinator: wishCoordinator, worldID: selectedWorldID,
            residentScope: residentScope, registerInventory: { try await inventory.register($0) },
            inventoryReadback: { try await inventory.readback(objectID: $0) })
        activity.motionProjection = { [weak self] in self?.motionProjection() ?? (false, nil) }
        activity.contactProjection = { [weak self] in
            guard let self, let active = self.context.snapshot.activeActivity,
                  active.id != "wish_machine.collect",
                  let entry = self.context.propAnchorRegistry.entry(activityID: active.id),
                  let contact = self.context.propAnchorRegistry.anchorsByID[entry.objectID + "#button"]
                    ?? self.context.propAnchorRegistry.anchorsByID[entry.objectID + "#interact"],
                  contact.kind == .interaction else { return nil }
            return [Double(contact.position.x), Double(contact.position.y), Double(contact.position.z)]
        }
        activity.contactObjectProjection = { [weak self] in
            guard let self, let active = self.context.snapshot.activeActivity,
                  active.id != "wish_machine.collect",
                  let entry = self.context.propAnchorRegistry.entry(activityID: active.id),
                  self.context.propAnchorRegistry.anchorsByID[entry.objectID + "#button"]?.kind == .interaction
            else { return nil }
            return entry.objectID
        }
        context.waitsForRenderedActivityCompletion = { [weak self] in
            guard let self else { return false }
            let projection = self.motionProjection()
            // Missing authored clips must not advance on a timer. Looping
            // clips retain their contract duration or explicit stop behavior.
            return projection.required && (projection.motion == nil || projection.motion?["loop"] as? Bool == false)
        }
        activity.onFiniteMotionCompleted = { [weak self] request, rawPhase in
            guard let self, let phase = LifeActivityPhase(rawValue: rawPhase),
                  let active = self.context.snapshot.activeActivity,
                  let contract = self.context.activityCatalog.definition(id: active.id)?.contract(for: phase),
                  !contract.motionIDs.isEmpty else { return }
            do { try self.context.completeActivityPlayback(requestID: request, phase: phase) }
            catch { NSLog("[UnityActivity] finite motion completion could not persist") }
        }
        outputGate.check = { [weak self] job in self?.isWishOutputRendered(job.objectID) == true }
        installNotifications()
        preparePropSupport()
        let authoredTemplates = UnityBuiltinDevicesBridge.snapshot(package: package)
        Task { [weak self] in
            guard let self, !self.closed else { return }
            do {
                let identity = RustWorldPropClient.Identity(worldID: selectedWorldID,
                    residentScope: scope, hostSessionID: self.residentHostSessionID)
                let data = try JSONSerialization.data(withJSONObject: authoredTemplates)
                let registered = try await self.propAuthority.deviceCatalog(identity,templates:data)
                struct Reply: Decodable { struct Snapshot: Decodable { struct Record: Decodable {let state:WorldState};let record:Record};let snapshot:Snapshot }
                let decoder=JSONDecoder();decoder.dateDecodingStrategy = .millisecondsSince1970
                let confirmed = try decoder.decode(Reply.self,from:registered).snapshot.record.state
                guard !self.closed else { return }
                try self.adoptAuthorityState(confirmed)
            } catch { self.notificationError = "空间原始功能点注册未确认（world_device_catalog_unavailable）。" }
        }
    }

    private func preparePropSupport() {
        guard let base = context.propSupportQuerying else { return }
        let positions = context.manifest.waypoints.filter(\.enabled).map(\.position)
        guard !positions.isEmpty else { return }
        let parameters = PropSupportGridParameters.default
        let margin = parameters.spacing + parameters.capsuleRadius
        let bounds = WorldPlanarBounds(
            minimumX: positions.map(\.x).min()! - margin, maximumX: positions.map(\.x).max()! + margin,
            minimumZ: positions.map(\.z).min()! - margin, maximumZ: positions.map(\.z).max()! + margin)
        propGrid.setRouteBand(fromWaypoints: context.manifest.waypoints)
        let collision = PropSupportDerivationWorld(base: base,
            topVolumes: context.manifest.collisionVolumes.filter(\.isBlocking))
        propSupportWork = Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            await self.propGrid.preparePlacementSupport(collision: collision,
                seed: self.context.manifest.spawn.position, bounds: bounds, key: self.context.manifest.worldID)
            self.attemptHeldAvatarRebinding()
        }
    }

    func start() {
        guard !closed else { return }
        activity.start()
        _ = inbox.command(["op": "inbox.list"])
        scheduleNotifications()
    }

    /// Invoke only after Unity has acknowledged the actual selected renderer.
    @discardableResult
    func updateCharacterFormat(_ engine: PresenceEngine, assetID: String? = nil,selectionRevision: UInt64 = 0) -> Bool {
        guard !closed else { return false }
        switch engine {
        case .orb: avatarFormat = nil
        case .pmx: avatarFormat = .pmx
        case .vrm: avatarFormat = .vrm
        case .live2D: return false
        }
        renderedAvatarAssetID = assetID
        renderedCharacterSelectionRevision = selectionRevision
        attachmentReadiness.invalidate()
        pendingHeldAvatarRebinding = UnityHeldAvatarRebinding.pending(state: context.state,
            targetAvatarID: renderedAvatarAssetID, selectionRevision: selectionRevision)
        heldAvatarBindingNotice = pendingHeldAvatarRebinding == nil ? nil : "正在为新角色检查原手持物件的挂点；物件身份和放回位置保持。"
        context.updateWalkingSpeed(LivingWorldBootstrap.walkingSpeed(approvedMotions: approvedMotions,avatarFormat: avatarFormat))
        activity.invalidateProjection()
        return true
    }

    private func attemptHeldAvatarRebinding() {
        guard !closed, let pending = pendingHeldAvatarRebinding else { return }
        guard pending.isCurrent(state: context.state, targetAvatarID: renderedAvatarAssetID,
            selectionRevision: renderedCharacterSelectionRevision) else {
            pendingHeldAvatarRebinding = nil
            heldAvatarBindingNotice = nil
            return
        }
        guard attachmentReadiness.permits(slot: pending.slot.rawValue, objectID: pending.objectID,
            assetID: pending.assetID, layoutRevision: context.state.layoutRevision) else {
            heldAvatarBindingNotice = "新角色的原挂点或物件资产尚未准备好；原手持记录保留，未放回或重新拿取。"
            return
        }
        guard heldRebindingRequestID == nil, let nativeFacts = nativePropFacts else { return }
        let requestID = "system.avatar-rebind." + UUID().uuidString
        heldRebindingRequestID = requestID
        Task { [weak self] in
            guard let self else { return }
            var submitted = false
            do {
                struct Binding: Decodable { struct Snapshot: Decodable { struct Record: Decodable { let state: WorldState; let recordRevision: UInt64 }; let record: Record }; let snapshot: Snapshot; let heldBindingSHA256: String }
                let identity = RustWorldPropClient.Identity(worldID: context.manifest.worldID,
                    residentScope: residentScope, hostSessionID: residentHostSessionID)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                let binding = try decoder.decode(Binding.self, from: await propAuthority.systemReturnBinding(identity))
                guard !closed, pending.isCurrent(state: binding.snapshot.record.state, targetAvatarID: renderedAvatarAssetID,
                    selectionRevision: renderedCharacterSelectionRevision) else { throw RustWorldPropError.rejected("world_prop_system_event_stale") }
                let facts = try await nativeFacts(identity)
                let observed = try await propAuthority.observe(identity, expectedRevision: binding.snapshot.record.recordRevision,
                    layoutRevision: binding.snapshot.record.state.layoutRevision, facts: facts)
                guard !closed, pending.selectionRevision == renderedCharacterSelectionRevision,
                    pending.targetAvatarID == renderedAvatarAssetID else { throw RustWorldPropError.rejected("world_prop_system_event_stale") }
                submitted = true
                let receipt = try await propAuthority.systemAvatarReturn(identity, expectedRevision: binding.snapshot.record.recordRevision,
                    layoutRevision: binding.snapshot.record.state.layoutRevision, geometryID: observed.geometryID, requestID: requestID,
                    objectID: pending.objectID, previousAvatarAssetID: pending.previousAvatarID, avatarAssetID: pending.targetAvatarID,
                    selectionRevision: pending.selectionRevision, heldBindingSHA256: binding.heldBindingSHA256, rebind: true)
                try await context.adoptRustPropReceipt(receipt)
                guard context.state.heldProp?.objectID == pending.objectID,
                    context.state.heldProp?.avatarAssetID == pending.targetAvatarID else { throw RustWorldPropError.executionUnknown }
                heldRebindingRequestID = nil; pendingHeldAvatarRebinding = nil; heldAvatarBindingNotice = nil
                attachmentReadiness.invalidate(); onPropLayoutChanged?()
            } catch {
                if !submitted { heldRebindingRequestID = nil }
                if case RustWorldPropError.rejected = error { heldRebindingRequestID = nil }
                heldAvatarBindingNotice = "新角色手持绑定回执未确认；原物件及放回记录保留（world_prop_rebind_unconfirmed）。"
            }
        }
    }

    func prepareManualMotionSelection() throws {
        guard !closed else { throw CompositionError.sessionClosed }
        try context.stopActivity(reason: "用户从设置选择动作")
        activity.invalidateProjection()
    }

    func refreshApprovedMotions() throws {
        guard !closed else { throw CompositionError.sessionClosed }
        let installed = try motionStore.listMotions()
        var supplemental = LivingWorldBootstrap.approvedInstalledMotions(installed)
        if let music = installed.first(where: { $0.id == MotionPackageStore.iluvSlapBassID }) { supplemental["listen.music"] = music }
        let refreshed = try LivingWorldBootstrap.approvedMotions(resources: worldPackage.manifest.resources,
            packageRoot: worldPackage.packageRoot,supplementalMotions: supplemental)
        approvedMotions = refreshed
        context.updateWalkingSpeed(LivingWorldBootstrap.walkingSpeed(approvedMotions: refreshed,avatarFormat: avatarFormat))
        activity.invalidateProjection()
        scheduleNotifications()
    }

    /// The player's existing action is invoked only after formal navigation,
    /// authored phase progression and the renderer's actual motion acknowledgement.
    var prepareJukebox: (@MainActor () async throws -> Void)?
    private lazy var jukeboxAuthority: RustJukeboxClient = {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: applicationSupportBase)
        return RustJukeboxClient(endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath,
            worldID: context.manifest.worldID, scopeID: residentScope, hostSessionID: residentHostSessionID)
    }()
    private var jukeboxView: RustJukeboxClient.View?
    private var jukeboxRenderFacts: Data?
    private var jukeboxLastRenderFacts: Data?

    func performJukebox(operation: Data, _ play: @escaping @MainActor () async throws -> Data) async throws {
        guard !closed else { throw CompositionError.sessionClosed }
        var value = try await jukeboxAuthority.begin(operation: operation, requestID: UUID().uuidString)
        let compoundID = value.compoundID
        var originalError: Error?
        var cancellationSent = false
        defer {
            if jukeboxView?.compoundID == compoundID {
                jukeboxView = nil; jukeboxRenderFacts = nil; jukeboxLastRenderFacts = nil
            }
        }
        while true {
            jukeboxView = value
            if value.state == "completed" { return }
            if value.state == "failed" {
                throw originalError ?? RustJukeboxClient.Fault.rejected(value.errorCode ?? "jukebox_execution_failed")
            }
            if value.action?.status == "unknown" { throw RustJukeboxClient.Fault.unknown }
            if (Task.isCancelled || closed) && !cancellationSent {
                cancellationSent = true; originalError = CancellationError()
                value = try await jukeboxAuthority.read(compoundID: compoundID, cancelRequested: true)
                continue
            }
            if let pending = value.action, pending.status == "pending" {
                let claimed = try await jukeboxAuthority.claim(compoundID: compoundID, actionID: pending.actionID)
                value = claimed; jukeboxView = claimed
                guard let action = claimed.action, action.status == "claimed" else { continue }
                let facts: Data
                do {
                    guard !closed else { throw CompositionError.sessionClosed }
                    switch action.kind {
                    case "prepare":
                        try await prepareJukebox?()
                        facts = try jukeboxPreparationFacts()
                    case "start":
                        activity.invalidateProjection()
                        try await context.startActivityMeasured(id: "music.listen")
                        let run = try await jukeboxAuthority.observeActivity()
                        guard context.currentActivityRequestID == run.runRequestID else { throw CancellationError() }
                        facts = try JSONSerialization.data(withJSONObject:
                            ["runRequestID": run.runRequestID, "generation": run.generation])
                    case "play":
                        guard let fence = claimed.runFence,
                              context.currentActivityRequestID == fence.runRequestID,
                              context.activeActivitySnapshot?.phase.rawValue == fence.phase else { throw CancellationError() }
                        facts = try await play()
                    case "compensate_stop":
                        guard let fence = claimed.runFence,
                              context.currentActivityRequestID == fence.runRequestID,
                              context.activeActivitySnapshot?.phase.rawValue == fence.phase else { throw CancellationError() }
                        try context.stopActivity(reason: "点唱机操作未完成")
                        activity.invalidateProjection()
                        facts = try JSONSerialization.data(withJSONObject: [:])
                    default: throw RustJukeboxClient.Fault.rejected("jukebox_invalid_state")
                    }
                } catch {
                    originalError = error
                    let uncertain = error is TaskdHTTPError || error is PropTaskDaemonError
                        || (error is CancellationError && (action.kind == "play" || action.kind == "start"))
                    value = try await jukeboxAuthority.receipt(compoundID: compoundID, actionID: action.actionID,
                        outcome: uncertain ? "unknown" : "failed", errorCode: "native_action_failed")
                    continue
                }
                // Lost replies do not re-execute the native action. Resolve its durable identity only.
                do {
                    value = try await jukeboxAuthority.receipt(compoundID: compoundID, actionID: action.actionID,
                        outcome: "completed", facts: facts)
                } catch {
                    let observed = try await jukeboxAuthority.read(compoundID: compoundID)
                    guard observed.action?.actionID != action.actionID || observed.state == "completed"
                        || observed.state == "failed" else { throw RustJukeboxClient.Fault.unknown }
                    value = observed
                }
                continue
            }
            if value.action?.status == "claimed" { throw RustJukeboxClient.Fault.unknown }
            if let wait = value.waitMS, wait > 0 {
                // Rust supplies the due interval; this native delay does not decide timeout or stages.
                try? await Task.sleep(for: .milliseconds(wait))
            }
            let rendered = jukeboxRenderFacts; jukeboxRenderFacts = nil
            do {
                value = try await jukeboxAuthority.read(compoundID: compoundID, renderFacts: rendered)
            } catch WorldAuthorityError.daemon("jukebox_stale_render") {
                // A finite clip may advance Rust's phase before the raw renderer fact reaches it.
                // Discard only that observation; no native action is claimed or replayed here.
                value = try await jukeboxAuthority.read(compoundID: compoundID)
            }
        }
    }
    private func jukeboxPreparationFacts() throws -> Data {
        guard let entry = context.propAnchorRegistry.entry(activityID: "music.listen") else {
            throw CompositionError.jukeboxNotPlaced
        }
        let authored = context.activityCatalog.definition(id: "music.listen")?.contract(for: .loop)?.motionIDs ?? []
        let projection = UnityActivityMotionProjection.resolve(avatarFormat: avatarFormat,
            approvedMotions: approvedMotions, locomoting: false, authoredIDs: authored)
        if projection.required && projection.motion == nil { throw UnityActivityBridge.ProjectionError.notRendered }
        let contact = context.propAnchorRegistry.anchorsByID[entry.objectID + "#button"]
            ?? context.propAnchorRegistry.anchorsByID[entry.objectID + "#interact"]
        func point(_ value: WorldVector3) -> [String: Double] {
            ["x": Double(value.x), "y": Double(value.y), "z": Double(value.z)]
        }
        var facts: [String: Any] = ["worldRevision": context.state.revision, "objectID": entry.objectID,
            "interactionTarget": point(entry.position), "motionRequired": projection.required,
            "avatarFormat": avatarFormat?.rawValue as Any? ?? NSNull(),
            "requiredMotionID": projection.motion?["id"] ?? NSNull(), "contactTarget": NSNull()]
        if let contact, contact.kind == .interaction { facts["contactTarget"] = point(contact.position) }
        if projection.required {
            let selected = projection.motion?["id"] as? String
            let authoredID = authored.first(where: { $0 == selected || approvedMotions[$0]?.id == selected })
                ?? (selected == MotionPackageStore.iluvSlapBassVRMID ? authored.first(where: { $0 == "listen.music" }) : nil)
            facts["motionBinding"] = ["authoredMotionID": authoredID ?? "",
                "renderedMotionID": projection.motion?["id"] ?? NSNull(),
                "avatarFormat": avatarFormat?.rawValue as Any? ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: facts)
    }
    private func captureJukeboxProjection(_ raw: [String: Any]) {
        guard let view = jukeboxView, view.state == "wait_render", let fence = view.runFence,
              raw["requestID"] as? String == fence.runRequestID,
              raw["phase"] as? String == fence.phase else { return }
        guard let position = raw["position"] as? [Double], position.count == 3 else { return }
        var facts = raw
        facts["runRequestID"] = fence.runRequestID; facts["generation"] = fence.generation
        facts["phaseGeneration"] = fence.phaseGeneration
        facts["position"] = ["x": position[0], "y": position[1], "z": position[2]]
        if let contact = raw["contactPosition"] as? [Double], contact.count == 3 {
            facts["contactPosition"] = ["x": contact[0], "y": contact[1], "z": contact[2]]
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: facts, options: .sortedKeys),
           encoded != jukeboxLastRenderFacts {
            jukeboxLastRenderFacts = encoded; jukeboxRenderFacts = encoded
        }
    }

    private func motionProjection() -> (required: Bool, motion: [String: Any]?) {
        let active = context.snapshot.activeActivity
        let phase = active?.phase
        let authored = active.flatMap { context.activityCatalog.definition(id: $0.id)?.contract(for: $0.phase) }
        return UnityActivityMotionProjection.resolve(avatarFormat: avatarFormat,approvedMotions: approvedMotions,
            locomoting: phase?.rawValue == "approach" || context.snapshot.movement != nil,
            authoredIDs: authored?.motionIDs ?? [],
            holdingRightHandAtIdle: active == nil && context.state.heldProp?.hand == .rightHand)
    }

    func adoptAuthorityState(_ state: WorldState, replacingUncommittedProjection: Bool = false) throws {
        var sources = context.propFunctionSources.filter {
            state.objectStates[$0.declaration.objectID]?.isEnabled == true
                && state.objectStates[$0.declaration.objectID]?.functionPointDeclaration == nil
        }
        for (_, item) in state.objectStates where item.isEnabled {
            guard item.functionPointDeclaration == nil,
                  let raw = item.metadata["gmgn.builtin-device.v1"],
                  let declaration = try? JSONDecoder().decode(WorldProceduralPropDeclaration.self, from: Data(raw.utf8)),
                  let points = declaration.functionPointDeclaration else { continue }
            sources.removeAll { $0.declaration.objectID == declaration.objectID }
            sources.append(WorldPropFunctionSource(declaration: points,
                seedPosition: declaration.seedPosition, seedYaw: declaration.seedYaw))
        }
        try context.adoptAuthorityState(state, propFunctionSources: sources,
            replacingUncommittedProjection: replacingUncommittedProjection)
        activity.invalidateProjection()
        scheduleNotifications()
    }

    /// Inventory confirmation is followed by this actual authority readback.
    /// No archive save, command replay or optimistic object registration occurs.
    @discardableResult
    func refreshAuthorityState(preservingActorForInventory: Bool = false) async throws -> WorldState {
        guard !closed else { throw CompositionError.sessionClosed }
        let wasTicking = context.isTicking
        context.stopTicking(checkpoint: false)
        defer { if !closed && wasTicking { context.startTicking() } }
        guard let restored = try await context.readPersistedAuthorityState() else {
            throw WorldAuthorityError.noAuthorityRecord
        }
        try Task.checkCancellation()
        guard !closed else { throw CompositionError.sessionClosed }
        // A failed checkpoint can leave the disposable simulation ahead of the
        // durable world. Only this owner's fresh authority load may replace it;
        // external cached projections retain the normal monotonic guard.
        if preservingActorForInventory {
            try context.adoptAuthorityInventoryLayout(restored, propFunctionSources: context.propFunctionSources)
            scheduleNotifications()
        } else {
            try adoptAuthorityState(restored, replacingUncommittedProjection: true)
        }
        try await context.acceptAuthoritySnapshot(restored)
        return context.state
    }

    static func authoritativeClaimEvidence(_ job: WishMachineJob, _ context: WorldAgentContext,
                                          store: PropGenerationStore) -> WishMachineClaimEvidence? {
        guard job.worldID == context.manifest.worldID, job.stage == .ready,
              let run = context.currentRustActivityRun,
              run.definition.id == "wish_machine.collect",
              let anchor = context.propAnchorRegistry.entry(activityID: "wish_machine.collect"),
              let path = job.modelPath, !path.isEmpty,
              FileManager.default.isReadableFile(atPath: path),
              let jobID = job.jobID, let record = store.jobs.first(where: { $0.id == jobID }),
              record.receipt?.state == .completed, record.localModelPath == path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return nil }
        let position = context.state.agentTransform.position
        let distance = sqrt(pow(Double(position.x - anchor.position.x), 2)
            + pow(Double(position.y - anchor.position.y), 2)
            + pow(Double(position.z - anchor.position.z), 2))
        return WishMachineClaimEvidence(worldID: job.worldID, activityID: "wish_machine.collect",
            phase: run.phase.rawValue, distanceMeters: distance, outputAvailable: true,
            activityRequestID: run.requestID, activityGeneration: run.generation,
            phaseGeneration: run.phaseGeneration, activityHostSessionID: run.hostSessionID, objectID: job.objectID)
    }

    /// Each human turn supplies its existing grant identity independently of the
    /// call-ledger run UUID. Missing grant retains read tools but rejects spending.
    func worldServices(
        musicActions: (any DJAgentRadioActions)? = nil,
        musicPlanningAvailable: Bool = false,
        spatialActionsAvailable: Bool = false,
        musicTakeoverEnabled: @escaping @MainActor () -> Bool = { true },
        screenCapability: @escaping @MainActor (String) -> ResidentPropScreenCapability? = { _ in nil },
        authorization: @escaping @MainActor (UUID, String) -> UUID? = { _, _ in nil },
        serviceFacts: @escaping @MainActor () -> (configured: Bool, notice: String) = { (false, "生成服务未配置。") }
    ) -> RenderHostResidentConversation.WorldServices {
        let makeTools: @MainActor (UUID, String, Bool, @escaping @MainActor () -> Bool) -> [ResidentWorldToolSession.AdditionalTool] = { [weak self] runID, humanText, foreground, isCurrent in
                guard let self, !self.closed else { return [] }
                if !humanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isCurrent() {
                    try? self.beginHumanReferenceWindow(runID: runID,isCurrent: isCurrent)
                }
                let grant: UUID? = foreground ? (self.humanImageGrants[runID] ?? authorization(runID, humanText)
                    ?? self.humanReferenceWindows[runID]) : nil
                let lease = ResidentWishMachineTools(coordinator: self.wishCoordinator,
                    worldID: self.context.manifest.worldID, residentScope: self.residentScope,
                    authorizationID: grant, isCurrent: isCurrent,
                    humanOrderedClaim: { !humanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                    continuationResumeAuthorizationID: foreground && isCurrent() && !humanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? runID : nil,
                    serviceFacts: serviceFacts)
                let music = musicActions.map {
                    ResidentMusicToolBridge(actions: UnityResidentMusicActions(base: $0, world: self),
                        isCurrent: isCurrent, exportedNames: foreground ? ResidentMusicToolBridge.playbackNames.union(musicPlanningAvailable ? ResidentMusicToolBridge.planningNames : []).union(spatialActionsAvailable ? ResidentMusicToolBridge.spatialNames : []) :
                            ["read_radio_state", "read_current_track", "list_music_playlists", "read_music_playlist", "search_music"],
                        permitsWorldTransitionResult: foreground && spatialActionsAvailable,
                        takeoverEnabled: musicTakeoverEnabled).tools
                } ?? []
                let reference = ResidentWishReferenceTools.sessionTools(coordinator: self.wishCoordinator,
                    authorizationID: grant,
                    worldID: self.context.manifest.worldID, residentScope: self.residentScope,
                    isCurrent: isCurrent, directory: self.referenceDirectory)
                // Inventory reads share the original service and current world
                // lease. Mutation tools require the renderer's verified support
                // geometry and grip preparation before they can be registered.
                let props = ResidentPropToolBridge(
                service: self.makePropPlacementService(isCurrent: isCurrent),
                    allowsMutation: !humanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isCurrent: isCurrent, onChange: { [weak self] in self?.onPropLayoutChanged?() },
                    prepareMutation: { [weak self] command in
                        guard let self, !self.closed, isCurrent() else { throw CancellationError() }
                        try self.preparePropMutation(command)
                    },
                    resolveDelegatedGrant: { [weak self] objectID, placement in
                        guard let self, !self.closed, isCurrent() else { throw CancellationError() }
                        let grant = try await self.resolveWishPlacementGrant(objectID: objectID, placement: placement)
                        guard !self.closed, isCurrent() else { throw CancellationError() }
                        return grant
                    }, recordDelegatedPlacement: { [weak self] grant, placement in
                        guard let self, !self.closed, isCurrent() else { throw CancellationError() }
                        try await self.wishCoordinator.recordPlacementCompletion(worldID: self.context.manifest.worldID,
                            residentScope: self.residentScope, objectID: grant.objectID, requestID: grant.requestID,
                            surfaceID: placement.surfaceID, target: Self.wishTarget(placement))
                    }, ownershipRow: { [weak self] objectID in
                        guard let self, !self.closed, isCurrent() else { return nil }
                        return self.notificationProjection().rows.first { $0.key.objectID == objectID }
                    }, screenCapability: { objectID in
                        guard isCurrent() else { return nil }
                        return screenCapability(objectID)
                    }, rustTool: { [weak self] name, callID, arguments in
                        guard let self, !self.closed, isCurrent(), let nativeFacts = self.nativePropFacts,
                              let dispatch = ResidentWorldToolSession.rustDispatchAuthority,
                              dispatch.worldID == self.context.manifest.worldID, dispatch.residentScope == self.residentScope,
                              dispatch.callID == callID, dispatch.toolName == name else {
                            throw RustWorldPropError.rejected("world_prop_unauthorized")
                        }
                        let identity = RustWorldPropClient.Identity(worldID: dispatch.worldID,
                            residentScope: dispatch.residentScope, hostSessionID: dispatch.hostSessionID)
                        return try await self.context.executeRustPropTool(name, callID: callID, arguments: arguments,
                            client: self.propAuthority, identity: identity, nativeFacts: { try await nativeFacts(identity) }, isCurrent: isCurrent)
                    }).tools.filter {
                        ["read_owned_props", "list_placement_surfaces", "preview_prop_placement",
                         "apply_prop_placement", "withdraw_prop", "undo_prop_placement", "delete_prop",
                         "hold_prop", "adjust_held_prop_grip", "return_held_prop", "drop_held_prop", "enable_prop_capability"].contains($0.name)
                    }
                return self.wish.tools(for: lease) + music + (foreground ? reference : []) + props
            }
        return .init(context: context, dispatcher: dispatcher,
            isCurrent: { [weak self] in self?.closed == false },
            additionalTools: { runID, text, current in makeTools(runID, text, true, current) },
            onCancel: { [weak self] in
                self?.activity.invalidateProjection()
                self?.humanImageGrants.removeAll()
                self?.humanReferenceWindows.removeAll()
            }, backgroundTools: { runID, current in makeTools(runID, "", false, current) })
    }

    /// Preparing a mutation cannot declare a renderer ready. Unity's actual
    /// loader receipt and the original asset bytes must both match before any
    /// command introduces a visible prop; removal never depends on a good mesh.
    private func makePropPlacementService(isCurrent: @escaping () -> Bool) -> ResidentPropPlacementService {
        ResidentPropPlacementService(context: self.context, support: { [weak self] in
                        guard let self, !self.closed,
                              let support = self.propGrid.supportForPlacement(key: self.context.manifest.worldID) else { return nil }
                        return ResidentPropPlacementSupport(grid: support.grid, collision: support.collision,
                            routeConstraint: self.propGrid.routeConstraint(activities: self.context.manifest.activities,
                                waypoints: self.context.manifest.waypoints))
                    }, prepare: { [weak self] prop in
                        guard let self, !self.closed, isCurrent() else { throw CancellationError() }
                        let catalog = UnityGeneratedAssetCatalog(root: self.applicationSupportBase,
                            worldID: self.context.manifest.worldID, residentScope: self.residentScope)
                        try catalog.update(state: self.context.state, jobs: self.generationStore.jobs,
                            revision: self.context.state.layoutRevision)
                        try catalog.verifyPreparedAsset(prop)
                    }, isCurrent: isCurrent,
                    currentAvatarAssetID: { [weak self] in self?.renderedAvatarAssetID },
                    makeGripCalibration: { [weak self] prop, avatarID, point in
                        guard let self, !self.closed, isCurrent(), avatarID == self.renderedAvatarAssetID else {
                            throw ResidentPropPlacementError.avatarChanged
                        }
                        guard self.avatarFormat == .pmx || self.avatarFormat == .vrm else {
                            throw PropAttachmentError.unsupportedAvatar
                        }
                        guard self.attachmentReadiness.slots.contains(point.worldSlot.rawValue) else { throw PropAttachmentError.missingBone(point) }
                        guard self.attachmentReadiness.permits(slot:point.worldSlot.rawValue,objectID:prop.objectID,
                            assetID:prop.assetID,layoutRevision:self.context.state.layoutRevision) else { throw PropAttachmentError.assetNotPrepared }
                        if let reason = PropAttachmentSlots.clearanceRejection(for: prop, point: point) {
                            throw ResidentPropPlacementError.attachmentUnsupported(reason)
                        }
                        var geometry: [WorldTriangle]?
                        if point == .rightHand {
                            let catalog = UnityGeneratedAssetCatalog(root: self.applicationSupportBase,
                                worldID: self.context.manifest.worldID, residentScope: self.residentScope)
                            try catalog.update(state: self.context.state, jobs: self.generationStore.jobs,
                                revision: self.context.state.layoutRevision)
                            let modelURL = try catalog.verifyPreparedAsset(prop)
                            geometry = try GLBColliderDecoder().decode(data: Data(contentsOf: modelURL, options: .mappedIfSafe))
                        }
                        guard let calibration = PropAttachmentSlots.calibration(avatarAssetID: avatarID, prop: prop,
                            point: point, geometry: geometry) else {
                            throw ResidentPropPlacementError.attachmentUnsupported("柄部位置未确认，需要显式握点标定。")
                        }
                        return calibration
                    })
    }

    private func preparePropMutation(_ command: WorldPropLayoutCommand) throws {
        switch command {
        case .hold(let id,let avatarID,let calibration),.adjustGrip(let id,let avatarID,let calibration):
            guard avatarID == renderedAvatarAssetID,let prop=context.state.objectStates[id]?.generatedProp,
                  attachmentReadiness.permits(slot:calibration.hand.rawValue,objectID:id,assetID:prop.assetID,
                    layoutRevision:context.state.layoutRevision) else { throw PropAttachmentError.assetNotPrepared }
        case .rebindHeldAvatar(let id, _, let calibration):
            guard calibration.avatarAssetID == renderedAvatarAssetID,
                  let prop = context.state.objectStates[id]?.generatedProp,
                  attachmentReadiness.permits(slot: calibration.hand.rawValue, objectID: id,
                    assetID: prop.assetID, layoutRevision: context.state.layoutRevision) else {
                throw PropAttachmentError.assetNotPrepared
            }
        default: break
        }
        var introduced = Set<String>()
        switch command {
        case .place(let id, _), .hold(let id, _, _), .adjustGrip(let id, _, _), .rebindHeldAvatar(let id, _, _), .enableCapability(let id, _): introduced.insert(id)
        case .returnHeld(let id, _):
            if context.state.heldProp?.returnState.isEnabled == true { introduced.insert(id) }
        case .dropHeld(let id, _, _): introduced.insert(id)
        case .undo:
            if let previous = context.state.layoutUndo?.previous, previous.isEnabled,
               let prop = previous.generatedProp { introduced.insert(prop.objectID) }
        case .register, .withdraw, .resize, .rebase, .delete: break
        }
        guard !introduced.isEmpty else { return }
        let catalog = UnityGeneratedAssetCatalog(root: applicationSupportBase,
            worldID: context.manifest.worldID, residentScope: residentScope)
        try catalog.update(state: context.state, jobs: generationStore.jobs, revision: context.state.layoutRevision)
        for id in introduced.sorted() {
            guard let prop = context.state.objectStates[id]?.generatedProp,
                  attachmentReadiness.isAssetPrepared(objectID:id,assetID:prop.assetID,
                    layoutRevision:context.state.layoutRevision) else { throw PropAttachmentError.assetNotPrepared }
            try catalog.verifyPreparedAsset(prop)
        }
    }

    private static func wishTarget(_ placement: WorldPropPlacement) -> WishPlacementTarget {
        WishPlacementTarget(surfaceID: placement.surfaceID,
            position: .init(x: Double(placement.position.x), y: Double(placement.position.y), z: Double(placement.position.z)),
            yaw: Double(placement.yaw))
    }

    private func resolveWishPlacementGrant(objectID: String, placement: WorldPropPlacement) async throws -> ResidentPropDelegatedGrant {
        guard !closed, context.state.propTombstones?[objectID] == nil,
              context.state.objectStates[objectID]?.generatedProp != nil,
              wishCoordinator.residentJobs(worldID: context.manifest.worldID, residentScope: residentScope)
                .contains(where: { $0.objectID == objectID && $0.stage == .claimed && $0.autoContinuationPaused != true })
        else { throw WishMachineError.unauthorized }
        let grant = try await wishCoordinator.resolvePlacementGrant(worldID: context.manifest.worldID,
            residentScope: residentScope, objectID: objectID, surfaceID: placement.surfaceID, target: Self.wishTarget(placement))
        let target = (grant.explicitTarget ?? grant.boundTarget).map {
            WorldPropPlacement(surfaceID: $0.surfaceID,
                position: .init(x: Float($0.position.x), y: Float($0.position.y), z: Float($0.position.z)), yaw: Float($0.yaw))
        }
        return ResidentPropDelegatedGrant(objectID: objectID, allowedSurfaceIDs: Set(grant.allowedSurfaceIDs),
            target: target, requestID: grant.requestID)
    }

    /// Current foreground human turns may search/download a reference. Creating
    /// this window creates no coordinator authorization and permits no spending:
    /// registerWebReference durably creates a grant only after a real PNG exists.
    func beginHumanReferenceWindow(runID: UUID, isCurrent: @MainActor () -> Bool) throws {
        guard !closed, isCurrent() else { throw WishMachineError.unauthorized }
        if humanReferenceWindows[runID] == nil { humanReferenceWindows[runID] = UUID() }
    }

    /// Host-only human attachment submission. Importing/registering images by
    /// itself spends nothing; authorization is durable only for actual local
    /// attachments on the current human run, matching the original app contract.
    @discardableResult
    func authorizeHumanImages(runID: UUID, conversationID: String,
                              attachments: [ResidentImageAttachment],
                              isCurrent: @MainActor () -> Bool) async throws -> UUID {
        guard !closed, isCurrent(), !conversationID.isEmpty,
              !attachments.isEmpty, attachments.count <= 4 else { throw WishMachineError.unauthorized }
        try await wishCoordinator.registerImages(attachments, worldID: context.manifest.worldID,
            residentScope: residentScope, conversationID: conversationID)
        guard !closed, isCurrent() else { throw WishMachineError.unauthorized }
        let grantID = humanImageGrants[runID] ?? humanReferenceWindows[runID] ?? UUID()
        try await wishCoordinator.authorize(registeredImageIDs: attachments.map(\.id),
            worldID: context.manifest.worldID, residentScope: residentScope,
            conversationID: conversationID, authorizationID: grantID,
            source: .init(author: "用户提供", license: "未核验，仅限个人测试"))
        guard !closed, isCurrent() else { throw WishMachineError.unauthorized }
        humanImageGrants[runID] = grantID
        return grantID
    }

    func snapshot() -> [String: Any] {
        ["activity": activity.snapshot(), "wish": wish.snapshot(), "inbox": inbox.snapshot(), "inventoryMutation": inventoryMutation,
         "heldAvatarBindingNotice": heldAvatarBindingNotice as Any? ?? NSNull(),
         "notificationError": notificationError as Any? ?? NSNull(),
         "agentNotifications": notifications?.snapshot() ?? [:],
         "notificationRetryFailures": notificationRetry.failures,
         "renderedWishOutputIDs": wishOutputReceipts.renderedObjectIDs,
         "currentActivityPhase": context.snapshot.activeActivity?.phase.rawValue as Any? ?? NSNull()]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard !closed else { return false }
        if value["op"] as? String == "inventory.delete" {
            guard !inventoryMutationBusy, value["worldID"] as? String == context.manifest.worldID,
                  let objectID = value["objectID"] as? String,
                  let expected = value["layoutRevision"] as? UInt64,
                  expected == context.state.layoutRevision else { return false }
            inventoryMutationBusy = true
            Task { [weak self] in
                guard let self else { return }
                defer { inventoryMutationBusy = false }
                var result: [String: Any] = ["objectID": objectID]
                do {
                    guard !closed else { throw CompositionError.sessionClosed }
                    let identity = RustWorldPropClient.Identity(worldID: context.manifest.worldID,
                        residentScope: residentScope, hostSessionID: residentHostSessionID)
                    let (state, revision) = try await context.rustPropAuthoritySnapshot(client: propAuthority, identity: identity)
                    guard state.layoutRevision == expected, !closed else { throw RustWorldPropError.rejected("revision_conflict") }
                    let raw = try JSONSerialization.data(withJSONObject: ["op":"delete","objectID":objectID])
                    let intent = try await propAuthority.uiIntent(identity, expectedRevision: revision, layoutRevision: expected, command: raw)
                    guard !closed else { throw CompositionError.sessionClosed }
                    let receipt = try await propAuthority.uiCommand(identity, intent: intent, expectedRevision: revision,
                        layoutRevision: expected, geometryID: nil, requestID: "human-delete:" + UUID().uuidString)
                    try await context.adoptRustPropReceipt(receipt)
                    let durable = try await refreshAuthorityState(preservingActorForInventory: true)
                    guard durable.objectStates[objectID] == nil, durable.propTombstones?[objectID]?.isValid == true else {
                        throw CompositionError.authorityReadBehind
                    }
                    result["status"] = "completed"
                    onPropLayoutChanged?()
                } catch { result["status"] = "failed"; result["message"] = error.localizedDescription }
                result["generation"] = ((inventoryMutation["generation"] as? UInt64) ?? 0) &+ 1
                inventoryMutation = result
            }
            return true
        }
        if value["op"] as? String == "wish.output.projected" { return acknowledgeWishOutput(value) }
        if (value["op"] as? String)?.hasPrefix("inbox.") == true {
            let accepted = inbox.command(value)
            if accepted { scheduleNotifications() }
            return accepted
        }
        if value["op"] as? String == "activity.projected" {
            let accepted = activity.acknowledgeProjection(value)
            if accepted { captureJukeboxProjection(value) }
            return accepted
        }
        return wish.command(value)
    }

    func close() {
        guard !closed else { return }
        closed = true
        propSupportWork?.cancel(); propSupportWork = nil
        notificationWork?.cancel(); notificationWork = nil
        notifications?.close(store: generationStore); inbox.close()
        wishOutputReceipts.update(worldID: context.manifest.worldID, entries: [])
        wish.close()
        activity.close()
        generationStore.clearConfiguration()
        humanImageGrants.removeAll()
        humanReferenceWindows.removeAll()
    }

    // MARK: - Notification projection and actual renderer receipts
    private func installNotifications() {
        notifications = UnityWorldNotifications(worldID: context.manifest.worldID,
            residentScope: residentScope, inbox: inbox)
        let previousCoordinatorChange = wishCoordinator.onChange
        wishCoordinator.onChange = { [weak self] in
            previousCoordinatorChange?(); self?.scheduleNotifications()
        }
        let previousStoreChange = generationStore.onChange
        generationStore.onChange = { [weak self] in
            previousStoreChange?(); self?.scheduleNotifications()
        }
        generationStore.onMessage = { [weak self] consumer, message in
            guard let self, !self.closed,
                  self.notifications?.receive(consumer: consumer, message: message) == true else { return }
            self.scheduleNotifications()
        }
    }

    func bindWishAgent(_ deliver: @escaping @MainActor (ResidentAgentLoop.Event, Bool) -> Bool) {
        guard !closed else { return }
        notifications?.onAgentEvent = deliver
        scheduleNotifications()
    }

    func didConsumeWishEvents(_ events: [ResidentAgentLoop.Event]) {
        guard !closed else { return }
        do { try notifications?.didConsume(events, coordinator: wishCoordinator) }
        catch {
            // The model/tools have already completed. Failure to persist their
            // consumption receipt must not turn them into a retryable model run.
            notificationError = "notification_not_confirmed"
        }
        scheduleNotifications()
    }

    func didNotConsumeWishEvents(_ events: [ResidentAgentLoop.Event]) {
        guard !closed else { return }
        notifications?.didNotConsume(events)
        scheduleNotifications()
    }

    private func scheduleNotifications() {
        guard !closed else { return }
        notificationDirty = true
        guard notificationWork == nil else { return }
        notificationWork = Task { [weak self] in
            guard let self else { return }
            defer { notificationWork = nil }
            while notificationDirty && !closed && !Task.isCancelled {
                notificationDirty = false
                let projection = notificationProjection()
                do {
                    let delivered = try await notifications?.synchronize(rows: projection.rows, tasks: projection.tasks,
                        coordinator: wishCoordinator, store: generationStore,
                        outputIsRendered: { [weak self] objectID in self?.isWishOutputRendered(objectID) == true })
                    if delivered == false && !closed {
                        notificationDirty = true
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    notificationRetry.succeeded()
                    notificationError = nil
                } catch {
                    guard !closed, !Task.isCancelled else { break }
                    // Reconcile the same IDs even when nothing else changes.
                    // This does not submit jobs or renew stopped agent authority.
                    notificationError = "notification_not_confirmed"
                    notificationDirty = true
                    do { try await Task.sleep(nanoseconds: notificationRetry.failed()) }
                    catch { break }
                }
            }
        }
    }

    private func isWishOutputRendered(_ objectID: String) -> Bool {
        guard let job = wishCoordinator.residentJobs(worldID: context.manifest.worldID, residentScope: residentScope)
            .first(where: { $0.objectID == objectID }), let path = job.modelPath else { return false }
        return wishOutputReceipts.isRendered(objectID: objectID, wishID: job.id.uuidString, modelPath: path)
    }

    func updateWishOutputProjections(_ entries: [[String: Any]]) {
        guard !closed else { return }
        wishOutputReceipts.update(worldID: context.manifest.worldID, entries: entries)
        scheduleNotifications()
    }

    /// Unity sends this only after its asynchronous model loader has produced
    /// the actual visible output; unload/failure sends rendered=false.
    private func acknowledgeWishOutput(_ value: [String: Any]) -> Bool {
        guard value["worldID"] as? String == context.manifest.worldID,
              let wishID = value["wishID"] as? String,
              let objectID = value["objectID"] as? String,
              let job = wishCoordinator.residentJobs(worldID: context.manifest.worldID, residentScope: residentScope)
                .first(where: { $0.id.uuidString == wishID && $0.objectID == objectID }) else { return false }
        guard job.stage == .ready || job.stage == .claimed,
              let path = job.modelPath, value["modelPath"] as? String == path,
              wishOutputReceipts.accept(value) else { return false }
        scheduleNotifications()
        return true
    }

    private func notificationProjection() -> (rows: [OwnershipRow], tasks: [WishMachineTaskPresentation]) {
        let jobs = wishCoordinator.residentJobs(worldID: context.manifest.worldID, residentScope: residentScope)
        let rows = jobs.enumerated().map { index, job -> OwnershipRow in
            var facts = OwnershipRowFacts(objectID: job.objectID)
            facts.jobID = job.id; facts.jobName = job.name
            facts.jobStage = OwnershipJobStage(rawValue: job.stage.rawValue)
            facts.remoteState = job.remoteState?.rawValue; facts.lastError = job.lastError
            facts.cancelRequested = job.cancelRequested ?? false; facts.processOrder = index
            let item = context.state.objectStates[job.objectID]
            let prop = item?.generatedProp
            facts.objectPresent = prop != nil; facts.objectHasGeneratedProp = prop != nil
            facts.objectName = prop?.displayName; facts.objectIsEnabled = item?.isEnabled ?? false
            facts.matchedBySourceWishID = prop?.sourceWishID == job.id.uuidString
            if context.state.heldProp?.objectID == job.objectID { facts.heldSlot = context.state.heldProp?.hand.rawValue }
            if let tombstone = context.state.propTombstones?[job.objectID] {
                facts.tombstoneName = tombstone.displayName; facts.tombstoneReason = tombstone.reason
                facts.tombstoneSettlement = tombstone.settlement.summary
            }
            facts.claimReceiptPresent = context.state.layoutReceipts["claimed.\(job.id.uuidString)"] != nil
            facts.canRedoInventoryRegistration = context.state.canRedoInventoryRegistration(objectID: job.objectID)
            facts.trayShowsThis = isWishOutputRendered(job.objectID)
            if case .success = wishCoordinator.claimAvailability(id: job.id, worldID: job.worldID, residentScope: residentScope) { facts.canClaimNow = true }
            facts.canRetryNow = WishMachineCoordinator.retryableStages.contains(job.stage) && job.jobID != nil
            return ResidentOwnershipProjection.row(facts)
        }
        let tasks = rows.compactMap { row -> WishMachineTaskPresentation? in
            guard let id = row.key.jobID else { return nil }
            return .init(id: id, title: row.name, status: row.statusText, detail: row.reasonText ?? "",
                isTerminal: [.inInventory, .placed, .failed, .ended].contains(row.state))
        }
        return (rows, tasks)
    }
}
