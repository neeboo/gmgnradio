// Pure Foundation policy harness. Does not launch the app or touch user stores.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
func declaration(_ signature: String, in source: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let open = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unbalanced declaration: \(signature)")
}
let runtime = try read("apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift")
let bootstrap = try read("apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift")
guard declaration("static func walkingSpeed(", in: bootstrap).contains("avatarFormat:") else {
    print("FAIL: walking speed selects PMX cadence even when the active avatar is VRM"); exit(1)
}
let performance = try read("apps/macos/Sources/GMGNRadio/Presence/ResidentPerformanceMotionPolicy.swift")
let modelTypes = String(runtime[runtime.range(of: "enum StageAvatarFormat:")!.lowerBound..<runtime.range(of: "enum StageMotionCompletionPolicy")!.lowerBound])
let installedIDs = String(bootstrap[bootstrap.range(of: "static let installedLivingMotionIDs:")!.lowerBound..<bootstrap.range(of: "static func loadBundledCanary(")!.lowerBound])
let harness = #"""
import Foundation
\#(modelTypes)
\#(performance)
struct WorldResource { let id: String; let path: String; let kind: String }
enum MotionPackageStore { static let iluvSlapBassID = "builtin.motion.iluvslapbass" }
enum LivingWorldBootstrapError: Error { case invalidMotionResource(id: String, kind: String, path: String) }
enum LivingWorldBootstrap {
    static let fallbackWalkingSpeed: Float = 1.2
    static let bonesWalkCompatibility = StageMotionLocomotion(strideSpeed: 0.75, playbackRate: 1, inPlace: true)
    static let ardyWalkCompatibility = StageMotionLocomotion(strideSpeed: 0.45, playbackRate: 4, inPlace: true)
    \#(installedIDs)
    \#(declaration("static func approvedInstalledMotions(", in: bootstrap))
    \#(declaration("static func approvedMotions(", in: bootstrap))
    \#(declaration("static func walkingSpeed(", in: bootstrap))
}
func expect(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL: \(message)"); exit(1) }
}
func motion(_ id: String, format: StageMotionFormat = .vmd, loop: Bool = true) -> StageMotionAsset {
    StageMotionAsset(id: id, name: id, format: format, url: URL(fileURLWithPath: "/fixture/\(id).\(format.rawValue)"), loop: loop)
}
@main struct Test {
    static func main() throws {
        let bones = motion("gmgn.motion.bones.walk-loop-pmx")
        let ardy = motion("gmgn.motion.ardy-walk-loop-pmx")
        let generated = motion("gmgn.motion.generated.a-person-naturally-picks-up-a-coffee-cup-76b63e0f")
        let oldJacks = motion("gmgn.motion.ardy-natural-jumping-jacks")
        let jacks = motion("gmgn.motion.bones.jumping-jacks-pmx")
        let backflip = motion("gmgn.motion.ardy-backflip", loop: false)
        let slap = motion(MotionPackageStore.iluvSlapBassID)
        let approved = LivingWorldBootstrap.approvedInstalledMotions([bones, ardy, generated, oldJacks, jacks, backflip])
        expect(approved[ardy.id] == nil, "ARDY walk must not enter resident world playback")
        expect(approved[generated.id] == nil, "generated coffee motion must not enter resident world playback")
        expect(approved[oldJacks.id] == nil, "ARDY jumping jacks must not remain a substitute")
        expect(Set(approved.keys) == [bones.id, jacks.id, backflip.id], "only BONES and the preserved backflip enter installed allow-list")
        expect(approved[bones.id]?.strideSpeed == 0.75 && approved[bones.id]?.playbackRate == 1, "BONES walk cadence preserved")
        expect(approved[backflip.id]?.url == backflip.url && approved[backflip.id]?.loop == false, "backflip source and one-shot behavior preserved")
        expect(ResidentPerformanceMotionPolicy.requiredMotionID(for: "performance.jumping_jacks") == jacks.id, "jumping jacks require BONES")
        expect(ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.jumping_jacks", avatarFormat: .pmx, approvedMotions: approved), "installed BONES jumping jacks available")
        expect(!ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.jumping_jacks", avatarFormat: .pmx, approvedMotions: [oldJacks.id: oldJacks]), "missing BONES package remains unavailable")
        expect(!ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.jumping_jacks", avatarFormat: .vrm, approvedMotions: approved), "PMX-only package not advertised for VRM")
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: [ardy.id: ardy.applyingLocomotionFallback(.init(strideSpeed: 0.1, playbackRate: 4, inPlace: true))]) == 1.2, "legacy walking speed must not leak through")
        let vrmWalk = StageMotionAsset(id: "gmgn.motion.bones.walk-loop-vrm", name: "VRM Walk", format: .vrma, url: URL(fileURLWithPath: "/fixture/walk.vrma"), strideSpeed: 1.40076154, playbackRate: 1, inPlace: true)
        let bothWalks = LivingWorldBootstrap.approvedInstalledMotions([bones, vrmWalk])
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: bothWalks, avatarFormat: .pmx) == 0.75, "PMX must retain its own source cadence")
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: bothWalks, avatarFormat: .vrm) == vrmWalk.strideSpeed!, "VRM must use compatible VRMA source cadence")
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: [bones.id: bothWalks[bones.id]!], avatarFormat: .vrm) == 1.2, "PMX-only cadence must not leak into VRM")
        let wrongFormat = StageMotionAsset(id: vrmWalk.id, name: "bad", format: .vmd, url: vrmWalk.url, strideSpeed: 0.5, inPlace: true)
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: [wrongFormat.id: wrongFormat], avatarFormat: .vrm) == 1.2, "format mismatch must not select cadence")
        let doubledVRM = StageMotionAsset(id: vrmWalk.id, name: "faster", format: .vrma, url: vrmWalk.url, strideSpeed: 1.4, playbackRate: 2, inPlace: true)
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: [doubledVRM.id: doubledVRM], avatarFormat: .vrm) == 2.8, "navigation speed must include the selected clip playback multiplier")
        let oneShotWalk = StageMotionAsset(id: vrmWalk.id, name: "one shot", format: .vrma, url: vrmWalk.url, loop: false, strideSpeed: 1.4, inPlace: true)
        expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: [oneShotWalk.id: oneShotWalk], avatarFormat: .vrm) == 1.2, "one-shot library motions must not provide looping navigation cadence")
        let resources = [WorldResource(id: bones.id, path: "walk.vmd", kind: "motion.vmd"), WorldResource(id: ardy.id, path: "legacy.vmd", kind: "motion.vmd"), WorldResource(id: "walk.forward", path: "unknown.vmd", kind: "motion.vmd")]
        let merged = try LivingWorldBootstrap.approvedMotions(resources: resources, packageRoot: URL(fileURLWithPath: "/fixture"), supplementalMotions: ["listen.music": slap, generated.id: generated, backflip.id: backflip])
        expect(Set(merged.keys) == [bones.id, "listen.music", backflip.id], "resource and supplemental entrances reject other sources")
        expect(merged["listen.music"] == slap, "slap bass music alias unchanged")
        print("PASS: BONES-only resident world motions, preserved backflip and slap bass, missing-package availability")
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-world-motion-sources-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let source = dir.appendingPathComponent("main.swift"), binary = dir.appendingPathComponent("test")
try harness.write(to: source, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", source.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit()
guard test.terminationStatus == 0 else { exit(test.terminationStatus) }
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apps/macos/Resources/Worlds/marble-living-cabin/world.json"))) as! [String: Any]
let definitions = manifest["activityDefinitions"] as! [[String: Any]]
for definition in definitions {
    for phase in definition["phases"] as! [[String: Any]] {
        for id in phase["motionIDs"] as! [String] {
            guard id.hasPrefix("gmgn.motion.bones.") || id == "gmgn.motion.ardy-backflip" || id == "listen.music" else {
                print("FAIL: bundled world retains disallowed motion \(id)"); exit(1)
            }
        }
    }
}
print("PASS: bundled living cabin phase contracts contain no disallowed motion sources")
