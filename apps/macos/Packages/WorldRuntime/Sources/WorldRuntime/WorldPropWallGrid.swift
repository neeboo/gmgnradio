import Foundation

// ===========================================================================
// 「靠墙放」—— 竖直面（墙面）从**既有几何**里派生出来，不另建一套世界
// ===========================================================================
//
// ## 为什么要有这一份
//
// 今天"可放置面"只有一种：`PropSupportGrid` 派生出来的**承托层**（每个 (x,z) 列上一个高度）。
// 那是列扫描的产物 —— 一列只能给出一个 y，所以它**只可能表达水平面**。用户的原话是
// 「现在放置只能放地板」，要的是"靠墙"。
//
// 墙**已经在几何里**了：cabin 的碰撞网格里那些竖直三角形就是墙，
// `WorldPropSupportQuerying.triangles(in:)` 今天就能把它们取出来（`PropPlacementEvaluator`
// 的净空判定一直在用它们，`blockedByMesh` 说的"这里会插进墙或家具"就是它）。
// 所以这一份**不引入任何新的世界几何来源**：输入就是同一批三角形 + 同一张承托网格。
//
// ## 关键设计：墙面只负责**生成候选落点**，判定仍然是那**一个**判据
//
// 靠墙摆放 = "站在地板上、背朝墙"。所以它不需要任何新判据：
//
//   1. 从同一批三角形里认出竖直面（本文件）；
//   2. 把物件的**背面**（本地 -Z；正面 +Z 是判据链的锚定语义定出来的，见
//      `WorldPropOrientationPolicy.canonicalForward`）转到墙的外法线上，落点交给
//      **地板摆放那同一条换算** `WorldPlanarFootprint.center(anchoredAt:spacing:)` ——
//      既有的评估器正是用它把 footprint 摊到世界上，所以"面板说能靠墙"与"真的落地"
//      看到的是同一个盒子；
//   3. 位置与 yaw 交给**既有那一条**判定通路（`PropPlacementEvaluator` /
//      `ResidentPropPlacementService`）—— 承托层一致性、网格净空（"墙前净空不足"、
//      "会插进墙或家具"就是这里拒绝的）、阻挡体积、已放物件互斥、居民可达性，
//      一个字都不放宽、也不重写。
//
// 于是"靠墙可放"的格子与"真的落到地上"是**同一个答案**（同一条出口），
// 不可能出现"面板说能靠墙、落地却被拒"。
//
// ## ⚠️ 两件必须如实说出来的事（真机实测，见 tools/test-resident-prop-orientation-and-wall.swift）
//
// **1. 承托网格刻意剔除了贴着墙的那一圈。** 站立判据用的是半径 0.2 m 的胶囊
// （`PropSupportGridFilter`），格心离墙面不足 0.2 m 时 `canOccupy` 必为假 ⇒ 那一列不是
// 站立层、进不了 BFS ⇒ **没有承托层**。所以"贴墙那一格"在既有判据下必然读成
// `.noSupport`（可见拒绝，不是静默放行）。真实舱体 @0.25 m：3160 层，贴墙一圈在
// `report.layersBeforeFilter` 里看得见、在 `layersAfterFilter` 里没有。
// 因此本文件的候选按"离墙由近到远"排（`maximumAnchorDepth` 格），第一格就是贴墙那一个：
// 能放时最贴墙，放不下时自动退到最近的可放格。**真正贴墙**需要新增"可放不可站"的承托
// 类别，那会改动承托/通道/红绿格的既有语义 —— 属于产品取舍，不在这里偷偷做。
//
// **2. 贴墙平面被格边界量化。** 锚定语义要求盒子的背面落在格子边界上，所以候选的背面
// 只能落在 `k × spacing` 上（最多差一格）。落在墙**里**的那一侧由既有的网格净空判据
// 兜底（拒绝），所以量化只可能让某一格读成"不可靠墙"，不可能让它穿墙。
//
// ## 为什么不做"绕墙面法线任意倾斜"
//
// 判据链（footprint 平面化、`WorldPropMeshClearance.canPlace` 的 yaw-only 守卫、
// `WorldPropBoxOverlap`、承托层一致性、`ResidentPropPlacementService.validate` 从
// `effectiveSize` 取半长）**整体**建立在"物件绕竖轴转"这个前提上。让一件东西绕**水平**
// 法线倾斜，等于给这几条判据各加一条非 yaw 分支 —— 那是第二套几何；而且摆放落地那条
// 唯一出口（`ResidentPropPlacementService`）只吃 `(surfaceID, position, yaw)`，
// 放不下"某一次摆放专用的包围盒"。所以这一份把墙面坐标系（法线 / 切线 / 竖直）如实给出、
// 用它定出 yaw 与落点；倾斜留待判据链整体支持非 yaw 时再加，而不是先在画面上转、
// 让判据在后面追。倾斜的完整实现要改 `ResidentPropPlacementService.swift`（本轮明确避开）。

