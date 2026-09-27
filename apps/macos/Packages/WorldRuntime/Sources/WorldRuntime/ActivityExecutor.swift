import Foundation

public struct ActivityApproachPlan: Equatable, Sendable {
    public let waypoints: [WorldVector3]
    public let targetYaw: Float?

    public init(waypoints: [WorldVector3], targetYaw: Float? = nil) {
        self.waypoints = waypoints
        self.targetYaw = targetYaw
    }
}

public enum ActivityExecutionFailure: String, Codable, Equatable, Sendable {
    case pathUnavailable
    case blocked
    case missingAnchor
    case missingMotion
    case invalidState
}

public enum ActivityExecutionRejection: Equatable, Sendable {
    case notInterruptible
    case lowerPriority
    case definitionMismatch
    case cooldownActive(until: Date)
}

public enum ActivityExecutionEffect: Equatable, Sendable {
    case requestPath(from: WorldVector3, destinationID: String)
    case moved(to: WorldVector3)
    case aligned(yaw: Float)
    case phaseChanged(activityID: String, phase: LifeActivityPhase)
    case suspended(activityID: String)
    case resumed(activityID: String, phase: LifeActivityPhase)
    case completed(activityID: String)
    case cancelled(activityID: String)
    case failed(activityID: String, reason: ActivityExecutionFailure)
    case rejected(activityID: String, reason: ActivityExecutionRejection)
    case enteredSafeIdle
}

public enum ActivityExecutorError: Error, Equatable, Sendable {
    case noActiveApproach
    case emptyPath
}

public struct ActivityExecutorStatus: Equatable, Sendable {
    public let activityID: String?
    public let activity: LifeActivity
    public let phase: LifeActivityPhase
    public let position: WorldVector3
    public let yaw: Float
    public let priority: ActivityPriority

    public init(
        activityID: String?,
        activity: LifeActivity,
        phase: LifeActivityPhase,
        position: WorldVector3,
        yaw: Float,
        priority: ActivityPriority
    ) {
        self.activityID = activityID
        self.activity = activity
        self.phase = phase
        self.position = position
        self.yaw = yaw
        self.priority = priority
    }
}

/// Advances authored activity plans using only elapsed time and supplied paths.
/// Agent reasoning may choose a request before it reaches this type; it never
/// runs inside the tick path.
public struct ActivityExecutor: Sendable {
    private struct Run: Sendable {
        let request: ScheduledActivity
        let definition: LifeActivityDefinition
        var phase: LifeActivityPhase
        var path: [WorldVector3]
        var pathIndex: Int
        var targetYaw: Float?
    }

    private struct SuspendedRun: Sendable {
        var run: Run
        let resumePhase: LifeActivityPhase
    }

    private var current: Run?
    private var suspended: [SuspendedRun] = []
    private var position: WorldVector3
    private var yaw: Float
    private var walkingSpeed: Float
    private let turningSpeed: Float
    private let collisionQuery: (any WorldCollisionQuerying)?
    private let capsule: WorldCapsule
    private let maximumStepHeight: Float

    public private(set) var cooldowns: [String: Date] = [:]

    /// Execution identity stays distinct even when two requests share a world timestamp.
    public var currentRequestID: String? { current?.request.id }

    public mutating func updateWalkingSpeed(_ speed: Float) {
        guard speed.isFinite, speed >= 0 else { return }
        walkingSpeed = speed
    }

    /// Continue an existing execution without changing its identity or activity.
    /// The supplied path still passes the same collision checks as its first leg.
    public mutating func continueApproach(_ plan: ActivityApproachPlan) throws -> [ActivityExecutionEffect] {
        guard var active = current else { throw ActivityExecutorError.noActiveApproach }
        active.phase = .approach
        current = active
        return [.phaseChanged(activityID: active.definition.id, phase: .approach)] + (try supplyApproach(plan))
    }

    public init(
        position: WorldVector3,
        yaw: Float = 0,
        walkingSpeed: Float = 1.2,
        turningSpeed: Float = 4.5,
        collisionQuery: (any WorldCollisionQuerying)? = nil,
        capsule: WorldCapsule = WorldCapsule(radius: 0.2, height: 1.8),
        maximumStepHeight: Float = 0.3
    ) {
        self.position = position
        self.yaw = yaw
        self.walkingSpeed = max(0, walkingSpeed)
        self.turningSpeed = max(0, turningSpeed)
        self.collisionQuery = collisionQuery
        self.capsule = capsule
        self.maximumStepHeight = max(0, maximumStepHeight)
    }

