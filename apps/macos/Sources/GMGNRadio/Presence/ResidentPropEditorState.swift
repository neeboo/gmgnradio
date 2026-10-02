import Foundation
import Combine
import os
import WorldRuntime

struct ResidentPropEditorSurface: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let position: WorldVector3
    /// 这一层上有多少个格子（同一承托高度的格子数）。
    ///
    /// 为什么要它：真实舱体的地面是**起伏网格**，按高度归并之后每个高度常常只有 1 格
    /// （实测 3,160 格 / 3,136 个高度）；而桌面、台面是平的，一层能有十几格。
    /// 未摆出的物件的初始落点因此先试**格子多**的层 —— 那才是"平整、放得下"的承托面。
    var cellCount: Int = 0
    /// 这一层的候选落点，**离出生点（`manifest.spawn`）近的排在前面**。
    ///
    /// 空数组表示"只有 `position` 这一个候选"（宿主拿不到网格时的退路，旧行为）。
    /// 顺序是**纯顺序**：能不能放由 `ResidentPropEditorState` 用 `preview`
    /// （= `ResidentPropPlacementService.preview`，fail-closed）逐个确认。
    var candidateAnchors: [WorldVector3] = []
}

/// 未摆出物件的初始落点候选：**纯排序，不含任何判定**。
///
/// 规则只有一句话：**承托面越平整越大越靠前**（同一高度上的格子越多越靠前），
/// 同一个承托面内**离出生点越近越靠前**（并列按列序，保证确定性）。
///
/// 为什么不在这里判"能不能放"：那有唯一一条既有路径（`PropPlacementEvaluator` 给悬停格子判、
/// `ResidentPropPlacementService.preview` 给落点判）。这里只提供**顺序**，判定留给它们。
enum ResidentPropInitialPlacement {
    /// 把网格里**同一承托高度**的格子按"离出生点近"排好，挂到对应的承托面上。
    ///
    /// `surfaces` 必须来自同一份网格（`ResidentPropPlacementService.listedSupportLayers()`），
    /// 所以按高度归并时能一一对上。`grid` 为 nil 或 `surfaces` 为空时原样返回 ——
    /// 那是"格子还在派生"，不是"没有候选"。
    static func fillingAnchors(
        _ surfaces: [ResidentPropEditorSurface],
        grid: PropSupportGrid?,
        spawn: WorldVector3,
        limitPerSurface: Int = 8
    ) -> [ResidentPropEditorSurface] {
        guard let grid, !surfaces.isEmpty, grid.spacing.isFinite, grid.spacing > 0 else { return surfaces }
        let spacing = grid.spacing
        var byHeight: [Float: [PropSupportLayerRef]] = [:]
        for layer in grid.layers { byHeight[layer.supportHeight, default: []].append(layer) }
        return surfaces.map { surface in
            guard let layers = byHeight[surface.position.y], !layers.isEmpty else { return surface }
            let ordered = layers
                .map { layer -> (distance: Float, x: Int, z: Int, position: WorldVector3) in
                    let x = Float(layer.column.x) * spacing + spacing * 0.5
                    let z = Float(layer.column.z) * spacing + spacing * 0.5
                    let dx = x - spawn.x, dz = z - spawn.z
                    return (dx * dx + dz * dz, layer.column.x, layer.column.z,
                            WorldVector3(x: x, y: layer.supportHeight, z: z))
                }
                .sorted { $0.distance == $1.distance
                    ? ($0.x, $0.z) < ($1.x, $1.z)
                    : $0.distance < $1.distance }
                .prefix(max(1, limitPerSurface))
            var enriched = surface
            enriched.candidateAnchors = ordered.map(\.position)
            return enriched
        }
    }
}

/// 场景里一次「点一下」该做什么 —— **唯一一份**分流规则。
///
/// 控制器只负责把"按下/抬起、clickCount、手上有没有物件、命中哪一件"喂进来，
/// 规则本身在这里（于是它可以离线逐项验证，不需要起窗口、也不需要真的鼠标）。
///
/// 与"点面板里那一行"是两条入口，但**同一条出口**：`select(objectID:)`。
enum ResidentPropSceneClick {
    enum Action: Equatable {
        /// 什么也不做（编辑器没开 / 没点中任何东西 / 双击）。
        case none
        /// 拿起场景里的已摆物件：进入携带态（`ResidentPropEditorState.select`）。
        case pickUp(String)
        /// 点地放下：既有落地通路（`onResidentPropGridCommit`）。
        case dropAtGrid
        /// 双击：把「刚在场景里拾起的那一下」撤回原位（preview 从不改世界），并复位相机。
        case reclaimPickUpAndResetCamera
    }

    /// 「抬起」这一次点击该做什么。
    ///
    /// - 编辑器没打开（或格子没激活）：**没有任何效果**（防误触）。
    /// - 手上有物件：任何单击都是**放下**，绝不是重新拾取 —— 否则"想把手里这件放稳"
    ///   会变成"把脚边那件又拿起来"。
    /// - 空手 + 单击命中已摆物件：拾取。
    /// - 双击：不拾取（既有的"复位相机"保留，见 `resolvePress`）。
    static func resolve(
        isEditorOpen: Bool,
        isBuildModeActive: Bool,
        isCarrying: Bool,
        clickCount: Int,
        hitObjectID: String?
    ) -> Action {
        guard isEditorOpen, isBuildModeActive else { return .none }
        if isCarrying { return .dropAtGrid }
        guard clickCount == 1, let hitObjectID else { return .none }
        return .pickUp(hitObjectID)
    }

    /// 「按下」这一次该做什么：只回答双击那一下要不要**撤回刚拾起的那一件**。
    ///
    /// 双击的第一下已经是一记合法的单击（已经拿起），第二下到来时把这一下撤回原位并复位相机 ——
    /// 净效果就是"双击不做拾取，相机照旧复位"。撤回不需要新状态：携带态只是 preview，
    /// **从不改世界**，所以撤回不会留下半次摆放。
    ///
    /// 判据里刻意**不问** `isCarrying`：拾取是异步的，第二下完全可能赶在它落地之前到来。
    /// `cancelPreview()` 两种时序都能兜住（它清 `selectedID`，`select` 的后续步骤会自己放弃）。
    static func resolvePress(
        isEditorOpen: Bool,
        isBuildModeActive: Bool,
        carryingStartedAtScenePointer: Bool,
        clickCount: Int
    ) -> Action {
        guard isEditorOpen, isBuildModeActive else { return .none }
        guard carryingStartedAtScenePointer, clickCount > 1 else { return .none }
        return .reclaimPickUpAndResetCamera
    }
}

// 「我的物件」列表的状态推导**只有一处**：
// `ResidentOwnershipProjection`（`Presence/ResidentOwnershipProjection.swift`），纯函数、
// 不实现 `Codable`、不落盘。这里原先并存的第二套目录投影与它的第四套状态文案已在
// 2026-10-02 仲裁后**逐字删除**：两套投影并存正是"东西静默消失"的形状，不许再回来。

