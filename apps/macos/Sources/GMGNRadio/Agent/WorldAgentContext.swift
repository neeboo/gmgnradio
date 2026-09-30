import Foundation
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
    case routeBlocked(String)
    case noWalkablePlacement
}

struct WorldAgentPlaceSnapshot: Codable, Equatable, Sendable {
    let id: String
    let position: WorldVector3
    let arrivalRadius: Float
}

struct WorldAgentActivityOption: Codable, Equatable, Sendable {
    let id: String
    let action: String
    let entryPlaceID: String
    let interruptible: Bool
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
    private struct MovementRun {
        let requestID: String
        var path: WorldPath
        var nextPointIndex: Int
        var replansRemaining = 1
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
        enum Origin { case boundCapability, functionPointAnchor }

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
    private var combinedActivityCatalog: ActivityCatalog?
    /// 世界包/资产声明的道具功能点来源。**锚点不落盘**：每次布局变化都从
    /// （声明 × 摆放）重新派生。
    let propFunctionSources: [WorldPropFunctionSource]
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
    var currentActivityRequestID: String? { activityExecutor.currentRequestID }
    var currentMovementRequestID: String? { movement?.requestID }
    private var movement: MovementRun?
    private var patrol: PatrolRun?
    private let executionScopeID = UUID().uuidString
    // Only planning uses this cache. Each actual movement step is checked again.
    private var navigationTraversalCache: [NavigationSegment: Bool] = [:]
    private var activityPhaseElapsed: TimeInterval = 0
    private let persistence: (any WorldStatePersisting)?
    private var walkingSpeed: Float
    private let capsule: WorldCapsule
    private let maximumStepHeight: Float
    private var tickingTask: Task<Void, Never>?
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
    var onTickError: (@MainActor (Error) -> Void)?

    init(
        manifest: WorldManifest,
        startedAt: Date = Date(),
        persistence: (any WorldStatePersisting)? = nil,
        walkingSpeed: Float = 1.2,
        capsule: WorldCapsule = WorldCapsule(radius: 0.2, height: 1.8),
        maximumStepHeight: Float = 0.3,
        propFunctionSources: [WorldPropFunctionSource] = []
    ) throws {
        self.manifest = manifest
        self.propFunctionSources = propFunctionSources
        navigationGraph = WaypointNavigationGraph(manifest: manifest)
        baseCollisionWorld = CollisionVolumeWorld(manifest: manifest)
        collisionWorld = ReplaceableCollisionWorld(
            initial: CollisionVolumeWorld(manifest: manifest)
        )
        authoredActivityCatalog = try ActivityCatalog(manifest: manifest)
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

        collisionWorld.replace(with: PropLayoutCollisionWorld(base: baseCollisionWorld,
            volumes: simulation.state.objectStates.values.compactMap(\.generatedCollisionVolume)))

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

        if let active = simulation.state.activeActivity,
           let restored = resolvedActivityPlan(activityID: active.activityID)
        {
            let request = ScheduledActivity(
                id: "\(executionScopeID)-restored-\(active.activityID)-\(active.startedAt.timeIntervalSince1970)",
                definitionID: active.activityID,
                activity: restored.definition.activity,
                priority: .autonomousIdle,
                requestedAt: active.startedAt
            )
            let effects = activityExecutor.start(
                request,
                definition: restored.definition,
                at: simulation.state.worldTime
            )
            if effects.contains(where: \.requestsPath) {
                let path = try navigationGraph.route(
                    from: transform.position.simd,
                    to: restored.entryWaypointID
                )
                var points = path.points
                if let approachPoint = restored.approachPoint { points.append(approachPoint) }
                _ = try activityExecutor.supplyApproach(
                    ActivityApproachPlan(
                        waypoints: points,
                        targetYaw: restored.targetYaw
                    )
                )
            }
            if active.activityID == "home.walk" {
                patrol = PatrolRun(targetID: restored.entryWaypointID)
            }
        } else if let active = simulation.state.activeActivity,
                  propActivities[active.activityID] == nil,
                  let stale = simulation.state.objectStates.first(where: { objectID, item in
                      // Map the stale run through the persisted capability, not
                      // through currently discoverable activities: the machine
                      // may have no operation spot at all after a restart.
                      guard let capability = item.propCapability else { return false }
                      return WorldPropActivityTemplate.activityID(
                          objectID: objectID, templateID: capability.templateID
                      ) == active.activityID
                  }),
                  let capability = stale.value.propCapability {
            // The operation spot no longer resolves after a restart (layout or
            // collision changed while stopped). End the phantom run: a prop
            // usage nothing can ever finish must not survive as "running".
            let reason = "重启后无法到达物件操作位点"
            _ = try? simulation.cancelActivity(reason: reason,
                expectedRevision: simulation.state.revision)
            _ = try? simulation.recordPropUsage(objectID: stale.key,
                usage: WorldPropUsageState(templateID: capability.templateID, status: .stopped,
                    activityRequestID: "restored", updatedAt: simulation.state.worldTime, reason: reason),
                expectedRevision: simulation.state.revision)
            try? publish(forcePersistence: true)
        }
    }

