import Foundation
import Testing
@testable import WorldRuntime

@Test("An executor can synchronize to a collision-validated placement")
func activityExecutorSynchronizesPlacement() {
    var executor = ActivityExecutor(
        position: WorldVector3(x: 0, y: 0, z: 0),
        yaw: 0
    )

    executor.synchronizePlacement(
        position: WorldVector3(x: 1, y: 0.02, z: -1),
        yaw: 0.75
    )

    #expect(executor.status.position == WorldVector3(x: 1, y: 0.02, z: -1))
    #expect(executor.status.yaw == 0.75)
}

@Test("Scheduler follows the living-world priority contract")
func schedulerFollowsPriorityContract() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let candidates = ActivityPriority.allCases.reversed().enumerated().map { index, priority in
        ScheduledActivity(
            id: "request-\(index)",
            definitionID: "activity-\(index)",
            activity: .idle,
            priority: priority,
            requestedAt: now.addingTimeInterval(TimeInterval(index))
        )
    }

    let selected = ActivityScheduler().select(
        from: Array(candidates),
        at: now,
        cooldowns: [:]
    )

    #expect(selected?.priority == .explicitUserRequest)
    #expect(ActivityPriority.allCases == [
        .explicitUserRequest,
        .activeConversation,
        .scheduledSharedActivity,
        .musicContext,
        .autonomousIdle,
        .safeIdleFallback,
    ])
}

@Test("Scheduler skips cooling activities and resolves ties deterministically")
func schedulerSkipsCooldownAndResolvesTies() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let earlier = ScheduledActivity(
        id: "request.b",
        definitionID: "read",
        activity: .gaze(targetID: "book"),
        priority: .autonomousIdle,
        requestedAt: now
    )
    let lexicalWinner = ScheduledActivity(
        id: "request.a",
        definitionID: "window",
        activity: .gaze(targetID: "window"),
        priority: .autonomousIdle,
        requestedAt: now
    )

    let selected = ActivityScheduler().select(
        from: [earlier, lexicalWinner],
        at: now,
        cooldowns: ["read": now.addingTimeInterval(20)]
    )

    #expect(selected == lexicalWinner)
}

@Test("Executor acquires a path, moves, aligns, and enters the activity")
func executorApproachesAndAligns() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "sit.window",
        activity: .sit(anchorID: "chair.window")
    )
    var executor = ActivityExecutor(position: .zero, walkingSpeed: 1)
    let request = scheduled(definition, priority: .autonomousIdle, at: now)

    let startEffects = executor.start(request, definition: definition, at: now)
    #expect(startEffects == [
        .phaseChanged(activityID: definition.id, phase: .approach),
        .requestPath(from: .zero, destinationID: "chair.window"),
    ])

    try executor.supplyApproach(
        ActivityApproachPlan(
            waypoints: [.zero, WorldVector3(x: 1, y: 0, z: 0)],
            targetYaw: .pi / 2
        )
    )
    let firstTick = executor.tick(deltaTime: 0.5)
    #expect(firstTick == [.moved(to: WorldVector3(x: 0.5, y: 0, z: 0))])
    #expect(executor.status.phase == .approach)

    let arrival = executor.tick(deltaTime: 0.5)
    #expect(arrival == [
        .moved(to: WorldVector3(x: 1, y: 0, z: 0)),
        .aligned(yaw: .pi / 2),
        .phaseChanged(activityID: definition.id, phase: .enter),
    ])
    #expect(executor.status.position == WorldVector3(x: 1, y: 0, z: 0))
    #expect(executor.status.yaw == .pi / 2)
}

@Test("Executor turns smoothly toward the current path segment while walking")
func executorFacesThePathWhileWalking() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.east",
        activity: .walk(destinationID: "east")
    )
    var executor = ActivityExecutor(
        position: .zero,
        yaw: 0,
        walkingSpeed: 1,
        turningSpeed: 2
    )
    _ = executor.start(
        scheduled(definition, priority: .explicitUserRequest, at: now),
        definition: definition,
        at: now
    )
    try executor.supplyApproach(
        ActivityApproachPlan(
            waypoints: [.zero, WorldVector3(x: 2, y: 0, z: 0)]
        )
    )

    _ = executor.tick(deltaTime: 0.25)

    #expect(abs(executor.status.yaw - 0.5) < 0.0001)
    #expect(executor.status.position == WorldVector3(x: 0.25, y: 0, z: 0))
}

