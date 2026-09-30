import Foundation

/// 摆放之后**居民还走不走得到他要去的地方**。
///
/// ## 这条判据在保护什么
///
/// 居民的一切移动都由 `WaypointNavigationGraph` 规划（`WorldAgentContext.planRoute` /
/// `move` / `startActivity`）。导航图是**烘焙产物**：它不会因为用户放了一件家具就重建。
/// 运行时唯一的重规划能力是"把受阻的有向边记下来改道"（惰性重规划，见
/// `WorldNavigationRouting.route(from:to:canTraverse:)`）。所以：
///
/// - 家具压住**中间路点**：导航图把那条边当作不可走，路由器改道 —— 只要图还连通就不致命。
///   这正是"真实的房间装修允许你在走道上放东西，居民绕过去"。
/// - 家具切断**唯一通路**（门口/独木桥）：目标锚点整块不可达，居民永远去不了那里，
///   那次活动会变成永久失败。**这一条必须拒绝。**
///
/// 旧判据要求"643 个路点 + 2354 条路线的 0.1 m 采样全部可容纳"，把第一条也当成致命错误，
/// 于是真机舱体上**地板一格都放不下**：实测评估器判可放的 132 个地面格里 100% 被路点否掉，
/// 存档里 9 条摆放回执全部落在展示台台面、地面层一条都没有。这里把判据收窄到**第二条**：
/// 把物件摆上去，真去走一遍，看还到不到得了每个活动锚点。
///
/// ## 为什么用格子图，而不是调用真路由器
///
/// 真路由器每问一条边就要跑一次网格 `canTraverse`（真实舱体实测中位 2.5 **秒**/边，
/// 161,600 个三角形；旧判据一次摆放判定实测中位 10–16 **秒**）—— 鼠标一动就跑不可能，
/// 也没法用来给格子上色。
/// 而"哪里能站"这件事**已经**在 `PropSupportGrid` 里派生好了：它就是几何本身，
/// 也是摆放判定用的同一份几何。于是把同一张格子当成移动图：
///
/// - **节点** = 一列里落在可站带内最高的承托层（`standable`）；没有承托层就站不住。
/// - **边** = 8 邻域，两端都能站、高差不超过 `maximumStepHeight`。
///
/// 可达性判定于是退化成一次 BFS，**每个节点 O(1)**（承托高度查表），完全不碰三角形网格。
/// 判据仍然是 fail-closed：模型说站不住/过不去就不放行；"模型说可以"只是**不否决** ——
/// 真正的落地由同一条服务校验回答，运行时还有惰性重规划兜底。
///
/// ## 与"完全不检查路点"的区别（为什么不做那件更激进的事）
///
/// 完全不检查 = 允许把门口堵死。那样居民会永久卡在"去不了"的活动上，而用户没有任何提示：
/// 他看到的仍然是一格绿。这里保留的正是那条**真实会坏掉**的约束，只是不再保护
/// "每一个中间路点都必须空着"。
public enum WorldPlacementRouteDecision: Equatable, Sendable {
    /// 导航不受影响，或收窄后的判据允许。
    case allowed
    /// 这个物件会占掉一个**活动锚点**：居民没有地方站，那次活动没法进行。
    case blockedAnchor(String)
    /// 这个物件会把某个活动锚点**彻底隔开**：从居民当前位置再也走不到。
    case blockedRoute(String)
    /// 判据本身的输入不成立（拿不到格子 / 锚点落地找不到承托层）：一律拒绝（fail-closed）。
    case unavailable
}

/// 移动图：一列一节点，值是该列可站立的承托高度（`nil` = 站不住）。
///
/// **建一次就够**：拓扑只依赖派生出的承托网格与可站带，与已放物件无关。
public struct WorldPlacementRouteMap: Sendable {
    /// 移动图的一格边长（米）。**等于**派生承托网格的间距：节点就是承托格子本身。
    public let spacing: Float
    /// 行走胶囊半径（米）。物件向外扩张这么多才算"站不上去"。
    ///
    /// 默认 0.25 比居民真正的胶囊（0.2）**更大** —— 这是摆放预检有意的保守余量
    /// （fail-closed 方向）。但**几何模型只有一份**：被占节点由
    /// `WorldCapsuleClearance` 用这个胶囊对物件的真实 OBB 判定，调用方不另算几何。
    public let capsuleRadius: Float
    /// 行走胶囊高度（米），与居民真正的胶囊同高。
    public let capsuleHeight: Float
    /// 用于"这根节点站不站得住"的站姿胶囊。
    public var capsule: WorldCapsule {
        WorldCapsule(radius: capsuleRadius, height: capsuleHeight)
    }
    /// 相邻两格之间允许的高差（= 角色控制器的 `maximumStepHeight`）。
    public let maximumStepHeight: Float
    public let lowerHeight: Float
    public let upperHeight: Float
    private let standable: [PropSupportColumn: Float]
    private let nodes: [PropSupportColumn: Int]
    private let columnStride: Int
    private let columnOriginX: Int
    private let columnOriginZ: Int
    /// 可站格数（诊断用）。
    public var standableNodeCount: Int { standable.count }

