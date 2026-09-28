import Foundation
import Testing
import WorldRuntime
@testable import GMGNRadio

private let coffeeObjectID = "wish-prop-ebfc07be"
private let coffeeActivityID = "coffee.brew@wish-prop-ebfc07be"

private final class ReloadableStatePersistence: WorldStatePersisting, @unchecked Sendable {
    var latestState: WorldState?
    var loadCount = 0

    func save(_ state: WorldState) throws {
        latestState = state
    }

    func load() throws -> WorldState? {
        loadCount += 1
        return latestState
    }
}

private extension WorldManifest {
    static var propCapabilityFixture: WorldManifest {
        let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
        let unit = WorldVector3(x: 1, y: 1, z: 1)
        let transform: (Float, Float, Float) -> WorldTransform = { x, y, z in
            WorldTransform(position: WorldVector3(x: x, y: y, z: z), rotation: identity, scale: unit)
        }
        let phases = LifeActivityPhase.allCases.map { ActivityPhaseContract(phase: $0) }

        return WorldManifest(
            schemaVersion: 1,
            packageID: "capability-package",
            packageVersion: "1.0.0",
            worldID: "capability-room",
            displayName: "Capability Room",
            calibration: WorldCalibration(
                visualToGameplay: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                metersPerUnit: 1
            ),
            spawn: transform(0, 0, 0),
            collisionVolumes: [
                WorldCollisionVolume(
                    id: "ground",
                    center: WorldVector3(x: 2, y: -0.5, z: 0),
                    halfExtents: WorldVector3(x: 5, y: 0.5, z: 5),
                    rotation: identity,
                    isBlocking: true
                ),
            ],
            waypoints: [
                WorldWaypoint(id: "spawn", position: transform(0, 0, 0).position, arrivalRadius: 0.1, enabled: true),
                WorldWaypoint(id: "chair", position: transform(2, 0, 0).position, arrivalRadius: 0.1, enabled: true),
                WorldWaypoint(id: "mid", position: transform(0, 0, 2.8).position, arrivalRadius: 0.1, enabled: true),
                WorldWaypoint(id: "coffee-near", position: transform(2, 0, 2.8).position, arrivalRadius: 0.1, enabled: true),
            ],
            routes: [
                WorldRoute(id: "chair-link", waypointIDs: ["spawn", "chair"], bidirectional: true, enabled: true),
                WorldRoute(id: "coffee-link", waypointIDs: ["spawn", "mid", "coffee-near"], bidirectional: true, enabled: true),
            ],
            activities: [
                WorldActivityAnchor(
                    id: "sit-chair",
                    action: "sit",
                    entryWaypointID: "chair",
                    transform: transform(2, 0, 0),
                    motionID: nil,
                    propIDs: [],
                    interruptible: true
                ),
            ],
            activityDefinitions: [
                LifeActivityDefinition(
                    id: "sit-chair",
                    activity: .sit(anchorID: "sit-chair"),
                    phases: phases,
                    interruptible: true,
                    cooldownSeconds: 0
                ),
            ],
            cameras: [],
            capabilities: [
                WorldCapability("navigation"),
                .activity("sit-chair"),
            ],
            resources: []
        )
    }
}

@MainActor
private func makeCapabilityContext(
    persistence: (any WorldStatePersisting)? = nil,
    walkingSpeed: Float = 4
) throws -> WorldAgentContext {
    try WorldAgentContext(
        manifest: .propCapabilityFixture,
        startedAt: Date(timeIntervalSince1970: 1_000),
        persistence: persistence,
        walkingSpeed: walkingSpeed
    )
}

