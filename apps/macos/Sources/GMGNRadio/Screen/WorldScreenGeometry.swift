import Foundation
import simd

// MARK: - 屏幕：物件上的一个面（本体坐标系）

/// 屏幕几何在物件 `metadata` 里的**唯一**键。
///
/// 与 `gmgn.prop-function-points.v1` / `gmgn.generated-prop.v1` 同一条路：派生块写进
/// `WorldObjectState.metadata`，不新建表、不新建文件格式、不新建第二种"物件上的东西"。
enum WorldScreenMetadataKey {
    /// 屏幕**在哪**（几何 + 出处）。编辑器标定写这个键。
    static let definition = "gmgn.screen.v1"
    /// 这一台电视**现在放什么**（内容）。与几何分开：生命周期不同，一个跟物件走，
    /// 一个跟"这台电视当前的状态"走。
    static let content = "gmgn.screen-content.v1"
}

/// 屏幕几何的**出处**。命中哪一级必须写进 `note`，不许无声无息地用缺省。
enum WorldScreenSource: String, Codable, Equatable, Sendable, CaseIterable {
    /// ① 用户/编辑器标定。
    case calibrated
    /// ② 由尺寸/网格推断出来的最大平坦面。
    case inferred
    /// ③ 缺省值（**必须**说"这是猜的"）。
    case `default`
}

/// 一件道具**本体坐标系**下的屏幕四边形。
///
/// 存的是 `中心 + 朝向 + 半宽高`，**四角是派生的**。为什么不存四角：存四角就能存出一个
/// 非平行四边形的"屏幕"，于是平面性与宽高比都变成需要额外校验的自由度，而屏幕的定义
/// 本该只有一处。派生保证"任意一组合法参数都恰好给出一个平面矩形"。
///
/// 坐标系与功能点同口径：原点 = 道具落地点，+Y 向上，只绕 Y 的摆放旋转。
struct WorldScreenQuad: Equatable, Sendable {
    /// 局部坐标下的屏幕中心。
    var center: SIMD3<Float>
    /// 屏幕平面绕 Y 的朝向（弧度，局部）。与 `WorldPropAnchorRegistry.worldPosition` 同口径。
    var yaw: Float
    /// 屏幕平面绕自身右轴的俯仰（弧度，局部）。挂墙向下倾为负。
    var pitch: Float
    var halfWidth: Float
    var halfHeight: Float

    /// 允许的几何范围。这些是**防御性**边界，不是产品上的限制。
    static let minimumHalfExtent: Float = 0.02
    static let maximumHalfExtent: Float = 5
    static let maximumCenterMagnitude: Float = 100

    init(
        center: SIMD3<Float>,
        yaw: Float = 0,
        pitch: Float = 0,
        halfWidth: Float,
        halfHeight: Float
    ) {
        self.center = center
        self.yaw = yaw
        self.pitch = pitch
        self.halfWidth = halfWidth
        self.halfHeight = halfHeight
    }

    var isValid: Bool {
        guard [center.x, center.y, center.z, yaw, pitch, halfWidth, halfHeight]
            .allSatisfy(\.isFinite)
        else { return false }
        guard abs(center.x) <= Self.maximumCenterMagnitude,
              abs(center.y) <= Self.maximumCenterMagnitude,
              abs(center.z) <= Self.maximumCenterMagnitude
        else { return false }
        guard abs(yaw) <= 4 * .pi, abs(pitch) <= .pi / 2 else { return false }
        guard halfWidth >= Self.minimumHalfExtent, halfWidth <= Self.maximumHalfExtent,
              halfHeight >= Self.minimumHalfExtent, halfHeight <= Self.maximumHalfExtent
        else { return false }
        return true
    }

    /// 宽高比（宽 / 高）。永远是正数：合法性已经保证半宽高为正。
    var aspect: Float { halfWidth / halfHeight }

    var width: Float { halfWidth * 2 }
    var height: Float { halfHeight * 2 }

    /// 局部右轴（单位向量）。与 `WorldPropAnchorRegistry.worldPosition` 的 yaw 口径逐字一致：
    /// 那里 `x' = pos.x + cos·x + sin·z`、`z' = pos.z - sin·x + cos·z`，代入局部 +X 即得。
    var right: SIMD3<Float> { SIMD3(cos(yaw), 0, -sin(yaw)) }

    /// 局部法向（屏幕正面朝向，单位向量）。未俯仰时就是局部 +Z。
    var normal: SIMD3<Float> {
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        return simd_normalize(forward * cos(pitch) + SIMD3<Float>(0, 1, 0) * sin(pitch))
    }

