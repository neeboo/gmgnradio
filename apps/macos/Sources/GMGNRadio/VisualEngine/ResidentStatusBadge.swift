import CoreGraphics
import Foundation
import simd

/// 气泡配色的一条。存分量而不是 `SwiftUI.Color`，于是配色可以在没有 SwiftUI 的离线
/// harness 里断言（"底是不是白的、符号是不是深的"），而渲染端只负责把这些分量包成
/// `Color`。整份代码里 RGB 只在这里出现一次。
struct ResidentStatusBadgeInk: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    /// 感知亮度（Rec. 709）。断言"白色底 / 深色符号"用的就是它。
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// 居民「在想 / 在说」的**唯一一份**符号来源，以及头顶那朵漫画气泡的**纯几何**。
///
/// 为什么要有这个类型：同一个状态现在有三个渲染点 ——
///
/// 1. 舞台世界里角色**头顶的漫画气泡**（`StageOverlayView` 里的
///    `StageResidentHeadBadgeView`，主交付）；
/// 2. 舞台下方合成器那行状态文字（`StageResidentComposer`）；
/// 3. Live Cam 面板的状态行（`LiveCamPanel.updateResidentStatusNotice`）。
///
/// 三处**都**从这里取符号（`symbol(isThinking:isSpeaking:)`），所以「🤔 表示思考、
/// 🗣️ 表示说话」这两条字面量在整份代码里各只出现一次；任何一处改了符号，另外两处
/// 自动跟着改，不可能出现"舞台显示 🤔、面板显示别的"这种分叉。配色同理：云体、指向
/// 圆点、符号用的是同一个 `ResidentStatusBadgeInk`。
///
/// 叠加规则（明确、且三处一致）：**说话优先于思考**。语音输出（TTS 正在播）时只显示
/// 🗣️；只有没在说话时才显示 🤔。语音输入（`voiceActive`，用户在说、居民在听）既不是
/// 思考也不是说话，用 👂 单独表示。
///
/// 空闲态（既没在思考也没在说话、也不在听）**不带任何符号**：气泡整朵不画，状态行就是
/// 原来的「你的居民」。所以屏幕上不会留下一个孤立的 emoji。
///
/// 本类型只依赖 Foundation / CoreGraphics / simd，不含 AppKit、Metal 或任何渲染状态，
/// 所以几何、配色与规则都能离线单测（`tools/test-stage-resident-chat.swift`）。
enum ResidentStatusBadge {

    // MARK: - 状态 → 符号（全仓库唯一一份字面量）

    /// 思考中（模型在跑 / 等居民回应）。
    static let thinkingSymbol = "🤔"
    /// 说话中（语音正在输出）。
    static let speakingSymbol = "🗣️"
    /// 在听（语音输入活跃：用户在说话）。
    static let listeningSymbol = "👂"

    /// 当前该显示哪个符号。`nil` = 空闲，不画气泡、也不加前缀。
    ///
    /// 规则：**说话优先**。两者同时为真时（流式语音在生成还没结束时就开始播）取 🗣️，
    /// 因为"正在出声"是用户此刻唯一的听觉事实，而"在等模型"只是过程。
    static func symbol(isThinking: Bool, isSpeaking: Bool) -> String? {
        if isSpeaking { return speakingSymbol }
        if isThinking { return thinkingSymbol }
        return nil
    }

    /// 气泡该不该画。空闲态整朵（云 + 点）消失。
    static func isVisible(isThinking: Bool, isSpeaking: Bool) -> Bool {
        symbol(isThinking: isThinking, isSpeaking: isSpeaking) != nil
    }

    // MARK: - 状态文字行（舞台合成器与 Live Cam 面板共用）

    /// 空闲态的原文案。**不带符号**。
    static let idleLabel = "你的居民"
    /// 说话态的文案。与 `speakingSymbol` 一起组成 `speakingLine`。
    static let speakingText = "正在说话…"
    /// 听音态沿用改动前的文案，只多一个符号前缀。
    static let listeningText = "正在听你说话…"

    /// 说话那一行（符号 + 文案）。Live Cam 面板在"没在思考、但语音正在播"时插这一行。
    static var speakingLine: String { speakingSymbol + " " + speakingText }
    /// 听音那一行。听音既不是思考也不是说话，所以走独立符号，不复用 `decorate`。
    static var listeningLine: String { listeningSymbol + " " + listeningText }