/// 一个**竖直面**（墙/家具侧面）：法线沿 X 或 Z，位置吸附到格边界。
///
/// 它是**查询结果**（从既有三角形里派生的），不是世界数据：不存档、不写回、
/// 每次从同一份几何派生。同一份几何 + 同一张网格 ⇒ 同一批墙面（顺序确定）。
public struct WorldPropWallPatch: Equatable, Hashable, Sendable {
    public enum Axis: String, Codable, Equatable, Sendable {
        case x
        case z
    }

    /// 墙面法线沿哪根水平轴。
    public let axis: Axis
    /// 墙面所在的世界坐标（x 或 z），**吸附到格边界**（`整数 × spacing`）。
    public let coordinate: Float
    /// 房间在墙面的哪一侧：`+1` ⇒ 可站立的空间在 `coordinate` 的正方向一侧。
    public let normalSign: Float
    /// 墙沿**另一根**水平轴的范围。
    public let tangentMinimum: Float
    public let tangentMaximum: Float
    /// 墙面的高度范围（米）。
    public let minimumHeight: Float
    public let maximumHeight: Float
    /// 墙面**房间侧**那一列里、落在墙高范围内的承托层所在列（贴墙的地面格）。
    public let columns: [PropSupportColumn]

    public init(axis: Axis, coordinate: Float, normalSign: Float,
                tangentMinimum: Float, tangentMaximum: Float,
                minimumHeight: Float, maximumHeight: Float,
                columns: [PropSupportColumn]) {
        self.axis = axis
        self.coordinate = coordinate
        self.normalSign = normalSign
        self.tangentMinimum = tangentMinimum
        self.tangentMaximum = tangentMaximum
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
        self.columns = columns
    }

    /// 稳定的审计标识（渲染/日志/测试都用它）。
    public var id: String {
        let sign = normalSign >= 0 ? "+" : "-"
        return "wall.\(axis.rawValue)@\(String(format: "%.3f", coordinate)):\(sign)"
    }

    /// 墙的外法线（指向房间）。
    public var normal: SIMD2<Float> {
        switch axis {
        case .x: return SIMD2(normalSign, 0)
        case .z: return SIMD2(0, normalSign)
        }
    }

    /// 墙面切向（沿墙）。
    public var tangent: SIMD2<Float> {
        switch axis {
        case .x: return SIMD2(0, 1)
        case .z: return SIMD2(1, 0)
        }
    }

    public var isValid: Bool {
        [coordinate, normalSign, tangentMinimum, tangentMaximum, minimumHeight, maximumHeight]
            .allSatisfy(\.isFinite)
            && (normalSign == 1 || normalSign == -1)
            && tangentMinimum <= tangentMaximum
            && minimumHeight <= maximumHeight
    }
}

