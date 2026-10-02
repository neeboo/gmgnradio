import Foundation

/// 「电视」这条产品规则里**给用户看的那几句话**（唯一一份，纯函数、无 UI）。
///
/// ## 这条规则是什么（2026-10-02 按用户的反对改正）
///
/// 用户的反对原话：「**不行啊，这样用户就没办法自定义外观了啊**」。
/// 背景是真机 2026-10-01「平面电视」：用户发了一张平面电视的产品图、给了 `1443 × 862 × 302 mm`，
/// 生成器交回来的是**一个大立方体**，而 app 那条"三轴 + 板形 ⇒ 直接用基础几何拼"的支路
/// **静默**把生成结果换掉了 —— 用户那张参考图（贴图、细节、观感）**一次都没被用上**。
///
/// 所以规则是：
///
/// 1. **生成永远是作者路径**：素材 / 提示词 → 生成 → **用它**。几何拼**不是默认**；
/// 2. 几何拼只是"生成器没做对"时的**可见修复选项**，而且**必须由用户明说**
///    （`WishPropAppearanceChoice.primitiveTelevision`，走 `build_primitive_television` 工具）——
///    **绝不静默替换**；
/// 3. 两条路都得是正常物件（摆放 / 承托 / 碰撞 / 删除 / 入库），尺寸与判据同源。
///
/// ## 这里为什么只有"字"
///
/// 判据（板形 / 最大平坦面 / 尺寸 / 承托）**一条都不在这里**：它们是既有的那一份
/// （`WorldScreenFaceInference.rejection`、`WorldPropSizePolicy`、摆放服务），这条规则
/// **一个字都没放宽**。这个文件只把"判据说了什么"翻译成用户读得懂的一句人话，并把
/// **两个选择**摆在他面前 —— 面板那一行、任务行、agent 回执读的都是这一份，不另写一套。
enum ResidentPropTelevisionRepair {

    /// 用户选了「用几何拼」之后，入库那句回读的前缀（后面接 `dimensionsSummary`）。
    ///
    /// 它让"这件的几何是你**选**的那条路拼的"看得见：不写，用户会以为几何还是生成器给的。
    static let geometryChosenPrefix = "你选了用几何拼。"

    /// 「生成器没做对」时的**一句人话 + 两个选择**。
    ///
    /// 调用点（`App/GMGNRadioApp.swift` 的生成入库那一处）已经用**既有那一份**板形判据
    /// （`WorldScreenFaceInference.rejection`）判过**生成网格量出来的**那一份尺寸 ——
    /// 这里只负责说人话。所以这句话出现 ⟺ 判据说"它不是一块扁平面板"。
    ///
    /// - `name`：用户给这件起的名字（照实叫，不叫"那件东西"）；
    /// - `millimeters`：**用户原话的三个毫米数**（选择②要按它拼，所以必须逐位说出来）。
    static func shapeChoiceNotice(name: String, millimeters: PropSizeIntent.Millimeters) -> String {
        let axes = PropSizeIntent.millimetersText(millimeters)
        return "生成器把「\(name)」做成了方块，不像一块扁平面板。两条路你挑："
            + "①换张图重做 —— 发我一张正面、无背景、只有一件产品的图，说一句「重做\(name)」"
            + "（正面、单件、无背景的图更容易出扁平面板）；"
            + "②对我说「拼一台标准电视」，我用几何按你说的 \(axes) 毫米拼一台"
            + "（尺寸就是这三个数，正面那一块就是屏幕：要放什么你自己说了算）。"
    }

    /// 用户选了"用几何拼"，但他给的那三个数**本身**就不像一块扁平面板。
    ///
    /// 这时拼不出电视，而**绝不静默落回生成网格** —— 一次明确的选择"点了没反应"比不做更坏。
    /// 判据仍是既有那一份（同一份 `WorldScreenFaceInference.rejection`），只是这次吃的是
    /// 用户给的三个数（`WorldPrimitiveTelevision` 会拒绝非法/退化的三轴，这里说的是"合法但不像面板"）。
    static func geometryUnavailableNotice(name: String, millimeters: PropSizeIntent.Millimeters) -> String {
        let axes = PropSizeIntent.millimetersText(millimeters)
        return "你选了用几何拼，但你给的 \(axes) 毫米这三个数本身就不像一块扁平面板（最薄那一维"
            + "相对最长那一维太厚），拼出来也不会是电视 —— 所以我**没有**拼，也**没有**替你把它换成"
            + "别的东西。要么把三个数改成一整块面板的比例（例如 1443 × 862 × 302），要么换张图重做"
            + "「\(name)」。"
    }
}
