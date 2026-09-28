import Foundation
import simd

/// 建造模式格子的**呈现层**：把派生出的摆放格子 + 每个格子的判定结果，
/// 变成一份可直接灌进 Metal 实例化绘制的四边列表。
///
/// 刻意与 Metal 解耦（本文件只依赖 Foundation + simd），原因有两个：
///   - 距离淡出、剔除、状态着色、预算内降级这些**容易出错的逻辑**可以离线单测；
///   - 渲染 pass 只剩"把实例塞进 buffer"，是机械工作。
///
/// 与 `PropSupportGridPicker` 同一套约定：格子 `(columnX, columnZ)` 覆盖
/// `[x*s, (x+1)*s] × [z*s, (z+1)*s]`，列坐标是**最小角**。
enum PropSupportGridPresentation {
    /// 建造模式格子的**焦点裁剪**：只画锚定 footprint 本体 + 外扩的几圈。
    ///
    /// The Sims 的格子是**局部辅助线**，不是铺满地面的地毯。漫过整个地板的实心格子
    /// 既盖住了地面材质，也把唯一重要的信息（这块能不能放）淹没了。所以：
    ///
    ///   - footprint 本体（`states` 里已被 `PropSupportGridMapping.footprintStates`
    ///     标记过的那批格子）按 `CellState.tint` 全对比绘制；
    ///   - 本体外扩 `ringCount` 圈压到 `ringAlpha`，作为"邻近可延伸区域"的提示；
    ///   - **再远的格子一个实例都不生成** —— 过滤落在生成这一步，渲染器不必每帧
    ///     去丢弃几千个格子。
    ///
    /// **锚点只有一处来源：`states` 的键。** 不需要新的状态源，因为：
    ///   - 携带物件时，`footprintStates` 已经把 footprint 覆盖的列写进 `states`；
    ///   - **没携带物件时**，编辑器仍然按"一格"的 footprint 做悬停判定
    ///     （`GMGNRadioApp.updateResidentPropGridHover` 在 `footprint == nil` 时
    ///     退回 `spacing` 见方），所以光标所在格同样会出现在 `states` 里。
    ///
    /// `states` 为空（光标没落在任何承托层上，或还没进场景）时**一个格子都不画** ——
    /// 这正是"空旷时不再铺满地面"。
    struct Focus: Equatable, Sendable {
        /// 外扩圈数。
        ///
        /// 取 **2** 而不是 1：1 圈在 1×1 的悬停 footprint 下只有 8 个淡格，看上去像一圈
        /// 描边而不是"格子"——看不出格距，也就回答不了"怎么看到格子"这个原始需求。
        /// 2 圈最小给出 5×5，每个方向能看见两条淡线再淡出。代价仍然很小：0.25 m 格距下
        /// 一共 25 格，相对真实生活舱派生出的上千列只是脚下一小块，不会变回地毯。
        static let ringCount = 2
        /// 外圈的不透明度。
        ///
        /// 取 **0.2**：淡环必须明显弱于 footprint 的状态色（黄 `.validFootprint` /
        /// 红 `.invalidFootprint`，见 `CellState.tint`），否则用户分不清"这块能放"
        /// 和"这块只是附近"；但又要亮到在浅色与深色地面上都能被看见。0.2 大约是一层
        /// 看得见但透底的染色，正好是辅助线的量级。
        static let ringAlpha: Float = 0.2

        /// footprint 本体的格子（= `states` 的键），全对比。
        let core: Set<Cell>
        /// 参与绘制的格子（本体 + 外圈），顺序与传入的 `cells` 一致。
        let cells: [Cell]
    }

