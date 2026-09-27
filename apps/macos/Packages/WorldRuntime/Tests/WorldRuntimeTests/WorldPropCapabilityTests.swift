import Foundation
import Testing
@testable import WorldRuntime

private func layoutSimulation() -> WorldSimulation {
    WorldSimulation(restoring: WorldState(revision: 0, worldID: "room", worldTime: .distantPast,
        lastObservedWallTime: .distantPast, weather: .clear,
        agentTransform: WorldTransform(position: .init(x: 0,y: 0,z: 0),rotation: .init(x: 0,y: 0,z: 0,w: 1),scale: .init(x: 1,y: 1,z: 1))))
}

private let espressoMachine = WorldGeneratedProp(
    objectID: "wish-prop-ebfc07be",
    sourceWishID: "wish-ebfc07be",
    assetID: "asset-espresso",
    displayName: "E2E-0907 咖啡机",
    size: .init(x: 0.29150167, y: 0.35, z: 0.4719286),
    sourceHeight: 2
)

private func placedEspressoSimulation() throws -> WorldSimulation {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(espressoMachine), expectedLayoutRevision: 0, requestID: "claim")
    try sim.applyPropLayout(
        .place(objectID: espressoMachine.objectID,
            placement: .init(surfaceID: "resident.display_table",
                position: .init(x: -2.7, y: 0.52, z: -5), yaw: 0)),
        expectedLayoutRevision: 1, requestID: "place")
    return sim
}

@Test func capabilityBindingPersistsSurvivesRestoreAndRejectsUnknownTemplates() throws {
    var sim = try placedEspressoSimulation()
    let bindRevision = sim.state.layoutRevision
    try sim.applyPropLayout(
        .enableCapability(objectID: espressoMachine.objectID, templateID: "coffee.brew"),
        expectedLayoutRevision: bindRevision, requestID: "bind")

    let capability = try #require(sim.state.objectStates[espressoMachine.objectID]?.propCapability)
    #expect(capability == WorldPropCapability(objectID: espressoMachine.objectID, templateID: "coffee.brew"))
    #expect(sim.state.objectStates[espressoMachine.objectID]?.generatedProp == espressoMachine,
            "绑定能力不得改变领取资产身份")
    #expect(sim.state.layoutRevision == bindRevision + 1)
    #expect(sim.state.layoutReceipts["bind"] == .enableCapability(objectID: espressoMachine.objectID, templateID: "coffee.brew"))

    let restored = WorldSimulation(restoring: try JSONDecoder().decode(WorldState.self,
        from: JSONEncoder().encode(sim.state)))
    #expect(restored.state.objectStates[espressoMachine.objectID]?.propCapability == capability,
            "能力必须持久化并在重启后保留")

    let boundObject = sim.state.objectStates[espressoMachine.objectID]
    let boundLayoutRevision = sim.state.layoutRevision
    try sim.applyPropLayout(
        .enableCapability(objectID: espressoMachine.objectID, templateID: "coffee.brew"),
        expectedLayoutRevision: sim.state.layoutRevision, requestID: "rebind")
    #expect(sim.state.objectStates[espressoMachine.objectID] == boundObject,
            "重复绑定同一模板必须不改变物件状态")
    #expect(sim.state.layoutRevision == boundLayoutRevision, "重复绑定不得推进布局版本")
    #expect(throws: WorldPropLayoutError.unsupportedCapability(templateID: "latte.art")) {
        try sim.applyPropLayout(
            .enableCapability(objectID: espressoMachine.objectID, templateID: "latte.art"),
            expectedLayoutRevision: sim.state.layoutRevision, requestID: "unsupported")
    }
    #expect(sim.state.objectStates[espressoMachine.objectID] == boundObject)
    #expect(throws: WorldPropLayoutError.invalidObject) {
        try sim.applyPropLayout(
            .enableCapability(objectID: "background", templateID: "coffee.brew"),
            expectedLayoutRevision: sim.state.layoutRevision, requestID: "unknown-object")
    }
    #expect(sim.state.objectStates[espressoMachine.objectID] == boundObject)

    try sim.applyPropLayout(.withdraw(objectID: espressoMachine.objectID),
        expectedLayoutRevision: sim.state.layoutRevision, requestID: "withdraw")
    #expect(sim.state.objectStates[espressoMachine.objectID]?.isEnabled == false)
    #expect(sim.state.objectStates[espressoMachine.objectID]?.propCapability == capability,
            "收回保留能力绑定，使用由摆放状态另行拦截")
}