    public var status: ActivityExecutorStatus {
        guard let current else {
            return ActivityExecutorStatus(
                activityID: nil,
                activity: .idle,
                phase: .loop,
                position: position,
                yaw: yaw,
                priority: .safeIdleFallback
            )
        }
        return ActivityExecutorStatus(
            activityID: current.definition.id,
            activity: current.request.activity,
            phase: current.phase,
            position: position,
            yaw: yaw,
            priority: current.request.priority
        )
    }

    public mutating func synchronizePlacement(
        position: WorldVector3,
        yaw: Float
    ) {
        self.position = position
        self.yaw = yaw
    }

    @discardableResult
    public mutating func start(
        _ request: ScheduledActivity,
        definition: LifeActivityDefinition,
        at date: Date
    ) -> [ActivityExecutionEffect] {
        guard request.definitionID == definition.id,
              request.activity == definition.activity
        else {
            return [.rejected(activityID: definition.id, reason: .definitionMismatch)]
        }

        if let cooldownUntil = cooldowns[definition.id], cooldownUntil > date {
            return [
                .rejected(
                    activityID: definition.id,
                    reason: .cooldownActive(until: cooldownUntil)
                ),
            ]
        }

        var effects: [ActivityExecutionEffect] = []
        if var active = current {
            guard active.definition.interruptible else {
                return [.rejected(activityID: definition.id, reason: .notInterruptible)]
            }
            if request.priority == .explicitUserRequest,
               active.request.priority == .explicitUserRequest
            {
                effects.append(.cancelled(activityID: active.definition.id))
                current = nil
                suspended.removeAll()
                effects.append(contentsOf: begin(request, definition: definition))
                return effects
            }
            guard request.priority < active.request.priority else {
                return [.rejected(activityID: definition.id, reason: .lowerPriority)]
            }

            let resumePhase = active.phase
            active.phase = .interrupt
            current = active
            effects.append(.phaseChanged(activityID: active.definition.id, phase: .interrupt))
            effects.append(.suspended(activityID: active.definition.id))
            suspended.append(SuspendedRun(run: active, resumePhase: resumePhase))
        }

        effects.append(contentsOf: begin(request, definition: definition))
        return effects
    }

    @discardableResult
    public mutating func acquireApproach(
        using router: any WorldNavigationRouting,
        targetYaw: Float? = nil
    ) throws -> [ActivityExecutionEffect] {
        guard let active = current,
              active.phase == .approach,
              let destinationID = active.request.activity.approachTargetID
        else {
            throw ActivityExecutorError.noActiveApproach
        }

        // 物件摆放后成为导航障碍：把由碰撞世界推出的可达性交给路径规划，图会用它在
        // 候选边上做碰撞查询并惰性重规划（绕开家具），而不是撞上去才发现受阻。
        //
        // 没有碰撞世界时沿用本文件既有的 fail-open 约定（见 `resolvedDestination` 的
        // `guard let collisionQuery else { return destination }`）：导航不是授权边界，
        // 摆放判定才是。
        let canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool
        if let collisionQuery {
            let capsule = capsule
            let maximumStepHeight = maximumStepHeight
            canTraverse = { start, end in
                collisionQuery.canTraverse(capsule, from: start, to: end, maximumStepHeight: maximumStepHeight)
            }
        } else {
            canTraverse = { _, _ in true }
        }
        let path = try router.route(from: position.simd3, to: destinationID, canTraverse: canTraverse)
        return try supplyApproach(
            ActivityApproachPlan(waypoints: path.points, targetYaw: targetYaw)
        )
    }

    @discardableResult
    public mutating func supplyApproach(
        _ plan: ActivityApproachPlan
    ) throws -> [ActivityExecutionEffect] {
        guard var active = current, active.phase == .approach else {
            throw ActivityExecutorError.noActiveApproach
        }

        active.path = plan.waypoints
        active.pathIndex = 0
        active.targetYaw = plan.targetYaw
        skipReachedWaypoints(in: &active)
        current = active

        guard canFollowPath(active) else {
            return fail(.blocked, at: active.request.requestedAt)
        }

        guard active.pathIndex >= active.path.count else { return [] }
        return finishApproach()
    }

