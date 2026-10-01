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
    /// 判据分层的**类型前提**被违反：一次被当成"入库登记"的提交，候选状态里那件东西却在空间里。
    /// 分类错了就必须 fail-closed 拒绝，而不是悄悄跳过空间判据（见 `ResidentPropLayoutIntent`）。
    case inventoryRegistrationInSpace(String)
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
        // 拒绝文案与判据**同源**：上限只有一个定义，文案插值的就是它 ——
        // 改数字时文案自动跟着改，不可能再出现"判据与嘴上说的不是同一个数"。
        case .propTooLarge(let name): "\(name) 最长边超过 \(ResidentPropAttachmentEligibility.holdableLongestEdgeText)，只能摆放，暂时不能拿在手里。"
        case .activityActive: "居民正在进行正式活动，请先停止活动再拿起物件。"
        case .notHeld: "这个物件当前没有拿在手里。"
        case .inventoryRegistrationInSpace(let name): "入库登记只收未摆出的物件，\(name) 现在在空间里。"
        }
    }
}

/// 一次布局提交的**意图**：它决定这次提交要过哪一层判据。
///
/// 为什么必须是**类型**、而不是 `validate` 里的一个 `if isRegister { skip }`：
/// `WorldPropLayoutCommand` 是会长出新 case 的开放集合，而"这次提交碰不碰空间"是每加一个
/// case 都必须回答的问题。把它收成**唯一一处**对命令的穷尽 `switch`（`resolve(_:in:)`），
/// 编译器就会在有人加命令时逼他回答；散落的 `if` 只会让新命令悄悄沿用某一条默认值
/// —— 那正是"第二种真相"长出来的形状。
enum ResidentPropLayoutIntent: Equatable {
    /// **入库登记**：这件东西**不在空间里**（未摆出、也没拿在手上），没有落点可言。
    /// 判据只有归属与资产：物件身份 / 尺寸合法 / 资产存在且哈希自洽 / 请求幂等。
    /// **不得**要求承托面、可达、通道、与已摆物件不重叠 —— 库存里的东西不在空间里。
    case inventoryRegistration(objectID: String)
    /// **空间变更**：候选状态里"空间里有什么、它在哪"变了（新摆 / 移动 / 收起 / 手持 /
    /// 改尺寸 / 加能力 / 撤销）。判据是**全部**空间判据（`ResidentPropPlacementService.validate(_:)`，
    /// 一个字不放宽）。
    case spatialChange(objectID: String)
}