/// 合成承托几何：一张水平承托层。
///
/// 「具名摆放面」（`ResidentPropSupportSurface`）已从生产代码删除，摆放校验现在是
/// 「格子 + footprint」：物件必须坐在某一层格子上，整块占地由 `PropPlacementEvaluator`
/// 判定。这里按旧的 `resident.display_table`（中心 (2, 0.52, 2)、半长 0.5×0.5、yaw 0）
/// 派生一张等价的承托网格给 `support:`，而不是把断言改成空壳。
private struct FlatSupport: WorldPropSupportQuerying {
    let minimumX: Float
    let maximumX: Float
    let minimumZ: Float
    let maximumZ: Float
    let height: Float

    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }

    /// 遵守 `groundHeight` 的 y 受限契约：只报不高于查询点的承托面，列扫描才会收敛。
    func groundHeight(at position: SIMD3<Float>) -> Float? {
        guard position.x >= minimumX, position.x <= maximumX,
              position.z >= minimumZ, position.z <= maximumZ else { return nil }
        return height <= position.y + 0.05 ? height : nil
    }

    func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool { true }

    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        guard bounds.maximumX >= minimumX, bounds.minimumX <= maximumX,
              bounds.maximumZ >= minimumZ, bounds.minimumZ <= maximumZ else { return [] }
        let a = SIMD3<Float>(minimumX, height, minimumZ)
        let b = SIMD3<Float>(maximumX, height, minimumZ)
        let c = SIMD3<Float>(maximumX, height, maximumZ)
        let d = SIMD3<Float>(minimumX, height, maximumZ)
        return [WorldTriangle(a, b, c), WorldTriangle(a, c, d)]
    }
}

private let capabilitySupportWorld = FlatSupport(
    minimumX: 1, maximumX: 3, minimumZ: 1, maximumZ: 3, height: 0.52
)

private let capabilitySupport: ResidentPropPlacementSupport = {
    let bounds = WorldPlanarBounds(
        minimumX: capabilitySupportWorld.minimumX, maximumX: capabilitySupportWorld.maximumX,
        minimumZ: capabilitySupportWorld.minimumZ, maximumZ: capabilitySupportWorld.maximumZ
    )
    let grid = PropSupportGridBuilder.build(
        collision: capabilitySupportWorld,
        bounds: bounds,
        seed: WorldVector3(x: 2, y: 0.52, z: 2),
        parameters: PropSupportGridParameters()
    )
    return ResidentPropPlacementSupport(grid: grid, collision: capabilitySupportWorld)
}()

@MainActor
private func bindPlacedCoffeeMachine(in context: WorldAgentContext) throws {
    let prop = WorldGeneratedProp(
        objectID: coffeeObjectID,
        sourceWishID: "wish-ebfc07be",
        assetID: "asset-espresso",
        displayName: "E2E-0907 咖啡机",
        size: WorldVector3(x: 0.29, y: 0.35, z: 0.47),
        sourceHeight: 2
    )
    try context.commitPropLayout(.register(prop), expectedLayoutRevision: 0, requestID: "claim") { _ in }
    try context.commitPropLayout(
        .place(objectID: coffeeObjectID,
            placement: .init(surfaceID: "resident.display_table",
                position: WorldVector3(x: 2, y: 0.52, z: 2), yaw: 0)),
        expectedLayoutRevision: 1, requestID: "place"
    ) { _ in }
}

@MainActor
private func advanceToEnterPhase(_ context: WorldAgentContext) throws {
    for _ in 0..<24 {
        guard context.snapshot.activeActivity?.phase != .enter else { return }
        try context.tick(deltaTime: 0.5)
    }
}

@MainActor
@Test
func unboundPropStaysInertUntilCapabilityIsExplicitlyBound() throws {
    let context = try makeCapabilityContext()
    try bindPlacedCoffeeMachine(in: context)

    #expect(!context.snapshot.activities.contains { $0.id == coffeeActivityID })
    #expect(throws: WorldAgentContextError.unknownActivity(coffeeActivityID)) {
        try context.startActivity(id: coffeeActivityID)
    }

    try context.commitPropLayout(
        .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "bind"
    ) { _ in }

    let option = try #require(context.snapshot.activities.first { $0.id == coffeeActivityID })
    #expect(option.action == "interact")
    #expect(option.entryPlaceID == "coffee-near", "操作位点必须是相对物件的可达路点")
    #expect(context.isPropCapabilityActivity(coffeeActivityID))
    #expect(context.propActivityIDs(objectID: coffeeObjectID) == [coffeeActivityID])
    #expect(context.activityCatalog.definition(id: coffeeActivityID)?.displayName == "冲泡一杯咖啡")
}

