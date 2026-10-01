import Foundation

/// 「用户说的那个尺寸指的是**哪根轴**」——提交契约（`size_intent.axis`）与世界尺度策略
/// 共用这**一份**词汇（`longest` / `height` 就是线上字面量，`WorldPropSizeIntent` 直接解码它）。
public enum WorldPropSizeAxis: String, Codable, Equatable, Sendable {
    /// 最长边（"一把 1.1 米的剑"：剑横着，那 1.1 米说的是它有多长）。
    case longest
    /// 高度（"高 35 厘米的咖啡机"：立着的物件，高度就是它的大小）。
    case height
}

/// 提交时声明的尺寸意图（守护进程契约里的 `size_intent`，app 侧镜像）。
///
/// 它随产物一起存进世界状态，回答两个问题：这件物件的尺寸**是按谁的话定的**，
/// 以及"用户手动覆盖 > 尺寸意图 > 工作流权威尺寸 > 自动推断"这条优先级里它排第几。
/// 缺失时合成 Codable 不编码这个键 —— 没有意图的产物其元数据与改造前逐字节相同。
public struct WorldPropSizeIntent: Codable, Equatable, Sendable {
    /// 谁说的这个尺寸。`default` 在 Swift 里是关键字，所以 case 名与线上字面量分开写
    /// （`rawValue` 才是契约，与 `PropGenerationState.waitingResources` 同一手法）。
    public enum Source: String, Codable, Equatable, Sendable {
        case user
        case suggested
        case fallback = "default"
    }

    public let axis: WorldPropSizeAxis
    public let meters: Float
    public let source: Source

    public init(axis: WorldPropSizeAxis, meters: Float, source: Source) {
        self.axis = axis; self.meters = meters; self.source = source
    }

    /// 由提交契约的**原始字面量**构造。轴名或出处越界 ⇒ nil（不静默、也不替调用方
    /// 编一个出处）。存在的意义就是"契约里那五个字面量只有这一份解释"。
    public init?(axis: String, meters: Double, source: String) {
        guard let axis = WorldPropSizeAxis(rawValue: axis),
              let source = Source(rawValue: source),
              meters.isFinite, meters > 0, meters <= 100 else { return nil }
        self.init(axis: axis, meters: Float(meters), source: source)
    }

    public var isValid: Bool { meters.isFinite && meters > 0 && meters <= 100 }

    /// 契约那边的同一个三元组（审计 / 提示词回读用）。
    public var wire: (axis: String, meters: Double, source: String) {
        (axis.rawValue, Double(meters), source.rawValue)
    }

    /// 一句话说明"这个尺寸是谁、按哪根轴说的"，给面板与工具回执用。
    public var summary: String {
        let who = switch source {
        case .user: "用户指定"
        case .suggested: "服务建议"
        case .fallback: "默认值"
        }
        let axisText = axis == .longest ? "最长边" : "高度"
        return "\(who)的\(axisText) \(String(format: "%.2f", meters)) 米"
    }
}

/// 「生成请求的目标尺寸 → 世界里真实尺寸」的**唯一**一份策略。
///
/// 为什么需要它（真机 2026-10-01 的「2B 白色长剑（外形摆件）」）：
/// 这一步以前是**只按高度轴**归一（`scale = 请求高度 / (max.y - min.y)`），而生成服务
/// 交回来的网格**不保证立着**。那把剑的网格实测是 1.005 × 0.133 × 0.057 m
/// （长 × 高 × 厚；服务回执 `inspection.bounds.dimensions` 与 GLB 字节级重算完全一致），
/// 请求高度 1.1 m ⇒ scale = 1.1 / 0.133493 = 8.2401 ⇒ 场景里 **8.2848 m 长**。
/// 舱室只有 7 × 8 × 3.2 m —— 剑比房间还长，横跨整个舱室，同一个尺寸下**没有任何落点**
/// 能过摆放判定（"太大了控不了"与"领取后从房间里消失"是同一个根因的两面）。
///
/// 规则只有一条，而且**只在"请求高度"进入系统的那一处**应用（生成入库与托盘展示）：
///
/// - `最长边 / 高度 ≤ longThinAspectLimit`：这件东西的"高度"就是它的大小 ⇒ 与旧行为
///   **逐位相同**（咖啡机 1.348、斧头 1.265 都落在这里 ⇒ 已摆好的两件尺寸一个数字都不变）；
/// - 否则它是一件**细长物件**（剑、扫帚、滑雪板）：高度轴不是它的大小 ⇒ 改按**最长边**归一，
///   渲染后的最长边 = 请求高度，且**横纵比不失真**（等比缩放，绝不拉伸任何一个轴）；
/// - 最后对"渲染后的最长边"做一次统一的上下限夹取：太小看不见、太大撑满房间。
///   夹取时给出**读得懂的原因**，而不是静默改数字。
///
/// 为什么**不能**对渲染端也用这一条：已登记物件的渲染输入是**定稿高度**（`size.y`），
/// 不是请求高度。策略只吃"请求高度"，重复套用会把细长物件每帧再缩一次（不幂等）。
public enum WorldPropSizePolicy {
    /// 细长物件的门槛：最长边超过高度的这个倍数时，"高度"不再代表这件东西的大小。
    ///
    /// 取值依据（真机数据）：能用的两件分别是 1.348（咖啡机）与 1.265（斧头），
    /// 坏掉的剑是 7.532。4 落在"既有物件一个都不碰"与"细长物件必须改判"之间。
    public static let longThinAspectLimit: Float = 4

