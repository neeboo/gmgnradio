import Foundation
import simd

// MARK: - 前景遮挡：把"更近的东西"从覆盖层上**按区域**裁掉
//
// 覆盖层是 native `CALayer`（`WKWebView` 自己就是一层），**不参与深度测试** ——
// 这是第一版自己标注的限制：站在屏前的角色不会挡住它，"人身上糊着一块网页"。
//
// 这一份文件是**唯一**回答"屏幕上哪一块被更近的东西挡住"的地方：
//
//   * 输入：屏幕四角（世界）、相机位置、一组**凸**遮挡物（房间三角面 / 物件盒 / 居民盒）；
//   * 输出：一张**区域级**掩码 —— 哪一格被挡、哪一格看得见（默认 24 × 14 = 336 格）；
//   * 判据：从相机到该格中心的世界点连一条线，是否**先**撞上某个遮挡物。
//
// 为什么是"格级"而不是"逐像素"，以及为什么不是读回深度：
//
//   1. 逐像素要一份深度或物体 ID 的读回。仓里现成的读回路径
//      （`ResidentVisionSurface.captureCurrentObservation`）读回的是**颜色**（BGRA），
//      不是深度；而且它是**单飞 + 按需**的（一次请求对应一帧，后面还要编 PNG）。
//      要在 60 Hz 拿到深度，得给渲染器加一条深度回读并改 shader —— 那是本目录的红线。
//   2. 场景几何**已经在手上**：`SpatialStageStore.sceneOccluderTriangles` 就是渲染器
//      用来做深度遮挡的那一份房间三角面，`WorldObjectState.generatedCollisionVolume`
//      就是每件道具的盒，`avatarPlacement` 就是居民的摆放。用它们做 CPU 射线求交，
//      结果与渲染器看到的是**同一份几何**，不新增第二条事实源。
//   3. 于是这一级的诚实标注是"**格级**（24 × 14），不是逐像素"。格数、被挡格数、
//      每格耗时都写在 `WorldScreenOcclusionMask` / 回执里，可复核。
//
// **这一份不依赖 AppKit / Metal / WorldRuntime**：纯值 + 纯函数，离线 harness
// （`tools/test-resident-screen-overlay.swift`）直接编译它并逐格验证。

// MARK: - 遮挡物

/// 一块遮挡用的三角面。
///
/// 三个点就是全部定义。刻意**不复用** `WorldRuntime.WorldTriangle`：本目录的几何
/// 要能被离线 harness 单独编译（与 `WorldScreenPlacement` 不依赖 `WorldRuntime` 同一条纪律）。
struct WorldScreenTriangle: Equatable, Sendable {
    let first: SIMD3<Float>
    let second: SIMD3<Float>
    let third: SIMD3<Float>

    init(_ first: SIMD3<Float>, _ second: SIMD3<Float>, _ third: SIMD3<Float>) {
        self.first = first
        self.second = second
        self.third = third
    }

    var centroid: SIMD3<Float> { (first + second + third) / 3 }
}

/// 一个**只绕 Y 摆放**的盒。
///
/// 语义与生产**逐字一致**：`WorldObjectState.generatedCollisionVolume` 把盒心放在
/// `position.y + size.y / 2`、半长是 `size / 2`，也就是 x/z 以落地点为中心、
/// y 从 0 到 size.y。屏幕四边形（`WorldScreenFace.quad`）用的是同一套约定。
struct WorldScreenBox: Equatable, Sendable {
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
    let yaw: Float
    /// 这个盒是谁的。屏幕自己那件**必须**能被排除，否则会自己挡自己。
    let owner: String?

    init(center: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float, owner: String? = nil) {
        self.center = center
        self.halfExtents = halfExtents
        self.yaw = yaw
        self.owner = owner
    }
}

/// 一帧的遮挡物集合。
///
/// `revision` 只描述**静态三角面**那一半（房间）：它变了才需要重建 BVH。
/// 盒那一半每帧都可能动（居民在走路），所以逐个测、不进 BVH。
struct WorldScreenOccluders: Equatable, Sendable {
    var triangles: [WorldScreenTriangle]
    var boxes: [WorldScreenBox]
    /// 房间三角面的代次（`SpatialStageStore.sceneOccluderRevision`）。
    var revision: UInt64

    static let empty = WorldScreenOccluders(triangles: [], boxes: [], revision: 0)

    init(triangles: [WorldScreenTriangle] = [], boxes: [WorldScreenBox] = [], revision: UInt64 = 0) {
        self.triangles = triangles
        self.boxes = boxes
        self.revision = revision
    }