    @discardableResult
    public mutating func tick(deltaTime: TimeInterval) -> [ActivityExecutionEffect] {
        guard deltaTime > 0,
              var active = current,
              active.phase == .approach,
              active.pathIndex < active.path.count
        else {
            return []
        }

        var effects: [ActivityExecutionEffect] = []
        var remainingDistance = walkingSpeed * Float(deltaTime)
        var didUpdateFacing = false

        while remainingDistance > 0, active.pathIndex < active.path.count {
            let target = active.path[active.pathIndex]
            let delta = target.subtracting(position)
            let horizontalDistance = hypot(delta.x, delta.z)
            if !didUpdateFacing,
               horizontalDistance > Self.positionTolerance
            {
                let pathYaw = atan2(delta.x, delta.z)
                yaw = Self.rotate(
                    yaw,
                    toward: pathYaw,
                    maximumDelta: turningSpeed * Float(deltaTime)
                )
                didUpdateFacing = true
            }

            if horizontalDistance <= remainingDistance
                || horizontalDistance <= Self.positionTolerance
            {
                guard let groundedTarget = resolvedMove(from: position, to: target) else {
                    current = active
                    effects.append(contentsOf: fail(.blocked, at: active.request.requestedAt))
                    return effects
                }
                position = groundedTarget
                effects.append(.moved(to: position))
                remainingDistance -= horizontalDistance
                active.pathIndex += 1
            } else {
                let progress = remainingDistance / horizontalDistance
                let destination = WorldVector3(
                    x: position.x + delta.x * progress,
                    y: position.y,
                    z: position.z + delta.z * progress
                )
                guard let groundedDestination = resolvedMove(
                    from: position,
                    to: destination
                ) else {
                    current = active
                    effects.append(contentsOf: fail(.blocked, at: active.request.requestedAt))
                    return effects
                }
                position = groundedDestination
                effects.append(.moved(to: position))
                remainingDistance = 0
            }
        }

        current = active
        if active.pathIndex >= active.path.count {
            effects.append(contentsOf: finishApproach())
        }
        return effects
    }

    @discardableResult
    public mutating func advancePhase(at date: Date) -> [ActivityExecutionEffect] {
        guard var active = current else { return [] }

        switch active.phase {
        case .enter:
            active.phase = .loop
            current = active
            return [.phaseChanged(activityID: active.definition.id, phase: .loop)]
        case .loop:
            active.phase = .exit
            current = active
            return [.phaseChanged(activityID: active.definition.id, phase: .exit)]
        case .exit:
            return complete(active, at: date)
        case .approach, .interrupt, .failed:
            return []
        }
    }

    @discardableResult
    public mutating func cancel(at date: Date) -> [ActivityExecutionEffect] {
        stop(at: date)
    }

    @discardableResult
    public mutating func stop(at date: Date) -> [ActivityExecutionEffect] {
        guard let active = current else {
            suspended.removeAll()
            return []
        }
        recordCooldown(for: active, at: date)
        current = nil
        suspended.removeAll()
        return [
            .cancelled(activityID: active.definition.id),
            .enteredSafeIdle,
        ]
    }

    @discardableResult
    public mutating func fail(
        _ reason: ActivityExecutionFailure,
        at date: Date
    ) -> [ActivityExecutionEffect] {
        guard var active = current else { return [.enteredSafeIdle] }
        active.phase = .failed
        current = active
        recordCooldown(for: active, at: date)

        var effects: [ActivityExecutionEffect] = [
            .phaseChanged(activityID: active.definition.id, phase: .failed),
            .failed(activityID: active.definition.id, reason: reason),
        ]
        effects.append(contentsOf: resumeOrIdle())
        return effects
    }

    private mutating func begin(
        _ request: ScheduledActivity,
        definition: LifeActivityDefinition
    ) -> [ActivityExecutionEffect] {
        if let targetID = request.activity.approachTargetID {
            current = Run(
                request: request,
                definition: definition,
                phase: .approach,
                path: [],
                pathIndex: 0,
                targetYaw: nil
            )
            return [
                .phaseChanged(activityID: definition.id, phase: .approach),
                .requestPath(from: position, destinationID: targetID),
            ]
        }

        current = Run(
            request: request,
            definition: definition,
            phase: .enter,
            path: [],
            pathIndex: 0,
            targetYaw: nil
        )
        var effects: [ActivityExecutionEffect] = []
        if case let .turn(targetYaw) = request.activity {
            yaw = targetYaw
            effects.append(.aligned(yaw: targetYaw))
        }
        effects.append(.phaseChanged(activityID: definition.id, phase: .enter))
        return effects
    }

