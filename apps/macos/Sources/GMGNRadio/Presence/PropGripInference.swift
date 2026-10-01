import Foundation
import simd
import WorldRuntime

// ===========================================================================
// 「攥在哪儿、刃朝哪边」—— 手持握点（grip）的**唯一**一份推断策略
// ===========================================================================
//
// ## 为什么要有这一份
//
// 手持这条链早就通了：`WorldPropGripCalibration`（`WorldPropLayout.swift:167`）是标定本身，
// `.hold` / `.adjustGrip` 是命令，`PropAttachmentMatrix.transform`
// （`PropAttachment.swift:160`）每帧算的就是 `手骨世界变换 × grip`。缺的从来不是绑定，
// 而是**标定从哪来**：`ResidentPropAttachmentEligibility.suggestedCalibration` 今天给
// 所有物件同一个硬编码的 `normalizedGrip (0.5, 0.2, 0.5)` —— 那是"原始 AABB 的中点偏下"。
//
// 对饭盒、咖啡杯这类接近方的东西，中点是对的。对**细长**的东西是错的：真机那把
// 「2B 白色长剑」原始 AABB 是 1.005(X) × 0.133(Y) × 0.057(Z) 米，`x = 0.5` 就是
// **握在剑身正中间**。屏幕上一眼能看出那不是"用手拿"，是"穿在手上"。
//
// ## 输入刻意只有两样，都是世界状态里已有的
//
//   `WorldGeneratedProp.effectiveSize`（摆正**之后**的最终世界尺寸，米）
//   `WorldGeneratedProp.orientationRotation`（资产级摆正旋转）
//
// 不引入任何新的量取：`normalizedGrip` 的语义是"原始网格 AABB 的比例"，而原始 AABB 与
// 摆正后的 AABB 只差一次**带符号的轴置换**，所以"哪根原始轴最长""它最终有多长"这两件事
// 都能从上面两样精确反推出来（见 `rawAxisCarrying(_:orientation:)`）。于是接线处只需要
// 一个 `WorldGeneratedProp`，既不用碰渲染器，也不用把 `worldBounds` 从渲染层搬上来。
//
// ## 判据只有两条，都不许猜
//
//   ① 网格说得清自己是细长的（最长边 / 次长边 ≥ `axisAspectLimit`）⇒ 握点落在**最长轴的一端**，
//      并把刃轴转到手骨骨轴上（`meshPrincipalAxis`）。
//   ② 说不清（接近方/矮的物件）⇒ **逐字节沿用今天的缺省**（`inheritedDefault`）：
//      同一组数字、同一个单位四元数。这一份刻意"不顺手优化"别的物件 —— 既有物件的手感
//      一个都不许因为这次改动而变。
//
// ## 与 `WorldPropOrientationPolicy` 的分工（是两份东西，不是两份朝向）
//
//   `WorldPropOrientationPolicy` 管的是**摆在房间里**的朝向（让躺着生成的网格立起来）；
//   这一套管的是**攥在手里**时刃相对手骨往哪指。两者作用在同一份网格上，所以这里的推导
//   **必须**先过一遍 `orientation` 再谈刃轴 —— 否则会出现"放在地上立着、拿在手里躺着"。
//
//   换算次序与 `PropAttachmentMatrix.transform` 的矩阵乘法次序
//   （`pose * localRotation * scale * anchor * uprightMatrix`）逐项对齐：
//
//     网格顶点 ──[orientation]──► 摆正后的网格 ──[localRotation]──► 手骨局部空间 ──[手骨世界]──► 世界
//
//   于是"网格主轴在**手骨局部空间**里的方向" = `R_localRotation · R_orientation · â`，
//   这一份要做的就是让这个方向等于 `bladeDirectionInHandSpace`。**只有这一处**做这个换算：
//   渲染端读到的永远是同一条 `WorldPropGripCalibration`，不存在第二份刃朝向。
//
// ## ⚠️ 需要在真机上确认的唯一一个假设
//
// `bladeDirectionInHandSpace = (0, 1, 0)` 读作"MMD 骨轴"：PMX 骨骼的局部 +Y 是骨从根到梢的
// 方向，于是 `右手首` 的局部 +Y = 腕→指尖。攥拳握剑时剑身正是沿这条轴出拳（前伸还是上举由
// 动作决定，这一份不碰动画）。**这个假设没有在真机上量过。** 2B 那把 `右手首` 的局部轴若与
// MMD 常规不同，改这一个常量即可，其余判据不受影响。

/// 「这份握点是**怎么来的**」。与 `WorldPropOrientationSource` / `WorldPropSizeProvenance`
/// 同一个手法：面板与回执读它，两态一一对应上面那两条路。
enum PropGripOrigin: String, Equatable, Sendable {
    /// ① 网格自己说得清是细长的 ⇒ 柄端握点 + 刃轴对齐手骨骨轴。
    case meshPrincipalAxis = "mesh-principal-axis"
    /// ② 说不清 ⇒ **逐字节**沿用今天的缺省。
    case inheritedDefault = "inherited-default"

