import Foundation
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
        let path: WorldPath
        var nextPointIndex: Int
    }

    let manifest: WorldManifest
    let navigationGraph: WaypointNavigationGraph
    let collisionWorld: ReplaceableCollisionWorld
    let activityCatalog: ActivityCatalog

    private(set) var simulation: WorldSimulation
    private(set) var activityExecutor: ActivityExecutor
    var currentActivityRequestID: String? { activityExecutor.currentRequestID }
    private var movement: MovementRun?
    private var activityPhaseElapsed: TimeInterval = 0
    private let persistence: (any WorldStatePersisting)?
    private let walkingSpeed: Float
    private let capsule: WorldCapsule
    private let maximumStepHeight: Float
    private var tickingTask: Task<Void, Never>?
    private var lastCheckpointWorldTime: Date?
    private var publishedEventCount = 0

    var onSnapshotChanged: (@MainActor (WorldAgentSnapshot) -> Void)?
    var onEventsPublished: (@MainActor ([WorldEvent]) -> Void)?
    var onTickError: (@MainActor (Error) -> Void)?

    init(
        manifest: WorldManifest,
        startedAt: Date = Date(),
        persistence: (any WorldStatePersisting)? = nil,
        walkingSpeed: Float = 1.2,
        capsule: WorldCapsule = WorldCapsule(radius: 0.2, height: 1.8),
        maximumStepHeight: Float = 0.3
    ) throws {
        self.manifest = manifest
        navigationGraph = WaypointNavigationGraph(manifest: manifest)
        collisionWorld = ReplaceableCollisionWorld(
            initial: CollisionVolumeWorld(manifest: manifest)
        )
        activityCatalog = try ActivityCatalog(manifest: manifest)
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

        let transform = simulation.state.agentTransform
        activityExecutor = ActivityExecutor(
            position: transform.position,
            yaw: Self.yaw(of: transform.rotation),
            walkingSpeed: self.walkingSpeed,
            collisionQuery: collisionWorld,
            capsule: capsule,
            maximumStepHeight: self.maximumStepHeight
        )

        if let active = simulation.state.activeActivity,
           let definition = activityCatalog.definition(id: active.activityID),
           let anchor = manifest.activities.first(where: { $0.id == active.activityID })
        {
            let request = ScheduledActivity(
                id: "restored-\(active.activityID)-\(active.startedAt.timeIntervalSince1970)",
                definitionID: active.activityID,
                activity: definition.activity,
                priority: .autonomousIdle,
                requestedAt: active.startedAt
            )
            let effects = activityExecutor.start(
                request,
                definition: definition,
                at: simulation.state.worldTime
            )
            if effects.contains(where: \.requestsPath) {
                let path = try navigationGraph.route(
                    from: transform.position.simd,
                    to: anchor.entryWaypointID
                )
                _ = try activityExecutor.supplyApproach(
                    ActivityApproachPlan(
                        waypoints: path.points,
                        targetYaw: Self.yaw(of: anchor.transform.rotation)
                    )
                )
            }
        }
    }

    var state: WorldState { simulation.state }
    var events: [WorldEvent] { simulation.events }

    func installCollisionWorld(_ world: any WorldCollisionQuerying) {
        collisionWorld.replace(with: world)
    }

    @discardableResult
    func installCollisionWorldAndReconcilePlacement(
        _ world: any WorldCollisionQuerying
    ) throws -> WorldVector3? {
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

        collisionWorld.replace(with: world)
        guard resolved != current else { return nil }

        let deltaX = resolved.x - current.x
        let deltaZ = resolved.z - current.z
        if deltaX * deltaX + deltaZ * deltaZ > 0.0001 {
            movement = nil
            _ = activityExecutor.stop(at: state.worldTime)
            if state.activeActivity != nil {
                _ = try simulation.cancelActivity(
                    reason: "碰撞网格更新后迁移到可站立位置",
                    expectedRevision: state.revision
                )
            }
            activityPhaseElapsed = 0
        }

        let yaw = Self.yaw(of: state.agentTransform.rotation)
        try updateTransform(position: resolved, yaw: yaw, notify: false)
        activityExecutor.synchronizePlacement(position: resolved, yaw: yaw)
        try publish(forcePersistence: true)
        return resolved
    }

    var snapshot: WorldAgentSnapshot {
        let status = activityExecutor.status
        let activeActivity = simulation.state.activeActivity.map { activity in
            WorldAgentActiveActivitySnapshot(
                id: activity.activityID,
                activity: status.activity,
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
                .filter(\.enabled)
                .map {
                    WorldAgentPlaceSnapshot(
                        id: $0.id,
                        position: $0.position,
                        arrivalRadius: $0.arrivalRadius
                    )
                }
                .sorted { $0.id < $1.id },
            activities: manifest.activities
                .map {
                    WorldAgentActivityOption(
                        id: $0.id,
                        action: $0.action,
                        entryPlaceID: $0.entryWaypointID,
                        interruptible: $0.interruptible
                    )
                }
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
        return try navigationGraph.route(
            from: state.agentTransform.position.simd,
            to: placeID
        )
    }

    @discardableResult
    func move(to placeID: String) throws -> WorldPath {
        let path = try planRoute(to: placeID)
        if state.activeActivity != nil {
            try stopActivity()
        }
        movement = MovementRun(path: path, nextPointIndex: 0)
        try recordControlChange()
        return path
    }

    func startActivity(id: String, requestedAt: Date? = nil) throws {
        guard let definition = activityCatalog.definition(id: id),
              let anchor = manifest.activities.first(where: { $0.id == id })
        else {
            throw WorldAgentContextError.unknownActivity(id)
        }

        let date = requestedAt ?? state.worldTime
        let request = ScheduledActivity(
            id: "agent-\(id)-\(state.revision)",
            definitionID: id,
            activity: definition.activity,
            priority: .explicitUserRequest,
            requestedAt: date
        )
        // Validate the replacement and its approach before changing the current execution.
        var preparedExecutor = activityExecutor
        var effects = preparedExecutor.start(request, definition: definition, at: date)
        if effects.contains(where: \.isRejectedOrFailed) {
            throw WorldAgentContextError.activityRejected(id)
        }

        if effects.contains(where: \.requestsPath) {
            do {
                let path = try navigationGraph.route(
                    from: state.agentTransform.position.simd,
                    to: anchor.entryWaypointID
                )
                effects += try preparedExecutor.supplyApproach(
                    ActivityApproachPlan(
                        waypoints: path.points,
                        targetYaw: Self.yaw(of: anchor.transform.rotation)
                    )
                )
            } catch {
                throw WorldAgentContextError.routeBlocked(anchor.entryWaypointID)
            }
        }
        guard !effects.contains(where: \.isRejectedOrFailed) else {
            throw WorldAgentContextError.routeBlocked(anchor.entryWaypointID)
        }

        activityExecutor = preparedExecutor
        movement = nil
        if state.activeActivity != nil {
            _ = try simulation.cancelActivity(expectedRevision: state.revision)
        }
        _ = try simulation.startActivity(id, expectedRevision: state.revision)
        activityPhaseElapsed = 0
        try publish(forcePersistence: true)
    }

    func stopActivity(reason: String? = nil) throws {
        let effects = activityExecutor.stop(at: state.worldTime)
        guard state.activeActivity != nil else {
            if !effects.isEmpty { try recordControlChange() }
            return
        }
        _ = try simulation.cancelActivity(
            reason: Self.normalizedOptional(reason),
            expectedRevision: state.revision
        )
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

        while remaining > 0, run.nextPointIndex < run.path.points.count {
            let target = run.path.points[run.nextPointIndex]
            let delta = target.subtracting(position)
            let horizontalDistance = hypot(delta.x, delta.z)
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
                movement = nil
                throw WorldAgentContextError.routeBlocked(run.path.destinationID)
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
                movement = nil
                throw WorldAgentContextError.routeBlocked(run.path.destinationID)
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
            try updateTransform(position: position, yaw: Self.yaw(of: state.agentTransform.rotation), notify: false)
        }
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
        let effects = activityExecutor.tick(deltaTime: deltaTime)
        try applyActivityEffects(effects)

        let status = activityExecutor.status
        guard status.activityID != nil, status.phase != .approach else { return }
        activityPhaseElapsed += deltaTime
        guard let definition = status.activityID.flatMap(activityCatalog.definition),
              let duration = definition.contract(for: status.phase)?.durationSeconds,
              activityPhaseElapsed >= duration
        else {
            return
        }
        activityPhaseElapsed = 0
        try applyActivityEffects(activityExecutor.advancePhase(at: state.worldTime))
    }

    private func applyActivityEffects(_ effects: [ActivityExecutionEffect]) throws {
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
            case .completed:
                if state.activeActivity != nil {
                    _ = try simulation.completeActivity(expectedRevision: state.revision)
                }
            case .cancelled:
                if state.activeActivity != nil {
                    _ = try simulation.cancelActivity(expectedRevision: state.revision)
                }
            case let .failed(_, reason):
                if state.activeActivity != nil {
                    _ = try simulation.cancelActivity(
                        reason: "活动执行失败：\(reason.rawValue)",
                        expectedRevision: state.revision
                    )
                }
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
        // Index directly into the append-only log; never scan historical frame events.
        let end = simulation.events.count
        var observations: [WorldEvent] = []
        for index in publishedEventCount..<end {
            let event = simulation.events[index]
            switch event.kind {
            case .timeAdvanced, .timeCaughtUp, .agentTransformUpdated, .liveCameraChanged:
                break
            default:
                observations.append(event)
            }
        }
        // Advance before either callback, because observers may synchronously mutate the world.
        publishedEventCount = end
        if !observations.isEmpty { onEventsPublished(observations) }
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