    /// 渲染后最长边的下限：再小在房间里看不见。
    public static let minimumExtentMeters: Float = 0.02
    /// 渲染后最长边的上限：舱室只有 7 × 8 × 3.2 m，超过这个数就是"撑满房间"。
    public static let maximumExtentMeters: Float = 3

    /// 按什么归一的（落进 `Resolution.basis`，供 UI/测试断言"走的是哪条路"）。
    public enum Basis: String, Equatable, Sendable {
        /// 高度就是它的大小（既有方形/矮物件走这条，与旧行为逐位相同）。
        case height
        /// 细长物件：按最长边归一。
        case longestEdge
        /// 夹到最长边上限。
        case clampedMaximum
        /// 夹到最长边下限。
        case clampedMinimum
    }

    public struct Resolution: Equatable, Sendable {
        /// 世界里真实尺寸（等比于原始网格）。
        public let size: WorldVector3
        public let basis: Basis
        /// 原始网格的 最长边 / 高度。
        public let aspectRatio: Float
        /// 被夹取时**读得懂**的原因；没夹取时为 nil。
        public let reason: String?
        public var longestEdge: Float { WorldPropSizePolicy.longestEdge(of: size) }
        public init(size: WorldVector3, basis: Basis, aspectRatio: Float, reason: String?) {
            self.size = size; self.basis = basis; self.aspectRatio = aspectRatio; self.reason = reason
        }
    }

    public static func longestEdge(of size: WorldVector3) -> Float {
        max(size.x, max(size.y, size.z))
    }

    public static func isFinite(_ size: WorldVector3) -> Bool {
        size.x.isFinite && size.y.isFinite && size.z.isFinite
    }

    /// 请求高度 → 世界尺寸。给不出合法尺寸时返回 nil（调用方 fail-closed）。
    ///
    /// **没有尺寸意图时**走这条（用户没提尺寸 ⇒ 由 app 按外形推断）。有意图时走
    /// `intended(sourceExtent:axis:meters:)` —— 两者共用同一段夹取，所以"按哪根轴归一"
    /// 不会长出第二套上下限。
    public static func automatic(sourceExtent: WorldVector3, requestedHeight: Float) -> Resolution? {
        guard let shape = shape(of: sourceExtent),
              requestedHeight.isFinite, requestedHeight > 0, requestedHeight <= 100
        else { return nil }
        // 细长物件：高度轴不是它的大小 ⇒ 按最长边归一。
        let basis: Basis = shape.aspect > longThinAspectLimit ? .longestEdge : .height
        let scale = requestedHeight / (basis == .longestEdge ? shape.longest : shape.height)
        return clamp(shape: shape, scale: scale, basis: basis)
    }

