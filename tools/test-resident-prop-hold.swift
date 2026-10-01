// 手持（grip + 手骨跟随）的判据。
//
// 读生产源码 → 切出**真的**那几段（`PropGripInference` / `PropAttachmentMatrix` /
// `WorldPropRotation`）→ 编译 → 跑 → 逐条负对照证明判据真的会红。
//
// 为什么是"切片"而不是"另写一份等价实现"：另写一份的话，判据测的是我抄的那一份，
// 生产代码坏了门禁也不会红 —— 那正是这个仓库反复踩过的"门禁从不 FAIL"。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func readSource(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}

func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL:", message); exit(1) }
}

/// 从源码里切出 `signature` 开头的那**一个**花括号块（含嵌套）。
/// `occurrence` 用来取第 n 次出现（`orientedBounds` 有两个重载）。
func declaration(_ source: String, _ signature: String, occurrence: Int = 1) -> String? {
    var searchStart = source.startIndex
    var found: Range<String.Index>?
    for _ in 0..<occurrence {
        guard let range = source.range(of: signature, range: searchStart..<source.endIndex) else {
            return nil
        }
        found = range
        searchStart = range.upperBound
    }
    guard let start = found?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[start...index]) }
        }
    }
    return nil
}

/// 走遍生产源码树，返回所有 `.swift` 的相对路径。
func swiftFiles(under relative: String) -> [String] {
    let base = root.appendingPathComponent(relative)
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
        return []
    }
    var result: [String] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        result.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
    }
    return result.sorted()
}

/// 「谁在定义一个握点」。判据与负对照共用**同一个**函数 —— 负对照注入之后必须数得出第二份。
///
/// 两样都算"一处来源"：手写出来的那组数字（`inheritedNormalizedGrip` 那个字面量），
/// 以及任何**内联**写出比例的 `normalizedGrip: WorldVector3(...)`。引用一份已有的标定
/// （`suggestion.normalizedGrip` / `existing.normalizedGrip`）不算 —— 那正是"只有一处"的意思。
func gripDefinitionFiles(in files: [String], overrides: [String: String] = [:]) throws -> [String] {
    var hits: [String] = []
    for file in files {
        let text: String
        if let override = overrides[file] {
            text = override
        } else {
            text = try readSource(file)
        }
        if text.contains("WorldVector3(x: 0.5, y: 0.2, z: 0.5)")
            || text.contains("normalizedGrip: WorldVector3(") {
            hits.append(file)
        }
    }
    return hits
}

/// 「这段代码有没有写骨骼/节点的变换」。负对照共用。
func writesTransforms(_ text: String) -> Bool {
    ["simdWorldTransform =", "simdTransform =", "simdPosition =",
     "simdOrientation =", "simdScale =", "eulerAngles ="].contains { text.contains($0) }
}

// ---------------------------------------------------------------------------
// 生产源码
// ---------------------------------------------------------------------------
let gripPath = "apps/macos/Sources/GMGNRadio/Presence/PropGripInference.swift"
let attachmentPath = "apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift"
let slotPath = "apps/macos/Sources/GMGNRadio/Presence/PropAttachmentSlot.swift"
let placementPath = "apps/macos/Sources/GMGNRadio/Presence/ResidentPropPlacementService.swift"
let pmxPath = "apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift"
let marblePath = "apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift"
let orientationPath = "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropOrientation.swift"
let sizePolicyPath = "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropSizePolicy.swift"

let gripSource = try readSource(gripPath)
let attachmentSource = try readSource(attachmentPath)
let slotSource = try readSource(slotPath)
let placementSource = try readSource(placementPath)
let pmxSource = try readSource(pmxPath)
let marbleSource = try readSource(marblePath)
let orientationSource = try readSource(orientationPath)
let sizePolicySource = try readSource(sizePolicyPath)

// ---------------------------------------------------------------------------
// 【断言 3】grip 只有一处定义，且可被用户调整覆盖
// ---------------------------------------------------------------------------
let definitionFiles = try gripDefinitionFiles(in: swiftFiles(under: "apps/macos/Sources/GMGNRadio"))
check(definitionFiles == [gripPath],
      "握点缺省必须只有一处定义（\(gripPath)），实测 \(definitionFiles)")

// 负对照：往**源码副本**里塞第二处来源 ⇒ 上面那条判据必须数得出两份。
// 注入点放在挂点表上：那正是"手那套缺省被抄到第二个地方"最可能发生的地方。
let secondSourceCopy = slotSource.replacingOccurrences(
    of: "case .back, .waist: WorldVector3(x: 0.5, y: 0.5, z: 0.5)",
    with: "case .back, .waist: WorldVector3(x: 0.5, y: 0.2, z: 0.5)   // normalizedGrip: WorldVector3(x:"
)
check(secondSourceCopy != slotSource, "负对照的注入点失效了（挂点表里那句默认握点找不到了）")
let injectedDefinitions = try gripDefinitionFiles(
    in: swiftFiles(under: "apps/macos/Sources/GMGNRadio"),
    overrides: [slotPath: secondSourceCopy]
)
check(injectedDefinitions.count == 2,
      "负对照失败：注入第二处握点来源之后判据居然还是 \(injectedDefinitions.count) 处")