    /// 从派生好的承托网格建移动图。
    ///
    /// - `lowerHeight`/`upperHeight` 之外的承托层不参与居民移动（桌面、屋顶、家具顶面）。
    /// - 同一列有多层时取**带内最高的那一层**：桌子底下的地面仍然可以走（桌子由物件的
    ///   阻挡体积表达），而桌面本身在带外，不参与。
    public init(
        grid: PropSupportGrid,
        lowerHeight: Float,
        upperHeight: Float,
        maximumStepHeight: Float = 0.25,
        capsuleRadius: Float = 0.25,
        capsuleHeight: Float = 1.8
    ) {
        self.spacing = grid.spacing
        self.lowerHeight = lowerHeight
        self.upperHeight = upperHeight
        self.maximumStepHeight = maximumStepHeight
        self.capsuleRadius = capsuleRadius
        self.capsuleHeight = capsuleHeight
        var heights: [PropSupportColumn: Float] = [:]
        heights.reserveCapacity(grid.layers.count)
        var minimumX = Int.max, maximumX = Int.min
        var minimumZ = Int.max, maximumZ = Int.min
        for layer in grid.layers {
            guard layer.supportHeight >= lowerHeight - 0.0001,
                  layer.supportHeight <= upperHeight + 0.0001 else { continue }
            minimumX = min(minimumX, layer.column.x); maximumX = max(maximumX, layer.column.x)
            minimumZ = min(minimumZ, layer.column.z); maximumZ = max(maximumZ, layer.column.z)
            if let existing = heights[layer.column] {
                if layer.supportHeight > existing { heights[layer.column] = layer.supportHeight }
            } else {
                heights[layer.column] = layer.supportHeight
            }
        }
        standable = heights
        guard !heights.isEmpty, minimumX <= maximumX, minimumZ <= maximumZ else {
            columnOriginX = 0; columnOriginZ = 0; columnStride = 0; nodes = [:]
            return
        }
        columnOriginX = minimumX
        columnOriginZ = minimumZ
        columnStride = maximumX - minimumX + 1
        var indexed: [PropSupportColumn: Int] = [:]
        indexed.reserveCapacity(heights.count)
        for column in heights.keys {
            indexed[column] = (column.z - minimumZ) * columnStride + (column.x - minimumX)
        }
        nodes = indexed
    }

    /// 这根承托高度/位置能不能站人（诊断与测试用）。
    public func supportHeight(at column: PropSupportColumn) -> Float? { standable[column] }

    /// 物件占据的移动图节点。
    ///
    /// **与运行时同一个判据**：把**同一个** `WorldCollisionVolume`（摆放服务手里那份
    /// `generatedCollisionVolume` / 候选的 `placementVolume`）交给
    /// `WorldCapsuleClearance.isClear`，问"站姿胶囊能不能站在这根节点上"。
    ///
    /// 为什么必须共用：这条判据决定"摆上去之后居民还走不走得到活动锚点"，而运行时
    /// 真正拦人的是 `CollisionVolumeWorld.canOccupy`。两边各写一套几何就会漂开 ——
    /// 真机 2026-09-30 的斧头（yaw=90°）实测：旧实现（未旋转的半尺寸去扩世界轴 AABB）
    /// 只标了 11 个被占节点，而运行时真值是 15 个（9 个漏挡、5 个假挡）。
    ///
    /// 代价：只扫物件**自己**的世界包围盒覆盖的那几列（`worldHalfExtents`），每列 O(1)
    /// 的胶囊×OBB 测试。与房间大小、三角形数、路网规模都无关；不碰三角形网格。
    ///
    /// 体积无法表示时返回**空集**是调用方不能接受的静默放行 —— 所以调用方
    /// （`ResidentPropPlacementService`）必须先通过 `WorldLayoutObstacles.resolve`
    /// 拿到"全部解得出体积的物件"，解不出的那些在这里根本到不了（详见那里的说明）。
    public func blockedNodes(
        volume: WorldCollisionVolume,
        capsule: WorldCapsule? = nil
    ) -> Set<Int> {
        let capsule = capsule ?? self.capsule
        guard capsule.isValid,
              spacing.isFinite, spacing > 0, columnStride > 0, !standable.isEmpty,
              let halfExtents = WorldCapsuleClearance.worldHalfExtents(of: volume)
        else { return [] }
        let center = SIMD3(volume.center.x, volume.center.y, volume.center.z)
        // 只扫物件世界包围盒**外扩站姿胶囊**之后覆盖的那几列：代价随物件尺寸与胶囊半径
        // 有界，且一定是"可能被判阻挡"的节点的超集（|格心-中心| > 半尺寸+半径 时胶囊
        // 绝不可能碰到盒子）。
        let reachX = halfExtents.x + capsule.radius
        let reachZ = halfExtents.z + capsule.radius
        let xRange = Int(floor((center.x - reachX) / spacing))
            ... Int(floor((center.x + reachX) / spacing))
        let zRange = Int(floor((center.z - reachZ) / spacing))
            ... Int(floor((center.z + reachZ) / spacing))
        var result: Set<Int> = []
        for x in xRange {
            for z in zRange {
                let column = PropSupportColumn(x: x, z: z)
                guard let layerHeight = standable[column], let node = nodes[column] else { continue }
                let cx = (Float(x) + 0.5) * spacing
                let cz = (Float(z) + 0.5) * spacing
                // 节点上的居民站在它自己的承托高度上（与运行时 `groundedDestination` 同形）。
                guard !WorldCapsuleClearance.isClear(
                    capsule, at: SIMD3(cx, layerHeight, cz), of: volume
                ) else { continue }
                result.insert(node)
            }
        }
        return result
    }