    /// 把三角面换一份、代次跟着走。房间没变时**不重建** BVH。
    static func triangles(_ triangles: [WorldScreenTriangle], revision: UInt64) -> Self {
        WorldScreenOccluders(triangles: triangles, boxes: [], revision: revision)
    }
}

// MARK: - 掩码

/// 容器 bounds 坐标系里的一个矩形（单位 = 点，左下原点）。
struct WorldScreenMaskRect: Equatable, Sendable {
    let x: Float
    let y: Float
    let width: Float
    let height: Float
}

/// 一块屏幕的**区域级**可见性。
///
/// 坐标口径与 `WorldScreenQuad.corners` 同序：格 `(column, row)` 的 `column` 沿
/// `BL → BR`（屏幕的"右"），`row` 沿 `BL → TL`（屏幕的"上"），两者都从 0 起。
/// 于是 `blocked[row * columns + column]`。
struct WorldScreenOcclusionMask: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let blocked: [Bool]

    init(columns: Int, rows: Int, blocked: [Bool]) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.blocked = blocked
    }

    static func fullyVisible(columns: Int, rows: Int) -> Self {
        WorldScreenOcclusionMask(
            columns: columns, rows: rows,
            blocked: [Bool](repeating: false, count: max(columns, 1) * max(rows, 1))
        )
    }

    var cellCount: Int { columns * rows }

    func isBlocked(column: Int, row: Int) -> Bool {
        guard column >= 0, column < columns, row >= 0, row < rows else { return false }
        let index = row * columns + column
        guard index >= 0, index < blocked.count else { return false }
        return blocked[index]
    }

    var blockedCellCount: Int { blocked.reduce(into: 0) { if $1 { $0 += 1 } } }
    var visibleCellCount: Int { cellCount - blockedCellCount }
    var blockedFraction: Float {
        cellCount == 0 ? 0 : Float(blockedCellCount) / Float(cellCount)
    }

    /// 一格都没被挡 ⇒ 调用方应该**完全不挂掩码**（正常观看时零风险、零开销）。
    var isFullyVisible: Bool { blockedCellCount == 0 }

    /// 可见区域的矩形并集（水平的连续格合并成一条，减少路径段数）。
    /// **顺序固定**（行优先、每行从左到右），于是可以逐位复现。
    func visibleRects(in size: SIMD2<Float>) -> [WorldScreenMaskRect] {
        rects(in: size, matching: false)
    }

    /// 被挡区域的矩形并集。给诊断与判据用（"哪一块不画网页"）。
    func blockedRects(in size: SIMD2<Float>) -> [WorldScreenMaskRect] {
        rects(in: size, matching: true)
    }

    private func rects(in size: SIMD2<Float>, matching wanted: Bool) -> [WorldScreenMaskRect] {
        let cellWidth = size.x / Float(columns)
        let cellHeight = size.y / Float(rows)
        guard cellWidth > 0, cellHeight > 0 else { return [] }
        var result: [WorldScreenMaskRect] = []
        for row in 0 ..< rows {
            var runStart: Int?
            for column in 0 ... columns {
                let matches = column < columns ? (isBlocked(column: column, row: row) == wanted) : false
                if matches, runStart == nil { runStart = column }
                if !matches, let start = runStart {
                    result.append(
                        WorldScreenMaskRect(
                            x: Float(start) * cellWidth,
                            y: Float(row) * cellHeight,
                            width: Float(column - start) * cellWidth,
                            height: cellHeight
                        )
                    )
                    runStart = nil
                }
            }
        }
        return result
    }
}

// MARK: - 一次掩码更新的账

/// 「这一帧算了几格、挡了几格、花了多久」——面板、`read_screen` 与判据**读同一份**。
///
/// 之所以要把它做成一个显式类型：遮挡这一级最容易糊过去的就是"看起来挡住了"，
/// 而成本与格数是它唯一能被复核的两个数字。
struct WorldScreenOcclusionStat: Equatable, Sendable {
    let objectID: String
    let columns: Int
    let rows: Int
    let blockedCellCount: Int
    let cost: Duration

    var cellCount: Int { columns * rows }
    var visibleCellCount: Int { cellCount - blockedCellCount }
    var isFullyVisible: Bool { blockedCellCount == 0 }

    /// 一行话（面板与 `read_screen` 用同一份）。
    var displayText: String {
        let milliseconds = Double(cost.components.attoseconds) / 1e15
            + Double(cost.components.seconds) * 1000
        let costText = String(format: "%.2f ms", milliseconds)
        if isFullyVisible {
            return "前景遮挡：\(columns) × \(rows) 格全部可见（\(costText)）"
        }
        return "前景遮挡：\(blockedCellCount)/\(cellCount) 格被更近的东西挡住"
            + "（可见 \(visibleCellCount) 格，\(costText)）"
    }
}

