import Foundation
import simd
import os
import WorldRuntime

enum WorldAgentContextError: Error, Equatable {
    case restoredWorldMismatch(expected: String, actual: String)
    case unknownPlace(String)
    case unknownActivity(String)
    case unknownCamera(String)
    case invalidGoalID
    case invalidTickDuration
    case activityRejected(String)
    case activityStartRejected(String, ActivityExecutionRejection)
    case routeBlocked(String)
    case noWalkablePlacement
}

enum WorldCoordinateMovementError: Error, LocalizedError {
    case invalidPosition, missingGround, offGround, occupied, blocked
    var errorDescription: String? {
        switch self {
        case .invalidPosition: "人物位置或请求编号无效。"
        case .missingGround: "目标位置没有可验证的真实地面。"
        case .offGround: "目标高度偏离地面，请使用该位置的地面高度。"
        case .occupied: "目标位置没有足够空间容纳人物。"
        case .blocked: "人物无法沿合法地面到达目标位置。"
        }
    }
}

struct WorldAgentPlaceSnapshot: Codable, Equatable, Sendable {
    let id: String
    let position: WorldVector3
    let arrivalRadius: Float
    let displayName: String?

    init(id: String, position: WorldVector3, arrivalRadius: Float, displayName: String? = nil) {
        self.id = id; self.position = position; self.arrivalRadius = arrivalRadius; self.displayName = displayName
    }
}

struct WorldAgentActivityOption: Codable, Equatable, Sendable {
    let id: String
    let action: String
    let entryPlaceID: String
    let interruptible: Bool
    var seat: WorldPropSeatProjection? = nil
}

struct WorldAgentCameraOption: Codable, Equatable, Sendable {
    let id: String
    let transform: WorldTransform
    let fieldOfViewDegrees: Float
}

struct WorldAgentActiveActivitySnapshot: Codable, Equatable, Sendable {
    let id: String
    let activity: LifeActivity
    let phase: LifeActivityPhase
    var seat: WorldPropSeatProjection? = nil
}

struct WorldAgentMovementSnapshot: Codable, Equatable, Sendable {
    let destinationID: String
    let waypointIDs: [String]
    let nextWaypointIndex: Int
    let totalLength: Float
}

struct WorldAgentSnapshot: Codable, Equatable, Sendable {
    let revision: UInt64
    let worldID: String
    let displayName: String
    let worldTime: Date
    let weather: WorldWeather
    let agentTransform: WorldTransform
    let liveCamera: WorldCameraState?
    let activeActivity: WorldAgentActiveActivitySnapshot?
    let movement: WorldAgentMovementSnapshot?
    let completedGoalIDs: [String]
    let places: [WorldAgentPlaceSnapshot]
    let activities: [WorldAgentActivityOption]
    let cameras: [WorldAgentCameraOption]
}

@MainActor
final class WorldAgentContext {
    /// Successful stop intent also clears renderer-owned manual motion.
    var onActivityStopped: (() -> Void)?
    private struct MovementRun {
        let requestID: String
        var path: WorldPath
        var nextPointIndex: Int
        var replansRemaining = 1
        var coordinateTarget: WorldVector3? = nil
    }

    private struct PatrolRun {
        var targetID: String
        var visits: [String: Int] = [:]
    }

    private struct NavigationSegment: Hashable {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
    }

    let manifest: WorldManifest
    let navigationGraph: WaypointNavigationGraph
    let collisionWorld: ReplaceableCollisionWorld
    private var baseCollisionWorld: any WorldCollisionQuerying
    private let authoredActivityCatalog: ActivityCatalog
    private let rustActivityCatalog: RustActivityCatalogClient?
    private let rustWorldActivity: RustWorldActivityClient?
    private let rustPropCapability: RustPropCapabilityClient?
    private var capabilityRefresh: Task<Void, Never>?
    private var capabilityGeneration: UInt64 = 0
    private var confirmedOperationSpots: [String: RustPropCapabilityClient.Target] = [:]
    private var confirmedFunctionPointSpots: [String: RustPropCapabilityClient.Target] = [:]
    private var confirmedDevicePlaces: [String: RustPropCapabilityClient.PlaceBinding] = [:]
    private var confirmedDevicePlaceLayoutRevision: UInt64?
    private var confirmedCapabilityCollisionRevision: UInt64?
    private(set) var activityCatalogFault: Error?

    /// A bound prop capability becomes one concrete, discoverable activity with
    /// a standable operation spot resolved against the current collision world.
    /// `approachPoint` is the collision-verified final leg appended after the
    /// entry waypoint when the waypoint itself lies outside arm's reach.
    private struct PropActivity {
        /// 这件活动的**来源**。两类活动的几何都来自运行时注册/派生，但它们是不同的东西，
        /// 消费方（动作可用性、进入阶段动作失败回写）用的是不同规则：
        ///
        /// - `boundCapability`：生成物件绑定的能力模板。它的进入阶段是**回执驱动的动作**
        ///   （`WorldPropActivityTemplate.enterMotionIDs`），没有可播的动作就不能算可用。
        /// - `functionPointAnchor`：世界固有设备声明的功能点锚点（许愿机、点唱机）。
        ///   它的进入阶段由世界包的活动定义**逐字**声明要不要动作，宿主不得拿生成物件的
        ///   规则去判它 —— 那会把 `enter.motionIDs == []`（本来就不需要动作）判成"缺动作"。
        ///
        /// 这两类以前被同一个"在 `propActivities` 里"的判据混在一起，于是世界设备活动
        /// 被按生成物件能力活动审查。来源必须是**显式**的，不能靠"在哪里出现过"推断。
        enum Origin { case boundCapability, functionPointAnchor, seatCalibration }

        let definition: LifeActivityDefinition
        let objectID: String
        let templateID: String
        let entryWaypointID: String
        let approachPoint: WorldVector3?
        let targetYaw: Float
        /// 非 `nil` = 这件活动的入口是**运行时注册的道具功能点锚点**（不是绑定能力模板）。
        /// 移动/收回时靠它判断"锚点是不是从居民脚下移走了"。
        let functionPointAnchorID: String?
        let functionPointPosition: WorldVector3?
        let origin: Origin

        var isFunctionPoint: Bool { origin == .functionPointAnchor }
    }

    private var propActivities: [String: PropActivity] = [:]
    private var seatProjections: [String: WorldPropSeatProjection] = [:]
    private var combinedActivityCatalog: ActivityCatalog?
    /// 世界包/资产声明的道具功能点来源。**锚点不落盘**：每次布局变化都从
    /// （声明 × 摆放）重新派生。
    private(set) var propFunctionSources: [WorldPropFunctionSource]
    /// 当前已注册出来的道具功能点世界锚点。纯值、每次重建、永不落盘。
    private(set) var propAnchorRegistry: WorldPropAnchorRegistry = .empty
    /// 最近一次派生失败的原因（诊断用）。派生失败时**保留旧注册表**，
    /// 绝不发布半注册状态。
    private(set) var propAnchorRegistryFault: WorldPropAnchorError?

    var activityCatalog: ActivityCatalog {
        combinedActivityCatalog ?? authoredActivityCatalog
    }

    private(set) var simulation: WorldSimulation
    private(set) var activityExecutor: ActivityExecutor
    var currentActivityRequestID: String? {
        if let rustWorldActivity { return rustWorldActivity.running?.requestID }
        return activityExecutor.currentRequestID
    }
    /// The current authority receipt, never an executor-invented activity identity.
    var currentRustActivityRun: RustWorldActivityClient.Run? {rustWorldActivity?.running}
    private var rustApproach: MovementRun?
    private var rustActivityDeadlineTask: Task<Void, Never>?
    private var rustActivityReceiptFault: Error?
    private var rustCatalogInput: Data?
    var currentMovementRequestID: String? { movement?.requestID }
    private var movement: MovementRun?
    private var patrol: PatrolRun?
    private let executionScopeID = UUID().uuidString
    // Only planning uses this cache. Each actual movement step is checked again.
    private var navigationTraversalCache: [NavigationSegment: Bool] = [:]
    // Discovery is read many times per rendered frame. Object layout/metadata and
    // installed collision geometry determine these spots; time and actor movement
    // do not. Manifest waypoints, world ID, capsule and step height are immutable
    // for this context. Actual navigation still resolves and validates its target.
    private var generatedPlacesCache: (objects: [String: WorldObjectState], collisionRevision: UInt64,
                                       places: [WorldAgentPlaceSnapshot])?
    private var activityPhaseElapsed: TimeInterval = 0
    var waitsForRenderedActivityCompletion: (() -> Bool)?
    private let persistence: (any WorldStatePersisting)?
    private var walkingSpeed: Float
    private let capsule: WorldCapsule
    private let maximumStepHeight: Float
    struct NativePhysicsRequest: Sendable {
        let worldID: String
        let hostSessionID: String
        let layoutRevision: UInt64
        let physicsGeneration: UInt64
        let probes: [RustPropCapabilityClient.Probe]
        let capsuleRadius: Float
        let capsuleHeight: Float
    }
    typealias NativePhysics = @MainActor @Sendable (NativePhysicsRequest) async throws -> [RustPropCapabilityClient.Measurement]
    let nativePhysics: NativePhysics?
    private struct NativeMovementProof {
        let runID: String
        let index: Int
        let layout: UInt64
        let collision: UInt64
        let generation: UInt64
        let from: WorldVector3
        let target: WorldVector3
        var result: Result<RustPropCapabilityClient.Measurement, Error>?
    }
    private var nativeMovementProof: NativeMovementProof?
    private var nativeMovementProbeTask: Task<Void, Never>?
    var physicsCapsule: WorldCapsule { capsule }
    var physicsStepHeight: Float { maximumStepHeight }
    private var tickingTask: Task<Void, Never>?
    var isTicking: Bool { tickingTask != nil }
    private var lastCheckpointWorldTime: Date?
    /// Monotonic observation cursor over the retained event window: the `sequence`
    /// of the last retained event this context has scanned, or `nil` before the
    /// first scan. Sequences are mutation watermarks that never restart (even after
    /// a restore or a window trim), so this cursor stays valid while
    /// `WorldSimulation` drops the oldest retained events — an absolute array index
    /// would silently desynchronize. See `publishObservations`.
    private var publishedSequence: UInt64?

    var onSnapshotChanged: (@MainActor (WorldAgentSnapshot) -> Void)?
    var onEventsPublished: (@MainActor ([WorldEvent]) -> Void)?
    /// Persisted Rust facts have their own sequence namespace, distinct from
    /// the native frame/pose observation cache.
    var onRustEventsPublished: (@MainActor ([WorldEvent]) -> Void)?
    private var publishedRustFactSequence: UInt64 = 0
    var onTickError: (@MainActor (Error) -> Void)?