@Test("Executor can acquire an authored route through the navigation seam")
func executorAcquiresAuthoredRoute() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.window",
        activity: .walk(destinationID: "wp.window")
    )
    let router = WaypointNavigationGraph(
        waypoints: [
            WorldWaypoint(
                id: "wp.spawn",
                position: .zero,
                arrivalRadius: 0.1,
                enabled: true
            ),
            WorldWaypoint(
                id: "wp.window",
                position: WorldVector3(x: 2, y: 0, z: 0),
                arrivalRadius: 0.1,
                enabled: true
            ),
        ],
        routes: [
            WorldRoute(
                id: "route.window",
                waypointIDs: ["wp.spawn", "wp.window"],
                bidirectional: true,
                enabled: true
            ),
        ]
    )
    var executor = ActivityExecutor(position: .zero, walkingSpeed: 2)
    _ = executor.start(
        scheduled(definition, priority: .explicitUserRequest, at: now),
        definition: definition,
        at: now
    )

    let effects = try executor.acquireApproach(using: router)

    #expect(effects.isEmpty)
    #expect(executor.tick(deltaTime: 1).contains(
        .phaseChanged(activityID: definition.id, phase: .enter)
    ))
    #expect(executor.status.position == WorldVector3(x: 2, y: 0, z: 0))
}

@Test("Executor advances enter, loop, and exit then records cooldown")
func executorCompletesLifecycleAndRecordsCooldown() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "turn.window",
        activity: .turn(targetYaw: 1),
        cooldownSeconds: 30
    )
    var executor = ActivityExecutor(position: .zero)
    let request = scheduled(definition, priority: .autonomousIdle, at: now)

    _ = executor.start(request, definition: definition, at: now)
    #expect(executor.status.phase == .enter)
    #expect(executor.advancePhase(at: now) == [
        .phaseChanged(activityID: definition.id, phase: .loop),
    ])
    #expect(executor.advancePhase(at: now) == [
        .phaseChanged(activityID: definition.id, phase: .exit),
    ])
    #expect(executor.advancePhase(at: now) == [
        .completed(activityID: definition.id),
        .enteredSafeIdle,
    ])
    #expect(executor.status.activity == .idle)
    #expect(executor.status.phase == .loop)
    #expect(executor.cooldowns[definition.id] == now.addingTimeInterval(30))
}

@Test("A higher-priority request interrupts then resumes prior work")
func executorInterruptsAndResumes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let background = executorDefinition(
        id: "music.sofa",
        activity: .listenMusic(anchorID: "sofa"),
        interruptible: true
    )
    let conversation = executorDefinition(
        id: "conversation.turn",
        activity: .turn(targetYaw: 0),
        interruptible: true
    )
    var executor = ActivityExecutor(position: .zero)
    _ = executor.start(
        scheduled(background, priority: .musicContext, at: now),
        definition: background,
        at: now
    )
    _ = try? executor.supplyApproach(ActivityApproachPlan(waypoints: [.zero]))
    _ = executor.advancePhase(at: now)
    #expect(executor.status.phase == .loop)

    let effects = executor.start(
        scheduled(conversation, priority: .activeConversation, at: now),
        definition: conversation,
        at: now
    )
    #expect(effects.contains(.phaseChanged(activityID: background.id, phase: .interrupt)))
    #expect(effects.contains(.suspended(activityID: background.id)))
    #expect(executor.status.activityID == conversation.id)

    _ = executor.advancePhase(at: now)
    _ = executor.advancePhase(at: now)
    let completion = executor.advancePhase(at: now)
    #expect(completion == [
        .completed(activityID: conversation.id),
        .resumed(activityID: background.id, phase: .loop),
    ])
    #expect(executor.status.activityID == background.id)
    #expect(executor.status.phase == .loop)
}

@Test("A new explicit user request replaces the current explicit request")
func executorReplacesEqualPriorityUserRequest() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = executorDefinition(
        id: "walk.center",
        activity: .walk(destinationID: "center")
    )
    let second = executorDefinition(
        id: "walk.kitchen",
        activity: .walk(destinationID: "kitchen")
    )
    var executor = ActivityExecutor(position: .zero)
    _ = executor.start(
        scheduled(first, priority: .explicitUserRequest, at: now),
        definition: first,
        at: now
    )

    let effects = executor.start(
        scheduled(
            second,
            priority: .explicitUserRequest,
            at: now.addingTimeInterval(1)
        ),
        definition: second,
        at: now.addingTimeInterval(1)
    )

    #expect(effects.contains(.cancelled(activityID: first.id)))
    #expect(effects.contains {
        if case .requestPath(_, destinationID: "kitchen") = $0 { true }
        else { false }
    })
    #expect(executor.status.activityID == second.id)
    #expect(executor.cooldowns[first.id] == nil)
}