@Test func capabilityTemplateBuildsReceiptDrivenInteractDefinition() throws {
    let template = try #require(WorldPropActivityTemplate.supported["coffee.brew"])
    let definition = template.definition(objectID: espressoMachine.objectID)

    #expect(definition.id == "coffee.brew@wish-prop-ebfc07be")
    #expect(definition.activity == .interact(anchorID: espressoMachine.objectID))
    #expect(definition.interruptible)
    #expect(try ActivityCatalog(definitions: [definition]).definitions.count == 1,
            "模板定义必须自带全部六个阶段才能进入活动目录")

    let enter = try #require(definition.contract(for: .enter))
    #expect(enter.durationSeconds == nil, "enter 阶段只能由实际播放回执推进，不允许计时完成")
    #expect(!enter.motionIDs.isEmpty)

    let loop = try #require(definition.contract(for: .loop))
    #expect(loop.durationSeconds == 0, "回执到达后 loop/exit 立即收尾")
    #expect(loop.motionIDs.isEmpty, "不得引用未批准的生成喝咖啡动作")
    #expect(definition.contract(for: .exit)?.durationSeconds == 0)

    let approach = try #require(definition.contract(for: .approach))
    #expect(approach.motionIDs.contains("gmgn.motion.bones.walk-loop-vrm"))
    #expect(approach.requiredAnchorIDs == [espressoMachine.objectID])
}

@Test func operationAnchorCandidatesRankStandableWaypointsDeterministically() {
    func waypoint(_ id: String, _ x: Float, _ z: Float, enabled: Bool = true) -> WorldWaypoint {
        WorldWaypoint(id: id, position: .init(x: x, y: 0, z: z), arrivalRadius: 0.1, enabled: enabled)
    }
    // 机器 footprint（半宽 0.145/0.235）外扩胶囊半径 0.2 的区域不可站。
    func standable(_ position: WorldVector3) -> Bool {
        !(abs(position.x) < 0.345 && abs(position.z + 5) < 0.435)
    }
    let candidates = WorldPropActivityTemplate.operationAnchorCandidates(
        propCenter: WorldVector3(x: 0, y: 0.52, z: -5),
        waypoints: [
            waypoint("inside-footprint", 0, -4.9),
            waypoint("near", 0, -4.55),
            waypoint("near-far", 0, -4.4),
            waypoint("disabled", 0.1, -4.7, enabled: false),
            waypoint("tie-b", 0.15, -4.3),
            waypoint("tie-a", -0.15, -4.3),
            waypoint("beyond-discovery", 0, -2.4),
        ],
        canStand: standable
    )
    #expect(candidates.map(\.id) == ["near", "near-far", "tie-a", "tie-b"],
        "锚点按中心距离排序、等距按 ID、剔除禁用/占地内/超出发现半径")
}

@Test func finalApproachMarchStopsAtFirstBlockedStepAndRequiresReach() {
    let propCenter = WorldVector3(x: 0, y: 0.52, z: -5)
    let half = WorldVector3(x: 0.145, y: 0.175, z: 0.235)
    // 模型：台缘把胶囊挡在 z <= -4.15，机器 footprint+capsule 区域不可站。
    func occupiable(_ position: WorldVector3) -> Bool {
        guard position.z <= -4.15 else { return false }
        return !(abs(position.x) < 0.345 && abs(position.z + 5) < 0.435)
    }
    let approach = try? #require(WorldPropActivityTemplate.finalApproachPoint(
        from: WorldVector3(x: 0, y: 0, z: -4.35),
        propCenter: propCenter, propYaw: 0, propHalfExtents: half,
        resolve: { occupiable($0) ? $0 : nil }
    ))
    #expect(approach?.z == -4.4, "第一候选（z=-4.40，边缘距 0.365m）已进入可达窗口，立即作为站位")

    // 一步都无法推进时显式不可用，不得隔空按键。
    let blocked = WorldPropActivityTemplate.finalApproachPoint(
        from: WorldVector3(x: 0, y: 0, z: -4.35),
        propCenter: propCenter, propYaw: 0, propHalfExtents: half,
        resolve: { _ in nil }
    )
    #expect(blocked == nil, "碰撞完全不允许接近时必须返回 nil")
}

