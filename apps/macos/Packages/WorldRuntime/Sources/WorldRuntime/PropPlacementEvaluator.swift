import Foundation

/// 物件在地面上的占地矩形：`size.x` 是本地 X 方向尺寸、`size.y` 是本地 Z 方向尺寸（米），
/// `yaw` 只绕 Y 旋转（弧度）。
///
/// **为什么只支持绕 Y**：与 `WorldPropMeshClearance.canPlace` 的限制保持一致 ——
/// 它要求 `abs(q.x) < 0.0001 && abs(q.z) < 0.0001`。轴上倾斜的旋转不在本期范围，
/// 相应地把这套 yaw-only 假设在代码里写清楚，而不是让它悄悄退化成错误的近似。
public struct WorldPlanarFootprint: Equatable, Sendable {
    public let size: SIMD2<Float>
    public let yaw: Float

    /// 单次 footprint 允许覆盖的格子数上限（防御病态输入；超出即视为不成立）。
    public static let maximumColumnCount = 4096
    /// 相切是否算相交的容差：小于这个重叠量按"分开"处理，避免浮点误差制造假重叠。
    static let overlapTolerance: Float = 0.0001

    public init(size: SIMD2<Float>, yaw: Float = 0) {
        self.size = size
        self.yaw = yaw
    }

    public var isValid: Bool {
        size.x.isFinite && size.y.isFinite && size.x > 0 && size.y > 0 && yaw.isFinite
    }

    /// footprint 在 yaw 下的轴对齐包围半径（x / z 方向）。
    public var halfExtents: SIMD2<Float> {
        let cosine = abs(cos(yaw))
        let sine = abs(sin(yaw))
        return SIMD2(
            cosine * size.x / 2 + sine * size.y / 2,
            sine * size.x / 2 + cosine * size.y / 2
        )
    }

    /// 锚定列是 footprint 的**最小角**所在的格子（格子 `i` 覆盖世界区间
    /// `[i * spacing, (i + 1) * spacing]`），这个函数给出 footprint 中心相对该角的世界偏移。
    ///
    /// 用最小角锚定的理由：0.45 m 的物件在 0.25 m 格上正好占 2×2（与设计文档 §5.2 一致），
    /// 且锚定列自身必然被覆盖（"含自身"）。
    public func center(anchoredAt column: PropSupportColumn, spacing: Float) -> SIMD2<Float> {
        let anchor = column.worldPosition(spacing: spacing)
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let localX = size.x / 2
        let localZ = size.y / 2
        // 本地 → 世界：与 `WorldPropMeshClearance.canPlace` 的 local() 互逆。
        return anchor + SIMD2(
            cosine * localX + sine * localZ,
            -sine * localX + cosine * localZ
        )
    }

    /// 该 footprint 锚定在某列时覆盖哪些列（含锚定列自身）。
    ///
    /// 覆盖判据 = 格子方块与旋转后矩形的精确 2D SAT 相交（相切不算）。这样
    /// footprint 跨列时下游可以"整块一起变绿/红"（设计文档 §5.2）。
    public func columns(
        anchoredAt column: PropSupportColumn,
        spacing: Float
    ) -> [PropSupportColumn] {
        guard isValid, spacing.isFinite, spacing > 0 else { return [] }
        let footprintCenter = center(anchoredAt: column, spacing: spacing)
        let half = halfExtents
        guard let xRange = tileIndexRange(
            minimum: footprintCenter.x - half.x,
            maximum: footprintCenter.x + half.x,
            spacing: spacing
        ),
            let zRange = tileIndexRange(
                minimum: footprintCenter.y - half.y,
                maximum: footprintCenter.y + half.y,
                spacing: spacing
            ),
            propSupportColumnCount(xRange) * propSupportColumnCount(zRange)
                <= Double(Self.maximumColumnCount)
        else {
            return []
        }

        let cosine = cos(yaw)
        let sine = sin(yaw)
        // 本地 X / Z 轴在世界 XZ 平面上的方向（与 canPlace 的 local() 约定一致）。
        let firstAxis = SIMD2<Float>(cosine, -sine)
        let secondAxis = SIMD2<Float>(sine, cosine)
        let axes = [firstAxis, secondAxis, SIMD2(1, 0), SIMD2(0, 1)]
        let tileRadiusScale = spacing / 2
        // 投影半径必须用**本地**半尺寸：`halfExtents` 已经是世界轴对齐半径，
        // 只有 yaw = 0 时两者才恰好相等。
        let localHalfX = size.x / 2
        let localHalfZ = size.y / 2

        var result: [PropSupportColumn] = []
        for x in xRange {
            for z in zRange {
                // 格子中心在 (i + 0.5) * spacing：格子 i 覆盖 [i*spacing, (i+1)*spacing]。
                let tileCenter = SIMD2<Float>(
                    (Float(x) + 0.5) * spacing,
                    (Float(z) + 0.5) * spacing
                )
                let offset = tileCenter - footprintCenter
                let separated = axes.contains { axis in
                    let footprintRadius = localHalfX * abs(simd2Dot(firstAxis, axis))
                        + localHalfZ * abs(simd2Dot(secondAxis, axis))
                    let tileRadius = tileRadiusScale
                        * (abs(axis.x) + abs(axis.y))
                    return abs(simd2Dot(offset, axis))
                        >= footprintRadius + tileRadius - Self.overlapTolerance
                }
                if !separated {
                    result.append(PropSupportColumn(x: x, z: z))
                }
            }
        }
        return result
    }
}