    /// 从 footprint 着色表推出"这一帧该画哪些格子"。
    ///
    /// - footprint 是贴着**某一层**放的（`footprintStates` 按锚点层过滤），所以只有与它
    ///   同层的格子才进焦点：否则旁边桌面上会凭空浮出一片格子，比原来更乱。
    /// - 本体是矩形（可能斜放），用它的**轴对齐外包**外扩 `ringCount` 圈：形状规整、
    ///   代价是 O(1)。逐格算 Chebyshev 距离只在斜放 footprint 上略有差别，不值得多扫一遍。
    static func focus(cells: [Cell], states: [Cell: CellState]) -> Focus {
        let core = Set(states.keys)
        guard !core.isEmpty else { return Focus(core: [], cells: []) }

        var layers: Set<Int> = []
        var minimumX = Int.max, maximumX = Int.min
        var minimumZ = Int.max, maximumZ = Int.min
        for cell in core {
            layers.insert(cell.layer)
            minimumX = min(minimumX, cell.columnX)
            maximumX = max(maximumX, cell.columnX)
            minimumZ = min(minimumZ, cell.columnZ)
            maximumZ = max(maximumZ, cell.columnZ)
        }
        let lowX = minimumX - Focus.ringCount, highX = maximumX + Focus.ringCount
        let lowZ = minimumZ - Focus.ringCount, highZ = maximumZ + Focus.ringCount

        let visible = cells.filter { cell in
            layers.contains(cell.layer)
                && cell.columnX >= lowX && cell.columnX <= highX
                && cell.columnZ >= lowZ && cell.columnZ <= highZ
        }
        return Focus(core: core, cells: visible)
    }

    /// 一个格子在画面里的状态。颜色由渲染层按 `tint` 映射。
    enum CellState: Equatable, Sendable {
        /// 这里可以放。
        case placeable
        /// 几何不允许（插墙 / 家具 / 无承托 / 净空不足）。
        case blocked
        /// 已被别的物件占用。
        case occupied
        /// 当前 footprint 的一部分，且整体合法。
        case validFootprint
        /// 当前 footprint 的一部分，但整体不合法。
        case invalidFootprint

        /// 线性 RGBA。放在这里是为了让"哪种状态什么颜色"成为**可测的事实**，
        /// 而不是散落在 shader 里的魔法数。
        var tint: SIMD4<Float> {
            switch self {
            case .placeable: SIMD4(0.30, 0.85, 0.45, 1)
            case .blocked: SIMD4(0.90, 0.30, 0.28, 1)
            case .occupied: SIMD4(0.55, 0.58, 0.62, 1)
            case .validFootprint: SIMD4(1.00, 0.82, 0.25, 1)
            case .invalidFootprint: SIMD4(0.95, 0.35, 0.30, 1)
            }
        }
    }

    /// 一个待呈现的格子。`columnX/columnZ` 是**最小角**的世界坐标（与 WorldRuntime 一致）。
    struct Cell: Equatable, Hashable, Sendable {
        let columnX: Int
        let columnZ: Int
        let layer: Int
        let columnXWorld: Float
        let columnZWorld: Float
        let supportHeight: Float

        init(columnX: Int, columnZ: Int, layer: Int,
             columnXWorld: Float, columnZWorld: Float, supportHeight: Float) {
            self.columnX = columnX
            self.columnZ = columnZ
            self.layer = layer
            self.columnXWorld = columnXWorld
            self.columnZWorld = columnZWorld
            self.supportHeight = supportHeight
        }

        /// 格子中心 = 最小角 + 半格。
        func worldCenter(spacing: Float) -> SIMD3<Float> {
            SIMD3(columnXWorld + spacing * 0.5, supportHeight, columnZWorld + spacing * 0.5)
        }
    }

    /// 一个四边实例。`center` 已含抬高量，`size` 已扣掉缝隙。
    struct Instance: Equatable, Sendable {
        let center: SIMD3<Float>
        let size: Float
        let alpha: Float
        let state: CellState
    }

    struct Options: Equatable, Sendable {
        /// 抬高，避免与承托面共面闪烁。
        var lift: Float = 0.001
        /// 每格留出的缝隙比例，做出"一格一格"的观感（0 = 严丝合缝）。
        var gap: Float = 0.08
        /// 这个距离以内完全不透明。
        var fadeStart: Float = 8
        /// 到这个距离完全淡出，不再绘制。
        var fadeEnd: Float = 28
        /// 硬上限：超过它一律不画（也不参与预算竞争）。
        var maximumDistance: Float = 30
        /// 实例上限。**超出时丢最远的**，而不是拒绝用户放置：
        /// 渲染预算只能影响"画多少"，不能影响"能放多少"。
        var maximumInstances: Int = 20000

        static let `default` = Options()

