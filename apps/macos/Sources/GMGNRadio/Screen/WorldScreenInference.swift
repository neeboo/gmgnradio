import Foundation
import simd

// MARK: - 屏幕几何的三级来源

/// 「这块屏幕的几何是哪来的」的**唯一**解析处。
///
/// 优先级（高 → 低，命中即停，**命中哪一级必须写进 `note`**）：
///
/// 1. **标定**：`metadata["gmgn.screen.v1"]` 合法即用。用户/编辑器说了算。
/// 2. **推断**：没有标定、但有这件道具的尺寸（生成道具的 `effectiveSize`，或承托网格
///    派生出的包围盒）时，取**最大平坦面**，要求面积 ≥ `minimumFaceArea` 且这件东西
///    **像一块板**（最薄轴 ≤ 最长轴的 `maximumPanelThicknessRatio`）。
/// 3. **缺省**：前两级都说不出话、且调用方**明确**声明"这台是要装屏幕的电视"时，
///    用一台通用电视的缺省，并在 `note` 里**逐字写明这是猜的、为什么走到这一步**。
///    调用方没有声明时**不给缺省** —— 返回具名原因（不硬猜）。
///
/// 缺省与推断的差别就是"要不要说谎"：两者都写在 `note` 里，且
/// `WorldScreenDefinition.isValid` 强制 `note` 非空，所以**不存在**一条说不出来处的
/// 屏幕定义。
enum WorldScreenResolution {
    /// 低于这个面积（m²）的"面"不是屏幕，是零件。20 cm × 20 cm。
    static let minimumFaceArea: Float = 0.04
    /// "像一块板"的判据：最薄轴 / 最长轴。
    static let maximumPanelThicknessRatio: Float = 0.25
    /// 推断出的屏幕相对该面**每边**留的边框余量，取该面**短边**的这个比例。
    ///
    /// 为什么不是"一个固定毫米数"，也不是一个把屏幕整体缩到某个百分比的常数
    /// （真机 2026-10-02，用户原话「屏幕也没有 filled」）：
    ///
    /// 这一级是**推断**：手上只有这件道具的包围盒（`effectiveSize`），不知道它的边框
    /// 在网格里有多宽。所以余量只能由**这一面自己的尺寸**派生 —— 于是三轴怎么变，
    /// 余量同倍跟着变，屏幕占正面的比例与尺寸无关。固定毫米数做不到这一点：
    /// 同一份 8.6 mm 在 0.862 m 高的电视上是 1%，在 0.34 m 高的小电视上就是 2.5%。
    ///
    /// 这里曾经是一个把屏幕缩到 **86%** 的常数（`panelInset = 0.86`，每边吃掉该轴的
    /// 7%）。真机那台 `1443 × 862 × 302 mm` 的电视正面是 `1.443 × 0.862 m`，屏幕
    /// 四边形却只有 `1.241 × 0.741 m`：左右各缩进 **101 mm**、上下各 **60 mm**，
    /// 面积只占正面的 **73.96%** —— 截图里那块"缩在正面中间、还偏下的暗矩形"就是它。
    /// 而这件机身的正面**就是屏幕本身**（参考图那张产品图里屏幕几乎顶到画幅边缘）。
    static let bezelMarginFraction: Float = 0.01
    /// 屏幕面相对包围盒表面外移的一点点，避免与自身表面共面闪烁。
    static let surfaceOffset: Float = 0.001

    /// 这一面**每边**该留的边框余量（米）。派生，不存 —— 于是"这块屏幕多大"仍然只有
    /// `halfWidth/halfHeight` 一处定义，这里只是它唯一的推导入口。
    ///
    /// 取**短边**而不是各轴各按自己的比例：真实电视的边框是**等宽**的，四边留一样宽
    /// 最像一台电视。`2 × 余量` 恒小于短边（1% ≪ 100%），四边形不可能被余量吃成负的。
    ///
    /// 于是覆盖率有一个与尺寸无关的下界：两条边各自留下的比例都 ≤ 2%（短边那一侧恰好
    /// 2%，长边那一侧更小），最坏是正方形那一份 `0.98 × 0.98 = 96.04%`。
    static func bezelMargin(faceWidth: Float, faceHeight: Float) -> Float {
        min(faceWidth, faceHeight) * bezelMarginFraction
    }

    /// 缺省的"一台通用电视"（米）。只在 `allowsDefault` 为真时使用。
    static let defaultWidth: Float = 1.10
    static let defaultHeight: Float = 0.62
    static let defaultCenterHeight: Float = 1.05