@Test("Executor rejects interruption of protected work")
func executorRejectsProtectedInterruption() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let protected = executorDefinition(
        id: "sit.protected",
        activity: .sit(anchorID: "chair"),
        interruptible: false
    )
    let urgent = executorDefinition(id: "turn.urgent", activity: .turn(targetYaw: 0))
    var executor = ActivityExecutor(position: .zero)
    _ = executor.start(
        scheduled(protected, priority: .autonomousIdle, at: now),
        definition: protected,
        at: now
    )

    let effects = executor.start(
        scheduled(urgent, priority: .explicitUserRequest, at: now),
        definition: urgent,
        at: now
    )

    #expect(effects == [.rejected(activityID: urgent.id, reason: .notInterruptible)])
    #expect(executor.status.activityID == protected.id)
}

@Test("Executor cancel clears the active run and enters safe idle")
func executorCancelsActiveRun() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "read.cancelled",
        activity: .gaze(targetID: "book")
    )
    var executor = ActivityExecutor(position: .zero)
    _ = executor.start(
        scheduled(definition, priority: .autonomousIdle, at: now),
        definition: definition,
        at: now
    )

    let effects = executor.cancel(at: now)

    #expect(effects == [
        .cancelled(activityID: definition.id),
        .enteredSafeIdle,
    ])
    #expect(executor.status.activityID == nil)
    #expect(executor.status.activity == .idle)
}

@Test("Executor stop clears suspended work instead of resuming it")
func executorStopsAllRuns() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let background = executorDefinition(
        id: "music.background",
        activity: .listenMusic(anchorID: "sofa")
    )
    let foreground = executorDefinition(
        id: "turn.foreground",
        activity: .turn(targetYaw: 1)
    )
    var executor = ActivityExecutor(position: .zero)
    _ = executor.start(
        scheduled(background, priority: .musicContext, at: now),
        definition: background,
        at: now
    )
    _ = executor.start(
        scheduled(foreground, priority: .activeConversation, at: now),
        definition: foreground,
        at: now
    )

    let effects = executor.stop(at: now)

    #expect(effects == [
        .cancelled(activityID: foreground.id),
        .enteredSafeIdle,
    ])
    #expect(executor.status.activityID == nil)
    #expect(executor.advancePhase(at: now).isEmpty)
}

@Test("Path failure reports failed and falls back to safe idle")
func executorFallsBackAfterPathFailure() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "sit.missing",
        activity: .sit(anchorID: "missing")
    )
    var executor = ActivityExecutor(position: .zero)
    _ = executor.start(
        scheduled(definition, priority: .autonomousIdle, at: now),
        definition: definition,
        at: now
    )

    let effects = executor.fail(.pathUnavailable, at: now)

    #expect(effects == [
        .phaseChanged(activityID: definition.id, phase: .failed),
        .failed(activityID: definition.id, reason: .pathUnavailable),
        .enteredSafeIdle,
    ])
    #expect(executor.status.activity == .idle)
    #expect(executor.status.phase == .loop)
}

@Test("Executor rejects a path whose endpoint is free but segment crosses a wall")
func executorRejectsPathCrossingWall() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.behind-wall",
        activity: .walk(destinationID: "behind-wall")
    )
    let collision = MutableTraversalWorld(blockingX: 0.5)
    var executor = ActivityExecutor(
        position: .zero,
        walkingSpeed: 1,
        collisionQuery: collision,
        capsule: WorldCapsule(radius: 0.2, height: 1.8),
        maximumStepHeight: 0.3
    )
    _ = executor.start(
        scheduled(definition, priority: .autonomousIdle, at: now),
        definition: definition,
        at: now
    )

    let effects = try executor.supplyApproach(
        ActivityApproachPlan(waypoints: [WorldVector3(x: 1, y: 0, z: 0)])
    )

    #expect(effects == [
        .phaseChanged(activityID: definition.id, phase: .failed),
        .failed(activityID: definition.id, reason: .blocked),
        .enteredSafeIdle,
    ])
    #expect(executor.status.position == .zero)
    #expect(executor.status.activity == .idle)
}