// MARK: - 射线求交

/// 房间三角面的 BVH。房间不每帧变，建一次用很久（`revision` 变了才重建）。
///
/// 为什么要有它：真机房间的遮挡三角面是**上千**这个量级，336 格 × 每格一次朴素遍历
/// 在 60 Hz 上是纯粹烧 CPU。BVH 把每次查询从 O(三角面数) 降到 O(log n)。
final class WorldScreenOccluderIndex {
    private struct Node {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>
        /// 叶子：`start ..< start + count` 是 `order` 的下标区间；分支：`count == 0`。
        var start: Int32
        var count: Int32
        var left: Int32
        var right: Int32
    }

    private static let leafSize = 8

    let revision: UInt64
    let triangleCount: Int
    private var nodes: [Node] = []
    private var order: [Int32] = []
    private let triangles: [WorldScreenTriangle]

    init(triangles: [WorldScreenTriangle], revision: UInt64) {
        self.triangles = triangles
        self.revision = revision
        self.triangleCount = triangles.count
        guard !triangles.isEmpty else { return }
        order = Array(0 ..< Int32(triangles.count))
        nodes.reserveCapacity(max(triangles.count / Self.leafSize * 2, 1))
        _ = build(range: 0 ..< order.count)
    }

    // MARK: 构建

    private func bounds(of range: Range<Int>) -> (SIMD3<Float>, SIMD3<Float>) {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for index in range {
            let triangle = triangles[Int(order[index])]
            for point in [triangle.first, triangle.second, triangle.third] {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        return (minimum, maximum)
    }

    private func build(range: Range<Int>) -> Int32 {
        let (minimum, maximum) = bounds(of: range)
        let nodeIndex = Int32(nodes.count)
        nodes.append(
            Node(minimum: minimum, maximum: maximum, start: Int32(range.lowerBound),
                 count: Int32(range.count), left: -1, right: -1)
        )
        guard range.count > Self.leafSize else { return nodeIndex }

        let extent = maximum - minimum
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        let sorted = range.sorted { lhs, rhs in
            triangles[Int(order[lhs])].centroid[axis] < triangles[Int(order[rhs])].centroid[axis]
        }.map(Int32.init)
        order.replaceSubrange(range, with: sorted)
        let middle = range.lowerBound + range.count / 2
        guard middle > range.lowerBound, middle < range.upperBound else { return nodeIndex }
        let left = build(range: range.lowerBound ..< middle)
        let right = build(range: middle ..< range.upperBound)
        nodes[Int(nodeIndex)].left = left
        nodes[Int(nodeIndex)].right = right
        nodes[Int(nodeIndex)].count = 0
        return nodeIndex
    }

    // MARK: 查询

    /// 射线 `origin + t · direction`（`t ∈ (0, maximumDistance]`）撞到的**最近**三角面。
    ///
    /// 只算**在前面进入**的：`t <= 0` 一律不算 —— 相机正好落在某个遮挡物内部时
    /// （贴脸、卡进角色里）不该把整块屏幕打黑。
    func firstHit(origin: SIMD3<Float>, direction: SIMD3<Float>, maximumDistance: Float) -> Float? {
        guard !nodes.isEmpty, maximumDistance > 0 else { return nil }
        var best: Float?
        var stack: [Int32] = [0]
        stack.reserveCapacity(64)
        while let nodeIndex = stack.popLast() {
            let node = nodes[Int(nodeIndex)]
            guard let entry = Self.slabEntry(
                minimum: node.minimum, maximum: node.maximum,
                origin: origin, direction: direction, limit: best ?? maximumDistance
            ) else { continue }
            guard entry <= (best ?? maximumDistance) else { continue }
            if node.count == 0 {
                if node.left >= 0 { stack.append(node.left) }
                if node.right >= 0 { stack.append(node.right) }
                continue
            }
            for offset in 0 ..< Int(node.count) {
                let triangle = triangles[Int(order[Int(node.start) + offset])]
                if let distance = Self.triangleHit(
                    triangle, origin: origin, direction: direction, maximumDistance: best ?? maximumDistance
                ), distance > 0, distance < (best ?? maximumDistance) {
                    best = distance
                }
            }
        }
        return best
    }

    /// 射线进入轴对齐盒的参数（`nil` = 没进）。`limit` 之外直接剪掉。
    ///
    /// 与 `boxHit` 同一套 slab 手法，但**不用除法**：方向分量为 0 的轴上只判"在不在盒内"，
    /// 于是不会出现 `0 × ∞ = NaN` 把整次查询判没。
    private static func slabEntry(
        minimum: SIMD3<Float>, maximum: SIMD3<Float>,
        origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float
    ) -> Float? {
        var entry: Float = -.greatestFiniteMagnitude
        var exit: Float = .greatestFiniteMagnitude
        for axis in 0 ..< 3 {
            guard abs(direction[axis]) > 1e-9 else {
                if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] { return nil }
                continue
            }
            let inverse = 1 / direction[axis]
            let near = (minimum[axis] - origin[axis]) * inverse
            let far = (maximum[axis] - origin[axis]) * inverse
            entry = max(entry, min(near, far))
            exit = min(exit, max(near, far))
        }
        guard exit >= max(entry, 0), entry <= limit else { return nil }
        return entry
    }

    /// Möller–Trumbore。**双面**：遮挡物不分正反，两面都不透光。
    private static func triangleHit(
        _ triangle: WorldScreenTriangle,
        origin: SIMD3<Float>, direction: SIMD3<Float>, maximumDistance: Float
    ) -> Float? {
        let edge1 = triangle.second - triangle.first
        let edge2 = triangle.third - triangle.first
        let pvec = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, pvec)
        guard abs(determinant) > 1e-12 else { return nil }
        let inverse = 1 / determinant
        let tvec = origin - triangle.first
        let u = simd_dot(tvec, pvec) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let qvec = simd_cross(tvec, edge1)
        let v = simd_dot(direction, qvec) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = simd_dot(edge2, qvec) * inverse
        guard distance > 0, distance <= maximumDistance else { return nil }
        return distance
    }
}