    init(
        manifest: WorldManifest,
        startedAt: Date = Date(),
        persistence: (any WorldStatePersisting)? = nil,
        walkingSpeed: Float = 1.2,
        capsule: WorldCapsule = WorldCapsule(radius: 0.2, height: 1.8),
        maximumStepHeight: Float = 0.3,
        propFunctionSources: [WorldPropFunctionSource] = [],
        initialCollisionWorld: (any WorldCollisionQuerying)? = nil,
        rustActivityCatalog: RustActivityCatalogClient? = nil,
        rustWorldActivity: RustWorldActivityClient? = nil,
        rustPropCapability: RustPropCapabilityClient? = nil,
        nativePhysics: NativePhysics? = nil
    ) throws {
        guard nativePhysics == nil || initialCollisionWorld != nil else {
            throw RustPropCapabilityClient.Failure.unavailable
        }
        self.manifest = manifest
        self.propFunctionSources = propFunctionSources
        navigationGraph = WaypointNavigationGraph(manifest: manifest)
        baseCollisionWorld = initialCollisionWorld ?? CollisionVolumeWorld(manifest: manifest)
        collisionWorld = ReplaceableCollisionWorld(
            initial: baseCollisionWorld
        )
        self.rustActivityCatalog = rustActivityCatalog
        self.rustWorldActivity = rustWorldActivity
        self.rustPropCapability = rustPropCapability
        self.nativePhysics = nativePhysics
        authoredActivityCatalog = try rustActivityCatalog?.manifest(manifest) ?? ActivityCatalog(manifest: manifest)
        self.persistence = persistence
        self.walkingSpeed = max(0, walkingSpeed)
        self.capsule = capsule
        self.maximumStepHeight = max(0, maximumStepHeight)

        if let restored = try persistence?.load() {
            guard restored.worldID == manifest.worldID else {
                throw WorldAgentContextError.restoredWorldMismatch(
                    expected: manifest.worldID,
                    actual: restored.worldID
                )
            }
            simulation = WorldSimulation(restoring: restored)
        } else {
            simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)
        }

        if nativePhysics != nil { collisionWorld.replace(with: baseCollisionWorld) }
        else { collisionWorld.replace(with: PropLayoutCollisionWorld(base: baseCollisionWorld,
            obstacles: WorldLayoutObstacles.resolve(simulation.state).obstacles)) }

        let transform = simulation.state.agentTransform
        activityExecutor = ActivityExecutor(
            position: transform.position,
            yaw: Self.yaw(of: transform.rotation),
            walkingSpeed: self.walkingSpeed,
            collisionQuery: collisionWorld,
            capsule: capsule,
            maximumStepHeight: self.maximumStepHeight
        )

        rebuildPropActivities()

        if let activityCatalogFault { throw activityCatalogFault }