/// 一个**靠墙候选落点**：位置吸附到墙面、正面朝房间、底面落在既有承托层上。
public struct WorldPropWallAttachment: Equatable, Sendable {
    public let patch: WorldPropWallPatch
    /// 物件坐在哪一层承托面上（与地板摆放同一个 `PropSupportLayerRef` 口径）。
    public let layer: PropSupportLayerRef
    /// 摆件位置（= 物件 AABB 中心；底面在 `layer.supportHeight`）。
    public let position: WorldVector3
    /// 背面贴墙、正面朝房间的 yaw。
    public let yaw: Float

    public init(patch: WorldPropWallPatch, layer: PropSupportLayerRef,
                position: WorldVector3, yaw: Float) {
        self.patch = patch
        self.layer = layer
        self.position = position
        self.yaw = yaw
    }
}

public enum WorldPropWallGrid {
    /// 判"这个三角形是不是竖直面"的法线容差：`|n.y| <= 0.34` ≈ 与竖直方向夹角 20° 以内。
    ///
    /// 取 20°：真实舱体的墙不是数学平面（有倒角、有起伏），阈值太紧会一片墙都认不出来；
    /// 太松会把桌面/斜屋顶当成墙。0.34 落在两者之间，而且**只影响"能不能当墙用"**，
    /// 判定仍然由既有的净空判据兜底（认错了墙 ⇒ 摆件与它相交 ⇒ 既有判据拒绝）。
    public static let verticalNormalLimit: Float = 0.34
    /// 三角形的**厚度**上限（沿法线轴的跨度，米）：竖直面在法线方向上必须是薄的。
    public static let maximumThickness: Float = 0.02
    /// 墙脚与地板的容差（米）：网格墙常常比地板低几厘米（沉进楼板），这一条让那些墙也认得出。
    /// 取 0.3 与 `PropSupportGridParameters.maximumStepHeight` 同一个量级 —— 再高就不是
    /// "墙脚沉下去"，而是"这面墙悬在半空、底下没有地板"。
    public static let floorTolerance: Float = 0.3
    /// 一次派生最多产出多少个墙面（防御病态网格；真实舱体是几十个量级）。
    public static let maximumPatches = 1024

    /// 从**既有**三角形派生竖直面。
    ///
    /// - `triangles`：调用方从 `WorldPropSupportQuerying.triangles(in:)` 拿到的那一批
    ///   （与承托网格派生**同一份**几何，不新开来源）；
    /// - `grid`：承托网格，用来判定"墙的哪一侧是房间"以及贴墙那一列有没有可站立的地面；
    /// - `bounds`：派生范围（与承托网格同一份边界）。
    public static func derive(
        triangles: [WorldTriangle],
        bounds: WorldPlanarBounds,
        grid: PropSupportGrid
    ) -> [WorldPropWallPatch] {
        let spacing = grid.spacing
        guard spacing.isFinite, spacing > 0, bounds.isValid, !triangles.isEmpty else { return [] }
        var raw: [RawPatch] = []
        raw.reserveCapacity(64)
        for triangle in triangles {
            guard let patch = rawPatch(of: triangle, bounds: bounds, spacing: spacing) else { continue }
            raw.append(patch)
            if raw.count >= maximumPatches * 8 { break }
        }
        guard !raw.isEmpty else { return [] }
        raw.sort { lhs, rhs in
            if lhs.axis != rhs.axis { return lhs.axis.rawValue < rhs.axis.rawValue }
            if lhs.coordinate != rhs.coordinate { return lhs.coordinate < rhs.coordinate }
            if lhs.normalSign != rhs.normalSign { return lhs.normalSign > rhs.normalSign }
            if lhs.tangentMinimum != rhs.tangentMinimum { return lhs.tangentMinimum < rhs.tangentMinimum }
            return lhs.tangentMaximum < rhs.tangentMaximum
        }
        var merged: [RawPatch] = []
        for patch in raw {
            if var last = merged.last, last.canMerge(with: patch) {
                last.tangentMinimum = min(last.tangentMinimum, patch.tangentMinimum)
                last.tangentMaximum = max(last.tangentMaximum, patch.tangentMaximum)
                last.minimumHeight = min(last.minimumHeight, patch.minimumHeight)
                last.maximumHeight = max(last.maximumHeight, patch.maximumHeight)
                merged[merged.count - 1] = last
            } else {
                merged.append(patch)
                if merged.count >= maximumPatches { break }
            }
        }
        return merged.flatMap { resolve($0, grid: grid) }.sorted { $0.id < $1.id }
    }