// ---------------------------------------------------------------------------
// 【断言 3b】握点说明必须**可见**：接回"已按主轴摆正"那条既有 notice 通道
//
// `PropGripSuggestion.notice` 被算出来、被断言，但生产路径上原来没有任何地方显示它
// （`suggestedCalibration` 只取 normalizedGrip/localOffset/localRotation）——
// 于是"推断不出 grip ⇒ 有可见说明"这条要求**不成立**。这里钉的就是那条接线。
// ---------------------------------------------------------------------------
let appPath = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
let appSource = try readSource(appPath)

/// 「握点推断说了什么，用户看得见吗」。判据与负对照共用**同一个**函数。
/// 看得见 = 那句话被写进**既有那一条**通道（`orientationNotices[job.objectID]` →
/// 末尾统一 `residentPropNotices[objectID] = message` + `showResidentVoiceStatus`），
/// 而不是存在某个没人读的变量里、也不是另开第二条 notice 通道。
func gripNoticeIsVisible(in source: String) -> Bool {
    guard let marker = source.range(
        of: "ResidentPropAttachmentEligibility.suggestedGripNotice(for:") else { return false }
    let tail = source[marker.upperBound...].prefix(400)
    return tail.split(separator: "\n").contains {
        $0.contains("orientationNotices[job.objectID] =") && $0.contains("gripNotice")
    }
}

/// 「说明是不是就只有 `PropGripInference` 那一个出口」。
func gripNoticeIsSingleSource(_ source: String) -> Bool {
    declaration(source, "static func suggestedGripNotice(")?
        .contains("PropGripInference.suggestion(for: prop).notice") == true
}

check(gripNoticeIsSingleSource(attachmentSource),
      "握点说明必须原样取自 `PropGripInference.suggestion(for:)`（不另写一份说明）")
let reimplementedSource = attachmentSource.replacingOccurrences(
    of: "PropGripInference.suggestion(for: prop).notice",
    with: "\"网格最长边推断完成\"")
check(!gripNoticeIsSingleSource(reimplementedSource),
      "负对照失败：把说明换成另写的一句之后判据居然还认")

check(gripNoticeIsVisible(in: appSource),
      "生产路径必须把握点说明接回既有的可见通道（`orientationNotices[job.objectID]`），否则算出来也没人看得见")
check(appSource.contains("for (objectID, message) in orientationNotices.sorted"),
      "`orientationNotices` 必须仍然是那条既有可见通道的出口（本判据依赖它）")
check(appSource.contains("residentPropNotices[objectID] = message")
      && appSource.contains("showResidentVoiceStatus(message)"),
      "可见通道的终点必须还是 `residentPropNotices` + `showResidentVoiceStatus`")

// 负对照：把"写进通道"那一行删掉（= 算出来又丢掉）⇒ 判据必须红。
let droppedNoticeSource = appSource.replacingOccurrences(
    of: "orientationNotices[job.objectID] = prefix + gripNotice",
    with: "_ = gripNotice")
check(droppedNoticeSource != appSource,
      "负对照的前提没了：生产源码里找不到 `orientationNotices[job.objectID] = prefix + gripNotice` 这一行")
check(!gripNoticeIsVisible(in: droppedNoticeSource),
      "负对照失败：注入「丢掉 notice」之后判据居然还说它可见")

// 用户覆盖：`adjustGrip` 必须**保留**已有握点、只换用户拖出来的偏移与朝向。
let adjustBody = declaration(placementSource, "func adjustGripCommand(")
check(adjustBody?.contains("normalizedGrip: existing.normalizedGrip") == true,
      "adjustGripCommand 必须沿用已存档的 normalizedGrip（握点只有一个权威出口）")
check(adjustBody?.contains("localOffset: localOffset") == true
      && adjustBody?.contains("localRotation: localRotation") == true,
      "adjustGripCommand 必须让用户的偏移/朝向覆盖推断值")

// ---------------------------------------------------------------------------
// 【断言 2】只读骨骼：手持不修改任何骨骼变换
// ---------------------------------------------------------------------------
let handPoseBody = declaration(pmxSource, "func evaluatedAttachmentPose(")
check(handPoseBody?.contains("bone.presentation.simdWorldTransform") == true,
      "evaluatedAttachmentPose 必须读 presentation 上的**求值后**骨骼世界变换")
check(handPoseBody.map { !writesTransforms($0) } == true,
      "evaluatedAttachmentPose 里出现了变换写入 —— 手持绝不能反过来改动画")

let heldRenderBody = declaration(marbleSource, "private func renderResidentHeldProp(")
check(heldRenderBody != nil, "找不到 renderResidentHeldProp")
check(heldRenderBody.map { !writesTransforms($0) } == true,
      "renderResidentHeldProp 里出现了变换写入 —— 手持绝不能反过来改动画")

// 负对照：给源码副本塞一行写骨骼 ⇒ 同一个函数必须报"有写入"。
let boneWriteCopy = (handPoseBody ?? "") + "\n        bone.simdWorldTransform = matrix_identity_float4x4"
check(writesTransforms(boneWriteCopy),
      "负对照失败：注入写骨骼之后 writesTransforms 居然没看出来")

// ---------------------------------------------------------------------------
// 【断言 4】找不到手骨 / grip 缺失 ⇒ 可见失败
// ---------------------------------------------------------------------------
let failureBranchCount = heldRenderBody.map {
    $0.components(separatedBy: "= .failed(").count - 1
} ?? 0
check(failureBranchCount == 3,
      "renderResidentHeldProp 必须有三条**可见**失败（角色不符 / 渲染器缺失 / 抛错），实测 \(failureBranchCount)")

