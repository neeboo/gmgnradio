import Foundation

/// 平面（XZ）范围，单位米，含边界。
///
/// 摆放派生需要"三角形几何"这种比胶囊查询更底层的输入，而范围查询的单位是平面范围：
/// 世界 Y 不参与筛选 —— 同一个 XZ 位置可能在多个高度层（地面 / 桌面 / 台阶）上都有几何。
/// Y 的筛选属于调用方（例如 `WorldPropMeshClearance.canPlace` 自己按承托高度做上下界判断）。
public struct WorldPlanarBounds: Equatable, Sendable {
    public let minimumX: Float
    public let maximumX: Float
    public let minimumZ: Float
    public let maximumZ: Float

    public init(
        minimumX: Float,
        maximumX: Float,
        minimumZ: Float,
        maximumZ: Float
    ) {
        self.minimumX = minimumX
        self.maximumX = maximumX
        self.minimumZ = minimumZ
        self.maximumZ = maximumZ
    }

    /// 由中心与半长构造。摆放判定用：footprint 在 yaw 下的轴对齐包围半径。
    public init(
        centerX: Float,
        centerZ: Float,
        halfExtentX: Float,
        halfExtentZ: Float
    ) {
        self.init(
            minimumX: centerX - halfExtentX,
            maximumX: centerX + halfExtentX,
            minimumZ: centerZ - halfExtentZ,
            maximumZ: centerZ + halfExtentZ
        )
    }

    public var isValid: Bool {
        minimumX.isFinite && maximumX.isFinite
            && minimumZ.isFinite && maximumZ.isFinite
            && minimumX <= maximumX && minimumZ <= maximumZ
    }

    public func contains(x: Float, z: Float) -> Bool {
        guard isValid, x.isFinite, z.isFinite else { return false }
        return x >= minimumX && x <= maximumX && z >= minimumZ && z <= maximumZ
    }

    /// 向外扩张 `margin` 米（负值收缩）。输入不成立时原样返回。
    public func expanded(by margin: Float) -> WorldPlanarBounds {
        guard isValid, margin.isFinite else { return self }
        return WorldPlanarBounds(
            minimumX: minimumX - margin,
            maximumX: maximumX + margin,
            minimumZ: minimumZ - margin,
            maximumZ: maximumZ + margin
        )
    }
}

/// 摆放派生需要三角形几何，而 `WorldCollisionQuerying` 只有胶囊查询。
///
/// 谁实现它：真正持有网格几何的碰撞世界（当前是 `TriangleMeshCollisionWorld`）。
///
/// **谁不实现它，以及为什么**：
/// - `CollisionVolumeWorld` 只有阻挡体积、没有任何三角形，因此**不实现**这个协议。
///   如果让它"实现"并返回空数组，摆放判定会把"没有三角形"读成"没有碰撞"，于是处处可放
///   （fail-open）—— 这正是本项目要避免的方向（`ResidentPropPlacementError.environmentNotReady`
///   就是"数据未就绪就拒绝"的先例）。
/// - `ReplaceableCollisionWorld` 同理不声明 conformance：它在内部 world 不支持时用
///   `propSupportQuerying()` 返回 nil 明确失败。**几何拿不到就拒绝，绝不放行。**
public protocol WorldPropSupportQuerying: WorldCollisionQuerying {
    /// 返回 XZ 包围盒与 `bounds` 相交的全部三角形。
    ///
    /// 调用方可以依赖的语义：
    /// - 只按 XZ 包围盒筛选（含边界，即相切也算相交），不做 Y 筛选。
    /// - **去重**（一个三角形可能落在多个空间哈希 cell 里）并按内部索引**升序**返回，
    ///   保证同一份几何永远给出同一个顺序，从而让判定结果可复现、可逐项比较。
    /// - 不要求覆盖"包围盒相交"之外的三角形；也不允许漏掉任何包围盒相交的三角形。
    /// - `bounds` 不合法时返回空数组。空数组的含义是"这个范围里没有几何"，
    ///   **不是**"这个范围可以放"：调用方必须把它当作失败（见 `WorldPropMeshClearance.canPlace`
    ///   对空三角形数组会直接返回 true）。
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle]
}

extension WorldTriangle {
    /// 顶点包围盒下界。内部使用：范围筛选与列扫描都要用。
    var boundsMinimum: SIMD3<Float> {
        SIMD3(
            Swift.min(first.x, second.x, third.x),
            Swift.min(first.y, second.y, third.y),
            Swift.min(first.z, second.z, third.z)
        )
    }

    /// 顶点包围盒上界。内部使用：列扫描的初始天花板取它。
    var boundsMaximum: SIMD3<Float> {
        SIMD3(
            Swift.max(first.x, second.x, third.x),
            Swift.max(first.y, second.y, third.y),
            Swift.max(first.z, second.z, third.z)
        )
    }

    /// XZ 包围盒是否与平面范围相交（含边界）。
    func intersects(_ bounds: WorldPlanarBounds) -> Bool {
        let minimum = boundsMinimum
        let maximum = boundsMaximum
        return minimum.x <= bounds.maximumX && maximum.x >= bounds.minimumX
            && minimum.z <= bounds.maximumZ && maximum.z >= bounds.minimumZ
    }
}
