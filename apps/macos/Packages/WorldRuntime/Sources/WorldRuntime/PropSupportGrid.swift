import Foundation

/// 承托结构派生的参数。
///
/// 这些参数与派生算法一起构成"承托结构"的完整定义：同一份几何 + 同一份参数必须得到
/// 同一张网格（`algorithmVersion` 是将来把派生结果纳入烘焙门禁时的版本号入口）。
public struct PropSupportGridParameters: Equatable, Sendable {
    /// 格子间距（米）。默认 0.25：摆放需要贴合物件尺寸，比导航的 0.5 m 细。
    public let spacing: Float
    /// 逐层下降的步长（米）。默认 0.101，与烘焙器 `tools/navigation/LivingCabinNavigation.swift`
    /// 的列扫描一致：必须大于 `groundHeight` 的 0.05 m 容差，否则会反复命中同一层。
    public let layerStepDown: Float
    /// 列扫描初始天花板在范围内最高几何之上的余量（米）。默认 0.1，与烘焙器一致。
    public let scanCeilingMargin: Float
    /// 派生算法版本，从 1 起。
    public let algorithmVersion: Int

    public static let `default` = PropSupportGridParameters()

    public init(
        spacing: Float = 0.25,
        layerStepDown: Float = 0.101,
        scanCeilingMargin: Float = 0.1,
        algorithmVersion: Int = 1
    ) {
        self.spacing = spacing
        self.layerStepDown = layerStepDown
        self.scanCeilingMargin = scanCeilingMargin
        self.algorithmVersion = algorithmVersion
    }

    public var isValid: Bool {
        spacing.isFinite && spacing > 0
            && layerStepDown.isFinite && layerStepDown > 0
            && scanCeilingMargin.isFinite && scanCeilingMargin >= 0
            && algorithmVersion >= 1
    }
}

/// 格子列：世界坐标 = `Float(x) * spacing` / `Float(z) * spacing`（与烘焙器的列编号一致）。
///
/// 一列（同一 x,z）可能有多层承托面（地面、桌面、台阶），层号见 `PropSupportLayer.layer`。
public struct PropSupportColumn: Hashable, Sendable {
    public let x: Int
    public let z: Int

    public init(x: Int, z: Int) {
        self.x = x
        self.z = z
    }

    /// 该列的世界 XZ 坐标（列的最小角，见 `WorldPlanarFootprint.columns(anchoredAt:spacing:)`）。
    public func worldPosition(spacing: Float) -> SIMD2<Float> {
        SIMD2(Float(x) * spacing, Float(z) * spacing)
    }
}

/// 一层承托面：某列上第 `layer` 层的高度。
public struct PropSupportLayer: Equatable, Hashable, Sendable {
    /// 层号，从 0 起，按高度升序。
    public let layer: Int
    public let supportHeight: Float
    /// 承托面中心：`(列世界 x, supportHeight, 列世界 z)`。
    public let center: WorldVector3

    public init(layer: Int, supportHeight: Float, center: WorldVector3) {
        self.layer = layer
        self.supportHeight = supportHeight
        self.center = center
    }
}

/// 列 + 层的组合引用，方便查询与渲染分块（同时带 column 与 layer）。
public struct PropSupportLayerRef: Equatable, Hashable, Sendable {
    public let column: PropSupportColumn
    public let layer: PropSupportLayer

    public init(column: PropSupportColumn, layer: PropSupportLayer) {
        self.column = column
        self.layer = layer
    }

    public var supportHeight: Float { layer.supportHeight }
    public var center: WorldVector3 { layer.center }
}

/// 派生出的承托结构。
///
/// **架构上刻意把"承托结构"和"某件物件的合法性"分开**：
/// 承托结构只依赖几何（本类型），建一次即可缓存、可在渲染层反复用；
/// 合法性依赖"你正在放的那件东西"（尺寸、高度），由 `PropPlacementEvaluator` 每次评估
/// 少数几个格子。所以这里**不做任何"能不能放"的过滤**，也就不会为每件物件重建整张网格。
public struct PropSupportGrid: Sendable {
    public let spacing: Float
    public let bounds: WorldPlanarBounds
    public let parameters: PropSupportGridParameters
    /// 扁平、**确定性顺序**（先 x 升 → 再 z 升 → 再 layer 升）的全部格子。
    /// 便于测试逐项比较，也便于渲染层按顺序分块上传。
    public let layers: [PropSupportLayerRef]

    private let layersByColumn: [PropSupportColumn: [PropSupportLayer]]
    private let columnRangeX: ClosedRange<Int>?
    private let columnRangeZ: ClosedRange<Int>?

