import Foundation

/// 承托结构派生的参数。
///
/// 这些参数与派生算法一起构成"承托结构"的完整定义：同一份几何 + 同一份参数必须得到
/// 同一张网格（`algorithmVersion` 是将来把派生结果纳入烘焙门禁时的版本号入口）。
///
/// 后四个参数是**连通性过滤**（见 `PropSupportGridBuilder.build`）的输入：过滤前的
/// 列扫描会把 5 米高的屋顶也枚举进来，只有"从种子点可达"才能把它们剔掉。
public struct PropSupportGridParameters: Equatable, Sendable {
    /// 格子间距（米）。默认 0.25：摆放需要贴合物件尺寸，比导航的 0.5 m 细。
    public let spacing: Float
    /// 逐层下降的步长（米）。默认 0.101，与烘焙器 `tools/navigation/LivingCabinNavigation.swift`
    /// 的列扫描一致：必须大于 `groundHeight` 的 0.05 m 容差，否则会反复命中同一层。
    public let layerStepDown: Float
    /// 列扫描初始天花板在范围内最高几何之上的余量（米）。默认 0.1，与烘焙器一致。
    public let scanCeilingMargin: Float
    /// 派生算法版本。**2 起**表示结果经过连通性过滤（1 = 纯列扫描，会把屋顶/天花板/孤岛
    /// 一起列出来），将来把派生结果纳入烘焙门禁时靠它区分旧缓存。
    public let algorithmVersion: Int
    /// 一步能迈过的最大高差（米）。默认 0.3，与烘焙器 `bakeCabinNavigation` 一致。
    /// 同列纵向与相邻列横向的连通都受它约束：0.5 m 高的平台不是"台阶"，是另一块地。
    public let maximumStepHeight: Float
    /// 站立胶囊半径（米）。默认 0.2，与烘焙器一致。
    public let capsuleRadius: Float
    /// 站立胶囊高度（米）。默认 1.8，与烘焙器一致。
    public let capsuleHeight: Float
    /// 家具带高度（米）。默认 1.6：可达地面之上这么高以内的层算"家具顶面"。
    ///
    /// 为什么单独给一个带而不是复用胶囊高度：家具顶面**自己站不住人**（胶囊进不去
    /// 家具下面，见 `PropSupportGridBuilder.build` 的"家具下地面层"），它的合法性来自
    /// "就在可达地面正上方"。带越高越容易把二层/夹层也当成家具顶面（见 §5.3b 的不确定项）。
    public let furnitureBandHeight: Float

    public static let `default` = PropSupportGridParameters()

    public init(
        spacing: Float = 0.25,
        layerStepDown: Float = 0.101,
        scanCeilingMargin: Float = 0.1,
        algorithmVersion: Int = 2,
        maximumStepHeight: Float = 0.3,
        capsuleRadius: Float = 0.2,
        capsuleHeight: Float = 1.8,
        furnitureBandHeight: Float = 1.6
    ) {
        self.spacing = spacing
        self.layerStepDown = layerStepDown
        self.scanCeilingMargin = scanCeilingMargin
        self.algorithmVersion = algorithmVersion
        self.maximumStepHeight = maximumStepHeight
        self.capsuleRadius = capsuleRadius
        self.capsuleHeight = capsuleHeight
        self.furnitureBandHeight = furnitureBandHeight
    }

    /// 连通性过滤使用的站立胶囊。
    public var capsule: WorldCapsule {
        WorldCapsule(radius: capsuleRadius, height: capsuleHeight)
    }

    public var isValid: Bool {
        spacing.isFinite && spacing > 0
            && layerStepDown.isFinite && layerStepDown > 0
            && scanCeilingMargin.isFinite && scanCeilingMargin >= 0
            && algorithmVersion >= 1
            && maximumStepHeight.isFinite && maximumStepHeight >= 0
            && furnitureBandHeight.isFinite && furnitureBandHeight >= 0
            && capsule.isValid
    }
}