        // Persisted activity is a projection; only Rust can restore execution.
    }

    /// Startup/tests can await the current authority receipt without frame polling.
    func awaitConfirmedActivityCatalog() async throws {
        while true {
            try Task.checkCancellation()
            let generation = capabilityGeneration
            await capabilityRefresh?.value
            if generation != capabilityGeneration { continue }
            if let activityCatalogFault { throw activityCatalogFault }
            guard confirmedCapabilityCollisionRevision == collisionWorld.revision else {
                throw RustPropCapabilityClient.Failure.unavailable
            }
            return
        }
    }

    private func rebuildPropActivities() {
        capabilityGeneration &+= 1
        let generation = capabilityGeneration
        capabilityRefresh?.cancel()
        propActivities = [:]; seatProjections = [:]; confirmedOperationSpots = [:]; confirmedFunctionPointSpots = [:]
        confirmedDevicePlaces = [:]; confirmedDevicePlaceLayoutRevision = nil
        confirmedCapabilityCollisionRevision = nil
        combinedActivityCatalog = try? ActivityCatalog(definitions: [])
        activityCatalogFault = nil
        guard rustPropCapability != nil, rustWorldActivity != nil else {
            activityCatalogFault = RustPropCapabilityClient.Failure.unavailable
            return
        }
        capabilityRefresh = Task { [weak self] in
            guard let self else { return }
            do { try await rebuildPropActivitiesFromAuthority(generation: generation) }
            catch is CancellationError { }
            catch {
                guard capabilityGeneration == generation else { return }
                activityCatalogFault = error
                onTickError?(error)
            }
        }
    }

    private func rebuildPropActivitiesFromAuthority(generation: UInt64) async throws {
        guard let rustPropCapability, let rustWorldActivity else { throw RustPropCapabilityClient.Failure.unavailable }
        let layoutRevision = state.layoutRevision
        let collisionRevision = collisionWorld.revision
        let objects = state.objectStates
        func current() throws {
            try Task.checkCancellation()
            guard capabilityGeneration == generation, state.layoutRevision == layoutRevision,
                  state.objectStates == objects, collisionWorld.revision == collisionRevision else { throw CancellationError() }
        }
        rebuildPropAnchorRegistry()
        let devicePlaces = try await rustPropCapability.places(worldID: manifest.worldID,
            hostSessionID: rustWorldActivity.hostSessionID, layoutRevision: layoutRevision)
        try current()
        var rebuilt: [String: PropActivity] = [:]
        var seats: [String: WorldPropSeatProjection] = [:]
        var spots: [String: RustPropCapabilityClient.Target] = [:]
        var functionSpots: [String: RustPropCapabilityClient.Target] = [:]
        let measure: @MainActor @Sendable (RustPropCapabilityClient.Probe) -> RustPropCapabilityClient.Measurement = { [weak self] probe in
            guard let self, self.capabilityGeneration == generation,
                  self.collisionWorld.revision == collisionRevision else {
                return .init(key: probe.key, position: probe.position, grounded: nil, canTraverse: false)
            }
            let grounded = self.groundedPosition(probe.position, in: self.collisionWorld)
            let traversable = probe.from.flatMap { from in grounded.map { target in
                self.collisionWorld.canTraverse(self.capsule, from: from.simd, to: target.simd,
                    maximumStepHeight: self.maximumStepHeight)
            } } ?? false
            return .init(key: probe.key, position: probe.position, grounded: grounded, canTraverse: traversable)
        }
        let batch: RustPropCapabilityClient.BatchPhysics = { [weak self] probes in
            guard let self else { throw CancellationError() }
            return try await self.measureNativePhysics(probes)
        }
        for objectID in objects.keys.sorted() {
            guard let item = objects[objectID] else { continue }
            guard item.isEnabled,
                  let prop = item.generatedProp, prop.objectID == objectID
            else { continue }
            let destination = try await rustPropCapability.resolve(worldID: manifest.worldID,
                hostSessionID: rustWorldActivity.hostSessionID, objectID: objectID, layoutRevision: layoutRevision,
                kind: "objectDestination", capsuleRadius: capsule.radius, waypoints: manifest.waypoints, physics: measure, batchPhysics: batch)
            try current()
            if let target = destination.target { spots[objectID] = target }
            guard item.propCapability != nil else { continue }
            let capability = try await rustPropCapability.resolve(worldID: manifest.worldID,
                hostSessionID: rustWorldActivity.hostSessionID, objectID: objectID, layoutRevision: layoutRevision,
                kind: "capability", capsuleRadius: capsule.radius, waypoints: manifest.waypoints, physics: measure, batchPhysics: batch)
            try current()
            guard let definition = capability.definition, let binding = capability.usageBinding,
                  let templateID = binding["templateID"], binding["objectID"] == objectID,
                  let entry = capability.target else { continue }
            let activity = PropActivity(
                definition: definition,
                objectID: objectID,
                templateID: templateID,
                entryWaypointID: entry.waypointID,
                approachPoint: entry.approachPoint,
                targetYaw: entry.targetYaw,
                functionPointAnchorID: nil,
                functionPointPosition: nil,
                origin: .boundCapability
            )
            rebuilt[activity.definition.id] = activity
        }
        for activityID in propAnchorRegistry.registeredActivityIDs {
            guard let anchor = propAnchorRegistry.entry(activityID: activityID),
                  let definition = authoredActivityCatalog.definition(id: activityID)
            else { continue }
            let resolved = try await rustPropCapability.approach(worldID: manifest.worldID,
                hostSessionID: rustWorldActivity.hostSessionID, objectID: anchor.objectID,
                layoutRevision: layoutRevision, kind: "functionPoint", role: anchor.role,
                activityID: activityID, waypoints: manifest.waypoints, physics: measure, batchPhysics: batch)
            try current()
            guard let entry = resolved.target else { continue }
            functionSpots[anchor.id] = entry
            rebuilt[activityID] = PropActivity(
                definition: definition,
                objectID: anchor.objectID,
                templateID: activityID,
                entryWaypointID: entry.waypointID,
                approachPoint: entry.approachPoint,
                targetYaw: entry.targetYaw,
                functionPointAnchorID: anchor.id,
                functionPointPosition: resolved.position,
                origin: .functionPointAnchor
            )
        }
        for (objectID, item) in simulation.state.objectStates {
            // Raw generated-object facts only; Rust owns seat eligibility and projection.
            guard item.isEnabled, item.generatedProp != nil else { continue }
            let resolved = try await rustPropCapability.approach(worldID: manifest.worldID,
                hostSessionID: rustWorldActivity.hostSessionID, objectID: objectID,
                layoutRevision: layoutRevision, kind: "seat", role: nil, activityID: nil,
                waypoints: manifest.waypoints, physics: measure, batchPhysics: batch)
            try current()
            guard let entry = resolved.target, let seat = resolved.seatProjection,
                  seat.objectID == objectID, let definition = resolved.definition else { continue }
            rebuilt[seat.activityID] = PropActivity(definition: definition, objectID: objectID,
                templateID: "seat.sit", entryWaypointID: entry.waypointID,
                approachPoint: entry.approachPoint, targetYaw: entry.targetYaw,
                functionPointAnchorID: nil, functionPointPosition: nil, origin: .seatCalibration)
            seats[seat.activityID] = seat
        }
        // Registered device anchors intentionally replace their authored
        // definitions. Including both copies makes ActivityCatalog reject the
        // entire merge, silently dropping dynamic seat/capability contracts.
        let dynamic = rebuilt.values.map(\.definition).sorted { $0.id < $1.id }
        let definitions = try await rustPropCapability.merge(authored: authoredActivityCatalog.definitions, dynamic: dynamic)
        try current()
        let catalog = try ActivityCatalog(definitions: definitions)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bindings = rebuilt.compactMapValues { activity -> [String: String]? in
                guard activity.origin == .boundCapability,
                      state.objectStates[activity.objectID]?.generatedProp != nil else { return nil }
                return ["objectID": activity.objectID, "templateID": activity.templateID]
            }
            var input = try encoder.encode(catalog.definitions)
            input.append(try encoder.encode(bindings))
            if rustCatalogInput != input {
                let receipt = try await rustPropCapability.bindCatalog(worldID: manifest.worldID,
                    hostSessionID: rustWorldActivity.hostSessionID, definitions: catalog.definitions,
                    waypoints: manifest.waypoints, usageBindings: bindings,
                    routes: manifest.routes, authoredActivities: manifest.activities)
                try current()
                try rustWorldActivity.acceptConfirmedCatalog(receipt)
                rustCatalogInput = input
            }
        }
        try current()
        seatProjections = seats; propActivities = rebuilt; confirmedOperationSpots = spots
        confirmedFunctionPointSpots = functionSpots
        confirmedDevicePlaces = devicePlaces; confirmedDevicePlaceLayoutRevision = layoutRevision
        confirmedCapabilityCollisionRevision = collisionRevision
        generatedPlacesCache = nil
        combinedActivityCatalog = catalog; activityCatalogFault = nil
        onSnapshotChanged?(snapshot)
    }

    /// 从（声明 × 摆放）重新派生注册表。
    ///
    /// 派生失败 ⇒ **保留旧注册表**并记下原因：注册表是纯值，失败时旧值仍然完整可用，
    /// 所以不可能出现"一半锚点是新的一半是旧的"。这是移动/收回/换世界/加载存档
    /// 共用的同一条回滚语义。
    private func rebuildPropAnchorRegistry() {
        do {
            propAnchorRegistry = try WorldPropAnchorRegistry.derive(
                sources: propFunctionSources,
                objectStates: simulation.state.objectStates
            )
            propAnchorRegistryFault = nil
        } catch let error as WorldPropAnchorError {
            propAnchorRegistryFault = error
            Self.log.error("道具功能点注册失败，保留上一份注册表：\(String(describing: error), privacy: .public)")
        } catch {
            Self.log.error("道具功能点注册失败：\(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "gmgn.world", category: "prop-anchors")

    /// Contact point stays explicit; agentTransform is the safe approach capsule.
    /// Unity projects the actual animated pelvis onto this calibrated seat.
    var activeSeatProjection: WorldPropSeatProjection? {
        guard let active = runningActivity, active.phase == .loop,
              let seat = seatProjections[active.id],
              confirmedCapabilityCollisionRevision == collisionWorld.revision
        else { return nil }
        return seat
    }

    /// An acknowledged Rust target only. Snapshot/frame reads never perform HTTP or choose a destination.
    private func resolvedOperationSpot(
        objectID: String
    ) -> (waypointID: String, approachPoint: WorldVector3?, standPoint: WorldVector3)? {
        guard confirmedCapabilityCollisionRevision == collisionWorld.revision,
              let target = confirmedOperationSpots[objectID] else { return nil }
        return (target.waypointID, target.approachPoint, target.standPoint)
    }

    /// 这件活动是不是**生成物件绑定的能力模板**活动。只有它才有"回执驱动的进入动作"，
    /// 也才受"当前 avatar 格式必须有匹配的已批准动作"这条门禁。
    ///
    /// 判据必须是**来源**：649e425 之后 `propActivities` 同时装着两类活动（生成物件能力、
    /// 世界固有设备的功能点锚点），按"在不在这个字典里"分类会让设备活动被生成物件的规则
    /// 审查 —— `wish_machine.collect` / `music.listen` 的进入阶段本来就 `motionIDs == []`，
    /// 于是被判成"缺动作、不可用"，居民永远无法进入领取活动。
    func isPropCapabilityActivity(_ activityID: String) -> Bool {
        propActivities[activityID]?.origin == .boundCapability
    }

    /// 这件活动是不是**世界固有设备声明的功能点锚点**活动（几何来自运行时注册表）。
    func isRegisteredFunctionPointActivity(_ activityID: String) -> Bool {
        propActivities[activityID]?.origin == .functionPointAnchor
    }

    func propActivityIDs(objectID: String) -> [String] {
        propActivities.values
            .filter { $0.objectID == objectID }
            .map(\.definition.id)
            .sorted()
    }

    var state: WorldState { simulation.state }
    /// The simulation's retained event window (session marker + newest events,
    /// bounded by `WorldSimulation.retainedEventCapacity`). Read-through for
    /// introspection and tests only; observation delivery goes through the
    /// sequence cursor in `publishObservations`.
    var events: [WorldEvent] { simulation.events }

    func updateWalkingSpeed(_ speed: Float) {
        guard speed.isFinite, speed >= 0 else { return }
        walkingSpeed = speed
        activityExecutor.updateWalkingSpeed(speed)
    }

    /// Adopt a verified Rust readback after another owned service commits layout.
    /// This method never persists or replays a command. The old movement executor
    /// is discarded so it cannot continue writing from a replaced revision.
    func readPersistedAuthorityState() async throws -> WorldState? {
        guard let persistence else { return nil }
        // Adoption can reject an external activity. Reading must leave the
        // checkpoint lease unchanged until that validation has succeeded.
        return try await Task.detached(priority: .utility) { try persistence.readSnapshot() }.value
    }

    /// Verify durable facts without accepting a newer checkpoint lease.
    func readAuthoritySnapshot() async throws -> WorldState? {
        guard let persistence else { return nil }
        return try await Task.detached(priority: .utility) { try persistence.readSnapshot() }.value
    }

    func acceptAuthoritySnapshot(_ adopted: WorldState) async throws {
        guard let persistence else { return }
        try await Task.detached(priority: .utility) { try persistence.acceptSnapshot(adopted) }.value
    }

    var nativePropActivityBindingSources: [String: (objectID: String, metadataKey: String)] {
        propActivities.mapValues { activity in
            let key: String = switch activity.origin {
            case .boundCapability: "gmgn.prop-capability.v1"
            case .functionPointAnchor: "gmgn.prop-function-points.v1"
            case .seatCalibration: "gmgn.prop-seat.v1"
            }
            return (activity.objectID, key)
        }
    }

    func rustPropAuthoritySnapshot(client: RustWorldPropClient, identity: RustWorldPropClient.Identity) async throws -> (WorldState, UInt64) {
        struct Snapshot: Decodable {
            struct Record: Decodable { let state: WorldState; let recordRevision: UInt64 }
            let record: Record
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(Snapshot.self, from:await client.snapshot(identity))
        guard snapshot.record.state.worldID == manifest.worldID, identity.worldID == manifest.worldID else {
            throw RustWorldPropError.invalidResponse
        }
        return (snapshot.record.state, snapshot.record.recordRevision)
    }

    func adoptRustPropReceipt(_ data: Data) async throws {
        struct Snapshot: Decodable { struct Record: Decodable { let state: WorldState }; let record: Record }
        struct Receipt: Decodable { let snapshot: Snapshot }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let receipt = try decoder.decode(Receipt.self, from:data)
        guard receipt.snapshot.record.state.worldID == manifest.worldID,
              let latest = try await readAuthoritySnapshot() else { throw RustWorldPropError.invalidResponse }
        try adoptAuthorityState(latest, propFunctionSources:propFunctionSources,
            replacingUncommittedProjection:true)
        try await acceptAuthoritySnapshot(latest)
    }

    /// Rust owns the reduction; native measurements do not authorize a mutation.
    func executeRustPropTool(_ name: String, callID: String, arguments: Data,
                             client: RustWorldPropClient, identity: RustWorldPropClient.Identity,
                             nativeFacts: @MainActor () async throws -> Data,
                             isCurrent: @MainActor () -> Bool) async throws -> Data {
        guard identity.worldID == manifest.worldID, isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if name == "read_owned_props" {
            let raw = try await client.read(identity)
            var result = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
            result["ok"] = true; result["layout_revision"] = result["layoutRevision"]
            result["can_undo"] = result["canUndo"]
            if let rows = result["objects"] as? [[String: Any]] {
                result["objects"] = rows.map { row in
                    var projected = row
                    projected["object_id"] = row["objectID"]
                    if let prop = row["prop"] as? [String: Any] {
                        projected["name"] = prop["displayName"]
                        projected["asset_id"] = prop["assetID"]
                    }
                    return projected
                }
            }
            return try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        }
        let mutations: Set<String> = ["apply_prop_placement","withdraw_prop","undo_prop_placement","hold_prop",
            "adjust_held_prop_grip","return_held_prop","drop_held_prop","delete_prop","enable_prop_capability","resize_prop"]
        guard mutations.contains(name) || name == "preview_prop_placement" || name == "list_placement_surfaces" else {
            throw RustWorldPropError.rejected("world_prop_operation_not_migrated")
        }
        let dispatch = ResidentWorldToolSession.rustDispatchAuthority
        if mutations.contains(name) {
            guard let dispatch, dispatch.worldID == identity.worldID, dispatch.residentScope == identity.residentScope,
                  dispatch.hostSessionID == identity.hostSessionID, dispatch.callID == callID,
                  dispatch.toolName == name else { throw RustWorldPropError.rejected("world_prop_unauthorized") }
        }
        struct Snapshot: Decodable {
            struct Record: Decodable { let recordRevision: UInt64; let state: WorldState }
            let record: Record
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(Snapshot.self, from: await client.snapshot(identity))
        guard snapshot.record.state.worldID == identity.worldID, isCurrent() else { throw CancellationError() }
        let needsGeometry = !["delete_prop","withdraw_prop","enable_prop_capability"].contains(name)
        var geometryID: String?
        if needsGeometry {
            let facts = try await nativeFacts()
            let observed = try await client.observe(identity, expectedRevision: snapshot.record.recordRevision,
                layoutRevision: snapshot.record.state.layoutRevision, facts: facts)
            geometryID = observed.geometryID
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if name == "list_placement_surfaces", let geometryID { return try await client.surfaces(identity, geometryID: geometryID) }
        if name == "preview_prop_placement" {
            guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
                  let object = args["object_id"] as? String, let surface = args["surface_id"] as? String,
                  let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber,
                  let z = args["z"] as? NSNumber, let yaw = args["yaw"] as? NSNumber else {
                throw RustWorldPropError.rejected("world_prop_invalid_input")
            }
            let command = try JSONSerialization.data(withJSONObject: ["op":"place","objectID":object,
                "surfaceID":surface,"position":[x,y,z],"yaw":yaw])
            guard let geometryID else { throw RustWorldPropError.invalidResponse }
            return try await client.preview(identity, expectedRevision: snapshot.record.recordRevision,
                layoutRevision: snapshot.record.state.layoutRevision, geometryID: geometryID, command: command)
        }
        guard let dispatch else { throw RustWorldPropError.rejected("world_prop_unauthorized") }
        let authority = RustWorldPropClient.AgentAuthority(identity:identity, runID:dispatch.runID,
            callID:dispatch.callID, operationID:dispatch.operationID)
        do {
            let raw = try await client.command(authority, expectedRevision:snapshot.record.recordRevision,
                layoutRevision:snapshot.record.state.layoutRevision, geometryID:geometryID,
                requestID:"agent:\(dispatch.runID):\(dispatch.callID):\(dispatch.operationID)")
            struct Mutation: Decodable { let snapshot: Snapshot }
            let mutation = try decoder.decode(Mutation.self, from: raw)
            guard mutation.snapshot.record.state.worldID == identity.worldID, isCurrent() else { throw CancellationError() }
            try adoptAuthorityState(mutation.snapshot.record.state, propFunctionSources: propFunctionSources,
                replacingUncommittedProjection:true)
            try await acceptAuthoritySnapshot(mutation.snapshot.record.state)
            return raw
        } catch RustWorldPropError.rejected(let code) { throw RustWorldPropError.rejected(code) }
        catch { throw RustWorldPropError.executionUnknown }
    }

    func adoptAuthorityState(_ restored: WorldState, propFunctionSources sources: [WorldPropFunctionSource],
                             replacingUncommittedProjection: Bool = false) throws {
        guard restored.worldID == manifest.worldID else {
            throw WorldAgentContextError.restoredWorldMismatch(expected: manifest.worldID, actual: restored.worldID)
        }
        guard replacingUncommittedProjection || restored.revision >= state.revision else { return }
        let preservesActivity = restored.activeActivity == state.activeActivity
            && currentActivityRequestID != nil
        if rustWorldActivity == nil, let active = restored.activeActivity, !preservesActivity {
            // An external active run has no renderer lease in this context.
            // It must be restored by the normal bootstrap, not invented here.
            throw WorldAgentContextError.activityRejected(active.activityID)
        }
        let registered = sources.filter {
            let item = restored.objectStates[$0.declaration.objectID]
            return item?.isEnabled == true && item?.functionPointDeclaration == nil
        }
        let registry = try WorldPropAnchorRegistry.derive(sources: registered, objectStates: restored.objectStates)
        simulation = WorldSimulation(restoring: restored)
        propFunctionSources = registered
        propAnchorRegistry = registry
        propAnchorRegistryFault = nil
        movement = nil
        patrol = nil
        activityPhaseElapsed = 0
        collisionWorld.replace(with: layoutCollisionWorld(for: restored))
        if !preservesActivity {
            activityExecutor = ActivityExecutor(position: restored.agentTransform.position,
                yaw: Self.yaw(of: restored.agentTransform.rotation), walkingSpeed: walkingSpeed,
                collisionQuery: collisionWorld, capsule: capsule, maximumStepHeight: maximumStepHeight)
        }
        rebuildPropActivities()
        navigationTraversalCache.removeAll(keepingCapacity: true)
        lastCheckpointWorldTime = restored.worldTime
        onSnapshotChanged?(snapshot)
    }

    /// Inventory confirmation adopts durable layout, never an archived actor run.
    /// Keep the current renderer lease, movement and activity executor intact.
    func adoptAuthorityInventoryLayout(_ restored: WorldState,
                                      propFunctionSources sources: [WorldPropFunctionSource]) throws {
        guard restored.worldID == manifest.worldID else {
            throw WorldAgentContextError.restoredWorldMismatch(expected: manifest.worldID, actual: restored.worldID)
        }
        guard restored.layoutRevision >= state.layoutRevision else {
            throw WorldPropLayoutError.staleRevision(submitted: restored.layoutRevision, current: state.layoutRevision)
        }
        var merged = state
        merged.revision = max(state.revision, restored.revision)
        merged.objectStates = restored.objectStates
        merged.layoutRevision = restored.layoutRevision
        merged.layoutReceipts = restored.layoutReceipts
        merged.layoutUndo = restored.layoutUndo
        merged.heldProp = restored.heldProp
        merged.propTombstones = restored.propTombstones
        let registered = sources.filter {
            let item = merged.objectStates[$0.declaration.objectID]
            return item?.isEnabled == true && item?.functionPointDeclaration == nil
        }
        let registry = try WorldPropAnchorRegistry.derive(sources: registered, objectStates: merged.objectStates)
        simulation = WorldSimulation(restoring: merged)
        propFunctionSources = registered
        propAnchorRegistry = registry
        propAnchorRegistryFault = nil
        collisionWorld.replace(with: layoutCollisionWorld(for: merged))
        rebuildPropActivities()
        navigationTraversalCache.removeAll(keepingCapacity: true)
        onSnapshotChanged?(snapshot)
    }

    func completeActivityPlayback(requestID: String, phase: LifeActivityPhase) throws {
        if let rustWorldActivity {
            guard let run = rustWorldActivity.running, run.requestID == requestID, run.phase == phase else { return }
            do { try applyRustActivityReceipt(run: run, kind: "clipCompleted") }
            catch WorldAuthorityError.daemon(let code) where code == "world_activity_infinite_loop" { return }
            return
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    func failActivityPlayback(requestID: String, phase: LifeActivityPhase) throws {
        if let rustWorldActivity {
            guard let run = rustWorldActivity.running, run.requestID == requestID, run.phase == phase else { return }
            try applyRustActivityReceipt(run: run, kind: "failed")
            return
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    func failMovementPlayback(requestID: String) throws {
        guard let run = movement, run.requestID == requestID else { return }
        if let rustWorldActivity, let authorityRun = rustWorldActivity.movement,
           authorityRun.requestID == requestID {
            try applyRustActivityReceipt(run: authorityRun, kind: "failed")
            return
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    /// 建造模式派生格子用的几何入口 —— 交出去的是**世界几何**（`baseCollisionWorld`：
    /// 环境网格 + manifest 里那批固定家具体积），**不是** `collisionWorld`（后者在 base
    /// 之上又叠了 `WorldLayoutObstacles.resolve(state)` 的**已摆物件**体积，那是运行时
    /// 拦人用的）。拿不到几何时返回 nil，调用方必须按 fail-closed 处理（不能摆放）。
    ///
    /// **为什么已摆物件的体积不许进派生世界**（真机 2026-10-01「舱室里什么都摆不了」）：
    /// `PropLayoutCollisionWorld.canTraverse`（本文件 `1406-1416`）会沿着移动线段**采样
    /// 已摆物件的体积**，而承托网格的连通性过滤问的正是它 —— 于是一件已摆物件会把它
    /// **自己脚下那一列**从网格里挤掉。实测（真权威快照 + 真舱体几何）：斧头在
    /// `(-2.625, -0.058583736, -2.375)`，列 `(-11,-10)` 整列没有承托层（0 层）；
    /// 同一份几何下不把它的体积算进去，那一列立刻恢复 `[-0.058583736]`。而
    /// `ResidentPropPlacementService.validate` 每次提交都会复算**房间里每一件**已摆物件
    /// 的位置（那正是它该做的）⇒ 复算到斧头必然 `.unknownSurface` ⇒ 任何一次 `place`
    /// 都被拒，且与"你想摆的那一件"毫无关系。
    ///
    /// 排除的是**这一类可移动体积**，所以每件物件自己的体积按构造就不在自己（也不在别人）
    /// 的承托/可达判定里。**判据一个字都没放宽**：真正回答"别人挡不挡它"的两条判据原样
    /// 保留，而且 `validate` 对**全部**已摆物件跑：
    /// 1. `PropPlacementEvaluator.evaluate` 的 `placedObstacles` OBB 互斥（那里传的是
    ///    `placed.filter { $0.0 != id }`，即除自己以外的每一件已摆物件）；
    /// 2. `WorldPlacementRouteMap.decision(blockedNodes:)`（占位节点由**全部**已摆物件的
    ///    `blockedNodes(obstacle:)` 给出）。
    /// 运行时拦人那条路一个字没动：`collisionWorld` 里装的仍然是含已摆物件体积的那一份。
    /// 这一份也正是 `PropSupportGrid` 自己的声明（"承托结构只依赖几何，建一次即可缓存"，
    /// 见 `PropSupportGrid.swift` 的类型说明），以及 `ResidentPropGridEditorModel` 的网格
    /// 缓存键（worldID）成立的前提。
    var propSupportQuerying: (any WorldPropSupportQuerying)? {
        baseCollisionWorld as? any WorldPropSupportQuerying
    }

    func installCollisionWorld(_ world: any WorldCollisionQuerying) {
        navigationTraversalCache.removeAll(keepingCapacity: true)
        baseCollisionWorld = world
        collisionWorld.replace(with: layoutCollisionWorld(for: state))
        // Entry spots stand or fall with the installed environment, so the
        // discovered prop activities must be re-derived, not just at layout commits.
        rebuildPropActivities()
    }

    func layoutCollisionWorld(for state: WorldState) -> any WorldCollisionQuerying {
        if nativePhysics != nil { return baseCollisionWorld }
        return PropLayoutCollisionWorld(base: baseCollisionWorld,
            obstacles: WorldLayoutObstacles.resolve(state).obstacles)
    }

    /// Conservative horizontal clearance against the currently installed environment.
    /// Authored props use exact box checks in the placement service as well.
    func hasEnvironmentClearance(for volume: WorldCollisionVolume) -> Bool {
        let radius = max(0.02, sqrt(volume.halfExtents.x * volume.halfExtents.x + volume.halfExtents.z * volume.halfExtents.z))
        return baseCollisionWorld.canOccupy(WorldCapsule(radius: radius,
            height: volume.halfExtents.y * 2 + radius * 2),
            at: SIMD3(volume.center.x, volume.center.y - volume.halfExtents.y, volume.center.z))
    }

    /// Persistence is the commit point. No callback, renderer or physics sees an unsaved candidate.
    @discardableResult
    func commitPropLayout(_ command: WorldPropLayoutCommand, expectedLayoutRevision: UInt64,
                          requestID: String, validate: (WorldState) throws -> Void) throws -> WorldState {
        // Layout mutations must enter the typed Rust prop reducer.
        throw WorldAuthorityError.noAuthorityRecord
    }

    @discardableResult
    func installCollisionWorldAndReconcilePlacement(
        _ world: any WorldCollisionQuerying
    ) throws -> WorldVector3? {
        let world = PropLayoutCollisionWorld(base: world,
            obstacles: WorldLayoutObstacles.resolve(state).obstacles)
        let current = state.agentTransform.position
        let resolved = groundedPosition(current, in: world)
            ?? manifest.waypoints
                .filter(\.enabled)
                .compactMap { waypoint -> WorldVector3? in
                    groundedPosition(waypoint.position, in: world)
                }
                .min {
                    let firstDelta = SIMD3(
                        $0.x - current.x,
                        $0.y - current.y,
                        $0.z - current.z
                    )
                    let secondDelta = SIMD3(
                        $1.x - current.x,
                        $1.y - current.y,
                        $1.z - current.z
                    )
                    let firstDistance = firstDelta.x * firstDelta.x
                        + firstDelta.y * firstDelta.y
                        + firstDelta.z * firstDelta.z
                    let secondDistance = secondDelta.x * secondDelta.x
                        + secondDelta.y * secondDelta.y
                        + secondDelta.z * secondDelta.z
                    if firstDistance == secondDistance {
                        if $0.x != $1.x { return $0.x < $1.x }
                        if $0.z != $1.z { return $0.z < $1.z }
                        return $0.y < $1.y
                    }
                    return firstDistance < secondDistance
                }
        guard let resolved else {
            throw WorldAgentContextError.noWalkablePlacement
        }

        baseCollisionWorld = world.base
        collisionWorld.replace(with: world)
        navigationTraversalCache.removeAll(keepingCapacity: true)
        rebuildPropActivities()
        guard resolved != current else { return nil }

        let deltaX = resolved.x - current.x
        let deltaZ = resolved.z - current.z
        if deltaX * deltaX + deltaZ * deltaZ > 0.0001 {
            if rustWorldActivity != nil, state.activeActivity != nil { try stopActivity() }
            movement = nil
            patrol = nil
            activityPhaseElapsed = 0
        }

        let yaw = Self.yaw(of: state.agentTransform.rotation)
        try updateTransform(position: resolved, yaw: yaw, notify: false)
        activityExecutor.synchronizePlacement(position: resolved, yaw: yaw)
        try publish(forcePersistence: true)
        return resolved
    }

    /// 执行器**唯一**的一手事实：「现在真的在跑哪个活动、跑到哪个相位」。
    ///
    /// `snapshot.activeActivity` 不是这个问题的答案：它的 `id` 来自**模拟状态**
    /// （`simulation.state.activeActivity`），`phase` 来自**执行器**，两者可以描述不同的
    /// 东西 —— 执行器没有 run 时 `ActivityExecutor.status` 走安全待机回退，返回
    /// `activityID == nil` 与 `phase == .loop`。也就是说"相位是 loop"在什么都没跑的时候
    /// 也成立，`phase` 单独不构成"真的在跑"的证据。
    ///
    /// 领取这类"必须真的站在设备前"的判据要的是执行器这一份事实：没有 run 就**没有**
    /// 活动（`nil`），相位也只会是那个 run 自己的相位。
    var runningActivity: WorldAgentActiveActivitySnapshot? {
        if let rustWorldActivity {
            guard let run = rustWorldActivity.running else { return nil }
            return WorldAgentActiveActivitySnapshot(id: run.definition.id, activity: run.activity ?? run.definition.activity,
                phase: run.phase, seat: seatProjections[run.definition.id])
        }
        return nil
    }

    /// The same simulation/executor projection as the full snapshot, without
    /// resolving discovery places for callers that only need activity state.
    var activeActivitySnapshot: WorldAgentActiveActivitySnapshot? {
        runningActivity
    }

    var snapshot: WorldAgentSnapshot {
        let activeActivity = activeActivitySnapshot
        return WorldAgentSnapshot(
            revision: state.revision,
            worldID: state.worldID,
            displayName: manifest.displayName,
            worldTime: state.worldTime,
            weather: state.weather,
            agentTransform: state.agentTransform,
            liveCamera: state.liveCamera,
            activeActivity: activeActivity,
            movement: movement.map {
                WorldAgentMovementSnapshot(
                    destinationID: $0.path.destinationID,
                    waypointIDs: $0.path.waypointIDs,
                    nextWaypointIndex: $0.nextPointIndex,
                    totalLength: $0.path.totalLength
                )
            },
            completedGoalIDs: state.completedGoals.keys.sorted(),
            places: (manifest.waypoints
                .filter { $0.enabled && !$0.id.hasPrefix("wp.auto.") }
                .compactMap { waypoint -> WorldAgentPlaceSnapshot? in
                    guard confirmedDevicePlaceLayoutRevision == state.layoutRevision,
                          confirmedCapabilityCollisionRevision == collisionWorld.revision else { return nil }
                    let position: WorldVector3
                    if let binding = confirmedDevicePlaces[waypoint.id] {
                        guard let currentPosition = binding.position else { return nil }
                        position = currentPosition
                    } else { position = waypoint.position }
                    return WorldAgentPlaceSnapshot(
                        id: waypoint.id,
                        position: position,
                        arrivalRadius: waypoint.arrivalRadius
                    )
                }
                + generatedPlaceSnapshots()).sorted { $0.id < $1.id },
            activities: (manifest.activities.compactMap { anchor -> WorldAgentActivityOption? in
                // 道具功能点锚点**不在**这里出现：它们的几何来自运行时注册表，
                // 由下面的 `propActivities` 提供。这里只出世界固有锚点。
                guard let entryWaypointID = anchor.entryWaypointID else { return nil }
                return WorldAgentActivityOption(
                    id: anchor.id,
                    action: anchor.action,
                    entryPlaceID: entryWaypointID,
                    interruptible: anchor.interruptible
                )
            } + propActivities.values.map { propActivity in
                WorldAgentActivityOption(
                    id: propActivity.definition.id,
                    action: propActivity.definition.activity.typeID,
                    entryPlaceID: propActivity.entryWaypointID,
                    interruptible: propActivity.definition.interruptible,
                    seat: seatProjections[propActivity.definition.id]
                )
            })
            .sorted { $0.id < $1.id },
            cameras: manifest.cameras
                .map {
                    WorldAgentCameraOption(
                        id: $0.id,
                        transform: $0.transform,
                        fieldOfViewDegrees: $0.fieldOfViewDegrees
                    )
                }
                .sorted { $0.id < $1.id }
        )
    }

    func planRoute(to placeID: String) throws -> WorldPath {
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        guard confirmedDevicePlaceLayoutRevision == state.layoutRevision,
              confirmedCapabilityCollisionRevision == collisionWorld.revision else {
            throw WorldAgentContextError.routeBlocked(placeID)
        }
        if let item = state.objectStates[placeID], item.isEnabled, item.generatedProp != nil {
            guard let spot = generatedObjectSpot(placeID) else { throw WorldAgentContextError.routeBlocked(placeID) }
            let path = try waypointRoute(to: spot.waypointID)
            if let rustWorldActivity {
                return try rustWorldActivity.finalizeRoute(path, start: state.agentTransform.position,
                    destinationID: placeID, finalTarget: spot.approachPoint, destinationKind: "generated")
            }
            throw WorldAuthorityError.noAuthorityRecord
        }
        if let anchorID = devicePlaceAnchorID(placeID) {
            guard confirmedCapabilityCollisionRevision == collisionWorld.revision,
                  let spot = confirmedFunctionPointSpots[anchorID] else {
                throw WorldAgentContextError.routeBlocked(placeID)
            }
            let path = try waypointRoute(to: spot.waypointID)
            if let rustWorldActivity {
                return try rustWorldActivity.finalizeRoute(path, start: state.agentTransform.position,
                    destinationID: placeID, finalTarget: spot.approachPoint, destinationKind: "device")
            }
            throw WorldAuthorityError.noAuthorityRecord
        }
        return try waypointRoute(to: placeID)
    }

    private func generatedPlaceSnapshots() -> [WorldAgentPlaceSnapshot] {
        let revision = collisionWorld.revision
        let objects = state.objectStates
        if let cached = generatedPlacesCache,
           cached.collisionRevision == revision, cached.objects == objects {
            return cached.places
        }
        let places = objects.compactMap { objectID, item -> WorldAgentPlaceSnapshot? in
            guard item.isEnabled, let prop = item.generatedProp,
                  let spot = generatedObjectSpot(objectID) else { return nil }
            return WorldAgentPlaceSnapshot(id: objectID, position: spot.standPoint,
                                          arrivalRadius: 0.05, displayName: prop.displayName)
        }
        generatedPlacesCache = (objects, revision, places)
        return places
    }

    /// Dynamic object destinations use the saved transform and scaled footprint.
    /// A distant manifest waypoint is only a route leg, never the final destination.
    private func generatedObjectSpot(_ objectID: String)
        -> (waypointID: String, approachPoint: WorldVector3?, standPoint: WorldVector3)? {
        guard let item = state.objectStates[objectID], item.isEnabled,
              let prop = item.generatedProp, prop.objectID == objectID else { return nil }
        return resolvedOperationSpot(objectID: objectID)
    }

    /// Keep authored place IDs stable, but resolve device geometry from the saved placement.
    /// The trusted Rust catalog carries explicit authored bindings, never a seed-coordinate guess.
    private func devicePlaceAnchorID(_ placeID: String) -> String? {
        guard confirmedDevicePlaceLayoutRevision == state.layoutRevision,
              confirmedCapabilityCollisionRevision == collisionWorld.revision else { return nil }
        return confirmedDevicePlaces[placeID]?.anchorID
    }

    private func waypointRoute(to placeID: String) throws -> WorldPath {
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        guard manifest.waypoints.contains(where: { $0.id == placeID && $0.enabled }) else {
            throw WorldAgentContextError.unknownPlace(placeID)
        }
        let position = state.agentTransform.position.simd
        guard canTraverse(from: position, to: position) else {
            throw WorldAgentContextError.routeBlocked(placeID)
        }
        if let rustWorldActivity {
            return try rustWorldActivity.route(manifest: manifest, start: state.agentTransform.position,
                destinationID: placeID, canTraverse: cachedNavigationTraversal)
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    private func cachedNavigationTraversal(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Bool {
        let segment = NavigationSegment(start: start, end: end)
        if let cached = navigationTraversalCache[segment] { return cached }
        let result = canTraverse(from: start, to: end)
        navigationTraversalCache[segment] = result
        return result
    }

    private func canTraverse(from start: SIMD3<Float>, to target: SIMD3<Float>) -> Bool {
        guard let ground = collisionWorld.groundHeight(at: target), ground.isFinite else { return false }
        let destination = SIMD3(target.x, ground, target.z)
        return collisionWorld.canOccupy(capsule, at: destination)
            && collisionWorld.canTraverse(capsule, from: start, to: destination, maximumStepHeight: maximumStepHeight)
    }

    @discardableResult
    func move(to placeID: String) throws -> WorldPath {
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        let path = try planRoute(to: placeID)
        if let rustWorldActivity {
            guard let authority = persistence as? AuthorityWorldStatePersistence else { throw WorldAuthorityError.noAuthorityRecord }
            if authority.lastAppliedRevision == 0 { try authority.save(state) }
            let receipt = try rustWorldActivity.move(world: state, expectedRevision: authority.lastAppliedRevision,
                path: path, movementRequestID: UUID().uuidString)
            try adoptRustActivity(receipt)
            return path
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    /// Human XYZ editing shares the same grounded movement and durable owner as
    /// ordinary navigation. It never teleports a renderer or invents a floor.
    @discardableResult
    func move(to position: WorldVector3, requestID: String, expectedRevision: UInt64) throws -> WorldPath {
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        guard expectedRevision == state.revision else {
            throw WorldSimulationError.staleRevision(submitted: expectedRevision, current: state.revision)
        }
        guard !requestID.isEmpty, requestID.utf8.count <= 256 else { throw WorldCoordinateMovementError.invalidPosition }
        let path = try coordinateRoute(to: position, destinationID: "coordinate." + requestID)
        if let rustWorldActivity {
            guard let authority = persistence as? AuthorityWorldStatePersistence else { throw WorldAuthorityError.noAuthorityRecord }
            if authority.lastAppliedRevision == 0 { try authority.save(state) }
            let receipt = try rustWorldActivity.move(world: state, expectedRevision: authority.lastAppliedRevision,
                path: path, movementRequestID: requestID, coordinateTarget: path.points.last)
            try adoptRustActivity(receipt)
            return path
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    private func coordinateRoute(to position: WorldVector3, destinationID: String) throws -> WorldPath {
        if let rustWorldActivity {
            let ground = collisionWorld.groundHeight(at: position.simd)
            let measuredTarget = WorldVector3(x: position.x, y: ground ?? position.y, z: position.z)
            return try rustWorldActivity.coordinateRoute(manifest: manifest, start: state.agentTransform.position,
                target: position, destinationID: destinationID, ground: ground,
                occupable: ground?.isFinite == true && collisionWorld.canOccupy(capsule, at: measuredTarget.simd),
                startOccupable: canTraverse(from: state.agentTransform.position.simd, to: state.agentTransform.position.simd),
                canTraverse: cachedNavigationTraversal)
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    func startActivity(id: String, requestedAt: Date? = nil) throws {
        guard nativePhysics == nil else { throw RustPropCapabilityClient.Failure.unavailable }
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        if let activityCatalogFault { throw activityCatalogFault }
        if let rustWorldActivity {
            guard let authority = persistence as? AuthorityWorldStatePersistence else {
                throw WorldAuthorityError.noAuthorityRecord
            }
            if authority.lastAppliedRevision == 0 { try authority.save(state) }
            let receipt = try rustWorldActivity.start(world: state, expectedRevision: authority.lastAppliedRevision,
                definitionID: id, capsuleRadius: capsule.radius,
                waitsForRenderedCompletion: waitsForRenderedActivityCompletion?() == true,
                measureApproach: { probe in
                    let grounded = self.groundedPosition(probe.position, in: self.collisionWorld)
                    let traversable = probe.from.flatMap { from in grounded.map { target in
                        self.collisionWorld.canTraverse(self.capsule, from: from.simd, to: target.simd,
                            maximumStepHeight: self.maximumStepHeight)
                    } } ?? false
                    return .init(key: probe.key, position: probe.position, grounded: grounded, canTraverse: traversable)
                }, canTraverse: { self.canTraverse(from: $0, to: $1) })
            movement = nil; patrol = nil
            try adoptRustActivity(receipt)
            return
        }

        throw WorldAuthorityError.noAuthorityRecord
    }

    func startActivityMeasured(id: String) async throws {
        guard let rustWorldActivity, let rustPropCapability,
              let authority = persistence as? AuthorityWorldStatePersistence else { throw WorldAuthorityError.noAuthorityRecord }
        try await awaitConfirmedActivityCatalog()
        if let activityCatalogFault { throw activityCatalogFault }
        if authority.lastAppliedRevision == 0 { try authority.save(state) }
        let world=state, revision=authority.lastAppliedRevision, collisionRevision=collisionWorld.revision,
            generation=capabilityGeneration
        let receipt=try await rustWorldActivity.startMeasured(world:world,expectedRevision:revision,definitionID:id,
            capsuleRadius:capsule.radius,waitsForRenderedCompletion:waitsForRenderedActivityCompletion?() == true,
            transport:rustPropCapability,measure:{ [weak self] probes in
                guard let self, self.state.layoutRevision == world.layoutRevision,
                      self.collisionWorld.revision == collisionRevision, self.capabilityGeneration == generation else { throw CancellationError() }
                return try await self.measureNativePhysics(probes)
            },validate:{ [weak self] in
                guard let self, self.state.agentTransform == world.agentTransform,
                      self.state.activeActivity == world.activeActivity, self.state.layoutRevision == world.layoutRevision,
                      self.capabilityGeneration == generation, self.collisionWorld.revision == collisionRevision,
                      authority.lastAppliedRevision == revision else { throw CancellationError() }
            })
        guard state.worldID == world.worldID, state.layoutRevision == world.layoutRevision,
              collisionWorld.revision == collisionRevision, capabilityGeneration == generation else {
            // A dispatched start is not replayed after geometry changes. Its actual
            // authority snapshot remains recoverable by the normal observation path.
            throw CancellationError()
        }
        movement=nil; patrol=nil
        try adoptRustActivity(receipt)
    }

    private func measureNativePhysics(_ probes: [RustPropCapabilityClient.Probe]) async throws -> [RustPropCapabilityClient.Measurement] {
        try Task.checkCancellation()
        guard probes.count <= 4096, let rustWorldActivity else { throw RustPropCapabilityClient.Failure.unavailable }
        if probes.isEmpty { return [] }
        let worldID=state.worldID, layoutRevision=state.layoutRevision, generation=capabilityGeneration,
            collisionRevision=collisionWorld.revision
        let result: [RustPropCapabilityClient.Measurement]
        if let nativePhysics {
            result=try await nativePhysics(.init(worldID:worldID,hostSessionID:rustWorldActivity.hostSessionID,
                layoutRevision:layoutRevision,physicsGeneration:generation,probes:probes,
                capsuleRadius:capsule.radius,capsuleHeight:capsule.height))
        } else {
            result=probes.map { probe in
                let grounded=groundedPosition(probe.position,in:collisionWorld)
                let traversable=probe.from.flatMap { from in grounded.map { target in
                    collisionWorld.canTraverse(capsule,from:from.simd,to:target.simd,maximumStepHeight:maximumStepHeight)
                } } ?? false
                return .init(key:probe.key,position:probe.position,grounded:grounded,canTraverse:traversable)
            }
        }
        try Task.checkCancellation()
        guard state.worldID == worldID, state.layoutRevision == layoutRevision,
              capabilityGeneration == generation, collisionWorld.revision == collisionRevision,
              result.count == probes.count, zip(result,probes).allSatisfy({ $0.key == $1.key && $0.position == $1.position })
        else { throw RustPropCapabilityClient.Failure.invalidReceipt }
        return result
    }

    func stopActivity(reason: String? = nil) throws {
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        if let rustWorldActivity {
            movement = nil; patrol = nil; rustApproach = nil
            rustActivityDeadlineTask?.cancel(); rustActivityDeadlineTask = nil
            if let run = rustWorldActivity.running ?? rustWorldActivity.movement {
                try applyRustActivityReceipt(run: run, kind: "stopped", stop: true)
            } else if state.activeActivity != nil {
                guard let authority = persistence as? AuthorityWorldStatePersistence else { throw WorldAuthorityError.noAuthorityRecord }
                let receipt = try rustWorldActivity.stopUnknown(world: state, expectedRevision: authority.lastAppliedRevision)
                try adoptRustActivity(receipt)
            } else { try recordControlChange() }
            onActivityStopped?()
            return
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    func look(at placeID: String) throws {
        guard confirmedDevicePlaceLayoutRevision == state.layoutRevision,
              confirmedCapabilityCollisionRevision == collisionWorld.revision else {
            throw WorldAgentContextError.routeBlocked(placeID)
        }
        if let item = state.objectStates[placeID], item.isEnabled, item.generatedProp != nil {
            let origin = state.agentTransform.position
            try updateTransform(position: origin,
                yaw: atan2(item.transform.position.x - origin.x, item.transform.position.z - origin.z))
            return
        }
        guard let place = manifest.waypoints.first(where: { $0.id == placeID && $0.enabled }) else {
            throw WorldAgentContextError.unknownPlace(placeID)
        }
        let origin = state.agentTransform.position
        let target: WorldVector3
        if let binding = confirmedDevicePlaces[placeID] {
            guard let position = binding.position else { throw WorldAgentContextError.routeBlocked(placeID) }
            target = position
        } else { target = place.position }
        let yaw = atan2(target.x - origin.x, target.z - origin.z)
        try updateTransform(position: origin, yaw: yaw)
    }

    enum WorldControlSource: Equatable { case agent, ui }
    private var rustWorldControlBinding: (client: RustWorldControlClient, identity: RustWorldControlClient.Identity)?
    func bindWorldControl(client: RustWorldControlClient, identity: RustWorldControlClient.Identity) {
        guard identity.worldID == manifest.worldID else { return }
        rustWorldControlBinding = (client, identity)
    }
    func setWeather(_ weather: WorldWeather, source: WorldControlSource = .agent) async throws {
        try await setWeather(rawValue: weather.rawValue, source: source)
    }
    func setWeather(rawValue: String, source: WorldControlSource = .agent) async throws {
        try await performWorldControl(["op": "weather", "weather": rawValue], source: source)
    }
    func selectCamera(id: String, source: WorldControlSource = .agent) async throws {
        try await performWorldControl(["op": "camera", "cameraID": id], source: source)
    }
    func completeGoal(id: String, summary: String? = nil, source: WorldControlSource = .agent) async throws {
        var command: [String: Any] = ["op": "goal", "goalID": id]
        command["summary"] = summary.map { $0 as Any } ?? NSNull()
        try await performWorldControl(command, source: source)
    }
    private func performWorldControl(_ command: [String: Any], source: WorldControlSource) async throws {
        guard let binding = rustWorldControlBinding,
              let authority = persistence as? AuthorityWorldStatePersistence else { throw WorldAuthorityError.noAuthorityRecord }
        let dispatch = ResidentWorldToolSession.rustDispatchAuthority
        switch source {
        case .agent:
            guard let dispatch, dispatch.worldID == binding.identity.worldID,
                  dispatch.residentScope == binding.identity.residentScope,
                  dispatch.hostSessionID == binding.identity.hostSessionID else { throw RustWorldControlClient.Failure.unavailable }
        case .ui:
            guard dispatch == nil else { throw RustWorldControlClient.Failure.unavailable }
        }
        if authority.lastAppliedRevision == 0 { try authority.save(state) }
        let expectedRevision = authority.lastAppliedRevision
        let requestID = dispatch.map { "agent:\($0.runID):\($0.callID):\($0.operationID)" } ?? UUID().uuidString
        let receipt = try await binding.client.perform(identity: binding.identity, cameras: manifest.cameras,
            expectedRevision: expectedRevision, requestID: requestID,
            command: JSONSerialization.data(withJSONObject: command), agent: dispatch, uiRequested: source == .ui)
        guard rustWorldControlBinding?.identity == binding.identity, authority.lastAppliedRevision == expectedRevision,
              !Task.isCancelled else { throw RustWorldControlClient.Failure.invalidReceipt }
        try await acceptAuthoritySnapshot(receipt.snapshot.record.state)
        // The control reducer cannot move a native actor or undo time actually
        // observed while its HTTP request was in flight.
        var projected = receipt.snapshot.record.state
        projected.agentTransform = state.agentTransform
        projected.worldTime = state.worldTime
        projected.revision = max(projected.revision, state.revision)
        simulation = WorldSimulation(restoring: projected)
        let events = receipt.events.filter { $0.sequence > publishedRustFactSequence }
        if let last = events.last, let onRustEventsPublished {
            publishedRustFactSequence = last.sequence
            onRustEventsPublished(events)
        }
        onSnapshotChanged?(snapshot)
    }

    func tick(deltaTime: TimeInterval) throws {
        guard deltaTime.isFinite, deltaTime > 0 else {
            throw WorldAgentContextError.invalidTickDuration
        }

        let movementWasActive = movement != nil
        if movement == nil { nativeMovementProbeTask?.cancel(); nativeMovementProbeTask=nil; nativeMovementProof=nil }
        let activityBeforeTick = runningActivity
        var tickError: Error?
        do {
            _ = try simulation.advance(by: deltaTime, expectedRevision: state.revision,
                recordActivityElapsed: false)
            if movement != nil {
                try tickMovement(deltaTime: deltaTime)
            } else if state.activeActivity != nil {
                try tickActivity(deltaTime: deltaTime)
            }
        } catch {
            tickError = error
        }
        let activityAfterTick = runningActivity
        let movementCompleted = movementWasActive && movement == nil
        let activityPhaseChanged =
            activityBeforeTick?.id != activityAfterTick?.id
                || activityBeforeTick?.phase != activityAfterTick?.phase
        let actorIsMoving = movement != nil
            || activityAfterTick?.phase == .approach
        let shouldCheckpoint = movementCompleted
            || activityPhaseChanged
            || (actorIsMoving && isMovementCheckpointDue)
        try publish(forcePersistence: shouldCheckpoint)
        if let tickError { throw tickError }
    }

    func startTicking(interval: TimeInterval = 1.0 / 30.0) {
        tickingTask?.cancel()
        tickingTask = nil
        guard interval.isFinite, interval > 0 else { return }
        tickingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                do {
                    try self.tick(deltaTime: interval)
                } catch {
                    self.onTickError?(error)
                }
            }
        }
    }

    func stopTicking(checkpoint: Bool = true) {
        nativeMovementProbeTask?.cancel(); nativeMovementProbeTask=nil; nativeMovementProof=nil
        tickingTask?.cancel()
        tickingTask = nil
        guard checkpoint else { return }
        do {
            try saveCheckpoint()
        } catch {
            onTickError?(error)
        }
    }

    private func tickMovement(deltaTime: TimeInterval) throws {
        guard var run = movement else { return }
        guard let authorityRun = rustWorldActivity?.movement,
              authorityRun.requestID == run.requestID else { throw WorldAuthorityError.noAuthorityRecord }
        var remaining = walkingSpeed * Float(deltaTime)
        var position = state.agentTransform.position
        var yaw = Self.yaw(of: state.agentTransform.rotation)
        var didTurn = false

        while remaining > 0, run.nextPointIndex < run.path.points.count {
            let target = run.path.points[run.nextPointIndex]
            let delta = target.subtracting(position)
            let horizontalDistance = hypot(delta.x, delta.z)
            if !didTurn, horizontalDistance > 0.0001 {
                let targetYaw = atan2(delta.x, delta.z)
                let difference = atan2(sin(targetYaw-yaw), cos(targetYaw-yaw))
                yaw += max(-4.5 * Float(deltaTime), min(4.5 * Float(deltaTime), difference))
                didTurn = true
            }
            var destination: WorldVector3
            if horizontalDistance <= remaining || horizontalDistance <= 0.0001 {
                destination = target
            } else {
                let progress = remaining / horizontalDistance
                destination = WorldVector3(
                    x: position.x + delta.x * progress,
                    y: position.y,
                    z: position.z + delta.z * progress
                )
            }

            let nativeMeasurement: RustPropCapabilityClient.Measurement?
            if nativePhysics != nil {
                if let proof=nativeMovementProof,proof.runID==run.requestID,proof.index==run.nextPointIndex,
                   proof.layout==state.layoutRevision,proof.collision==collisionWorld.revision,
                   proof.generation==capabilityGeneration,proof.from==position {
                    destination=proof.target
                }
                guard let measured = try nativeMovementMeasurement(run: run, from: position, target: destination) else { break }
                nativeMeasurement = measured
            } else { nativeMeasurement = nil }
            let sampledGround = nativePhysics != nil ? nativeMeasurement?.grounded?.y : collisionWorld.groundHeight(at: destination.simd)
            guard let ground = sampledGround,
                  ground.isFinite
            else {
                try handleBlockedMovement(run, position: position, yaw: yaw)
                return
            }
            let groundedDestination = WorldVector3(
                x: destination.x,
                y: ground,
                z: destination.z
            )
            let nativeClear = nativeMeasurement?.canTraverse == true && nativeMeasurement?.grounded != nil
            guard nativePhysics != nil ? nativeClear : (collisionWorld.canOccupy(capsule, at: groundedDestination.simd)
                && collisionWorld.canTraverse(
                      capsule,
                      from: position.simd,
                      to: groundedDestination.simd,
                      maximumStepHeight: maximumStepHeight
                  ))
            else {
                try handleBlockedMovement(run, position: position, yaw: yaw)
                return
            }

            position = groundedDestination
            if destination.x == target.x && destination.z == target.z {
                remaining -= horizontalDistance
                run.nextPointIndex += 1
            } else {
                remaining = 0
            }
        }

        movement = run.nextPointIndex >= run.path.points.count ? nil : run
        if movement == nil, let item = state.objectStates[run.path.destinationID], item.isEnabled,
           item.generatedProp != nil {
            yaw = atan2(item.transform.position.x - position.x, item.transform.position.z - position.z)
        }
        if position != state.agentTransform.position || movement == nil {
            try updateTransform(position: position, yaw: yaw, notify: false)
        }
        if movement == nil {
            if let authorityRun = rustWorldActivity?.movement {
                do { try applyRustActivityReceipt(run: authorityRun, kind: "arrived") }
                catch { rustActivityReceiptFault = error; throw error }
                return
            }
            throw WorldAuthorityError.noAuthorityRecord
        }
    }
    /// One actual leg probe at a time. Awaiting physics never becomes a blocked receipt.
    private func nativeMovementMeasurement(run: MovementRun, from: WorldVector3,
                                           target: WorldVector3) throws -> RustPropCapabilityClient.Measurement? {
        guard let nativePhysics, let rustWorldActivity else { throw WorldAuthorityError.noAuthorityRecord }
        let layout=state.layoutRevision, collision=collisionWorld.revision, generation=capabilityGeneration
        if let proof=nativeMovementProof, proof.runID==run.requestID,proof.index==run.nextPointIndex,
           proof.layout==layout,proof.collision==collision,proof.generation==generation,proof.target==target,proof.from==from {
            if let result=proof.result {return try result.get()}
            return nil
        }
        nativeMovementProbeTask?.cancel()
        nativeMovementProof = .init(runID:run.requestID,index:run.nextPointIndex,layout:layout,collision:collision,generation:generation,from:from,target:target,result:nil)
        let request=NativePhysicsRequest(worldID:manifest.worldID,hostSessionID:rustWorldActivity.hostSessionID,
            layoutRevision:layout,physicsGeneration:generation,
            probes:[.init(key:"movement.leg",position:target,from:from)],capsuleRadius:capsule.radius,capsuleHeight:capsule.height)
        nativeMovementProbeTask=Task { @MainActor [weak self] in
            let result: Result<RustPropCapabilityClient.Measurement,Error>
            do {
                let facts=try await nativePhysics(request)
                guard facts.count==1,facts[0].key=="movement.leg",facts[0].position==target else {throw RustPropCapabilityClient.Failure.invalidReceipt}
                result = .success(facts[0])
            } catch { result = .failure(error) }
            guard let self,!Task.isCancelled,self.state.layoutRevision==layout,self.collisionWorld.revision==collision,
                  self.capabilityGeneration==generation,
                  self.movement?.requestID==run.requestID,self.movement?.nextPointIndex==run.nextPointIndex,
                  self.state.agentTransform.position==from else {return}
            self.nativeMovementProof?.result=result
            if case .failure(let error)=result {self.rustActivityReceiptFault=error;self.onSnapshotChanged?(self.snapshot)}
        }
        return nil
    }

    private func handleBlockedMovement(_ run: MovementRun, position: WorldVector3, yaw: Float) throws {
        navigationTraversalCache.removeAll(keepingCapacity: true)
        if position != state.agentTransform.position {
            try updateTransform(position: position, yaw: yaw, notify: false)
        }
        if let authorityRun = rustWorldActivity?.movement {
            movement = nil
            do { try applyRustActivityReceipt(run: authorityRun, kind: "blocked") }
            catch { rustActivityReceiptFault = error; throw error }
            return
        }
        throw WorldAuthorityError.noAuthorityRecord
    }

    private func groundedPosition(
        _ position: WorldVector3,
        in world: any WorldCollisionQuerying
    ) -> WorldVector3? {
        guard let ground = world.groundHeight(at: position.simd),
              ground.isFinite
        else {
            return nil
        }
        let resolved = WorldVector3(
            x: position.x,
            y: ground,
            z: position.z
        )
        return world.canOccupy(capsule, at: resolved.simd) ? resolved : nil
    }

    private func adoptRustActivity(_ receipt: RustWorldActivityClient.Mutation) throws {
        guard let record = receipt.snapshot?.record,
              let authority = persistence as? AuthorityWorldStatePersistence else {
            throw WorldAuthorityError.noAuthorityRecord
        }
        try authority.acceptSnapshot(record.state)
        simulation = WorldSimulation(restoring: record.state)
        let events = (receipt.events ?? []).filter { $0.sequence > publishedRustFactSequence }
        if let last = events.last, let onRustEventsPublished {
            publishedRustFactSequence = last.sequence
            onRustEventsPublished(events)
        }
        activityExecutor.synchronizePlacement(position: state.agentTransform.position,
            yaw: Self.yaw(of: state.agentTransform.rotation))
        rustActivityDeadlineTask?.cancel(); rustActivityDeadlineTask = nil
        rustActivityReceiptFault = nil
        rustApproach = nil
        movement = nil; patrol = nil
        if let run = rustWorldActivity?.movement, let rustWorldActivity {
            if run.status == "replanRequired" {
                let path: WorldPath
                do {
                    if let target = run.coordinateTarget { path = try coordinateRoute(to: target, destinationID: run.path.destinationID) }
                    else { path = try planRoute(to: run.path.destinationID) }
                } catch {
                    try applyRustActivityReceipt(run: run, kind: "failed")
                    return
                }
                try adoptRustActivity(rustWorldActivity.replan(world: state, expectedRevision: authority.lastAppliedRevision,
                    run: run, path: path))
                return
            }
            movement = MovementRun(requestID: run.requestID, path: run.path, nextPointIndex: 0,
                coordinateTarget: run.coordinateTarget)
        }
        if let run = rustWorldActivity?.running {
            if let yaw = run.alignmentYaw {
                try updateTransform(position: state.agentTransform.position, yaw: yaw, notify: false)
                try authority.save(state)
            }
            if let targets = run.patrolCandidates, let rustWorldActivity {
                var rejected: [String] = []
                for target in targets {
                    let route: WorldPath
                    do { route = try waypointRoute(to: target) }
                    catch WorldAuthorityError.daemon(let code) where code == "world_activity_unreachable" {
                        rejected.append(target); continue
                    }
                    let receipt = try rustWorldActivity.continuePatrol(world: state,
                        expectedRevision: authority.lastAppliedRevision, run: run,
                        targetID: target, path: route, rejectedTargets: rejected)
                    try adoptRustActivity(receipt)
                    return
                }
                try applyRustActivityReceipt(run: run, kind: "failed")
                return
            }
            if run.phase == .approach {
                rustApproach = MovementRun(requestID: run.requestID, path: run.path, nextPointIndex: 0)
            }
            if run.deadlineEligible, let deadline = run.deadlineMs {
                // Rust issues the deadline/eligibility; the host only schedules
                // one delivery. It never advances a phase during a frame tick.
                let delay = max(0, Double(deadline) / 1000 - Date().timeIntervalSince1970)
                rustActivityDeadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    guard !Task.isCancelled, let self,
                          let current = self.rustWorldActivity?.running,
                          current.requestID == run.requestID, current.generation == run.generation,
                          current.phaseGeneration == run.phaseGeneration else { return }
                    do { try self.applyRustActivityReceipt(run: current, kind: "deadline") }
                    catch { self.rustActivityReceiptFault = error; self.onTickError?(error) }
                }
            }
        }
        onSnapshotChanged?(snapshot)
    }

    private func applyRustActivityReceipt(run: RustWorldActivityClient.Run, kind: String, stop: Bool = false) throws {
        guard let rustWorldActivity, let authority = persistence as? AuthorityWorldStatePersistence else {
            throw WorldAuthorityError.noAuthorityRecord
        }
        let receipt = try rustWorldActivity.receipt(world: state, expectedRevision: authority.lastAppliedRevision,
            run: run, kind: kind, stop: stop)
        try adoptRustActivity(receipt)
    }

    private func tickRustActivityApproach(deltaTime: TimeInterval) throws {
        guard rustActivityReceiptFault == nil,
              let run = rustWorldActivity?.running, run.phase == .approach,
              var approach = rustApproach else { return }
        var position = state.agentTransform.position
        var yaw = Self.yaw(of: state.agentTransform.rotation)
        var remaining = walkingSpeed * Float(deltaTime)
        var faced = false
        while remaining > 0, approach.nextPointIndex < approach.path.points.count {
            let target = approach.path.points[approach.nextPointIndex]
            let delta = target.subtracting(position)
            let horizontal = hypot(delta.x, delta.z)
            if !faced, horizontal > 0.0001 {
                let targetYaw = atan2(delta.x, delta.z)
                let difference = atan2(sin(targetYaw-yaw), cos(targetYaw-yaw))
                yaw += max(-4.5 * Float(deltaTime), min(4.5 * Float(deltaTime), difference))
                faced = true
            }
            let reached = horizontal <= remaining || horizontal <= 0.0001
            let candidate = reached ? target : WorldVector3(x: position.x + delta.x * remaining / horizontal,
                y: position.y, z: position.z + delta.z * remaining / horizontal)
            guard let ground = collisionWorld.groundHeight(at: candidate.simd), ground.isFinite else {
                rustApproach = nil
                do { try applyRustActivityReceipt(run: run, kind: "failed") }
                catch { rustActivityReceiptFault = error; throw error }
                return
            }
            let next = WorldVector3(x: candidate.x, y: ground, z: candidate.z)
            guard collisionWorld.canOccupy(capsule, at: next.simd), canTraverse(from: position.simd, to: next.simd) else {
                rustApproach = nil
                do { try applyRustActivityReceipt(run: run, kind: "failed") }
                catch { rustActivityReceiptFault = error; throw error }
                return
            }
            position = next
            if reached { remaining -= horizontal; approach.nextPointIndex += 1 }
            else { remaining = 0 }
        }
        rustApproach = approach
        if approach.nextPointIndex >= approach.path.points.count {
            if let targetYaw = run.targetYaw { yaw = targetYaw }
            try updateTransform(position: position, yaw: yaw, notify: false)
            // Consume once even if RPC fails. An error freezes this request;
            // idle frames must not hammer the authority or revive an old run.
            rustApproach = nil
            do { try applyRustActivityReceipt(run: run, kind: "arrived") }
            catch { rustActivityReceiptFault = error; throw error }
        } else {
            try updateTransform(position: position, yaw: yaw, notify: false)
        }
    }

    private func tickActivity(deltaTime: TimeInterval) throws {
        guard rustWorldActivity != nil else { throw WorldAuthorityError.noAuthorityRecord }
        try tickRustActivityApproach(deltaTime: deltaTime)
    }



    private func updateTransform(
        position: WorldVector3,
        yaw: Float,
        notify: Bool = true
    ) throws {
        let old = state.agentTransform
        let transform = WorldTransform(
            position: position,
            rotation: Self.rotation(yaw: yaw),
            scale: old.scale
        )
        _ = try simulation.updateAgentTransform(transform, expectedRevision: state.revision)
        if notify { try publish(forcePersistence: true) }
    }

    private func recordControlChange() throws {
        _ = try simulation.advance(by: 0, expectedRevision: state.revision)
        try publish(forcePersistence: true)
    }

    private var isMovementCheckpointDue: Bool {
        guard persistence != nil else { return false }
        guard let lastCheckpointWorldTime else { return true }
        return state.worldTime.timeIntervalSince(lastCheckpointWorldTime) >= 1
    }

    private func publish(forcePersistence: Bool) throws {
        publishObservations()
        onSnapshotChanged?(snapshot)
        if forcePersistence {
            try saveCheckpoint()
        }
    }

    private func publishObservations() {
        // Keep the cursor until an observer is attached, including the initial load fact.
        guard let onEventsPublished else { return }
        let retained = simulation.events
        // Real retained events were evicted from the fixed-capacity window before
        // this context's cursor reached them: the consumer lagged beyond the cache.
        // Clock events consume sequence numbers between retained events, so only the
        // simulation's explicit eviction counter can distinguish an honest gap from
        // ordinary clock noise.
        let missedRetained = simulation.trimmedNewestSequence
            .map { (publishedSequence ?? 0) < $0 } ?? false
        // Scan the retained window strictly after the cursor. On an eviction gap the
        // historical session marker (`.worldLoaded`/`.worldRestored`) fronts an
        // *incomplete* stream, so it is skipped and an explicit observation-gap
        // notice is delivered instead: handing the stale marker through unchanged
        // would masquerade a trimmed history as a complete one.
        var observations: [WorldEvent] = []
        if missedRetained, publishedSequence == nil {
            for event in retained.dropFirst() {
                observations.append(contentsOf: filteredDelivery(for: event))
            }
        } else {
            for event in retained {
                if let publishedSequence, event.sequence <= publishedSequence { continue }
                observations.append(contentsOf: filteredDelivery(for: event))
            }
        }
        if missedRetained {
            // Honest re-observation notice, never a fabricated world fact. The world
            // was NOT restored, so the resident must not be told it was: this marker
            // carries its own kind (`.observationGap`) and `ResidentWorldObservation`
            // maps it to an explicit `observation_gap` notice that says events were
            // lost and current state must be re-queried.
            //
            // The marker's sequence is the simulation's real eviction watermark
            // (`trimmedNewestSequence`): the highest sequence an evicted event
            // actually carried. That keeps the marker monotonic and inside the live
            // watermark range — no reserved top-of-`UInt64` band — while its resident
            // identity still cannot collide with `world:<scope>:<worldID>:<sequence>`
            // because the mapper namespaces the two id schemes separately. The marker
            // never enters the simulation log.
            if let trimmed = simulation.trimmedNewestSequence {
                observations.insert(
                    WorldEvent(
                        sequence: trimmed,
                        revision: state.revision,
                        worldTime: state.worldTime,
                        kind: .observationGap(worldID: state.worldID)
                    ),
                    at: 0
                )
            }
        }
        // Advance before either callback, because observers may synchronously mutate the world.
        if let newest = retained.last,
           publishedSequence.map({ newest.sequence > $0 }) ?? true {
            publishedSequence = newest.sequence
        }
        if !observations.isEmpty { onEventsPublished(observations) }
    }

    private func filteredDelivery(for event: WorldEvent) -> [WorldEvent] {
        switch event.kind {
        case .timeAdvanced, .timeCaughtUp, .agentTransformUpdated, .liveCameraChanged:
            return []
        default:
            return [event]
        }
    }

    private func saveCheckpoint() throws {
        guard let persistence else { return }
        try persistence.save(state)
        lastCheckpointWorldTime = state.worldTime
    }

    private static func yaw(of rotation: WorldQuaternion) -> Float {
        let numerator = 2 * (rotation.w * rotation.y + rotation.x * rotation.z)
        let denominator = 1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z)
        return atan2(numerator, denominator)
    }

    private static func rotation(yaw: Float) -> WorldQuaternion {
        WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2))
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

/// Generated props block bodies but never contribute a walkable top surface.
/// 摆放格子派生需要三角形几何。这个包装类型的地面与几何都来自 `base`，`props` 只是
/// 已放物件的阻挡**形状**（yaw 盒子或生成侧的碰撞代理）。转发给 `base`，拿不到就返回
/// 空数组 —— 理由与 `MarbleLivingCabinCollisionWorld` 的 conformance 相同：派生器会因此
/// 得到空网格（"不猜、不放行"），评估器会因此得到 `.noSupport`，两道都是 fail-closed。
///
/// 形状来自**唯一一份** `WorldLayoutObstacles.resolve`：于是运行时拦人的东西与摆放预检
/// 看到的完全同一批障碍（含碰撞代理），不存在"预检按盒子、运行时按代理"的分叉。
private struct PropLayoutCollisionWorld: WorldCollisionQuerying, WorldPropSupportQuerying {
    let base: any WorldCollisionQuerying
    let props: CollisionVolumeWorld
    init(base: any WorldCollisionQuerying, obstacles: [WorldPropObstacle]) {
        self.base = base; props = CollisionVolumeWorld(obstacles: obstacles)
    }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        base.canOccupy(capsule, at: position) && props.canOccupy(capsule, at: position)
    }
    func groundHeight(at position: SIMD3<Float>) -> Float? { base.groundHeight(at: position) }
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        (base as? any WorldPropSupportQuerying)?.triangles(in: bounds) ?? []
    }
    func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>, to end: SIMD3<Float>, maximumStepHeight: Float) -> Bool {
        guard base.canTraverse(capsule, from: start, to: end, maximumStepHeight: maximumStepHeight) else { return false }
        let distance = sqrt((end-start).x*(end-start).x + (end-start).y*(end-start).y + (end-start).z*(end-start).z)
        guard distance.isFinite, distance < 10_000 else { return false }
        let steps = max(1, Int(ceil(distance / max(0.01,capsule.radius/2))))
        for i in 0...steps {
            let p = start + (end-start) * (Float(i)/Float(steps))
            guard props.canOccupy(capsule, at: p) else { return false }
        }
        return true
    }
}

private extension WorldVector3 {
    var simd: SIMD3<Float> { SIMD3(x, y, z) }

    func adding(_ other: Self) -> Self {
        Self(x: x + other.x, y: y + other.y, z: z + other.z)
    }

    func subtracting(_ other: Self) -> Self {
        Self(x: x - other.x, y: y - other.y, z: z - other.z)
    }

    func scaled(by scalar: Float) -> Self {
        Self(x: x * scalar, y: y * scalar, z: z * scalar)
    }

    var length: Float { (x * x + y * y + z * z).squareRoot() }
}

private extension ActivityExecutionEffect {
    var requestsPath: Bool {
        if case .requestPath = self { true } else { false }
    }

    var isRejectedOrFailed: Bool {
        switch self {
        case .rejected, .failed: true
        default: false
        }
    }

    var movedPosition: WorldVector3? {
        if case let .moved(position) = self { position } else { nil }
    }

    var alignedYaw: Float? {
        if case let .aligned(yaw) = self { yaw } else { nil }
    }
}