    init(
        spacing: Float,
        bounds: WorldPlanarBounds,
        parameters: PropSupportGridParameters,
        layers: [PropSupportLayerRef],
        layersByColumn: [PropSupportColumn: [PropSupportLayer]],
        columnRangeX: ClosedRange<Int>?,
        columnRangeZ: ClosedRange<Int>?
    ) {
        self.spacing = spacing
        self.bounds = bounds
        self.parameters = parameters
        self.layers = layers
        self.layersByColumn = layersByColumn
        self.columnRangeX = columnRangeX
        self.columnRangeZ = columnRangeZ
    }

    /// 没有任何承托面的网格（几何缺失 / 边界不成立）。`contains` 仍按边界回答，
    /// 这样调用方能区分"越界"和"这里没有承托面"。
    static func empty(
        spacing: Float,
        bounds: WorldPlanarBounds,
        parameters: PropSupportGridParameters
    ) -> PropSupportGrid {
        PropSupportGrid(
            spacing: spacing,
            bounds: bounds,
            parameters: parameters,
            layers: [],
            layersByColumn: [:],
            columnRangeX: propSupportColumnRange(
                minimum: bounds.minimumX,
                maximum: bounds.maximumX,
                spacing: spacing
            ),
            columnRangeZ: propSupportColumnRange(
                minimum: bounds.minimumZ,
                maximum: bounds.maximumZ,
                spacing: spacing
            )
        )
    }

    /// 该列的全部承托层，按 layer 升序；没有则返回空数组。
    public func layers(at column: PropSupportColumn) -> [PropSupportLayer] {
        layersByColumn[column] ?? []
    }

    /// 该列是否落在派生边界内。
    public func contains(_ column: PropSupportColumn) -> Bool {
        guard let columnRangeX, let columnRangeZ else { return false }
        return columnRangeX.contains(column.x) && columnRangeZ.contains(column.z)
    }

    /// 距离 `point` 最近的一层承托面；`maximumDistance` 之外返回 nil。
    ///
    /// 只在"XZ 距离不超过 maximumDistance"的列里找：任何 3D 距离 ≤ d 的层，
    /// 其 |dx|、|dz| 必然 ≤ d，所以这个列范围是精确的（不是近似）。
    /// 平局时保留 (x, z, layer) 顺序里最靠前的一个，结果确定。
    public func nearestLayer(
        to point: WorldVector3,
        maximumDistance: Float
    ) -> PropSupportLayerRef? {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              maximumDistance.isFinite, maximumDistance >= 0,
              spacing.isFinite, spacing > 0,
              let xRange = propSupportColumnRange(
                  minimum: point.x - maximumDistance,
                  maximum: point.x + maximumDistance,
                  spacing: spacing
              ),
              let zRange = propSupportColumnRange(
                  minimum: point.z - maximumDistance,
                  maximum: point.z + maximumDistance,
                  spacing: spacing
              )
        else {
            return nil
        }

        var best: PropSupportLayerRef?
        var bestDistanceSquared = Float.infinity
        for x in xRange {
            for z in zRange {
                let column = PropSupportColumn(x: x, z: z)
                guard let columnLayers = layersByColumn[column] else { continue }
                for layer in columnLayers {
                    let deltaX = layer.center.x - point.x
                    let deltaY = layer.center.y - point.y
                    let deltaZ = layer.center.z - point.z
                    let distanceSquared = deltaX * deltaX
                        + deltaY * deltaY
                        + deltaZ * deltaZ
                    guard distanceSquared <= maximumDistance * maximumDistance else {
                        continue
                    }
                    // 严格小于：平局时保留扁平顺序里最靠前的那一个。
                    if distanceSquared < bestDistanceSquared {
                        bestDistanceSquared = distanceSquared
                        best = PropSupportLayerRef(column: column, layer: layer)
                    }
                }
            }
        }
        return best
    }
}

/// 承托结构派生器。
///
/// 多层枚举复用烘焙器已验证的列扫描算法（`tools/navigation/LivingCabinNavigation.swift`）：
/// 一列可能有多层承托面（地面、桌面、台阶），必须全部枚举出来，`layer` 从 0 起按高度升序编号。
/// 唯一的差别是天花板/底面取"本次派生范围"内几何的 minY / maxY（烘焙器取全量顶点），
/// 范围收窄不影响结果：能投影到范围内某列的三角形必然也落在范围内。
public enum PropSupportGridBuilder {
    /// 单次派生的列数上限。防止病态边界（例如 spacing 极小）导致天文数字循环。
    /// 真实房间 13.5 m × 23.0 m、0.25 m 间距只有约 5,000 列。
    static let maximumColumnCount: Double = 2_000_000

    /// 单列层数上限。防御不收敛的病态几何；截断只会少列层，不会多列层。
    static let maximumLayerCount = 256