/// 一次派生的报告：调用方（和测试）据此看见过滤掉了什么。
///
/// 对齐烘焙器 `CabinNavigationReport` 的风格：烘焙器把 `surfaceCandidates` /
/// `blockedCandidates` / `disconnectedCandidates` 全部写进报告，而不是静默丢弃。
public struct PropSupportGridReport: Equatable, Sendable {
    /// 有承托面的列数（至少枚举出一层的列）。
    public let columns: Int
    /// 列扫描枚举出的层数（过滤前）。真实生活舱 @0.25 m 实测 9,737。
    public let layersBeforeFilter: Int
    /// 过滤后留下的层数。
    public let layersAfterFilter: Int
    /// 其中"站立胶囊可容纳"的层数（过滤前的口径）。
    public let standableLayers: Int
    /// 其中"家具下地面层"的层数（过滤前的口径）：见 `build` 里的定义。
    public let coveredGroundLayers: Int
    /// 从种子点 BFS 可达的层数（含家具下地面层）。
    public let reachableLayers: Int
    /// 靠家具带保留的层数：本身不可达，但位于某个可达层上方 `furnitureBandHeight` 内。
    public let furnitureBandLayers: Int
    /// 是否找到了种子层。false 时 `layers` 必为空（种子越界 / 没有候选层 / 没有几何）。
    public let seeded: Bool

    public static let empty = PropSupportGridReport(
        columns: 0,
        layersBeforeFilter: 0,
        layersAfterFilter: 0,
        standableLayers: 0,
        coveredGroundLayers: 0,
        reachableLayers: 0,
        furnitureBandLayers: 0,
        seeded: false
    )

