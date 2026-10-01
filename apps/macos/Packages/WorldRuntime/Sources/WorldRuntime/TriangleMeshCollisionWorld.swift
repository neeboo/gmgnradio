import Foundation

public struct WorldTriangle: Equatable, Sendable {
    public let first: SIMD3<Float>
    public let second: SIMD3<Float>
    public let third: SIMD3<Float>

    public init(
        _ first: SIMD3<Float>,
        _ second: SIMD3<Float>,
        _ third: SIMD3<Float>
    ) {
        self.first = first
        self.second = second
        self.third = third
    }
}

public struct TriangleMeshCollisionWorld: WorldCollisionQuerying {
    private struct Cell: Hashable, Sendable {
        let x: Int
        let z: Int
    }

    private let triangles: [WorldTriangle]
    private let cells: [Cell: [Int]]
    private let cellSize: Float

    public init(
        triangles: [WorldTriangle],
        cellSize: Float = 0.25
    ) {
        let resolvedCellSize = cellSize.isFinite && cellSize > 0
            ? cellSize
            : 0.25
        self.cellSize = resolvedCellSize
        self.triangles = triangles.filter(\.isUsable)
        var builtCells: [Cell: [Int]] = [:]
        for (index, triangle) in self.triangles.enumerated() {
            let xRange = cellRange(
                minimum: triangle.minimum.x,
                maximum: triangle.maximum.x,
                cellSize: resolvedCellSize
            )
            let zRange = cellRange(
                minimum: triangle.minimum.z,
                maximum: triangle.maximum.z,
                cellSize: resolvedCellSize
            )
            for x in xRange {
                for z in zRange {
                    builtCells[Cell(x: x, z: z), default: []].append(index)
                }
            }
        }
        cells = builtCells
    }

    public func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool {
        guard capsule.isValid, position.isFinite else { return false }
        let bottom = position + SIMD3(0, capsule.radius, 0)
        let top = position + SIMD3(0, capsule.height - capsule.radius, 0)
        let radiusSquared = capsule.radius * capsule.radius
        let candidates = candidateIndices(
            minimumX: position.x - capsule.radius,
            maximumX: position.x + capsule.radius,
            minimumZ: position.z - capsule.radius,
            maximumZ: position.z + capsule.radius
        )
        for index in candidates {
            let triangle = triangles[index]
            if triangle.isWalkableSurface,
               triangle.maximum.y <= position.y + capsule.radius + 0.01
            {
                continue
            }
            if segmentTriangleDistanceSquared(
                start: bottom,
                end: top,
                triangle: triangle
            ) < radiusSquared - 0.000001 {
                return false
            }
        }
        return true
    }

    public func groundHeight(at position: SIMD3<Float>) -> Float? {
        guard position.isFinite else { return nil }
        return groundHeight(
            at: position,
            maximumAbovePosition: 0.05
        )
    }

    public func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        guard capsule.isValid,
              maximumStepHeight.isFinite, maximumStepHeight >= 0,
              start.isFinite, destination.isFinite,
              let startGround = groundHeight(
                  at: start,
                  maximumAbovePosition: maximumStepHeight
              ),
              let destinationGround = groundHeight(
                  at: destination,
                  maximumAbovePosition: maximumStepHeight
              ),
              abs(destinationGround - startGround) <= maximumStepHeight + 0.0001
        else {
            return false
        }

        let groundedStart = SIMD3(start.x, startGround, start.z)
        guard canOccupy(capsule, at: groundedStart) else { return false }

        let distance = worldDistance(start, destination)
        let rawStepCount = ceil(distance / capsule.radius)
        guard rawStepCount.isFinite, rawStepCount <= Float(Int.max) else {
            return false
        }