    /// 解析一台道具的屏幕几何。
    ///
    /// - Parameters:
    ///   - objectID: 物件 id。所有具名原因都带上它。
    ///   - calibratedJSON: `metadata["gmgn.screen.v1"]` 的原始 JSON（可能没有）。
    ///   - size: 这件道具的尺寸（米，局部包围盒的 x/y/z）。没有尺寸 = 没有第二级。
    ///   - allowsDefault: 调用方是否**明确**声明"这是一台要装屏幕的电视"。
    ///     只有为真时才允许走到第三级；否则缺几何就是缺几何（可见失败）。
    static func resolve(
        objectID: String,
        calibratedJSON: String?,
        size: SIMD3<Float>?,
        allowsDefault: Bool
    ) -> Result<WorldScreenDefinition, WorldScreenGeometryIssue> {
        // ① 标定。存在但读不出来是**错误**，不是"没有"：坏数据不许静默降级成推断值。
        if let calibratedJSON {
            guard let definition = WorldScreenDefinitionCoding.decode(
                calibratedJSON, expecting: objectID
            ) else {
                return .failure(.invalidCalibration(objectID: objectID))
            }
            return .success(definition)
        }

        // ② 推断。
        if let size, size.x.isFinite, size.y.isFinite, size.z.isFinite,
           size.x > 0, size.y > 0, size.z > 0 {
            let face = WorldScreenFaceInference.largestFace(size: size)
            if let rejection = WorldScreenFaceInference.rejection(size: size, objectID: objectID) {
                // 有尺寸但判不出屏幕：**不许糊一块与这件道具无关的平面**。
                //
                // 这里曾经落到"通用电视"缺省（1.10 m × 0.62 m、中心高 1.05 m）。那是错的，
                // 理由是**真机数据**而不是偏好：真机那件 `超大荧幕电视`（生成道具
                // `2F633C0F-…`，用户意图最长边 1.443 m ⇒ 尺寸 1.443 × 0.901 × 1.443 m）
                // 三边 0.62 比 1 还粗，`notPanelLike` 成立；于是它被糊上一块固定
                // 1.10 × 0.62、中心高 **1.05 m** 的平面 —— 比这件道具自己的顶（0.901 m）
                // 还高 0.15 m。"屏幕"于是浮在电视**上方**，既不在它身上，也不跟它一样大。
                //
                // 两条纪律同时要求改：
                // 1. `docs/plans/2026-10-02-stage-tv-screen.md` §1.2 写明缺省是
                //    "**尺寸也没有时**"那一级；尺寸在手时把判定权交给一个固定尺寸，
                //    等于让**名字**压过**几何**。
                // 2. 屏幕是**物件上的一个面**。猜也必须猜这件道具自己的一个面。
                guard allowsDefault else {
                    return .failure(rejection)
                }
                return .success(fallbackDefinition(objectID: objectID, size: size))
            }
            return .success(inferredDefinition(objectID: objectID, size: size, face: face))
        }

        // ③ 缺省（必须有明确声明）。
        guard allowsDefault else {
            return .failure(.missingGeometry(objectID: objectID))
        }
        return .success(defaultDefinition(objectID: objectID, extraReason: ""))
    }

    // MARK: 由最大平坦面推断

    static func inferredDefinition(
        objectID: String,
        size: SIMD3<Float>,
        face: WorldScreenFace
    ) -> WorldScreenDefinition {
        let quad = face.quad(size: size)
        let area = face.area(size: size)
        let extents = face.extents(size: size)
        let margin = WorldScreenResolution.bezelMargin(
            faceWidth: extents.x, faceHeight: extents.y
        )
        // 一整条字面量（不拆成 `+`）：`test-user-facing-copy.swift` 的豁免是按**字面量**
        // 匹配的，拆开之后后半句会以"新文案"的身份进入用户可见那一档 —— 但它不是面板文案，
        // 它是标定工程注记（面板那一句在 `ScreenPanelCopy.screenRangeLine`）。
        let note = String(
            format: "由最大平坦面推断：法向 %@，面积 %.3f m²（%.2f m × %.2f m），屏幕铺满这一面、四边各留边框 %.0f mm。不是标定值，可在面板里改。",
            face.normalName, area, quad.width, quad.height, margin * 1000
        )
        return WorldScreenDefinition(
            objectID: objectID, source: .inferred, quad: quad, note: note
        )
    }

    // MARK: 判不出板形、但调用方已声明"这是电视"

