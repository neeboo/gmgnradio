import CoreGraphics
import Foundation

/// 「这里为什么不能放」贴在**光标（手柄锚点）旁边**那枚小胶囊的纯逻辑。
///
/// 真机反馈：用户在装修时看到台面上一片绿格、其中两格是红的，问"这两个红色的是什么意思"。
/// 红 = 不能放 ✓，原因也**已经算出来了** —— 但它只写在面板下方那行 `state.notice` 里，
/// 而用户的视线在光标/物件上，不会去看面板右下角。于是原因要跟着光标走。
///
/// 这里刻意**不含任何文案**：写什么由调用方从既有的阻挡原因投影（
/// `ResidentPropGridEditorModel.hoveredBlockReason` → `PropSupportBlockReason.errorDescription`）
/// 取来。这个类型只回答两件事：
///   1. **该不该画、画什么**（`content(isCarrying:reason:)`）；
///   2. **画在哪**（`frame(anchor:ringRadius:textSize:viewSize:)`）—— 屏幕空间，不动 Metal。
///
/// 只依赖 Foundation，所以绘制逻辑能离线单测（`tools/test-resident-prop-render.swift`）。
enum ResidentPropBlockReasonLabel {
    /// 胶囊底边与**圆环外缘**之间的间隙。圆环半径 26 pt，所以标签整体在锚点上方
    /// `10（手柄固定偏移）+ 26（半径）+ 6（间隙）= 42 pt`，且与圆环同侧（右上）——
    /// 落点那个格子本身不会被挡住。
    static let ringGap: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let fontSize: CGFloat = 11
    static let cornerRadius: CGFloat = 7

    /// 该不该画、画什么文案。
    ///
    /// - **没携带物件**（手上没东西）→ nil：不画；
    /// - **没有原因**（这里能放）→ nil：不画。可放时不该常驻一枚"能放"的噪音标签，
    ///   绿色格子本身已经说明了这件事；
    /// - 原因是空白（只有空格/换行）→ nil：画一个空气泡不如不画；
    /// - 否则**原样**返回原因（不做任何拼装、改写或截断）。
    static func content(isCarrying: Bool, reason: String?) -> String? {
        guard isCarrying, let reason else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 胶囊底框：水平居中于锚点、底边压在**圆环外缘之上**（`anchor.y + ringRadius + ringGap`），
    /// 再夹进视图内，免得贴边时被裁掉。
    ///
    /// `anchor` 是旋转手柄圆环的圆心（= footprint 中心投影 + 固定屏幕偏移），
    /// 与 `StageWorldInteractionView.rotationHandleCenter` 同一个点、同一套坐标（左下原点）。
    static func frame(
        anchor: CGPoint,
        ringRadius: CGFloat,
        textSize: CGSize,
        viewSize: CGSize
    ) -> CGRect {
        let width = max(0, textSize.width) + horizontalPadding * 2
        let height = max(0, textSize.height) + verticalPadding * 2
        // 宽度先夹：视图比标签还窄时（极端情况）靠左贴边，而不是算出负的 x。
        let maximumX = max(0, viewSize.width - width)
        let x = min(max(anchor.x - width / 2, 0), maximumX)
        // 上方优先：这是唯一不压住物件、也不压住圆环的方向。
        // 上面实在放不下（锚点贴着视图顶边）时退回"尽量靠上但留在视图内"，
        // 这时才可能与圆环重叠 —— 屏幕边缘的极端情况，不是常态。
        let preferredY = anchor.y + ringRadius + ringGap
        let maximumY = max(0, viewSize.height - height)
        let y = min(max(preferredY, 0), maximumY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
