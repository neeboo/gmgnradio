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
    /// 推断出的屏幕相对该面留的边框比例（面板边框）。
    static let panelInset: Float = 0.86
    /// 屏幕面相对包围盒表面外移的一点点，避免与自身表面共面闪烁。
    static let surfaceOffset: Float = 0.001

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
                // 有尺寸但判不出屏幕：只有调用方明确声明是电视时才给缺省，且缺省必须
                // 把"为什么没走推断"写出来。
                guard allowsDefault else {
                    return .failure(rejection)
                }
                return .success(
                    defaultDefinition(
                        objectID: objectID,
                        extraReason: "（这件道具判不出屏幕：\(rejection.errorDescription)）"
                    )
                )
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
        let note = String(
            format: "由最大平坦面推断：法向 %@，面积 %.3f m²（%.2f m × %.2f m）。不是标定值，可在面板里改。",
            face.normalName, area, quad.width, quad.height
        )
        return WorldScreenDefinition(
            objectID: objectID, source: .inferred, quad: quad, note: note
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

    func area(size: SIMD3<Float>) -> Float {
        switch self {
        case .front: size.x * size.y
        case .side: size.z * size.y
        case .top: size.x * size.z
        }
    }

    /// 这一面在本体坐标系里的屏幕四边形。
    ///
    /// 局部包围盒的约定来自生产：`WorldObjectState.generatedCollisionVolume` 把盒心放在
    /// `position.y + size.y/2`、半长是 `size/2`，也就是 **x/z 以落地点为中心、y 从 0 到 size.y**。
    /// 屏幕作为"物件上的一个面"必须与它同口径，否则屏幕会浮在半空。
    func quad(size: SIMD3<Float>) -> WorldScreenQuad {
        switch self {
        case .front:
            WorldScreenQuad(
                center: SIMD3<Float>(0, size.y / 2, size.z / 2 + WorldScreenResolution.surfaceOffset),
                yaw: 0, pitch: 0,
                halfWidth: size.x / 2 * WorldScreenResolution.panelInset,
                halfHeight: size.y / 2 * WorldScreenResolution.panelInset
            )
        case .side:
            WorldScreenQuad(
                center: SIMD3<Float>(size.x / 2 + WorldScreenResolution.surfaceOffset, size.y / 2, 0),
                yaw: .pi / 2, pitch: 0,
                halfWidth: size.z / 2 * WorldScreenResolution.panelInset,
                halfHeight: size.y / 2 * WorldScreenResolution.panelInset
            )
        case .top:
            WorldScreenQuad(
                center: SIMD3<Float>(0, size.y + WorldScreenResolution.surfaceOffset, 0),
                yaw: 0, pitch: .pi / 2,
                halfWidth: size.x / 2 * WorldScreenResolution.panelInset,
                halfHeight: size.z / 2 * WorldScreenResolution.panelInset
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
        if thinnest / longest > WorldScreenResolution.maximumPanelThicknessRatio {
            return .notPanelLike(objectID: objectID)
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
