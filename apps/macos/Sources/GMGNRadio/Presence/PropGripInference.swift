import Foundation
import simd
import WorldRuntime

// Grip coordinates always describe source-mesh AABB proportions. Size and orientation
// identify the principal axis, but do not identify which end has a handle. A verified
// GLB's actual section geometry must establish the guard/round-handle/flat-blade
// relationship. Ambiguous elongated meshes require explicit calibration.
// No saved calibration is changed during rendering or inference.

/// Provenance of a proposed grip; unknownHandle is not an automatic hand calibration.
enum PropGripOrigin: String, Equatable, Sendable {
    /// ② 说不清 ⇒ **逐字节**沿用今天的缺省。
    case inheritedDefault = "inherited-default"
    case meshHandleSection = "mesh-handle-section"
    case unknownHandle = "unknown-handle"

    var label: String {
        switch self {
        case .inheritedDefault: return "沿用缺省握点（物件不细长，无需推断）"
        case .meshHandleSection: return "网格截面证据（护手旁的圆柄）"
        case .unknownHandle: return "柄部位置未确认，需要显式标定"
        }
    }
}

/// 一份推断出来的握点。字段与 `WorldPropGripCalibration` 一一对应，只是还缺
/// `avatarAssetID` / `hand` —— 那两样由调用方（`makeGripCalibration`）按当前居民填。
struct PropGripSuggestion: Equatable, Sendable {
    /// 相对**原始网格 AABB** 的比例（0…1，每轴）。与存档里既有标定的语义完全相同。
    let normalizedGrip: WorldVector3
    /// 米。作用在**手骨局部空间**（见 `PropAttachmentMatrix.transform` 的次序说明）。
    let localOffset: WorldVector3
    /// 手骨局部空间的旋转，把摆正后的网格转到"刃沿骨轴"。
    let localRotation: WorldQuaternion
    let origin: PropGripOrigin
    /// 给用户看的一句话。`nil` = 这件事本来就无需说明（物件不细长，沿用的是既有缺省）。
    let notice: String?

    /// 与 `WorldPropGripCalibration.isValid` 同一套边界：比例有限且在 0…1、偏移有限且 |v|≤2、
    /// 旋转是单位四元数。这里是**入库前**的第一次拦截，越界就地报出来而不是等 `hold` 拒绝。
    var isValid: Bool {
        let grip = [normalizedGrip.x, normalizedGrip.y, normalizedGrip.z]
        guard grip.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
        let offset = [localOffset.x, localOffset.y, localOffset.z]
        guard offset.allSatisfy({ $0.isFinite && abs($0) <= 2 }) else { return false }
        let rotation = [localRotation.x, localRotation.y, localRotation.z, localRotation.w]
        guard rotation.allSatisfy(\.isFinite) else { return false }
        let lengthSquared = rotation.reduce(Float.zero) { $0 + $1 * $1 }
        return lengthSquared.isFinite && abs(lengthSquared - 1) <= 0.01
    }
}

/// 「摆正后的世界尺寸 + 摆正旋转 → 握点」的**唯一**一份策略。纯函数、无副作用、可离线逐项断言。
enum PropGripInference {
    /// 掌心挂点局部空间里的柄→剑尖方向。运行时掌心框架的 +Y 是掌面法向，
    /// +X 是腕→中指；这根长轴不表示刀刃侧，也不能独自决定刀刃朝向。
    static let bladeDirectionInHandSpace = SIMD3<Float>(0, 1, 0)

    /// 仅识别细长外形；不能据此认定有柄或确定柄端。
    ///
    /// **刻意复用** `WorldPropSizePolicy.longThinAspectLimit`（= 4）：那个数在仓库里已经是
    /// "多细算细长"的唯一定义（`WorldPropOrientationPolicy.lyingDownAspectLimit` 也引用它）。
    /// 若这里另立一个数，就会出现"尺寸/朝向按细长算、握点却按方算"的自相矛盾。
    /// 真机数据：剑是 1.005 / 0.133 = 7.56（≥ 4，走推断）；咖啡机、斧头这类 ≤ 1.4（走缺省）。
    static let axisAspectLimit: Float = WorldPropSizePolicy.longThinAspectLimit

