// Offline: compile the production loader and runtime with asset/GPU adapters stubbed.
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
let runtime = try read("apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift")
let loader = try read("apps/macos/Sources/GMGNRadio/MMD/StageAvatarAnimationLoader.swift")
let marble = try read("apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift")
let desktop = try read("apps/macos/Sources/GMGNRadio/DesktopPresence/VRMAvatarMetalView.swift")
let playback = try read("apps/macos/Sources/GMGNRadio/VisualEngine/StageAvatarMotionPlayback.swift")
let pmx = try read("apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift")
guard !marble.contains("animationPlayer.applyRootMotion = false"),
      !marble.contains("StageAvatarAnimationPlayback.speed("),
      !desktop.contains("StageAvatarAnimationPlayback.speed("),
      marble.contains("player.isFinished"), desktop.contains("player.isFinished"),
      marble.contains("avatarAnimationPlayer == nil ? motion.bodyLift : 0"),
      desktop.contains("animationPlayer == nil ? motion.bodyLift : 0"),
      marble.contains("appliedPMXPlaybackIdentity = identity"),
      marble.contains("rememberFailedPlaybackIdentity("),
      desktop.contains("reportMotionPlayback(") else {
    print("FAIL: renderer still overrides authored playback or lacks terminal lifecycle/cached attempt identity"); exit(1)
}
guard runtime.contains("func reportMotionPlayback("), runtime.contains("func playbackIdentity(") else {
    print("FAIL: runtime has no identity-scoped playback completion/failure feedback"); exit(1)
}
let harness = #"""
import Foundation
import Observation
struct WorldTransform: Equatable, Sendable {}
struct LifeActivity: Equatable, Sendable {}
struct LifeActivityPhase: Equatable, Sendable {}
enum StageAvatarMotionPlayback: Equatable, Sendable { case temporary(StageMotionAsset); case naturalIdle(fallback: String?) }
enum StageAvatarActivity: Equatable, Sendable { case idle, listening, speaking }
struct PresencePackageStore {
    static func liveStore() throws -> Self { Self() }
    func activeAvatar() throws -> StageAvatarAsset? { nil }
}
struct MotionPackageStore {
    static let naturalIdleID = "idle"
    static func liveStore() throws -> Self { Self() }
    func activeMotion() throws -> StageMotionAsset? { nil }
    func activate(id: String) throws {}
    func listMotions() throws -> [StageMotionAsset] { [] }
}
enum MotionPackageError: Error { case motionNotFound }
enum VRMHumanoidBone { case hips, head }
struct LocomotionMetadata { var strideSpeed: Float = 0; var sourceHipsHeight: Float = 0 }
struct JointTrack {
    let bone: VRMHumanoidBone
    let rotationSampler: ((Float) -> Float)?
    let translationSampler: ((Float) -> SIMD3<Float>)?
    let scaleSampler: ((Float) -> SIMD3<Float>)?
}
struct AnimationClip {
    var jointTracks: [JointTrack]
    var locomotion: LocomotionMetadata? = nil
}
struct VRMHumanoid {
    func getBoneNode(_ bone: VRMHumanoidBone) -> Int? { nil }
}
final class VRMNode {
    weak var parent: VRMNode?
    var initialTranslation: SIMD3<Float> = .zero
}
struct VRMModel {
    var humanoid: VRMHumanoid? = nil
    var nodes: [VRMNode] = []
}
final class AnimationPlayer {
    var isLooping = true
    var applyRootMotion = false
    var speed: Float = 1
    var clip: AnimationClip?
    func load(_ clip: AnimationClip) { self.clip = clip }
}
enum VRMAnimationLoader {
    static func loadVRMA(from: URL, model: VRMModel) throws -> AnimationClip {
        AnimationClip(jointTracks: [JointTrack(bone: .hips, rotationSampler: nil,
            translationSampler: { SIMD3(2 + $0, 1 + $0 * 2, 3 - $0) }, scaleSampler: nil)])
    }
}
enum NanoemVMDLoader { static func load(from: URL) throws -> Int { 0 } }
enum VMDToVRMClipAdapter {
    static func makeClip(from: Int, model: VRMModel) -> AnimationClip { AnimationClip(jointTracks: []) }
}
\#(runtime.replacingOccurrences(of: "import WorldRuntime", with: ""))
\#(loader.replacingOccurrences(of: "import VRMMetalKit", with: ""))
\#(declaration("enum StageAvatarResolvedMotion:", in: playback))
enum Privacy { case `public` }
extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { appendLiteral(String(describing: value)) }
}
struct TestLog { func notice(_ text: String) {}; func error(_ text: String) {} }
struct TestRenderProfile { let drawsWorld = false }
struct TestCalibration { let avatarAssetID: String }
struct TestHeldProp { let calibration: TestCalibration }
struct TestSpatialStage { let residentHeldProp: TestHeldProp? = nil }
enum PMXWarmKitchenCoffeeCup { static func shouldDisplay(motionID: String) -> Bool { false } }
@MainActor final class PMXStageAvatarRenderer {
    enum MotionLoadFailurePolicy: Equatable, Sendable { case preserveCurrentMotion }
    static let motionLoadFailurePolicy: MotionLoadFailurePolicy = .preserveCurrentMotion
    \#(declaration("static func locomotionGait(", in: pmx))
    var loadedLocomotionGait: StageLocomotionGait?
    var onMotionFinished: ((URL) -> Void)?
    var attempts = 0
    var attemptsByPath: [String: Int] = [:]
    var fails = true
    var failingPaths: Set<String> = []
    func setCoffeeCupVisible(_ visible: Bool) {}
    func clearMotion() { loadedLocomotionGait = nil }
    func loadMotion(from url: URL, repeats: Bool, playbackRate: Float, inPlace: Bool, locomotion: StageLocomotionGait? = nil) throws {
        attempts += 1
        attemptsByPath[url.path, default: 0] += 1
        if fails || failingPaths.contains(url.path) { throw MotionPackageError.motionNotFound }
        loadedLocomotionGait = locomotion
    }
}
@MainActor final class TestPMXHost {
    static let log = TestLog()
    let avatarRuntime: StageAvatarRuntimeStore
    let renderProfile = TestRenderProfile()
    let spatialStage = TestSpatialStage()
    var appliedPMXResolvedMotion: StageAvatarResolvedMotion?
    var appliedPMXPlaybackIdentity: StageMotionPlaybackIdentity?
    var failedPMXPlaybackIdentities: [StageMotionPlaybackIdentity] = []
    init(_ store: StageAvatarRuntimeStore) { avatarRuntime = store }
    \#(declaration("private func synchronizePMXWorldMotion(", in: marble))
    \#(declaration("private func loadPMXMotion(", in: marble))
    \#(declaration("private func pruneStaleFailedPlaybackIdentities(", in: marble))
    \#(declaration("private func rememberFailedPlaybackIdentity(", in: marble))
    func frame(_ renderer: PMXStageAvatarRenderer) { synchronizePMXWorldMotion(renderer) }
}
@main struct Test {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: "/offline/motion.vrma")
        let full = StageMotionAsset(id: "full", name: "Full", format: .vrma, url: url, loop: false, playbackRate: 1.25, inPlace: false)
        let fullPlayer = try StageAvatarAnimationLoader.makeLoopingPlayer(for: full, model: VRMModel())!
        precondition(fullPlayer.applyRootMotion, "full source motion must apply hips XYZ")
        precondition(fullPlayer.clip!.jointTracks[0].translationSampler!(2) == SIMD3<Float>(4, 5, 1))
        precondition(fullPlayer.speed == 1.25, "authored cadence must be preserved")
        precondition(!fullPlayer.isLooping)
        let inPlace = StageMotionAsset(id: "walk", name: "Walk", format: .vrma, url: url, inPlace: true)
        let walkPlayer = try StageAvatarAnimationLoader.makeLoopingPlayer(for: inPlace, model: VRMModel())!
        precondition(walkPlayer.applyRootMotion, "in-place must still apply authored vertical hips")
        precondition(walkPlayer.clip!.jointTracks[0].translationSampler!(2) == SIMD3<Float>(2, 5, 3), "in-place locks XZ only")
        let store = StageAvatarRuntimeStore(packageStore: nil, motionPackageStore: nil)
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(full), sourceRevision: 1, activityRequestID: "request-a"))
        let identity = store.playbackIdentity(for: full)
        var outcomes: [StageMotionPlaybackEvent] = []
        let observer = store.observeMotionPlayback { outcomes.append($0) }
        store.reportMotionPlayback(identity: identity, outcome: .completed)
        store.reportMotionPlayback(identity: identity, outcome: .completed)
        precondition(outcomes.count == 1, "duplicate completion must emit once")
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(full), sourceRevision: 2, activityRequestID: "request-b"))
        store.reportMotionPlayback(identity: identity, outcome: .failed("stale"))
        precondition(outcomes.count == 1, "old request must not report against replacement")
        let replacement = store.playbackIdentity(for: full)
        store.reportMotionPlayback(identity: replacement, outcome: .failed("bad asset"))
        store.reportMotionPlayback(identity: replacement, outcome: .failed("bad asset"))
        precondition(outcomes.count == 2 && outcomes.last?.outcome == .failed("bad asset"))
        let beforeRestart = store.snapshot.revision
        store.refresh(forcePlaybackReload: true)
        precondition(store.snapshot.revision == beforeRestart + 1)
        store.removeMotionPlaybackObserver(observer)
        let badVMD = StageMotionAsset(id: "pmx-action", name: "PMX Action", format: .vmd, url: URL(fileURLWithPath: "/offline/action.vmd"), loop: false)
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(badVMD), sourceRevision: 3, activityRequestID: "pmx-a"))
        let host = TestPMXHost(store)
        let renderer = PMXStageAvatarRenderer()
        var pmxEvents: [StageMotionPlaybackEvent] = []
        let pmxObserver = store.observeMotionPlayback { pmxEvents.append($0) }
        for _ in 0..<120 { host.frame(renderer) }
        precondition(renderer.attempts == 1, "failed PMX asset must not reload every frame")
        precondition(pmxEvents.count == 1, "failed PMX attempt reports one terminal event")
        store.refresh(forcePlaybackReload: true)
        renderer.fails = false
        host.frame(renderer)
        precondition(renderer.attempts == 2, "explicit retry revision permits one new load")
        renderer.onMotionFinished?(badVMD.url!)
        renderer.onMotionFinished?(badVMD.url!)
        precondition(pmxEvents.count == 2 && pmxEvents.last?.outcome == .completed)
        // Regression: a bad selected motion A fails once, a temporary thinking
        // motion B plays, then A re-resolves with the SAME playback identity.
        // The failed identity must stay failed: no reload and no duplicate
        // failure callback. Only an explicit new playback revision or activity
        // request permits another attempt.
        let failedA = StageMotionAsset(id: "pmx-a", name: "PMX A", format: .vmd, url: URL(fileURLWithPath: "/offline/action-a.vmd"), loop: true)
        let thinkingB = StageMotionAsset(id: "pmx-b", name: "PMX B", format: .vmd, url: URL(fileURLWithPath: "/offline/action-b.vmd"), loop: true)
        renderer.fails = false
        renderer.failingPaths = [failedA.url!.path]
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(failedA), sourceRevision: 10, activityRequestID: "pmx-a"))
        host.frame(renderer)
        precondition(renderer.attemptsByPath[failedA.url!.path] == 1, "bad motion A loads exactly once")
        let pmxEventsAfterA = pmxEvents.count
        precondition(pmxEventsAfterA == 3, "first A failure reports exactly one terminal event")
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(thinkingB), sourceRevision: 11, activityRequestID: "pmx-b"))
        host.frame(renderer)
        precondition(renderer.attemptsByPath[thinkingB.url!.path] == 1, "temporary thinking motion B plays once")
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(failedA), sourceRevision: 12, activityRequestID: "pmx-a"))
        host.frame(renderer)
        precondition(renderer.attemptsByPath[failedA.url!.path] == 1, "failed A must not reload after B with unchanged identity")
        precondition(pmxEvents.count == pmxEventsAfterA, "no duplicate failure callback for unchanged A identity")
        for _ in 0..<3 { host.frame(renderer) }
        precondition(renderer.attemptsByPath[failedA.url!.path] == 1, "failed identity stays suppressed across frames")
        let revisionBeforeRetry = store.snapshot.revision
        store.refresh(forcePlaybackReload: true)
        precondition(store.snapshot.revision == revisionBeforeRetry + 1, "force reload creates a new playback revision")
        renderer.failingPaths = []
        host.frame(renderer)
        precondition(renderer.attemptsByPath[failedA.url!.path] == 2, "explicit new playback revision permits one new load")
        precondition(host.failedPMXPlaybackIdentities.isEmpty, "failed identity retention clears on revision change")
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(failedA), sourceRevision: 13, activityRequestID: "pmx-a2"))
        host.frame(renderer)
        precondition(renderer.attemptsByPath[failedA.url!.path] == 3, "a new activity request permits one new load")
        // Bounded retention: distinct failed identities are capped.
        for index in 0..<40 {
            let floodURL = URL(fileURLWithPath: "/offline/flood-\(index).vmd")
            let flood = StageMotionAsset(id: "flood-\(index)", name: "Flood", format: .vmd, url: floodURL, loop: true)
            renderer.failingPaths = [floodURL.path]
            store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(flood), sourceRevision: 20 + UInt64(index), activityRequestID: "flood-\(index)"))
            host.frame(renderer)
        }
        precondition(host.failedPMXPlaybackIdentities.count <= 32, "failed identity retention is bounded")
        let pmxWalk = StageMotionAsset(id: "measured-walk", name: "Walk", format: .vmd,
            url: URL(fileURLWithPath: "/offline/measured-walk.vmd"), loop: true,
            strideSpeed: 0.75, playbackRate: 1, inPlace: true)
        renderer.failingPaths = []
        store.installWorldActivity(StageAvatarWorldActivitySnapshot(transform: WorldTransform(),
            activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: .temporary(pmxWalk),
            sourceRevision: 100, activityRequestID: "measured-walk"))
        host.frame(renderer)
        precondition(renderer.loadedLocomotionGait?.authoredStepSpeed == 0.75,
            "real PMX synchronizer must pass the measured gait to the renderer")
        store.removeMotionPlaybackObserver(pmxObserver)
        print("PASS: full XYZ, in-place XZ lock with original Y, authored rate and one-shot flag")
        print("PASS: once-only terminal events, stale request rejection and explicit playback retry identity")
        print("PASS: real PMX synchronizer caches failed attempts across 120 frames and allows explicit retry")
        print("PASS: failed identity survives temporary B playback without reload or duplicate failure, retries only on new revision/request")
        print("PASS: real PMX synchronizer forwards measured locomotion calibration")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motion-lifecycle-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let source = directory.appendingPathComponent("main.swift")
try harness.write(to: source, atomically: true, encoding: .utf8)
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
try run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", source.path, "-o", directory.appendingPathComponent("test").path])
try run(directory.appendingPathComponent("test").path, [])