    /// 同一份网格、同一套归一策略，在**指定那个坐标系**里量出来的尺寸。
    ///
    /// 用途只有一个：身份判定（`WorldGeneratedProp.matchesIdentity(of:)` 的尺寸那一腿）。
    /// 世界状态里的 `size` 是"登记**当时**那套量法"的结果，而量法会变：摆正
    /// （`WorldPropOrientation`，2026-10-01 18:20 落地）之后，躺着生成的网格会被转正，
    /// AABB 的三个分量跟着换位 —— 同一份网格，登记时量到 `1.1 × 0.146 × 0.062`，
    /// 今天再量是 `0.146 × 1.1 × 0.062`。拿这两个数字互相要求逐位相等，等于**两个
    /// 坐标系互相要求相等**：真机那把 `2B 白色长剑`（17:15 登记、政策 18:20 落地）
    /// 就是这样被判成 `ownershipMismatch`、资产判成未备好，然后从房间里消失的。
    ///
    /// `orientation` 传**存档自己声明的那一份**（`WorldGeneratedProp.orientation`）：
    /// `nil` 就是"摆正之前"那个坐标系 —— 也就是改造前登记的存档所用的量法。
    /// 返回 nil = 这份网格量不出合法尺寸（与上面两条入口同一口径，调用方 fail-closed）。
    public static func recordedBaseline(
        sourceExtent: WorldVector3,
        orientation: WorldPropOrientation?,
        sizeIntent: WorldPropSizeIntent?,
        requestedHeight: Float
    ) -> WorldVector3? {
        let extent = orientation.map {
            WorldPropOrientationPolicy.orientedExtent(of: sourceExtent, by: $0)
        } ?? sourceExtent
        if let sizeIntent {
            return intended(sourceExtent: extent, axis: sizeIntent.axis, meters: sizeIntent.meters)?.size
        }
        return automatic(sourceExtent: extent, requestedHeight: requestedHeight)?.size
    }

    /// 提交时的**尺寸意图** → 世界尺寸。这是"用户说了尺寸"那条路的权威入口：
    ///
    /// - `axis == .longest`（"一把 1.1 米的剑"）：按**最长边**归一到 `meters`。
    ///   真机那把剑原来按高度归一（0.133 m 的厚度被当成"高度"）⇒ 8.28 m 长；
    ///   按最长边归一后场景里最长边就是 1.1 m，横纵比不失真。
    /// - `axis == .height`（"高 35 厘米的咖啡机"）：按**高度**归一，与旧路径逐位相同。
    ///
    /// 之后同样只做一次统一的上下限夹取（越界给读得懂的原因，不静默）。
    public static func intended(sourceExtent: WorldVector3, axis: WorldPropSizeAxis, meters: Float) -> Resolution? {
        guard let shape = shape(of: sourceExtent), meters.isFinite, meters > 0, meters <= 100 else { return nil }
        switch axis {
        case .height:
            return clamp(shape: shape, scale: meters / shape.height, basis: .height)
        case .longest:
            return clamp(shape: shape, scale: meters / shape.longest, basis: .longestEdge)
        }
    }

    /// 原始网格外形（最长边 / 高度 / 纵横比）的**一次**量取。两条归一入口都从它出发。
    private struct Shape {
        let extent: WorldVector3
        let height: Float
        let longest: Float
        let aspect: Float
    }

    private static func shape(of sourceExtent: WorldVector3) -> Shape? {
        guard isFinite(sourceExtent), sourceExtent.x > 0, sourceExtent.y > 0, sourceExtent.z > 0 else { return nil }
        let height = sourceExtent.y
        let longest = longestEdge(of: sourceExtent)
        guard longest.isFinite, longest > 0 else { return nil }
        let aspect = longest / height
        guard aspect.isFinite, aspect > 0 else { return nil }
        return Shape(extent: sourceExtent, height: height, longest: longest, aspect: aspect)
    }

