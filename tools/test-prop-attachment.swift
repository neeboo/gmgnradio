import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let attachmentURL = root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift"
)
guard FileManager.default.fileExists(atPath: attachmentURL.path) else {
    print("FAIL: PropAttachment.swift is missing")
    exit(1)
}
let pmxSource = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift"
    ),
    encoding: .utf8
)
let storeSource = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift"
    ),
    encoding: .utf8
)
let marbleSource = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift"
    ),
    encoding: .utf8
)
let propRendererSource = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/Presence/ResidentPropRenderer.swift"
    ),
    encoding: .utf8
)
guard pmxSource.contains("func evaluatedAttachmentPose(")
else { print("FAIL: PMX renderer has no evaluated hand-pose API"); exit(1) }
guard storeSource.contains("func validateResidentPropAttachment(")
else { print("FAIL: spatial store has no current-renderer attachment preflight"); exit(1) }
guard marbleSource.contains("residentPropAttachmentValidationHandler")
else { print("FAIL: full space does not publish PMX hand-bone preflight"); exit(1) }
guard marbleSource.contains("renderResidentHeldProp(")
else { print("FAIL: full space does not render held GLB after the avatar"); exit(1) }
guard marbleSource.contains("PropAttachmentError.avatarMismatch.localizedDescription")
else { print("FAIL: changed avatar does not expose an explicit held-prop failure"); exit(1) }
guard propRendererSource.contains("desiredHeld.map { [$0.assetKey] }"),
      propRendererSource.contains("submitted.remove(item.objectID)") else {
    print("FAIL: held GLB is not protected from cache eviction or reloadable after eviction")
    exit(1)
}

let source = try String(contentsOf: attachmentURL, encoding: .utf8)
guard !source.contains("gmgn.motion.resident-hold-display"),
      marbleSource.contains("avatarRuntime.residentHoldDisplayMotion") else {
    print("FAIL: held display must use the installed BONES motion, not an authored bundled pose")
    exit(1)
}
// ---- 几何 / 朝向 / 握点推断：编**同一份源码**，不在这儿抄一份类型定义 ----------------
// 为什么改：这个 harness 原本用"剥掉 `import WorldRuntime` + 手写 stub"的老办法，
// 于是朝向那条线给 `PropAttachment.swift` 加了 `WorldPropRotation` /
// `WorldPropOrientationPolicy` 的引用之后，它就地变红 —— 而它**不在门禁里**，
// 红着没人管（这就是"红着没人管"的成因）。
// 现在这三份都编真源码，手写 stub 只剩"世界里的大类型"（标定 / 资产 / 描述符），
// 那一部分的漂移由本文件自己的断言盯着。
let geometrySource = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldGeometry.swift"), encoding: .utf8)
let orientationSource = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropOrientation.swift"), encoding: .utf8)
    .replacingOccurrences(of: "import WorldRuntime", with: "")
let gripInferenceSource = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/PropGripInference.swift"), encoding: .utf8)
    .replacingOccurrences(of: "import WorldRuntime", with: "")
// 被引用的那几个常量**逐字**从生产源码里抽出来：数字只有一个出处，那边改了这里立刻跟着变。
let sizePolicySource = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropSizePolicy.swift"), encoding: .utf8)
let collisionProxySource = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropCollisionProxy.swift"), encoding: .utf8)
func productionLine(_ text: String, prefix: String, _ what: String) -> String {
    guard let line = text.split(separator: "\n")
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { $0.hasPrefix(prefix) })
    else {
        print("FAIL: 生产源码里找不到\(what)（以 \"\(prefix)\" 开头的声明）")
        exit(1)
    }
    return line
}
let aspectLimitLine = productionLine(
    sizePolicySource, prefix: "public static let longThinAspectLimit", "细长门槛")
let upAxesLine = productionLine(
    collisionProxySource, prefix: "public static let acceptedUpAxes", "up 轴白名单")
let forwardAxesLine = productionLine(
    collisionProxySource, prefix: "public static let acceptedForwardAxes", "forward 轴白名单")
