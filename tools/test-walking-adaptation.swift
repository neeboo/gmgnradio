// Hostless behavioral checks for walking auto-adaptation.
//
// Compiles the production gait/telemetry logic, the production VRM loader
// seams, the production PMX gait resolver, and the whole production executor
// walking linkage against inert shims. No AppKit, Metal, GPU, application
// bundle or network is started. Macro-free: the @Observable store is not
// embedded, only the pure declarations under test are extracted.
//
// Run from the repository root: swift tools/test-walking-adaptation.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

// Extracts a whole balanced declaration (signature through its closing brace).
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{")
    else {
        fatalError("Missing production declaration: \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced production declaration: \(signature)")
}

// Extracts one computed property body (used for isLocomotionLoop) so the real
// implementation compiles against a small asset stub.
func computedProperty(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{")
    else {
        fatalError("Missing production property: \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced production property: \(signature)")
}

let runtime = try read("apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift")
let executorSource = try read("apps/macos/Sources/GMGNRadio/Presence/StageAvatarActivityExecutor.swift")
let loader = try read("apps/macos/Sources/GMGNRadio/MMD/StageAvatarAnimationLoader.swift")
let pmx = try read("apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift")

guard runtime.contains("struct StageAvatarLocomotionTelemetry"),
      runtime.contains("struct StageLocomotionGait"),
      runtime.contains("func updateLocomotion("),
      runtime.contains("var isLocomotionLoop: Bool"),
      executorSource.contains("struct StageAvatarGroundSpeedMeter"),
      executorSource.contains("groundSpeedMeter.record("),
      executorSource.contains("runtime.updateLocomotion("),
      executorSource.contains("clock: @escaping () -> TimeInterval"),
      loader.contains("static func applyLocomotion("),
      loader.contains("static func locomotionGait("),
      loader.contains("static func measureHipsRestHeight("),
      pmx.contains("locomotionMeasuredSpeed"),
      pmx.contains("static func locomotionGait(") else {
    print("FAIL: walking-adaptation production surfaces are missing")
    exit(1)
}

let telemetryDecl = declaration(
    "struct StageAvatarLocomotionTelemetry:", in: runtime)
let gaitDecl = declaration("struct StageLocomotionGait:", in: runtime)
let isLocomotionLoopProperty = computedProperty(
    "var isLocomotionLoop: Bool", in: runtime)
let loaderLoadClip = declaration("static func loadClip(", in: loader)
let loaderMakePlayer = declaration("static func makeLoopingPlayer(", in: loader)
let loaderMakePlayerWithGait = declaration(
    "static func makeLoopingPlayerWithGait(", in: loader)
let loaderApply = declaration("static func applyLocomotion(", in: loader)
let loaderGait = declaration("static func locomotionGait(", in: loader)
let loaderHips = declaration("static func measureHipsRestHeight(", in: loader)
let pmxGait = declaration("static func locomotionGait(", in: pmx)
let executorBody = executorSource.replacingOccurrences(
    of: "import WorldRuntime", with: "")

let harness = #"""
import Foundation
import simd
import os

// MARK: Shims (WorldRuntime, VRMMetalKit and renderers stay outside this build)

struct WorldVector3: Equatable, Sendable { var x: Float = 0; var y: Float = 0; var z: Float = 0 }
struct WorldQuaternion: Equatable, Sendable { var x: Float = 0; var y: Float = 0; var z: Float = 0; var w: Float = 1 }
struct WorldTransform: Equatable, Sendable { var position = WorldVector3(); var rotation = WorldQuaternion() }
struct LifeActivity: Equatable, Sendable { let typeID: String }
enum LifeActivityPhase: String, Sendable { case approach, enter, loop, exit }
struct ActivityPhaseContract { let phase: LifeActivityPhase }

struct StageMotionAsset: Equatable, Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL?
    var loop = false
    var inPlace: Bool? = false
    var strideSpeed: Float? = nil
    var playbackRate: Float = 1
    \#(isLocomotionLoopProperty)
}
enum StageMotionFormat: String { case procedural, vrma, vmd }

// MARK: Production pure logic extracted from StageAvatarRuntime.swift

\#(telemetryDecl)
\#(gaitDecl)

// MARK: Full production loader compiled against inert shims

struct LocomotionMetadata { var strideSpeed: Float = 0; var sourceHipsHeight: Float = 0 }
enum VRMHumanoidBone: Equatable { case hips, head }
struct JointTrack {
    let bone: VRMHumanoidBone
    let rotationSampler: ((Float) -> simd_quatf)?
    let translationSampler: ((Float) -> SIMD3<Float>)?
    let scaleSampler: ((Float) -> SIMD3<Float>)?
}
struct AnimationClip {
    var jointTracks: [JointTrack] = []
    var locomotion: LocomotionMetadata? = nil
}
enum MotionPackageError: Error { case motionNotFound }
struct VRMHumanoid {
    func getBoneNode(_ bone: VRMHumanoidBone) -> Int? { bone == .hips ? 1 : nil }
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
    var loadCount = 0
    func load(_ clip: AnimationClip) { self.clip = clip; loadCount += 1 }
}

struct StageAvatarAnimationLoad {
    let player: AnimationPlayer?
    let gait: StageLocomotionGait?
}
enum VRMAnimationLoader {
    static func loadVRMA(from url: URL, model: VRMModel) throws -> AnimationClip {
        var clip = AnimationClip()
        clip.jointTracks = [JointTrack(bone: .hips, rotationSampler: nil,
            translationSampler: { SIMD3<Float>(2 + $0, 1 + $0 * 2, 3 - $0) },
            scaleSampler: nil)]
        clip.locomotion = LocomotionMetadata(strideSpeed: 1.4007615, sourceHipsHeight: 0.90)
        return clip
    }
}
enum NanoemVMDLoader { static func load(from url: URL) throws -> Int { 0 } }
enum VMDToVRMClipAdapter {
    static func makeClip(from document: Int, model: VRMModel) -> AnimationClip {
        AnimationClip()
    }
}

enum StageAvatarAnimationLoader {
    \#(loaderLoadClip)
    \#(loaderMakePlayer)
    \#(loaderMakePlayerWithGait)
    \#(loaderApply)
    \#(loaderGait)
    \#(loaderHips)
}

enum PMXStageAvatarRenderer {
    \#(pmxGait)
}

// MARK: Production executor walking linkage embedded verbatim

struct StageMotionPlaybackIdentity { let motion: StageMotionAsset; let worldActivityRequestID: String?; let worldActivityPhase: LifeActivityPhase? }
enum StageMotionPlaybackOutcome { case completed, failed(String) }
struct StageMotionPlaybackEvent { let identity: StageMotionPlaybackIdentity; let outcome: StageMotionPlaybackOutcome }
struct Fallback { let requestedMotionIDs: [String]; let activityTypeID: String; let phase: LifeActivityPhase; let reason: LifeActivityPhase }
enum StageAvatarMotionPlayback: Equatable, Sendable {
    case temporary(StageMotionAsset)
    var fallback: Fallback? { nil }
    static func resolve(activity: LifeActivity, phase: LifeActivityPhase,
                        phaseContract: ActivityPhaseContract?,
                        approvedMotions: [String: StageMotionAsset]) -> Self {
        // Mirrors the real resolver for the harness: a locomotion asset in the
        // approved set wins, otherwise a plain non-locomotion one-shot.
        if let walk = approvedMotions.values.first(where: { $0.isLocomotionLoop }) {
            return .temporary(walk)
        }
        return .temporary(StageMotionAsset(id: "one-shot", name: "One Shot", format: .vrma, url: nil))
    }
}
struct StageAvatarWorldActivitySnapshot: Equatable, Sendable {
    let transform: WorldTransform; let activity: LifeActivity; let phase: LifeActivityPhase
    let motionPlayback: StageAvatarMotionPlayback; let sourceRevision: UInt64
    var activityRequestID: String? = nil
}
struct StageAvatarPlacement { let position: SIMD3<Float>; let scale: Float; let yaw: Float }
@MainActor final class StageAvatarRuntimeStore {
    var worldActivity: StageAvatarWorldActivitySnapshot?
    var installs = 0
    var locomotion = StageAvatarLocomotionTelemetry.standing
    func installWorldActivity(_ value: StageAvatarWorldActivitySnapshot) { installs += 1; worldActivity = value }
    func clearWorldActivity() { worldActivity = nil }
    func updateLocomotion(_ value: StageAvatarLocomotionTelemetry) {
        if value != locomotion { locomotion = value }
    }
}
@MainActor final class SpatialStageStore {
    var avatarPlacement = StageAvatarPlacement(position: .zero, scale: 1, yaw: 0)
    var placementWrites = 0
    func setWorldAvatarPlacement(_ value: StageAvatarPlacement) { avatarPlacement = value; placementWrites += 1 }
    func clearTransientAvatarPlacement() {}
}

\#(executorBody)

@main struct Test {
    @MainActor static func main() {
        // 1. Reproduction of the current insufficiency: authored rate alone is
        //    static. A 1.4 m/s walk at 1.0 m/s actual travel would overstride;
        //    the adaptive rate must be ~0.714 rather than the authored 1.
        let walk = StageMotionAsset(id: "walk", name: "Walk", format: .vrma, url: URL(fileURLWithPath: "/offline/walk.vrma"),
                                    loop: true, inPlace: true, strideSpeed: 1.4007615)
        precondition(walk.isLocomotionLoop, "walk with stride contract is locomotion")
        let idle = StageMotionAsset(id: "idle", name: "Idle", format: .vrma, url: nil, loop: true, inPlace: true)
        precondition(!idle.isLocomotionLoop, "idle loop without stride is not locomotion")
        let dance = StageMotionAsset(id: "dance", name: "Dance", format: .vrma, url: nil, loop: true,
                                     inPlace: false, strideSpeed: 1.0)
        precondition(!dance.isLocomotionLoop, "non-in-place clip is never locomotion")

        let gait = StageLocomotionGait(authoredStepSpeed: 1.4007615,
                                       sourceHipsHeight: 0.90, targetHipsHeight: 0.90)
        precondition(abs(gait.playbackRate(forGroundSpeed: 1.4) - 1.0) < 1e-3)
        precondition(abs(gait.playbackRate(forGroundSpeed: 1.0) - (1.0 / 1.4007615)) < 1e-3,
                     "slow actual travel must slow the clip below authored rate")

        // 2. Zero speed: hard freeze (rate 0); the phase is never reset.
        let player = AnimationPlayer()
        player.speed = 1
        StageAvatarAnimationLoader.applyLocomotion(
            telemetry: StageAvatarLocomotionTelemetry(measuredSpeed: 0, isLocomotionActive: true),
            gait: gait, player: player)
        precondition(player.speed == 0 && player.loadCount == 0,
                     "zero speed freezes without restarting the clip")

        // 3. Constant-speed regression: at the authored speed the rate stays
        //    exactly 1 and the step phase integrates the actually traveled
        //    distance (distance/step).
        var phase = Float(0)
        let dt = Float(1.0 / 30.0)
        let authoredGroundSpeed = gait.authoredStepSpeed
        var x = Float(0)
        for _ in 0..<300 {
            x += authoredGroundSpeed * dt
            let rate = gait.playbackRate(forGroundSpeed: authoredGroundSpeed)
            phase += rate * dt
            precondition(abs(rate - 1) < 1e-4, "constant authored speed keeps rate 1")
        }
        precondition(abs(phase - x / gait.impliedStepSpeed) < 1e-3,
                     "step phase must integrate actual traveled distance")

        // 4. Speed changes auto-correct with clamping (no run clip exists).
        precondition(abs(gait.playbackRate(forGroundSpeed: 0.7) - 0.5) < 1e-3)
        precondition(abs(gait.playbackRate(forGroundSpeed: 2.1) - 1.3) < 1e-3,
                     "above authored speed the rate is capped")
        precondition(gait.playbackRate(forGroundSpeed: 0.03) == 0,
                     "near standstill freezes instead of marching in place")

        // 5. Character-proportion changes auto-correct via the hips ratio.
        let tallGait = StageLocomotionGait(authoredStepSpeed: 1.4007615,
                                           sourceHipsHeight: 0.90, targetHipsHeight: 1.35)
        precondition(abs(tallGait.heightScale - 1.5) < 1e-3)
        precondition(abs(tallGait.playbackRate(forGroundSpeed: 1.4) - (1.0 / 1.5)) < 1e-3,
                     "taller rig at same nav speed needs slower cadence")
        let smallGait = StageLocomotionGait(authoredStepSpeed: 1.4007615,
                                            sourceHipsHeight: 0.90, targetHipsHeight: 0.45)
        precondition(abs(smallGait.heightScale - 0.5) < 1e-3)
        precondition(abs(smallGait.playbackRate(forGroundSpeed: 1.4) - 1.3) < 1e-3,
                     "shorter rig rate is capped rather than absurd")
        let unknownGait = StageLocomotionGait(authoredStepSpeed: 1.4007615)
        precondition(unknownGait.heightScale == 1,
                     "missing hips data must not fabricate a proportion correction")

        // 6. VRM vs PMX gait resolution.
        //    VRM: manifest stride + VRMA source hips + measured target hips.
        let root = VRMNode(); root.initialTranslation = SIMD3<Float>(0, 0.45, 0)
        let hipsNode = VRMNode(); hipsNode.initialTranslation = SIMD3<Float>(0, 0.9, 0)
        hipsNode.parent = root
        var model = VRMModel()
        model.nodes = [root, hipsNode]
        model.humanoid = VRMHumanoid()
        var clip = AnimationClip()
        clip.locomotion = LocomotionMetadata(strideSpeed: 1.4007615, sourceHipsHeight: 0.90)
        let vrmGait = StageAvatarAnimationLoader.locomotionGait(for: walk, clip: clip, model: model)
        precondition(vrmGait != nil && abs(vrmGait!.targetHipsHeight! - 1.35) < 1e-3
                     && abs(vrmGait!.heightScale - 1.5) < 1e-3,
                     "VRM gait must measure target hips and read source hips from the clip")
        //    PMX: VMD carries no source-rig hips; the scale stays 1 (no data,
        //    no invented correction). authoredStepSpeed is the *measured*
        //    rate-1 feet-plant speed of the shipped walk-loop-pmx VMD on the
        //    na_2b rig (stance-drift regression 0.72-0.78 m/s, cadence ~86
        //    steps/min), so the bootstrap default nav speed equals it and the
        //    normal constant-speed cruise keeps rate exactly 1 (no maxRate cap).
        let pmxWalk = StageMotionAsset(id: "walk-pmx", name: "Walk PMX", format: .vmd, url: nil,
                                       loop: true, inPlace: true, strideSpeed: 0.75)
        let pmxGait = PMXStageAvatarRenderer.locomotionGait(for: pmxWalk)
        precondition(pmxGait != nil && pmxGait!.sourceHipsHeight == nil
                     && pmxGait!.targetHipsHeight == nil && pmxGait!.heightScale == 1)
        precondition(abs(pmxGait!.playbackRate(forGroundSpeed: 0.75) - 1.0) < 1e-3,
                     "PMX measured speed keeps the normal constant-speed behavior")
        precondition(abs(pmxGait!.playbackRate(forGroundSpeed: 1.5) - StageLocomotionGait.maximumRate) < 1e-3,
                     "speeds beyond the clip contract clamp at maximumRate (slide boundary, no run clip)")
        precondition(abs(pmxGait!.impliedStepSpeed - 0.75) < 1e-6,
                     "implied step speed is the measured stride contract, never a silent constant")

        // 6b. Full loader, one pass: authored cadence preserved, hips XZ
        //     anchored at the loop anchor with authored Y kept, and the gait is
        //     returned alongside the player without a second decode.
        var loaderModel = VRMModel()
        let lroot = VRMNode(); lroot.initialTranslation = SIMD3<Float>(0, 0.45, 0)
        let lhips = VRMNode(); lhips.initialTranslation = SIMD3<Float>(0, 0.9, 0)
        lhips.parent = lroot
        loaderModel.nodes = [lroot, lhips]
        loaderModel.humanoid = VRMHumanoid()
        let load = try! StageAvatarAnimationLoader.makeLoopingPlayerWithGait(
            for: walk, model: loaderModel)
        precondition(load.player != nil && load.player!.speed == 1,
                     "authored cadence stays 1 for the VRM walk")
        let sample = load.player!.clip!.jointTracks[0].translationSampler!(2)
        precondition(abs(sample.x - 2) < 1e-6 && abs(sample.z - 3) < 1e-6
                     && abs(sample.y - 5) < 1e-6,
                     "in-place hips lock XZ at the loop anchor but keep authored Y")
        precondition(load.gait != nil && abs(load.gait!.heightScale - 1.5) < 1e-3,
                     "one-pass load must also return the gait for the retimer")
        let legacy = try! StageAvatarAnimationLoader.makeLoopingPlayer(
            for: walk, model: loaderModel)
        precondition(legacy != nil && legacy!.speed == 1,
                     "legacy loader entry keeps its behavior")

        // 7. Executor linkage: measured ground speed follows the actual world
        //    transform stream; locomotion-active only while a walk resolves.
        let store = StageAvatarRuntimeStore(), stage = SpatialStageStore()
        var now: TimeInterval = 0
        let executor = StageAvatarActivityExecutor(runtime: store, spatialStage: stage,
                                                   worldSpawn: WorldTransform(),
                                                   clock: { now })
        let activity = LifeActivity(typeID: "walk")
        var positionX = Float(0)
        func tick(_ dx: Float, revision: UInt64) {
            now += 1.0 / 30.0
            positionX += dx
            var transform = WorldTransform()
            transform.position.x = positionX
            _ = executor.apply(transform: transform, activity: activity, phase: .approach,
                               sourceRevision: revision,
                               approvedMotions: ["walk": walk])
        }
        for revision in 1...90 { tick(1.4 / 30, revision: UInt64(revision)) }
        precondition(abs(store.locomotion.measuredSpeed - 1.4) < 0.08,
                     "steady 1.4 m/s travel must be measured within tolerance")
        precondition(store.locomotion.isLocomotionActive, "resolved walk loop activates locomotion")

        // 8. Curve/block slowdown: half the displacement at the same cadence.
        for revision in 91...180 { tick(0.7 / 30, revision: UInt64(revision)) }
        precondition(abs(store.locomotion.measuredSpeed - 0.7) < 0.08,
                     "half-displacement travel must halve the measured speed")
        let slowed = gait.playbackRate(forGroundSpeed: store.locomotion.measuredSpeed)
        precondition(abs(slowed - 0.5) < 0.08, "clip rate follows the measured slowdown")

        // 9. Stop: no marching in place. The estimate decays below the freeze
        //    threshold while the walk loop is still resolved.
        for revision in 181...300 { tick(0, revision: UInt64(revision)) }
        precondition(store.locomotion.measuredSpeed < StageLocomotionGait.freezeSpeed,
                     "standing world must report standstill")
        precondition(gait.playbackRate(forGroundSpeed: store.locomotion.measuredSpeed) == 0,
                     "driver freezes instead of striding in place")
        let frozenPlayer = AnimationPlayer()
        StageAvatarAnimationLoader.applyLocomotion(
            telemetry: store.locomotion, gait: gait, player: frozenPlayer)
        precondition(frozenPlayer.speed == 0 && frozenPlayer.loadCount == 0,
                     "stop freezes in place with continuous phase")

        // 10. Resume keeps phase continuous: the same player is only retimed.
        for revision in 301...360 { tick(1.4 / 30, revision: UInt64(revision)) }
        StageAvatarAnimationLoader.applyLocomotion(
            telemetry: store.locomotion, gait: gait, player: frozenPlayer)
        precondition(frozenPlayer.loadCount == 0 && frozenPlayer.speed > 0,
                     "resume only retimes the existing player, never reloads")

        // 11. Non-locomotion playback leaves the player's authored rate alone.
        let idleStore = StageAvatarRuntimeStore(), idleStage = SpatialStageStore()
        let idleExecutor = StageAvatarActivityExecutor(runtime: idleStore, spatialStage: idleStage,
                                                       worldSpawn: WorldTransform(), clock: { now })
        _ = idleExecutor.apply(transform: WorldTransform(), activity: LifeActivity(typeID: "idle"),
                               phase: .loop, sourceRevision: 1,
                               approvedMotions: ["dance": dance])
        let authoredPlayer = AnimationPlayer()
        authoredPlayer.speed = 1.25
        StageAvatarAnimationLoader.applyLocomotion(
            telemetry: idleStore.locomotion, gait: gait, player: authoredPlayer)
        precondition(authoredPlayer.speed == 1.25,
                     "idle/dance playback keeps its authored cadence untouched")

        // 12. Telemetry coalescing and world-clear reset.
        let before = store.locomotion
        store.updateLocomotion(before)
        precondition(store.locomotion == before, "equal telemetry is coalesced")
        _ = executor.clear(sourceRevision: 400)
        precondition(store.locomotion == .standing, "world clear resets locomotion telemetry")

        // 13. Measured PMX contract at the bootstrap default speed: cruising at
        //     the measured 0.75 m/s keeps rate exactly 1 (feet planted, far
        //     under the 1.3 cap); temporary world pauses freeze in place for as
        //     long as the pause lasts (no marching), and clearing the world
        //     stops the locomotion flag without reloading or rewinding the
        //     animation player, so the phase stays continuous.
        let pmxStore = StageAvatarRuntimeStore(), pmxStage = SpatialStageStore()
        var pmxNow: TimeInterval = 0
        let pmxExecutor = StageAvatarActivityExecutor(runtime: pmxStore, spatialStage: pmxStage,
                                                      worldSpawn: WorldTransform(), clock: { pmxNow })
        let walkActivity = LifeActivity(typeID: "walk")
        var pmxX = Float(0)
        func pmxTick(_ dx: Float, revision: UInt64) {
            pmxNow += 1.0 / 30.0
            pmxX += dx
            var transform = WorldTransform()
            transform.position.x = pmxX
            _ = pmxExecutor.apply(transform: transform, activity: walkActivity, phase: .approach,
                                  sourceRevision: revision, approvedMotions: ["walk": pmxWalk])
        }
        for revision in 1...90 { pmxTick(0.75 / 30, revision: UInt64(revision)) }
        precondition(abs(pmxStore.locomotion.measuredSpeed - 0.75) < 0.05,
                     "steady cruise at the measured PMX contract is measured as such")
        let pmxCruise = pmxGait!.playbackRate(forGroundSpeed: pmxStore.locomotion.measuredSpeed)
        precondition(abs(pmxCruise - 1.0) < 0.1 && pmxCruise < StageLocomotionGait.maximumRate,
                     "default world speed equals the measured stride contract: no long-term maxRate cap")
        let cruisePlayer = AnimationPlayer()
        StageAvatarAnimationLoader.applyLocomotion(telemetry: pmxStore.locomotion, gait: pmxGait!, player: cruisePlayer)
        precondition(abs(cruisePlayer.speed - 1.0) < 0.1, "cruise keeps the natural cadence")

        // A long paused world (walk still resolved) must freeze, not march.
        for revision in 91...300 { pmxTick(0, revision: UInt64(revision)) }
        precondition(pmxStore.locomotion.measuredSpeed < StageLocomotionGait.freezeSpeed,
                     "paused world decays to standstill while the walk loop stays resolved")
        precondition(pmxGait!.playbackRate(forGroundSpeed: pmxStore.locomotion.measuredSpeed) == 0,
                     "paused world never steps in place")
        let pausePlayer = AnimationPlayer()
        pausePlayer.speed = 1
        StageAvatarAnimationLoader.applyLocomotion(telemetry: pmxStore.locomotion, gait: pmxGait!, player: pausePlayer)
        precondition(pausePlayer.speed == 0 && pausePlayer.loadCount == 0,
                     "temporary pause freezes the same player; phase is not reset")

        // Clear: world activity ends -> locomotion flag off, telemetry standing.
        _ = pmxExecutor.clear(sourceRevision: 400)
        precondition(pmxStore.locomotion == .standing && !pmxStore.locomotion.isLocomotionActive,
                     "clear stops locomotion telemetry without leaving a stale walk flag")
        StageAvatarAnimationLoader.applyLocomotion(telemetry: pmxStore.locomotion, gait: pmxGait!, player: pausePlayer)
        precondition(pausePlayer.loadCount == 0, "post-clear telemetry never reloads or rewinds the clip")

        // Re-applied world resume retimes only: no reload, phase continuous.
        for revision in 401...460 { pmxTick(0.75 / 30, revision: UInt64(revision)) }
        StageAvatarAnimationLoader.applyLocomotion(telemetry: pmxStore.locomotion, gait: pmxGait!, player: pausePlayer)
        precondition(pausePlayer.loadCount == 0 && pausePlayer.speed > 0,
                     "resume after pause+clear retimes the existing player; phase continuity is preserved")

        print("PASS: 13 walking-adaptation groups (rate math, zero/varied speed, proportions, VRM/PMX measured contract, executor ground-speed linkage, pause/clear in-place freeze with continuous phase, cap policy at cruise)")
    }
}
"""#

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("walking-adaptation-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("main.swift")
let binary = directory.appendingPathComponent("test")
try harness.write(to: file, atomically: true, encoding: .utf8)
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", file.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process()
run.executableURL = binary
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
