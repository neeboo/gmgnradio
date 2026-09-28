import Foundation
import simd

/// 摆放格子 → 呈现与拾取所需形状的**纯映射**，以及 footprint 的状态着色。
///
/// 刻意**不 import WorldRuntime**：这样离线 harness 不必编译整个 WorldRuntime 包
/// （那要 ~40 秒一次），而这里的映射恰恰是最容易出错的地方——半格偏移、层顺序、
/// footprint 整块着色。调用方负责把 `PropSupportGrid.layers` 摊平成下面的轻量输入。
///
/// **坐标约定（与 WorldRuntime 一致，且只在这里做一次换算）**：列号 × 间距 = 该列的世界
/// **最小角**，格心 = 最小角 + 半个间距。`PropSupportGridPresentation` 内部会自己加半格，
/// 所以这里**只填最小角**，绝不预先加半格，否则整张格子会偏移半格。
enum PropSupportGridMapping {
    /// 一个格子的最小输入。
    struct LayerInput: Equatable, Sendable {
        let columnX: Int
        let columnZ: Int
        let layer: Int
        let supportHeight: Float
        /// 该网格的间距（米）。逐项携带是为了让映射保持无状态、可逐项测试。
        let spacing: Float

        init(columnX: Int, columnZ: Int, layer: Int, supportHeight: Float, spacing: Float) {
            self.columnX = columnX
            self.columnZ = columnZ
            self.layer = layer
            self.supportHeight = supportHeight
            self.spacing = spacing
        }
    }

    /// 列号 → 世界最小角。唯一的换算点。
    static func columnWorldOrigin(columnX: Int, columnZ: Int, spacing: Float) -> SIMD2<Float> {
        SIMD2(Float(columnX) * spacing, Float(columnZ) * spacing)
    }

    /// 映射成呈现层的格子。**保持输入顺序**（`PropSupportGrid.layers` 本身是确定性顺序），
    /// 并且逐项保留自己的 `spacing`，这样同一帧里若混入不同间距的层也不会错。
    static func presentationCells(_ layers: [LayerInput]) -> [PropSupportGridPresentation.Cell] {
        layers.map { layer in
            let origin = columnWorldOrigin(columnX: layer.columnX, columnZ: layer.columnZ, spacing: layer.spacing)
            return PropSupportGridPresentation.Cell(
                columnX: layer.columnX,
                columnZ: layer.columnZ,
                layer: layer.layer,
                columnXWorld: origin.x,
                columnZWorld: origin.y,
                supportHeight: layer.supportHeight
            )
        }
    }

    /// 映射成拾取候选。拾取器自己按 `spacing` 把命中点量化成列号，所以这里不需要世界坐标。
    static func pickerCandidates(_ layers: [LayerInput]) -> [PropSupportGridPicker.Candidate] {
        layers.map { layer in
            PropSupportGridPicker.Candidate(
                columnX: layer.columnX,
                columnZ: layer.columnZ,
                layer: layer.layer,
                supportHeight: layer.supportHeight
            )
        }
    }

    /// 列键。footprint 覆盖列与格子列都用它比较，避免比较浮点世界坐标。
    struct ColumnKey: Hashable, Sendable {
        let x: Int
        let z: Int

        init(x: Int, z: Int) {
            self.x = x
            self.z = z
        }
    }

    /// footprint 覆盖范围内的格子状态。
    ///
    /// 只输出**属于该 footprint** 的格子：列在覆盖集内，且层号等于锚点层号
    /// （footprint 是贴着某一层放的，不该把同列的其他层也染成同一个颜色）。
    /// 其余格子**不出现在字典里**，呈现层对缺失项默认 `.placeable`。
    ///
    /// `isFootprintValid` 是**整块**的判定结果（由 `PropPlacementEvaluator` 给出），
    /// 所以整块 footprint 一起变绿或一起变红 —— 这正是 Sims 的手感。
    static func footprintStates(
        cells: [PropSupportGridPresentation.Cell],
        coveredColumns: Set<ColumnKey>,
        anchorLayer: Int,
        isFootprintValid: Bool
    ) -> [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] {
        guard !coveredColumns.isEmpty else { return [:] }
        var states: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
        let state: PropSupportGridPresentation.CellState = isFootprintValid ? .validFootprint : .invalidFootprint
        for cell in cells where cell.layer == anchorLayer
            && coveredColumns.contains(ColumnKey(x: cell.columnX, z: cell.columnZ)) {
            states[cell] = state
        }
        return states
    }

    /// 吸附后的摆放位置：格心（最小角 + 半格），y 用承托高度。
    ///
    /// 与 `PropSupportGridPresentation.Cell.worldCenter(spacing:)` 必须一致——两处都加半格，
    /// 不允许其中一处加两次。
    static func snappedPlacementPosition(
        columnX: Int,
        columnZ: Int,
        spacing: Float,
        supportHeight: Float
    ) -> SIMD3<Float> {
        let origin = columnWorldOrigin(columnX: columnX, columnZ: columnZ, spacing: spacing)
        return SIMD3(origin.x + spacing * 0.5, supportHeight, origin.y + spacing * 0.5)
    }

    /// 把 yaw 归一化到 `[0, 2π)`。步进旋转用它，避免反复累加后漂成大数。
    static func normalizedYaw(_ yaw: Float) -> Float {
        guard yaw.isFinite else { return 0 }
        let twoPi = Float.pi * 2
        let remainder = yaw.truncatingRemainder(dividingBy: twoPi)
        return remainder < 0 ? remainder + twoPi : remainder
    }

    /// 步进旋转：**45° 一步**（与 The Sims 4 官方口径一致；2026-09-28 之前是 90°，
    /// 见 `docs/plans/2026-09-28-decoration-in-space-interaction.md` D4）。
    ///
    /// 步长只在这一处：`ResidentPropGridEditorModel.rotateFootprint(bySteps:)` 是旋转的
    /// 唯一入口（R / ⇧R / `,` / `.` / 场景内手柄都走它），谁都不要再抄一份。
    static func yaw(rotatedBySteps steps: Int, from yaw: Float) -> Float {
        normalizedYaw(yaw + Float(steps) * (Float.pi / 4))
    }
}
