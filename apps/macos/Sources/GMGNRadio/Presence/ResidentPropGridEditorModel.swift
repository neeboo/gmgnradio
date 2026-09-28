import Combine
import Foundation
import os
import simd
import WorldRuntime

/// 建造模式格子的**唯一真相来源**：网格、悬停格、footprint 判定与着色。
///
/// 分工：
/// - `WorldRuntime` 负责几何（`PropSupportGridBuilder` 派生、`PropPlacementEvaluator` 判定）；
/// - `PropSupportGridMapping` 负责纯映射与着色（可离线验证）；
/// - 本类型只做"持有 + 编排"，不自己算几何，也不自己决定颜色。
///
/// **缓存策略**：网格只依赖几何、种子与参数，**与已放物件无关**（`commitPropLayout` 只把
/// 物件包进碰撞世界，网格几何不变）。所以按调用方给的 `key`（例如 worldID）派生一次即可，
/// 每次放置都重建是浪费：真实生活舱一次派生在 -O 下约 0.5 s。
@MainActor final class ResidentPropGridEditorModel: ObservableObject {
    /// 派生这条链的常驻诊断（与宿主同一个 subsystem/category，`log show` 一条命令就能读全）。
    ///
    /// 为什么要它：真机 2026-09-28 的"面板永远说格子还在生成"之所以查了很久，是因为这条
    /// 链**每一步都是静默的** —— 缓存命中、算完被丢弃、派生出空网格，全都不留痕迹。
    /// 日志是 `.notice` 级：不带 `--info` 也能看到。
    static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "LivingWorld")
    /// 建造模式是否开启。关闭时渲染层不该画格子，拾取也不该命中。
    @Published private(set) var isBuildModeActive = false
    @Published private(set) var grid: PropSupportGrid?
    @Published private(set) var report: PropSupportGridReport?
    /// 当前悬停的格子（已映射成呈现层类型）。
    @Published private(set) var hovered: PropSupportGridPresentation.Cell?
    /// 悬停位置放不下时的原因；nil 表示可放。文案由 `PropSupportBlockReason.errorDescription` 给出。
    @Published private(set) var hoveredBlockReason: PropSupportBlockReason?
    /// 需要着色的格子（footprint 内 + 悬停物件的发光）。缺省即"可放"。
    @Published private(set) var cellStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    /// 当前 footprint 朝向（弧度，已归一化）。45° 步进由 `rotateFootprint(bySteps:)` 驱动。
    @Published private(set) var footprintYaw: Float = 0
    /// 光标正悬停的**已摆物件**（The Sims 的 white glow 语义）。nil = 光标不在任何已摆物件上。
    ///
    /// 由宿主在每次光标移动时设置（见 `setHoveredProp`）。它**不是**"选中"：
    /// 选中/携带仍然是 `ResidentPropEditorState.selectedID` 那一条路。
    private(set) var hoveredPropID: String?

    /// 每次状态变更**之后**触发，供宿主把网格与着色转发给渲染层。
    ///
    /// 刻意不用 `objectWillChange`：它在变更**之前**发，订阅者读到的是旧值。
    var onGridChanged: (@MainActor () -> Void)?

    private var collision: (any WorldPropSupportQuerying)?
    private var gridKey: String?
    private var cells: [PropSupportGridPresentation.Cell] = []
    private var candidates: [PropSupportGridPicker.Candidate] = []
    private var layerRefs: [PropSupportColumn: [Int: PropSupportLayerRef]] = [:]

    /// 最近一次评估的输入。旋转时要据此重算着色，而不需要新的光标位置。
    private struct EvaluationInputs {
        let footprintSize: SIMD2<Float>
        let height: Float
        let blockingVolumes: [WorldCollisionVolume]
        let placedProps: [WorldCollisionVolume]
    }
    private var evaluationInputs: EvaluationInputs?
    private var hoveredLayerRef: PropSupportLayerRef?
    /// 当前 footprint 的判定着色（不含悬停发光）。`publishCellStates()` 把它与发光合并。
    private var footprintStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    private var hoverTarget: HoverTarget?

    var isReady: Bool { grid != nil }
    /// 摆放校验需要的碰撞世界（能给出三角形）。与 `grid` 同时可用，否则为 nil。
    var supportCollision: (any WorldPropSupportQuerying)? { collision }
    /// 供渲染层使用的格子，与 `cellStates` 同一坐标系（缺省状态的格子也在这里）。
    var renderCells: [PropSupportGridPresentation.Cell] { cells }
    var spacing: Float { grid?.spacing ?? PropSupportGridParameters.default.spacing }

    /// 开启建造模式并（按需）派生网格。
    ///
    /// `key` 用来避免重复派生：同一个 key 且已有网格时直接复用。调用方应传能代表"几何身份"
    /// 的值（worldID 即可）——已放物件的增删不改变几何，不需要重新派生。
    func activate(
        collision: any WorldPropSupportQuerying,
        seed: WorldVector3,
        bounds: WorldPlanarBounds,
        key: String,
        parameters: PropSupportGridParameters = .default
    ) async {
        self.collision = collision
        isBuildModeActive = true
        if gridKey == key, let grid {
            // 已有同一份几何的网格：只把缓存重新指向它，不重新派生。
            Self.log.notice("格子派生：命中缓存 key=\(key, privacy: .public) 层=\(grid.layers.count, privacy: .public)")
            rebuildCaches(from: grid)
            onGridChanged?()
            return
        }
        Self.log.notice("格子派生：开始 key=\(key, privacy: .public)")
        let startedAt = ContinuousClock.now
        // 派生是**纯计算**，且真实舱体一次要 0.5 s（-O）/ 6.6 s（-Onone）。
        // 同步做会把打开装修编辑器的那一帧卡住，所以放后台；`PropSupportGrid` 是 Sendable。
        let built = await Task.detached(priority: .userInitiated) {
            PropSupportGridBuilder.build(
                collision: collision,
                bounds: bounds,
                seed: seed,
                parameters: parameters
            )
        }.value
        let elapsed = startedAt.duration(to: .now)
        // 派生期间编辑器可能已经被关掉：那就别把结果写回来。
        guard isBuildModeActive, gridKey != key else {
            // 这条过去是完全静默的：一次算完的派生被丢掉，外面却还留着"请求过"的印记。
            // 真机排查必须能一眼看出是**哪一半**把它丢掉的。
            Self.log.notice("格子派生：结果被丢弃（建造模式开着=\(self.isBuildModeActive, privacy: .public) 缓存键相同=\(self.gridKey == key, privacy: .public)）key=\(key, privacy: .public)")
            return
        }
        grid = built
        report = built.report
        gridKey = key
        rebuildCaches(from: built)
        clearHover()
        let report = built.report
        Self.log.notice(
            "格子派生：完成 key=\(key, privacy: .public) 耗时=\(elapsed.description, privacy: .public) 层=\(built.layers.count, privacy: .public) 列=\(self.cells.count, privacy: .public) 种上=\(report.seeded, privacy: .public) 过滤前=\(report.layersBeforeFilter, privacy: .public)"
        )
        onGridChanged?()
    }

    func deactivate() {
        Self.log.notice("格子派生：停用（此前缓存键=\(self.gridKey ?? "nil", privacy: .public)）")
        isBuildModeActive = false
        onGridChanged?()
        grid = nil
        report = nil
        gridKey = nil
        collision = nil
        cells = []
        candidates = []
        layerRefs = [:]
        hoveredPropID = nil
        hoverTarget = nil
        clearHover()
        onGridChanged?()
    }

    /// 光标移到一件**已摆出来的**物件上：它的 footprint 格子进入 `.hoverTarget`（发光）。
    ///
    /// 唯一一份尺寸来源是 `WorldObjectState.generatedCollisionVolume`（摆放/碰撞用的那个盒子），
    /// 所以"看起来在发光的范围"与"系统认为它占的地方"是同一个事实。
    ///
    /// `placement` 语义上与 `ResidentPropEditorState.select(objectID:)` 初始化携带态用的是同一个
    /// 事实（物件自己的 transform），所以"发光的 footprint"就是"拿起来后跟着鼠标的那块 footprint"。
    func setHoveredProp(objectID: String, volume: WorldCollisionVolume) {
        guard isBuildModeActive, grid != nil else { return }
        let yaw = Self.yaw(of: volume.rotation)
        guard yaw.isFinite else { return }
        let spacing = self.spacing
        guard spacing.isFinite, spacing > 0,
              volume.halfExtents.x > 0, volume.halfExtents.z > 0 else { return }
        // 摆件的位置是**格心**（列最小角 + 半格），所以列号 = `floor(格心 / 间距)` ——
        // 与 `PropSupportGridPicker.pick` 把命中点量化成列用的是同一条换算（这里不另立一份）。
        let column = PropSupportColumn(
            x: Int((volume.center.x / spacing).rounded(.down)),
            z: Int((volume.center.z / spacing).rounded(.down))
        )
        let target = HoverTarget(
            objectID: objectID,
            column: column,
            // 盒底 = 它坐在哪一层承托面上（高度容差与摆放校验同口径）。
            supportHeight: volume.center.y - volume.halfExtents.y,
            footprint: WorldPlanarFootprint(
                size: SIMD2(volume.halfExtents.x * 2, volume.halfExtents.z * 2), yaw: yaw
            )
        )
        // 光标在**同一件**物件上继续移动（每秒几十次）不该重算整块 footprint 的着色。
        guard target != hoverTarget else { return }
        hoverTarget = target
        hoveredPropID = objectID
        publishCellStates()
    }

    /// 光标离开所有已摆物件（或进入携带态、装修结束）：熄掉发光。
    func clearHoveredProp() {
        guard hoveredPropID != nil || hoverTarget != nil else { return }
        hoveredPropID = nil
        hoverTarget = nil
        publishCellStates()
    }

    func clearHover() {
        hovered = nil
        hoveredBlockReason = nil
        hoveredLayerRef = nil
        evaluationInputs = nil
        footprintStates = [:]
        publishCellStates()
    }

    /// 45° 步进旋转（步长在 `PropSupportGridMapping.yaw(rotatedBySteps:from:)`）。
    /// 旋转后立刻按上一次的评估输入重算整块 footprint 的着色，
    /// 这样用户按住旋转键就能看到绿/红跟着转。
    func rotateFootprint(bySteps steps: Int) {
        footprintYaw = PropSupportGridMapping.yaw(rotatedBySteps: steps, from: footprintYaw)
        reevaluateFootprint()
        onGridChanged?()
    }

    /// 光标 → 最近格子 → footprint 整体判定 → 整块着色。
    ///
    /// 纯 CPU：格子平面 `y = supportHeight` 与光标射线闭式求交，不做 GPU readback。
    func updateHover(
        normalizedCursor: SIMD2<Float>,
        inverseViewProjection: simd_float4x4,
        footprintSize: SIMD2<Float>,
        height: Float,
        blockingVolumes: [WorldCollisionVolume],
        placedProps: [WorldCollisionVolume],
        maximumDistance: Float = 30
    ) {
        guard isBuildModeActive, let grid, collision != nil else {
            clearHover()
            return
        }
        guard let picked = PropSupportGridPicker.pick(
            normalized: normalizedCursor,
            inverseViewProjection: inverseViewProjection,
            candidates: candidates,
            spacing: grid.spacing,
            maximumDistance: maximumDistance
        ) else {
            clearHover()
            return
        }
        let column = PropSupportColumn(x: picked.columnX, z: picked.columnZ)
        guard let layerRef = layerRefs[column]?[picked.layer] else {
            clearHover()
            return
        }
        hoveredLayerRef = layerRef
        evaluationInputs = EvaluationInputs(
            footprintSize: footprintSize,
            height: height,
            blockingVolumes: blockingVolumes,
            placedProps: placedProps
        )
        reevaluateFootprint()
    }

    /// 吸附后的摆放位置与朝向（格心 + 当前 footprint 朝向）。没有悬停时返回 nil。
    var snappedPlacement: (position: SIMD3<Float>, yaw: Float)? {
        guard let layerRef = hoveredLayerRef, grid != nil else { return nil }
        return (
            PropSupportGridMapping.snappedPlacementPosition(
                columnX: layerRef.column.x,
                columnZ: layerRef.column.z,
                spacing: spacing,
                supportHeight: layerRef.supportHeight
            ),
            footprintYaw
        )
    }

    /// 悬停所在层的标识。`surfaceID` 现在是层标识，不再是具名摆放面。
    var hoveredLayerName: String? {
        hoveredLayerRef.map { "grid.layer\($0.layer)" }
    }

    /// 当前悬停是否可放（`hoveredBlockReason == nil` 且有悬停）。
    var canPlaceAtHover: Bool { hoveredLayerRef != nil && hoveredBlockReason == nil }

    // MARK: - 内部

    /// 光标下那件已摆物件的**发光轮廓**。
    private struct HoverTarget: Equatable {
        let objectID: String
        let column: PropSupportColumn
        let supportHeight: Float
        let footprint: WorldPlanarFootprint
    }

    /// 悬停发光与"坐在哪一层"共用的高度容差。与
    /// `ResidentPropPlacementService.supportLayer(at:grid:)` 的 0.005 m 同口径：
    /// 两处不一致的话，发光会落在物件**旁边**那一层上。
    private static let hoverTargetHeightTolerance: Float = 0.005

    /// 四元数 → 绕 y 的 yaw。与 `ResidentPropEditorState.select(objectID:)` 用的是同一个式子
    /// （摆放与发光必须对同一件物件得到同一个朝向）。
    private static func yaw(of rotation: WorldQuaternion) -> Float {
        atan2(2 * (rotation.w * rotation.y + rotation.x * rotation.z),
              1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z))
    }

    private func rebuildCaches(from grid: PropSupportGrid) {
        let layers = grid.layers.map { layer in
            PropSupportGridMapping.LayerInput(
                columnX: layer.column.x,
                columnZ: layer.column.z,
                layer: layer.layer.layer,
                supportHeight: layer.supportHeight,
                spacing: grid.spacing
            )
        }
        cells = PropSupportGridMapping.presentationCells(layers)
        candidates = PropSupportGridMapping.pickerCandidates(layers)
        var refs: [PropSupportColumn: [Int: PropSupportLayerRef]] = [:]
        for layer in grid.layers { refs[layer.column, default: [:]][layer.layer.layer] = layer }
        layerRefs = refs
    }

    /// 悬停物件的 footprint 格子。**写进 `cellStates` 就同时决定了焦点裁剪的锚点**
    /// （`PropSupportGridPresentation.focus` 的 `core` 就是 `states` 的键），
    /// 所以发光只能出现在"物件脚下那一小块 + 两圈淡格"里 —— 它不可能绕开裁剪去铺满地面。
    private func hoverTargetStates() -> [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] {
        guard let target = hoverTarget, let grid else { return [:] }
        let spacing = grid.spacing
        guard spacing.isFinite, spacing > 0 else { return [:] }
        let columns = Set(
            target.footprint.columns(anchoredAt: target.column, spacing: spacing)
                .map { PropSupportGridMapping.ColumnKey(x: $0.x, z: $0.z) }
        )
        guard !columns.isEmpty else { return [:] }
        var states: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
        for cell in cells
        where abs(cell.supportHeight - target.supportHeight) < Self.hoverTargetHeightTolerance
            && columns.contains(PropSupportGridMapping.ColumnKey(x: cell.columnX, z: cell.columnZ)) {
            states[cell] = .hoverTarget
        }
        return states
    }

    /// `cellStates` 的**唯一**写入口：footprint 的判定着色 + 悬停物件的发光。
    ///
    /// 发光**覆盖**在同一格上的判定色（那件物件所在的位置，用户此刻要的是"点它能拿起来"，
    /// 而不是"这里能不能放"）。
    private func publishCellStates() {
        var states = footprintStates
        for (cell, state) in hoverTargetStates() { states[cell] = state }
        cellStates = states
        onGridChanged?()
    }

    private func reevaluateFootprint() {
        guard let grid, let collision, let layerRef = hoveredLayerRef, let inputs = evaluationInputs else {
            hovered = nil
            hoveredBlockReason = nil
            footprintStates = [:]
            publishCellStates()
            return
        }
        let footprint = WorldPlanarFootprint(size: inputs.footprintSize, yaw: footprintYaw)
        let reason = PropPlacementEvaluator.evaluate(
            footprint: footprint,
            height: inputs.height,
            at: layerRef,
            grid: grid,
            collision: collision,
            blockingVolumes: inputs.blockingVolumes,
            placedProps: inputs.placedProps
        )
        let columns = footprint.columns(anchoredAt: layerRef.column, spacing: grid.spacing)
        let covered = Set(columns.map { PropSupportGridMapping.ColumnKey(x: $0.x, z: $0.z) })
        footprintStates = PropSupportGridMapping.footprintStates(
            cells: cells,
            coveredColumns: covered,
            anchorLayer: layerRef.layer.layer,
            isFootprintValid: reason == nil
        )
        hovered = cells.first {
            $0.columnX == layerRef.column.x && $0.columnZ == layerRef.column.z
                && $0.layer == layerRef.layer.layer
        }
        hoveredBlockReason = reason
        publishCellStates()
    }
}
