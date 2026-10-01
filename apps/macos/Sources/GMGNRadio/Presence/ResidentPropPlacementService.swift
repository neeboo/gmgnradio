import Foundation
import WorldRuntime

/// 摆放校验需要的承托几何。
///
/// 由建造模式的 `ResidentPropGridEditorModel` 提供。拿不到时摆放一律被拒绝
/// （fail-closed），而不是"随便放"。
struct ResidentPropPlacementSupport {
    let grid: PropSupportGrid
    let collision: any WorldPropSupportQuerying
    /// 「挡住居民走路」这条判据的全部输入。
    ///
    /// 现在的判据是**收窄后**的：从居民当前位置出发，还能不能走到每一个活动锚点
    /// （见 `WorldPlacementRouteMap`）。它替代了旧的"643 个路点 + 2354 条路线的
    /// 0.1 m 采样都必须空着"——后者在真机舱体上让地板一格都放不下。
    ///
    /// `nil` = 调用方拿不到移动图 ⇒ 这条判据**拒绝**（fail-closed），而不是跳过。
    var routeConstraint: RouteConstraint?

    /// 缺省 = 拿不到移动图 = 拒绝（fail-closed）。生产宿主必须显式给出。
    init(grid: PropSupportGrid,
         collision: any WorldPropSupportQuerying,
         routeConstraint: RouteConstraint? = nil) {
        self.grid = grid
        self.collision = collision
        self.routeConstraint = routeConstraint
    }

    struct RouteConstraint {
        let map: WorldPlacementRouteMap
        let anchorIDs: [String]
        let anchorPositions: [String: WorldVector3]
    }
}

enum ResidentPropPlacementError: Error, Equatable, LocalizedError {
    case inactiveContext, environmentNotReady, unknownSurface, outsideSurface, collision(String), blockedRoute(String)
    case blockedBySupport(PropSupportBlockReason)
    case avatarUnavailable, avatarChanged, attachmentUnsupported(String), propTooLarge(String), activityActive, notHeld
    var errorDescription: String? {
        switch self {
        case .inactiveContext: "当前空间或编辑操作已结束。"
        case .environmentNotReady: "空间碰撞数据尚未准备好，请稍后再摆放。"
        case .unknownSurface: "这里不是可以摆放的承托面。"
        case .blockedBySupport(let reason): reason.errorDescription
        case .outsideSurface: "物件超出了支撑面的范围。"
        case .collision(let name): "这里会碰到居民或物件：\(name)。"
        case .blockedRoute(let name): "摆在这里居民就走不到 \(name) 了。"
        case .avatarUnavailable: "当前没有可用于手持展示的居民。"
        case .avatarChanged: "居民已经更换，这次手持操作没有保存。"
        case .attachmentUnsupported(let reason): reason
        case .propTooLarge(let name): "\(name) 最长边超过 45 厘米，只能摆放，暂时不能拿在手里。"
        case .activityActive: "居民正在进行正式活动，请先停止活动再拿起物件。"
        case .notHeld: "这个物件当前没有拿在手里。"
        }
    }
}

@MainActor
final class ResidentPropPlacementService {
    let context: WorldAgentContext
    /// 承托几何的来源。默认 nil = 拿不到 = 不可摆放（fail-closed）。
    private let support: () -> ResidentPropPlacementSupport?
    private let prepare: (WorldGeneratedProp) throws -> Void
    private let isCurrent: () -> Bool
    private let currentAvatarAssetID: () -> String?
    private let makeGripCalibration: (WorldGeneratedProp, String) throws -> WorldPropGripCalibration
    init(context: WorldAgentContext,
         support: @escaping () -> ResidentPropPlacementSupport? = { nil },
         prepare: @escaping (WorldGeneratedProp) throws -> Void = { _ in },
         isCurrent: @escaping () -> Bool = { true },
         currentAvatarAssetID: @escaping () -> String? = { nil },
         makeGripCalibration: @escaping (WorldGeneratedProp, String) throws -> WorldPropGripCalibration = { _,_ in
             throw ResidentPropPlacementError.attachmentUnsupported("当前居民还没有右手展示适配。")
         }) {
        self.context = context; self.support = support; self.prepare = prepare; self.isCurrent = isCurrent
        self.currentAvatarAssetID = currentAvatarAssetID
        self.makeGripCalibration = makeGripCalibration
    }