    /// 局部上轴（单位向量）＝ 世界 +Y 在屏幕平面内的分量。
    var up: SIMD3<Float> {
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        return simd_normalize(SIMD3<Float>(0, 1, 0) * cos(pitch) - forward * sin(pitch))
    }

    /// 四角，顺序固定 **BL, BR, TR, TL**（从左下起逆时针）。派生，不存。
    var corners: [SIMD3<Float>] {
        let r = right * halfWidth
        let u = up * halfHeight
        return [
            center - r - u,
            center + r - u,
            center + r + u,
            center - r + u,
        ]
    }

    /// 世界角点 = 摆放 transform ∘ 局部角点。用的是**既有**的局部→世界规则
    /// （只绕 Y 的旋转 + 平移，与功能点锚点、承托网格同一套），不另写一份。
    func worldCorners(placedAt position: SIMD3<Float>, yaw placementYaw: Float) -> [SIMD3<Float>] {
        corners.map { WorldScreenPlacement.worldPosition(of: $0, placedAt: position, yaw: placementYaw) }
    }

    /// 世界法向（把局部法向按摆放 yaw 转过去）。
    func worldNormal(yaw placementYaw: Float) -> SIMD3<Float> {
        let local = normal
        let rotated = WorldScreenPlacement.worldPosition(
            of: local, placedAt: SIMD3<Float>(0, 0, 0), yaw: placementYaw
        )
        return simd_normalize(rotated)
    }

    /// 世界中心。
    func worldCenter(placedAt position: SIMD3<Float>, yaw placementYaw: Float) -> SIMD3<Float> {
        WorldScreenPlacement.worldPosition(of: center, placedAt: position, yaw: placementYaw)
    }
}

/// 局部 → 世界的**唯一**规则。与 `WorldPropAnchorRegistry.worldPosition` 逐字同式。
///
/// 为什么不直接调那一个：那一份在 `WorldRuntime` 包里，而本文件刻意**不依赖任何包**
/// （几何/投影要能被离线 harness 直接编译）。两处算式的一致性由
/// `tools/test-resident-screen-overlay.swift` 的"生产源码原文比对"钉住：任何一处漂移都会红。
enum WorldScreenPlacement {
    static func worldPosition(
        of local: SIMD3<Float>,
        placedAt position: SIMD3<Float>,
        yaw: Float
    ) -> SIMD3<Float> {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return SIMD3<Float>(
            position.x + cosine * local.x + sine * local.z,
            position.y + local.y,
            position.z - sine * local.x + cosine * local.z
        )
    }
}

// MARK: - 屏幕定义（落盘的那一份）

/// `metadata["gmgn.screen.v1"]` 的载荷：屏幕**在哪** + **这个答案是怎么来的**。
///
/// `note` 是**必填**且在类型层强制非空：一条说不出出处的屏幕定义根本构造不出来。
/// 这就是"不确定就说不猜"的落地方式 —— 不靠自觉，靠类型。
struct WorldScreenDefinition: Equatable, Sendable, Codable {
    static let maximumNoteLength = 240

    let objectID: String
    let source: WorldScreenSource
    let quad: WorldScreenQuad
    /// 给人看的一句：这一组几何是**怎么来的**。空串 = 非法。
    let note: String

    init(objectID: String, source: WorldScreenSource, quad: WorldScreenQuad, note: String) {
        self.objectID = objectID
        self.source = source
        self.quad = quad
        self.note = note
    }

    var isValid: Bool {
        !objectID.isEmpty
            && objectID.count <= 256
            && quad.isValid
            && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.count <= Self.maximumNoteLength
    }

    /// 「这台电视的几何不是标定值」的可见标记。面板与 agent 回执都读它，
    /// 于是"猜的"这件事在**两个面上**都看得见。
    var isProvisional: Bool { source != .calibrated }