    /// 等比缩放到目标尺寸，并对"渲染后的最长边"做**唯一一次**上下限夹取。
    private static func clamp(shape: Shape, scale: Float, basis: Basis) -> Resolution? {
        var scale = scale
        var basis = basis
        var reason: String?
        let rendered = shape.longest * scale
        if rendered.isFinite, rendered > maximumExtentMeters {
            scale = maximumExtentMeters / shape.longest
            basis = .clampedMaximum
            reason = "这件物件太长了：按请求尺寸它的最长边会是 \(meters(rendered)) 米，"
                + "超过上限 \(meters(maximumExtentMeters)) 米（房间只有 7 × 8 × 3.2 米），"
                + "已经缩到最长边 \(meters(maximumExtentMeters)) 米。"
        } else if !(rendered.isFinite) || rendered < minimumExtentMeters {
            scale = minimumExtentMeters / shape.longest
            basis = .clampedMinimum
            reason = "这件物件太小了：按请求尺寸它的最长边只有 \(meters(rendered)) 米，"
                + "低于下限 \(meters(minimumExtentMeters)) 米（再小在房间里看不见），"
                + "已经放大到最长边 \(meters(minimumExtentMeters)) 米。"
        }
        guard scale.isFinite, scale > 0 else { return nil }
        let size = WorldVector3(x: shape.extent.x * scale, y: shape.extent.y * scale, z: shape.extent.z * scale)
        guard isFinite(size), size.x > 0, size.y > 0, size.z > 0 else { return nil }
        return Resolution(size: size, basis: basis, aspectRatio: shape.aspect, reason: reason)
    }

    /// 用户手动改尺寸：把**最长边**设为目标值，等比缩放**当前**尺寸。
    ///
    /// 越界一律**拒绝**并给读得懂的原因（不静默夹取）：用户拖到的那个数字要么被接受，
    /// 要么被告知为什么不行。等比是**架构要求**而不是偏好：渲染端只有一份等比缩放
    /// （`WishMachineOutputPlacement.transform` 三个轴的 scale 是同一个值），
    /// 存一个非等比的 `size` 会让碰撞盒与画面对不上。
    public static func manualSize(current: WorldVector3, targetLongestEdge: Float) throws -> WorldVector3 {
        guard isFinite(current), current.x > 0, current.y > 0, current.z > 0 else {
            throw WorldPropLayoutError.invalidSize("这个物件现在的尺寸不合法，不能调整。")
        }
        let currentLongest = longestEdge(of: current)
        guard targetLongestEdge.isFinite, targetLongestEdge > 0 else {
            throw WorldPropLayoutError.invalidSize("尺寸必须是大于 0 的数。")
        }
        if targetLongestEdge < minimumExtentMeters {
            throw WorldPropLayoutError.invalidSize(
                "尺寸太小：最长边 \(meters(targetLongestEdge)) 米低于下限 \(meters(minimumExtentMeters)) 米，"
                + "缩到这个程度在房间里看不见。")
        }
        if targetLongestEdge > maximumExtentMeters {
            throw WorldPropLayoutError.invalidSize(
                "尺寸太大：最长边 \(meters(targetLongestEdge)) 米超过上限 \(meters(maximumExtentMeters)) 米"
                + "（房间只有 7 × 8 × 3.2 米），再大就撑满房间了。")
        }
        let factor = targetLongestEdge / currentLongest
        guard factor.isFinite, factor > 0 else {
            throw WorldPropLayoutError.invalidSize("尺寸换算失败，请重新拖动。")
        }
        return WorldVector3(x: current.x * factor, y: current.y * factor, z: current.z * factor)
    }

    /// 提交上来的尺寸是不是**当前尺寸的等比缩放**；不是就返回 nil。
    ///
    /// 这是"尺寸只有一个来源"的硬保证：世界里的 `size` 只有一份，碰撞盒、红/绿格、
    /// 存档都读它；画面用同一份等比缩放画出来。谁要是提交一个非等比的 `size`，
    /// 碰撞盒与画面当场就分叉了 —— 所以在这里拒绝，而不是让它进世界状态。
    public static func uniformFactor(from current: WorldVector3, to submitted: WorldVector3) -> Float? {
        guard isFinite(current), isFinite(submitted),
              current.x > 0, current.y > 0, current.z > 0,
              submitted.x > 0, submitted.y > 0, submitted.z > 0 else { return nil }
        let fx = submitted.x / current.x, fy = submitted.y / current.y, fz = submitted.z / current.z
        guard fx.isFinite, fy.isFinite, fz.isFinite else { return nil }
        let tolerance: Float = 0.001
        guard abs(fx - fy) <= tolerance * max(1, abs(fy)),
              abs(fy - fz) <= tolerance * max(1, abs(fz)) else { return nil }
        return fy
    }

    /// `2.34` 这种两小数写法，用于可读原因（`%.2f`，只给用户看）。
    static func meters(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