/// 放置被拒的原因。带 id 的两个分支是为了给用户可读原因（哪个体积 / 哪件已放物件）。
public enum PropSupportBlockReason: Equatable, Sendable {
    case outsideBounds
    case noSupport
    case blockedByMesh
    case blockedByBlockingVolume(String)
    case blockedByPlacedProp(String)
    case insufficientClearance
}

extension PropSupportBlockReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outsideBounds: "这里超出了可摆放的范围。"
        case .noSupport: "这里没有承托面，或者整块占地的高度不一致。"
        case .blockedByMesh: "这里会插进墙或家具。"
        case let .blockedByBlockingVolume(id): "这里会碰到 \(id)。"
        case let .blockedByPlacedProp(id): "这里会和已经放好的 \(id) 重叠。"
        case .insufficientClearance: "这里空间不够，放不下。"
        }
    }
}

/// 单件物件的放置判定。
///
/// 判定同时覆盖两样东西（设计文档 §6.3）：
/// 1. **网格**：`WorldPropMeshClearance.canPlace`。它只支持 yaw 旋转、允许与承托面接触、
///    拒绝任何穿入物件的三角形。
/// 2. **阻挡体积**：点唱机 / 许愿机 / 展示台是独立的 `WorldCollisionVolume`（`isBlocking: true`），
///    不在 `collider.glb` 里，所以另做盒-盒判定（`WorldPropBoxOverlap`）。同样的辅助用于已放物件的互斥。
///
/// **性能**：`canPlace` 是 O(传入三角形数)，所以这里先用 `triangles(in:)` 按 footprint 的
/// 包围范围取局部三角形再调用，绝不把全量三角形（真实房间 161,600 个）传进去。
/// footprint 跨列时是"整块判定"：每一列都必须有同一层承托面，任一处失败就返回对应原因。
public enum PropPlacementEvaluator {
    /// 同一个 footprint 覆盖的各列，承托高度允许的最大差值（米）。
    /// 超过它说明这块地不平（例如一半在桌面、一半在地面），物件会悬空或陷进去。
    public static let maximumSupportHeightDeviation: Float = 0.02

    /// 局部三角形范围查询的外扩余量（米）：`canPlace` 自己会做精确的 AABB 与 SAT 判定，
    /// 这里只保证"包围盒刚好相切"的三角形不会被漏掉。
    public static let triangleQueryMargin: Float = 0.01