        let stepCount = max(1, Int(rawStepCount))
        var previousGround = startGround
        for step in 1 ... stepCount {
            let progress = Float(step) / Float(stepCount)
            let sample = start + (destination - start) * progress
            guard let sampleGround = groundHeight(
                at: sample,
                maximumAbovePosition: maximumStepHeight
            ),
                abs(sampleGround - previousGround) <= maximumStepHeight + 0.0001
            else {
                return false
            }

            let groundedSample = SIMD3(sample.x, sampleGround, sample.z)
            if !canOccupy(capsule, at: groundedSample) {
                let clearanceGround = max(
                    sampleGround,
                    max(startGround, destinationGround)
                )
                let liftedSample = SIMD3(sample.x, clearanceGround, sample.z)
                guard clearanceGround - sampleGround
                    <= maximumStepHeight + 0.0001,
                    canOccupy(capsule, at: liftedSample)
                else {
                    return false
                }
            }
            previousGround = sampleGround
        }
        return true
    }

    private func groundHeight(
        at position: SIMD3<Float>,
        maximumAbovePosition: Float
    ) -> Float? {
        let exactHeights = candidateIndices(
            minimumX: position.x,
            maximumX: position.x,
            minimumZ: position.z,
            maximumZ: position.z
        ).compactMap {
            triangleHeight(triangles[$0], x: position.x, z: position.z)
        }.filter {
            $0 <= position.y + maximumAbovePosition + 0.0001
        }
        if let exact = exactHeights.max() {
            return exact
        }

        // Reconstructed room meshes contain millimetre-scale seams between
        // otherwise continuous floor patches. Resolve the closest walkable
        // edge inside a small tolerance so a capsule does not lose the floor
        // for a single animation frame.
        let seamTolerance: Float = 0.03
        let toleranceSquared = seamTolerance * seamTolerance
        return candidateIndices(
            minimumX: position.x - seamTolerance,
            maximumX: position.x + seamTolerance,
            minimumZ: position.z - seamTolerance,
            maximumZ: position.z + seamTolerance
        ).compactMap { index -> Float? in
            let triangle = triangles[index]
            guard triangle.isWalkableSurface,
                  let edge = nearestProjectedEdge(
                      of: triangle,
                      toX: position.x,
                      z: position.z
                  ),
                  edge.distanceSquared <= toleranceSquared,
                  edge.height <= position.y + maximumAbovePosition + 0.0001
            else {
                return nil
            }
            return edge.height
        }.max()
    }

    private func candidateIndices(
        minimumX: Float,
        maximumX: Float,
        minimumZ: Float,
        maximumZ: Float
    ) -> Set<Int> {
        let xRange = cellRange(
            minimum: minimumX,
            maximum: maximumX,
            cellSize: cellSize
        )
        let zRange = cellRange(
            minimum: minimumZ,
            maximum: maximumZ,
            cellSize: cellSize
        )
        var result: Set<Int> = []
        for x in xRange {
            for z in zRange {
                result.formUnion(cells[Cell(x: x, z: z)] ?? [])
            }
        }
        return result
    }
}

extension TriangleMeshCollisionWorld: WorldPropSupportQuerying {
    /// 按平面范围取局部三角形，复用构造时建立的 0.25 m 空间哈希。
    ///
    /// 为什么必须分桶：`WorldPropMeshClearance.canPlace` 是 O(传入三角形数)，真实房间有
    /// 161,600 个三角形；若每格都传全量就是 3.2 亿次检测。这里的范围查询把单个 footprint
    /// 的输入降到几十个三角形。
    ///
    /// 为什么排序去重：哈希会把同一个三角形写进它 AABB 覆盖的每个 cell，`candidateIndices`
    /// 返回的是 Set（无序且可能重叠）。摆放判定要求"同样几何 → 同样结果"，所以这里
    /// 精确筛选后按内部索引升序输出。
    ///
    /// 为什么还要精确筛选：cell 粒度是 0.25 m，候选集合可能包含 AABB 其实不相交的三角形
    /// （大三角形横跨好几个 cell）。精确筛选保证结果与暴力遍历全量三角形完全一致。
    public func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        guard bounds.isValid else { return [] }
        let candidates = candidateIndices(
            minimumX: bounds.minimumX,
            maximumX: bounds.maximumX,
            minimumZ: bounds.minimumZ,
            maximumZ: bounds.maximumZ
        )
        guard !candidates.isEmpty else { return [] }
        var result: [WorldTriangle] = []
        result.reserveCapacity(candidates.count)
        for index in candidates.sorted() where triangles[index].intersects(bounds) {
            result.append(triangles[index])
        }
        return result
    }
}

private func cellRange(
    minimum: Float,
    maximum: Float,
    cellSize: Float
) -> ClosedRange<Int> {
    Int(floor(minimum / cellSize)) ... Int(floor(maximum / cellSize))
}