@MainActor
@Test
func boundPropUsageWalksFacesAndCompletesOnlyThroughMatchingPlaybackReceipt() throws {
    let context = try makeCapabilityContext()
    try bindPlacedCoffeeMachine(in: context)
    try context.commitPropLayout(
        .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "bind"
    ) { _ in }

    try context.startActivity(id: coffeeActivityID)
    try advanceToEnterPhase(context)

    #expect(context.snapshot.activeActivity?.id == coffeeActivityID)
    #expect(context.snapshot.activeActivity?.phase == .enter)
    #expect(context.snapshot.agentTransform.position == WorldVector3(x: 2, y: 0, z: 2.8))
    #expect(abs(context.snapshot.agentTransform.rotation.y - sin(.pi / 2)) < 0.001,
            "到达后必须面向咖啡机")

    // Enter 阶段没有时长：计时推进与外来回执都不能制造完成。
    for _ in 0..<8 { try context.tick(deltaTime: 1) }
    #expect(context.snapshot.activeActivity?.phase == .enter,
            "没有真实播放回执时，咖啡使用不得仅因时间推进而完成")
    try context.completeActivityPlayback(requestID: "foreign-receipt", phase: .enter)
    #expect(context.snapshot.activeActivity?.phase == .enter, "回执与当前运行不匹配时不得推进")

    try context.completeActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
    #expect(context.snapshot.activeActivity?.phase == .loop)
    try context.tick(deltaTime: 0.05)
    try context.tick(deltaTime: 0.05)
    #expect(context.snapshot.activeActivity == nil)
    #expect(context.events.contains {
        if case .activityCompleted(activityID: coffeeActivityID) = $0.kind { true } else { false }
    })

    // 冷却期内重启必须被拒绝；冷却过后同一能力可再次使用。
    #expect(throws: WorldAgentContextError.activityRejected(coffeeActivityID)) {
        try context.startActivity(id: coffeeActivityID)
    }
    try context.tick(deltaTime: 46)
    try context.startActivity(id: coffeeActivityID)
    try advanceToEnterPhase(context)

    try context.failActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
    #expect(context.snapshot.activeActivity == nil)
    #expect(context.events.contains {
        if case .activityFailed(activityID: coffeeActivityID, reason: "missingMotion") = $0.kind { true } else { false }
    })
}

@MainActor
@Test
func stopCancelsUsageAndWithdrawHidesTheActivityUntilReplaced() throws {
    let context = try makeCapabilityContext()
    try bindPlacedCoffeeMachine(in: context)
    try context.commitPropLayout(
        .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "bind"
    ) { _ in }

    try context.startActivity(id: coffeeActivityID)
    try context.stopActivity(reason: "用户取消")
    #expect(context.snapshot.activeActivity == nil)
    #expect(context.events.contains {
        if case .activityCancelled(activityID: coffeeActivityID, _) = $0.kind { true } else { false }
    })

    try context.commitPropLayout(
        .withdraw(objectID: coffeeObjectID),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "withdraw"
    ) { _ in }
    #expect(!context.snapshot.activities.contains { $0.id == coffeeActivityID })
    #expect(throws: WorldAgentContextError.unknownActivity(coffeeActivityID)) {
        try context.startActivity(id: coffeeActivityID)
    }

    // 能力绑定持久存在：重新摆出即恢复可发现，无需再次绑定。
    try context.commitPropLayout(
        .place(objectID: coffeeObjectID,
            placement: .init(surfaceID: "resident.display_table",
                position: WorldVector3(x: 2, y: 0.52, z: 2), yaw: 0)),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "replace"
    ) { _ in }
    #expect(context.snapshot.activities.contains { $0.id == coffeeActivityID })
}