    /// Resolves an activity against **registered prop function-point anchors**
    /// first, then bound prop capabilities, then the authored manifest.
    ///
    /// 「活动规划只认注册出来的锚点」：道具功能点锚点的几何只有注册表知道，
    /// `manifest.activities` 那一行**不含**任何几何（见 `WorldActivityEntry`）。
    private func resolvedActivityPlan(
        activityID: String
    ) -> (definition: LifeActivityDefinition, entryWaypointID: String,
          approachPoint: WorldVector3?, targetYaw: Float)? {
        if let propActivity = propActivities[activityID] {
            return (propActivity.definition, propActivity.entryWaypointID,
                    propActivity.approachPoint, propActivity.targetYaw)
        }
        guard let definition = authoredActivityCatalog.definition(id: activityID),
              let anchor = manifest.activities.first(where: { $0.id == activityID })
        else { return nil }
        // 世界固有锚点：几何随世界烘焙。道具功能点锚点在 `propActivities` 里，
        // 走不到这一行 —— 不注册就**没有**锚点，绝不回退到任何烘焙值。
        guard let entryWaypointID = anchor.entryWaypointID,
              let transform = anchor.transform else { return nil }
        return (definition, entryWaypointID, nil, Self.yaw(of: transform.rotation))
    }

    private func rebuildPropActivities() {
        rebuildPropAnchorRegistry()
        var rebuilt: [String: PropActivity] = [:]
        for (objectID, item) in simulation.state.objectStates {
            guard item.isEnabled,
                  let prop = item.generatedProp, prop.objectID == objectID,
                  let capability = item.propCapability, capability.objectID == objectID,
                  let template = WorldPropActivityTemplate.supported[capability.templateID]
            else { continue }
            guard let entry = resolvedOperationSpot(
                propCenter: item.transform.position,
                propYaw: Self.yaw(of: item.transform.rotation),
                propHalfExtents: WorldVector3(
                    x: prop.size.x / 2, y: prop.size.y / 2, z: prop.size.z / 2
                ),
                in: collisionWorld
            ) else { continue }
            let yaw = atan2(
                item.transform.position.x - entry.standPoint.x,
                item.transform.position.z - entry.standPoint.z
            )
            let activity = PropActivity(
                definition: template.definition(objectID: objectID),
                objectID: objectID,
                templateID: capability.templateID,
                entryWaypointID: entry.waypointID,
                approachPoint: entry.approachPoint,
                targetYaw: yaw,
                functionPointAnchorID: nil,
                functionPointPosition: nil,
                origin: .boundCapability
            )
            rebuilt[activity.definition.id] = activity
        }
        for activityID in propAnchorRegistry.registeredActivityIDs {
            guard let anchor = propAnchorRegistry.entry(activityID: activityID),
                  let definition = authoredActivityCatalog.definition(id: activityID),
                  let entry = resolvedFunctionPointSpot(anchor: anchor, in: collisionWorld)
            else { continue }
            rebuilt[activityID] = PropActivity(
                definition: definition,
                objectID: anchor.objectID,
                templateID: activityID,
                entryWaypointID: entry.waypointID,
                approachPoint: entry.approachPoint,
                targetYaw: anchor.yaw,
                functionPointAnchorID: anchor.id,
                functionPointPosition: anchor.position,
                origin: .functionPointAnchor
            )
        }
        propActivities = rebuilt
        combinedActivityCatalog = try? ActivityCatalog(
            definitions: authoredActivityCatalog.definitions + rebuilt.values.map(\.definition)
        )
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

    /// 把一个**已注册的功能点锚点**落成可走的落点：先找落在锚点上的路点
    /// （世界包烘焙时 `wp.jukebox` / `wish_machine.pickup` 就是锚点本身，于是
    /// 种子摆放下的路线与旧行为逐字一致），找不到就退到"最近的可站立路点 + 一段
    /// 经过碰撞校验的最后接近"。两者都不成立 = 这件道具的活动**不可用**。
    private func resolvedFunctionPointSpot(
        anchor: WorldPropFunctionAnchor,
        in world: any WorldCollisionQuerying
    ) -> (waypointID: String, approachPoint: WorldVector3?, standPoint: WorldVector3)? {
        func occupiable(_ position: WorldVector3) -> WorldVector3? {
            groundedPosition(position, in: world)
        }
        guard let standPoint = occupiable(anchor.position) else { return nil }
        if let exact = manifest.waypoints.first(where: { waypoint in
            guard waypoint.enabled else { return false }
            let dx = waypoint.position.x - anchor.position.x
            let dy = waypoint.position.y - anchor.position.y
            let dz = waypoint.position.z - anchor.position.z
            return (dx * dx + dy * dy + dz * dz) <= 0.0001
        }) {
            return (exact.id, nil, standPoint)
        }
        for waypoint in WorldPropActivityTemplate.operationAnchorCandidates(
            propCenter: WorldVector3(x: anchor.position.x, y: anchor.position.y, z: anchor.position.z),
            waypoints: manifest.waypoints,
            canStand: { occupiable($0) != nil }
        ) {
            guard world.canTraverse(
                capsule, from: waypoint.position.simd, to: standPoint.simd,
                maximumStepHeight: maximumStepHeight
            ) else { continue }
            return (waypoint.id, standPoint, standPoint)
        }
        return nil
    }

    private static let log = Logger(subsystem: "gmgn.world", category: "prop-anchors")

    /// Resolves where the resident actually stands to operate the machine:
    /// the nearest standable anchor waypoint, and — when that waypoint lies
    /// outside arm's reach — a short final leg marched toward the footprint and
    /// verified against the installed collision world (grounded, capsule fits,
    /// straight-line traversable). No qualifying spot means the activity is
    /// explicitly unavailable; a remote button press is never assumed.
    private func resolvedOperationSpot(
        propCenter: WorldVector3,
        propYaw: Float,
        propHalfExtents: WorldVector3,
        in world: any WorldCollisionQuerying
    ) -> (waypointID: String, approachPoint: WorldVector3?, standPoint: WorldVector3)? {
        func occupiable(_ position: WorldVector3) -> WorldVector3? {
            groundedPosition(position, in: world)
        }
        for waypoint in WorldPropActivityTemplate.operationAnchorCandidates(
            propCenter: propCenter,
            waypoints: manifest.waypoints,
            canStand: { occupiable($0) != nil }
        ) {
            let waypointEdge = WorldPropActivityTemplate.footprintEdgeDistance(
                from: waypoint.position, propCenter: propCenter,
                propYaw: propYaw, propHalfExtents: propHalfExtents
            )
            guard waypointEdge > WorldPropActivityTemplate.interactionReach else {
                return (waypoint.id, nil, waypoint.position)
            }
            if let approachPoint = WorldPropActivityTemplate.finalApproachPoint(
                from: waypoint.position, propCenter: propCenter,
                propYaw: propYaw, propHalfExtents: propHalfExtents,
                resolve: occupiable
            ), world.canTraverse(
                capsule, from: waypoint.position.simd, to: approachPoint.simd,
                maximumStepHeight: maximumStepHeight
            ) {
                return (waypoint.id, approachPoint, approachPoint)
            }
        }
        return nil
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

    func completeActivityPlayback(requestID: String, phase: LifeActivityPhase) throws {
        guard currentActivityRequestID == requestID, state.activeActivity != nil,
              activityExecutor.status.phase == phase, phase != .approach else { return }
        // An indefinite loop has no renderer completion authority.
        if phase == .loop,
           activityCatalog.definition(id: activityExecutor.status.activityID ?? "")?
            .contract(for: .loop)?.durationSeconds == nil { return }
        guard patrol == nil else { return }
        try applyActivityEffects(activityExecutor.advancePhase(at: state.worldTime),
            usageRequestID: requestID)
        try publish(forcePersistence: true)
    }

    func failActivityPlayback(requestID: String, phase: LifeActivityPhase) throws {
        guard currentActivityRequestID == requestID, state.activeActivity != nil,
              activityExecutor.status.phase == phase else { return }
        patrol = nil
        try applyActivityEffects(activityExecutor.fail(.missingMotion, at: state.worldTime),
            usageRequestID: requestID)
        try publish(forcePersistence: true)
    }

    func failMovementPlayback(requestID: String) throws {
        guard let run = movement, run.requestID == requestID else { return }
        movement = nil
        try simulation.recordMovementOutcome(requestID: run.requestID,
            destinationID: run.path.destinationID, failure: ActivityExecutionFailure.missingMotion.rawValue,
            expectedRevision: state.revision)
        try publish(forcePersistence: true)
    }

    /// 建造模式派生格子用的几何入口。装进上下文的 world 可能是包装类型
    /// （`MarbleLivingCabinCollisionWorld` 或 `PropLayoutCollisionWorld`），它们已转发
    /// 三角形；拿不到时返回 nil，调用方必须按 fail-closed 处理（不能摆放）。
    var propSupportQuerying: (any WorldPropSupportQuerying)? {
        collisionWorld.propSupportQuerying()
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
        PropLayoutCollisionWorld(base: baseCollisionWorld,
            volumes: state.objectStates.values.compactMap(\.generatedCollisionVolume))
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
        var candidate = simulation
        let baseline = state
        try candidate.applyPropLayout(command, expectedLayoutRevision: expectedLayoutRevision, requestID: requestID)
        guard candidate.state != state else { return state }
        try validate(candidate.state)
        guard state == baseline else {
            throw WorldPropLayoutError.staleRevision(submitted: expectedLayoutRevision, current: state.layoutRevision)
        }
        // The whole transaction is decided on the candidate: the stale-run
        // cancel is folded into the candidate state, so the save is the single
        // commit point. A failed save leaves memory — world, collision,
        // executor, usage — completely untouched, and the old run keeps
        // receiving its receipts. No callback ever sees anything unsaved.
        let candidateCollision = PropLayoutCollisionWorld(base: baseCollisionWorld,
            volumes: candidate.state.objectStates.values.compactMap(\.generatedCollisionVolume))
        var executorStopped = false
        if let activeID = state.activeActivity?.activityID,
           let active = propActivities[activeID] {
            if active.isFunctionPoint {
                // 道具功能点锚点：新位置由**候选状态**派生。锚点移动了、消失了、
                // 或者在新位置上站不住，正在跑的那一次就必须中止 —— 否则居民会继续
                // 在一个已经不存在的入口上等回执。
                let candidateRegistry = try? WorldPropAnchorRegistry.derive(
                    sources: propFunctionSources, objectStates: candidate.state.objectStates
                )
                let anchor = candidateRegistry?.anchor(id: active.functionPointAnchorID ?? "")
                let spotResolved = anchor.flatMap {
                    resolvedFunctionPointSpot(anchor: $0, in: candidateCollision)
                }
                if anchor?.position != active.functionPointPosition || spotResolved == nil {
                    _ = try candidate.cancelActivity(reason: "物件已收回或移动，使用中止",
                        expectedRevision: candidate.state.revision)
                    executorStopped = true
                }
            } else {
                let placementChanged: Bool = {
                    guard let before = baseline.objectStates[active.objectID],
                          let after = candidate.state.objectStates[active.objectID] else { return false }
                    return before.isEnabled != after.isEnabled || before.transform != after.transform
                }()
                var spotResolved: (waypointID: String, approachPoint: WorldVector3?, standPoint: WorldVector3)?
                if !placementChanged, let item = candidate.state.objectStates[active.objectID],
                   let prop = item.generatedProp, item.isEnabled,
                   let capability = item.propCapability,
                   WorldPropActivityTemplate.supported[capability.templateID] != nil {
                    spotResolved = resolvedOperationSpot(
                        propCenter: item.transform.position,
                        propYaw: Self.yaw(of: item.transform.rotation),
                        propHalfExtents: WorldVector3(
                            x: prop.size.x / 2, y: prop.size.y / 2, z: prop.size.z / 2
                        ),
                        in: candidateCollision
                    )
                }
                if placementChanged || spotResolved == nil {
                    _ = try candidate.cancelActivity(reason: "物件已收回或移动，使用中止",
                        expectedRevision: candidate.state.revision)
                    executorStopped = true
                }
            }
        }
        try persistence?.save(candidate.state)
        simulation = candidate
        collisionWorld.replace(with: candidateCollision)
        rebuildPropActivities()
        if executorStopped {
            _ = activityExecutor.stop(at: state.worldTime)
            activityPhaseElapsed = 0
        }
        navigationTraversalCache.removeAll(keepingCapacity: true)
        lastCheckpointWorldTime = state.worldTime
        publishObservations()
        onSnapshotChanged?(snapshot)
        return state
    }

    @discardableResult
    func installCollisionWorldAndReconcilePlacement(
        _ world: any WorldCollisionQuerying
    ) throws -> WorldVector3? {
        let world = PropLayoutCollisionWorld(base: world,
            volumes: state.objectStates.values.compactMap(\.generatedCollisionVolume))
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
            let stoppingActivityID = state.activeActivity?.activityID
            let usageRequestID = currentActivityRequestID
            movement = nil
            patrol = nil
            _ = activityExecutor.stop(at: state.worldTime)
            if state.activeActivity != nil {
                _ = try simulation.cancelActivity(
                    reason: "碰撞网格更新后迁移到可站立位置",
                    expectedRevision: state.revision
                )
                if let stoppingActivityID {
                    syncPropUsage(stoppingActivityID, status: .stopped,
                        requestID: usageRequestID ?? "", reason: "碰撞网格更新后迁移到可站立位置")
                }
            }
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
        let status = activityExecutor.status
        guard let id = status.activityID else { return nil }
        return WorldAgentActiveActivitySnapshot(id: id, activity: status.activity, phase: status.phase)
    }

    var snapshot: WorldAgentSnapshot {
        let status = activityExecutor.status
        let activeActivity = simulation.state.activeActivity.map { activity in
            WorldAgentActiveActivitySnapshot(
                id: activity.activityID,
                activity: patrol.map { .walk(destinationID: $0.targetID) } ?? status.activity,
                phase: status.phase
            )
        }
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
            places: manifest.waypoints
                .filter { $0.enabled && !$0.id.hasPrefix("wp.auto.") }
                .map {
                    WorldAgentPlaceSnapshot(
                        id: $0.id,
                        position: $0.position,
                        arrivalRadius: $0.arrivalRadius
                    )
                }
                .sorted { $0.id < $1.id },
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
                    interruptible: propActivity.definition.interruptible
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
        guard manifest.waypoints.contains(where: { $0.id == placeID && $0.enabled }) else {
            throw WorldAgentContextError.unknownPlace(placeID)
        }
        let position = state.agentTransform.position.simd
        guard canTraverse(from: position, to: position) else {
            throw WorldAgentContextError.routeBlocked(placeID)
        }
        return try navigationGraph.route(
            from: position,
            to: placeID,
            canTraverse: cachedNavigationTraversal
        )
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
        let path = try planRoute(to: placeID)
        if state.activeActivity != nil {
            try stopActivity()
        }
        patrol = nil
        movement = MovementRun(requestID: UUID().uuidString, path: path, nextPointIndex: 0)
        try recordControlChange()
        return path
    }

    func startActivity(id: String, requestedAt: Date? = nil) throws {
        guard let plan = resolvedActivityPlan(activityID: id) else {
            throw WorldAgentContextError.unknownActivity(id)
        }
        let definition = plan.definition
        let entryWaypointID = plan.entryWaypointID
        let targetYaw = plan.targetYaw

        let date = requestedAt ?? state.worldTime
        let request = ScheduledActivity(
            id: "\(executionScopeID)-agent-\(id)-\(state.revision)",
            definitionID: id,
            activity: definition.activity,
            priority: .explicitUserRequest,
            requestedAt: date
        )
        // Validate the replacement and its approach before changing the current execution.
        var preparedExecutor = activityExecutor
        preparedExecutor.synchronizePlacement(position: state.agentTransform.position,
            yaw: Self.yaw(of: state.agentTransform.rotation))
        var effects = preparedExecutor.start(request, definition: definition, at: date)
        if effects.contains(where: \.isRejectedOrFailed) {
            throw WorldAgentContextError.activityRejected(id)
        }

        if effects.contains(where: \.requestsPath) {
            do {
                let path = try planRoute(to: entryWaypointID)
                var points = path.points
                if let approachPoint = plan.approachPoint { points.append(approachPoint) }
                effects += try preparedExecutor.supplyApproach(
                    ActivityApproachPlan(
                        waypoints: points,
                        targetYaw: targetYaw
                    )
                )
            } catch {
                throw WorldAgentContextError.routeBlocked(entryWaypointID)
            }
        }
        guard !effects.contains(where: \.isRejectedOrFailed) else {
            throw WorldAgentContextError.routeBlocked(entryWaypointID)
        }

        let priorActivityID = state.activeActivity?.activityID
        let priorRequestID = currentActivityRequestID
        activityExecutor = preparedExecutor
        movement = nil
        patrol = id == "home.walk" ? PatrolRun(targetID: entryWaypointID) : nil
        if let priorActivityID {
            _ = try simulation.cancelActivity(expectedRevision: state.revision)
            syncPropUsage(priorActivityID, status: .stopped, requestID: priorRequestID ?? "",
                reason: "新的使用请求替换了当前运行")
        }
        _ = try simulation.startActivity(id, expectedRevision: state.revision)
        syncPropUsage(id, status: .running, requestID: activityExecutor.currentRequestID ?? "")
        activityPhaseElapsed = 0
        try publish(forcePersistence: true)
    }

    func stopActivity(reason: String? = nil) throws {
        let wasMoving = movement != nil
        let stoppingActivityID = state.activeActivity?.activityID
        let usageRequestID = currentActivityRequestID
        movement = nil
        patrol = nil
        let effects = activityExecutor.stop(at: state.worldTime)
        guard state.activeActivity != nil else {
            if wasMoving || !effects.isEmpty { try recordControlChange() }
            return
        }
        _ = try simulation.cancelActivity(
            reason: Self.normalizedOptional(reason),
            expectedRevision: state.revision
        )
        if let stoppingActivityID {
            syncPropUsage(stoppingActivityID, status: .stopped, requestID: usageRequestID ?? "",
                reason: Self.normalizedOptional(reason) ?? "使用已停止")
        }
        activityPhaseElapsed = 0
        try publish(forcePersistence: true)
    }

    func look(at placeID: String) throws {
        guard let place = manifest.waypoints.first(where: { $0.id == placeID && $0.enabled }) else {
            throw WorldAgentContextError.unknownPlace(placeID)
        }
        let origin = state.agentTransform.position
        let target = place.position
        let yaw = atan2(target.x - origin.x, target.z - origin.z)
        try updateTransform(position: origin, yaw: yaw)
    }

    func setWeather(_ weather: WorldWeather) throws {
        _ = try simulation.setWeather(weather, expectedRevision: state.revision)
        try publish(forcePersistence: true)
    }

    func selectCamera(id: String) throws {
        guard let anchor = manifest.cameras.first(where: { $0.id == id }) else {
            throw WorldAgentContextError.unknownCamera(id)
        }
        _ = try simulation.setLiveCamera(
            WorldCameraState(anchor: anchor),
            expectedRevision: state.revision
        )
        try publish(forcePersistence: true)
    }

    func completeGoal(id: String, summary: String? = nil) throws {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WorldAgentContextError.invalidGoalID }
        _ = try simulation.completeGoal(
            normalized,
            summary: Self.normalizedOptional(summary),
            expectedRevision: state.revision
        )
        try publish(forcePersistence: true)
    }

    func tick(deltaTime: TimeInterval) throws {
        guard deltaTime.isFinite, deltaTime > 0 else {
            throw WorldAgentContextError.invalidTickDuration
        }

        let movementWasActive = movement != nil
        let activityBeforeTick = activityExecutor.status
        var tickError: Error?
        do {
            _ = try simulation.advance(by: deltaTime, expectedRevision: state.revision)
            if movement != nil {
                try tickMovement(deltaTime: deltaTime)
            } else if state.activeActivity != nil {
                try tickActivity(deltaTime: deltaTime)
            }
        } catch {
            tickError = error
        }
        let activityAfterTick = activityExecutor.status
        let movementCompleted = movementWasActive && movement == nil
        let activityPhaseChanged =
            activityBeforeTick.activityID != activityAfterTick.activityID
                || activityBeforeTick.phase != activityAfterTick.phase
        let actorIsMoving = movement != nil
            || activityAfterTick.phase == .approach
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

    func stopTicking() {
        tickingTask?.cancel()
        tickingTask = nil
        do {
            try saveCheckpoint()
        } catch {
            onTickError?(error)
        }
    }

    private func tickMovement(deltaTime: TimeInterval) throws {
        guard var run = movement else { return }
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
            let destination: WorldVector3
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

            guard let ground = collisionWorld.groundHeight(at: destination.simd),
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
            guard collisionWorld.canOccupy(capsule, at: groundedDestination.simd),
                  collisionWorld.canTraverse(
                      capsule,
                      from: position.simd,
                      to: groundedDestination.simd,
                      maximumStepHeight: maximumStepHeight
                  )
            else {
                try handleBlockedMovement(run, position: position, yaw: yaw)
                return
            }

            position = groundedDestination
            if horizontalDistance <= remaining || horizontalDistance <= 0.0001 {
                remaining -= horizontalDistance
                run.nextPointIndex += 1
            } else {
                remaining = 0
            }
        }

        movement = run.nextPointIndex >= run.path.points.count ? nil : run
        if position != state.agentTransform.position {
            try updateTransform(position: position, yaw: yaw, notify: false)
        }
        if movement == nil {
            try simulation.recordMovementOutcome(requestID: run.requestID, destinationID: run.path.destinationID,
                expectedRevision: state.revision)
        }
    }

    private func handleBlockedMovement(_ run: MovementRun, position: WorldVector3, yaw: Float) throws {
        navigationTraversalCache.removeAll(keepingCapacity: true)
        if position != state.agentTransform.position {
            try updateTransform(position: position, yaw: yaw, notify: false)
        }
        if run.replansRemaining > 0, let path = try? planRoute(to: run.path.destinationID), !path.points.isEmpty {
            var retry = run
            retry.path = path
            retry.nextPointIndex = 0
            retry.replansRemaining -= 1
            movement = retry
            return
        }
        movement = nil
        try simulation.recordMovementOutcome(requestID: run.requestID, destinationID: run.path.destinationID,
            failure: ActivityExecutionFailure.blocked.rawValue, expectedRevision: state.revision)
        throw WorldAgentContextError.routeBlocked(run.path.destinationID)
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

    private func tickActivity(deltaTime: TimeInterval) throws {
        let usageRequestID = currentActivityRequestID
        let effects = activityExecutor.tick(deltaTime: deltaTime)
        try applyActivityEffects(effects, usageRequestID: usageRequestID)

        let status = activityExecutor.status
        guard status.activityID != nil, status.phase != .approach else { return }
        if patrol != nil {
            try continuePatrol()
            return
        }
        activityPhaseElapsed += deltaTime
        guard let definition = status.activityID.flatMap(activityCatalog.definition),
              let duration = definition.contract(for: status.phase)?.durationSeconds,
              activityPhaseElapsed >= duration
        else {
            return
        }
        activityPhaseElapsed = 0
        try applyActivityEffects(activityExecutor.advancePhase(at: state.worldTime),
            usageRequestID: usageRequestID)
    }

    /// Bounded local selection: no model calls, no graph scan on every frame.
    /// Eight attempted destinations per completed leg is also the failure budget.
    private func continuePatrol() throws {
        guard var run = patrol, state.activeActivity?.activityID == "home.walk" else { patrol = nil; return }
        run.visits[run.targetID, default: 0] += 1
        let position = state.agentTransform.position
        let candidates = manifest.waypoints.filter {
            let distance = hypot($0.position.x-position.x, $0.position.z-position.z)
            return $0.enabled && $0.id != run.targetID && distance >= 1 && distance <= 6
        }.sorted {
            let lhs = (run.visits[$0.id, default: 0], abs(hypot($0.position.x-position.x, $0.position.z-position.z)-3), $0.id)
            let rhs = (run.visits[$1.id, default: 0], abs(hypot($1.position.x-position.x, $1.position.z-position.z)-3), $1.id)
            return lhs < rhs
        }
        for candidate in candidates.prefix(8) {
            guard let path = try? planRoute(to: candidate.id), !path.points.isEmpty else { continue }
            var executor = activityExecutor
            let effects = try executor.continueApproach(ActivityApproachPlan(waypoints: path.points))
            guard !effects.contains(where: \.isRejectedOrFailed) else { continue }
            activityExecutor = executor
            run.targetID = candidate.id
            patrol = run
            try applyActivityEffects(effects, usageRequestID: executor.currentRequestID)
            return
        }
        patrol = nil
        try applyActivityEffects(activityExecutor.fail(.pathUnavailable, at: state.worldTime))
    }

    /// Usage receipts are recorded only for prop activities, only at real
    /// lifecycle transitions, and anchored to the request that actually drove
    /// the run. A lost binding makes the write fail, so a stale in-flight
    /// activity can never complete a withdrawn or rebound object.
    private func syncPropUsage(_ activityID: String, status: WorldPropUsageState.Status,
                               requestID: String, reason: String? = nil) {
        guard !requestID.isEmpty, let propActivity = propActivities[activityID] else { return }
        // Reasons are bounded to the persisted metadata limit, so an over-long
        // stop reason can never fail the write and leave a "running" usage.
        let boundedReason = reason.map { $0.count <= 256 ? $0 : String($0.prefix(256)) }
        do {
            try simulation.recordPropUsage(objectID: propActivity.objectID,
                usage: WorldPropUsageState(templateID: propActivity.templateID, status: status,
                    activityRequestID: requestID, updatedAt: state.worldTime, reason: boundedReason),
                expectedRevision: state.revision)
        } catch {
            // A failed terminal write must never be swallowed: the usage state
            // would stay stale (running) while nothing runs. Surface it through
            // the context's error channel instead of hiding it.
            onTickError?(error)
        }
    }

    private func applyActivityEffects(
        _ effects: [ActivityExecutionEffect],
        usageRequestID: String? = nil
    ) throws {
        if let position = effects.compactMap(\.movedPosition).last {
            try updateTransform(
                position: position,
                yaw: activityExecutor.status.yaw,
                notify: false
            )
        } else if let yaw = effects.compactMap(\.alignedYaw).last {
            try updateTransform(position: state.agentTransform.position, yaw: yaw, notify: false)
        }

        for effect in effects {
            switch effect {
            case .phaseChanged:
                activityPhaseElapsed = 0
            case let .completed(activityID):
                patrol = nil
                if state.activeActivity != nil {
                    _ = try simulation.completeActivity(expectedRevision: state.revision)
                }
                syncPropUsage(activityID, status: .completed, requestID: usageRequestID ?? "")
            case let .cancelled(activityID):
                patrol = nil
                if state.activeActivity != nil {
                    _ = try simulation.cancelActivity(expectedRevision: state.revision)
                }
                syncPropUsage(activityID, status: .stopped, requestID: usageRequestID ?? "",
                    reason: "使用已停止")
            case let .failed(activityID, reason):
                patrol = nil
                if reason == .blocked || reason == .pathUnavailable {
                    navigationTraversalCache.removeAll(keepingCapacity: true)
                }
                if state.activeActivity != nil {
                    _ = try simulation.failActivity(
                        reason: reason.rawValue,
                        expectedRevision: state.revision
                    )
                }
                syncPropUsage(activityID, status: .failed, requestID: usageRequestID ?? "",
                    reason: reason.rawValue)
            case let .resumed(activityID, _):
                if state.activeActivity != nil {
                    _ = try simulation.cancelActivity(expectedRevision: state.revision)
                }
                _ = try simulation.startActivity(
                    activityID,
                    expectedRevision: state.revision
                )
            default:
                break
            }
        }
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
/// 已放物件的阻挡体积（没有三角形）。转发给 `base`，拿不到就返回空数组 —— 理由与
/// `MarbleLivingCabinCollisionWorld` 的 conformance 相同：派生器会因此得到空网格
/// （"不猜、不放行"），评估器会因此得到 `.noSupport`，两道都是 fail-closed。
private struct PropLayoutCollisionWorld: WorldCollisionQuerying, WorldPropSupportQuerying {
    let base: any WorldCollisionQuerying
    let props: CollisionVolumeWorld
    init(base: any WorldCollisionQuerying, volumes: [WorldCollisionVolume]) {
        self.base = base; props = CollisionVolumeWorld(volumes: volumes)
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