    /// 一个原始（未合并）竖直面：位置已经吸附到格边界，还没问过"哪一侧是房间"。
    private struct RawPatch {
        var axis: WorldPropWallPatch.Axis
        var coordinate: Float
        var normalSign: Float
        var tangentMinimum: Float
        var tangentMaximum: Float
        var minimumHeight: Float
        var maximumHeight: Float

        func canMerge(with other: RawPatch) -> Bool {
            axis == other.axis && coordinate == other.coordinate && normalSign == other.normalSign
                && other.tangentMinimum <= tangentMaximum + 0.0001
                && tangentMinimum <= other.tangentMaximum + 0.0001
        }
    }

    private static func rawPatch(
        of triangle: WorldTriangle,
        bounds: WorldPlanarBounds,
        spacing: Float
    ) -> RawPatch? {
        let a = triangle.first, b = triangle.second, c = triangle.third
        guard [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z].allSatisfy(\.isFinite) else { return nil }
        let ab = b - a, ac = c - a
        let normal = SIMD3(
            ab.y * ac.z - ab.z * ac.y,
            ab.z * ac.x - ab.x * ac.z,
            ab.x * ac.y - ab.y * ac.x
        )
        let length = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
        guard length > 0.0000001 else { return nil }
        let unit = normal / length
        guard abs(unit.y) <= verticalNormalLimit else { return nil }

        let axis: WorldPropWallPatch.Axis = abs(unit.x) >= abs(unit.z) ? .x : .z
        let coordinateOf: (SIMD3<Float>) -> Float = { axis == .x ? $0.x : $0.z }
        let tangentOf: (SIMD3<Float>) -> Float = { axis == .x ? $0.z : $0.x }
        let values = [coordinateOf(a), coordinateOf(b), coordinateOf(c)]
        let low = values.min()!, high = values.max()!
        // 法线方向必须是**薄的**：厚的那是斜屋顶/台阶，不是墙。
        guard high - low <= maximumThickness else { return nil }
        let plane = (low + high) / 2
        // 吸附到格边界：格子 `k` 覆盖 `[k*spacing, (k+1)*spacing]`，所以边界就是 `k*spacing`。
        let snapped = (plane / spacing).rounded() * spacing
        guard snapped.isFinite else { return nil }
        switch axis {
        case .x:
            guard snapped >= bounds.minimumX - 0.001, snapped <= bounds.maximumX + 0.001 else { return nil }
        case .z:
            guard snapped >= bounds.minimumZ - 0.001, snapped <= bounds.maximumZ + 0.001 else { return nil }
        }
        let tangentValues = [tangentOf(a), tangentOf(b), tangentOf(c)]
        let heights = [a.y, b.y, c.y]
        // 法线的**朝向**：`unit` 指哪边都可以，房间在哪一侧稍后由承托网格回答（两个方向各试一次）。
        return RawPatch(
            axis: axis,
            coordinate: snapped,
            normalSign: 1,
            tangentMinimum: tangentValues.min()!,
            tangentMaximum: tangentValues.max()!,
            minimumHeight: heights.min()!,
            maximumHeight: heights.max()!
        )
    }