struct ResidentPropEditorSnapshot: Equatable, Sendable {
    let worldID: String
    let revision: UInt64
    let objects: [WorldObjectState]
    let surfaces: [ResidentPropEditorSurface]
    let canUndo: Bool
    let heldProp: WorldHeldProp?
    let holdUnavailableReasons: [String: String]
    /// 每个物件 **× 每个挂点**的不可用原因（`objectID` → 挂点原始值 → 原因）。
    ///
    /// 为什么必须是二维的：真机 2026-10-02 用户说的是"把 2B 白色长剑挂到**背后**"，而当时
    /// 面板/工具手里只有一份**按右手**问出来的答案（`holdEligibility` 的省缺是 `.rightHand`），
    /// 于是右手的问题被当成了对背后的回答 —— 用户永远试不出背后到底行不行。
    ///
    /// 这一份里每一条都是**那个挂点自己**问出来的（`holdEligibility(objectID:point:)`），
    /// 判据一个字没改。缺项 = 那个挂点这里判不了 ⇒ 让世界那条命令自己去判（不冒充）。
    let holdUnavailableReasonsBySlot: [String: [String: String]]
    /// 承托几何**永远**不会来（派生的前置条件不成立：拿不到碰撞三角形或导航范围）。
    ///
    /// `false`（缺省）表示"格子还在派生"。这个字段只回答"还会不会好"，**不回答就绪与否** ——
    /// 就绪与否只看 `surfaces` 是不是空，所以两者不可能自相矛盾。
    let supportGeometryUnavailable: Bool
    /// 派生出来的**竖直面**（墙面）数量，以及其中"背朝墙能放"的格子数。
    ///
    /// 两者都来自同一次派生（`ResidentPropGridEditorModel`），面板只读、不判定。
    /// `wallPlaceableCells` 数的是**判据说可以**的格子（与地板摆放同一个出口），
    /// 不是"几何上看起来能靠"的格子。
    let wallFaces: Int
    let wallPlaceableCells: Int
    /// 「我的物件」的**全部事实**：`wishes.json` 的一条 job ∪ 世界文档的一件物件
    /// （含已删除的墓碑 —— 它不再被"跳过"，而是折叠进「已结束」，见唯一投影）。
    ///
    /// 这一份**不是列表状态** —— 行、对外状态、分组、折叠、动作全由唯一投影
    /// `ResidentOwnershipProjection` 从它**现算**。宿主只提供事实，一个字都不判断。
    ///
    /// 加它是因为真机 2026-10-02 用户那句「没领取也应该在这个列表，写着未领取啊」：
    /// 列表以前只读库存记录，于是**还没领取的许愿产物在这个列表里根本不存在**。
    let ownershipFacts: [OwnershipRowFacts]
    /// 组内确定性顺序（行标识 → `wishes.json` 里的下标，越大越新）。
    ///
    /// `WishMachineJob` 没有时间字段，所以"最近在前"只能用这个**确定性**的替代，
    /// 而不是假装有时间戳（见投影的 `ordered`）。
    let ownershipOrder: [String: Int]
    init(worldID: String, revision: UInt64, objects: [WorldObjectState], surfaces: [ResidentPropEditorSurface],
         canUndo: Bool, heldProp: WorldHeldProp? = nil, holdUnavailableReasons: [String: String] = [:],
         holdUnavailableReasonsBySlot: [String: [String: String]] = [:],
         supportGeometryUnavailable: Bool = false,
         wallFaces: Int = 0, wallPlaceableCells: Int = 0,
         ownershipFacts: [OwnershipRowFacts] = [], ownershipOrder: [String: Int] = [:]) {
        self.worldID = worldID; self.revision = revision; self.objects = objects; self.surfaces = surfaces
        self.canUndo = canUndo; self.heldProp = heldProp; self.holdUnavailableReasons = holdUnavailableReasons
        self.holdUnavailableReasonsBySlot = holdUnavailableReasonsBySlot
        self.supportGeometryUnavailable = supportGeometryUnavailable
        self.wallFaces = wallFaces; self.wallPlaceableCells = wallPlaceableCells
        self.ownershipFacts = ownershipFacts; self.ownershipOrder = ownershipOrder
    }
    static let empty = Self(worldID: "", revision: 0, objects: [], surfaces: [], canUndo: false,
                            heldProp: nil, holdUnavailableReasons: [:], supportGeometryUnavailable: false)

    /// 拿不到承托几何时，面板要**说出来**的原因（有承托面时不会被读到）。
    ///
    /// 「派生中」的措辞与点击落地那条（`GMGNRadioApp.residentPropGridCommit`）**逐字一致**：
    /// 同一个用户处境（格子还没出来）在两处说同一句话，工具测试钉住这一点。
    var supportUnavailableNotice: String {
        supportGeometryUnavailable ? Self.supportUnavailableText : Self.supportDerivingText
    }

    /// 「格子还在生成」——**只在真的有一次派生在跑的时候**才允许说。
    ///
    /// 它为什么必须是一个常量而不是散落的字面量：真机 2026-09-28，格子其实早就好了，
    /// 这句话却一直挂着，用户以为永远好不了。现在它与宿主的"派生令牌"一一对应。
    static let supportDerivingText = "格子还在生成，请稍候"
    /// 「拿不到摆放几何」——**不会好了**（没派生在跑、或者派生完了但一无所获）。
    static let supportUnavailableText = "当前空间拿不到摆放几何，暂时不能摆放"
}

/// Drafts never change the world. Both validation and saving go through the host's placement service.
@MainActor final class ResidentPropEditorState: ObservableObject {
    /// 宿主**答不出**现状（装修会话已经不在）时的那句话。
    ///
    /// 为什么必须是**第三句**：`refreshSnapshot` 返回 nil 与"返回一份承托面为空的现状"是
    /// 两件互斥的事实 —— 前者是"这次点击没有人会来救"，后者是"宿主说现在确实没有承托面"。
    /// 把 nil 当成"没有新信息"而沿用手里那份陈旧快照，就等于替宿主撒谎：真机上那句
    /// 「格子还在生成，请稍候」正是这么来的（它其实永远不会好，因为会话已经不在）。
    static let supportSessionUnavailableText = "这次点击没有拿到摆放几何的当前状态：请收起摆放面板后重新打开"
    /// 承托面到了之后，替换掉上面那两句过期提示的那一句。
    static let supportReadyText = "格子已就绪，可以摆放了"
    /// 需要随事实刷新/替换的承托面提示（业务提示不在此列，绝不覆盖）。
    static let supportNotices: Set<String> = [
        ResidentPropEditorSnapshot.supportDerivingText,
        ResidentPropEditorSnapshot.supportUnavailableText,
        supportSessionUnavailableText,
    ]
    @Published private(set) var snapshot = ResidentPropEditorSnapshot.empty
    @Published private(set) var isOpen = false
    @Published private(set) var selectedID: String?
    @Published private(set) var placement: WorldPropPlacement?
    @Published private(set) var candidate: WorldObjectState?
    @Published private(set) var isMoving = false
    @Published private(set) var isSaving = false
    @Published private(set) var notice = ""
    @Published var showsPlacedOnly = false
    /// 面板上"下一次拿/把它挪到哪"选中的挂点。
    ///
    /// **它只是面板上的选中格，不是挂载事实**：挂载事实住在 `WorldHeldProp.hand` 与标定里
    /// （两者都是持久状态）。所以显示时优先读世界那一份（`selectedHoldPoint`），
    /// 这里绝不复制一份"它现在挂在哪儿"。
    @Published var holdPoint: PropAttachmentPoint = .rightHand