private extension WorldTriangle {
    var minimum: SIMD3<Float> {
        SIMD3(
            Swift.min(first.x, second.x, third.x),
            Swift.min(first.y, second.y, third.y),
            Swift.min(first.z, second.z, third.z)
        )
    }

    var maximum: SIMD3<Float> {
        SIMD3(
            Swift.max(first.x, second.x, third.x),
            Swift.max(first.y, second.y, third.y),
            Swift.max(first.z, second.z, third.z)
        )
    }

    var isUsable: Bool {
        first.isFinite && second.isFinite && third.isFinite
            && squaredLength(cross(second - first, third - first)) > 0.00000001
    }

    var isWalkableSurface: Bool {
        let normal = cross(second - first, third - first)
        let lengthSquared = squaredLength(normal)
        return lengthSquared > 0.00000001
            && normal.y * normal.y >= lengthSquared * 0.5
    }
}

private func triangleHeight(
    _ triangle: WorldTriangle,
    x: Float,
    z: Float
) -> Float? {
    let a = triangle.first
    let b = triangle.second
    let c = triangle.third
    let denominator = (b.z - c.z) * (a.x - c.x)
        + (c.x - b.x) * (a.z - c.z)
    guard abs(denominator) > 0.000001 else { return nil }
    let firstWeight = ((b.z - c.z) * (x - c.x)
        + (c.x - b.x) * (z - c.z)) / denominator
    let secondWeight = ((c.z - a.z) * (x - c.x)
        + (a.x - c.x) * (z - c.z)) / denominator
    let thirdWeight = 1 - firstWeight - secondWeight
    let tolerance: Float = -0.00001
    guard firstWeight >= tolerance,
          secondWeight >= tolerance,
          thirdWeight >= tolerance
    else {
        return nil
    }
    return firstWeight * a.y + secondWeight * b.y + thirdWeight * c.y
}

private func nearestProjectedEdge(
    of triangle: WorldTriangle,
    toX x: Float,
    z: Float
) -> (distanceSquared: Float, height: Float)? {
    let point = SIMD2<Float>(x, z)
    let vertices = [triangle.first, triangle.second, triangle.third]
    var result: (distanceSquared: Float, height: Float)?
    for index in vertices.indices {
        let first = vertices[index]
        let second = vertices[(index + 1) % vertices.count]
        let start = SIMD2<Float>(first.x, first.z)
        let delta = SIMD2<Float>(second.x - first.x, second.z - first.z)
        let lengthSquared = delta.x * delta.x + delta.y * delta.y
        guard lengthSquared > 0.00000001 else { continue }
        let offset = point - start
        let progress = min(
            max((offset.x * delta.x + offset.y * delta.y) / lengthSquared, 0),
            1
        )
        let closest = start + delta * progress
        let distance = point - closest
        let candidate = (
            distanceSquared: distance.x * distance.x + distance.y * distance.y,
            height: first.y + (second.y - first.y) * progress
        )
        if result == nil || candidate.distanceSquared < result!.distanceSquared {
            result = candidate
        }
    }
    return result
}

/// 「线段到三角形的最短距离²」——**唯一一份**实现。
///
/// 三个调用方共用它：房间网格的 `TriangleMeshCollisionWorld.canOccupy`（胶囊 × 房间）、
/// 生成物件的 `WorldCapsuleClearance.isClear(_:at:of: WorldPropProxyObstacleMesh)`
/// （胶囊 × 碰撞代理）。刻意**不做**成 `private`：代理碰撞若另写一份距离函数，
/// 那就是"第二套几何"，正是这个项目反复踩的坑。
func segmentTriangleDistanceSquared(
    start: SIMD3<Float>,
    end: SIMD3<Float>,
    triangle: WorldTriangle
) -> Float {
    if segmentIntersectsTriangle(start: start, end: end, triangle: triangle) {
        return 0
    }
    return min(
        pointTriangleDistanceSquared(start, triangle: triangle),
        pointTriangleDistanceSquared(end, triangle: triangle),
        segmentSegmentDistanceSquared(start, end, triangle.first, triangle.second),
        segmentSegmentDistanceSquared(start, end, triangle.second, triangle.third),
        segmentSegmentDistanceSquared(start, end, triangle.third, triangle.first)
    )
}