    /// 把符号加到**既有**状态行前面。没有符号时原样返回，所以空闲态一个字都不变。
    ///
    /// 这是给"文案已经由调用方决定"的渲染点用的（Live Cam 面板的进度行可能是任意
    /// 工具进度文案，不能在这里重新拼装）。
    static func decorate(_ line: String, isThinking: Bool, isSpeaking: Bool) -> String {
        guard let symbol = symbol(isThinking: isThinking, isSpeaking: isSpeaking) else { return line }
        return symbol + " " + line
    }

    /// 舞台合成器的状态行：**只有这一处**决定「思考 / 说话 / 在听 / 空闲」四种文案。
    ///
    /// `progress` 是宿主推来的真实进度（例如"正在查询歌单…"）；思考时显示它而不是一句
    /// 假的"思考中"（这条口径不变，见 `ResidentAgentLoop`）。四个分支的**文案**与改动前
    /// 逐字一致，新增的只是符号前缀（说话分支是新增的：改动前语音输出时这行显示的是
    /// 空闲文案"你的居民"，用户看不到"它在说话"）。
    static func statusLine(
        isThinking: Bool,
        isSpeaking: Bool,
        isListening: Bool,
        progress: String
    ) -> String {
        if isSpeaking { return speakingLine }
        if isThinking { return decorate(progress, isThinking: true, isSpeaking: false) }
        if isListening { return listeningLine }
        return idleLabel
    }

    // MARK: - 头顶锚点（世界空间）

    /// 居民**头顶**在模型本地坐标里的高度（米）。
    ///
    /// 与 `MarblePMXFraming` 内部那个 `normalizedHeight` 是同一个量：模型包围盒还没测出来
    /// 时（`bounds == nil`），整套绑定矩阵就是把本地 `0 ... normalizedHeight` 线性映射到
    /// `placement.position.y ... placement.position.y + placement.scale * normalizedHeight`。
    /// 两个常量必须一致 —— harness 里有断言把生产源码里那个值读出来钉住（改一处不会
    /// 静默错位）。
    static let headLocalTopY: Float = 1.7