    /// 那一行该显示哪个挂点：**已挂载就读世界状态**，否则读用户将要用的那一个。
    var selectedHoldPoint: PropAttachmentPoint {
        if isSelectedHeld, let held = snapshot.heldProp { return held.hand.attachmentPoint }
        return holdPoint
    }
    /// 「格子还没就绪时点的那一行」——一次**待办**，不是选中。
    ///
    /// 为什么需要它：真机一次格子派生 0.7 s（Debug 4.8 s），用户**打开装修就点行**，
    /// 那一下正好落在空档里，被回一句「格子还在生成，请稍候」就**丢掉了**；格子好了那句
    /// 提示会换成「可以摆放了」，但那次点击**不会被补做** —— 用户以为点过了，实际没有携带态。
    ///
    /// 三条约束（缺一条就会变成"过一会儿自己拿起一件东西"，比丢一次点击更糟）：
    /// - **只允许一件**：后一次点行**覆盖**前一次，绝不排队成一串；
    /// - 只在"承托面还没到 / 宿主答不出"时写入；承托面一到就由
    ///   `completePendingSelectIfReady()` 走**同一条出口**补做；
    /// - 任何"用户已经不要这件事了"的信号（改选另一件、关面板、Esc、退出装修、换世界、
    ///   保存中）都必须**作废**它。
    private var pendingSelectObjectID: String?
    /// 每一次"用户又点了一次 / 作废"都会 +1。补做是异步的（`update` 同步、`preview` 要等），
    /// 所以补做的任务必须带上**发起时的这一个数**：中间只要发生任何一件"用户已经不要这件事了"
    /// 的事，那个在飞的补做就自己失效 —— 否则会出现"关掉面板之后它还是把东西拿起来了"。
    private var selectIntentGeneration = 0
    /// 携带态待办的诊断日志（与宿主同一个 subsystem/category，`log show` 一条命令读全）。
    ///
    /// 为什么要它：这次修的是"用户点了行、却什么都没发生"。三个分支（记住意图 / 补做 /
    /// 作废）里任何一个是**静默**的，真机上就分不清"没记住""记住了但没补做"与
    /// "记住了又被别的事件作废了"。三条都是 `.notice`，不带 `--info` 也能看到。
    ///
    /// 这里用字面量 subsystem 而不是 `ProductIdentity`：本文件也被 `tools/*` 的离线 harness
    /// 直接编译，那些 harness 不装 App 的 `ProductIdentity`。值与 `ProductIdentity` 一致。
    private let livingWorldLogger = Logger(subsystem: "ai.gmgn.radio", category: "LivingWorld")
    var preview: (@MainActor (String, WorldPropPlacement) async throws -> WorldObjectState)?
    var commit: (@MainActor (WorldPropLayoutCommand, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    var hold: (@MainActor (String, PropAttachmentPoint, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    var adjustHeldGrip: (@MainActor (String, WorldVector3, WorldQuaternion, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    var returnHeld: (@MainActor (String, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    /// 按**现状**再要一份快照。宿主没有可答的上下文（没在装修、世界换了）时返回 nil。
    ///
    /// 唯一消费者是 `select(objectID:)`：见那里对"快照是推送来的、格子却异步派生"的说明。
    var refreshSnapshot: (@MainActor () -> ResidentPropEditorSnapshot?)?
    /// 列表里「未领取」那一行的动作 —— 接的是**既有**那条领取路径
    /// （`WishMachineCoordinator.claim`，与 agent 的 `claim_wish_output` 同一个出口）。
    ///
    /// 判据一个字都没放宽：人要到许愿机领取位置、托盘真的显示出这一件 ——
    /// 够不到时这里收到的是它自己那句具名原因（`WishMachineError.notAtMachine`），
    /// 面板照原话显示，**不替它编一句更"友好"的话**，也不绕过它。
    var claimWishOutput: (@MainActor (String) async throws -> Void)?
    /// 失败那一行的「重试」——接的是**既有**的 `WishMachineCoordinator.retry`
    /// （与 agent 的 `retry_wish_generation` 同一条）。能不能重试由那条路自己的 guard 回答
    /// （对它不接受的 stage，回的是 `WishMachineError.retryUnavailable` 的原话）。
    var retryWishOutput: (@MainActor (String) async throws -> Void)?
    /// Q4：「领取」够不到许愿机时那一枚「让居民去取」——走**既有的 agent 路径**
    /// （`claim_when_arrived`，居民自己走到取物点再领）。
    ///
    /// **不是**一条新的人类通道：这里只是替用户对居民说一句话，真正那一次领取仍然
    /// 由 `WishMachineCoordinator.claim` 的三条判据（`activityID == "wish_machine.collect"`、
    /// `distanceMeters ≤ 0.25`、`outputAvailable`）决定，一个字都没放宽。
    var askResidentToFetchOutput: (@MainActor (String) async throws -> Void)?
    /// 「已领取但没入库」那一行的下一步：走**既有**的入库补做重入
    /// （`synchronizeOwnedResidentProps` → 摆放服务的 `register`，幂等键仍是
    /// `claimed.<jobID>`）。它**不是** `retry`：`retryableStages` 刻意不含 `.claimed`。
    var retryInventoryOutput: (@MainActor (String) async throws -> Void)?
    var onPreviewChanged: @MainActor (WorldObjectState?) -> Void = { _ in }
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }
    /// 一个**面板**动作做完之后，把键盘焦点交回场景交互视图（参数是动作名，只给诊断日志用）。
    ///
    /// 为什么必须由宿主做：面板是 SwiftUI 的 `NSHostingView`，点完一行/一个按钮之后窗口的
    /// first responder 可能已经不在 `StageWorldInteractionView` 上，而"点完这一行接着在房间里
    /// 挪落点、按 `R`/`⇧R`/`,`/`.` 转、按 `Esc` 放回"正是这套编辑的**全部**手感 ——
    /// 焦点不在场景上时这些一个都不生效（真机 2026-09-29：点行进了携带态、圆环也画出来了，
    /// 但鼠标不跟手、圆环点不动、`R`/`,`/`.` 全没反应）。
    ///
    /// 宿主把它接到**既有的** `window.makeFirstResponder(worldInteractionView)` 上
    /// （与 `togglePropEditor()` 开面板时那条路径同一个出口），本类型不碰 responder chain。
    ///
    /// 只挂在"面板触发、接着要用户回场景操作"的动作上：`select` / `undo` / `withdraw`。
    /// 「居民右手」那套（`holdSelected` / `returnSelected` / `nudgeHeld` / `rotateHeld`）不挂：
    /// 它们的效果是**居民手里**的东西，用户是在面板上连点微调，抢焦点没有收益（也刻意不动
    /// 那套既有行为）。
    var onSceneFocusRequested: (@MainActor (String) -> Void)?
    /// 同一次用户意图内**已经提交过**的许愿动作（值来自 `WishActionLedger`）。
    ///
    /// 只由唯一那个动作出口 `performWishAction` 读写；行不再提供那个动作时由
    /// `pruneSubmittedWishActions()` 放掉（"这一件已经不是那个状态了"），
    /// 关面板 / 换世界由 `close()` 清空（"用户不要这件事了"）。台账里没有判据，
    /// 只有一个事实："这个 `(任务, 动作)` 在这次意图里已经交出去过一次"。
    private var submittedWishActions = WishActionLedger()
    /// **还在飞**的那一次许愿动作的键。与台账分开：台账记的是"已经交出去过"，
    /// 这一条记的是"还没回来"。
    ///
    /// 为什么必须有它：「让居民去取」那一次是动作**自己**先把摆放面板关掉再提交的，
    /// 而 `close()` 会清台账（"用户不要这件事了"）—— 关面板发生在 `record` 之前，
    /// 所以在飞的那一次只有这个键认得出第二次点击，否则它就成了"点了没反应"。
    private var inFlightWishActionKey: String?
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var draftRevision: UInt64?
    private var requestID = UUID().uuidString
    private var submittedCommand: WorldPropLayoutCommand?
    private var submittedActionKey: String?

    var objects: [WorldObjectState] {
        snapshot.objects.filter { item in
            item.generatedProp != nil && (!showsPlacedOnly || item.isEnabled || snapshot.heldProp?.objectID == item.generatedProp?.objectID)
        }
    }
    /// 「我的物件」这一页现在的**全部行** —— 由**唯一**投影 `ResidentOwnershipProjection`
    /// 从 `snapshot.ownershipFacts` 现算。本类型不推导状态、不另存一份、不缓存。
    ///
    /// 「房间里」这一档仍然是**已摆放**（语义一个字没改）：只保留投影判定为 `inRoom`
    /// 的那些行，于是未领取 / 失败 / 已删除的行不会污染这一页。
    var ownershipList: OwnershipList {
        var rows = snapshot.ownershipFacts.map(ResidentOwnershipProjection.row)
        if showsPlacedOnly { rows = rows.filter { $0.group == .inRoom } }
        return ResidentOwnershipProjection.list(rows, order: snapshot.ownershipOrder,
                                                showsEnded: showsEnded)
    }
    /// 「已结束」那一组是否展开。**默认折叠**（Q1：已删除的折叠可见，不是隐藏）。
    ///
    /// 它只是这一次点击的界面状态：不进快照、不落盘。行的状态仍然只由权威推导。
    @Published var showsEnded = false
    /// 某一件物件现在是不是**居民拿在手里 / 挂在身上**（唯一一份既有的持有事实）。
    func isHeld(_ objectID: String) -> Bool { snapshot.heldProp?.objectID == objectID }
    var selectedObject: WorldObjectState? { snapshot.objects.first { $0.generatedProp?.objectID == selectedID } }
    var isSelectedHeld: Bool { selectedID != nil && snapshot.heldProp?.objectID == selectedID }
    /// 「鼠标把物件拿在手上」——**派生**，不新增存储状态。
    ///
    /// 这样 confirm / cancelPreview / save 这些既有清理路径会自动把它清掉，不存在
    /// "忘了复位"的失效 bug。与「居民把物件拿在手里」（`isSelectedHeld` / `holdSelected()`
    /// 的 `WorldPropLayoutCommand.hold`，会持久化、绑居民右手、要求 2B 角色、最长边超过
    /// `ResidentPropAttachmentEligibility.holdableLongestEdgeText` 拒绝）是**两件不同的事**，命名上不要混：「在手」=鼠标携带，「手持/拿着看/放回」=居民携带。
    var isCarrying: Bool { isOpen && placement != nil && !isSelectedHeld }
    /// 当前摆放/建造模式算 footprint 用的物件尺寸：优先"正在拖动/待确认"的那个，否则用选中的。
    /// 没有选中任何物件时返回 nil，调用方退回"一格"。
    ///
    /// **唯一一份推导**：摆放校验（`residentPropGridHover` 的 `footprintSize`/`height`）与
    /// 场景内旋转手柄的外扩距离都读它——两处各抄一遍的话，手柄会偏离真正被判定/着色的 footprint。
    var footprint: (size: SIMD2<Float>, height: Float)? {
        guard let prop = (candidate ?? selectedObject)?.generatedProp else { return nil }
        // 尺寸只有一个出口：`effectiveSize`（判据、碰撞盒、红/绿格、渲染目标高度都读它）。
        return (SIMD2(prop.effectiveSize.x, prop.effectiveSize.z), prop.effectiveSize.y)
    }
    // 行上的状态文案**只有一份**：`OwnershipDisplayState.label` / `OwnershipSentence`
    // （都在 `ResidentOwnershipProjection`，视图直接读 `OwnershipRow.statusText`）。
    // 这里原先另有一份「手持中 / 已摆出 / 尚未摆放」的第二套文案 —— 2026-10-02 仲裁后
    // 随第二套投影一起退场：真机 2026-10-01「大剑还是消失了」要的是**可见**，
    // 而"已摆出"与投影的"已摆放"并存本身就又是一份真相。
    var selectedGrip: WorldPropGripCalibration? { isSelectedHeld ? selectedObject?.gripCalibration : nil }
    /// 选中那一行现在显示的"为什么拿不了"：问的是**用户此刻选的挂点**（`holdPoint`），
    /// 不是省缺的右手 —— 否则用户把挂点切到"背后"时，那一行还在说右手的问题。
    var selectedHoldUnavailableReason: String? {
        guard let selectedID else { return nil }
        if let reason = snapshot.holdUnavailableReasonsBySlot[selectedID]?[holdPoint.worldSlot.rawValue] {
            return reason
        }
        // 旧快照（没有逐挂点那一份）只有右手的答案：只在用户选的正是右手时读它，别拿它冒充别的挂点。
        guard holdPoint == .rightHand else { return nil }
        return snapshot.holdUnavailableReasons[selectedID]
    }
    /// 「这件物件挂在**这个**挂点上现在行不行」。
    ///
    /// 快照里 `holdUnavailableReasonsBySlot` 的每一条都是**那个挂点自己**问出来的
    /// （宿主对 `PropAttachmentPoint.allCases` 逐挂点调 `holdEligibility(objectID:point:)`）。
    /// 所以这里能直接回答用户真正选的那一个；缺项（旧快照 / 宿主没给这个挂点的答案）时返回
    /// nil = "这里判不了，让世界那条命令自己去判"，**绝不拿别的挂点的答案冒充**。
    private func availabilityReason(id: String, point: PropAttachmentPoint) -> String? {
        if let reason = snapshot.holdUnavailableReasonsBySlot[id]?[point.worldSlot.rawValue] {
            // 屏上那一行由 `notice` 显示；日志里必须有同一句，否则又只有屏幕、没有排障线索。
            livingWorldLogger.notice("摆件面板拒绝 step=hold-unavailable 挂点=\(point.rawValue, privacy: .public) 物件=\(id, privacy: .public) 原因=\(reason, privacy: .public)")
            return reason
        }
        guard point == .rightHand, let reason = snapshot.holdUnavailableReasons[id] else { return nil }
        livingWorldLogger.notice("摆件面板拒绝 step=hold-unavailable 挂点=\(point.rawValue, privacy: .public) 物件=\(id, privacy: .public) 原因=\(reason, privacy: .public)")
        return reason
    }
    var surface: ResidentPropEditorSurface? { snapshot.surfaces.first { $0.id == placement?.surfaceID } }
    var canConfirm: Bool { isOpen && !isSaving && candidate != nil && draftRevision == snapshot.revision }

    func update(_ value: ResidentPropEditorSnapshot) {
        if snapshot.worldID != value.worldID { close(); notice = "" }
        else if placement != nil && draftRevision != value.revision {
            previewGeneration = UUID()
            notice = "房间摆放已有变化，请重新选择位置"
            candidate = nil; onPreviewChanged(nil)
        }
        // 「提示必须与事实一致」也包括**事实变了但提示没刷新**：承托面到了以后，
        // 面板上还挂着"格子还在生成 / 拿不到摆放几何"就是在说一句过期的话 ——
        // 用户会以为永远好不了（真机 2026-09-28 的截图正是这句话挂在已经就绪的格子上）。
        // 只改写这三句承托面提示，业务提示（预览失败、保存结果…）一个字都不动。
        if !value.surfaces.isEmpty, Self.supportNotices.contains(notice) {
            notice = Self.supportReadyText
        }
        snapshot = value
        // 「已经交出去过一次」的台账随**投影**剪枝：行不再提供那个动作（换了动作、
        // 进了库存、已删除）就放掉，下一次点击是新的意图。
        pruneSubmittedWishActions()
        // 承托面到了 ⇒ 把"格子还没就绪时点的那一行"补做掉（见 `completePendingSelectIfReady`）。
        // 这是**唯一**的补做触发点：宿主在就绪那一刻重推快照，正是那次点击被浪费的地方。
        completePendingSelectIfReady()
    }
    /// 把许愿动作台账剪到"此刻投影仍然提供的动作"这一集合上。
    ///
    /// 判据不在这里：哪一行、给哪些动作，全部来自**唯一投影**（`snapshot.ownershipFacts`
    /// → `ResidentOwnershipProjection.row`）；本方法只做集合交集，不新增第二条可见性判据。
    private func pruneSubmittedWishActions() {
        let offered = Set(snapshot.ownershipFacts.map(ResidentOwnershipProjection.row).flatMap { row -> [String] in
            guard let jobID = row.key.jobID?.uuidString else { return [] }
            return row.actions.compactMap { action in
                Self.wishActionStep(for: action).map { WishActionLedger.key(jobID: jobID, step: $0) }
            }
        })
        submittedWishActions.keepOnly(offered)
    }
    /// 投影给的动作 → 唯一那个动作出口用的 `step` 名（与 `claimWish` / `retryWish` /
    /// `askResidentToFetch` / `retryWishInventory` 传进去的字面量一一对应）。
    ///
    /// 不是"动作到状态的映射"：它只回答"这一行现在给的那个按钮，走的是哪一个出口"，
    /// 仍然由投影决定**给不给**；给不出的动作（摆放/收回/删除）在这里返回 nil。
    static func wishActionStep(for action: OwnershipRowAction) -> String? {
        switch action {
        case .claim: "claim"
        case .askResidentToFetch: "ask-resident"
        case .retry: "retry"
        case .retryInventoryRegistration: "retry-inventory"
        case .place, .withdraw, .delete: nil
        }
    }
    func open() {
        guard !snapshot.worldID.isEmpty, !isOpen else { return }
        // 打开面板 = **新一次意图**开始，台账在这里清：「让居民去取」那一次是动作自己
        // 把面板关掉的，而 `close()` 清台账发生在 `record` 之前（关完面板才记账），
        // 所以关面板那一次清不掉自己记下的那条 —— 不在这里再清一次，重开面板后
        // 同一行会被误判成"重复提交"、再也点不动。
        submittedWishActions.removeAll()
        isOpen = true; onEditingChanged(true)
    }
    func close() {
        generation = UUID(); isSaving = false
        // 关面板 / 退出装修 / 换世界走的是同一条 `close()`：都是"用户不要这件事了"。
        // 待办必须在这里作废，否则格子就绪那一刻会**自己**拿起一件他从没在当前意图里选过的东西。
        clearPendingSelect(reason: "关闭面板、退出装修或换世界")
        // 许愿动作台账同一条纪律：面板关了，"这一次意图"就结束了，重开面板可以再点一次。
        submittedWishActions.removeAll()
        cancelPreview()
        if isOpen { isOpen = false; onEditingChanged(false) }
    }
    func cancelPreview() {
        // 双击撤回、外部取消都从这里走：同样是"不要这件事了"。
        clearPendingSelect(reason: "取消选择")
        previewGeneration = UUID(); candidate = nil; placement = nil; selectedID = nil
        draftRevision = nil; isMoving = false; notice = ""; onPreviewChanged(nil)
    }
    func escape() {
        // Esc 是"我不要这件事了"的最强信号：先作废待办，再按既有分支走
        // （两条分支各自也会清，这里是**明写**，便于真机日志一眼看出是 Esc 干的）。
        clearPendingSelect(reason: "Esc")
        // Saving can await asset preparation. Closing revokes the host's editing lease before it resumes.
        if isSaving { close() }
        else if selectedID != nil { cancelPreview() }
        else { close() }
    }
    /// 点一行 → 进入携带态（`isCarrying`）。
    ///
    /// **不信任手里的快照**：`surfaces` 是宿主**推送**来的字段，而格子派生是异步的
    /// （真实舱体一次 0.5 s，-Onone 6.6 s）。就绪那一刻的推送可能还没到，所以点一行时先按
    /// 现状要一份（`refreshSnapshot`）再判 —— 否则"格子已经画出来了、点一行却毫无反应"。
    ///
    /// **拿不到承托面时，这一次点击不许被丢掉**：真机 2026-09-28，用户打开装修就点行，
    /// 而格子要 0.7 s（Debug 4.8 s）才派生完，于是那一点正好落在空档里，被回一句
    /// "格子还在生成，请稍候"就没了 —— 格子好了那句提示会换成"可以摆放了"，但**那次点击
    /// 不会被补做**（用户以为点过了，实际没有携带态）。现在改成：这一次点击被**记住**，
    /// 承托面一到就由 `completePendingSelectIfReady()` 走**同一条出口**补做。
    func select(objectID: String) async {
        guard isOpen, !isSaving else { return }
        // 点行是**面板**动作：无论这一次是立刻进携带态、还是因为几何没到先记成待办
        // （`rememberPendingSelect`），用户接下来都在房间里等/看 —— 焦点现在就交回场景。
        handFocusBackToScene(trigger: "选择物件")
        // 用户又点了一次：上一次没能兑现的那次点行要么被这一次**覆盖**（这一次也进不了携带态
        // 时会被重新记住），要么被这一次**兑现**（这一次能进，走的就是下面同一条出口）。
        // 两条路都不该让它继续挂着 —— 待办**只允许一件**，绝不排队成一串。
        clearPendingSelect(reason: "用户又点了一次（后一次覆盖前一次）")
        await performSelect(objectID: objectID)
    }

    /// 面板动作的收尾：把键盘焦点交回场景交互视图（见 `onSceneFocusRequested`）。
    ///
    /// 唯一出口：任何一个面板动作要抢回焦点都走这里，不在调用点各写一遍。
    private func handFocusBackToScene(trigger: String) {
        onSceneFocusRequested?(trigger)
    }

    /// 点行的**唯一出口**：正常点击与"承托面到了以后补做那次待办"都走这里。
    ///
    /// 单独立出来就是为了让补做**不可能**另写一套逻辑：它进的仍是同一个 `select` 主体，
    /// 所以 fail-closed 一个字都没放宽（没有几何依旧进不了携带态）。
    private func performSelect(objectID: String) async {
        guard isOpen, !isSaving else { return }
        // 宿主答出来的那份是**唯一的现状**；`nil` 表示它答不出来（装修会话不在/世界换了）。
        // 这两件事在后面必须分开处理，所以这里留住"有没有答"这个事实本身。
        let refreshed = refreshSnapshot?()
        if let refreshed { update(refreshed) }
        guard isOpen else { return }
        // 行是从 `objects`（`snapshot.objects` 的过滤结果）画出来的，所以找不到只可能是
        // 快照刚好换了一版（例如世界被换掉）。那不是用户的动作失败，静默即可。
        guard let object = snapshot.objects.first(where: { $0.generatedProp?.objectID == objectID }) else { return }
        // 「必须有承托面」是**前置检查**，不是形式：`support` 同时给出初始落点 ——
        // `surfaceID` 与"未摆出物件的出生位置"（见下面的 `validate`）。拿不到就进不了携带态。
        // 但**绝不静默**，而且**绝不说谎**：用户点了那一行，必须看得见为什么还没反应。
        //
        // 两句提示的判据是不同的：
        // - 宿主答了现状（`refreshed != nil`）⇒ 用快照自己的说法：真的在生成 / 永远拿不到；
        // - 宿主答不出来（`refreshed == nil`）⇒ 不能说"还在生成"。没人会来救这次点击，
        //   说"请稍候"就是撒谎（真机 2026-09-28：格子早就好了，这句话却一直挂着）。
        guard let support = support(for: object) else {
            notice = refreshed == nil ? Self.supportSessionUnavailableText : snapshot.supportUnavailableNotice
            // 把这一次意图记下来：承托面一到就补做（提示先落定，日志里能读到用户看到的那句话）。
            rememberPendingSelect(objectID: objectID, hostAnswered: refreshed != nil)
            return
        }
        selectedID = objectID; draftRevision = snapshot.revision; requestID = UUID().uuidString
        if snapshot.heldProp?.objectID == objectID {
            placement = nil; candidate = nil; isMoving = false; notice = "手持展示中"; onPreviewChanged(nil)
            return
        }
        let q = object.transform.rotation
        let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        if object.isEnabled {
            // **已摆出的物件必须继续用自身的 transform**：它现在就在那儿，携带态只是把它
            // 原地"拿起来"，所以初始落点必须是它自己的位置与朝向。
            await validate(.init(surfaceID: support.id, position: object.transform.position, yaw: yaw))
            return
        }
        // 未摆出的物件（刚领的许愿产物）没有自己的 transform 可用。旧行为是固定退到那一层里
        // **列序最小**的那一格 —— 真实房间里那一格常常紧贴墙、家具或活动通道，于是勾和控件都
        // 出现了、footprint 却是红的，直到鼠标动一下才对。
        // 现在改成：按"承托面越平整越靠前、同面内离出生点越近越靠前"逐个用 `preview` 试，
        // **第一个真能放的就是初始落点**；判定只用既有的摆放服务，这里不新写几何。
        guard let initial = await firstPlaceablePlacement(objectID: objectID, yaw: yaw) else {
            // 试遍候选都不可放：保持现状（退回这一层的默认落点）并**明说**，不假装成功。
            let fallback = WorldPropPlacement(surfaceID: support.id, position: support.position, yaw: yaw)
            await validate(fallback)
            if candidate == nil { notice = "这里没有找到能放下它的位置：\(notice)" }
            return
        }
        await validate(initial)
    }

    /// 承托面还没到（或宿主答不出）⇒ 为这一次点行**记一个待办**。
    ///
    /// **只允许一件**：直接赋值，后一次点行覆盖前一次（绝不排队成一串）。
    /// 写入时机只有一处 —— `performSelect` 的承托守卫；所以待办永远是"用户点过、但还没兑现"
    /// 的那一件，不会凭空出现。
    private func rememberPendingSelect(objectID: String, hostAnswered: Bool) {
        pendingSelectObjectID = objectID
        livingWorldLogger.notice(
            "携带态待办：记住这次点行 objectID=\(objectID, privacy: .public) 宿主答出现状=\(hostAnswered, privacy: .public) 承托面=\(self.snapshot.surfaces.count, privacy: .public) 提示=\(self.notice, privacy: .public)"
        )
    }

    /// **作废**待办。每一个"用户已经不要这件事了"的信号都必须经过这里：
    /// 改选另一件（`select` 开头覆盖）、关面板 / 退出装修 / 换世界（`close`）、
    /// Esc（`escape`）、保存中（`save` / `saveAction`）。
    ///
    /// 少一处就会变成"过一会儿自己拿起一件东西" —— 那比原来那次点击被浪费更糟。
    private func clearPendingSelect(reason: String) {
        // 任何作废（哪怕此刻没有待办）都让**在飞的补做**失效：作废必须是无条件的。
        selectIntentGeneration &+= 1
        guard let objectID = pendingSelectObjectID else { return }
        pendingSelectObjectID = nil
        livingWorldLogger.notice(
            "携带态待办：作废 objectID=\(objectID, privacy: .public) 原因=\(reason, privacy: .public)"
        )
    }

    /// 宿主**答出了现状**、而且承托面**已经到**了 ⇒ 把那次没能兑现的点行**补做**掉。
    ///
    /// 唯一触发点：`update(_:)` 收到一份承托面非空的新快照（宿主在格子就绪那一刻的重推），
    /// 也就是真机上那次点击被浪费的地方。补做走 `performSelect`（与正常点行**完全同一条出口**），
    /// 所以 fail-closed 一个字都没放宽：没有几何仍然进不了携带态。
    /// 这里的 `snapshot.surfaces` 非空**就是**"几何到了"这个既有判据，不是新判据。
    private func completePendingSelectIfReady() {
        guard let objectID = pendingSelectObjectID, !snapshot.surfaces.isEmpty else { return }
        // 这里**只清待办、不作废**：这一件正是要补做的，绝不能让 clearPendingSelect 把它自己
        // 那次补做的令牌也一起作废掉。
        pendingSelectObjectID = nil
        let intent = selectIntentGeneration
        livingWorldLogger.notice(
            "携带态待办：承托面已到，补做这次点行 objectID=\(objectID, privacy: .public) 承托面=\(self.snapshot.surfaces.count, privacy: .public) Revision=\(self.snapshot.revision, privacy: .public)"
        )
        // 补做是异步的（要走 `preview`），而 `update` 是同步的：交给主线程的下一个回合。
        // 执行时重新确认这个意图**没有被更新的一次点击或任何作废事件取代** —— 中间用户可能
        // 已经关面板 / Esc / 保存 / 改选了另一件，那些事件各自会把令牌推走。
        Task { @MainActor [weak self] in
            guard let self, self.isOpen, !self.isSaving, self.selectIntentGeneration == intent else { return }
            await self.performSelect(objectID: objectID)
        }
    }

    /// 未摆出物件的初始落点：按候选顺序逐个问 `preview`，第一个非 nil 的就是它。
    ///
    /// - 候选顺序由宿主填进 `snapshot.surfaces`（`cellCount` 越大越靠前，同层内离出生点越近）；
    ///   拿不到网格时 `candidateAnchors` 为空，退回每一层的 `position`（旧行为）。
    /// - 判定**只有**一条：`preview`（= `ResidentPropPlacementService.preview`，fail-closed）。
    /// - `initialPlacementAttemptLimit` 是**主线程预算**：真实舱体一次 preview 约 5–13 ms
    ///   （-Onone；它要遍历全部承托层、活动通道与已放物件），不封顶就会在"放不下"的物件上
    ///   把主线程卡住。实测：0.2 m / 0.35×0.57 m / 0.45 m 三种尺寸都在**第 1 个候选**就成功。
    private func firstPlaceablePlacement(objectID: String, yaw: Float) async -> WorldPropPlacement? {
        guard let preview, !snapshot.surfaces.isEmpty else { return nil }
        // 承托面的顺序：格子多的在前（平整、成块的桌面/台面），并列时低的在前 —— 确定性。
        let ordered = snapshot.surfaces.sorted {
            $0.cellCount == $1.cellCount ? $0.position.y < $1.position.y : $0.cellCount > $1.cellCount
        }
        var attempts = 0
        for surface in ordered {
            let anchors = surface.candidateAnchors.isEmpty ? [surface.position] : surface.candidateAnchors
            for anchor in anchors {
                guard attempts < Self.initialPlacementAttemptLimit else { return nil }
                // 试的过程中用户可能已经取消选择、关掉编辑器或换了世界：那就别再往下试。
                guard isOpen, !isSaving, selectedID == objectID else { return nil }
                attempts += 1
                let placement = WorldPropPlacement(surfaceID: surface.id, position: anchor, yaw: yaw)
                if (try? await preview(objectID, placement)) != nil { return placement }
            }
        }
        return nil
    }

    /// 初始落点最多试几次 `preview`。见 `firstPlaceablePlacement` 的取舍说明。
    /// 上限**只有一处定义**：`RetryBackoff.swift` 的 `RetryBackoffSite.propPlacement`
    /// （这是主线程预算，不是等待；读同一个策略，语义与数值都不变）。
    static var initialPlacementAttemptLimit: Int {
        RetryBackoffSite.propPlacement.policy.maximumAttempts
    }

    /// 这一行现在能坐在哪一层承托面上。
    ///
    /// `supportSurfaceID` 是摆放时随状态存下来的**标签**，未摆出的物件没有它 —— 那时退回
    /// 第一层（`listedSupportLayers()` 按高度升序，第一层就是语义上的"地面"）。
    private func support(for object: WorldObjectState) -> ResidentPropEditorSurface? {
        snapshot.surfaces.first { $0.id == object.supportSurfaceID } ?? snapshot.surfaces.first
    }

    func selectSurface(_ id: String) async {
        guard !isSaving, let s = snapshot.surfaces.first(where: { $0.id == id }), selectedID != nil else { return }
        draftRevision = snapshot.revision
        await validate(.init(surfaceID: s.id, position: s.position, yaw: placement?.yaw ?? 0))
    }
    func toggleMoving() { guard !isSaving, placement != nil else { return }; isMoving.toggle() }
    func movePointer(to point: WorldVector3) async {
        guard !isSaving, let p = placement else { return }
        await validate(.init(surfaceID: p.surfaceID, position: point, yaw: p.yaw))
    }
    /// 建造模式：把预览挪到吸附后的格心。
    ///
    /// 与 `movePointer` 的差别有两点，都是建造模式需要的：
    /// - `surfaceID` 换成**层标识**（surfaceID 不再是具名摆放面）；
    /// - `yaw` 由调用方给（来自 `ResidentPropGridEditorModel.footprintYaw`），
    ///   这样 footprint 朝向只有一个真相来源，不会和编辑器里的旧值打架。
    func moveGridPointer(to point: WorldVector3, layerName: String, yaw: Float) async {
        guard !isSaving, placement != nil else { return }
        await validate(.init(surfaceID: layerName, position: point, yaw: yaw))
    }

    /// 建造模式的 90° 步进旋转。**全仓已无任何调用者**（旋转的唯一入口是
    /// `ResidentPropGridEditorModel.rotateFootprint(bySteps:)`，R / ⇧R / `,` / `.` /
    /// 场景内右键单击都走它）。这里保留只是为了"先报告、别删"；确认后应整段删除。
    func rotateQuarterTurn(bySteps steps: Int) async {
        guard !isSaving, let p = placement else { return }
        await validate(.init(surfaceID: p.surfaceID, position: p.position, yaw: p.yaw + Float(steps) * .pi / 2))
    }

    func pointerMissed() {
        guard !isSaving else { return }
        previewGeneration = UUID(); candidate = nil; onPreviewChanged(nil)
        notice = "指针没有落在当前支持面上"
    }
    func nudge(x: Float, z: Float) async {
        guard let p = placement else { return }
        await movePointer(to: .init(x: p.position.x + x, y: p.position.y, z: p.position.z + z))
    }
    /// 面板上的 45° 旋转按钮（`ResidentPropEditorView` 的「左转 45° / 右转 45°」）。
    ///
    /// ⚠️ 这条路径只改 `placement.yaw`，**是第二个 yaw 真相来源**（唯一真相是
    /// `ResidentPropGridEditorModel.footprintYaw`），下一次 `publishResidentPropGrid`
    /// 会把预览转回去。建造模式的手柄/按键**绝不**走这里。
    /// 本步（第 2 步）**没有删它**：删了会打断 `ResidentPropEditorView.swift:66-67` 的编译，
    /// 而那个文件属于后续的"面板瘦身"步（D10）。
    func rotate(_ direction: Float) async {
        guard !isSaving, let p = placement else { return }
        await validate(.init(surfaceID: p.surfaceID, position: p.position, yaw: p.yaw + direction * .pi / 4))
    }
    /// 「手上这一件现在在哪」= 把落点套在**它自己**的状态上。**显示专用**。
    ///
    /// 变换口径与 `WorldSimulation.applyPropLayout(.place)` 逐字一致（位置 + 绕 Y 的 yaw 四元数，
    /// 缩放沿用原件；`metadata` 原样带过去，所以 `generatedProp` 与已摆那一件**完全相同**，
    /// 宿主那条 `asset.prop == prop` 的资产归属判据一个字都没放宽）。
    ///
    /// 为什么必须由**落点**推出，而不是只信摆放服务：服务是 fail-closed 的判定入口 ——
    /// 落点被判不能放（真机实测：`blockedRoute`，挡住居民路点/通道）时它抛错，编辑器因此拿不到
    /// 任何状态，`onPreviewChanged` 只能收到 nil，渲染端于是继续画**原地那一件**。真机
    /// 2026-09-29：移动咖啡机时该次会话**全部 273 个"格子说可放"的落点都被服务拒绝**，
    /// 于是在手的物件一次都没跟过光标 —— 用户看到"物件站在原地不动、只有落点格子跟着鼠标跑"。
    ///
    /// 判定与显示必须分开：能不能放仍由 `preview` / `commit`（同一条 fail-closed 校验）回答，
    /// 显示只回答"手上拿着什么、它现在在哪"（The Sims 里拿起来的就是物件本身，放不下时它照样
    /// 跟着光标，红格与光标旁的原因才是判定）。世界一个字节都不改：这一份状态从不提交、从不落盘。
    static func onHandState(_ object: WorldObjectState, placement: WorldPropPlacement) -> WorldObjectState {
        let yaw = placement.yaw
        return WorldObjectState(
            isEnabled: true,
            transform: .init(
                position: .init(x: placement.position.x, y: placement.position.y, z: placement.position.z),
                rotation: .init(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
                scale: object.transform.scale
            ),
            metadata: object.metadata
        )
    }

    private func validate(_ p: WorldPropPlacement) async {
        guard isOpen, !isSaving, let id = selectedID, let preview else { return }
        let run = UUID(); previewGeneration = run
        draftRevision = snapshot.revision
        let context = generation; placement = p; candidate = nil
        // 在手预览**先**跟着光标走：服务还没答（甚至永远答"不能放"）时也要看得见手上那一件。
        // 服务答了就用服务那一份（与这一份同位置；额外带来 `candidate`，即"这里能放"）。
        onPreviewChanged(selectedObject.map { Self.onHandState($0, placement: p) })
        requestID = UUID().uuidString
        do {
            let result = try await preview(id, p)
            guard generation == context, previewGeneration == run, isOpen else { return }
            candidate = result; notice = "预览中 · 确认后保存"; onPreviewChanged(result)
        } catch {
            guard generation == context, previewGeneration == run, isOpen else { return }
            notice = error.localizedDescription
        }
    }
    func confirm() async {
        guard canConfirm, let id = selectedID, let p = placement else { return }
        await save(.place(objectID: id, placement: p))
    }

    // MARK: - 尺寸

    /// 这件物件现在多大（最长边，米）。**只读 `prop.size`**，与碰撞盒/红绿格同一份。
    var selectedLongestEdge: Float? {
        selectedObject?.generatedProp.map { WorldPropSizePolicy.longestEdge(of: $0.effectiveSize) }
    }

    /// 这件物件的尺寸是**怎么定**的：手动改过 > 按你说的尺寸（提交时的意图）> 工作流权威尺寸
    /// > 自动推断。面板必须说得出这一行 —— 用户看到的每个数字都要有出处，
    /// 否则"为什么它这么大"只能靠猜。判据只有一份（`WorldGeneratedProp.sizeProvenance`），
    /// 与 `effectiveSize` 同一个出口，所以两者不可能互相矛盾。
    var selectedSizeProvenance: String? {
        selectedObject?.generatedProp.map { "\($0.sizeProvenance.label)：\($0.sizeProvenanceSummary)" }
    }

    /// 用户改**这一件**物件自己的尺寸（唯一入口）。
    ///
    /// - 目标值以**最长边**（米）表达，整件东西**等比**缩放，写回它自己的那份元数据的
    ///   `size`：渲染、碰撞盒、红/绿格、存档读的都是它 —— 没有第二份尺寸来源。
    ///   （等比不是偏好而是架构要求：渲染端只有一份等比缩放，非等比会让碰撞盒与画面对不上。）
    /// - 越界（低于 0.02 m 看不见 / 高于 3 m 撑满房间）**拒绝**并给可读原因，不静默夹取。
    /// - 提交还要过一次**同一条摆放判定**（`commit` → 摆放服务的 `validate`）：改大之后
    ///   插墙/挡通道的尺寸会在**提交那一步**被拒，原因可读，而不是静默失败。
    func resize(toLongestEdge meters: Float) async {
        guard isOpen, !isSaving, let id = selectedID, let prop = selectedObject?.generatedProp else { return }
        if isSelectedHeld {
            notice = "这件物件正在居民手里，先放回再改尺寸。"
            return
        }
        let size: WorldVector3
        do { size = try WorldPropSizePolicy.manualSize(current: prop.effectiveSize, targetLongestEdge: meters) }
        catch { notice = error.localizedDescription; return }
        await commitSize(id: id, size: size)
    }

    /// 尺寸那一次提交的**唯一出口**（与 `saveAction` 同一个形状：保住选中，撤销槽不动）。
    private func commitSize(id: String, size: WorldVector3) async {
        guard isOpen, !isSaving, let commit else { return }
        isSaving = true; isMoving = false
        // 保存中：世界随时可能换一份回来，这次待办一律作废（见 `clearPendingSelect`）。
        clearPendingSelect(reason: "保存中")
        submittedCommand = nil
        let key = "resize:\(id):\(size.x):\(size.y):\(size.z)"
        if submittedActionKey != key { requestID = UUID().uuidString }
        submittedActionKey = key
        let context = generation, revision = snapshot.revision, id2 = requestID, draft = placement
        do {
            let result = try await commit(.resize(objectID: id, size: size), revision, id2)
            guard context == generation, isOpen else { return }
            guard result.worldID == snapshot.worldID else {
                isSaving = false; notice = "房间已切换，请重新打开摆放"; return
            }
            snapshot = result; isSaving = false; selectedID = id; draftRevision = result.revision
            let saved = String(format: "尺寸已保存：最长边 %.2f m（高 %.2f m）",
                               WorldPropSizePolicy.longestEdge(of: size), size.y)
            // 尺寸变了 ⇒ 手上那个落点必须按**同一条判定**重新过一次：红/绿格与落地判据同步。
            if let draft {
                await validate(WorldPropPlacement(surfaceID: draft.surfaceID, position: draft.position, yaw: draft.yaw))
                notice = "\(saved) · \(notice)"
            } else {
                notice = saved
            }
            requestID = UUID().uuidString
        } catch {
            guard context == generation, isOpen else { return }
            isSaving = false; notice = error.localizedDescription
        }
    }

    func withdraw() async {
        guard !isSaving, let id = selectedID, selectedObject?.isEnabled == true else { return }
        // 收回是**面板**动作：用户接下来要接着在房间里挑/放，焦点交回场景。
        handFocusBackToScene(trigger: "收回")
        await save(.withdraw(objectID: id))
    }

    /// 面板上那一次「删除」——**永久**（墓碑 + 事实，没有撤销）。
    ///
    /// 它走的是**既有那一条** `save(_:)`（同一个 `commit` 出口，与 agent 的
    /// `delete_prop` 是同一条世界命令），所以"面板能删的"与"agent 能删的"是同一集合，
    /// 判据也一个字不差；唯一的区别是这条路上再要说一句"永久"。
    func deleteSelected(reason: String? = nil) async {
        guard !isSaving, let id = selectedID, selectedObject?.generatedProp != nil else { return }
        // 删除是**面板**动作：删完用户多半还要接着摆别的，焦点交回场景。
        handFocusBackToScene(trigger: "删除")
        await save(.delete(objectID: id, reason: reason))
    }
    func undo() async {
        guard snapshot.canUndo, !isSaving else { return }
        // 撤销是**面板**动作：用户接下来还要接着摆放/转视角，焦点交回场景。
        handFocusBackToScene(trigger: "撤销上次")
        await save(.undo)
    }

    // MARK: - 许愿任务那一行上的动作（未领取 → 领取；生成失败 → 重试）

    /// 列表里「未领取」那一行的**唯一出口**：走宿主注入的既有领取路径。
    func claimWish(jobID: String) async {
        await performWishAction(jobID: jobID, step: "claim", action: claimWishOutput)
    }
    /// 列表里失败那一行的**唯一出口**：走宿主注入的既有 retry。
    func retryWish(jobID: String) async {
        await performWishAction(jobID: jobID, step: "retry", action: retryWishOutput)
    }
    /// 列表里「待领取」但**够不到**许愿机那一行的出口：请居民去取（既有 agent 路径）。
    func askResidentToFetch(jobID: String) async {
        await performWishAction(jobID: jobID, step: "ask-resident", action: askResidentToFetchOutput)
    }
    /// 列表里「已领取，入库尚未保存」那一行的出口：走既有的入库补做重入。
    func retryWishInventory(jobID: String) async {
        await performWishAction(jobID: jobID, step: "retry-inventory", action: retryInventoryOutput)
    }

    /// 两个许愿动作的公共形状：防重入（`isSaving`）+ 同一 `(任务, 动作)` 只提交一次
    /// （`submittedWishActions`）+ **失败绝不静默**（原话进 `notice` 与日志）。
    ///
    /// 这里刻意**不做**任何"能不能领/能不能重试"的预判：那个判定只有一份，在既有那条路上
    /// （`claim` 的三条门槛、`retry` 的 stage guard）。面板只负责把结果说出来 ——
    /// 多判一次就是第四套状态文案。
    ///
    /// `isSaving` 只挡**在飞**的那一次：真机上相隔一秒多的第二次激活（连点 / 界面重放）
    /// 落在它放开之后，于是同一个任务会**第二次**交给居民 —— 真机 2026-10-02 16:56:03.446 /
    /// 04.928 与 06.346 / 07.414，同一个任务各两条 `ask-resident`。所以再加一层与既有风格
    /// 一致的台账：同一次用户意图内，`(jobID, step)` 只提交一次；重复调用走幂等出口，
    /// 返回同一次的结果（同一句 `notice`），绝不第二次交给居民。
    ///
    /// 幂等判据问在 `isOpen` **之前**：`askResidentToFetch` 那一次是动作自己先把面板
    /// 关掉（见 `GMGNRadioApp.askResidentToFetchProp`），第二次点击落在 `isOpen == false`
    /// 上；先问 `isOpen` 就会静默 return —— 那正是"点了没反应"。已记过账的与**还在飞**的
    /// 同一次提交都走 `reportWishActionDuplicate`（同一句"重复提交已忽略"）。
    private func performWishAction(jobID: String, step: String,
                                   action: (@MainActor (String) async throws -> Void)?) async {
        let key = WishActionLedger.key(jobID: jobID, step: step)
        if inFlightWishActionKey == key {
            reportWishActionDuplicate(jobID: jobID, step: step)
            return
        }
        guard submittedWishActions.admits(jobID: jobID, step: step) else {
            reportWishActionDuplicate(jobID: jobID, step: step)
            return
        }
        guard isOpen, !isSaving else { return }
        guard let action else {
            notice = Self.wishActionNotWiredText
            livingWorldLogger.notice("摆件面板拒绝 step=wish-\(step, privacy: .public)-not-wired 任务=\(jobID, privacy: .public)")
            return
        }
        isSaving = true; isMoving = false
        inFlightWishActionKey = key
        // 保存中：世界随时可能换一份回来，这次待办一律作废（与 `save` 同一条纪律）。
        clearPendingSelect(reason: "许愿任务动作中")
        do {
            try await action(jobID)
            isSaving = false
            inFlightWishActionKey = nil
            submittedWishActions.record(jobID: jobID, step: step)
            // 状态那一句由宿主推来的新快照说（列表读的是权威），这里只说"这次动作提交出去了"。
            notice = Self.submittedText(for: step)
            livingWorldLogger.notice("摆件面板许愿任务 step=wish-\(step, privacy: .public) 任务=\(jobID, privacy: .public) 结果=已提交")
        } catch {
            isSaving = false
            inFlightWishActionKey = nil
            // **原话**：既有那条路给出的具名原因，一个字都不改写。
            notice = error.localizedDescription
            livingWorldLogger.notice("摆件面板许愿任务 step=wish-\(step, privacy: .public) 任务=\(jobID, privacy: .public) 结果=拒绝 原因=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 同一次意图内第二次点击的**唯一**出口：不再提交，只把同一次的结果再说一遍。
    ///
    /// 界面上那一句可能看不见（面板刚被第一次点击关掉），所以**日志里那一行是硬要求**：
    /// "重复提交已忽略"必须是可查的事实，不许静默。
    private func reportWishActionDuplicate(jobID: String, step: String) {
        // 幂等：同一次意图内的重复调用**不再提交**，只把同一次的结果再说一遍。
        notice = Self.submittedText(for: step)
        livingWorldLogger.notice("摆件面板拒绝 step=wish-\(step, privacy: .public)-duplicate 任务=\(jobID, privacy: .public) 结果=重复提交已忽略（同一次意图只提交一次）")
    }

    /// 宿主还没把许愿动作接上时的那句话（绝不静默、绝不假装做过）。
    static let wishActionNotWiredText = "摆放面板还没有接到许愿任务上（宿主还没接线），这一次没有提交。"
    // 提交出去之后那句"接下来会怎样"：状态词**只允许**用唯一投影的那五个
    // （`OwnershipDisplayState.label`），这里不再自己编第二套（原先写的「尚未摆放」
    // 是随第二套投影一起退场的第四套文案）。
    static let claimSubmittedText = "领取已登记。入库完成后这一行会改写成「\(OwnershipDisplayState.inInventory.label)」。"
    static let retrySubmittedText = "已按原提交确认。结果会显示在这一行。"
    static let askResidentSubmittedText = "已请居民去许愿机取这一件；它到达领取位置后按「领取」即可。"
    static let retryInventorySubmittedText = "已重试入库。成功的话这一行会改写成「\(OwnershipDisplayState.inInventory.label)」。"
    /// "这次动作提交出去了"那句话的**唯一**出处：首次提交与幂等重复走同一句，
    /// 于是重复调用返回的**就是**同一次的结果，界面不会因为点了第二下而改口。
    static func submittedText(for step: String) -> String {
        switch step {
        case "claim": claimSubmittedText
        case "ask-resident": askResidentSubmittedText
        case "retry-inventory": retryInventorySubmittedText
        default: retrySubmittedText
        }
    }
    func holdSelected(at point: PropAttachmentPoint? = nil) async {
        let target = point ?? holdPoint
        // **一次点击绝不允许什么都不发生**。原来这两条 guard 是裸 `return`：用户在
        // 「手/背后/腰间」上点一下，既没有动作、也没有一句话、日志里也没有一行
        // （真机 2026-10-02"剑挂不到背后"）。现在每一条不成立的出口都说清是哪一条。
        guard let id = selectedID else {
            notice = "请先选中一件物件，再选挂点。"
            livingWorldLogger.notice("摆件面板拒绝 step=hold-no-selection 挂点=\(target.rawValue, privacy: .public)")
            return
        }
        guard let hold else {
            notice = "摆放面板还没有接到世界里（空间会话未就绪），这次挂点没有提交。请关掉面板重开一次。"
            livingWorldLogger.notice("摆件面板拒绝 step=hold-not-wired 挂点=\(target.rawValue, privacy: .public) 物件=\(id, privacy: .public)")
            return
        }
        holdPoint = target
        // 已经挂在身上的是**同一件**：换挂点不必再过一次"能不能拿"（它已经在身上了），
        // 能不能挂由世界那条命令自己的判据回答（找不到骨骼 ⇒ 可见失败）。
        //
        // 这里的可用性原因**是按用户真正选的挂点**问的，不是拿手的答案回答背后/腰间：
        // `holdEligibility` 的省缺是 `.rightHand`，用它挡住"背后"会把一个手部的问题
        // 说成"背后也不行"，用户永远试不出来。真的挂不上时下面那次提交会给出**那个挂点
        // 自己的**具名原因（含统一日志一行）。
        if !isSelectedHeld, let reason = availabilityReason(id: id, point: target) {
            notice = reason
            return
        }
        await saveAction(key: "hold:\(id):\(target.rawValue)", keepSelection: id) { revision, requestID in
            try await hold(id, target, revision, requestID)
        }
    }
    func returnSelected() async {
        guard let id = selectedID, isSelectedHeld, let returnHeld else { return }
        await saveAction(key: "return:\(id)", keepSelection: nil) { revision, requestID in
            try await returnHeld(id, revision, requestID)
        }
    }
    func nudgeHeld(x: Float = 0, y: Float = 0, z: Float = 0) async {
        guard let id = selectedID, let grip = selectedGrip, let adjustHeldGrip else { return }
        let next = WorldVector3(x: grip.localOffset.x + x, y: grip.localOffset.y + y, z: grip.localOffset.z + z)
        await saveAction(key: "grip:\(id):\(next.x):\(next.y):\(next.z)", keepSelection: id) { revision, requestID in
            try await adjustHeldGrip(id, next, grip.localRotation, revision, requestID)
        }
    }
    func rotateHeld(_ direction: Float) async {
        guard let id = selectedID, let grip = selectedGrip, let adjustHeldGrip else { return }
        let q = grip.localRotation
        let currentYaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        let yaw = currentYaw + direction * .pi / 12
        let rotation = WorldQuaternion(x: 0, y: sin(yaw/2), z: 0, w: cos(yaw/2))
        await saveAction(key: "grip-yaw:\(id):\(yaw)", keepSelection: id) { revision, requestID in
            try await adjustHeldGrip(id, grip.localOffset, rotation, revision, requestID)
        }
    }
    private func save(_ command: WorldPropLayoutCommand) async {
        guard isOpen, !isSaving, let commit else { return }
        isSaving = true; isMoving = false
        // 保存中：世界随时可能换一份回来，这次待办一律作废（见 `clearPendingSelect`）。
        clearPendingSelect(reason: "保存中")
        submittedActionKey = nil
        if submittedCommand != command { requestID = UUID().uuidString; submittedCommand = command }
        // `cancelPreview()` 会把选中清掉，所以"删了哪一件"要在提交**之前**记下来 ——
        // 成功那句话必须说出名字（"已删除：2B 白色长剑"），而不是一句"已保存"。
        let deletedName = deletedDisplayName(of: command)
        let context = generation, revision = snapshot.revision, id = requestID
        do {
            let result = try await commit(command, revision, id)
            guard context == generation, isOpen else { return }
            guard result.worldID == snapshot.worldID else {
                isSaving = false; notice = "房间已切换，请重新打开摆放"; return
            }
            snapshot = result; isSaving = false; cancelPreview()
            // **成功必须可见，而且说的是真话**：删除是永久的，不能读成"保存了一下"。
            notice = deletedName.map(Self.deletedNotice) ?? "已保存"
            requestID = UUID().uuidString
        } catch {
            guard context == generation, isOpen else { return }
            isSaving = false; notice = error.localizedDescription
        }
    }

    /// 这条命令删的是哪一件（不是 `.delete` 就返回 nil，不猜）。
    private func deletedDisplayName(of command: WorldPropLayoutCommand) -> String? {
        guard case let .delete(objectID, _) = command else { return nil }
        return selectedObject?.generatedProp?.objectID == objectID
            ? selectedObject?.generatedProp?.displayName
            : snapshot.objects.first { $0.generatedProp?.objectID == objectID }?.generatedProp?.displayName
    }

    /// 「永久删除」那句话说给用户听的样子（**唯一**一份文案）。
    static func deletedNotice(_ name: String) -> String {
        "已删除（永久）：\(name)。它不会再出现在「我的物件」里，也不能恢复。"
    }

    private func saveAction(key: String, keepSelection: String?,
                            perform: @escaping @MainActor (UInt64, String) async throws -> ResidentPropEditorSnapshot) async {
        guard isOpen, !isSaving else { return }
        isSaving = true; isMoving = false
        // 保存中：世界随时可能换一份回来，这次待办一律作废（见 `clearPendingSelect`）。
        clearPendingSelect(reason: "保存中")
        if submittedCommand != nil || submittedActionKey != key { requestID = UUID().uuidString }
        submittedCommand = nil
        submittedActionKey = key
        let context = generation, revision = snapshot.revision, id = requestID
        do {
            let result = try await perform(revision, id)
            guard context == generation, isOpen else { return }
            guard result.worldID == snapshot.worldID else {
                isSaving = false; notice = "房间已切换，请重新打开摆放"; return
            }
            snapshot = result; isSaving = false; candidate = nil; placement = nil; isMoving = false
            selectedID = keepSelection; draftRevision = result.revision; onPreviewChanged(nil)
            notice = keepSelection.map { result.heldProp?.objectID == $0 } == true ? "手持展示中" : "已放回"
            requestID = UUID().uuidString
        } catch {
            guard context == generation, isOpen else { return }
            isSaving = false; notice = error.localizedDescription
        }
    }
    static func consumesScenePointer(isOpen: Bool, moving: Bool, inputOwnsFocus: Bool) -> Bool {
        isOpen && moving && !inputOwnsFocus
    }
}

/// 「同一 `(任务, 动作)` 在一次用户意图内只提交一次」的**纯台账**。
///
/// 它不判断"能不能领 / 能不能重试"（那个判定只有一份，在既有那条路上），只记
/// **事实**："这个动作已经交出去过一次"。故意做成值类型 + 纯函数，所以可以离线
/// 复现"连点两次"与"界面重放一次"的判别力（`tools/test-ownership-list-projection.swift`）。
///
/// 键里同时带任务与动作：任务不同、或同一任务换成另一个动作（例如从「让居民去取」
/// 变成「领取」），都是**新的一次意图**，各自可以提交一次。
struct WishActionLedger: Equatable {
    private var submitted: Set<String> = []

    static func key(jobID: String, step: String) -> String { "\(jobID)|\(step)" }

    /// 这次调用是不是**还没有**交出去过。返回 false = 重复提交，调用点必须走幂等出口。
    func admits(jobID: String, step: String) -> Bool {
        !submitted.contains(Self.key(jobID: jobID, step: step))
    }

    mutating func record(jobID: String, step: String) {
        submitted.insert(Self.key(jobID: jobID, step: step))
    }

    /// 只保留**此刻仍然被提供**的键：行不再是那个状态（换了动作、进了库存、已删除）
    /// 就说明上一次意图已经结束，用户下一次点击是新的意图，不必再被台账挡住。
    mutating func keepOnly(_ offered: Set<String>) {
        submitted.formIntersection(offered)
    }

    mutating func removeAll() { submitted.removeAll() }
}