// MARK: - 格级遮挡判定

/// 「这块屏幕上哪些格被更近的东西挡住」的**唯一**实现。
enum WorldScreenOcclusion {
    /// 默认格数。24 × 14 = 336 格：在 1080p 的一块 1.24 m 屏上每格约 40 × 40 像素，
    /// 足以让"人挡住半边屏"看起来是**被人的轮廓切开**，而不是整块闪掉。
    static let defaultColumns = 24
    static let defaultRows = 14

    /// 遮挡物必须比屏幕**近**这么多米才算数。
    ///
    /// 用途是压掉"与屏幕共面/擦着屏幕"的东西引起的整格抖动：屏幕自己就贴在道具表面上
    /// （外移 1 mm），任何数值噪声都会让边界格来回翻，那正是"正常观看时闪烁"。
    static let depthMargin: Float = 0.02

    /// 相机离格子太近时不做判定（贴着屏幕时"谁挡谁"没有意义，而且方向向量会退化）。
    static let minimumRayLength: Float = 0.05

    /// 屏幕四边形（**世界**，顺序 BL, BR, TR, TL）上参数为 `(u, v)` 的那一点。
    ///
    /// `u` 沿 BL → BR，`v` 沿 BL → TL。四边形是"中心 ± 右 ± 上"派生的平行四边形，
    /// 所以双线性插值的交叉项恒为 0；这里仍写通用式（退化成线性时逐位相同）。
    static func worldPoint(corners: [SIMD3<Float>], u: Float, v: Float) -> SIMD3<Float>? {
        guard corners.count == 4 else { return nil }
        let bl = corners[0], br = corners[1], tr = corners[2], tl = corners[3]
        let bottom = bl + (br - bl) * u
        let top = tl + (tr - tl) * u
        return bottom + (top - bottom) * v
    }

    /// 格 `(column, row)` 中心的参数坐标（`u` 沿右、`v` 沿上，都取格心）。
    static func cellCenter(column: Int, row: Int, columns: Int, rows: Int) -> SIMD2<Float> {
        SIMD2(
            (Float(column) + 0.5) / Float(max(columns, 1)),
            (Float(row) + 0.5) / Float(max(rows, 1))
        )
    }