    /// 收窄后的判据：**从居民当前位置出发，还能走到每一个活动锚点吗**。
    ///
    /// - `blockedNodes`：这次摆放新增的障碍节点（`blockedNodes(volume:...)`，判据与运行时同一份）。
    ///   调用方把**已放物件**的障碍节点并进来时，判据就同时覆盖了"这间房现在的样子"。
    /// - `anchorPositions`：锚点 id → 落点（世界坐标）。
    public func decision(
        blockedNodes occupied: Set<Int>,
        anchorIDs: [String],
        anchorPositions: [String: WorldVector3],
        residentPosition: WorldVector3
    ) -> WorldPlacementRouteDecision {
        guard spacing.isFinite, spacing > 0, columnStride > 0,
              !standable.isEmpty, !anchorIDs.isEmpty else {
            return .unavailable
        }
        var goals: [Int] = []
        for id in anchorIDs {
            guard let position = anchorPositions[id],
                  let node = node(at: position) else {
                return .unavailable
            }
            // 锚点被占 = 居民没有地方站，那次活动直接没法进行。
            if occupied.contains(node) { return .blockedAnchor(id) }
            goals.append(node)
        }
        guard let start = nearestNode(to: residentPosition) else { return .unavailable }
        for (index, goal) in goals.enumerated()
        where !reachable(from: start, to: goal, occupied: occupied) {
            return .blockedRoute(anchorIDs[index])
        }
        return .allowed
    }

    /// 锚点落点 → 移动图节点。落点必须真的落在一层承托面上（容差 0.35 m，覆盖
    /// 生成网格的地面起伏），否则判据输入不成立。
    public func node(at position: WorldVector3) -> Int? {
        guard spacing.isFinite, spacing > 0 else { return nil }
        let column = PropSupportColumn(
            x: Int(floor(position.x / spacing)),
            z: Int(floor(position.z / spacing))
        )
        guard let height = standable[column], let node = nodes[column] else { return nil }
        guard abs(height - position.y) <= 0.35 else { return nil }
        return node
    }

    /// 居民当前位置 → 最近的能站节点（居民脚下的那一格）。
    public func nearestNode(to position: WorldVector3, radius: Int = 2) -> Int? {
        if let exact = node(at: position) { return exact }
        guard spacing.isFinite, spacing > 0 else { return nil }
        let baseX = Int(floor(position.x / spacing))
        let baseZ = Int(floor(position.z / spacing))
        var best: (distance: Float, node: Int)?
        for dx in -radius...radius {
            for dz in -radius...radius {
                let column = PropSupportColumn(x: baseX + dx, z: baseZ + dz)
                guard let height = standable[column], let node = nodes[column] else { continue }
                guard abs(height - position.y) <= 0.6 else { continue }
                let x = (Float(column.x) + 0.5) * spacing - position.x
                let z = (Float(column.z) + 0.5) * spacing - position.z
                let distance = x * x + z * z
                if best == nil || distance < best!.distance { best = (distance, node) }
            }
        }
        return best?.node
    }

    private func reachable(from start: Int, to goal: Int, occupied: Set<Int>) -> Bool {
        guard start != goal else { return true }
        guard !occupied.contains(start) else { return false }
        var seen: Set<Int> = [start]
        var queue: [Int] = [start]
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let x = current % columnStride + columnOriginX
            let z = current / columnStride + columnOriginZ
            guard let currentHeight = standable[PropSupportColumn(x: x, z: z)] else { continue }
            for dx in -1...1 {
                for dz in -1...1 where !(dx == 0 && dz == 0) {
                    let next = PropSupportColumn(x: x + dx, z: z + dz)
                    guard let nextHeight = standable[next], let node = nodes[next] else { continue }
                    guard !seen.contains(node), !occupied.contains(node) else { continue }
                    guard abs(nextHeight - currentHeight) <= maximumStepHeight + 0.0001 else { continue }
                    if node == goal { return true }
                    seen.insert(node)
                    queue.append(node)
                }
            }
        }
        return false
    }
}