    /// 供 `list_placement_surfaces` 工具列出的承托层。
    ///
    /// **不再逐个列出格子**：真实生活舱过滤后有 3,000+ 层，全列给 agent 既没用也读不完。
    /// 按**承托高度**归并成层（同一高度的所有格子是同一层），报出高度、格数与水平范围。
    /// `surface_id` 因此从"具名摆放面"变成"层标识"（`layer.<i>`）；实际能否摆放由位置决定，
    /// 由 `PropPlacementEvaluator` 判定。
    struct SupportLayerInfo: Equatable, Sendable {
        let id: String
        let supportHeight: Float
        let cellCount: Int
        let center: WorldVector3
        let halfExtents: WorldVector3
    }

    func listedSupportLayers() -> [SupportLayerInfo] {
        guard let grid = support()?.grid else { return [] }
        let spacing = grid.spacing
        guard spacing.isFinite, spacing > 0 else { return [] }
        var byHeight: [Float: [PropSupportLayerRef]] = [:]
        for layer in grid.layers { byHeight[layer.supportHeight, default: []].append(layer) }
        return byHeight.keys.sorted().enumerated().map { index, height in
            let layers = byHeight[height] ?? []
            var minimumX = Float.greatestFiniteMagnitude, maximumX = -Float.greatestFiniteMagnitude
            var minimumZ = Float.greatestFiniteMagnitude, maximumZ = -Float.greatestFiniteMagnitude
            for layer in layers {
                let x = Float(layer.column.x) * spacing
                let z = Float(layer.column.z) * spacing
                minimumX = min(minimumX, x); maximumX = max(maximumX, x + spacing)
                minimumZ = min(minimumZ, z); maximumZ = max(maximumZ, z + spacing)
            }
            guard minimumX.isFinite, minimumZ.isFinite else {
                return SupportLayerInfo(id: "layer.\(index)", supportHeight: height, cellCount: 0,
                                        center: .init(x: 0, y: height, z: 0), halfExtents: .init(x: 0, y: 0, z: 0))
            }
            // `center` 必须是**一个真实格心**，不能是层范围的质心：编辑器用它给未摆放的
            // 物件做初始位置，而校验要求位置落在格心上（否则首帧就会报"不是承托面"）。
            // 取列序最小的那一格，确定性。`halfExtents` 仍然是整层的水平范围，供 UI 展示。
            let first = layers.min { ($0.column.x, $0.column.z) < ($1.column.x, $1.column.z) }
            let anchorX = Float(first?.column.x ?? 0) * spacing + spacing * 0.5
            let anchorZ = Float(first?.column.z ?? 0) * spacing + spacing * 0.5
            return SupportLayerInfo(
                id: "layer.\(index)",
                supportHeight: height,
                cellCount: layers.count,
                center: .init(x: anchorX, y: height, z: anchorZ),
                halfExtents: .init(x: (maximumX - minimumX) / 2, y: 0, z: (maximumZ - minimumZ) / 2)
            )
        }
    }

