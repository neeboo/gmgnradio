import Foundation

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
        guard capsule.isValid, position.isFinite else {
            return false
        }

        let bottom = position + SIMD3(0, capsule.radius, 0)
        let top = position + SIMD3(0, capsule.height - capsule.radius, 0)
        let radiusSquared = capsule.radius * capsule.radius

        for volume in blockingVolumes {
            guard let box = OrientedBox(volume) else {
                continue
            }
            let localBottom = box.toLocal(bottom)
            let localTop = box.toLocal(top)
            let distanceSquared = segmentAABBDistanceSquared(
                from: localBottom,
                to: localTop,
                halfExtents: box.halfExtents
            )

            // Surface contact is valid occupancy. Penetration is not.
            if distanceSquared < radiusSquared - 0.000001 {
                return false
            }
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
    let inverseRotation: NormalizedQuaternion

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