    /// 把原始面变成可用的墙面：**房间在哪一侧由承托网格回答**。
    ///
    /// 两侧都有地面 ⇒ 两侧各出一份（房间中间的隔断两侧都能靠），顺序固定为 `+1` 在前。
    /// 贴墙那一列必须真的有承托层，否则这面墙"靠"不上任何地板。
    private static func resolve(_ raw: RawPatch, grid: PropSupportGrid) -> [WorldPropWallPatch] {
        var patches: [WorldPropWallPatch] = []
        for sign in [Float(1), Float(-1)] {
            let columns = adjacentColumns(raw, normalSign: sign, grid: grid)
            guard !columns.isEmpty else { continue }
            // 房间那一侧得**真的有一块地板**，否则这面墙"靠"不上任何东西
            // （真实舱体的外墙外侧没有承托层 ⇒ 只出一份朝房间的墙面，不会凭空多出一份）。
            guard hasFloorOnRoomSide(raw, normalSign: sign, grid: grid) else { continue }
            patches.append(WorldPropWallPatch(
                axis: raw.axis, coordinate: raw.coordinate, normalSign: sign,
                tangentMinimum: raw.tangentMinimum, tangentMaximum: raw.tangentMaximum,
                minimumHeight: raw.minimumHeight, maximumHeight: raw.maximumHeight,
                columns: columns
            ))
        }
        return patches
    }

    /// 墙面**房间侧**那一列的列号（贴墙的锚定列）。
    ///
    /// `coordinate` 已经吸附到格边界（= `k*spacing`）。**两个方向都用同一个 `k`**：
    /// `attachment` 把盒子的本地 +Z 转到外法线，而 `WorldPlanarFootprint.center(anchoredAt:)`
    /// 让盒子从锚定列的**最小角**沿本地 +Z 长出去 —— 于是不论 `normalSign` 是 +1 还是 -1，
    /// 盒子的**背面**（本地 -Z）都正好落在 `coordinate` 这条格边界上。
    static func adjacentColumnIndex(coordinate: Float, normalSign: Float, spacing: Float) -> Int {
        _ = normalSign
        return Int((coordinate / spacing).rounded())
    }

    /// 房间那一侧的探针列里，至少有一列在墙高范围内有承托层。
    ///
    /// 探针 = 从墙脚那一列起、朝**房间里**走 `maximumAnchorDepth` 列。为什么要往里看：
    /// 紧贴墙的那一列往往本来就没有承托层（站不下人 ⇒ 被承托网格剔掉），只看它会把
    /// 每一面**外墙**都判成"这一侧不是房间"。这一条只是"这面墙值不值得列出来"的预筛；
    /// "这一格能不能放"仍然由那一个判据回答（它会把盒子覆盖的每一列都查一遍）。
    private static func hasFloorOnRoomSide(
        _ raw: RawPatch,
        normalSign: Float,
        grid: PropSupportGrid
    ) -> Bool {
        let spacing = grid.spacing
        let anchorIndex = adjacentColumnIndex(
            coordinate: raw.coordinate, normalSign: normalSign, spacing: spacing
        )
        guard let range = propSupportColumnRange(
            minimum: raw.tangentMinimum, maximum: raw.tangentMaximum, spacing: spacing
        ) else { return false }
        // 从墙脚那一列往**房间里**探 `maximumAnchorDepth` 列：贴着墙的第一列往往本来就没有
        // 承托层（站不下人 ⇒ 被承托网格剔掉），所以"这一侧有没有房间"要往里看一两列。
        for depth in 0 ..< maximumAnchorDepth {
            let probeIndex = anchorIndex + Int(normalSign) * depth
            for index in range {
                let column: PropSupportColumn
                switch raw.axis {
                case .x: column = PropSupportColumn(x: probeIndex, z: index)
                case .z: column = PropSupportColumn(x: index, z: probeIndex)
                }
                guard grid.contains(column) else { continue }
                let hasFloor = grid.layers(at: column).contains { layer in
                    layer.supportHeight >= raw.minimumHeight - floorTolerance
                        && layer.supportHeight <= raw.maximumHeight + 0.0001
                }
                if hasFloor { return true }
            }
        }
        return false
    }