@Test("Executor rechecks collision before every movement when the world changes")
func executorStopsWhenTraversalBecomesBlocked() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.dynamic-wall",
        activity: .walk(destinationID: "dynamic-wall")
    )
    let collision = MutableTraversalWorld()
    var executor = ActivityExecutor(
        position: .zero,
        walkingSpeed: 1,
        collisionQuery: collision,
        capsule: WorldCapsule(radius: 0.2, height: 1.8),
        maximumStepHeight: 0.3
    )
    _ = executor.start(
        scheduled(definition, priority: .autonomousIdle, at: now),
        definition: definition,
        at: now
    )
    #expect(try executor.supplyApproach(
        ActivityApproachPlan(waypoints: [WorldVector3(x: 1, y: 0, z: 0)])
    ).isEmpty)

    collision.setBlockingX(0.5)
    let effects = executor.tick(deltaTime: 1)

    #expect(effects == [
        .phaseChanged(activityID: definition.id, phase: .failed),
        .failed(activityID: definition.id, reason: .blocked),
        .enteredSafeIdle,
    ])
    #expect(executor.status.position == .zero)
    #expect(executor.status.activity == .idle)
}

@Test("Executor grounds every walking step on a non-flat mesh")
func executorGroundsEveryWalkingStep() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.slope",
        activity: .walk(destinationID: "slope")
    )
    let collision = SlopedGroundWorld(risePerMeter: 0.04)
    var executor = ActivityExecutor(
        position: .zero,
        walkingSpeed: 0.45,
        collisionQuery: collision,
        capsule: WorldCapsule(radius: 0.12, height: 0.9),
        maximumStepHeight: 0.3
    )
    _ = executor.start(
        scheduled(definition, priority: .explicitUserRequest, at: now),
        definition: definition,
        at: now
    )
    #expect(try executor.supplyApproach(
        ActivityApproachPlan(waypoints: [WorldVector3(x: 1, y: 0, z: 0)])
    ).isEmpty)

    var effects: [ActivityExecutionEffect] = []
    for _ in 0 ..< 90 where executor.status.phase == .approach {
        effects += executor.tick(deltaTime: 1.0 / 30.0)
    }

    #expect(!effects.contains(where: {
        if case .failed = $0 { return true }
        return false
    }))
    #expect(executor.status.phase == .enter)
    #expect(abs(executor.status.position.x - 1) < 0.0001)
    #expect(abs(executor.status.position.y - 0.04) < 0.0001)
}

@Test("Executor rejects a waypoint occupied by authored furniture")
func executorRejectsOccupiedWaypoint() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.into-furniture",
        activity: .walk(destinationID: "furniture")
    )
    let collision = MutableTraversalWorld(occupiedX: 1)
    var executor = ActivityExecutor(
        position: .zero,
        collisionQuery: collision
    )
    _ = executor.start(
        scheduled(definition, priority: .autonomousIdle, at: now),
        definition: definition,
        at: now
    )

    let effects = try executor.supplyApproach(
        ActivityApproachPlan(waypoints: [WorldVector3(x: 1, y: 0, z: 0)])
    )

    #expect(effects.contains(.failed(activityID: definition.id, reason: .blocked)))
    #expect(executor.status.position == .zero)
    #expect(executor.status.activity == .idle)
}

private func scheduled(
    _ definition: LifeActivityDefinition,
    priority: ActivityPriority,
    at date: Date
) -> ScheduledActivity {
    ScheduledActivity(
        id: "request.\(definition.id)",
        definitionID: definition.id,
        activity: definition.activity,
        priority: priority,
        requestedAt: date
    )
}

private func executorDefinition(
    id: String,
    activity: LifeActivity,
    interruptible: Bool = true,
    cooldownSeconds: TimeInterval = 0
) -> LifeActivityDefinition {
    LifeActivityDefinition(
        id: id,
        activity: activity,
        phases: LifeActivityPhase.allCases.map { ActivityPhaseContract(phase: $0) },
        interruptible: interruptible,
        cooldownSeconds: cooldownSeconds
    )
}

private extension WorldVector3 {
    static let zero = WorldVector3(x: 0, y: 0, z: 0)
}

private final class MutableTraversalWorld: WorldCollisionQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var blockingX: Float?
    private let occupiedX: Float?

    init(blockingX: Float? = nil, occupiedX: Float? = nil) {
        self.blockingX = blockingX
        self.occupiedX = occupiedX
    }

    func setBlockingX(_ value: Float?) {
        lock.withLock {
            blockingX = value
        }
    }

    func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool {
        guard let occupiedX else { return true }
        return abs(position.x - occupiedX) > 0.0001
    }

    func groundHeight(at position: SIMD3<Float>) -> Float? {
        0
    }

    func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        lock.withLock {
            guard let blockingX else { return true }
            let minimumX = min(start.x, destination.x)
            let maximumX = max(start.x, destination.x)
            return blockingX < minimumX || blockingX > maximumX
        }
    }
}