// 负对照：把 catch 里的上报换成静默 return ⇒ 判据必须发现少了一条。
let silentCopy = (heldRenderBody ?? "").replacingOccurrences(of: "= .failed(", with: "= .ignored(")
check((silentCopy.components(separatedBy: "= .failed(").count - 1) != 3,
      "负对照失败：把三条可见失败抹掉之后判据居然还是三条")

check(attachmentSource.contains("case missingBone(")
      && attachmentSource.contains("缺少右手骨骼")
      && attachmentSource.contains("没有可用的腰部骨骼")
      && attachmentSource.contains("没有可用的背后骨骼"),
      "找不到挂点骨骼必须有读得懂的中文失败（点名是哪个挂点、找过哪些骨名），而不是静默变成「没拿着」")

// 负对照：握点推断的"读不出来"那条路不许静默。
check(gripSource.contains("replacing(fallback, notice: unreadableSizeNotice)"),
      "尺寸读不出来那条路必须带上可见说明，不许静默退回缺省")

// ---------------------------------------------------------------------------
// 【断言 5 的前置】复用同一个"多细算细长"的数，不另立一份
// ---------------------------------------------------------------------------
check(sizePolicySource.contains("longThinAspectLimit: Float = 4"),
      "WorldPropSizePolicy.longThinAspectLimit 必须还是 4（握点复用的就是它）")
check(orientationSource.contains("lyingDownAspectLimit: Float = WorldPropSizePolicy.longThinAspectLimit"),
      "朝向与尺寸必须共用同一个细长门槛")

// ---------------------------------------------------------------------------
// 编译真代码
// ---------------------------------------------------------------------------
guard let poseDeclaration = declaration(attachmentSource, "enum PropAttachmentPose"),
      let matrixDeclaration = declaration(attachmentSource, "enum PropAttachmentMatrix"),
      let pointDeclaration = declaration(attachmentSource, "enum PropAttachmentPoint"),
      let descriptorDeclaration = declaration(attachmentSource, "struct ResidentHeldPropDescriptor"),
      let errorDeclaration = declaration(attachmentSource, "enum PropAttachmentError"),
      let slotPointDeclaration = declaration(slotSource, "extension PropAttachmentPoint"),
      let slotTableDeclaration = declaration(slotSource, "enum PropAttachmentSlots"),
      let rotationDeclaration = declaration(orientationSource, "public enum WorldPropRotation"),
      let quaternionExtension = declaration(orientationSource, "public extension WorldQuaternion"),
      let orientedBoundsDeclaration = declaration(orientationSource, "public static func orientedBounds(", occurrence: 2)
else {
    print("FAIL: 切不出需要的那几段真代码（切片签名变了？）")
    exit(1)
}

let stubs = #"""
import Foundation
import simd

struct WorldVector3: Codable, Equatable, Hashable, Sendable {
    let x: Float; let y: Float; let z: Float
}
struct WorldQuaternion: Codable, Equatable, Hashable, Sendable {
    let x: Float; let y: Float; let z: Float; let w: Float
}
enum WorldPropSlot: String, Codable, Equatable, Sendable {
    case rightHand
    case back
    case waist
}
/// 旧名：与生产同一个兼容别名（`WorldRuntime` 里那条 typealias）。
typealias WorldPropHand = WorldPropSlot

struct WorldPropGripCalibration: Codable, Equatable, Sendable {
    let avatarAssetID: String
    let hand: WorldPropHand
    let normalizedGrip: WorldVector3
    let localOffset: WorldVector3
    let localRotation: WorldQuaternion
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

/// 只留 `PropGripInference` 真正读的那两个出口 —— 尺寸只有一个权威出口（`effectiveSize`），
/// 朝向只有一个出口（`orientationRotation`）。真实的 `WorldGeneratedProp` 也是这么定义的。
struct WorldGeneratedProp: Codable, Equatable, Sendable {
    let objectID: String
    let assetID: String
    let displayName: String
    let size: WorldVector3
    let sourceHeight: Float
    var orientationRotation: WorldQuaternion = .identity
    var effectiveSize: WorldVector3 { size }
    var isValid: Bool {
        [size.x, size.y, size.z, sourceHeight].allSatisfy { $0.isFinite && $0 > 0 }
    }
}

/// 与生产同名同值；harness 另外用源码断言钉住那个字面量。
enum WorldPropSizePolicy { static let longThinAspectLimit: Float = 4 }
/// 与生产同名同值；harness 另外用源码断言钉住那个字面量。
enum ResidentPropAttachmentEligibility { static let supportedAvatarID = "pmx.2b-miss-0414-standard" }

enum WorldPropOrientationPolicy {
\#(orientedBoundsDeclaration)
}

/// 判据本体的断言。**必须与 harness 自己那一份同名同义** —— 两处都红才算真的红。
func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL:", message); exit(1) }
}
"""#

let orientationSlice = #"""
import Foundation
import simd

\#(quaternionExtension)

\#(rotationDeclaration)
"""#
    // 切出来的真代码是 `public` 的，而 harness 里的替身类型是 internal 的 ——
    // 去掉 `public` 只为让两者能同处一个模块，**不改任何一行几何**。
    .replacingOccurrences(of: "public ", with: "")

let attachmentSlice = #"""
import Foundation
import simd