    /// 贴墙那一列里落在墙高范围内的承托层所在列（沿切线方向，按墙的切线范围裁剪）。
    private static func adjacentColumns(
        _ raw: RawPatch,
        normalSign: Float,
        grid: PropSupportGrid
    ) -> [PropSupportColumn] {
        let spacing = grid.spacing
        let fixed = adjacentColumnIndex(coordinate: raw.coordinate, normalSign: normalSign, spacing: spacing)
        // 切线方向的列范围：墙面切线范围 [min, max] 覆盖的格子。
        let tangentMinimum = raw.tangentMinimum
        let tangentMaximum = raw.tangentMaximum
        guard let range = propSupportColumnRange(
            minimum: tangentMinimum, maximum: tangentMaximum, spacing: spacing
        ) else { return [] }
        var columns: [PropSupportColumn] = []
        for index in range {
            let column: PropSupportColumn
            switch raw.axis {
            case .x: column = PropSupportColumn(x: fixed, z: index)
            case .z: column = PropSupportColumn(x: index, z: fixed)
            }
            // 这里**不**要求这一列自己有承托层：`normalSign = -1` 时锚定列在外墙之外，
            // 而盒子是朝房间里长的。"墙脚有没有地板"由那**一个**判据回答
            // （`PropPlacementEvaluator` 会检查盒子覆盖的每一列），不在这里另立一份。
            columns.append(column)
        }
        return columns
    }

