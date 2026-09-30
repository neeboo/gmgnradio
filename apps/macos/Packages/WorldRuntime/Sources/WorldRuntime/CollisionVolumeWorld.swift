import Foundation

/// 「这个胶囊能不能站在这个落点」——**唯一一份**几何实现。
///
/// 世界上有两个地方要回答"这里有没有东西"，而且**必须给出同一个答案**：
///
/// - `CollisionVolumeWorld.canOccupy`：居民真实移动/站立（`PropLayoutCollisionWorld`
///   的底座就是它），也就是"已摆放的生成物件是不是世界障碍"这条运行时判据；
/// - `WorldPlacementRouteMap.blockedNodes`：摆放时的"摆上去之后居民还走不走得到
///   活动锚点"预检（格子红/黄与落地是否被拒都由它决定）。
///
/// 这两条曾经各有一套几何：运行时用物件的 **yaw OBB**（`generatedCollisionVolume` 的
/// 真实旋转），预检用**未旋转**的半尺寸去扩世界轴的 AABB。真机 2026-09-30 那把
/// yaw=90° 的斧头实测：预检只标了 11 个被占节点，而运行时的真值是 15 个 ——
/// **9 个真被挡的节点没标（fail-open）、5 个没被挡的节点被标（假拒绝）**。
///
/// 所以判据收在这里：两个调用方都只能问 `isClear`，不可能再出现第二套几何。
public enum WorldCapsuleClearance {
    /// 胶囊（底座落在 `position`，竖直向上）与该体积**不相交**时返回 true。
    ///
    /// 表面接触算合法占用（与 `CollisionVolumeWorld` 原来的口径逐字一致）。
    ///
    /// 体积**无法表示**（尺寸非正/非有限、中心或四元数退化）时返回 **false**：
    /// 元数据坏掉的物件不能被静默当成"这里没有东西"（fail-closed）。这条与
    /// `PropPlacementEvaluator` 里"宁可多挡一件，也不因为元数据不一致漏挡"同向。
    public static func isClear(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>,
        of volume: WorldCollisionVolume
    ) -> Bool {
        guard capsule.isValid, position.isFinite else {
            return false
        }
        guard let box = OrientedBox(volume) else {
            return false
        }

        let bottom = position + SIMD3(0, capsule.radius, 0)
        let top = position + SIMD3(0, capsule.height - capsule.radius, 0)
        let localBottom = box.toLocal(bottom)
        let localTop = box.toLocal(top)
        let distanceSquared = segmentAABBDistanceSquared(
            from: localBottom,
            to: localTop,
            halfExtents: box.halfExtents
        )
        return distanceSquared >= capsule.radius * capsule.radius - 0.000001
    }

    /// 体积在世界坐标下的半尺寸（把三个局部半轴旋转到世界后取分量绝对值之和）。
    ///
    /// 供"只扫物件真正覆盖的那几列"使用：调用方的代价因此只随物件自身尺寸增长，
    /// 与房间大小、三角形数量无关。体积无法表示时返回 nil。
    public static func worldHalfExtents(
        of volume: WorldCollisionVolume
    ) -> SIMD3<Float>? {
        guard let box = OrientedBox(volume) else {
            return nil
        }
        let x = box.rotation.rotating(SIMD3(1, 0, 0))
        let y = box.rotation.rotating(SIMD3(0, 1, 0))
        let z = box.rotation.rotating(SIMD3(0, 0, 1))
        let halfExtents = box.halfExtents
        var result = SIMD3<Float>.zero
        for axis in 0 ..< 3 {
            result[axis] = halfExtents.x * abs(x[axis])
                + halfExtents.y * abs(y[axis])
                + halfExtents.z * abs(z[axis])
        }
        return result.isFinite ? result : nil
    }
}

public struct CollisionVolumeWorld: WorldCollisionQuerying {
    private let blockingVolumes: [WorldCollisionVolume]

    public init(volumes: [WorldCollisionVolume]) {
        blockingVolumes = volumes.filter(\.isBlocking)
    }

    public init(manifest: WorldManifest) {
        self.init(volumes: manifest.collisionVolumes)
    }

    public func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool {
        // 判据委托给 `WorldCapsuleClearance`（唯一一份几何）：这里不再各写一遍
        // 距离测试，否则"运行时"与"摆放预检"又会慢慢漂开。
        guard capsule.isValid, position.isFinite else {
            return false
        }
        for volume in blockingVolumes
        where !WorldCapsuleClearance.isClear(capsule, at: position, of: volume) {
            return false
        }
        return true
    }

    public func groundHeight(at position: SIMD3<Float>) -> Float? {
        guard position.isFinite else {
            return nil
        }

        return blockingVolumes.compactMap { volume -> Float? in
            guard let box = OrientedBox(volume) else {
                return nil
            }
            return box.verticalIntersectionHeight(x: position.x, z: position.z)
        }.max()
    }
}

private struct OrientedBox {
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
    /// 世界 → 局部的旋转（用于把胶囊端点搬进盒子坐标系）。
    let inverseRotation: NormalizedQuaternion
    /// 局部 → 世界的旋转（用于把半轴搬进世界坐标算世界包围盒）。
    let rotation: NormalizedQuaternion