\#(pointDeclaration)

\#(slotPointDeclaration)

\#(descriptorDeclaration)

\#(errorDeclaration)

\#(poseDeclaration)

\#(matrixDeclaration)

\#(slotTableDeclaration)
"""#

let gripSlice = gripSource.replacingOccurrences(of: "import WorldRuntime", with: "")

let checks = #"""
import Foundation
import simd

@main struct Checks {
    static func main() throws {
        // 真机数据：那把「2B 白色长剑」。
        // 原始网格 AABB = 1.005(X) × 0.133(Y) × 0.057(Z) m —— **躺着**的，最长轴在 X。
        // 摆正之后（`WorldPropOrientationPolicy.infer`：绕 +Z 转 +90°）变成立着的一把，
        // 最终世界尺寸是 0.1462 × 1.1 × 0.0624（1.1 m 的剑）。
        let swordSize = WorldVector3(x: 0.1462, y: 1.1, z: 0.0624)
        let upright = WorldPropRotation.axisAngle(axis: SIMD3<Float>(0, 0, 1), angle: .pi / 2)

        // ---- 方向正确性：摆正旋转确实把原始 X 转到世界 Y ----
        let rotatedX = WorldPropRotation.rotate(SIMD3<Float>(1, 0, 0), by: upright)
        check(abs(rotatedX.y - 1) < 0.0001, "摆正旋转必须把原始 X 轴转到 +Y（实测 \(rotatedX)）")
        check(PropGripInference.rawAxisCarrying(1, orientation: upright) == 0,
              "摆正后最长的那根轴（Y）必须翻回原始网格的 X 轴")

        // ---- 推断出来的握点 ----
        let suggestion = PropGripInference.suggestion(size: swordSize, orientation: upright)
        check(suggestion.origin == .meshPrincipalAxis,
              "1.1 m 的剑（比值 7.52）必须走「按网格主轴推断」，实测 \(suggestion.origin.rawValue)")
        check(abs(suggestion.normalizedGrip.x - 0.054545) < 0.001,
              "握点必须落在**剑柄那一端**（X ≈ 0.055），实测 \(suggestion.normalizedGrip.x)")
        check(suggestion.normalizedGrip.y == 0.5 && suggestion.normalizedGrip.z == 0.5,
              "两个次轴必须在中间")
        check(suggestion.normalizedGrip.x < 0.25,
              "握点绝不能还停在剑身中间（改造前是 0.5）")
        check(suggestion.isValid, "推断出来的握点自己必须合法")
        check(suggestion.notice != nil, "细长物件的推断必须留下可见说明")

        // ---- 既有物件逐字节不变 ----
        let coffeeMachine = WorldVector3(x: 0.3, y: 0.26, z: 0.28)
        let inherited = PropGripInference.suggestion(size: coffeeMachine)
        check(inherited.origin == .inheritedDefault && inherited.notice == nil,
              "不细长的物件必须走缺省那条路且不加说明")
        check(inherited.normalizedGrip == PropGripInference.inheritedNormalizedGrip,
              "不细长的物件必须**逐字节**拿到改造前那组数 (0.5, 0.2, 0.5)")
        check(inherited.normalizedGrip == WorldVector3(x: 0.5, y: 0.2, z: 0.5),
              "改造前的缺省就是 (0.5, 0.2, 0.5)")

        // ---- 【断言 4】grip 缺失 ⇒ 可见失败，不是静默 ----
        let unreadable = PropGripInference.suggestion(size: WorldVector3(x: 0, y: 1, z: 1))
        check(unreadable.notice == PropGripInference.unreadableSizeNotice,
              "尺寸读不出来必须带上**可见说明**")
        check(PropGripInference.rawAxisCarrying(1, orientation: WorldQuaternion(x: 0, y: 0, z: 0, w: 0)) == nil,
              "退化的摆正旋转必须报「说不清」(nil)，不许猜一根轴出来")
        check(PropGripInference.bladeAxisInHandSpace(size: WorldVector3(x: -1, y: 1, z: 1),
                                                     orientation: upright,
                                                     localRotation: PropGripInference.identityRotation) == nil,
              "尺寸非法时刃轴必须报 nil（不是零向量）")
        check(PropAttachmentError.missingBone(.rightHand).errorDescription?.contains("右手骨骼") == true,
              "找不到手骨必须有一条读得懂的中文失败")
        check(PropAttachmentError.missingBone(.waist).errorDescription?.contains("腰部骨骼") == true,
              "找不到腰骨必须点名**腰部**骨骼（不能一律说成手）")
        check(PropAttachmentError.missingBone(.back).errorDescription?.contains("背后骨骼") == true,
              "找不到背骨必须点名**背后**骨骼")
        check(PropAttachmentPoint.rightHand.boneNameCandidates == ["右手首", "bone009"],
              "手骨名字就是 PMX 里的日文字面量（右手首），没有映射层")

        // ---- 【断言 1】物件世界变换 = 手骨世界变换 × grip ----
        // 原始网格 AABB（躺着的那把剑），单位与 GLB 一致。
        let minimum = SIMD3<Float>(-0.5025, -0.0665, -0.0285)
        let maximum = SIMD3<Float>(0.5025, 0.0665, 0.0285)
        let calibration = WorldPropGripCalibration(
            avatarAssetID: "pmx.2b-miss-0414-standard", hand: .rightHand,
            normalizedGrip: suggestion.normalizedGrip,
            localOffset: suggestion.localOffset,
            localRotation: suggestion.localRotation
        )
        let descriptor = ResidentHeldPropDescriptor(
            objectID: "prop", worldID: "world", assetID: "sha",
            modelURL: URL(fileURLWithPath: "/tmp/sword.glb"),
            targetHeightMeters: 1.1, attachmentPoint: .rightHand,
            calibration: calibration, orientation: upright
        )

        // 会动的手骨：两帧不同的旋转 + 平移。
        func handPose(yaw: Float, pitch: Float, translation: SIMD3<Float>) -> simd_float4x4 {
            let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
            var matrix = simd_float4x4(rotation)
            matrix.columns.3 = SIMD4<Float>(translation, 1)
            return matrix
        }
        let poseOne = handPose(yaw: 0.35, pitch: 0.2, translation: SIMD3<Float>(0.4, 1.2, 0.3))
        let poseTwo = handPose(yaw: -1.1, pitch: -0.45, translation: SIMD3<Float>(0.9, 1.35, -0.2))

        let first = try PropAttachmentMatrix.transform(
            minimum: minimum, maximum: maximum, descriptor: descriptor, handPose: poseOne)
        let second = try PropAttachmentMatrix.transform(
            minimum: minimum, maximum: maximum, descriptor: descriptor, handPose: poseTwo)

        // (a) 跟着手骨动
        let movedBy = simd_length(SIMD3<Float>(second.columns.3.x - first.columns.3.x,
                                              second.columns.3.y - first.columns.3.y,
                                              second.columns.3.z - first.columns.3.z))
        check(movedBy > 0.1, "手骨动了这么远，手里的剑必须跟着动（实测位移 \(movedBy) m）")

        // (b) 相对位姿不变：pose⁻¹ · object 两帧必须逐元素相同
        let relativeOne = simd_inverse(poseOne) * first
        let relativeTwo = simd_inverse(poseTwo) * second
        let relativeDrift = (0..<4).flatMap { column in
            (0..<4).map { row in
                abs(relativeOne[column][row] - relativeTwo[column][row])
            }
        }.max() ?? .infinity
        check(relativeDrift < 0.0001,
              "相对位姿必须不随手骨移动而变（两帧最大差 \(relativeDrift)）")

        // (c) **判据本体**：剑尖世界方向 = 手骨世界旋转 · 刃轴（手骨局部 +Y），角度贴数字。
        let gripPoint = minimum + (maximum - minimum) * SIMD3<Float>(
            calibration.normalizedGrip.x, calibration.normalizedGrip.y, calibration.normalizedGrip.z)
        let tipPoint = gripPoint + SIMD3<Float>(0.4, 0, 0)   // 沿原始 +X（柄 → 尖）
        func worldPoint(_ matrix: simd_float4x4, _ local: SIMD3<Float>) -> SIMD3<Float> {
            let value = matrix * SIMD4<Float>(local, 1)
            return SIMD3<Float>(value.x, value.y, value.z)
        }
        let gripWorld = worldPoint(first, gripPoint)
        let tipWorld = worldPoint(first, tipPoint)
        let bladeWorld = simd_normalize(tipWorld - gripWorld)
        let poseRotation = simd_float3x3(
            SIMD3<Float>(poseOne.columns.0.x, poseOne.columns.0.y, poseOne.columns.0.z),
            SIMD3<Float>(poseOne.columns.1.x, poseOne.columns.1.y, poseOne.columns.1.z),
            SIMD3<Float>(poseOne.columns.2.x, poseOne.columns.2.y, poseOne.columns.2.z)
        )
        let expected = simd_normalize(poseRotation * PropGripInference.bladeDirectionInHandSpace)
        let bladeCosine = simd_dot(bladeWorld, expected)
        let bladeDegrees = acos(max(-1, min(1, bladeCosine))) * 180 / .pi
        check(bladeDegrees < 1.0,
              "剑尖必须沿手骨骨轴出拳：与「手骨世界旋转 · (0,1,0)」夹角实测 \(bladeDegrees)°")
        // 握点必须落在手骨原点上（差一个 localOffset，这里是 0）。
        check(simd_length(gripWorld - SIMD3<Float>(poseOne.columns.3.x, poseOne.columns.3.y,
                                                  poseOne.columns.3.z)) < 0.001,
              "握点必须被放到手骨原点上")

        // (d) 负对照「不跟」：把手骨换成单位阵，两帧就分不出来了 ⇒ (a) 必须红。
        let frozenOne = try PropAttachmentMatrix.transform(
            minimum: minimum, maximum: maximum, descriptor: descriptor,
            handPose: matrix_identity_float4x4)
        let frozenTwo = try PropAttachmentMatrix.transform(
            minimum: minimum, maximum: maximum, descriptor: descriptor,
            handPose: matrix_identity_float4x4)
        check(frozenOne.columns.3 == frozenTwo.columns.3,
              "负对照失败：不跟手骨时两帧居然还不同")

        // (e) 负对照「打横」：网格躺着且**没有**被摆正（就是改造前那把剑）时，
        //     若刃朝向不校准，剑身会横在手里 —— 与骨轴夹角 90°。
        let lying = PropGripInference.suggestion(size: WorldVector3(x: 1.1, y: 0.1462, z: 0.0624))
        check(lying.origin == .meshPrincipalAxis, "躺着的细长物件同样要走主轴那条路")
        let alignedAxis = PropGripInference.bladeAxisInHandSpace(
            size: WorldVector3(x: 1.1, y: 0.1462, z: 0.0624),
            orientation: PropGripInference.identityRotation,
            localRotation: lying.localRotation)
        check(alignedAxis != nil, "柄在 X 轴上的躺着物件必须解得岀刃轴")
        let alignedDegrees = acos(max(-1, min(1, simd_dot(
            simd_normalize(alignedAxis!), PropGripInference.bladeDirectionInHandSpace)))) * 180 / .pi
        check(alignedDegrees < 1.0,
              "校准之后刃轴必须压在骨轴上，实测 \(alignedDegrees)°")

        let lyingAxis = PropGripInference.bladeAxisInHandSpace(
            size: WorldVector3(x: 1.1, y: 0.1462, z: 0.0624),
            orientation: PropGripInference.identityRotation,
            localRotation: PropGripInference.identityRotation)   // ← 注入「不校准」
        let lyingDegrees = acos(max(-1, min(1, simd_dot(
            simd_normalize(lyingAxis!), PropGripInference.bladeDirectionInHandSpace)))) * 180 / .pi
        check(lyingDegrees > 45,
              "负对照失败：不校准朝向时刃轴居然还贴着骨轴（实测 \(lyingDegrees)°）")
        print("   [负对照] 不校准朝向 ⇒ 刃轴与骨轴夹角 \(String(format: "%.1f", lyingDegrees))°（必须 > 45°）")
        print("   [正例]   校准之后   ⇒ 夹角 \(String(format: "%.3f", alignedDegrees))°")
        print("   [正例]   剑尖 vs 手骨世界旋转 · (0,1,0) ⇒ \(String(format: "%.3f", bladeDegrees))°")
        print("   [正例]   握点在剑身 \(String(format: "%.3f", suggestion.normalizedGrip.x)) 处（改造前 0.500）")

        // ---- 用户覆盖：拿用户拖出来的偏移/朝向，握点位置不动 ----
        let overridden = WorldPropGripCalibration(
            avatarAssetID: calibration.avatarAssetID, hand: .rightHand,
            normalizedGrip: calibration.normalizedGrip,
            localOffset: WorldVector3(x: 0, y: 0.02, z: -0.03),
            localRotation: calibration.localRotation)
        check(overridden.normalizedGrip == calibration.normalizedGrip,
              "adjustGrip 不许动握点位置（那会变成第二份握点来源）")
        let shifted = try PropAttachmentMatrix.transform(
            minimum: minimum, maximum: maximum,
            descriptor: ResidentHeldPropDescriptor(
                objectID: "prop", worldID: "world", assetID: "sha",
                modelURL: URL(fileURLWithPath: "/tmp/sword.glb"),
                targetHeightMeters: 1.1, attachmentPoint: .rightHand,
                calibration: overridden, orientation: upright),
            handPose: poseOne)
        check(shifted.columns.3 != first.columns.3,
              "用户拖了偏移就必须看得见（手里那一份跟着动）")

        // ------------------------------------------------------------------
        // 【挂点】手 / 背后 / 腰间：同一份公式、各自跟对的骨头、各自的默认姿势
        // ------------------------------------------------------------------
        check(PropAttachmentPoint.allCases == [.rightHand, .back, .waist],
              "挂点必须正好是 手 / 背后 / 腰间 三个")

        /// 「背后跟胸骨/脊椎、腰间跟腰/骨盆，而且都不是手骨」。判据与负对照共用同一个函数。
        func mountsOnRightBones(back: [String], waist: [String]) -> Bool {
            let hand = Set(PropAttachmentPoint.rightHand.boneNameCandidates)
            guard let backPrimary = back.first, let waistPrimary = waist.first else { return false }
            return Set(back).isDisjoint(with: hand) && Set(waist).isDisjoint(with: hand)
                && backPrimary == "上半身2" && back.contains("bone002")
                && waistPrimary == "腰" && waist.contains("下半身") && waist.contains("bone014")
        }
        check(mountsOnRightBones(back: PropAttachmentPoint.back.boneNameCandidates,
                                 waist: PropAttachmentPoint.waist.boneNameCandidates),
              "背后必须挂在胸骨（上半身2 / bone002），腰间必须挂在腰/骨盆（腰 / 下半身 / bone014），都不是手骨")
        // 负对照①：把背后挂到**手骨**上。
        check(!mountsOnRightBones(back: PropAttachmentPoint.rightHand.boneNameCandidates,
                                  waist: PropAttachmentPoint.waist.boneNameCandidates),
              "负对照失败：背后挂到手骨上居然没被抓到")
        // 负对照②：把腰间挂到**头/脖子**那一系。
        check(!mountsOnRightBones(back: PropAttachmentPoint.back.boneNameCandidates, waist: ["首", "頭"]),
              "负对照失败：腰间挂错骨头居然没被抓到")

        // 每个挂点都必须走**同一条** `骨骼世界 × 局部` —— 用同一组标定数字、只换挂点，
        // 相对位姿（pose⁻¹ · object）必须逐元素相同。谁要是给某个挂点另造一条公式，这条就红。
        func relativeToPose(_ point: PropAttachmentPoint) throws -> simd_float4x4 {
            let grip = WorldPropGripCalibration(
                avatarAssetID: "pmx.2b-miss-0414-standard", hand: point.worldSlot,
                normalizedGrip: WorldVector3(x: 0.5, y: 0.5, z: 0.5),
                localOffset: WorldVector3(x: 0, y: 0, z: 0),
                localRotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1))
            let descriptor = ResidentHeldPropDescriptor(
                objectID: "prop", worldID: "world", assetID: "sha",
                modelURL: URL(fileURLWithPath: "/tmp/sword.glb"),
                targetHeightMeters: 1.1, attachmentPoint: point, calibration: grip, orientation: upright)
            return simd_inverse(poseOne) * (try PropAttachmentMatrix.transform(
                minimum: minimum, maximum: maximum, descriptor: descriptor, handPose: poseOne))
        }
        func matrixDrift(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
            (0..<4).flatMap { column in (0..<4).map { row in abs(a[column][row] - b[column][row]) } }
                .max() ?? .infinity
        }
        let handRelative = try relativeToPose(.rightHand)
        let backDrift = matrixDrift(try relativeToPose(.back), handRelative)
        let waistDrift = matrixDrift(try relativeToPose(.waist), handRelative)
        check(backDrift < 0.000_01 && waistDrift < 0.000_01,
              "三个挂点必须共用同一条 `骨骼世界 × 局部`（背后差 \(backDrift)、腰间差 \(waistDrift)）")