    static let identityRotation = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)

    /// **今天**的缺省握点，逐字节。只有这一处定义 —— `inheritedDefault` 走的就是它，
    /// 于是"物件不细长"这一条路与改造前**逐位相同**。
    static let inheritedNormalizedGrip = WorldVector3(x: 0.5, y: 0.2, z: 0.5)

    /// 尺寸读不出来时的可见说明。**不许静默变成"随缘握"**。
    static let unreadableSizeNotice = "物件尺寸读不出来，握点沿用缺省（可能握不到东西上，请用握点微调纠正）。"

    /// 推断不合法而退回缺省时的可见说明。
    static let rejectedNotice = "推断出来的握点不合法，已退回缺省握点（请用握点微调纠正）。"

    /// 主入口。
    ///
    /// - Parameters:
    ///   - size: 物件在**摆正之后**的最终世界尺寸（米）—— 就是 `WorldGeneratedProp.effectiveSize`
    ///     这个唯一出口。三轴的**比值**与原始网格 AABB 的比值相同（两者只差一次带符号轴置换），
    ///     所以"最长边 / 次长边"这一步在这里判与在原始网格上判等价。
    ///   - orientation: 资产级摆正旋转（`WorldGeneratedProp.orientationRotation`）。
    ///     缺省 = 单位四元数 ⇒ 与改造前逐字节相同。
    static func suggestion(
        size: WorldVector3,
        orientation: WorldQuaternion = WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        geometry: [WorldTriangle]? = nil
    ) -> PropGripSuggestion {
        let fallback = PropGripSuggestion(
            normalizedGrip: inheritedNormalizedGrip,
            localOffset: WorldVector3(x: 0, y: 0, z: 0),
            localRotation: identityRotation,
            origin: .inheritedDefault,
            notice: nil
        )
        guard let extents = finitePositiveExtents(size) else {
            return replacing(fallback, notice: unreadableSizeNotice)
        }
        // 长轴仅用于寻找柄→尖方向；刀刃侧必须另有实际模型证据。
        let ranked = [0, 1, 2].sorted { extents[$0] > extents[$1] }
        let orientedPrincipalIndex = ranked[0]
        let longest = extents[orientedPrincipalIndex]
        let second = extents[ranked[1]]
        // ② 说不清 ⇒ 逐字节沿用缺省。这一条保证既有物件的手感一个都不动。
        guard second > 0, longest / second >= axisAspectLimit else { return fallback }
        // ① 网格说得清：把"摆正后最长的那根轴"翻回它**原始网格**里的那一根。
        //    `normalizedGrip` 的语义是原始 AABB 的比例，所以这里必须是原始那一根。
        guard let rawPrincipalIndex = rawAxisCarrying(orientedPrincipalIndex, orientation: orientation)
        else { return replacing(fallback, notice: rejectedNotice) }

        guard let geometry, let handle = handleSection(in: geometry, axis: rawPrincipalIndex) else {
            return PropGripSuggestion(normalizedGrip: inheritedNormalizedGrip,
                localOffset: fallback.localOffset, localRotation: identityRotation,
                origin: .unknownHandle,
                notice: "细长外形不能确定柄部位置；需要网格柄部证据或显式握点标定。")
        }
        let components = [handle.grip.x, handle.grip.y, handle.grip.z]
        var rawUnitAxis = SIMD3<Float>(0, 0, 0)
        rawUnitAxis[rawPrincipalIndex] = handle.bladeSign
        let orientedAxis = WorldPropRotation.rotate(rawUnitAxis, by: orientation)
        let normalizedGrip = WorldVector3(x: components[0], y: components[1], z: components[2])
        let localRotation = rotationAligning(orientedAxis, to: bladeDirectionInHandSpace)
        let axisName = ["X", "Y", "Z"][rawPrincipalIndex]
        let suggestion = PropGripSuggestion(
            normalizedGrip: normalizedGrip,
            localOffset: WorldVector3(x: 0, y: 0, z: 0),
            localRotation: localRotation,
            origin: .meshHandleSection,
            notice: String(format: "网格%@轴截面确认护手与连续圆柄，握点比例 %.3f，刃朝柄部反方向。", axisName, components[rawPrincipalIndex])
        )
        // 推断出来的东西自己也得过一遍边界；过不了就**可见地**退回缺省，不许悄悄交一份坏的出去。
        guard suggestion.isValid else { return replacing(fallback, notice: rejectedNotice) }
        return suggestion
    }

    /// 便利入口：直接用世界状态里的那件物件。**没有第二个尺寸来源** —— 读的就是
    /// `effectiveSize` 与 `orientationRotation` 这两个既有出口。
    static func suggestion(for prop: WorldGeneratedProp, geometry: [WorldTriangle]? = nil) -> PropGripSuggestion {
        suggestion(size: prop.effectiveSize, orientation: prop.orientationRotation, geometry: geometry)
    }

    /// Bounded evidence profile for the actual inspected white sword and measured PMX holding pose.
    /// Other assets/avatars have no verified cutting-edge frame; retain their existing calibration.
    /// This computes a new proposal only. Saved user grips are not migrated during rendering.
    static func verifiedForwardFacingSwordRotation(for prop: WorldGeneratedProp, avatarAssetID: String) -> WorldQuaternion? {
        guard prop.assetID == "sha256:e9dda009e47ca4c1ace5e8a6e4ccf18645a109556b4f4772e410815c2be05529",
              avatarAssetID == "pmx.2b-miss-0414-standard" else { return nil }
        // Actual GLB ±Z views and tip-section thickness confirm -Y cutting edge and -X handle→tip.
        // glTFast reflects source X. The persisted quaternion is then reflected through world Z.
        let axis = preparedSourceDirection(SIMD3<Float>(-1, 0, 0), orientation: prop.orientationRotation)
        let edge = preparedSourceDirection(SIMD3<Float>(0, -1, 0), orientation: prop.orientationRotation)
        // Actual hold-display PMX palm frame at t=0, measured in Unity, converted to persisted Z convention.
        let up = SIMD3<Float>(0.3697862, -0.2558435, -0.8931977)
        let forward = SIMD3<Float>(0.8843164, 0.3918314, 0.2538750)
        return rotationAligningFrame(primary: axis, edge: edge, toPrimary: up, toEdge: forward)
    }

    /// Source GLB direction → prepared prop local direction in persisted right-handed coordinates.
    /// Distinct X (glTFast) and Z (WorldCoordinates) reflections must not be conflated.
    static func preparedSourceDirection(_ raw: SIMD3<Float>, orientation: WorldQuaternion) -> SIMD3<Float> {
        WorldPropRotation.rotate(SIMD3<Float>(-raw.x, raw.y, -raw.z), by: orientation)
    }

    /// Source-space triangle intersections, including GLB node transforms. AABB alone cannot name a handle.
    /// Accept only one short round run beside a wide guard, opposite a substantially longer flat blade.
    static func handleSection(in triangles: [WorldTriangle], axis: Int) -> (grip: SIMD3<Float>, bladeSign: Float)? {
        guard (0..<3).contains(axis), !triangles.isEmpty else { return nil }
        let vertices = triangles.flatMap { [$0.first, $0.second, $0.third] }
        guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        var minimum = vertices[0], maximum = vertices[0]
        for vertex in vertices { minimum = simd_min(minimum, vertex); maximum = simd_max(maximum, vertex) }
        let extent = maximum - minimum
        guard extent.x > 0, extent.y > 0, extent.z > 0 else { return nil }
        let transverse = (0..<3).filter { $0 != axis }
        var sections: [(low: SIMD3<Float>, high: SIMD3<Float>)] = []
        let count = 40
        for index in 0..<count {
            let plane = minimum[axis] + extent[axis] * (Float(index) + 0.5) / Float(count)
            var points: [SIMD3<Float>] = []
            for triangle in triangles {
                let corners = [triangle.first, triangle.second, triangle.third]
                for edge in 0..<3 {
                    let a = corners[edge], b = corners[(edge + 1) % 3]
                    let delta = b[axis] - a[axis]
                    guard abs(delta) > 0.0000001 else { continue }
                    let t = (plane - a[axis]) / delta
                    if t >= 0 && t <= 1 { points.append(a + (b - a) * t) }
                }
            }
            guard var low = points.first else { return nil }
            var high = low
            for point in points { low = simd_min(low, point); high = simd_max(high, point) }
            sections.append((low, high))
        }
        func width(_ index: Int) -> Float {
            let s = sections[index]; return max(s.high[transverse[0]] - s.low[transverse[0]], s.high[transverse[1]] - s.low[transverse[1]])
        }
        func ratio(_ index: Int) -> Float {
            let s = sections[index]
            return min(s.high[transverse[0]] - s.low[transverse[0]], s.high[transverse[1]] - s.low[transverse[1]]) / max(width(index), 0.000001)
        }
        guard let guardIndex = (0..<count).max(by: { width($0) < width($1) }),
              guardIndex >= 6, guardIndex < count - 6 else { return nil }
        var candidates: [(grip: SIMD3<Float>, bladeSign: Float)] = []
        for direction in [-1, 1] {
            var run: [Int] = []
            for distance in 1..<count {
                let index = guardIndex + direction * distance
                guard sections.indices.contains(index) else { break }
                let round = ratio(index) >= 0.5 && width(index) < width(guardIndex) * 0.5
                if round { run.append(index) }
                else if !run.isEmpty { break }
                else if distance > 3 { break }
            }
            guard run.count >= 4, run.count <= 13, let first = run.first, let last = run.last else { continue }
            let opposite = (0..<count).filter { direction > 0 ? $0 < guardIndex - 2 : $0 > guardIndex + 2 }
            let flat = opposite.filter { ratio($0) < 0.4 && width($0) < width(guardIndex) * 0.8 }
            guard flat.count >= run.count * 2, flat.count >= 12 else { continue }
            let centerIndex = (first + last) / 2
            let center = (sections[centerIndex].low + sections[centerIndex].high) * 0.5
            let grip = (center - minimum) / extent
            candidates.append((grip, Float(-direction)))
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// 「摆正后第 `orientedIndex` 根轴，是**原始网格**的哪一根」。
    ///
    /// 摆正旋转把原始网格的每一根轴送到某一根世界轴上（带符号），所以反过来问就是：
    /// 哪一根原始轴在经过 `orientation` 之后主要落在 `orientedIndex` 上。
    /// 返回 `nil` = 说不清（旋转退化 / 非有限 / 不是一根轴对一根轴）⇒ 调用方必须当失败处理。
    static func rawAxisCarrying(_ orientedIndex: Int, orientation: WorldQuaternion) -> Int? {
        guard (0..<3).contains(orientedIndex), orientationIsUsable(orientation) else { return nil }
        var best: Int?
        var bestMagnitude: Float = 0
        for rawIndex in 0..<3 {
            var unitAxis = SIMD3<Float>(0, 0, 0)
            unitAxis[rawIndex] = 1
            let magnitude = abs(WorldPropRotation.rotate(unitAxis, by: orientation)[orientedIndex])
            guard magnitude.isFinite else { return nil }
            // 严格大于：一根轴对一根轴的旋转下不会出现并列，所以这个比较是确定性的。
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                best = rawIndex
            }
        }
        // 落在该轴上的分量必须接近 1；否则这份旋转我们不认识，绝不猜一根出来。
        guard let best, bestMagnitude >= 0.999 else { return nil }
        return best
    }

    /// 网格最长轴在**手骨局部空间**里的方向。判据与渲染共用这一个出口：
    /// 它就是"剑尖相对手骨指哪"的那根向量，`PropAttachmentMatrix.transform` 的乘法次序
    /// 保证世界方向 = `手骨世界旋转 · 这个向量`。
    ///
    /// `nil` = 尺寸读不出来（**不是**"方向是零"）。
    static func bladeAxisInHandSpace(
        size: WorldVector3,
        orientation: WorldQuaternion,
        localRotation: WorldQuaternion
    ) -> SIMD3<Float>? {
        guard let extents = finitePositiveExtents(size) else { return nil }
        let orientedPrincipalIndex = [0, 1, 2].max { extents[$0] < extents[$1] } ?? 0
        guard let rawIndex = rawAxisCarrying(orientedPrincipalIndex, orientation: orientation)
        else { return nil }
        var rawUnitAxis = SIMD3<Float>(0, 0, 0)
        rawUnitAxis[rawIndex] = 1
        return WorldPropRotation.rotate(
            WorldPropRotation.rotate(rawUnitAxis, by: orientation), by: localRotation
        )
    }

    /// 把 `from` 转到 `to` 的**最小**旋转。退化输入（零向量 / 非有限 / 已经同向）一律回单位
    /// 四元数：这一份的职责是"给出一个朝向"，不是"替调用方判失败" —— 判失败在
    /// `PropGripSuggestion.isValid` 与 `PropAttachmentError` 那两处。
    static func rotationAligning(_ from: SIMD3<Float>, to: SIMD3<Float>) -> WorldQuaternion {
        let fromLength = simd_length(from)
        let toLength = simd_length(to)
        guard fromLength.isFinite, toLength.isFinite, fromLength > 0.000_001, toLength > 0.000_001
        else { return identityRotation }
        let a = from / fromLength
        let b = to / toLength
        let cosine = simd_dot(a, b)
        guard cosine.isFinite else { return identityRotation }
        if cosine >= 1 - 0.000_001 { return identityRotation }
        if cosine <= -1 + 0.000_001 {
            // 正好反向：转轴不唯一，取一根与 a 垂直的确定性轴（先试 +X，太平行就换 +Y）。
            let seed = abs(a.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let axis = simd_cross(a, seed)
            guard simd_length(axis) > 0.000_001 else { return identityRotation }
            return WorldPropRotation.axisAngle(axis: axis, angle: .pi)
        }
        let axis = simd_cross(a, b)
        guard simd_length(axis) > 0.000_001 else { return identityRotation }
        return WorldPropRotation.axisAngle(axis: axis, angle: acos(max(-1, min(1, cosine))))
    }

    /// 完整双轴标定：先对齐柄轴，再绕柄轴对齐经确认的刃侧，补上单轴旋转缺失的 roll。
    /// 输入与目标必须是同一空间内的正交方向；不接受把刀尖或宽面法线当作刃侧。
    static func rotationAligningFrame(
        primary: SIMD3<Float>, edge: SIMD3<Float>,
        toPrimary targetPrimary: SIMD3<Float>, toEdge targetEdge: SIMD3<Float>
    ) -> WorldQuaternion? {
        func unit(_ value: SIMD3<Float>) -> SIMD3<Float>? {
            let length = simd_length(value)
            guard length.isFinite, length > 0.000001 else { return nil }
            return value / length
        }
        guard let axis = unit(primary), let edge = unit(edge),
              let targetAxis = unit(targetPrimary), let targetEdge = unit(targetEdge),
              abs(simd_dot(axis, edge)) < 0.001,
              abs(simd_dot(targetAxis, targetEdge)) < 0.001 else { return nil }
        let first = rotationAligning(axis, to: targetAxis)
        let alignedEdge = WorldPropRotation.rotate(edge, by: first)
        let angle = atan2(simd_dot(targetAxis, simd_cross(alignedEdge, targetEdge)),
                          simd_dot(alignedEdge, targetEdge))
        let twist = WorldPropRotation.axisAngle(axis: targetAxis, angle: angle)
        let result = WorldPropRotation.multiply(first, twist)
        guard simd_dot(WorldPropRotation.rotate(axis, by: result), targetAxis) > 0.9999,
              simd_dot(WorldPropRotation.rotate(edge, by: result), targetEdge) > 0.9999 else { return nil }
        return result
    }

    /// 同一份缺省，只换那句**可见的**说明。
    private static func replacing(_ suggestion: PropGripSuggestion, notice: String) -> PropGripSuggestion {
        PropGripSuggestion(
            normalizedGrip: suggestion.normalizedGrip,
            localOffset: suggestion.localOffset,
            localRotation: suggestion.localRotation,
            origin: suggestion.origin,
            notice: notice
        )
    }

    /// 三个分量都必须有限且 > 0 —— 与 `WorldPropSizePolicy` / `orientedBounds` 的 fail-closed
    /// 方向一致：读不出来就是读不出来，不许拿 0 当尺寸往下算。
    private static func finitePositiveExtents(_ size: WorldVector3) -> [Float]? {
        let values = [size.x, size.y, size.z]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100 }) else { return nil }
        return values
    }

    private static func orientationIsUsable(_ orientation: WorldQuaternion) -> Bool {
        let values = [orientation.x, orientation.y, orientation.z, orientation.w]
        guard values.allSatisfy(\.isFinite) else { return false }
        let lengthSquared = values.reduce(Float.zero) { $0 + $1 * $1 }
        return lengthSquared.isFinite && lengthSquared > 0.000_001
    }
}