    func holdCommand(objectID: String) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard context.state.activeActivity == nil else { throw ResidentPropPlacementError.activityActive }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let prop = context.state.objectStates[objectID]?.generatedProp else { throw WorldPropLayoutError.invalidObject }
        guard context.state.heldProp == nil else {
            throw ResidentPropPlacementError.attachmentUnsupported("居民一次只能拿一件物件，请先放回手里的物件。")
        }
        guard max(prop.size.x, max(prop.size.y, prop.size.z)) <= 0.45 else {
            throw ResidentPropPlacementError.propTooLarge(prop.displayName)
        }
        return .hold(objectID: objectID, avatarAssetID: avatarID,
                     calibration: try makeGripCalibration(prop, avatarID))
    }

    func holdEligibility(objectID: String) -> String? {
        do { _ = try holdCommand(objectID: objectID); return nil }
        catch { return error.localizedDescription }
    }

    func adjustGripCommand(objectID: String, localOffset: WorldVector3,
                           localRotation: WorldQuaternion) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let held = context.state.heldProp, held.objectID == objectID else { throw ResidentPropPlacementError.notHeld }
        guard held.avatarAssetID == avatarID else { throw ResidentPropPlacementError.avatarChanged }
        guard let item = context.state.objectStates[objectID], let existing = item.gripCalibration,
              existing.avatarAssetID == avatarID, existing.hand == .rightHand else {
            throw ResidentPropPlacementError.attachmentUnsupported("这个物件还没有当前居民的右手握点。")
        }
        return .adjustGrip(objectID: objectID, avatarAssetID: avatarID,
            calibration: .init(avatarAssetID: avatarID, hand: .rightHand,
                normalizedGrip: existing.normalizedGrip, localOffset: localOffset, localRotation: localRotation))
    }

    func returnHeldCommand(objectID: String) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let held = context.state.heldProp, held.objectID == objectID else { throw ResidentPropPlacementError.notHeld }
        guard held.avatarAssetID == avatarID else { throw ResidentPropPlacementError.avatarChanged }
        return .returnHeld(objectID: objectID, avatarAssetID: avatarID)
    }

    func preview(objectID: String, placement: WorldPropPlacement) throws -> WorldObjectState {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        return try previewState(objectID: objectID, placement: placement)
            .objectStates[objectID]!
    }

    /// `preview` 的**同步**形态，供"格子该是什么颜色"使用。
    ///
    /// 为什么要有它：格子的黄/红必须由**与落地完全相同的那条判定**决定（真机 2026-09-29 的
    /// 缺陷是"格子说可放、一点却被拒绝"）。而 `preview` 是 `async` —— 着色那条路是每帧
    /// 同步跑的（鼠标一动就要出新颜色），拿不到它的结果。这里把同一条判定（`validate`，
    /// 一个字都不改）暴露成同步调用，于是"格子颜色"与"落地"是**同一个函数**的返回值。
    ///
    /// 仍然 fail-closed：拒绝就是拒绝，抛出的原因就是光标旁那枚标签要显示的原因。
    func previewState(objectID: String, placement: WorldPropPlacement) throws -> WorldState {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        var candidate = WorldSimulation(restoring: context.state)
        try candidate.applyPropLayout(.place(objectID: objectID, placement: placement),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "preview.\(UUID())")
        try validate(candidate.state)
        return candidate.state
    }

    @discardableResult
    func commit(_ command: WorldPropLayoutCommand, expectedLayoutRevision: UInt64, requestID: String) throws -> WorldState {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        try validateAttachmentAuthorization(command)
        return try context.commitPropLayout(command, expectedLayoutRevision: expectedLayoutRevision, requestID: requestID) { state in
            try validate(state)
            for item in state.objectStates.values where item.isEnabled || state.heldProp?.objectID == item.generatedProp?.objectID {
                if let prop = item.generatedProp { try prepare(prop) }
            }
            guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
            try validateAttachmentAuthorization(command)
        }
    }

    private func validateAttachmentAuthorization(_ command: WorldPropLayoutCommand) throws {
        let submittedAvatarID: String?
        switch command {
        case .hold(_, let avatarAssetID, _), .adjustGrip(_, let avatarAssetID, _), .returnHeld(_, let avatarAssetID):
            submittedAvatarID = avatarAssetID
        case .register, .place, .withdraw, .undo, .enableCapability, .resize:
            submittedAvatarID = nil
        }
        if let submittedAvatarID {
            guard currentAvatarAssetID() == submittedAvatarID else { throw ResidentPropPlacementError.avatarChanged }
        }
    }

    private func validate(_ state: WorldState) throws {
        // 「世界障碍」只有一条来源：`WorldLayoutObstacles`（与运行时 `WorldAgentContext`
        // 消费的是同一份换算）。解不出碰撞体积的已摆物件**必须可见地拒绝**：
        // `compactMap` 的旧写法会把它静默丢掉，让它对这条判据（也对运行时）变成"无敌"。
        let obstacles = WorldLayoutObstacles.resolve(state)
        if let unmodelled = obstacles.unmodelledObjectIDs.first {
            throw ResidentPropPlacementError.blockedBySupport(.unmodelledPlacedProp(unmodelled))
        }
        // 编号 + 物件状态（尺寸/层要用）+ **同一个** 阻挡形状（运行时也读它）。
        //
        // 用 `.obstacles` 而不是 `.volumes`：前者是权威的一份，形状可以是 yaw 盒子**或**
        // 生成工作流给的碰撞代理（`collision_*`）。`.volumes` 只是"只认盒子的旧消费者"的
        // 保守投影（代理会被换成它的 yaw 外接盒），会假拒绝细长/凹形物件。
        var placed: [(String, WorldObjectState, WorldPropObstacle)] = obstacles.obstacles.compactMap { obstacle in
            if let item = state.objectStates[obstacle.id] { return (obstacle.id, item, obstacle) }
            if let held = state.heldProp, held.objectID == obstacle.id { return (obstacle.id, held.returnState, obstacle) }
            return nil
        }
        placed.sort { $0.0 < $1.0 }
        // 承托几何拿不到就一律拒绝（fail-closed），而不是"随便放"。
        //
        // 守卫在**循环里**是刻意的：`register`（只把物件收进库存、还没摆出来）没有承托面可判，
        // 于是它不需要承托几何也能成立；只有真的要判定"摆在哪"时才要求几何。
        for (id,item,obstacle) in placed {
            guard item.generatedProp?.objectID == id, let prop = item.generatedProp else {
                throw WorldPropLayoutError.invalidObject
            }
            guard let support = support() else { throw ResidentPropPlacementError.environmentNotReady }
            // 摆放校验 = 「格子 + footprint」：物件必须坐在**某一层格子**上，整块 footprint
            // 在该层放得下。网格、阻挡体积、已放物件、净空、越界全部由评估器判定。
            // 因此状态里的 surfaceID 现在只是一个随状态存下来的标签，不再参与校验。
            guard let layerRef = Self.supportLayer(at: item.transform.position, grid: support.grid) else {
                throw ResidentPropPlacementError.unknownSurface
            }
            // footprint 的朝向取**物件自己的** yaw（权威、与代理/盒子的形状无关）；
            // 尺寸取 `effectiveSize`（有权威尺寸时以它为准，没有就是 app 量的那一份）。
            let rotation = item.transform.rotation
            let yaw = atan2(2*(rotation.w*rotation.y),1-2*rotation.y*rotation.y)
            let size = prop.effectiveSize
            let footprint = WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw)
            if let reason = PropPlacementEvaluator.evaluate(
                footprint: footprint,
                height: size.y,
                at: layerRef,
                grid: support.grid,
                collision: support.collision,
                blockingVolumes: context.manifest.collisionVolumes.filter(\.isBlocking),
                placedObstacles: placed.filter { $0.0 != id }.map(\.2)
            ) {
                throw ResidentPropPlacementError.blockedBySupport(reason)
            }
            // 这里**不再**额外做一次 `context.hasEnvironmentClearance`：那个判据用的是
            // 箱体的**外接圆半径**胶囊（咖啡机 0.35×0.57 → 半径 0.334 m，而箱体半宽只有
            // 0.175×0.285），并要求这么粗的圆柱从箱底起整段空着。评估器已经用**真实 OBB**
            // 对局部三角形做了 SAT 判定，还单独做了独立体积的 OBB-OBB 判定 —— 两者都更精确，
            // 那句胶囊检查只会制造假拒绝（实测：真实舱体地面上它把可放格数压到几乎为零）。
        }
        // 「别把居民关在里面 / 别把唯一通路堵死」——**收窄后**的这一条判据。
        //
        // 旧实现（2026-09-29 之前）要求：居民当前位置、**全部 643 个路点**、6 个活动锚点、
        // 以及 2354 条路线的 0.1 m 采样点，全都能容纳 0.25 m 的站立胶囊。真机实测：
        // 格子说"可放"的 273 个去重格被服务拒绝 273/273，理由全是 `blockedRoute(waypoint …)`；
        // 存档 9 条摆放回执**全部**落在展示台 y=0.52，地面层一条都没有。也就是说那条判据
        // 实际上禁止了一切地面装修。
        //
        // 为什么它过分：导航图是烘焙产物、**运行时本来就会绕路**（惰性重规划：路由器在提议
        // 路径上逐段问 `canTraverse`，遇到受阻的有向边就记下来改道，见
        // `WorldNavigationRouting.route(from:to:canTraverse:)`）。所以"家具压住某个中间路点"
        // 不是致命错误 —— 真实的房间装修就是允许你在走道上放东西，居民绕过去。
        //
        // 为什么不能干脆不检查：把**唯一通路**（门口/独木桥）堵死，目标锚点就永久不可达，
        // 那次活动会永久失败，而用户看到的仍是一格绿。所以保留的正是这条**真的会坏掉**的
        // 约束：从居民当前位置出发，还能走到每一个活动锚点吗。
        //
        // 代价：用派生好的承托格子当移动图做一次 BFS（`WorldPlacementRouteMap`），
        // 每个节点 O(1)。不碰三角形网格 —— 真路由器每问一条边要 2.5 s（实测中位），
        // 一次摆放判定 16 s，鼠标一动跑不了。
        // 「别把居民夹在墙里」：居民**现在站的地方**不能被这件新家具压住。
        // 这一条与旧实现同口径（0.25 m / 1.8 m 的站立胶囊），只对居民自己这一个点判定。
        if !placed.isEmpty {
            let obstacles = CollisionVolumeWorld(obstacles: placed.map(\.2))
            guard obstacles.canOccupy(WorldCapsule(radius: 0.25, height: 1.8),
                                      at: SIMD3(state.agentTransform.position.x,
                                                state.agentTransform.position.y,
                                                state.agentTransform.position.z)) else {
                throw ResidentPropPlacementError.collision("居民")
            }
            // 「别把唯一通路堵死」——**收窄后**的这一条判据（见上面的长说明）。
            guard let support = support(), let constraint = support.routeConstraint else {
                throw ResidentPropPlacementError.environmentNotReady
            }
            // 锚点集合 = 世界固有锚点（随世界烘焙）+ **候选状态派生**出来的道具功能点锚点。
            //
            // 先试算、后提交：注册表从 `state`（候选）派生，所以判据看到的正是
            // "这件道具摆上去之后真实存在的锚点"，包括它**自己**的 pickup/interact ——
            // "移动之后居民还走得到新取物点吗"因此是同一条判据，而不是事后补一条。
            //
            // 派生失败（角色重复、两件道具抢同一个活动入口）⇒ 判据输入不成立 ⇒ 拒绝。
            let candidateRegistry: WorldPropAnchorRegistry
            do {
                candidateRegistry = try WorldPropAnchorRegistry.derive(
                    sources: context.propFunctionSources,
                    objectStates: state.objectStates
                )
            } catch {
                throw ResidentPropPlacementError.environmentNotReady
            }
            var anchorPositions = constraint.anchorPositions
            for (id, position) in candidateRegistry.routeAnchorPositions {
                anchorPositions[id] = position
            }
            var anchorIDSet = Set(constraint.anchorIDs)
            anchorIDSet.formUnion(candidateRegistry.routeAnchorIDs)
            // 移动图上的障碍 = **房间里现在所有**带阻挡体积的物件（含这一件候选）。
            // 把既有的也算进来，判据就同时覆盖"新家具和旧家具合起来把路堵死"。
            //
            // 被判定的东西就是上面那个 `obstacle`（= `WorldLayoutObstacles` 给的权威形状：
            // yaw 盒子**或**生成工作流给的碰撞代理），判定函数就是运行时那一份
            // （`WorldCapsuleClearance`，经 `WorldPlacementRouteMap.blockedNodes(obstacle:)`）
            // —— **判据只有一条**。
            //
            // 这里以前自己重建 footprint（尺寸 × yaw）再交给移动图，而移动图用**未旋转**的
            // 半尺寸去扩世界轴 AABB：真机那把 yaw=90° 的斧头因此漏挡 9 个、假挡 5 个节点。
            // 也不再因为"查不到承托层"而 `continue` 跳过一件已放物件（那是静默 fail-open）。
            var occupied: Set<Int> = []
            for (_, _, obstacle) in placed {
                occupied.formUnion(constraint.map.blockedNodes(obstacle: obstacle))
            }
            switch constraint.map.decision(
                blockedNodes: occupied,
                anchorIDs: anchorIDSet.sorted(),
                anchorPositions: anchorPositions,
                residentPosition: state.agentTransform.position
            ) {
            case .allowed:
                break
            case .blockedAnchor(let id), .blockedRoute(let id):
                throw ResidentPropPlacementError.blockedRoute(id)
            case .unavailable:
                throw ResidentPropPlacementError.environmentNotReady
            }
        }
    }

    /// 从摆放位置反查它坐在哪一层格子上。
    ///
    /// 位置来自 `PropSupportGridMapping.snappedPlacementPosition`，也就是**格心**
    /// （列最小角 + 半格），所以列号必须先把半格减掉再取整。高度必须与该层的承托高度
    /// 一致（容差 0.005，与旧的摆放面校验同口径）。
    private static func supportLayer(at position: WorldVector3, grid: PropSupportGrid) -> PropSupportLayerRef? {
        let spacing = grid.spacing
        guard spacing.isFinite, spacing > 0 else { return nil }
        let column = PropSupportColumn(
            x: Int(((position.x - spacing * 0.5) / spacing).rounded()),
            z: Int(((position.z - spacing * 0.5) / spacing).rounded())
        )
        return grid.layers.first {
            $0.column == column && abs($0.supportHeight - position.y) < 0.005
        }
    }
}