    /// 返回 nil 表示可放。
    ///
    /// 参数里的 `blockingVolumes` / `placedProps` 都按"障碍"处理，本函数**不**再看
    /// `isBlocking`：宁可多挡一件，也不因为元数据不一致漏挡（fail-closed）。
    public static func evaluate(
        footprint: WorldPlanarFootprint,
        height: Float,
        at anchor: PropSupportLayerRef,
        grid: PropSupportGrid,
        collision: any WorldPropSupportQuerying,
        blockingVolumes: [WorldCollisionVolume],
        placedProps: [WorldCollisionVolume]
    ) -> PropSupportBlockReason? {
        guard footprint.isValid,
              height.isFinite, height > 0,
              grid.spacing.isFinite, grid.spacing > 0
        else {
            // 输入不成立时拒绝，而不是当作可放。
            return .insufficientClearance
        }

        let columns = footprint.columns(
            anchoredAt: anchor.column,
            spacing: grid.spacing
        )
        guard !columns.isEmpty else { return .insufficientClearance }

        // 1. 整块占地都要有"同一层"的承托面，且高度一致（§5.2 整块一起变绿/红）。
        for column in columns {
            guard grid.contains(column) else { return .outsideBounds }
            guard let layer = grid.layers(at: column).first(where: {
                $0.layer == anchor.layer.layer
            }),
                abs(layer.supportHeight - anchor.layer.supportHeight)
                    <= maximumSupportHeightDeviation
            else {
                return .noSupport
            }
        }

        let supportHeight = anchor.layer.supportHeight
        let box = placementVolume(
            footprint: footprint,
            height: height,
            at: anchor,
            spacing: grid.spacing
        )

        // 2. 网格判定：只取这个 footprint 附近的局部三角形（空间分桶），
        //    否则 2,000 格 × 161,600 三角形 = 3.2 亿次检测，不可行。
        let queryBounds = WorldPlanarBounds(
            centerX: Float(box.center.x),
            centerZ: Float(box.center.z),
            halfExtentX: footprint.halfExtents.x,
            halfExtentZ: footprint.halfExtents.y
        ).expanded(by: triangleQueryMargin)
        let localTriangles = collision.triangles(in: queryBounds)
        // fail-closed：拿不到几何就不判定为可放（空三角形数组在 canPlace 里等价于"没有碰撞"）。
        // 正常情况下不可能为空：这一列的承托面本身就是从几何里派生出来的。
        guard !localTriangles.isEmpty else { return .noSupport }
        guard WorldPropMeshClearance.canPlace(
            box,
            supportHeight: supportHeight,
            triangles: localTriangles
        ) else {
            return .blockedByMesh
        }

        // 3. 独立阻挡体积（点唱机 / 许愿机 / 展示台）。
        for volume in blockingVolumes where WorldPropBoxOverlap.overlaps(box, volume) {
            return .blockedByBlockingVolume(volume.id)
        }

        // 4. 已放物件的包围盒互斥。
        for placed in placedProps where WorldPropBoxOverlap.overlaps(box, placed) {
            return .blockedByPlacedProp(placed.id)
        }

        return nil
    }

    /// 由 footprint + 高度 + 锚定层构造待检物件体积。
    /// 底部正好贴在承托面上（`canPlace` 允许与承托面接触），公开出来供预览渲染复用。
    public static func placementVolume(
        footprint: WorldPlanarFootprint,
        height: Float,
        at anchor: PropSupportLayerRef,
        spacing: Float
    ) -> WorldCollisionVolume {
        let center = footprint.center(anchoredAt: anchor.column, spacing: spacing)
        let supportHeight = anchor.layer.supportHeight
        return WorldCollisionVolume(
            id: "prop.preview",
            center: WorldVector3(
                x: center.x,
                y: supportHeight + height / 2,
                z: center.y
            ),
            halfExtents: WorldVector3(
                x: footprint.size.x / 2,
                y: height / 2,
                z: footprint.size.y / 2
            ),
            // 与 WorldPropMeshClearance.canPlace 一致：只绕 Y 旋转，x / z 分量为 0。
            rotation: WorldQuaternion(
                x: 0,
                y: sin(footprint.yaw / 2),
                z: 0,
                w: cos(footprint.yaw / 2)
            ),
            isBlocking: true
        )
    }
}

/// yaw-only 的 OBB-OBB 相交判定（分离轴定理）。
///
/// 为什么需要：点唱机 / 许愿机 / 展示台是独立的 `WorldCollisionVolume`，不在 `collider.glb` 里，
/// 网格判定覆盖不到它们；`WorldRuntime` 里原本没有盒-盒判定（App 侧那份是私有实现）。
///
/// 为什么只支持 yaw：与 `WorldPropMeshClearance.canPlace` 的限制保持一致
/// （它要求 `abs(q.x) < 0.0001 && abs(q.z) < 0.0001`）。轴上倾斜的旋转不在本期范围。
/// 遇到非 yaw-only 的输入时退化成保守的世界轴对齐包围盒判定：**只会多判"相交"，不会漏判**，
/// 与整个模块的 fail-closed 方向一致。
public enum WorldPropBoxOverlap {
    public static func overlaps(
        _ first: WorldCollisionVolume,
        _ second: WorldCollisionVolume
    ) -> Bool {
        guard let a = YawOnlyBox(first), let b = YawOnlyBox(second) else {
            // 尺寸非正 / 非有限 / 四元数退化：按"相交"处理，宁可多拒绝也不放行。
            return true
        }

        let vertical = SIMD3<Float>(0, 1, 0)
        if a.isYawOnly, b.isYawOnly {
            let axes = [a.firstAxis, a.secondAxis, b.firstAxis, b.secondAxis, vertical]
            for axis in axes {
                let distance = abs(simd3Dot(b.center - a.center, axis))
                let radiusA = a.projectionRadius(on: axis, vertical: vertical)
                let radiusB = b.projectionRadius(on: axis, vertical: vertical)
                if distance >= radiusA + radiusB - WorldPlanarFootprint.overlapTolerance {
                    return false
                }
            }
            return true
        }

        // 保守退路：世界轴对齐包围盒（OBB 相交必然 AABB 相交，反之不成立 → 只会多挡）。
        for axis in 0 ..< 3 {
            let distance = abs(b.center[axis] - a.center[axis])
            if distance >= a.worldExtents[axis] + b.worldExtents[axis]
                - WorldPlanarFootprint.overlapTolerance {
                return false
            }
        }
        return true
    }
}