    /// 角色头顶的**世界点**。`modelTransform` 由调用方从**既有的**绑定矩阵取得
    /// （`MarblePMXFraming.modelTransform(bounds:placement:)`）——这里只是把本地头顶
    /// 那一点代入，不重算任何绑定/投影。
    ///
    /// 取参数而不是在里面自己构造矩阵，是为了这个函数保持**纯函数**：给一个变换就得到
    /// 一个世界点，离线 harness 能直接喂一个平移/缩放矩阵验证"角色一动，锚点跟着动"。
    static func headTopWorldPoint(modelTransform: simd_float4x4) -> SIMD3<Float> {
        let local = SIMD4<Float>(0, headLocalTopY, 0, 1)
        let world = modelTransform * local
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    // MARK: - 屏幕空间几何（**左上原点**，与 `residentPropScreenPoint` 和 SwiftUI Canvas 同一套）

    /// 归一化投影（左上原点、`0...1`，就是 `SpatialStageStore.residentPropScreenPoint`
    /// 的返回值）→ 视图点（左上原点、pt）。**不做任何夹取**：夹取是 `anchor` 的事。
    static func viewPoint(projectedNormalized: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(
            x: projectedNormalized.x * viewSize.width,
            y: projectedNormalized.y * viewSize.height
        )
    }

    /// 云体（不含指向点）的尺寸，**固定 pt**。
    ///
    /// 尺寸里**没有任何随相机距离缩放的量**：投影只提供锚点位置，云的宽高恒定。于是
    /// "相机拉远时不要缩到看不见"这条不是靠夹取实现的，而是**结构上不可能缩放** ——
    /// 与既有的旋转手柄圆环（`StageWorldInteractionView` 里"整条链上没有任何随距离缩放
    /// 的量"）同一套口径。
    static let cloudSize = CGSize(width: 50, height: 36)

    /// 云底之下、留给"由大到小的指向圆点"的竖直跨度。
    static let tailSpan: CGFloat = 30

    /// 最下面那个指向圆点的**下边缘**与头顶之间必须留出的最小间隙（pt）。
    ///
    /// 这一条是"离头要有一点距离"的硬保障：即使相机拉到最近、云最低、浮动到最低点，
    /// 指向点与头顶之间也还有这么多空白。20 pt 是在真机反馈"小云朵卡在头部了"之后，
    /// 按"估算头高之外再留净空"给的：真机的头骨比"地面位置 + 1.7 m × 缩放"这个估算
    /// 略高（根节点抬升 `PMXFullStageGroundingPolicy` 只抬不降），所以间隙要按估算误差
    /// 之外的净空来给。
    static let minimumHeadGap: CGFloat = 20

    /// 间隙随角色**在屏幕上的身高**缩放的比例。
    ///
    /// 为什么不是纯屏幕常量：相机拉近时头在屏幕上变得很大，固定 20 pt 会被头本身吃掉
    /// —— 那正是"卡在头部"的成因。所以间隙按角色屏高线性放大，再夹在
    /// `minimumHeadGap ... maximumHeadGap`：近处不压头，远处不飘走，也不会跑到画面外。
    static let headGapRatio: CGFloat = 0.15
    static let maximumHeadGap: CGFloat = 38

    /// 上下浮动的幅度（pt）与周期（秒）。克制：±2.5 pt / 2 s。
    static let bobAmplitude: CGFloat = 2.5
    static let bobPeriod: Double = 2
    /// 思考时云里符号的呼吸幅度（缩放增量）与周期。
    static let breathAmplitude: CGFloat = 0.08
    static let breathPeriod: Double = 1.2

    /// 头顶与**最下面那个指向点下边缘**之间的净空（pt）。
    ///
    /// 角色屏高不可用（投影拿不到脚点）时退回最小值，于是气泡仍然画得出来、也仍然不压头。
    static func headGap(characterScreenHeight: CGFloat) -> CGFloat {
        guard characterScreenHeight.isFinite, characterScreenHeight > 0 else {
            return minimumHeadGap
        }
        return min(
            max(characterScreenHeight * headGapRatio, minimumHeadGap),
            maximumHeadGap
        )
    }

    /// 云朵**名义**中心（视图坐标，**左上原点**，不含浮动）。`nil` = 不画。
    ///
    /// 云体整体在头顶**之上**：中心 y = 头顶 y − 净空 − 指向点跨度 − 半个云高。也就是
    /// 头顶只是"指向点瞄准的那个点"，云体本身离它还有 `净空 + 指向点跨度` 那么远，
    /// 绝不是"以头顶为中心"。
    ///
    /// **不做夹边**：这是**世界锚定**的提示，夹到屏幕边缘就会指向一片没有角色的地方。
    /// 头顶投影落到视图外时干脆不画（角色走开/相机转开时云跟着消失，而不是贴在边上）。
    static func anchor(
        projectedHead: CGPoint,
        characterScreenHeight: CGFloat,
        viewSize: CGSize
    ) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard projectedHead.x >= 0, projectedHead.x <= viewSize.width,
              projectedHead.y >= 0, projectedHead.y <= viewSize.height
        else { return nil }
        // 整朵云要留在视图里，画面顶端塞不下就不画 —— 免得半个云挂出去。
        let centerY = projectedHead.y
            - headGap(characterScreenHeight: characterScreenHeight)
            - tailSpan
            - cloudSize.height / 2
        guard centerY - cloudSize.height / 2 >= 0 else { return nil }
        return CGPoint(x: projectedHead.x, y: centerY)
    }

    /// 云体矩形。`bob` 是当前的浮动偏移（正 = 往下一点点，左上原点）。
    ///
    /// 云体随浮动轻轻上下；**指向圆点不跟着浮**（见 `tailDots`）—— 它们是"从头顶冒出来的
    /// 想法"，钉在角色头顶上方，浮动只发生在云本身。于是"与头的最小间隙"是一个与时间
    /// 无关的常量，不会被浮动吃掉。
    static func cloudRect(anchor: CGPoint, bob: CGFloat = 0) -> CGRect {
        CGRect(
            x: anchor.x - cloudSize.width / 2,
            y: anchor.y - cloudSize.height / 2 + bob,
            width: cloudSize.width,
            height: cloudSize.height
        )
    }

    /// 缓慢上下浮动的偏移（pt）。时间的纯函数 —— 不累积、不依赖上一帧，所以状态切换或
    /// 掉帧都不会让它漂移或抖动。
    static func bobOffset(seconds: Double) -> CGFloat {
        CGFloat(sin(seconds * 2 * .pi / bobPeriod)) * bobAmplitude
    }

    /// 云里符号的呼吸缩放。只在思考时用（说话时符号保持 1.0，避免"边说话边抖"）。
    static func breathScale(seconds: Double) -> CGFloat {
        1 + CGFloat(sin(seconds * 2 * .pi / breathPeriod)) * breathAmplitude
    }