    public init(
        columns: Int,
        layersBeforeFilter: Int,
        layersAfterFilter: Int,
        standableLayers: Int,
        coveredGroundLayers: Int,
        reachableLayers: Int,
        furnitureBandLayers: Int,
        seeded: Bool
    ) {
        self.columns = columns
        self.layersBeforeFilter = layersBeforeFilter
        self.layersAfterFilter = layersAfterFilter
        self.standableLayers = standableLayers
        self.coveredGroundLayers = coveredGroundLayers
        self.reachableLayers = reachableLayers
        self.furnitureBandLayers = furnitureBandLayers
        self.seeded = seeded
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
///
/// **与"哪些层该存在"的区别**：上面说的是"某件东西能不能放在这一层"（评估器的活）；
/// 本类型已经做完了"这一层该不该存在"（**连通性过滤**，见 `PropSupportGridBuilder.build`）。
/// 列扫描会把屋顶、天花板、地面以下的外侧底面、不连通的孤岛一起枚举出来，过滤把它们剔除。
/// 真实生活舱 @0.25 m 实测：9,737 层 → 3,185 层，最高保留层 2.19 m（屋顶 5.31 m 全部剔除）。
public struct PropSupportGrid: Sendable {
    public let spacing: Float
    public let bounds: WorldPlanarBounds
    public let parameters: PropSupportGridParameters
    /// 扁平、**确定性顺序**（先 x 升 → 再 z 升 → 再 layer 升）的全部格子。
    /// 便于测试逐项比较，也便于渲染层按顺序分块上传。
    ///
    /// 只含通过连通性过滤的层。`layer` 保留**过滤前**的层号（不重排）：同一物理层在
    /// 相邻列必须共享同一个 `layer` 号，否则 footprint 跨列时 `PropPlacementEvaluator`
    /// 的"同一层"判据会错位。因此过滤后的层号可能有空洞（例如 0、2），这是刻意的。
    public let layers: [PropSupportLayerRef]
    /// 这次派生过滤掉了什么（对齐烘焙器的 report 风格）。
    public let report: PropSupportGridReport

    private let layersByColumn: [PropSupportColumn: [PropSupportLayer]]
    private let columnRangeX: ClosedRange<Int>?
    private let columnRangeZ: ClosedRange<Int>?

    init(
        spacing: Float,
        bounds: WorldPlanarBounds,
        parameters: PropSupportGridParameters,
        layers: [PropSupportLayerRef],
        report: PropSupportGridReport,
        layersByColumn: [PropSupportColumn: [PropSupportLayer]],
        columnRangeX: ClosedRange<Int>?,
        columnRangeZ: ClosedRange<Int>?
    ) {
        self.spacing = spacing
        self.bounds = bounds
        self.parameters = parameters
        self.layers = layers
        self.report = report
        self.layersByColumn = layersByColumn
        self.columnRangeX = columnRangeX
        self.columnRangeZ = columnRangeZ
    }

    /// 没有任何承托面的网格（几何缺失 / 边界不成立 / 种子不可用）。`contains` 仍按边界回答，
    /// 这样调用方能区分"越界"和"这里没有承托面"。
    static func empty(
        spacing: Float,
        bounds: WorldPlanarBounds,
        parameters: PropSupportGridParameters,
        report: PropSupportGridReport = .empty
    ) -> PropSupportGrid {
        PropSupportGrid(
            spacing: spacing,
            bounds: bounds,
            parameters: parameters,
            layers: [],
            report: report,
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
    /// **语义随连通性过滤而收窄**：它只看过滤后仍然存在的层，也就是"真的能放东西的层"。
    /// 过滤前它可能返回屋顶/天花板上的层（都是合法几何面），现在不会 —— 这正是渲染层
    /// 拾取和 `PropPlacementEvaluator` 想要的语义。
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
///
/// **`build` 还要做烘焙器紧跟着做的那一步（工作项 1–3 当时漏掉了）**。烘焙器的注释原文：
///
/// > "Visit every actual ground layer; **connectivity decides which layer belongs to the
/// > resident's reachable area.**"
///
/// 只做列扫描会得到什么（真实生活舱实测，161,600 三角形，0.25 m 间距）：
///
/// | 指标 | 值 |
/// | --- | --- |
/// | 层总数 | 9,737 |
/// | 高度分布 | y≈-1: 1067（外侧底面）· y≈0: 3231（地面）· y≈1: 694（桌面）· y≈2: 864 · y≈3: 1611 · y≈4: 555 · **y≈5: 1715（屋顶）** |
/// | 站立胶囊可容纳 | 6,763 / 9,737 |
///
/// 于是装修模式一进去整个屋子连**屋顶**都是格子。
///
/// **两种"显而易见的过滤"都不管用（都是实测反例，不要再走一遍）**：
/// 1. `isWalkableSurface` 用 `normal.y * normal.y >= lengthSquared * 0.5`，**朝上朝下都成立**，
///    所以它区分不了地板与天花板；屋顶外表面甚至是**朝上**的，照样通过。
/// 2. "站立胶囊可容纳"（`canOccupy`）**顶不住屋顶**：屋顶上方没有东西，站在屋顶上完全合法，
///    实测 6,763 层通过，3–5 米那 3,881 层全在里面。
///
/// 所以这里做**连通性过滤**：从种子点出发，只保留
/// **可达的站立层** ∪ **紧挨可达层上方一个带宽内的层**（桌面/家具顶面）。
public enum PropSupportGridBuilder {
    /// 单次派生的列数上限。防止病态边界（例如 spacing 极小）导致天文数字循环。
    /// 真实房间 13.5 m × 23.0 m、0.25 m 间距只有约 5,000 列。
    static let maximumColumnCount: Double = 2_000_000

    /// 单列层数上限。防御不收敛的病态几何；截断只会少列层，不会多列层。
    static let maximumLayerCount = 256

    /// 派生一张承托网格。
    ///
    /// `seed` 是连通性的起点（用世界的 spawn）：取离它最近的候选层作为唯一 BFS 起点。
    /// 种子必须落在 `bounds` 内，否则返回空网格 + `report.seeded == false`
    /// （不猜、不放行：fail-closed，与 `ResidentPropPlacementError.environmentNotReady` 同向）。
    public static func build(
        collision: any WorldPropSupportQuerying,
        bounds: WorldPlanarBounds,
        seed: WorldVector3,
        parameters: PropSupportGridParameters = .default
    ) -> PropSupportGrid {
        let resolvedSpacing = parameters.spacing.isFinite && parameters.spacing > 0
            ? parameters.spacing
            : PropSupportGridParameters.default.spacing
        guard bounds.isValid, parameters.isValid,
              seed.x.isFinite, seed.y.isFinite, seed.z.isFinite
        else {
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

        var scannedLayers: [PropSupportLayerRef] = []
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
                    scannedLayers.append(PropSupportLayerRef(column: column, layer: layer))
                }
                layersByColumn[column] = columnLayers
            }
        }

        let filter = PropSupportGridFilter(
            collision: collision,
            parameters: parameters,
            bounds: bounds,
            seed: seed,
            scannedLayers: scannedLayers,
            layersByColumn: layersByColumn
        ).run()

        return PropSupportGrid(
            spacing: resolvedSpacing,
            bounds: bounds,
            parameters: parameters,
            layers: filter.layers,
            report: filter.report,
            layersByColumn: filter.layersByColumn,
            columnRangeX: columnRangeX,
            columnRangeZ: columnRangeZ
        )
    }
}

/// 连通性过滤（`PropSupportGridBuilder.build` 的第二步）。独立成类型只是为了把两段
/// 职责分开：上面是"几何上有什么面"，这里是"哪些面属于住户真正够得着的区域"。
private struct PropSupportGridFilter {
    let collision: any WorldPropSupportQuerying
    let parameters: PropSupportGridParameters
    let bounds: WorldPlanarBounds
    let seed: WorldVector3
    /// 过滤前的扁平层（确定性顺序）与按列索引。列内数组的下标 **就是** `layer` 号。
    let scannedLayers: [PropSupportLayerRef]
    let layersByColumn: [PropSupportColumn: [PropSupportLayer]]

    func run() -> (
        layers: [PropSupportLayerRef],
        report: PropSupportGridReport,
        layersByColumn: [PropSupportColumn: [PropSupportLayer]]
    ) {
        let capsule = parameters.capsule
        let columnsWithSupport = layersByColumn.count

        // 1. 候选层 = 站立层 ∪ 家具下地面层。
        //
        // 站立层：`canOccupy(capsule, at: layer.center)`。注意这**不是**防屋顶的手段
        // （屋顶上方没东西，站上去合法），屋顶靠下面的 BFS 剔除。
        //
        // 家具下地面层：某列的最低层，且同列在 `(最低层, 最低层 + furnitureBandHeight]`
        // 内还有另一层。站立胶囊进不去家具下面（桌面板就在躯干高度上，`canOccupy` 必为假），
        // 但那一列的地面在"地面平面"上仍然是可达地面的一部分 —— 桌面板的 band 锚点只能是它。
        //
        // 没有这一条会怎样（真实房间实测）：y∈(0.5, 1.6) 的家具顶面 1,192 层里，
        // 只有 **44** 层在"锚点必须是站立层"的严格规则下拿得到同列下方锚点，
        // 于是设计文档 §5.4 里编辑器三个具名面之一的"桌面"会整体消失。
        // 墙不会因此漏进来：墙是竖直几何，不会在列里产生横向承托层，
        // 所以墙所在列既不是站立层、也不是家具下地面层，根本不在候选里（BFS 穿不过去）。
        var standable: Set<PropSupportLayerRef> = []
        var coveredGround: Set<PropSupportLayerRef> = []
        // 按过滤前的确定性顺序遍历（每列的 layer 0 正好出现一次），不遍历字典的键集合：
        // 结果本来就与顺序无关，但"遍历顺序也确定"省得以后有人怀疑这里有随机性。
        for groundRef in scannedLayers where groundRef.layer.layer == 0 {
            let column = groundRef.column
            guard let columnLayers = layersByColumn[column], let ground = columnLayers.first else {
                continue
            }
            if collision.canOccupy(capsule, at: ground.center.simd3) {
                standable.insert(groundRef)
            } else if columnLayers.dropFirst().contains(where: {
                $0.supportHeight - ground.supportHeight > 0.0001
                    && $0.supportHeight - ground.supportHeight
                        <= parameters.furnitureBandHeight + 0.0001
            }) {
                coveredGround.insert(groundRef)
            }
            for layer in columnLayers.dropFirst() where collision.canOccupy(capsule, at: layer.center.simd3) {
                standable.insert(PropSupportLayerRef(column: column, layer: layer))
            }
        }
        var candidates = standable
        candidates.formUnion(coveredGround)

        let baseReport = PropSupportGridReport(
            columns: columnsWithSupport,
            layersBeforeFilter: scannedLayers.count,
            layersAfterFilter: 0,
            standableLayers: standable.count,
            coveredGroundLayers: coveredGround.count,
            reachableLayers: 0,
            furnitureBandLayers: 0,
            seeded: false
        )

        // 种子必须落在边界内：越界说明调用方拿错了世界坐标，宁可返回空网格也不猜。
        guard bounds.contains(x: seed.x, z: seed.z) else {
            return ([], baseReport, [:])
        }

        // 2. 种子层 = 离种子点最近的候选层（平局保留扁平顺序里最靠前的一个，结果确定）。
        //    不做距离上限：种子已经在边界内，这里要的是"起点"，不是"附近有没有东西"。
        var seedRef: PropSupportLayerRef?
        var bestDistanceSquared = Float.infinity
        for ref in scannedLayers where candidates.contains(ref) {
            let deltaX = ref.center.x - seed.x
            let deltaY = ref.center.y - seed.y
            let deltaZ = ref.center.z - seed.z
            let distanceSquared = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
            guard distanceSquared.isFinite else { continue }
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                seedRef = ref
            }
        }
        guard let start = seedRef else {
            // 没有候选层（例如范围内只有一个屋顶）：空网格 + report 明确说"没种上"。
            return ([], baseReport, [:])
        }

        // 3. BFS：只走候选层。
        //    - 同列纵向：与当前层高差 <= maximumStepHeight 的候选层。
        //    - 同层横向：8 邻列中**层号相同**的候选层，且 canTraverse 为真。
        //      例外：两侧都是"地面层"（layer 0）且至少一侧是家具下地面层时，只看高差。
        //      站立胶囊进不去家具 footprint（canTraverse 必为假），但地面平面在那里是连续的；
        //      没有这条例外，整张桌子（含桌面）都会因为 `canOccupy` 进不去而消失。
        var reached: Set<PropSupportLayerRef> = [start]
        var queue: [PropSupportLayerRef] = [start]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1

            for layer in layersByColumn[current.column] ?? [] {
                let ref = PropSupportLayerRef(column: current.column, layer: layer)
                guard candidates.contains(ref), !reached.contains(ref),
                      abs(layer.supportHeight - current.supportHeight)
                          <= parameters.maximumStepHeight + 0.0001
                else { continue }
                reached.insert(ref)
                queue.append(ref)
            }

            for deltaX in -1 ... 1 {
                for deltaZ in -1 ... 1 where !(deltaX == 0 && deltaZ == 0) {
                    let column = PropSupportColumn(
                        x: current.column.x + deltaX,
                        z: current.column.z + deltaZ
                    )
                    guard let layers = layersByColumn[column],
                          current.layer.layer < layers.count
                    else { continue }
                    let layer = layers[current.layer.layer]
                    let ref = PropSupportLayerRef(column: column, layer: layer)
                    guard candidates.contains(ref), !reached.contains(ref),
                          abs(layer.supportHeight - current.supportHeight)
                              <= parameters.maximumStepHeight + 0.0001
                    else { continue }
                    let bothGroundLevel = current.layer.layer == 0 && layer.layer == 0
                    let furnitureFloorLevel = coveredGround.contains(current)
                        || coveredGround.contains(ref)
                    guard (bothGroundLevel && furnitureFloorLevel)
                        || collision.canTraverse(
                            capsule,
                            from: current.center.simd3,
                            to: ref.center.simd3,
                            maximumStepHeight: parameters.maximumStepHeight
                        )
                    else { continue }
                    reached.insert(ref)
                    queue.append(ref)
                }
            }
        }

        // 4. 保留集 = 可达层 ∪ { 同列中位于某个可达层上方、且高度差 <= furnitureBandHeight 的层 }。
        var retained = reached
        for ref in reached {
            for layer in layersByColumn[ref.column] ?? []
            where layer.supportHeight > ref.supportHeight
                && layer.supportHeight - ref.supportHeight
                    <= parameters.furnitureBandHeight + 0.0001 {
                retained.insert(PropSupportLayerRef(column: ref.column, layer: layer))
            }
        }

        // 5. 其余层从 grid.layers 中剔除；顺序沿用过滤前的确定性顺序（x → z → layer）。
        var layers: [PropSupportLayerRef] = []
        layers.reserveCapacity(retained.count)
        var retainedByColumn: [PropSupportColumn: [PropSupportLayer]] = [:]
        for ref in scannedLayers where retained.contains(ref) {
            layers.append(ref)
            retainedByColumn[ref.column, default: []].append(ref.layer)
        }

        let report = PropSupportGridReport(
            columns: columnsWithSupport,
            layersBeforeFilter: scannedLayers.count,
            layersAfterFilter: layers.count,
            standableLayers: standable.count,
            coveredGroundLayers: coveredGround.count,
            reachableLayers: reached.count,
            furnitureBandLayers: layers.count - reached.count,
            seeded: true
        )
        return (layers, report, retainedByColumn)
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