@Test func shippedDisplayTablePlacementStaysOperableThroughVerifiedFinalApproach() {
    // 真实同几何复刻：机器在展示台中心 (-2.7, 0.52, -5)；台体西缘 x=-3.15 把
    // 胶囊（r=0.2）挡在 x <= -3.35。最近合法路点 wp.auto.x-7.z-10.h0 (-3.5,-5)
    // 距机器西缘 0.654m，超出 0.6m 按键窗口；经碰撞核验的最终接近把站位推进
    // 到台缘 (-3.4, -5)，不扩大手长、不伪造可达。
    let propCenter = WorldVector3(x: -2.7, y: 0.52, z: -5)
    let half = WorldVector3(x: 0.29150167 / 2, y: 0.35 / 2, z: 0.4719286 / 2)
    func occupiable(_ position: WorldVector3) -> WorldVector3? {
        guard position.x <= -3.35 else { return nil }
        return position
    }
    func waypoint(_ id: String, _ x: Float, _ z: Float) -> WorldWaypoint {
        WorldWaypoint(id: id, position: .init(x: x, y: 0, z: z), arrivalRadius: 0.1, enabled: true)
    }
    let candidates = WorldPropActivityTemplate.operationAnchorCandidates(
        propCenter: propCenter,
        waypoints: [
            waypoint("wp.auto.x-7.z-10.h0", -3.5, -5),
            waypoint("wp.auto.x-7.z-11.h0", -3.5, -5.5),
            waypoint("two-grids-west", -4, -5),
        ],
        canStand: { occupiable($0) != nil }
    )
    #expect(candidates.first?.id == "wp.auto.x-7.z-10.h0",
        "真实展示台摆放的锚点是最近的西侧网格路点")

    let approach = try? #require(WorldPropActivityTemplate.finalApproachPoint(
        from: candidates[0].position, propCenter: propCenter, propYaw: 0,
        propHalfExtents: half, resolve: occupiable
    ))
    #expect(approach?.x == -3.4 && approach?.z == -5,
        "最终接近把站位推进到台缘 (-3.4, -5)")
    let edge = WorldPropActivityTemplate.footprintEdgeDistance(
        from: approach!, propCenter: propCenter, propYaw: 0, propHalfExtents: half)
    #expect(edge <= WorldPropActivityTemplate.interactionReach, "站位进入按键可达窗口")

    // 台体把胶囊挡在更远处（x <= -3.0 之外不可站）时，任何站位都进不了
    // 可达窗口：活动显式不可用。
    let lockedOut = WorldPropActivityTemplate.finalApproachPoint(
        from: WorldVector3(x: -3.5, y: 0, z: -5), propCenter: propCenter,
        propYaw: 0, propHalfExtents: half,
        resolve: { $0.x <= -3.5 ? $0 : nil }
    )
    #expect(lockedOut == nil, "碰撞把胶囊挡在可达窗口之外时，活动显式不可用")
}

