import Combine
import Foundation
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
    /// 建造模式是否开启。关闭时渲染层不该画格子，拾取也不该命中。
    @Published private(set) var isBuildModeActive = false
    @Published private(set) var grid: PropSupportGrid?
    @Published private(set) var report: PropSupportGridReport?
    /// 当前悬停的格子（已映射成呈现层类型）。
    @Published private(set) var hovered: PropSupportGridPresentation.Cell?
    /// 悬停位置放不下时的原因；nil 表示可放。文案由 `PropSupportBlockReason.errorDescription` 给出。
    @Published private(set) var hoveredBlockReason: PropSupportBlockReason?
    /// 需要着色的格子（footprint 内）。缺省即"可放"。
    @Published private(set) var cellStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    /// 当前 footprint 朝向（弧度，已归一化）。90° 步进由 `rotateFootprint(bySteps:)` 驱动。
    @Published private(set) var footprintYaw: Float = 0

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
    ) {
        self.collision = collision
        isBuildModeActive = true
        if gridKey == key, let grid {
            // 已有同一份几何的网格：只把缓存重新指向它，不重新派生。
            rebuildCaches(from: grid)
            onGridChanged?()
            return
        }
        let built = PropSupportGridBuilder.build(
            collision: collision,
            bounds: bounds,
            seed: seed,
            parameters: parameters
        )
        grid = built
        report = built.report
        gridKey = key
        rebuildCaches(from: built)
        clearHover()
        onGridChanged?()
    }

    func deactivate() {
        isBuildModeActive = false
        grid = nil
        report = nil
        gridKey = nil
        collision = nil
        cells = []
        candidates = []
        layerRefs = [:]
        clearHover()
        onGridChanged?()
    }

    func clearHover() {
        hovered = nil
        hoveredBlockReason = nil
        hoveredLayerRef = nil
        evaluationInputs = nil
        cellStates = [:]
    }

    /// 90° 步进旋转。旋转后立刻按上一次的评估输入重算整块 footprint 的着色，
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

    private func reevaluateFootprint() {
        guard let grid, let collision, let layerRef = hoveredLayerRef, let inputs = evaluationInputs else {
            hovered = nil
            hoveredBlockReason = nil
            cellStates = [:]
            onGridChanged?()
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
        cellStates = PropSupportGridMapping.footprintStates(
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
        onGridChanged?()
    }
}