    /// "判不出板形"那一级的兜底：**这件道具自己的一个面**，而不是一台与它无关的通用电视。
    ///
    /// 为什么给面而不是什么都不给：走到这里说明调用方已经**明确声明**"这台是要装屏幕的
    /// 电视"（名字里带电视/屏幕，或在面板里显式指定）。此时说"没有屏幕"，用户看到的是
    /// 一台什么都放不了的电视；这一级本来就是允许猜的（`source = .default`，
    /// `note` 里必须写"这是猜的"）。
    ///
    /// 为什么是**竖直面**（±Z 正面 / ±X 侧面里面积大的那一个）：屏幕在竖直面上覆盖
    /// 绝大多数情形（电视、显示器、挂墙屏）。躺着的薄板走的不是这一级 —— 它板形成立，
    /// `largestFace` 会正确地选中朝上的那一面；所以这一条不会把"躺着的屏幕"判错。
    ///
    /// 尺寸、比值、选中的面、最终宽高全部写进 `note`：这一份是猜的，但它**可以被复核**。
    static func fallbackDefinition(
        objectID: String,
        size: SIMD3<Float>
    ) -> WorldScreenDefinition {
        let face = WorldScreenFaceInference.defaultFace(size: size)
        let quad = face.quad(size: size)
        let note = String(
            format: "判不出板形（三边 %.2f × %.2f × %.2f m，最薄/最长 %.2f > %.2f）："
                + "按它面积较大的**竖直面** %@ 取 %.2f m × %.2f m。这一份是猜的，"
                + "不是标定值，请在面板里标定。",
            size.x, size.y, size.z,
            WorldScreenFaceInference.thinnestOverLongest(size: size),
            WorldScreenResolution.maximumPanelThicknessRatio,
            face.normalName, quad.width, quad.height
        )
        return WorldScreenDefinition(
            objectID: objectID, source: .default, quad: quad, note: note
        )
    }

    // MARK: 缺省

    static func defaultDefinition(objectID: String, extraReason: String) -> WorldScreenDefinition {
        let quad = WorldScreenQuad(
            center: SIMD3<Float>(0, defaultCenterHeight, 0),
            yaw: 0,
            pitch: 0,
            halfWidth: defaultWidth / 2,
            halfHeight: defaultHeight / 2
        )
        let note = "缺省未标定：假定 \(String(format: "%.2f", defaultWidth)) m × "
            + "\(String(format: "%.2f", defaultHeight)) m、中心高 "
            + "\(String(format: "%.2f", defaultCenterHeight)) m 的一台电视。"
            + "屏幕位置是猜的，请在面板里标定。\(extraReason)"
        return WorldScreenDefinition(
            objectID: objectID, source: .default, quad: quad, note: note
        )
    }
}

/// 包围盒的六个面里，哪一个当屏幕。
///
/// 选择是**确定性**的：面积最大的那一面；面积相等时按 `front(Z) > side(X) > top(Y)` 定序，
/// 于是同一份尺寸永远给出同一个答案（没有随机、没有"取最近"）。
enum WorldScreenFace: String, Equatable, Sendable {
    /// 法向 ±Z 的那一面（宽 × 高）。
    case front
    /// 法向 ±X 的那一面（厚 × 高）。
    case side
    /// 法向 ±Y 的那一面（宽 × 厚）。
    case top

    var normalName: String {
        switch self {
        case .front: "+Z（正面）"
        case .side: "+X（侧面）"
        case .top: "+Y（顶面）"
        }
    }

    /// 这一面的**宽 × 高**（米）。它是"这一面多大"的**唯一**一处说法：面积由它派生，
    /// 屏幕四边形与它的边框余量也都读它 —— 三处不可能各说各的尺寸。
    func extents(size: SIMD3<Float>) -> SIMD2<Float> {
        switch self {
        case .front: SIMD2(size.x, size.y)
        case .side: SIMD2(size.z, size.y)
        case .top: SIMD2(size.x, size.z)
        }
    }

    func area(size: SIMD3<Float>) -> Float {
        let extents = extents(size: size)
        return extents.x * extents.y
    }

    /// 这一面在本体坐标系里的屏幕四边形。
    ///
    /// 局部包围盒的约定来自生产：`WorldObjectState.generatedCollisionVolume` 把盒心放在
    /// `position.y + size.y/2`、半长是 `size/2`，也就是 **x/z 以落地点为中心、y 从 0 到 size.y**。
    /// 屏幕作为"物件上的一个面"必须与它同口径，否则屏幕会浮在半空。
    ///
    /// **铺满这一面**：半宽高 = 该面半尺寸 − `bezelMargin`（四边等宽的一圈边框余量）。
    /// 这里曾经是"该面半尺寸 × 0.86"（每边吃掉该轴 7%），真机上就是那块缩在正面中间的
    /// 暗矩形 —— 屏幕与它所在的**面**之间只该差一圈边框，不该差 14%。
    /// 四角仍然**派生**（`WorldScreenQuad.corners`），这里只给 中心 / 朝向 / 半宽高。
    func quad(size: SIMD3<Float>) -> WorldScreenQuad {
        let extents = extents(size: size)
        let margin = WorldScreenResolution.bezelMargin(
            faceWidth: extents.x, faceHeight: extents.y
        )
        switch self {
        case .front:
            return WorldScreenQuad(
                center: SIMD3<Float>(0, size.y / 2, size.z / 2 + WorldScreenResolution.surfaceOffset),
                yaw: 0, pitch: 0,
                halfWidth: extents.x / 2 - margin,
                halfHeight: extents.y / 2 - margin
            )
        case .side:
            return WorldScreenQuad(
                center: SIMD3<Float>(size.x / 2 + WorldScreenResolution.surfaceOffset, size.y / 2, 0),
                yaw: .pi / 2, pitch: 0,
                halfWidth: extents.x / 2 - margin,
                halfHeight: extents.y / 2 - margin
            )
        case .top:
            return WorldScreenQuad(
                center: SIMD3<Float>(0, size.y + WorldScreenResolution.surfaceOffset, 0),
                yaw: 0, pitch: .pi / 2,
                halfWidth: extents.x / 2 - margin,
                halfHeight: extents.y / 2 - margin
            )
        }
    }
}

