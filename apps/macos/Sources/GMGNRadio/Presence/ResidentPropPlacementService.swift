import Foundation
import WorldRuntime

/// 摆放校验需要的承托几何。
///
/// 由建造模式的 `ResidentPropGridEditorModel` 提供。拿不到时摆放一律被拒绝
/// （fail-closed），而不是"随便放"。
struct ResidentPropPlacementSupport {
    let grid: PropSupportGrid
    let collision: any WorldPropSupportQuerying
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
        case .blockedRoute(let name): "这里会挡住活动入口或通道：\(name)。"
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
        var candidate = WorldSimulation(restoring: context.state)
        try candidate.applyPropLayout(.place(objectID: objectID, placement: placement),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "preview.\(UUID())")
        try validate(candidate.state)
        return candidate.state.objectStates[objectID]!
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
        case .register, .place, .withdraw, .undo, .enableCapability:
            submittedAvatarID = nil
        }
        if let submittedAvatarID {
            guard currentAvatarAssetID() == submittedAvatarID else { throw ResidentPropPlacementError.avatarChanged }
        }
    }

    private func validate(_ state: WorldState) throws {
        var placed = state.objectStates.compactMap { id, item -> (String, WorldObjectState, WorldCollisionVolume)? in
            guard let volume = item.generatedCollisionVolume else { return nil }
            return (id,item,volume)
        }
        if let held = state.heldProp, held.returnState.isEnabled,
           let volume = held.returnState.generatedCollisionVolume {
            placed.append((held.objectID, held.returnState, volume))
        }
        // 承托几何拿不到就一律拒绝（fail-closed），而不是"随便放"。
        let support = support()
        for (id,item,box) in placed {
            guard item.generatedProp?.objectID == id, let prop = item.generatedProp else {
                throw WorldPropLayoutError.invalidObject
            }
            guard let support else { throw ResidentPropPlacementError.environmentNotReady }
            // 摆放校验 = 「格子 + footprint」：物件必须坐在**某一层格子**上，整块 footprint
            // 在该层放得下。网格、阻挡体积、已放物件、净空、越界全部由评估器判定。
            // 因此状态里的 surfaceID 现在只是一个随状态存下来的标签，不再参与校验。
            guard let layerRef = Self.supportLayer(at: item.transform.position, grid: support.grid) else {
                throw ResidentPropPlacementError.unknownSurface
            }
            let yaw = atan2(2*(box.rotation.w*box.rotation.y),1-2*box.rotation.y*box.rotation.y)
            let footprint = WorldPlanarFootprint(size: SIMD2(prop.size.x, prop.size.z), yaw: yaw)
            if let reason = PropPlacementEvaluator.evaluate(
                footprint: footprint,
                height: prop.size.y,
                at: layerRef,
                grid: support.grid,
                collision: support.collision,
                blockingVolumes: context.manifest.collisionVolumes.filter(\.isBlocking),
                placedProps: placed.filter { $0.0 != id }.map(\.2)
            ) {
                throw ResidentPropPlacementError.blockedBySupport(reason)
            }
            // 这里**不再**额外做一次 `context.hasEnvironmentClearance`：那个判据用的是
            // 箱体的**外接圆半径**胶囊（咖啡机 0.35×0.57 → 半径 0.334 m，而箱体半宽只有
            // 0.175×0.285），并要求这么粗的圆柱从箱底起整段空着。评估器已经用**真实 OBB**
            // 对局部三角形做了 SAT 判定，还单独做了独立体积的 OBB-OBB 判定 —— 两者都更精确，
            // 那句胶囊检查只会制造假拒绝（实测：真实舱体地面上它把可放格数压到几乎为零）。
        }
        let obstacles = CollisionVolumeWorld(volumes: placed.map(\.2))
        let capsule = WorldCapsule(radius: 0.25,height: 1.8)
        func clear(_ p: WorldVector3, radius: Float = 0.25) -> Bool {
            obstacles.canOccupy(.init(radius: max(0.25,radius),height: max(1.8,2*radius)),at: SIMD3(p.x,p.y,p.z))
        }
        guard clear(state.agentTransform.position) else { throw ResidentPropPlacementError.collision("居民") }
        for point in context.manifest.waypoints where point.enabled {
            guard clear(point.position,radius: point.arrivalRadius) else { throw ResidentPropPlacementError.blockedRoute(point.id) }
        }
        for activity in context.manifest.activities {
            guard clear(activity.transform.position) else { throw ResidentPropPlacementError.blockedRoute(activity.id) }
        }
        let points = Dictionary(uniqueKeysWithValues: context.manifest.waypoints.map { ($0.id,$0.position) })
        for route in context.manifest.routes where route.enabled {
            for pair in zip(route.waypointIDs,route.waypointIDs.dropFirst()) {
                guard let a=points[pair.0], let b=points[pair.1] else { continue }
                let dx=Double(b.x)-Double(a.x),dy=Double(b.y)-Double(a.y),dz=Double(b.z)-Double(a.z)
                let stepCount=ceil(sqrt(dx*dx+dy*dy+dz*dz)/0.1)
                guard stepCount.isFinite, stepCount <= 10_000 else { throw ResidentPropPlacementError.blockedRoute(route.id) }
                let start=SIMD3(a.x,a.y,a.z),end=SIMD3(b.x,b.y,b.z),d=end-start
                let steps=max(1,Int(stepCount))
                for i in 0...steps where !obstacles.canOccupy(capsule,at:start+d*(Float(i)/Float(steps))) {
                    throw ResidentPropPlacementError.blockedRoute(route.id)
                }
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