private struct SlopedGroundWorld: WorldCollisionQuerying {
    let risePerMeter: Float

    func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool {
        abs(position.y - risePerMeter * position.x) < 0.0001
    }

    func groundHeight(at position: SIMD3<Float>) -> Float? {
        risePerMeter * position.x
    }
}

@Test("Placed props block the approach, and an unobstructed route is unchanged")
func executorConsultsCollisionWhenRouting() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let definition = executorDefinition(
        id: "walk.window",
        activity: .walk(destinationID: "wp.window")
    )
    // 唯一通路：spawn(0,0,0) → window(2,0,0)，没有替代边。
    let router = WaypointNavigationGraph(
        waypoints: [
            WorldWaypoint(id: "wp.spawn", position: .zero, arrivalRadius: 0.1, enabled: true),
            WorldWaypoint(
                id: "wp.window",
                position: WorldVector3(x: 2, y: 0, z: 0),
                arrivalRadius: 0.1,
                enabled: true
            ),
        ],
        routes: [
            WorldRoute(
                id: "route.window",
                waypointIDs: ["wp.spawn", "wp.window"],
                bidirectional: true,
                enabled: true
            ),
        ]
    )

    // 一块合成平地。注意**不能**用空的 CollisionVolumeWorld 代表"无障碍"：它没有地面，
    // groundHeight 返回 nil，于是 canTraverse 处处失败 —— 那不是无障碍世界。
    let floor = [
        WorldTriangle(
            SIMD3<Float>(-10, 0, -10), SIMD3<Float>(10, 0, -10), SIMD3<Float>(10, 0, 10)
        ),
        WorldTriangle(
            SIMD3<Float>(-10, 0, -10), SIMD3<Float>(10, 0, 10), SIMD3<Float>(-10, 0, 10)
        ),
    ]

    // 1) 无障碍：接入 collisionQuery 之后，正常路径必须与今天完全一致（走完并进入 enter）。
    var clear = ActivityExecutor(
        position: .zero,
        walkingSpeed: 2,
        collisionQuery: TriangleMeshCollisionWorld(triangles: floor)
    )
    _ = clear.start(
        scheduled(definition, priority: .explicitUserRequest, at: now),
        definition: definition,
        at: now
    )
    #expect(throws: Never.self) { try clear.acquireApproach(using: router) }
    #expect(clear.tick(deltaTime: 1).contains(
        .phaseChanged(activityID: definition.id, phase: .enter)
    ))
    #expect(clear.status.position == WorldVector3(x: 2, y: 0, z: 0))

    // 2) 在唯一通路上放一个阻塞体积：规划必须发现走不通并抛 unreachable。
    //    这条是"闭包真的被查询"的证据 —— 没有接线时它会照旧穿过去并规划成功。
    // 地面来自网格、障碍来自体积，与 App 里的 MarbleLivingCabinCollisionWorld 同构。
    // 刻意**不能**只留体积：那样就没有地面，canTraverse 会因为"没有地面"而失败，
    // 测试就会为错误的原因通过。
    let blocked = TestGroundWithObstacle(
        ground: TriangleMeshCollisionWorld(triangles: floor),
        obstacles: CollisionVolumeWorld(volumes: [
            WorldCollisionVolume(
                id: "prop.blocking",
                center: WorldVector3(x: 1, y: 0.9, z: 0),
                halfExtents: WorldVector3(x: 0.4, y: 0.9, z: 0.4),
                rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
                isBlocking: true
            ),
        ])
    )
    var executor = ActivityExecutor(
        position: .zero,
        walkingSpeed: 2,
        collisionQuery: blocked
    )
    _ = executor.start(
        scheduled(definition, priority: .explicitUserRequest, at: now),
        definition: definition,
        at: now
    )
    #expect(throws: WorldNavigationError.unreachable(destinationID: "wp.window")) {
        try executor.acquireApproach(using: router)
    }
}

/// 测试用的组合世界：地面取自网格，障碍取自体积（等价于 App 的
/// `MarbleLivingCabinCollisionWorld`）。分开的理由见上面 blocked 用例的注释。
private struct TestGroundWithObstacle: WorldCollisionQuerying {
    let ground: any WorldCollisionQuerying
    let obstacles: CollisionVolumeWorld

    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        ground.canOccupy(capsule, at: position) && obstacles.canOccupy(capsule, at: position)
    }

    func groundHeight(at position: SIMD3<Float>) -> Float? {
        ground.groundHeight(at: position)
    }
}