/// 「最大平坦面 + 面积阈值 + 板形判据」这一级本身。
enum WorldScreenFaceInference {
    /// 面积最大的那一面。面积并列时按 `front > side > top` 定序（确定性）。
    static func largestFace(size: SIMD3<Float>) -> WorldScreenFace {
        let ordered: [WorldScreenFace] = [.front, .side, .top]
        var best = ordered[0]
        var bestArea = ordered[0].area(size: size)
        for face in ordered.dropFirst() {
            let area = face.area(size: size)
            if area > bestArea {
                best = face
                bestArea = area
            }
        }
        return best
    }

    /// 最薄轴 / 最长轴。板形判据与被拒绝时给用户的数字都是它。
    static func thinnestOverLongest(size: SIMD3<Float>) -> Float {
        let longest = max(size.x, max(size.y, size.z))
        let thinnest = min(size.x, min(size.y, size.z))
        guard longest.isFinite, thinnest.isFinite, longest > 0 else { return .infinity }
        return thinnest / longest
    }

    /// 判不出板形时，**这件道具自己的**哪一面当屏幕最少错：面积较大的**竖直面**
    /// （`front` = ±Z 正面，`side` = ±X 侧面）。面积并列 ⇒ 正面（与 `largestFace` 同序）。
    ///
    /// 这一条**只**服务于"已经判不出板形"的那一级，所以不会改变任何一块真板子的结论：
    /// 躺着的薄板板形成立，走的是 `largestFace`（正确地选中朝上的那一面）。
    static func defaultFace(size: SIMD3<Float>) -> WorldScreenFace {
        WorldScreenFace.front.area(size: size) >= WorldScreenFace.side.area(size: size)
            ? .front : .side
    }

    /// 判不出屏幕时的**具名**原因；判得出时 `nil`。
    ///
    /// 两条判据缺一不可：
    /// - **板形**：不要求薄边，一个方块柜子的每一面都够大，`largestFace` 就变成掷骰子；
    /// - **面积阈值**：20 cm 见方以下的面是零件，不是屏幕。
    static func rejection(size: SIMD3<Float>, objectID: String) -> WorldScreenGeometryIssue? {
        let longest = max(size.x, max(size.y, size.z))
        let thinnest = min(size.x, min(size.y, size.z))
        guard longest.isFinite, thinnest.isFinite, longest > 0 else {
            return .missingGeometry(objectID: objectID)
        }
        let ratio = thinnest / longest
        if ratio > WorldScreenResolution.maximumPanelThicknessRatio {
            return .notPanelLike(
                objectID: objectID,
                size: size,
                thinnestOverLongest: ratio,
                threshold: WorldScreenResolution.maximumPanelThicknessRatio
            )
        }
        let area = largestFace(size: size).area(size: size)
        if area < WorldScreenResolution.minimumFaceArea {
            return .belowAreaThreshold(objectID: objectID, largestFaceArea: area)
        }
        return nil
    }
}

/// 「这台物件是不是一台要装屏幕的电视」——缺省那一级的**唯一**入场券。
///
/// 这是一个**词法**判据，所以它必须可见：`WorldScreenResolution` 写出的 `note` 会说明
/// "按名称判定为屏幕候选"。用户/agent 也可以在面板里显式指定，绕过这个判据。
enum WorldScreenEligibility {
    private static let markers = [
        "tv", "television", "screen", "display", "monitor", "telly",
        "电视", "电视机", "屏幕", "显示器", "荧幕",
    ]

    static func isScreenCandidate(objectID: String, displayName: String) -> Bool {
        let haystack = (objectID + " " + displayName).lowercased()
        return markers.contains { haystack.contains($0) }
    }
}