    /// 由大到小的三个指向圆点，**圆心**在云底与头顶之间竖直排开。
    ///
    /// 索引 0 最大、紧贴云底；最后一个最小、离头顶最近 —— 漫画里"这是想法"的经典画法。
    /// 圆心 x 一律等于头顶投影的 x，所以指向点始终**正对头顶**；整组点与头顶之间还留着
    /// `headGap` 的净空（最后一个点的下边缘在 `headGap + 0.15 × tailSpan − 半径 > headGap`
    /// 之上）。
    static func tailDots(anchor: CGPoint) -> [(center: CGPoint, radius: CGFloat)] {
        let radii: [CGFloat] = [4.2, 3.0, 2.0]
        let samples: [CGFloat] = [0.18, 0.52, 0.85]
        let cloudBottom = anchor.y + cloudSize.height / 2
        return zip(radii, samples).map { radius, sample in
            (
                center: CGPoint(x: anchor.x, y: cloudBottom + sample * tailSpan),
                radius: radius
            )
        }
    }

    /// 云朵轮廓：底面圆角矩形 + 三个圆瓣。返回**要填充的每一块**（左上原点）。
    ///
    /// 不构造布尔并集路径（CoreGraphics 没给），而是让调用方按"描边色先画一圈放大版、
    /// 再画填充色本体"的顺序叠加 —— 结果是干净的单层云轮廓，没有内部弧线。
    /// 形状是纯几何，所以能离线断言"云瓣都在 rect 内、每一瓣都真的鼓出来"。
    ///
    /// 圆瓣返回的是**正方形 + 半径 = 半边长**（等价于圆），底面返回圆角矩形，两者都用
    /// `Path(roundedRect:cornerRadius:)` 画，调用方不需要分辨类型。
    static func cloudBlobs(in rect: CGRect) -> [(rect: CGRect, cornerRadius: CGFloat)] {
        /// `fromBottom`：0 = 云的底边，1 = 云的顶边。
        func blob(_ x: CGFloat, _ fromBottom: CGFloat, _ radius: CGFloat) -> (rect: CGRect, cornerRadius: CGFloat) {
            let centerY = rect.maxY - fromBottom * rect.height
            return (
                CGRect(
                    x: rect.minX + x * rect.width - radius,
                    y: centerY - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                radius
            )
        }
        let unit = rect.height
        // 底面那一条（横向铺满，托住三个圆瓣）。
        let base = (
            CGRect(
                x: rect.minX + 0.13 * rect.width,
                y: rect.maxY - 0.58 * rect.height,
                width: 0.74 * rect.width,
                height: 0.50 * rect.height
            ),
            0.25 * rect.height
        )
        return [
            base,
            blob(0.28, 0.52, 0.24 * unit),
            blob(0.50, 0.64, 0.29 * unit),
            blob(0.73, 0.50, 0.22 * unit),
        ]
    }

    // MARK: - 配色（全仓库唯一一份 RGB）

    /// 云体与指向圆点的**填充**：白色主体。
    ///
    /// 真机反馈（"气泡不太对，要用白色底"）：舱内背景偏暗，深色气泡与暗背景糊在一起。
    /// 白色主体在暗背景上最清楚，也符合漫画气泡的观感；亮背景下靠下面那条深色细描边界定。
    static let cloudFill = ResidentStatusBadgeInk(red: 1, green: 1, blue: 1, alpha: 0.96)
    /// 云体与指向圆点的**描边**：深色、细。亮背景可辨，暗背景上也不抢戏。
    static let cloudOutline = ResidentStatusBadgeInk(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.55)
    /// 云里符号的墨色：深色，压在白色主体上。
    ///
    /// 注意 🤔 / 🗣️ 是**彩色 emoji**：平台用字形自带的颜色渲染，不吃 `foregroundStyle`。
    /// 白色主体之上它们本来就清楚；这个墨色是给非彩色字形（未来的单色符号，或系统回落
    /// 字形）准备的，也把"深色符号"这条意图钉在唯一一份配色里。
    static let symbolInk = ResidentStatusBadgeInk(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
    /// 指向圆点与云体**同一套配色**（显式转发，不另写一份）。
    static var tailDotFill: ResidentStatusBadgeInk { cloudFill }
    static var tailDotOutline: ResidentStatusBadgeInk { cloudOutline }
}