@Test func usageStatePersistsThroughReceiptsAndNeverFakesCompletion() throws {
    var sim = try placedEspressoSimulation()
    try sim.applyPropLayout(
        .enableCapability(objectID: espressoMachine.objectID, templateID: "coffee.brew"),
        expectedLayoutRevision: sim.state.layoutRevision, requestID: "bind")
    try sim.advance(by: 0, expectedRevision: sim.state.revision)

    // 没有回执就没有使用状态。
    #expect(sim.state.objectStates[espressoMachine.objectID]?.propUsage == nil)

    let running = WorldPropUsageState(templateID: "coffee.brew", status: .running,
        activityRequestID: "run-1", updatedAt: sim.state.worldTime)
    try sim.recordPropUsage(objectID: espressoMachine.objectID, usage: running,
        expectedRevision: sim.state.revision)
    #expect(sim.state.objectStates[espressoMachine.objectID]?.propUsage == running)

    let completed = WorldPropUsageState(templateID: "coffee.brew", status: .completed,
        activityRequestID: "run-1", updatedAt: sim.state.worldTime)
    try sim.recordPropUsage(objectID: espressoMachine.objectID, usage: completed,
        expectedRevision: sim.state.revision)

    // 使用状态随世界状态持久化。
    let restored = WorldSimulation(restoring: try JSONDecoder().decode(WorldState.self,
        from: JSONEncoder().encode(sim.state)))
    #expect(restored.state.objectStates[espressoMachine.objectID]?.propUsage == completed,
            "使用状态必须持久化并可在重启后读回")

    // 与绑定不符的写入必须被拒绝：旧活动不能给换绑物件"补完成"。
    #expect(throws: WorldPropLayoutError.invalidObject) {
        try sim.recordPropUsage(objectID: espressoMachine.objectID,
            usage: WorldPropUsageState(templateID: "latte.art", status: .completed,
                activityRequestID: "run-2", updatedAt: sim.state.worldTime),
            expectedRevision: sim.state.revision)
    }
    #expect(throws: WorldPropLayoutError.invalidObject) {
        try sim.recordPropUsage(objectID: "background",
            usage: WorldPropUsageState(templateID: "coffee.brew", status: .completed,
                activityRequestID: "run-2", updatedAt: sim.state.worldTime),
            expectedRevision: sim.state.revision)
    }
    // 超长原因必须被显式拒绝（调用方负责截断），不得静默接受或留下坏状态。
    #expect(throws: WorldPropLayoutError.invalidObject) {
        try sim.recordPropUsage(objectID: espressoMachine.objectID,
            usage: WorldPropUsageState(templateID: "coffee.brew", status: .stopped,
                activityRequestID: "run-2", updatedAt: sim.state.worldTime,
                reason: String(repeating: "长", count: 300)),
            expectedRevision: sim.state.revision)
    }

    // 运行中的使用在物件被移动或收回后必须变为 stopped，而不是保留或假完成。
    var runningSim = try placedEspressoSimulation()
    try runningSim.applyPropLayout(
        .enableCapability(objectID: espressoMachine.objectID, templateID: "coffee.brew"),
        expectedLayoutRevision: runningSim.state.layoutRevision, requestID: "bind")
    try runningSim.advance(by: 0, expectedRevision: runningSim.state.revision)
    try runningSim.recordPropUsage(objectID: espressoMachine.objectID,
        usage: WorldPropUsageState(templateID: "coffee.brew", status: .running,
            activityRequestID: "run-3", updatedAt: runningSim.state.worldTime),
        expectedRevision: runningSim.state.revision)
    try runningSim.applyPropLayout(.withdraw(objectID: espressoMachine.objectID),
        expectedLayoutRevision: runningSim.state.layoutRevision, requestID: "withdraw")
    let stoppedUsage = try #require(runningSim.state.objectStates[espressoMachine.objectID]?.propUsage)
    #expect(stoppedUsage.status == .stopped, "收回必须把运行中的使用标记为 stopped")
    #expect(stoppedUsage.activityRequestID == "run-3", "停止状态保留原运行请求，便于识别中断")

    // 收回后重新摆出不改写使用状态；完成只能来自真实回执。
    try runningSim.applyPropLayout(
        .place(objectID: espressoMachine.objectID,
            placement: .init(surfaceID: "resident.display_table",
                position: .init(x: -2.7, y: 0.52, z: -5), yaw: 0)),
        expectedLayoutRevision: runningSim.state.layoutRevision, requestID: "replace")
    #expect(runningSim.state.objectStates[espressoMachine.objectID]?.propUsage == stoppedUsage,
            "重新摆出不改写使用状态，完成只能来自真实回执")
}