    var label: String {
        switch self {
        case .meshPrincipalAxis: return "按网格主轴推断（握最长轴的一端）"
        case .inheritedDefault: return "沿用缺省握点（物件不细长，无需推断）"
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
    /// 手骨局部空间里"剑尖应该指的方向"。MMD/PMX 骨骼的局部 +Y 是骨从根到梢的方向，
    /// 于是 `右手首` 的局部 +Y = 腕→指尖；攥拳握剑时剑身正沿这条轴出拳。
    ///
    /// **这是本文件唯一一个"没有在真机上量过"的数**。若 2B 的 `右手首` 局部轴与 MMD 常规
    /// 不同，改这一个常量即可，别的判据不会跟着分叉。
    static let bladeDirectionInHandSpace = SIMD3<Float>(0, 1, 0)

    /// 「最长边 / 次长边」到多少才算"这件东西有柄可握"。
    ///
    /// **刻意复用** `WorldPropSizePolicy.longThinAspectLimit`（= 4）：那个数在仓库里已经是
    /// "多细算细长"的唯一定义（`WorldPropOrientationPolicy.lyingDownAspectLimit` 也引用它）。
    /// 若这里另立一个数，就会出现"尺寸/朝向按细长算、握点却按方算"的自相矛盾。
    /// 真机数据：剑是 1.005 / 0.133 = 7.56（≥ 4，走推断）；咖啡机、斧头这类 ≤ 1.4（走缺省）。
    static let axisAspectLimit: Float = WorldPropSizePolicy.longThinAspectLimit

    /// 握点从柄端往里缩多少米。一次攥拳的半个掌宽量级：太小会握在剑首尾端的棱上，
    /// 太大会又滑回剑身中间。
    static let gripInsetMeters: Float = 0.06

    /// 内缩占主轴长度的比例上限。短物件上 `0.06 m` 可能已经过半，必须夹住 ——
    /// 否则"柄端握点"会变成"越过中点的另一端"。
    static let maximumGripInsetRatio: Float = 0.25

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
        orientation: WorldQuaternion = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
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
        // 摆正后的三轴按大到小排：最长的那一根就是"刃"那一根。
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

        var components: [Float] = [0.5, 0.5, 0.5]
        var rawUnitAxis = SIMD3<Float>(0, 0, 0)
        rawUnitAxis[rawPrincipalIndex] = 1
        let orientedAxis = WorldPropRotation.rotate(rawUnitAxis, by: orientation)
        // "哪一端是柄"只有网格主轴能说话，而主轴不带把手标记。取**摆正之后最靠下**的那一端：
        // 生成器交回来的网格是躺在原点上的，摆正后贴地的那一头就是它原来生根的那一头
        // （剑的护手/柄侧）。选错了也不需要重做 —— 用户用 adjustGrip 一次就能翻过来。
        let inset = min(gripInsetMeters / longest, maximumGripInsetRatio)
        let carriesUpward = orientedAxis[orientedPrincipalIndex] >= 0
        components[rawPrincipalIndex] = carriesUpward ? inset : 1 - inset
        let normalizedGrip = WorldVector3(x: components[0], y: components[1], z: components[2])
        let localRotation = rotationAligning(orientedAxis, to: bladeDirectionInHandSpace)
        let axisName = ["X", "Y", "Z"][rawPrincipalIndex]
        let suggestion = PropGripSuggestion(
            normalizedGrip: normalizedGrip,
            localOffset: WorldVector3(x: 0, y: 0, z: 0),
            localRotation: localRotation,
            origin: .meshPrincipalAxis,
            notice: String(
                format: "网格最长边在 %@ 轴（%.3f m，次长 %.3f m，比值 %.2f ≥ %.0f）⇒ 判定为细长物件，"
                    + "握点放在 %@ 轴 %@ 端往里 %.3f m（比例 %.3f），刃轴对齐手骨骨轴。"
                    + "握点与朝向都可用握点微调覆盖。",
                axisName, longest, second, longest / second, axisAspectLimit,
                axisName, carriesUpward ? "最小" : "最大", gripInsetMeters, inset
            )
        )
        // 推断出来的东西自己也得过一遍边界；过不了就**可见地**退回缺省，不许悄悄交一份坏的出去。
        guard suggestion.isValid else { return replacing(fallback, notice: rejectedNotice) }
        return suggestion
    }

    /// 便利入口：直接用世界状态里的那件物件。**没有第二个尺寸来源** —— 读的就是
    /// `effectiveSize` 与 `orientationRotation` 这两个既有出口。
    static func suggestion(for prop: WorldGeneratedProp) -> PropGripSuggestion {
        suggestion(size: prop.effectiveSize, orientation: prop.orientationRotation)
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