@MainActor
@Test
func capabilityPersistsAndRestoresDiscoverabilityAndRunningUsage() throws {
    let persistence = ReloadableStatePersistence()
    let context = try makeCapabilityContext(persistence: persistence)
    try bindPlacedCoffeeMachine(in: context)
    try context.commitPropLayout(
        .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "bind"
    ) { _ in }
    try context.startActivity(id: coffeeActivityID)
    try advanceToEnterPhase(context)

    let reloaded = try makeCapabilityContext(persistence: persistence)
    #expect(reloaded.snapshot.activities.contains { $0.id == coffeeActivityID },
            "能力随世界状态持久化，重启后活动必须可重新发现")
    #expect(reloaded.snapshot.activeActivity?.id == coffeeActivityID,
            "运行中的使用必须随世界状态恢复")
    #expect(reloaded.currentActivityRequestID != nil)
    try reloaded.tick(deltaTime: 0.05)
    #expect(reloaded.snapshot.activeActivity != nil, "恢复后的活动仍受回执约束")
}

@MainActor
@Test
func dispatcherRejectsPropUsageWhenCurrentAvatarFormatLacksTheButtonMotion() async throws {
    let context = try makeCapabilityContext()
    try bindPlacedCoffeeMachine(in: context)
    try context.commitPropLayout(
        .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
        expectedLayoutRevision: context.state.layoutRevision, requestID: "bind"
    ) { _ in }

    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { true },
        context: context,
        availableActivity: { $0 != coffeeActivityID }
    )
    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "use-incompatible",
        name: "start_activity",
        argumentsJSON: Data(#"{"activity_id":"coffee.brew@wish-prop-ebfc07be"}"#.utf8)
    ))

    #expect(result.isError)
    let body = try JSONDecoder().decode(WorldAgentToolResponse.self, from: result.resultJSON)
    #expect(body.code == "activity_unavailable")
    #expect(context.snapshot.activeActivity == nil,
            "动作与当前角色不兼容时不得开始，也不得留下可计成功的运行")
}

@MainActor
@Test
func capabilityToolBindsReadsBackAndRequiresHumanRound() async throws {
    let context = try makeCapabilityContext()
    try bindPlacedCoffeeMachine(in: context)
    let service = ResidentPropPlacementService(context: context, support: { capabilitySupport })

    let arguments = try JSONSerialization.data(withJSONObject: [
        "object_id": coffeeObjectID,
        "capability": "coffee.brew",
        "layout_revision": 2,
    ])

    let background = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { true })
    let backgroundTool = try #require(background.tools.first { $0.name == "enable_prop_capability" })
    let denied = await backgroundTool.handle("bind-denied", arguments)
    #expect(denied.isError)
    #expect(try #require(JSONSerialization.jsonObject(with: denied.resultJSON) as? [String: Any])["code"] as? String == "human_guidance_required")

    let bound = ResidentPropToolBridge(service: service, allowsMutation: true, isCurrent: { true })
    let tool = try #require(bound.tools.first { $0.name == "enable_prop_capability" })
    #expect(tool.validate(try #require(JSONSerialization.jsonObject(with: arguments) as? [String: Any])))

    let result = await tool.handle("bind-1", arguments)
    #expect(result.isError == false)
    let payload = try #require(JSONSerialization.jsonObject(with: result.resultJSON) as? [String: Any])
    #expect(payload["interaction_status"] as? String == "capability_bound_use_only")
    let objects = try #require(payload["objects"] as? [[String: Any]])
    let boundObject = try #require(objects.first { ($0["object_id"] as? String) == coffeeObjectID })
    let capability = try #require(boundObject["capability"] as? [String: Any])
    #expect(capability["template_id"] as? String == "coffee.brew")
    #expect(capability["activity_id"] as? String == coffeeActivityID)
    #expect(context.isPropCapabilityActivity(coffeeActivityID))

    let badArguments = try JSONSerialization.data(withJSONObject: [
        "object_id": coffeeObjectID,
        "capability": "latte.art",
        "layout_revision": 3,
    ])
    let rejected = await tool.handle("bind-bad", badArguments)
    #expect(rejected.isError)
    #expect(try #require(JSONSerialization.jsonObject(with: rejected.resultJSON) as? [String: Any])["code"] as? String == "placement_rejected")
}