guard geometrySource.contains("struct WorldVector3"),
      orientationSource.contains("enum WorldPropRotation"),
      orientationSource.contains("enum WorldPropOrientationPolicy"),
      gripInferenceSource.contains("enum PropGripInference")
else {
    print("FAIL: 几何 / 朝向 / 握点推断必须编真源码，不许退回手写 stub")
    exit(1)
}
let harness = #"""
import Foundation
import simd

// `WorldVector3` / `WorldQuaternion` 来自真的 `WorldGeometry.swift`（另一个文件，见下面编译参数），
// 所以这里**不再**手写一份。下面两个 enum 的常量是逐字从生产源码里抽出来的行。
enum WorldPropSizePolicy {
    \#(aspectLimitLine)
}
enum WorldPropAuthoritativeSize {
    \#(upAxesLine)
    \#(forwardAxesLine)
}

enum WorldPropSlot: String, Codable, Equatable, Sendable {
    case rightHand
    case back
    case waist
}
/// 旧名：与生产同一个兼容别名。
typealias WorldPropHand = WorldPropSlot
struct WorldPropGripCalibration: Codable, Equatable, Sendable {
    let avatarAssetID: String
    let hand: WorldPropHand
    let normalizedGrip: WorldVector3
    let localOffset: WorldVector3
    let localRotation: WorldQuaternion
    /// 与生产 `WorldPropLayout.swift` 逐字同一套边界（挂点表造标定时要过它）。
    var isValid: Bool {
        guard !avatarAssetID.isEmpty, avatarAssetID.count <= 256 else { return false }
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
struct WorldGeneratedProp: Codable, Equatable, Sendable {
    let objectID: String
    let sourceWishID: String
    let assetID: String
    let displayName: String
    let size: WorldVector3
    let sourceHeight: Float
    /// 资产级摆正旋转。缺省 nil ⇒ 与改造前逐字节相同（绝大多数物件）。
    var orientation: WorldQuaternion? = nil
    var isValid: Bool {
        [size.x, size.y, size.z, sourceHeight].allSatisfy { $0.isFinite && $0 > 0 }
    }
    /// 与生产同一个出口名：握点推断读的就是这两个（`size` + 摆正旋转）。
    var effectiveSize: WorldVector3 { size }
    var orientationRotation: WorldQuaternion { orientation ?? .identity }
}

enum StageAvatarFormat: String, Codable, Sendable { case vrm, pmx }
enum StageMotionFormat: String, Codable, Sendable { case procedural, vrma, vmd }
struct StageAvatarAsset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let format: StageAvatarFormat
    let modelURL: URL
    let resourceRootURL: URL
}
struct StageMotionAsset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL?
    let loop: Bool
    init(id: String, name: String, format: StageMotionFormat, url: URL?, loop: Bool = true) {
        self.id = id; self.name = name; self.format = format; self.url = url; self.loop = loop
    }
}
enum LifeActivity: Equatable, Sendable { case idle, action(String); var typeID: String { self == .idle ? "idle" : "action" } }
enum LifeActivityPhase: String, Equatable, Sendable { case approaching, loop, completed, failed, interrupt }
struct ActivityPhaseContract: Equatable, Sendable { let motionIDs: [String] }

func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL:", message); exit(1) }
}