extension ResidentPropLayoutIntent {
    /// 命令 + 现状 → 意图的**唯一一份**换算。默认方向是 `.spatialChange`（fail-closed）：
    /// 只有能证明"这次提交不碰空间"的命令才是登记。
    ///
    /// `state` 是**提交前**的现状（`ResidentPropPlacementService.commit` 读的是
    /// `context.state`）：这里要回答的是"这件东西**现在**在不在空间里"。
    static func resolve(_ command: WorldPropLayoutCommand, in state: WorldState) -> Self {
        switch command {
        case let .register(prop):
            // `applyPropLayout(.register)` 写下的候选条目是 `isEnabled == false`：只多一条
            // 库存记录，空间里没有它 —— 承托面/互斥/通路这些判据连输入都没有。
            //
            // `.rebase`（历史存档自愈）走**同一层**：它改的不是"空间里有什么、它在哪"
            // （那条命令逐位钉住 `isEnabled`/位置/朝向/手持状态），而是"这件**已经登记过**
            // 的资产是什么"。判据清单因此与登记完全相同：物件身份 + 尺寸合法 + 资产存在且
            // 哈希自洽 + 请求幂等（见 `validateInventoryRegistration`）。
            return .inventoryRegistration(objectID: prop.objectID)
        case let .rebase(prop):
            // 历史存档自愈（`.rebase`）**不加新的一层**：它回答的仍然是登记那一层的问题
            // ——"这件东西属于谁、它的资产在不在"，而**不是**"它摆得下吗"。
            //
            // 为什么空间判据在这里判不了（而且不该判）：`validate(_:)` 的输入是承托几何
            // （`support()`，装修模式派生出来的那份网格），而自愈发生在**每一次资产准备**
            // （`synchronizeOwnedResidentProps` 的 5 秒周期）—— 那时候装修模式多半没开、
            // 网格是 nil ⇒ `validate` 一定抛 `environmentNotReady` ⇒ 自动修复**永远完不成**，
            // 那正是要修的缺陷（"永久卡住"）。所以这里与 `.register` 同层：身份 + 资产 +
            // 幂等，一个字都不放宽（`validateInventoryRegistration` 还是那一条判据）。
            //
            // 落点与"空间里有什么"**一个字节都没变**：`applyPropLayout(.rebase)` 只换派生
            // 字段（尺寸/高度基准/朝向），`isEnabled`/位置/朝向/手持状态逐位保持，
            // 而且那道"只许换派生字段"的守卫在世界状态那一层（fail-closed）。
            // 空间判据在**每一次**摆放/移动时照旧全跑（`spatialChange` 那一层没动）——
            // 修复之后用户把剑拿起来再放下，走的就是那条一个字不放宽的判据。
            return .inventoryRegistration(objectID: prop.objectID)
        case let .resize(objectID, _):
            // 改**库存里那件**的尺寸：没摆出来、也没拿在手里 ⇒ 空间里没有它。
            // 已摆出/在手的那一件仍然要走空间判据（footprint 变了）。
            guard let item = state.objectStates[objectID], !item.isEnabled,
                  state.heldProp?.objectID != objectID
            else { return .spatialChange(objectID: objectID) }
            return .inventoryRegistration(objectID: objectID)
        case let .place(objectID, _), let .withdraw(objectID), let .hold(objectID, _, _),
             let .adjustGrip(objectID, _, _), let .returnHeld(objectID, _),
             let .enableCapability(objectID, _):
            // 全部会改变"空间里有什么 / 它在哪"：place/hold/returnHeld 让物件进出空间，
            // withdraw 把它收起来，enableCapability 增删功能点锚点（通路判据的输入），
            // adjustGrip 只动手里那一份状态 —— 但它与 `returnState` 同族，一并保守处理。
            return .spatialChange(objectID: objectID)
        case .undo:
            // 撤销恢复的是**上一件物件在空间里的位置**（`layoutUndo`），默认保守。
            return .spatialChange(objectID: state.layoutUndo?.objectID ?? "")
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
    private let makeGripCalibration: (WorldGeneratedProp, String, PropAttachmentPoint) throws -> WorldPropGripCalibration
    init(context: WorldAgentContext,
         support: @escaping () -> ResidentPropPlacementSupport? = { nil },
         prepare: @escaping (WorldGeneratedProp) throws -> Void = { _ in },
         isCurrent: @escaping () -> Bool = { true },
         currentAvatarAssetID: @escaping () -> String? = { nil },
         makeGripCalibration: @escaping (WorldGeneratedProp, String, PropAttachmentPoint) throws -> WorldPropGripCalibration = { _,_,_ in
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

    /// 拿起来（默认右手）**或**把这件已经在手上的物件换到别的挂点。
    ///
    /// 换挂点走的还是 `.hold` 那条世界命令族里既有的 `.adjustGrip`：同一条归属轴、同一份
    /// `returnState`（放回哪儿仍然是拿起前那一处），所以"换挂点"不会顺手改掉"从哪儿来回哪儿去"。
    func holdCommand(objectID: String, point: PropAttachmentPoint = .rightHand) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard context.state.activeActivity == nil else { throw ResidentPropPlacementError.activityActive }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let prop = context.state.objectStates[objectID]?.generatedProp else { throw WorldPropLayoutError.invalidObject }
        // 已经挂在身上的是**同一件**物件 ⇒ 这是"换挂点"，不是"再拿一次"（`.hold` 会以
        // `heldPropAlreadyExists` 拒绝，而用户说的正是"把它挂到背后去"）。
        if let held = context.state.heldProp, held.objectID == objectID {
            guard held.avatarAssetID == avatarID else { throw ResidentPropPlacementError.avatarChanged }
            return try remountCommand(objectID: objectID, point: point, avatarID: avatarID, prop: prop)
        }
        guard context.state.heldProp == nil else {
            throw ResidentPropPlacementError.attachmentUnsupported("居民一次只能拿一件物件，请先放回手里的物件。")
        }
        // 手持尺寸闸门：**上限只有一处定义**（`ResidentPropAttachmentEligibility.holdableLongestEdgeMeters`），
        // 拒绝文案（本文件上面那条 `propTooLarge`）、系统提示词、面板注释读的都是它。
        // `holdEligibility` 也走这个方法 ⇒ 判据没有第二个入口。
        guard max(prop.size.x, max(prop.size.y, prop.size.z))
            <= ResidentPropAttachmentEligibility.holdableLongestEdgeMeters else {
            throw ResidentPropPlacementError.propTooLarge(prop.displayName)
        }
        return .hold(objectID: objectID, avatarAssetID: avatarID,
                     calibration: try makeGripCalibration(prop, avatarID, point))
    }

    /// 就地把这件已挂载的物件换到另一个挂点：新标定整份由**挂点定义**给出
    /// （偏移/朝向/握点都是那个挂点的默认值，不是把手的默认值套上去），
    /// 走 `.adjustGrip` —— 既有命令，不动摆放轴与归属轴，`returnState` 一个字不改。
    private func remountCommand(objectID: String, point: PropAttachmentPoint,
                                avatarID: String, prop: WorldGeneratedProp) throws -> WorldPropLayoutCommand {
        .adjustGrip(objectID: objectID, avatarAssetID: avatarID,
                    calibration: try makeGripCalibration(prop, avatarID, point))
    }

    func holdEligibility(objectID: String, point: PropAttachmentPoint = .rightHand) -> String? {
        do { _ = try holdCommand(objectID: objectID, point: point); return nil }
        catch { return error.localizedDescription }
    }

    func adjustGripCommand(objectID: String, localOffset: WorldVector3,
                           localRotation: WorldQuaternion) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let held = context.state.heldProp, held.objectID == objectID else { throw ResidentPropPlacementError.notHeld }
        guard held.avatarAssetID == avatarID else { throw ResidentPropPlacementError.avatarChanged }
        guard let item = context.state.objectStates[objectID], let existing = item.gripCalibration,
              existing.avatarAssetID == avatarID else {
            throw ResidentPropPlacementError.attachmentUnsupported("这个物件还没有当前居民的挂点标定。")
        }
        // 微调**只动偏移与朝向**，挂点跟着既有标定走（`existing.hand`）：在背后微调不会
        // 把东西挪回手里。
        return .adjustGrip(objectID: objectID, avatarAssetID: avatarID,
            calibration: .init(avatarAssetID: avatarID, hand: existing.hand,
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
        // 这次提交要过哪一层判据 —— 换算只有一处（`ResidentPropLayoutIntent.resolve`）。
        // 基线取**提交前**的现状："这件东西现在在不在空间里"是这条命令的属性。
        let baseline = context.state
        let intent = ResidentPropLayoutIntent.resolve(command, in: baseline)
        return try context.commitPropLayout(command, expectedLayoutRevision: expectedLayoutRevision, requestID: requestID) { state in
            switch intent {
            case let .inventoryRegistration(objectID):
                // 入库登记：**不**跑空间判据（见该函数的说明）。
                try validateInventoryRegistration(objectID: objectID, in: state, baseline: baseline)
            case .spatialChange:
                // 摆放/移动/收起/手持/能力/撤销：**今天全部**判据，一个字不放宽。
                try validate(state)
                for item in state.objectStates.values where item.isEnabled || state.heldProp?.objectID == item.generatedProp?.objectID {
                    if let prop = item.generatedProp { try prepare(prop) }
                }
            }
            guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
            try validateAttachmentAuthorization(command)
        }
    }

    /// **入库登记那一层**的判据：只回答"这件东西属于谁、它的资产在不在"。
    ///
    /// 它回答的**不是**"这件东西摆不摆得下"：库存里的东西不在空间里
    /// （`applyPropLayout(.register)` 写下的候选条目是 `isEnabled == false`），没有落点可判。
    /// 真机 2026-10-01 `2B 白色长剑` 的登记被"这里不是可以摆放的承托面"拒掉，而那句话判的
    /// 其实是**房间里已经摆出的斧头** —— 与这次登记毫无关系：那把剑在 `state.json` 里连一条
    /// `objectStates` 都没有，更谈不上落点（实测见 `tools/test-resident-prop-placement.swift`
    /// 的"已领取但入库被拒"那一节：把空间判据接回登记，它就会带着那个缺陷变红）。
    ///
    /// 判据清单（与"归属与资产"一一对应）：
    /// - **物件身份**：候选状态里必须有这条带 `generatedProp` 的库存条目，且 `objectID` 与这次
    ///   登记一致（尺寸合法性由 `WorldGeneratedProp.isValid` 回答，越界尺寸由
    ///   `WorldPropSizePolicy` 在 `applyPropLayout(.resize)` 里拒绝）；
    /// - **归属 / 资产存在且哈希自洽**：由宿主注入的 `prepare` 回答（生产宿主读的是
    ///   `residentOwnedPropAssets` 与渲染器已备好的那一份，两者都以回执的产物哈希为准）；
    /// - **请求幂等**：由 `WorldSimulation.applyPropLayout` 的 `layoutReceipts` 回答
    ///   （同一 `claimed.<jobID>` 重放不会写第二遍，也不会再涨 `layoutRevision`）。
    ///
    /// 另有一条**类型前提**在运行时被钉住：既然意图是"入库登记"，这次**新建**的那条库存条目
    /// 就必须不在空间里。分类错了（将来有人把一条会启用物件的命令归成登记）会在这里
    /// fail-closed 拒绝，而不是悄悄跳过空间判据。已有条目（幂等重放：`.register` 对已存在的
    /// 物件只补一条回执、从不改动它）不在候选里被改动，所以不在这里重判。
    private func validateInventoryRegistration(objectID: String,
                                               in state: WorldState,
                                               baseline: WorldState) throws {
        guard let item = state.objectStates[objectID], let prop = item.generatedProp,
              prop.objectID == objectID else {
            throw WorldPropLayoutError.invalidObject
        }
        if baseline.objectStates[objectID] == nil, item.isEnabled {
            throw ResidentPropPlacementError.inventoryRegistrationInSpace(prop.displayName)
        }
        try prepare(prop)
    }

    private func validateAttachmentAuthorization(_ command: WorldPropLayoutCommand) throws {
        let submittedAvatarID: String?
        switch command {
        case .hold(_, let avatarAssetID, _), .adjustGrip(_, let avatarAssetID, _), .returnHeld(_, let avatarAssetID):
            submittedAvatarID = avatarAssetID
        case .register, .place, .withdraw, .undo, .enableCapability, .resize, .rebase:
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
        // 这个循环只会看到**空间里**的物件（`WorldLayoutObstacles` 只报 `isEnabled` 的，
        // 外加手持物的保留放回位）。入库登记（`.register`）根本走不到这里 ——
        // 它走的是 `ResidentPropLayoutIntent.inventoryRegistration` 那一层，判据只有
        // 归属与资产（见 `validateInventoryRegistration`）。
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