        // 标定里的挂点与描述符的挂点不一致 ⇒ 必须拒绝（不是"悄悄按其中一个办"）。
        let mismatched = WorldPropGripCalibration(
            avatarAssetID: "pmx.2b-miss-0414-standard", hand: .rightHand,
            normalizedGrip: WorldVector3(x: 0.5, y: 0.5, z: 0.5),
            localOffset: WorldVector3(x: 0, y: 0, z: 0),
            localRotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1))
        var mismatchRejected = false
        do {
            _ = try PropAttachmentMatrix.transform(
                minimum: minimum, maximum: maximum,
                descriptor: ResidentHeldPropDescriptor(
                    objectID: "prop", worldID: "world", assetID: "sha",
                    modelURL: URL(fileURLWithPath: "/tmp/sword.glb"),
                    targetHeightMeters: 1.1, attachmentPoint: .back,
                    calibration: mismatched, orientation: upright),
                handPose: poseOne)
        } catch { mismatchRejected = true }
        check(mismatchRejected, "标定说的挂点与描述符的挂点不一致时必须拒绝")

        // 背后/腰间的默认偏移**不是**把手那套 (0,0,0) 套上去；朝向也不是手的骨轴方向。
        check(PropAttachmentSlots.defaultOffsetMeters(for: .back) != PropAttachmentSlots.defaultOffsetMeters(for: .rightHand),
              "背后必须有自己的默认偏移，不许套用手那套")
        check(PropAttachmentSlots.defaultOffsetMeters(for: .waist) != PropAttachmentSlots.defaultOffsetMeters(for: .rightHand),
              "腰间必须有自己的默认偏移，不许套用手那套")
        check(PropAttachmentSlots.bladeDirectionInBoneSpace(for: .back) != PropGripInference.bladeDirectionInHandSpace,
              "背后必须是**斜挂**（不是沿手骨那种竖直）")
        check(abs(PropAttachmentSlots.bladeDirectionInBoneSpace(for: .waist).y) < 0.0001,
              "腰间必须是**横挂**（长轴水平）")

        // 手那个挂点：与 `PropGripInference` 交回来的标定**逐字节**相同（旧存档不回归）。
        let swordProp = WorldGeneratedProp(
            objectID: "sword", assetID: "sha", displayName: "2B 白色长剑",
            size: swordSize, sourceHeight: 1.1, orientationRotation: upright)
        guard let handCalibration = PropAttachmentSlots.calibration(
            avatarAssetID: "pmx.2b-miss-0414-standard", prop: swordProp, point: .rightHand) else {
            check(false, "手那个挂点必须能造出标定"); return
        }
        check(handCalibration.normalizedGrip == suggestion.normalizedGrip
              && handCalibration.localOffset == suggestion.localOffset
              && handCalibration.localRotation == suggestion.localRotation
              && handCalibration.hand == .rightHand,
              "手那个挂点必须**逐字节**等于 PropGripInference 交回来的标定（旧存档不回归）")

        // 背后/腰间：挂点定义给出的偏移与朝向必须真的落到标定里，而且刀尖方向贴数字。
        guard let backCalibration = PropAttachmentSlots.calibration(
            avatarAssetID: "pmx.2b-miss-0414-standard", prop: swordProp, point: .back),
            let waistCalibration = PropAttachmentSlots.calibration(
                avatarAssetID: "pmx.2b-miss-0414-standard", prop: swordProp, point: .waist) else {
            check(false, "背后/腰间必须能造出标定"); return
        }
        check(backCalibration.hand == .back && waistCalibration.hand == .waist,
              "标定里的挂点必须就是选的那个")
        check(backCalibration.localOffset == PropAttachmentSlots.defaultOffsetMeters(for: .back)
              && waistCalibration.localOffset == PropAttachmentSlots.defaultOffsetMeters(for: .waist),
              "背后/腰间的默认偏移必须来自挂点表")
        check(backCalibration.normalizedGrip == WorldVector3(x: 0.5, y: 0.5, z: 0.5),
              "吊在背上/腰上的东西挂的是网格中点，不是手那套柄端握点")

        /// 剑尖世界方向与"挂点要的方向"的夹角（同一份 `pose × 局部`，只是把标定换掉）。
        ///
        /// 探针必须沿**原始网格**的最长轴 —— 这把剑的 AABB 是 1.005(X) × 0.133(Y) × 0.057(Z)，
        /// 最长轴是 X（与上面那条手持判据用的是同一根轴：`gripPoint + (0.4, 0, 0)`）。
        func slotBladeDegrees(point: PropAttachmentPoint, calibration: WorldPropGripCalibration) throws -> Float {
            let descriptor = ResidentHeldPropDescriptor(
                objectID: "prop", worldID: "world", assetID: "sha",
                modelURL: URL(fileURLWithPath: "/tmp/sword.glb"),
                targetHeightMeters: 1.1, attachmentPoint: point, calibration: calibration, orientation: upright)
            let matrix = try PropAttachmentMatrix.transform(
                minimum: minimum, maximum: maximum, descriptor: descriptor, handPose: poseOne)
            let meshCentre = minimum + (maximum - minimum) * SIMD3<Float>(0.5, 0.5, 0.5)
            let origin = worldPoint(matrix, meshCentre)
            let tip = worldPoint(matrix, meshCentre + SIMD3<Float>(0.1, 0, 0))
            let worldBlade = simd_normalize(tip - origin)
            let expected = simd_normalize(poseRotation * PropAttachmentSlots.bladeDirectionInBoneSpace(for: point))
            return acos(max(-1, min(1, simd_dot(worldBlade, expected)))) * 180 / .pi
        }
        let backBlade = try slotBladeDegrees(point: .back, calibration: backCalibration)
        let waistBlade = try slotBladeDegrees(point: .waist, calibration: waistCalibration)
        check(backBlade < 1.0, "背后斜挂：刀身方向与挂点要的方向夹角 \(backBlade)°（必须 < 1°）")
        check(waistBlade < 1.0, "腰间横挂：刀身方向与挂点要的方向夹角 \(waistBlade)°（必须 < 1°）")
        // 负对照：不校准（直接用推断给手的那份旋转）⇒ 背后就不会是斜挂。
        let uncalibrated = WorldPropGripCalibration(
            avatarAssetID: "pmx.2b-miss-0414-standard", hand: .back,
            normalizedGrip: WorldVector3(x: 0.5, y: 0.5, z: 0.5),
            localOffset: PropAttachmentSlots.defaultOffsetMeters(for: .back),
            localRotation: suggestion.localRotation)
        let uncalibratedDegrees = try slotBladeDegrees(point: .back, calibration: uncalibrated)
        check(uncalibratedDegrees > 20,
              "负对照失败：不做挂点朝向校准，背后的刀身居然还贴着骨轴（实测 \(uncalibratedDegrees)°）")

        print("   [正例]   手钙定 = PropGripInference（逐字节）；背后 = 上半身2 斜挂；腰间 = 腰 横挂")
        print("   [正例]   刀身 vs 挂点目标方向：背后 \(String(format: "%.3f", backBlade))°、腰间 \(String(format: "%.3f", waistBlade))°")
        print("   [负对照] 背后不校准朝向 ⇒ \(String(format: "%.1f", uncalibratedDegrees))°（必须 > 20°）")
        print("   [正例]   三挂点相对位姿最大差：背后 \(backDrift)、腰间 \(waistDrift)（同一份公式）")

        print("PASS: 手骨跟随（世界 = 手骨世界 × grip）、只读骨骼、握点单一来源 + 用户覆盖、"
            + "缺失可见失败、细长物件刃轴压在骨轴上、三挂点（手/背后/腰间）同一公式且各跟对骨头")
    }
}
"""#

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-hold-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

let stubURL = temp.appendingPathComponent("Stubs.swift")
let orientationURL = temp.appendingPathComponent("OrientationSlice.swift")
let attachmentURL = temp.appendingPathComponent("AttachmentSlice.swift")
let gripURL = temp.appendingPathComponent("PropGripInference.swift")
let mainURL = temp.appendingPathComponent("main.swift")
let executableURL = temp.appendingPathComponent("check")
try stubs.write(to: stubURL, atomically: true, encoding: .utf8)
try orientationSlice.write(to: orientationURL, atomically: true, encoding: .utf8)
try attachmentSlice.write(to: attachmentURL, atomically: true, encoding: .utf8)
try gripSlice.write(to: gripURL, atomically: true, encoding: .utf8)
try checks.write(to: mainURL, atomically: true, encoding: .utf8)

func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compile = try run("/usr/bin/nice", [
    "-n", "15", "/usr/bin/swiftc", "-j1", "-swift-version", "6", "-parse-as-library",
    stubURL.path, orientationURL.path, attachmentURL.path, gripURL.path, mainURL.path,
    "-o", executableURL.path,
])
guard compile == 0 else {
    print("FAIL: 手持判据的 harness 编译失败（上面的 swiftc 报错就是原因）")
    exit(compile)
}
exit(try run(executableURL.path, []))