@main struct Checks {
    static func main() throws {
        let url = URL(fileURLWithPath: "/tmp/2b.pmx")
        let twoB = StageAvatarAsset(
            id: "pmx.2b-miss-0414-standard", name: "2B", format: .pmx,
            modelURL: url, resourceRootURL: url.deletingLastPathComponent()
        )
        let otherPMX = StageAvatarAsset(
            id: "pmx.other", name: "Other", format: .pmx,
            modelURL: url, resourceRootURL: url.deletingLastPathComponent()
        )
        let vrm = StageAvatarAsset(
            id: "pmx.2b-miss-0414-standard", name: "Wrong format", format: .vrm,
            modelURL: url, resourceRootURL: url.deletingLastPathComponent()
        )
        check(ResidentPropAttachmentEligibility.isEligible(twoB), "approved 2B PMX is eligible")
        check(ResidentPropAttachmentEligibility.rejectionReason(for: twoB) == nil, "eligible avatar has no rejection")
        check(ResidentPropAttachmentEligibility.rejectionReason(for: nil)?.contains("角色") == true, "missing avatar has Chinese rejection")
        check(ResidentPropAttachmentEligibility.rejectionReason(for: vrm)?.contains("PMX") == true, "VRM is rejected explicitly")
        check(ResidentPropAttachmentEligibility.rejectionReason(for: otherPMX)?.contains("2B") == true, "unapproved PMX is rejected explicitly")

        let prop = WorldGeneratedProp(
            objectID: "prop", sourceWishID: "wish", assetID: "sha",
            displayName: "small prop", size: .init(x: 0.08, y: 0.18, z: 0.06),
            sourceHeight: 1
        )
        let suggestion = ResidentPropAttachmentEligibility.suggestedCalibration(
            for: prop,
            avatar: twoB
        )
        check(suggestion?.avatarAssetID == twoB.id && suggestion?.hand == .rightHand, "eligible prop receives stable right-hand calibration")
        // 「既有物件的手感逐位不变」是**冻结的兼容契约**，所以这里钉的是字面量而不是
        // `PropGripInference.inheritedNormalizedGrip`（那等于自己跟自己比，改坏了也看不出来）。
        // 这一件是矮胖物件（最长边 / 高度 = 2.25 ≤ 细长门槛），必须原样走改造前的缺省。
        check(suggestion?.normalizedGrip == WorldVector3(x: 0.5, y: 0.2, z: 0.5)
              && suggestion?.localRotation == WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
              "a squat prop keeps the pre-change default grip and rotation byte for byte")
        check(ResidentPropAttachmentEligibility.suggestedCalibration(for: prop, avatar: otherPMX) == nil, "unsupported avatar receives no calibration")

        // ---- 握点说明的**唯一**出口：细长物件必须交得出来，且就是那一句 ----
        // 真机那把「2B 白色长剑」摆正后的世界尺寸：1.1 m 的最长边（比值 7.52 ≥ 4）。
        let sword = WorldGeneratedProp(
            objectID: "sword", sourceWishID: "wish", assetID: "sha",
            displayName: "2B 白色长剑", size: .init(x: 0.1462, y: 1.1, z: 0.0624),
            sourceHeight: 1.1
        )
        check(ResidentPropAttachmentEligibility.suggestedGripNotice(for: sword)
              == PropGripInference.suggestion(for: sword).notice,
              "细长物件的握点说明必须原样交出来（同一个 `PropGripInference` 出口，不另写一份）")
        check(ResidentPropAttachmentEligibility.suggestedGripNotice(for: sword)?.isEmpty == false,
              "1.1 m 的剑（细长）必须有可见说明，不许静默握上去")
        check(ResidentPropAttachmentEligibility.suggestedGripNotice(for: prop) == nil,
              "矮胖物件本就不需要说明，不许凭空造一句")

        let held = ResidentHeldPropDescriptor(
            objectID: "prop", worldID: "world", assetID: "sha",
            modelURL: URL(fileURLWithPath: "/tmp/prop.glb"),
            targetHeightMeters: 0.18, attachmentPoint: .rightHand,
            calibration: WorldPropGripCalibration(
                avatarAssetID: "pmx.2b-miss-0414-standard", hand: .rightHand,
                normalizedGrip: .init(x: 0.5, y: 0.2, z: 0.5),
                localOffset: .init(x: 0, y: 0, z: 0),
                localRotation: .init(x: 0, y: 0, z: 0, w: 1)
            )
        )
        check(held.attachmentPoint == .rightHand && held.targetHeightMeters == 0.18, "held descriptor preserves adopted metre size")
        check(PropAttachmentPoint.rightHand.boneNameCandidates == ["右手首", "bone009"], "2B right wrist uses the approved candidates")

        // ---- 挂点：背后跟胸骨/脊椎、腰间跟腰/骨盆，都不是手骨 ----
        check(PropAttachmentPoint.allCases == [.rightHand, .back, .waist], "挂点必须是 手 / 背后 / 腰间")
        check(PropAttachmentPoint.back.boneNameCandidates == ["上半身2", "bone002", "上半身", "bone001"],
              "背后挂点必须挂在胸骨（上半身2 / bone002）一系，退化到脊椎根")
        check(PropAttachmentPoint.waist.boneNameCandidates == ["腰", "下半身", "bone014", "センター", "bone000"],
              "腰间挂点必须挂在腰/骨盆（腰 / 下半身 / bone014）一系")
        let handBones = Set(PropAttachmentPoint.rightHand.boneNameCandidates)
        check(Set(PropAttachmentPoint.back.boneNameCandidates).isDisjoint(with: handBones)
              && Set(PropAttachmentPoint.waist.boneNameCandidates).isDisjoint(with: handBones),
              "背后/腰间的候选骨名里**不许**出现手骨 —— 挂错骨一眼能看出")
        check(PropAttachmentSlots.defaultOffsetMeters(for: .rightHand) == WorldVector3(x: 0, y: 0, z: 0)
              && PropAttachmentSlots.defaultOffsetMeters(for: .back) != WorldVector3(x: 0, y: 0, z: 0)
              && PropAttachmentSlots.defaultOffsetMeters(for: .waist) != WorldVector3(x: 0, y: 0, z: 0),
              "背后/腰间必须有自己的默认偏移，不是把手那套 (0,0,0) 套上去")
        check(PropAttachmentSlots.resolve(name: "back") == .back
              && PropAttachmentSlots.resolve(name: "挂背后") == .back
              && PropAttachmentSlots.resolve(name: "背后") == .back
              && PropAttachmentSlots.resolve(name: "挂腰上") == .waist
              && PropAttachmentSlots.resolve(name: "拿手里") == .rightHand
              && PropAttachmentSlots.resolve(name: "头顶") == nil
              && PropAttachmentSlots.resolve(name: "帽子") == nil,
              "挂点别名表只有一处，认不出来就 nil（不许猜一个挂点）")
        check(PropAttachmentSlots.displayName(for: .rightHand) == "右手"
              && PropAttachmentSlots.displayName(for: .back) == "背后"
              && PropAttachmentSlots.displayName(for: .waist) == "腰间",
              "挂点的中文名只有一处（面板与 agent 回执都读它）")

        var scaled = matrix_identity_float4x4
        scaled.columns.0 = SIMD4<Float>(0, 0, -2, 0)
        scaled.columns.1 = SIMD4<Float>(0, 3, 0, 0)
        scaled.columns.2 = SIMD4<Float>(4, 0, 0, 0)
        scaled.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let pose = try PropAttachmentPose.orthonormalized(scaled)
        let x = SIMD3<Float>(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)
        let y = SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let z = SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        check(abs(simd_length(x) - 1) < 0.00001 && abs(simd_length(y) - 1) < 0.00001 && abs(simd_length(z) - 1) < 0.00001, "avatar scale is removed")
        check(abs(simd_dot(x, y)) < 0.00001 && abs(simd_dot(y, z)) < 0.00001 && abs(simd_dot(z, x)) < 0.00001, "attachment basis is orthogonal")
        check(pose.columns.3 == SIMD4<Float>(1, 2, 3, 1), "animated wrist translation is retained")

        var second = scaled
        second.columns.3 = SIMD4<Float>(1.25, 2.1, 2.8, 1)
        let firstFollow = try PropAttachmentPose.orthonormalized(scaled)
        let secondFollow = try PropAttachmentPose.orthonormalized(second)
        check(firstFollow.columns.3 != secondFollow.columns.3, "two consecutive frames follow the evaluated wrist")

        do {
            var invalid = scaled
            invalid.columns.0 = .zero
            _ = try PropAttachmentPose.orthonormalized(invalid)
            check(false, "degenerate hand pose must fail")
        } catch let error as PropAttachmentError {
            check(error == .invalidHandPose, "degenerate hand pose reports explicit failure")
        }

        let selected = StageMotionAsset(id: "selected", name: "selected", format: .vmd, url: url)
        let thinking = StageMotionAsset(id: "thinking", name: "thinking", format: .vmd, url: url)
        let heldMotion = StageMotionAsset(id: "held", name: "held", format: .vmd, url: url)
        let formal = StageMotionAsset(id: "formal", name: "formal", format: .vmd, url: url)
        let formalPlayback = StageAvatarMotionPlayback.resolve(
            activity: .action("work"), phase: .loop,
            phaseContract: .init(motionIDs: ["formal"]),
            approvedMotions: ["formal": formal]
        )
        check(StageAvatarResolvedMotion.resolve(selectedMotion: selected, worldPlayback: formalPlayback, residentThinkingMotion: thinking, heldDisplayMotion: heldMotion) == .asset(formal), "formal activity outranks held display")
        check(StageAvatarResolvedMotion.resolve(selectedMotion: selected, worldPlayback: nil, residentThinkingMotion: thinking, heldDisplayMotion: heldMotion) == .asset(heldMotion), "held display outranks thinking")
        check(StageAvatarResolvedMotion.resolve(selectedMotion: selected, worldPlayback: nil, residentThinkingMotion: thinking, heldDisplayMotion: nil) == .asset(thinking), "thinking outranks user-selected motion")
        check(StageAvatarResolvedMotion.resolve(selectedMotion: selected, worldPlayback: nil, residentThinkingMotion: nil, heldDisplayMotion: nil) == .asset(selected), "user-selected motion remains final fallback")
        print("PASS: 2B eligibility, held descriptor, scale-free wrist pose and two-frame following")
    }
}
"""#

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-prop-attachment-\(UUID().uuidString)"
)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let sourceURL = temp.appendingPathComponent("PropAttachment.swift")
let slotURL = temp.appendingPathComponent("PropAttachmentSlot.swift")
let motionURL = temp.appendingPathComponent("StageAvatarMotionPlayback.swift")
let geometryURL = temp.appendingPathComponent("WorldGeometry.swift")
let orientationURL = temp.appendingPathComponent("WorldPropOrientation.swift")
let gripInferenceURL = temp.appendingPathComponent("PropGripInference.swift")
let harnessURL = temp.appendingPathComponent("main.swift")
let executableURL = temp.appendingPathComponent("check")
try source.replacingOccurrences(of: "import WorldRuntime", with: "")
    .write(to: sourceURL, atomically: true, encoding: .utf8)
// 挂点表（背后/腰间的定义）也是**真源码**，与 `PropAttachment.swift` 同一个模块编译。
try String(contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/Presence/PropAttachmentSlot.swift"), encoding: .utf8)
    .replacingOccurrences(of: "import WorldRuntime", with: "")
    .write(to: slotURL, atomically: true, encoding: .utf8)
try geometrySource.write(to: geometryURL, atomically: true, encoding: .utf8)
try orientationSource.write(to: orientationURL, atomically: true, encoding: .utf8)
try gripInferenceSource.write(to: gripInferenceURL, atomically: true, encoding: .utf8)
let motionSource = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/VisualEngine/StageAvatarMotionPlayback.swift"
    ),
    encoding: .utf8
).replacingOccurrences(of: "import WorldRuntime", with: "")
try motionSource.write(to: motionURL, atomically: true, encoding: .utf8)
try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compile = try run("/usr/bin/nice", [
    "-n", "15", "/usr/bin/swiftc", "-j1", "-swift-version", "6",
    "-parse-as-library",
    geometryURL.path, orientationURL.path, gripInferenceURL.path,
    sourceURL.path, slotURL.path, motionURL.path, harnessURL.path,
    "-o", executableURL.path,
])
guard compile == 0 else { exit(compile) }
exit(try run(executableURL.path, []))