    /// 由墙面 + 承托层 + 物件尺寸定出"背面贴墙"的候选落点。
    ///
    /// **位置不是这里自己算出来的**，而是转交给地板摆放那**同一条**换算
    /// （`WorldPlanarFootprint.center(anchoredAt:spacing:)`）：既有的摆放判据
    /// （`PropPlacementEvaluator`）正是用这一个函数把 footprint 摊到世界上，
    /// 所以"面板说能靠墙"与"真的落地"看到的是**同一个盒子**，不可能各算各的。
    ///
    /// yaw：把物件的**背面（本地 -Z）**转到墙的外法线上 ⇒ `yaw = atan2(n.x, n.z)`；
    /// 于是正面（本地 +Z）朝房间，盒子从锚定列沿外法线长出去 ⇒ 背面正好落在墙面上。
    ///
    /// ⚠️ 贴墙平面被**格边界量化**：锚定列的最小边就是墙面，所以平面必须落在格边界上
    /// （最多差一格 0.25 m）。越到墙里的那一侧由既有的网格净空判据兜底（会拒绝），
    /// 所以量化只可能让某一格读成"不可靠墙"，不可能让它穿墙。
    ///
    /// 返回的候选**不保证能放** —— 能不能放由既有那一条判据回答（见文件头）。
    public static func attachment(
        patch: WorldPropWallPatch,
        layer: PropSupportLayerRef,
        anchorColumn: PropSupportColumn,
        size: WorldVector3,
        spacing: Float
    ) -> WorldPropWallAttachment? {
        guard patch.isValid, spacing.isFinite, spacing > 0,
              size.x.isFinite, size.y.isFinite, size.z.isFinite,
              size.x > 0, size.y > 0, size.z > 0,
              !patch.columns.isEmpty
        else { return nil }
        let normal = patch.normal
        guard normal.x.isFinite, normal.y.isFinite else { return nil }
        let yaw = atan2(normal.x, normal.y)
        guard yaw.isFinite, layer.supportHeight.isFinite else { return nil }
        let footprint = WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw)
        let centre = footprint.center(anchoredAt: anchorColumn, spacing: spacing)
        guard centre.x.isFinite, centre.y.isFinite else { return nil }
        return WorldPropWallAttachment(
            patch: patch, layer: layer,
            position: WorldVector3(x: centre.x, y: layer.supportHeight, z: centre.y),
            yaw: yaw
        )
    }

    /// 靠墙候选最多往房间里退几列。
    ///
    /// 为什么需要"退"：承托网格**刻意剔除了贴着墙的那一圈**格子 —— 站立胶囊半径 0.2 m，
    /// 格心离墙面不足 0.2 m 时 `canOccupy` 必为假，于是那一列不是站立层、进不了 BFS
    /// （见 `PropSupportGridFilter` 的注释与 `report.layersBeforeFilter/AfterFilter` 的差值）。
    /// 那一圈**没有承托层** ⇒ 贴墙平面上的候选会被既有的承托判据判成 `.noSupport`。
    /// 所以这里按"离墙由近到远"生成若干个锚定列：**第一格就是贴墙那一个**（能放时最贴墙），
    /// 往后每一格退 0.25 m。能不能放仍然由那**一个**判据回答 —— 这里不替它做决定，
    /// 更不放宽它（真正贴墙需要新增"可放不可站"的承托类别，那是另一件事，见 README/汇报）。
    public static let maximumAnchorDepth = 3

    /// 一面墙 × 这张网格 × 物件尺寸 ⇒ 全部候选落点（顺序确定：先近后远，再切线，再层）。
    ///
    /// 候选 = "锚定列 + 一个真实的承托层"。承托层的**出处**是这一格盒子的**覆盖列**
    /// （`footprint.columns(anchoredAt:)`）：贴墙那一侧的墙脚可能压根没有承托层，
    /// 所以层必须从盒子真正坐着的那些列上取。
    ///
    /// 调用方拿这些候选去跑既有的那一条判定；能不能放由它回答。
    public static func candidateAttachments(
        patch: WorldPropWallPatch,
        grid: PropSupportGrid,
        size: WorldVector3
    ) -> [WorldPropWallAttachment] {
        guard patch.isValid, grid.spacing.isFinite, grid.spacing > 0,
              size.x.isFinite, size.y.isFinite, size.z.isFinite,
              size.x > 0, size.y > 0, size.z > 0
        else { return [] }
        let spacing = grid.spacing
        let normal = patch.normal
        let yaw = atan2(normal.x, normal.y)
        guard yaw.isFinite else { return [] }
        let footprint = WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw)
        let boundary = adjacentColumnIndex(
            coordinate: patch.coordinate, normalSign: patch.normalSign, spacing: spacing
        )
        // 切线下标取自补丁自己的锚定列（它们全在 boundary 这一列上）。
        let tangentIndices: [Int] = patch.columns
            .map { patch.axis == .x ? $0.z : $0.x }
            .sorted()
        guard !tangentIndices.isEmpty else { return [] }
        var result: [WorldPropWallAttachment] = []
        var seen = Set<String>()
        for depth in 0 ..< maximumAnchorDepth {
            let normalIndex = boundary + Int(patch.normalSign) * depth
            for tangent in tangentIndices {
                let anchor: PropSupportColumn
                switch patch.axis {
                case .x: anchor = PropSupportColumn(x: normalIndex, z: tangent)
                case .z: anchor = PropSupportColumn(x: tangent, z: normalIndex)
                }
                let covered = footprint.columns(anchoredAt: anchor, spacing: spacing)
                guard !covered.isEmpty else { continue }
                // 层的层号按**覆盖列里真实存在的那几层**枚举（顺序确定），高度取该层自身的高度。
                var layersByIndex: [Int: PropSupportLayer] = [:]
                for column in covered.sorted(by: { ($0.x, $0.z) < ($1.x, $1.z) }) {
                    guard grid.contains(column) else { continue }
                    for layer in grid.layers(at: column) {
                        guard layer.supportHeight >= patch.minimumHeight - floorTolerance,
                              layer.supportHeight <= patch.maximumHeight + 0.0001
                        else { continue }
                        if layersByIndex[layer.layer] == nil { layersByIndex[layer.layer] = layer }
                    }
                }
                for index in layersByIndex.keys.sorted() {
                    guard let layer = layersByIndex[index] else { continue }
                    let key = "\(anchor.x),\(anchor.z),\(layer.layer)"
                    guard seen.insert(key).inserted else { continue }
                    let layerRef = PropSupportLayerRef(column: anchor, layer: layer)
                    guard let attachment = attachment(
                        patch: patch, layer: layerRef, anchorColumn: anchor,
                        size: size, spacing: spacing
                    ) else { continue }
                    result.append(attachment)
                }
            }
        }
        return result
    }
}