    public static func build(
        collision: any WorldPropSupportQuerying,
        bounds: WorldPlanarBounds,
        parameters: PropSupportGridParameters = .default
    ) -> PropSupportGrid {
        let resolvedSpacing = parameters.spacing.isFinite && parameters.spacing > 0
            ? parameters.spacing
            : PropSupportGridParameters.default.spacing
        guard bounds.isValid, parameters.isValid else {
            return PropSupportGrid.empty(
                spacing: resolvedSpacing,
                bounds: bounds,
                parameters: parameters
            )
        }

        // 一片范围里的几何只查一次：初始天花板与终止下界都由它算出来（不做全量遍历）。
        let regionTriangles = collision.triangles(in: bounds)
        var maximumY = -Float.greatestFiniteMagnitude
        var minimumY = Float.greatestFiniteMagnitude
        for triangle in regionTriangles {
            let upper = triangle.boundsMaximum.y
            let lower = triangle.boundsMinimum.y
            guard upper.isFinite, lower.isFinite else { continue }
            maximumY = max(maximumY, upper)
            minimumY = min(minimumY, lower)
        }
        guard maximumY.isFinite, minimumY.isFinite, minimumY <= maximumY else {
            // 范围内没有可用几何：没有任何承托面（不猜、不放行）。
            return PropSupportGrid.empty(
                spacing: resolvedSpacing,
                bounds: bounds,
                parameters: parameters
            )
        }

        guard let columnRangeX = propSupportColumnRange(
            minimum: bounds.minimumX,
            maximum: bounds.maximumX,
            spacing: resolvedSpacing
        ),
            let columnRangeZ = propSupportColumnRange(
                minimum: bounds.minimumZ,
                maximum: bounds.maximumZ,
                spacing: resolvedSpacing
            ),
            propSupportColumnCount(columnRangeX) * propSupportColumnCount(columnRangeZ)
                <= maximumColumnCount
        else {
            return PropSupportGrid.empty(
                spacing: resolvedSpacing,
                bounds: bounds,
                parameters: parameters
            )
        }

        var layers: [PropSupportLayerRef] = []
        var layersByColumn: [PropSupportColumn: [PropSupportLayer]] = [:]
        // 确定性顺序：x 升 → z 升 → layer 升。
        for x in columnRangeX {
            for z in columnRangeZ {
                let columnX = Float(x) * resolvedSpacing
                let columnZ = Float(z) * resolvedSpacing
                var ceiling = maximumY + parameters.scanCeilingMargin
                var heights: [Float] = []
                // 一列可能同时有地面和桌面（甚至台阶）：逐层下降，把每一层都收进来。
                // `groundHeight(at:)` 的语义是"不高于 position.y + 0.05 的最高承托面"，
                // 所以每次把天花板压到刚找到的那一层之下（步长 > 0.05），就能取到下一层。
                while heights.count < maximumLayerCount,
                      let ground = collision.groundHeight(
                          at: SIMD3(columnX, ceiling, columnZ)
                      ),
                      ground >= minimumY - 0.001 {
                    heights.append(ground)
                    ceiling = ground - parameters.layerStepDown
                }
                guard !heights.isEmpty else { continue }

                let column = PropSupportColumn(x: x, z: z)
                var columnLayers: [PropSupportLayer] = []
                columnLayers.reserveCapacity(heights.count)
                for (level, height) in heights.sorted().enumerated() {
                    let layer = PropSupportLayer(
                        layer: level,
                        supportHeight: height,
                        center: WorldVector3(x: columnX, y: height, z: columnZ)
                    )
                    columnLayers.append(layer)
                    layers.append(PropSupportLayerRef(column: column, layer: layer))
                }
                layersByColumn[column] = columnLayers
            }
        }

        return PropSupportGrid(
            spacing: resolvedSpacing,
            bounds: bounds,
            parameters: parameters,
            layers: layers,
            layersByColumn: layersByColumn,
            columnRangeX: columnRangeX,
            columnRangeZ: columnRangeZ
        )
    }
}

/// 列索引范围：格子坐标 = `index * spacing`，只取落在 [minimum, maximum] 内的列。
/// 与烘焙器的 `Int(ceil(minX/spacing))...Int(floor(maxX/spacing))` 一致。
func propSupportColumnRange(
    minimum: Float,
    maximum: Float,
    spacing: Float
) -> ClosedRange<Int>? {
    guard minimum.isFinite, maximum.isFinite, spacing.isFinite, spacing > 0 else {
        return nil
    }
    let lower = ceil(minimum / spacing)
    let upper = floor(maximum / spacing)
    let limit: Float = 9e15
    guard lower.isFinite, upper.isFinite, lower > -limit, upper < limit, lower <= upper else {
        return nil
    }
    return Int(lower) ... Int(upper)
}

/// 用 Double 计算列数，避免 ClosedRange<Int>.count 在极端范围上溢出。
func propSupportColumnCount(_ range: ClosedRange<Int>) -> Double {
    Double(range.upperBound) - Double(range.lowerBound) + 1
}