        var isValid: Bool {
            lift.isFinite && gap.isFinite && (0..<1).contains(gap)
                && fadeStart.isFinite && fadeEnd.isFinite && fadeStart >= 0
                && fadeEnd > fadeStart && maximumDistance > 0 && maximumInstances > 0
        }

        /// 距离 → 不透明度：`fadeStart` 内全不透明，之后线性衰减到 `fadeEnd` 归零。
        func alpha(at distance: Float) -> Float {
            guard distance.isFinite else { return 0 }
            if distance <= fadeStart { return 1 }
            guard fadeEnd > fadeStart else { return 0 }
            return max(0, min(1, 1 - (distance - fadeStart) / (fadeEnd - fadeStart)))
        }
    }

    /// 生成实例列表。
    ///
    /// - `states` 里缺省的格子按 `.placeable` 处理：派生的承托结构本身不做合法性过滤，
    ///   合法性来自 `PropPlacementEvaluator`；缺省即"没有被判定为不能放"。
    /// - 输出顺序与 `cells` 一致（`PropSupportGrid.layers` 本身是确定性顺序），
    ///   便于测试逐项比较，也便于渲染层稳定分块。
    static func instances(
        cells: [Cell],
        states: [Cell: CellState] = [:],
        cameraPosition: SIMD3<Float>,
        spacing: Float,
        options: Options = .default
    ) -> [Instance] {
        build(cells: cells, states: states, cameraPosition: cameraPosition,
              spacing: spacing, options: options, alphaScale: { _ in 1 })
    }

    /// **本帧实际要画的东西**：`focus` 圈定的那一小块，本体全对比、外圈压到 `Focus.ringAlpha`。
    ///
    /// 这是建造模式唯一该走的入口 —— 直接调 `instances` 会画出整片地面（那是改动前的行为，
    /// 只在离线逐项验证距离淡出/预算时才有用）。
    static func focusedInstances(
        cells: [Cell],
        states: [Cell: CellState],
        cameraPosition: SIMD3<Float>,
        spacing: Float,
        options: Options = .default
    ) -> [Instance] {
        let focus = focus(cells: cells, states: states)
        guard !focus.core.isEmpty else { return [] }
        let ringAlpha = Focus.ringAlpha
        return build(
            cells: focus.cells, states: states, cameraPosition: cameraPosition,
            spacing: spacing, options: options,
            alphaScale: { focus.core.contains($0) ? 1 : ringAlpha }
        )
    }

    /// 实例生成的唯一实现。`alphaScale` 是逐格的不透明度倍数（焦点环用它把外圈压淡），
    /// 与距离淡出**相乘**：淡出只回答"远近"，`alphaScale` 只回答"本体还是外圈"。
    private static func build(
        cells: [Cell],
        states: [Cell: CellState],
        cameraPosition: SIMD3<Float>,
        spacing: Float,
        options: Options,
        alphaScale: (Cell) -> Float
    ) -> [Instance] {
        guard options.isValid, !cells.isEmpty,
              spacing.isFinite, spacing > 0,
              cameraPosition.x.isFinite, cameraPosition.y.isFinite, cameraPosition.z.isFinite
        else { return [] }

        let size = spacing * (1 - options.gap)
        guard size > 0, size.isFinite else { return [] }

        struct Entry { let index: Int; let distance: Float; let instance: Instance }
        var entries: [Entry] = []
        entries.reserveCapacity(cells.count)

        for (index, cell) in cells.enumerated() {
            let center = cell.worldCenter(spacing: spacing)
            guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { continue }
            let distance = simd_length(center - cameraPosition)
            guard distance.isFinite, distance <= options.maximumDistance else { continue }
            let alpha = options.alpha(at: distance) * alphaScale(cell)
            guard alpha > 0 else { continue }

            let lifted = SIMD3(center.x, center.y + options.lift, center.z)
            entries.append(Entry(index: index, distance: distance,
                                 instance: Instance(center: lifted, size: size,
                                                    alpha: alpha, state: states[cell] ?? .placeable)))
        }

        if entries.count > options.maximumInstances {
            // 丢最远的：按距离升序（同距离按原始下标）稳定排序，保留前 N，再还原原始顺序。
            entries.sort { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }
            entries.removeLast(entries.count - options.maximumInstances)
            entries.sort { $0.index < $1.index }
        }
        return entries.map(\.instance)
    }
}