    /// 算一整块屏幕的可见性掩码。
    ///
    /// - Parameters:
    ///   - quadCorners: 屏幕四角（世界，BL/BR/TR/TL）。
    ///   - cameraPosition: 本帧相机位置。
    ///   - occluders: 遮挡物（房间三角面 + 盒）。
    ///   - index: 与 `occluders.revision` 配套的 BVH（调用方缓存；为 nil 时现建，
    ///     只在测试/一次性路径上用）。
    ///   - owner: 这块屏幕自己的 `objectID`：它自己的盒要排除，否则自己挡自己。
    ///   - depthMargin: 见 `depthMargin`。
    static func mask(
        quadCorners: [SIMD3<Float>],
        cameraPosition: SIMD3<Float>,
        occluders: WorldScreenOccluders,
        index: WorldScreenOccluderIndex? = nil,
        excluding owner: String? = nil,
        columns: Int = defaultColumns,
        rows: Int = defaultRows,
        depthMargin: Float = depthMargin
    ) -> WorldScreenOcclusionMask {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        guard quadCorners.count == 4 else {
            return .fullyVisible(columns: columns, rows: rows)
        }
        let activeIndex: WorldScreenOccluderIndex?
        if let index {
            activeIndex = index
        } else if occluders.triangles.isEmpty {
            activeIndex = nil
        } else {
            activeIndex = WorldScreenOccluderIndex(
                triangles: occluders.triangles, revision: occluders.revision
            )
        }
        let boxes = occluders.boxes.filter { box in
            guard let owner else { return true }
            return box.owner != owner
        }
        var blocked = [Bool](repeating: false, count: columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let centre = cellCenter(column: column, row: row, columns: columns, rows: rows)
                guard let world = worldPoint(corners: quadCorners, u: centre.x, v: centre.y) else {
                    continue
                }
                let toScreen = world - cameraPosition
                let distance = simd_length(toScreen)
                guard distance > minimumRayLength, distance.isFinite else { continue }
                let direction = toScreen / distance
                var nearest: Float?
                if let hit = activeIndex?.firstHit(
                    origin: cameraPosition, direction: direction, maximumDistance: distance
                ), hit > 0 {
                    nearest = hit
                }
                for box in boxes {
                    guard let hit = boxHit(
                        box, origin: cameraPosition, direction: direction, maximumDistance: nearest ?? distance
                    ), hit > 0 else { continue }
                    if nearest == nil || hit < nearest! { nearest = hit }
                }
                blocked[row * columns + column] = isBlocked(
                    nearestOccluderDistance: nearest,
                    screenDistance: distance,
                    depthMargin: depthMargin
                )
            }
        }
        return WorldScreenOcclusionMask(columns: columns, rows: rows, blocked: blocked)
    }

    /// 一格的判据：这一格到相机之间有没有**更近**的遮挡物。
    ///
    /// **唯一**一处。判据做的注入负对照（"不遮挡"＝恒 false）替换的就是下面那一行。
    static func isBlocked(
        nearestOccluderDistance: Float?,
        screenDistance: Float,
        depthMargin: Float
    ) -> Bool {
        guard let hit = nearestOccluderDistance else { return false }
        return hit > 0 && hit < screenDistance - max(depthMargin, 0)
    }

    /// 射线与一个"只绕 Y 摆放"的盒的**进入**参数。只算在前面进入的（`t > 0`）。
    static func boxHit(
        _ box: WorldScreenBox,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maximumDistance: Float
    ) -> Float? {
        let local = WorldScreenPlacement.worldPosition(
            of: origin - box.center, placedAt: SIMD3<Float>(0, 0, 0), yaw: -box.yaw
        )
        // `worldPosition` 的 yaw 是"物件绕 Y 转 yaw"，所以反向查询要用 -yaw 把射线转回盒坐标系。
        let localDirection = rotated(direction, by: -box.yaw)
        let half = SIMD3<Float>(
            abs(box.halfExtents.x), abs(box.halfExtents.y), abs(box.halfExtents.z)
        )
        var entry: Float = -.greatestFiniteMagnitude
        var exit: Float = .greatestFiniteMagnitude
        for axis in 0 ..< 3 {
            guard half[axis] > 0 else {
                // 退化的薄盒：该轴上"在盒内"才算相交，否则直接不相交。
                if local[axis] < -half[axis] || local[axis] > half[axis] { return nil }
                continue
            }
            guard abs(localDirection[axis]) > 1e-9 else {
                if local[axis] < -half[axis] || local[axis] > half[axis] { return nil }
                continue
            }
            let inverse = 1 / localDirection[axis]
            let near = (-half[axis] - local[axis]) * inverse
            let far = (half[axis] - local[axis]) * inverse
            entry = max(entry, min(near, far))
            exit = min(exit, max(near, far))
        }
        guard exit >= max(entry, 0), entry > 0, entry <= maximumDistance else { return nil }
        return entry
    }

    /// 绕 Y 转 `yaw` 的纯向量旋转（与 `WorldScreenPlacement` 同式，无平移）。
    private static func rotated(_ vector: SIMD3<Float>, by yaw: Float) -> SIMD3<Float> {
        WorldScreenPlacement.worldPosition(of: vector, placedAt: SIMD3<Float>(0, 0, 0), yaw: yaw)
    }
}
