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
let harness = #"""
import Foundation
import simd

struct WorldVector3: Codable, Equatable, Sendable {
    let x: Float; let y: Float; let z: Float
}
struct WorldQuaternion: Codable, Equatable, Sendable {
    let x: Float; let y: Float; let z: Float; let w: Float
}
enum WorldPropHand: String, Codable, Equatable, Sendable { case rightHand }
struct WorldPropGripCalibration: Codable, Equatable, Sendable {
    let avatarAssetID: String
    let hand: WorldPropHand
    let normalizedGrip: WorldVector3
    let localOffset: WorldVector3
    let localRotation: WorldQuaternion
}
struct WorldGeneratedProp: Codable, Equatable, Sendable {
    let objectID: String
    let sourceWishID: String
    let assetID: String
    let displayName: String
    let size: WorldVector3
    let sourceHeight: Float
    var isValid: Bool {
        [size.x, size.y, size.z, sourceHeight].allSatisfy { $0.isFinite && $0 > 0 }
    }
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
        check(ResidentPropAttachmentEligibility.suggestedCalibration(for: prop, avatar: otherPMX) == nil, "unsupported avatar receives no calibration")

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
let motionURL = temp.appendingPathComponent("StageAvatarMotionPlayback.swift")
let harnessURL = temp.appendingPathComponent("main.swift")
let executableURL = temp.appendingPathComponent("check")
try source.replacingOccurrences(of: "import WorldRuntime", with: "")
    .write(to: sourceURL, atomically: true, encoding: .utf8)
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
    "-parse-as-library", sourceURL.path, motionURL.path, harnessURL.path,
    "-o", executableURL.path,
])
guard compile == 0 else { exit(compile) }
exit(try run(executableURL.path, []))