    private enum CodingKeys: String, CodingKey {
        case objectID, source, center, yaw, pitch, halfWidth, halfHeight, note
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try container.decode(String.self, forKey: .objectID)
        source = try container.decodeIfPresent(WorldScreenSource.self, forKey: .source) ?? .calibrated
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        let raw = try container.decodeIfPresent([Float].self, forKey: .center) ?? []
        guard raw.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .center, in: container,
                debugDescription: "屏幕中心必须是三个数的数组"
            )
        }
        quad = WorldScreenQuad(
            center: SIMD3<Float>(raw[0], raw[1], raw[2]),
            yaw: try container.decodeIfPresent(Float.self, forKey: .yaw) ?? 0,
            pitch: try container.decodeIfPresent(Float.self, forKey: .pitch) ?? 0,
            halfWidth: try container.decode(Float.self, forKey: .halfWidth),
            halfHeight: try container.decode(Float.self, forKey: .halfHeight)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectID, forKey: .objectID)
        try container.encode(source, forKey: .source)
        try container.encode([quad.center.x, quad.center.y, quad.center.z], forKey: .center)
        try container.encode(quad.yaw, forKey: .yaw)
        try container.encode(quad.pitch, forKey: .pitch)
        try container.encode(quad.halfWidth, forKey: .halfWidth)
        try container.encode(quad.halfHeight, forKey: .halfHeight)
        try container.encode(note, forKey: .note)
    }
}

/// 「这块屏幕为什么给不出来」的**具名**原因。一条都不许静默。
enum WorldScreenGeometryIssue: Error, Equatable, Sendable {
    /// 既没有标定，也没有能推断的尺寸，连缺省都给不出 ⇒ 不猜。
    case missingGeometry(objectID: String)
    /// 有尺寸，但这件东西不像一块板（最薄轴 > 最长轴的 1/4），"最大面"就是掷骰子。
    ///
    /// 三边、比值与**当时用的阈值**都是**载荷**而不是备注：用户看到"不像一块屏幕"时
    /// 要能当场复核（"1.44 × 0.90 × 1.44 m，0.62 > 0.25"），否则这句话与"我觉得不行"
    /// 没区别。阈值跟着载荷走而不是在这里引用 `WorldScreenResolution`：这一份是几何层，
    /// 不该反过来依赖推断层。
    case notPanelLike(
        objectID: String, size: SIMD3<Float>, thinnestOverLongest: Float, threshold: Float
    )
    /// 有尺寸，但最大面比阈值还小（低于 0.04 m²）。
    case belowAreaThreshold(objectID: String, largestFaceArea: Float)
    /// 标定块存在但非法（字段缺失 / 非有限 / 半宽高为 0）。
    case invalidCalibration(objectID: String)

    /// 给用户/agent 的**一句**人话。与面板那一行是同一份。
    ///
    /// 每个分支都显式 `return`：只要有一支要多条语句，隐式返回就不成立（实测会退化成
    /// "string literal is unused" 的警告 + 类型检查器报错）。
    var errorDescription: String {
        switch self {
        case let .missingGeometry(objectID):
            return "「\(objectID)」还没有屏幕：既没有标定，也没有可推断的尺寸。请在面板里标定宽高。"
        case let .notPanelLike(objectID, size, ratio, threshold):
            // 拆成几个 `let` 再拼：一整条 `String(format:)` 串起来的表达式会把
            // 类型检查器拖爆（实测 "unable to type-check this expression in reasonable time"）。
            let dimensions = String(format: "%.2f × %.2f × %.2f m", size.x, size.y, size.z)
            let measured = String(format: "%.2f", ratio)
            let limit = String(format: "%.2f", threshold)
            return "「\(objectID)」不像一块屏幕：三边 \(dimensions) 里没有明显薄的那一边"
                + "（最薄/最长 = \(measured) > \(limit)），最大面说明不了屏幕在哪。请手动标定。"
        case let .belowAreaThreshold(objectID, area):
            return "「\(objectID)」最大的一面只有 \(String(format: "%.3f", area)) m²，"
                + "小于 0.04 m² 的阈值，不算屏幕。请手动标定。"
        case let .invalidCalibration(objectID):
            return "「\(objectID)」的屏幕标定块读不出来（字段缺失或数值非法）。请在面板里重新标定。"
        }
    }
}

/// 「这些字节是不是一份合法的屏幕定义」——**唯一**的解码入口。
///
/// 世界状态里的读取器（`WorldScreenMetadata.swift`）与面板/工具的写入校验都走它，
/// 于是"合法"只有一处定义。
enum WorldScreenDefinitionCoding {
    /// 解码 + 校验 + **自称核对**：生成道具的声明必须自称是这一件。
    static func decode(_ json: String, expecting objectID: String?) -> WorldScreenDefinition? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldScreenDefinition.self, from: data),
              value.isValid
        else { return nil }
        if let objectID, value.objectID != objectID { return nil }
        return value
    }

    static func encode(_ definition: WorldScreenDefinition) -> String? {
        guard definition.isValid, let data = try? JSONEncoder().encode(definition) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