private func segmentIntersectsTriangle(
    start: SIMD3<Float>,
    end: SIMD3<Float>,
    triangle: WorldTriangle
) -> Bool {
    let direction = end - start
    let edge1 = triangle.second - triangle.first
    let edge2 = triangle.third - triangle.first
    let p = cross(direction, edge2)
    let determinant = dot(edge1, p)
    guard abs(determinant) > 0.000001 else { return false }
    let inverse = 1 / determinant
    let t = start - triangle.first
    let u = dot(t, p) * inverse
    guard u >= 0, u <= 1 else { return false }
    let q = cross(t, edge1)
    let v = dot(direction, q) * inverse
    guard v >= 0, u + v <= 1 else { return false }
    let distance = dot(edge2, q) * inverse
    return distance >= 0 && distance <= 1
}

private func pointTriangleDistanceSquared(
    _ point: SIMD3<Float>,
    triangle: WorldTriangle
) -> Float {
    let a = triangle.first
    let b = triangle.second
    let c = triangle.third
    let ab = b - a
    let ac = c - a
    let ap = point - a
    let d1 = dot(ab, ap)
    let d2 = dot(ac, ap)
    if d1 <= 0, d2 <= 0 { return squaredLength(ap) }

    let bp = point - b
    let d3 = dot(ab, bp)
    let d4 = dot(ac, bp)
    if d3 >= 0, d4 <= d3 { return squaredLength(bp) }

    let vc = d1 * d4 - d3 * d2
    if vc <= 0, d1 >= 0, d3 <= 0 {
        let v = d1 / (d1 - d3)
        return squaredLength(point - (a + v * ab))
    }

    let cp = point - c
    let d5 = dot(ab, cp)
    let d6 = dot(ac, cp)
    if d6 >= 0, d5 <= d6 { return squaredLength(cp) }

    let vb = d5 * d2 - d1 * d6
    if vb <= 0, d2 >= 0, d6 <= 0 {
        let w = d2 / (d2 - d6)
        return squaredLength(point - (a + w * ac))
    }

    let va = d3 * d6 - d5 * d4
    if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
        let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return squaredLength(point - (b + w * (c - b)))
    }

    let denominator = 1 / (va + vb + vc)
    let v = vb * denominator
    let w = vc * denominator
    return squaredLength(point - (a + ab * v + ac * w))
}

private func segmentSegmentDistanceSquared(
    _ firstStart: SIMD3<Float>,
    _ firstEnd: SIMD3<Float>,
    _ secondStart: SIMD3<Float>,
    _ secondEnd: SIMD3<Float>
) -> Float {
    let d1 = firstEnd - firstStart
    let d2 = secondEnd - secondStart
    let r = firstStart - secondStart
    let a = dot(d1, d1)
    let e = dot(d2, d2)
    let epsilon: Float = 0.000001
    var firstParameter: Float = 0
    var secondParameter: Float = 0

    if a <= epsilon, e <= epsilon {
        return squaredLength(firstStart - secondStart)
    } else if a <= epsilon {
        secondParameter = clamp(dot(d2, r) / e, 0, 1)
    } else {
        let c = dot(d1, r)
        if e <= epsilon {
            firstParameter = clamp(-c / a, 0, 1)
        } else {
            let b = dot(d1, d2)
            let denominator = a * e - b * b
            if abs(denominator) > epsilon {
                firstParameter = clamp((b * dot(d2, r) - c * e) / denominator, 0, 1)
            }
            secondParameter = (b * firstParameter + dot(d2, r)) / e
            if secondParameter < 0 {
                secondParameter = 0
                firstParameter = clamp(-c / a, 0, 1)
            } else if secondParameter > 1 {
                secondParameter = 1
                firstParameter = clamp((b - c) / a, 0, 1)
            }
        }
    }

    let firstPoint = firstStart + d1 * firstParameter
    let secondPoint = secondStart + d2 * secondParameter
    return squaredLength(firstPoint - secondPoint)
}

private func cross(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(
        lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.z * rhs.x - lhs.x * rhs.z,
        lhs.x * rhs.y - lhs.y * rhs.x
    )
}

private func dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private func squaredLength(_ value: SIMD3<Float>) -> Float { dot(value, value) }
private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
