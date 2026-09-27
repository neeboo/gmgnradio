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
            let alpha = options.alpha(at: distance)
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