private struct YawOnlyBox {
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
    /// 本地 X / Z 轴在世界中的方向。
    let firstAxis: SIMD3<Float>
    let secondAxis: SIMD3<Float>
    /// 世界轴对齐包围半径（非 yaw-only 时使用）。
    let worldExtents: SIMD3<Float>
    let isYawOnly: Bool

    init?(_ volume: WorldCollisionVolume) {
        let center = SIMD3(volume.center.x, volume.center.y, volume.center.z)
        let halfExtents = SIMD3(
            volume.halfExtents.x,
            volume.halfExtents.y,
            volume.halfExtents.z
        )
        let rotation = volume.rotation
        let lengthSquared = rotation.x * rotation.x
            + rotation.y * rotation.y
            + rotation.z * rotation.z
            + rotation.w * rotation.w
        guard center.isFinite, halfExtents.isFinite,
              halfExtents.x > 0, halfExtents.y > 0, halfExtents.z > 0,
              rotation.x.isFinite, rotation.y.isFinite,
              rotation.z.isFinite, rotation.w.isFinite,
              lengthSquared > 0.000001
        else {
            return nil
        }

        let inverseLength = 1 / sqrt(lengthSquared)
        let x = rotation.x * inverseLength
        let y = rotation.y * inverseLength
        let z = rotation.z * inverseLength
        let w = rotation.w * inverseLength

        // 旋转矩阵的三列 = 三个本地轴在世界中的方向。
        let firstColumn = SIMD3(
            1 - 2 * (y * y + z * z),
            2 * (x * y + w * z),
            2 * (x * z - w * y)
        )
        let secondColumn = SIMD3(
            2 * (x * y - w * z),
            1 - 2 * (x * x + z * z),
            2 * (y * z + w * x)
        )
        let thirdColumn = SIMD3(
            2 * (x * z + w * y),
            2 * (y * z - w * x),
            1 - 2 * (x * x + y * y)
        )

        self.center = center
        self.halfExtents = halfExtents
        isYawOnly = abs(x) < 0.0001 && abs(z) < 0.0001
        if isYawOnly {
            // 与 canPlace 提取 yaw 的方式一致：yaw = atan2(2*q.w*q.y, 1 - 2*q.y*q.y)。
            let yaw = atan2(2 * w * y, 1 - 2 * y * y)
            firstAxis = SIMD3(cos(yaw), 0, -sin(yaw))
            secondAxis = SIMD3(sin(yaw), 0, cos(yaw))
        } else {
            firstAxis = firstColumn
            secondAxis = thirdColumn
        }
        worldExtents = SIMD3(
            halfExtents.x * abs(firstColumn.x)
                + halfExtents.y * abs(secondColumn.x)
                + halfExtents.z * abs(thirdColumn.x),
            halfExtents.x * abs(firstColumn.y)
                + halfExtents.y * abs(secondColumn.y)
                + halfExtents.z * abs(thirdColumn.y),
            halfExtents.x * abs(firstColumn.z)
                + halfExtents.y * abs(secondColumn.z)
                + halfExtents.z * abs(thirdColumn.z)
        )
    }

    func projectionRadius(on axis: SIMD3<Float>, vertical: SIMD3<Float>) -> Float {
        halfExtents.x * abs(simd3Dot(firstAxis, axis))
            + halfExtents.y * abs(simd3Dot(vertical, axis))
            + halfExtents.z * abs(simd3Dot(secondAxis, axis))
    }
}

private func tileIndexRange(
    minimum: Float,
    maximum: Float,
    spacing: Float
) -> ClosedRange<Int>? {
    guard minimum.isFinite, maximum.isFinite, spacing.isFinite, spacing > 0 else {
        return nil
    }
    let lower = floor(minimum / spacing)
    let upper = floor(maximum / spacing)
    let limit: Float = 9e15
    guard lower.isFinite, upper.isFinite, lower > -limit, upper < limit, lower <= upper else {
        return nil
    }
    return Int(lower) ... Int(upper)
}

private func simd2Dot(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y
}

private func simd3Dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