    init?(_ volume: WorldCollisionVolume) {
        let center = volume.center.simd3
        let halfExtents = volume.halfExtents.simd3
        guard center.isFinite, halfExtents.isFinite,
              halfExtents.x > 0, halfExtents.y > 0, halfExtents.z > 0,
              let rotation = NormalizedQuaternion(volume.rotation)
        else {
            return nil
        }

        self.center = center
        self.halfExtents = halfExtents
        self.rotation = rotation
        inverseRotation = rotation.conjugate
    }

    func toLocal(_ point: SIMD3<Float>) -> SIMD3<Float> {
        inverseRotation.rotating(point - center)
    }

    func verticalIntersectionHeight(x: Float, z: Float) -> Float? {
        let localOrigin = toLocal(SIMD3(x, 0, z))
        let localDirection = inverseRotation.rotating(SIMD3(0, 1, 0))
        var lower = -Float.infinity
        var upper = Float.infinity

        for axis in 0 ..< 3 {
            let origin = localOrigin[axis]
            let direction = localDirection[axis]
            let extent = halfExtents[axis]

            if abs(direction) < 0.000001 {
                guard origin >= -extent, origin <= extent else {
                    return nil
                }
                continue
            }

            let first = (-extent - origin) / direction
            let second = (extent - origin) / direction
            lower = max(lower, min(first, second))
            upper = min(upper, max(first, second))
            if lower > upper {
                return nil
            }
        }
        return upper.isFinite ? upper : nil
    }
}

private struct NormalizedQuaternion {
    let vector: SIMD3<Float>
    let scalar: Float

    init?(_ value: WorldQuaternion) {
        let lengthSquared = value.x * value.x
            + value.y * value.y
            + value.z * value.z
            + value.w * value.w
        guard lengthSquared.isFinite, lengthSquared > 0.000001 else {
            return nil
        }
        let inverseLength = 1 / sqrt(lengthSquared)
        vector = SIMD3(value.x, value.y, value.z) * inverseLength
        scalar = value.w * inverseLength
    }

    private init(vector: SIMD3<Float>, scalar: Float) {
        self.vector = vector
        self.scalar = scalar
    }

    var conjugate: NormalizedQuaternion {
        NormalizedQuaternion(vector: -vector, scalar: scalar)
    }

    func rotating(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let twiceCross = 2 * cross(vector, value)
        return value + scalar * twiceCross + cross(vector, twiceCross)
    }
}

private func cross(
    _ lhs: SIMD3<Float>,
    _ rhs: SIMD3<Float>
) -> SIMD3<Float> {
    SIMD3(
        lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.z * rhs.x - lhs.x * rhs.z,
        lhs.x * rhs.y - lhs.y * rhs.x
    )
}

private func segmentAABBDistanceSquared(
    from start: SIMD3<Float>,
    to end: SIMD3<Float>,
    halfExtents: SIMD3<Float>
) -> Float {
    let direction = end - start
    var breakpoints: [Float] = [0, 1]

    for axis in 0 ..< 3 where abs(direction[axis]) > 0.000001 {
        let minimumCrossing = (-halfExtents[axis] - start[axis]) / direction[axis]
        let maximumCrossing = (halfExtents[axis] - start[axis]) / direction[axis]
        if minimumCrossing > 0, minimumCrossing < 1 {
            breakpoints.append(minimumCrossing)
        }
        if maximumCrossing > 0, maximumCrossing < 1 {
            breakpoints.append(maximumCrossing)
        }
    }
    breakpoints.sort()

    var minimumDistanceSquared = Float.infinity
    for interval in zip(breakpoints, breakpoints.dropFirst()) {
        let midpoint = (interval.0 + interval.1) / 2
        var quadratic = Float.zero
        var linear = Float.zero

        for axis in 0 ..< 3 {
            let midpointValue = start[axis] + direction[axis] * midpoint
            let boundary: Float?
            if midpointValue < -halfExtents[axis] {
                boundary = -halfExtents[axis]
            } else if midpointValue > halfExtents[axis] {
                boundary = halfExtents[axis]
            } else {
                boundary = nil
            }

            if let boundary {
                let offset = start[axis] - boundary
                quadratic += direction[axis] * direction[axis]
                linear += 2 * offset * direction[axis]
            }
        }

        var candidates = [interval.0, interval.1]
        if quadratic > 0 {
            let optimum = -linear / (2 * quadratic)
            if optimum > interval.0, optimum < interval.1 {
                candidates.append(optimum)
            }
        }

        for parameter in candidates {
            let point = start + direction * parameter
            minimumDistanceSquared = min(
                minimumDistanceSquared,
                pointAABBDistanceSquared(point, halfExtents: halfExtents)
            )
        }
    }
    return minimumDistanceSquared
}

private func pointAABBDistanceSquared(
    _ point: SIMD3<Float>,
    halfExtents: SIMD3<Float>
) -> Float {
    var result = Float.zero
    for axis in 0 ..< 3 {
        let excess = max(abs(point[axis]) - halfExtents[axis], 0)
        result += excess * excess
    }
    return result
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
