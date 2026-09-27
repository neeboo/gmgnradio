// Real library VRMNode and app transition code, with only GPU/asset IO replaced.
// Checks sparse clips cannot inherit unkeyed leg/wrist/root transforms.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
func declaration(_ signature: String, in source: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let open = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unbalanced declaration")
}
let view = try read("apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift")
let transition = declaration("private func synchronizeVRMWorldMotion(", in: view)
guard transition.contains("resetToBindPose()") else {
    print("FAIL: sparse VRM motion transitions preserve previous bone transforms"); exit(1)
}
let geometry = try read("apps/macos/Packages/checkouts/VRMMetalKit/Sources/VRMMetalKit/Renderer/VRMGeometry.swift")
let harness = #"""
import Foundation
import simd
// glTF parser input shape only. VRMNode and its reset/matrix behavior are real.
public struct GLTFNode {
    var name: String?; var mesh: Int? = nil; var skin: Int? = nil
    var matrix: [Float]? = nil; var translation: [Float]? = nil
    var rotation: [Float]? = nil; var scale: [Float]? = nil
}
\#(declaration("public class VRMNode", in: geometry))
\#(declaration("extension float4x4 {", in: geometry))
\#(declaration("private func decomposeMatrix(", in: geometry))
final class VRMModel {
    let nodes: [VRMNode]
    init(_ nodes: [VRMNode]) { self.nodes = nodes }
    func updateNodeTransforms() { nodes.filter { $0.parent == nil }.forEach { $0.updateWorldTransform() } }
}
struct StageMotionAsset: Equatable { let id: String }
struct StageMotionPlaybackIdentity: Equatable { let motion: StageMotionAsset; let snapshotRevision: UInt64 }
enum StageMotionPlaybackOutcome { case completed, failed(String) }
enum StageAvatarResolvedMotion: Equatable {
    case naturalIdle, asset(StageMotionAsset)
    static func resolve(selectedMotion: StageMotionAsset?, worldPlayback: String?, residentThinkingMotion: StageMotionAsset?, naturalIdleMotion: StageMotionAsset?) -> Self {
        (residentThinkingMotion ?? selectedMotion ?? naturalIdleMotion).map(Self.asset) ?? .naturalIdle
    }
}
struct WorldActivity { var motionPlayback: String? }
struct Snapshot { var motion: StageMotionAsset?; var revision: UInt64 = 0 }
final class Runtime {
    var snapshot = Snapshot(); var worldActivity: WorldActivity?
    var residentThinkingMotion: StageMotionAsset?
    var residentIdleMotion: StageMotionAsset?
    func playbackIdentity(for motion: StageMotionAsset) -> StageMotionPlaybackIdentity { StageMotionPlaybackIdentity(motion: motion, snapshotRevision: snapshot.revision) }
    func reportMotionPlayback(identity: StageMotionPlaybackIdentity, outcome: StageMotionPlaybackOutcome) {}
}
final class Renderer {
    var lookAtController: String?; var resets = 0
    func resetPhysics() { resets += 1 }
}
final class Player {
    var lookAtController: String?
    let motion: String
    init(_ motion: String) { self.motion = motion }
    func update(model: VRMModel) {
        // AnimationPlayer also writes only tracks contained in its active clip.
        if motion == "dance" {
            model.nodes[0].rotation = simd_quatf(angle: 1.4, axis: SIMD3(1,0,0))
            model.nodes[0].translation.y += 0.3
            model.nodes[0].scale = SIMD3(repeating: 1.1)
        } else if motion == "thinking" {
            model.nodes[1].rotation = simd_quatf(angle: 0.4, axis: SIMD3(0,0,1))
        }
        model.updateNodeTransforms()
    }
}
enum StageAvatarAnimationLoader {
    static func makeLoopingPlayer(for motion: StageMotionAsset, model: VRMModel) throws -> Player? {
        if motion.id == "invalid" { throw NSError(domain: "test", code: 1) }
        return Player(motion.id)
    }
}
enum Privacy { case `public` }
extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: String, privacy: Privacy) { appendLiteral(value) }
}
struct Log { func error(_ text: String) {} }
final class Host {
    static let log = Log()
    let avatarRuntime = Runtime()
    var avatarRenderer: Renderer? = Renderer()
    var appliedVRMResolvedMotion: StageAvatarResolvedMotion?
    var appliedVRMPlaybackIdentity: StageMotionPlaybackIdentity?
    var failedVRMPlaybackIdentities: [StageMotionPlaybackIdentity] = []
    var avatarAnimationPlayer: Player?
    \#(transition)
    \#(declaration("private func pruneStaleFailedPlaybackIdentities(", in: view))
    \#(declaration("private func rememberFailedPlaybackIdentity(", in: view))
    func tick(_ model: VRMModel) { synchronizeVRMWorldMotion(model); avatarAnimationPlayer?.update(model: model) }
}
let leg = VRMNode(index: 0, gltfNode: GLTFNode(name: "leftUpperLeg", translation: [0,0.9,0]))
let wrist = VRMNode(index: 1, gltfNode: GLTFNode(name: "rightHand"))
let model = VRMModel([leg,wrist]), host = Host()
host.avatarRuntime.snapshot.motion = StageMotionAsset(id: "dance")
host.tick(model)
precondition(leg.rotation.vector != leg.initialRotation.vector)
host.avatarRuntime.residentThinkingMotion = StageMotionAsset(id: "thinking")
host.tick(model)
precondition(leg.rotation.vector == leg.initialRotation.vector, "dance leg survives thinking")
precondition(leg.translation == leg.initialTranslation && leg.scale == leg.initialScale, "dance root/scale survives thinking")
precondition(wrist.rotation.vector != wrist.initialRotation.vector)
host.avatarRuntime.snapshot.motion = nil
host.avatarRuntime.residentThinkingMotion = nil
host.tick(model)
precondition(wrist.rotation.vector == wrist.initialRotation.vector, "thinking wrist survives natural idle")
host.avatarRuntime.residentThinkingMotion = StageMotionAsset(id: "thinking")
host.tick(model)
host.avatarRuntime.residentThinkingMotion = StageMotionAsset(id: "invalid")
host.tick(model)
precondition(host.avatarAnimationPlayer == nil && wrist.rotation.vector == wrist.initialRotation.vector, "failed next clip leaves previous pose")
let resetCount = host.avatarRenderer!.resets
host.tick(model)
precondition(host.avatarRenderer!.resets == resetCount, "unchanged clip resets physics every frame")
print("PASS: real VRMNode dance → thinking → idle, failed clip and unchanged frame reset policy")
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-vrm-transition-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let source = dir.appendingPathComponent("main.swift"), binary = dir.appendingPathComponent("test")
try harness.write(to: source, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", source.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
