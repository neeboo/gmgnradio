import Foundation

/// 摆放派生要求网格几何，但当前碰撞世界给不出三角形时的失败原因。
///
/// 沿用 `ResidentPropPlacementError.environmentNotReady` 的思路：**数据未就绪就拒绝**，
/// 不允许出现"拿不到几何 → 判定为可放"的路径。
public enum WorldPropSupportGeometryError: Error, Equatable, Sendable {
    case geometryUnavailable
}

public final class ReplaceableCollisionWorld: WorldCollisionQuerying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var current: any WorldCollisionQuerying
    private var generation: UInt64 = 0

    /// Changes even when replacement geometry has the same bounds.
    public var revision: UInt64 { lock.withLock { generation } }

    public init(initial: any WorldCollisionQuerying) {
        current = initial
    }

    public func replace(with collisionWorld: any WorldCollisionQuerying) {
        lock.withLock { current = collisionWorld; generation &+= 1 }
    }

    /// 只在内部 world 真的提供三角形几何时交出它，否则返回 nil。
    ///
    /// **为什么不给它加 `WorldPropSupportQuerying` conformance：** 这个类型只承诺
    /// `any WorldCollisionQuerying`，运行期可能装着 `CollisionVolumeWorld`（没有任何三角形）。
    /// 若让它"实现" `triangles(in:)`，最自然的写法就是返回空数组；而空数组在
    /// `WorldPropMeshClearance.canPlace` 里等价于"没有碰撞"，于是拿不到几何会变成"处处可放"
    /// （fail-open），这是危险的。所以我们选择不给它 conformance：调用方必须先拿到非 nil 的
    /// `any WorldPropSupportQuerying` 才能派生格子，拿不到就只能拒绝（fail-closed）。
    public func propSupportQuerying() -> (any WorldPropSupportQuerying)? {
        lock.withLock { current as? any WorldPropSupportQuerying }
    }

    /// 与 `propSupportQuerying()` 相同，但用抛错表达"几何不可用"，方便调用方沿用
    /// `ResidentPropPlacementError.environmentNotReady` 那类"数据未就绪就拒绝"的路径。
    public func requirePropSupportQuerying() throws -> any WorldPropSupportQuerying {
        guard let world = propSupportQuerying() else {
            throw WorldPropSupportGeometryError.geometryUnavailable
        }
        return world
    }

    public func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool {
        lock.withLock { current.canOccupy(capsule, at: position) }
    }

    public func groundHeight(at position: SIMD3<Float>) -> Float? {
        lock.withLock { current.groundHeight(at: position) }
    }

    public func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        lock.withLock {
            current.canTraverse(
                capsule,
                from: start,
                to: destination,
                maximumStepHeight: maximumStepHeight
            )
        }
    }
}