    private mutating func finishApproach() -> [ActivityExecutionEffect] {
        guard var active = current else { return [] }
        var effects: [ActivityExecutionEffect] = []
        if let targetYaw = active.targetYaw {
            yaw = targetYaw
            effects.append(.aligned(yaw: targetYaw))
        }
        active.phase = .enter
        current = active
        effects.append(.phaseChanged(activityID: active.definition.id, phase: .enter))
        return effects
    }

    private mutating func complete(
        _ active: Run,
        at date: Date
    ) -> [ActivityExecutionEffect] {
        recordCooldown(for: active, at: date)
        var effects: [ActivityExecutionEffect] = [
            .completed(activityID: active.definition.id),
        ]
        effects.append(contentsOf: resumeOrIdle())
        return effects
    }

    private mutating func resumeOrIdle() -> [ActivityExecutionEffect] {
        if var prior = suspended.popLast() {
            prior.run.phase = prior.resumePhase
            current = prior.run
            return [
                .resumed(
                    activityID: prior.run.definition.id,
                    phase: prior.resumePhase
                ),
            ]
        }

        current = nil
        return [.enteredSafeIdle]
    }

    private mutating func recordCooldown(for active: Run, at date: Date) {
        cooldowns[active.definition.id] = date.addingTimeInterval(
            max(0, active.definition.cooldownSeconds)
        )
    }

    private mutating func skipReachedWaypoints(in active: inout Run) {
        while active.pathIndex < active.path.count,
              active.path[active.pathIndex].distance(to: position) <= Self.positionTolerance
        {
            active.pathIndex += 1
        }
    }

    private func canFollowPath(_ active: Run) -> Bool {
        guard collisionQuery != nil else { return true }
        guard canOccupy(position) else { return false }

        var start = position
        for destination in active.path.dropFirst(active.pathIndex) {
            guard canMove(from: start, to: destination) else {
                return false
            }
            start = destination
        }
        return true
    }

    private func canMove(from start: WorldVector3, to destination: WorldVector3) -> Bool {
        resolvedMove(from: start, to: destination) != nil
    }

    private func resolvedMove(
        from start: WorldVector3,
        to destination: WorldVector3
    ) -> WorldVector3? {
        guard let collisionQuery else { return destination }
        guard let ground = collisionQuery.groundHeight(at: destination.simd3),
              ground.isFinite
        else {
            return nil
        }
        let groundedDestination = WorldVector3(
            x: destination.x,
            y: ground,
            z: destination.z
        )
        guard collisionQuery.canOccupy(capsule, at: groundedDestination.simd3),
              collisionQuery.canTraverse(
                  capsule,
                  from: start.simd3,
                  to: groundedDestination.simd3,
                  maximumStepHeight: maximumStepHeight
              )
        else {
            return nil
        }
        return groundedDestination
    }

    private func canOccupy(_ position: WorldVector3) -> Bool {
        collisionQuery?.canOccupy(capsule, at: position.simd3) ?? true
    }

    private static let positionTolerance: Float = 0.0001

    private static func rotate(
        _ angle: Float,
        toward target: Float,
        maximumDelta: Float
    ) -> Float {
        guard maximumDelta > 0 else { return angle }
        let twoPi = 2 * Float.pi
        var delta = (target - angle).truncatingRemainder(dividingBy: twoPi)
        if delta > .pi { delta -= twoPi }
        if delta < -.pi { delta += twoPi }
        return angle + min(max(delta, -maximumDelta), maximumDelta)
    }
}

private extension WorldVector3 {
    func adding(_ other: Self) -> Self {
        Self(x: x + other.x, y: y + other.y, z: z + other.z)
    }

    func subtracting(_ other: Self) -> Self {
        Self(x: x - other.x, y: y - other.y, z: z - other.z)
    }

    func scaled(by scalar: Float) -> Self {
        Self(x: x * scalar, y: y * scalar, z: z * scalar)
    }

    var length: Float {
        (x * x + y * y + z * z).squareRoot()
    }

    func distance(to other: Self) -> Float {
        subtracting(other).length
    }
}
