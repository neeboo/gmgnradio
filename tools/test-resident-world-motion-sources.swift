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
let locomotion = try read("apps/macos/Sources/GMGNRadio/Presence/ResidentLocomotionMotionPolicy.swift")
let projection = try read("apps/macos/UnityHost/UnityActivityMotionProjection.swift")
let modelTypes = String(runtime[runtime.range(of: "enum StageAvatarFormat:")!.lowerBound..<runtime.range(of: "enum StageMotionCompletionPolicy")!.lowerBound])
let installedIDs = String(bootstrap[bootstrap.range(of: "static let installedLivingMotionIDs:")!.lowerBound..<bootstrap.range(of: "static func loadBundledCanary(")!.lowerBound])
let harness = #"""
import Foundation
import CryptoKit
\#(modelTypes)
\#(performance)
\#(locomotion)
\#(projection)
struct WorldResource { let id: String; let path: String; let kind: String }
enum MotionPackageStore {
    static let iluvSlapBassID = "builtin.motion.iluvslapbass"
    static let iluvSlapBassVRMID = "builtin.motion.iluvslapbass-vrm"
}
enum LivingWorldBootstrapError: Error {
    case invalidMotionResource(id: String, kind: String, path: String)
    static func badMotionResource(id: String, kind: String, path: String) -> Self {
        .invalidMotionResource(id: id, kind: kind, path: path)
    }
}
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
        if CommandLine.arguments.count > 1 {
            let package = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as! [String: Any]
            let entry = package.appendingPathComponent(raw["entry"] as! String)
            let data = try Data(contentsOf: entry)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            expect(raw["id"] as? String == "gmgn.motion.bones.jumping-jacks-vrm" && raw["format"] as? String == "vrma"
                && raw["version"] as? String == "1.0.0" && digest == raw["sha256"] as? String,
                "real installed jumping-jacks VRMA package presence, version and hash")
            let installed = StageMotionAsset(id: raw["id"] as! String, name: raw["name"] as! String,
                format: .vrma, url: entry, version: raw["version"] as? String, sha256: digest,
                loop: raw["loop"] as! Bool, playbackRate: 1, inPlace: raw["inPlace"] as? Bool)
            let library = LivingWorldBootstrap.approvedInstalledMotions([installed])
            let merged = try LivingWorldBootstrap.approvedMotions(resources: [], packageRoot: package, supplementalMotions: library)
            let rendered = UnityActivityMotionProjection.resolve(avatarFormat: .vrm, approvedMotions: merged,
                locomoting: false, authoredIDs: ["gmgn.motion.bones.jumping-jacks-pmx"])
            print("OBSERVED real installed VRMA version=1.0.0 hashVerified=true approved=\(library[installed.id] != nil) required=\(rendered.required) motionPresent=\(rendered.motion != nil)")
            expect(rendered.required && rendered.motion?["id"] as? String == installed.id
                && rendered.motion?["format"] as? String == "vrma", "real installed VRMA reaches exact activity projection")
        }
        let bones = motion("gmgn.motion.bones.walk-loop-pmx")
        let ardy = motion("gmgn.motion.ardy-walk-loop-pmx")
        let generated = motion("gmgn.motion.generated.a-person-naturally-picks-up-a-coffee-cup-76b63e0f")
        let oldJacks = motion("gmgn.motion.ardy-natural-jumping-jacks")
        let jacks = motion("gmgn.motion.bones.jumping-jacks-pmx")
        let backflip = motion("gmgn.motion.ardy-backflip", loop: false)
        let slap = motion(MotionPackageStore.iluvSlapBassID)
        let slapVRM = motion(MotionPackageStore.iluvSlapBassVRMID, format: .vrma)
        let vrmMusic = LivingWorldBootstrap.approvedInstalledMotions([slapVRM])
        expect(vrmMusic[slapVRM.id] == slapVRM, "retarget of the preserved music clip must remain available to VRM")
        let holdPMX = motion("gmgn.motion.bones.hold-display-pmx")
        let holdVRM = motion("gmgn.motion.bones.hold-display-vrm", format: .vrma)
        let holdLibrary = LivingWorldBootstrap.approvedInstalledMotions([holdPMX, holdVRM])
        expect(holdLibrary[holdPMX.id]?.url == holdPMX.url && holdLibrary[holdPMX.id]?.format == .vmd,
            "approved BONES holding PMX keeps its installed source")
        expect(holdLibrary[holdVRM.id]?.url == holdVRM.url && holdLibrary[holdVRM.id]?.format == .vrma,
            "approved BONES holding VRM keeps its exact retarget source")
        let buttonPMX = motion("gmgn.motion.device.jukebox-low-button-pmx", loop: false)
        let buttonVRM = motion("gmgn.motion.device.jukebox-low-button-vrm", format: .vrma, loop: false)
        let unapprovedDevice = motion("gmgn.motion.device.unapproved-operation-pmx", loop: false)
        let deviceLibrary = LivingWorldBootstrap.approvedInstalledMotions([buttonPMX, buttonVRM, unapprovedDevice])
        expect(deviceLibrary[buttonPMX.id]?.url == buttonPMX.url && deviceLibrary[buttonPMX.id]?.loop == false,
            "bundled finite PMX button must reach the activity playback allow-list")
        expect(deviceLibrary[buttonVRM.id]?.url == buttonVRM.url && deviceLibrary[buttonVRM.id]?.loop == false,
            "bundled finite VRMA button must reach the activity playback allow-list")
        let mergedDevices = try LivingWorldBootstrap.approvedMotions(resources: [],
            packageRoot: URL(fileURLWithPath: "/fixture"), supplementalMotions: deviceLibrary)
        expect(mergedDevices[buttonPMX.id]?.url == buttonPMX.url && mergedDevices[buttonVRM.id]?.url == buttonVRM.url,
            "world resource merge must preserve both exact approved device clips")
        expect(deviceLibrary[unapprovedDevice.id] == nil && mergedDevices[unapprovedDevice.id] == nil,
            "the device namespace is not generally approved")
        let jacksVRM = StageMotionAsset(id: "gmgn.motion.bones.jumping-jacks-vrm", name: "BONES VRM Jumping Jacks",
            format: .vrma, url: URL(fileURLWithPath: "/fixture/jumping-jacks.vrma"), loop: true, inPlace: true)
        let vrmPerformanceLibrary = LivingWorldBootstrap.approvedInstalledMotions([jacksVRM])
        expect(vrmPerformanceLibrary[jacksVRM.id]?.url == jacksVRM.url,
            "exact installed BONES VRMA jumping jacks must reach resident activity projection")
        let mergedPerformance = try LivingWorldBootstrap.approvedMotions(resources: [],
            packageRoot: URL(fileURLWithPath: "/fixture"), supplementalMotions: vrmPerformanceLibrary)
        expect(mergedPerformance[jacksVRM.id]?.format == .vrma && mergedPerformance[jacksVRM.id]?.loop == true
            && mergedPerformance[jacksVRM.id]?.inPlace == true,
            "installed VRMA jumping jacks must survive world merge with authored looping in-place playback")
        let renderedVRM = UnityActivityMotionProjection.resolve(avatarFormat: .vrm, approvedMotions: mergedPerformance,
            locomoting: false, authoredIDs: ["gmgn.motion.bones.jumping-jacks-pmx"], fileExists: { _ in true })
        expect(renderedVRM.motion?["id"] as? String == jacksVRM.id, "policy-to-resolver preserves exact VRM performance clip")
        let missingVRM = UnityActivityMotionProjection.resolve(avatarFormat: .vrm, approvedMotions: [:],
            locomoting: false, authoredIDs: ["gmgn.motion.bones.jumping-jacks-pmx"], fileExists: { _ in true })
        expect(missingVRM.required && missingVRM.motion == nil, "missing installed jumping VRMA cannot claim readiness")
        let unrelated = motion("gmgn.motion.bones.unapproved-dance-vrm", format: .vrma)
        expect(LivingWorldBootstrap.approvedInstalledMotions([unrelated])[unrelated.id] == nil,
            "unapproved BONES VRMA cannot enter activity playback")
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
test.arguments = Array(CommandLine.arguments.dropFirst())
try test.run(); test.waitUntilExit()
guard test.terminationStatus == 0 else { exit(test.terminationStatus) }
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apps/macos/Resources/Worlds/marble-living-cabin/world.json"))) as! [String: Any]
let definitions = manifest["activityDefinitions"] as! [[String: Any]]
for definition in definitions {
    for phase in definition["phases"] as! [[String: Any]] {
        for id in phase["motionIDs"] as! [String] {
            guard id.hasPrefix("gmgn.motion.bones.") || id == "gmgn.motion.ardy-backflip" || id == "listen.music"
                || id == "gmgn.motion.device.jukebox-low-button-pmx"
                || id == "gmgn.motion.device.jukebox-low-button-vrm" else {
                print("FAIL: bundled world retains disallowed motion \(id)"); exit(1)
            }
        }
    }
}
print("PASS: bundled living cabin phase contracts contain no disallowed motion sources")
