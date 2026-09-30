// Hostless behavioral checks for the walking/idle motion contract.
//
// The contract the user asked for: **an avatar whose ground is moving always
// has a walking pose, and an avatar that is standing always has micro-motion.**
// A world/activity declaration stays the first choice; the built-in BONES
// walk/idle loops are the default. Nothing here launches the app, Metal, the
// GPU, the network or a user store: the real resolver, the real locomotion
// policy and the real executor are compiled against inert shims.
//
// Run from the repository root: swift tools/test-resident-walk-motion-default.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

let resolver = try read("apps/macos/Sources/GMGNRadio/VisualEngine/StageAvatarMotionPlayback.swift")
    .replacingOccurrences(of: "import WorldRuntime", with: "")
let policy = try read("apps/macos/Sources/GMGNRadio/Presence/ResidentLocomotionMotionPolicy.swift")
let executor = try read("apps/macos/Sources/GMGNRadio/Presence/StageAvatarActivityExecutor.swift")
    .replacingOccurrences(of: "import WorldRuntime", with: "")
let runtime = try read("apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift")
let view = try read("apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift")

// The production surfaces this harness is about must exist before it can test
// them; a rename that silently drops the default would otherwise "pass".
guard policy.contains("static func walkMotionIDs("),
      policy.contains("static func defaultMotionIDs("),
      policy.contains("func isPlayable("),
      executor.contains("ResidentLocomotionMotionPolicy.defaultMotionIDs("),
      executor.contains("No usable walking motion"),
      executor.contains("Defaulting to built-in walk motion while the ground moves"),
      executor.contains("static func visualPlayback("),
      resolver.contains("case naturalIdle") else {
    print("FAIL: the walking-motion default policy or its executor linkage is missing")
    exit(1)
}
// The separation is a code fact, not a comment: what the world declared drives
// receipts; what the renderer draws is the movement-driven channel.
guard view.contains("worldPlayback: avatarRuntime.worldActivity?.renderPlayback") else {
    print("FAIL: the renderer must draw the movement-driven renderPlayback, not the world declaration")
    exit(1)
}
let identityBody = declaration("func playbackIdentity(", in: runtime)
guard identityBody.contains("worldActivity?.motionPlayback"),
      !identityBody.contains("renderPlayback"),
      !identityBody.contains("visualPlayback") else {
    print("FAIL: a locomotion substitute must never carry a world request identity (its failure/completion would be written back as a world receipt)")
    exit(1)
}

// Production declarations extracted verbatim so the harness cannot drift from
// the shipped gait/telemetry math.
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
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
func computedProperty(_ signature: String, in source: String) -> String {
    declaration(signature, in: source)
}
let telemetryDecl = declaration("struct StageAvatarLocomotionTelemetry:", in: runtime)
let gaitDecl = declaration("struct StageLocomotionGait:", in: runtime)
let isLocomotionLoop = computedProperty("var isLocomotionLoop: Bool", in: runtime)

// The two real-machine timelines are replayed from the *shipped* package so
// the harness cannot drift from what the cabin actually declares.
let cabinWorld = try JSONSerialization.jsonObject(
    with: Data(contentsOf: root.appendingPathComponent(
        "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
    as? [String: Any] ?? [:]
func phaseMotionIDs(_ activityID: String, _ phase: String) -> [String] {
    guard let definitions = cabinWorld["activityDefinitions"] as? [[String: Any]],
          let definition = definitions.first(where: { $0["id"] as? String == activityID }),
          let phases = definition["phases"] as? [[String: Any]],
          let entry = phases.first(where: { $0["phase"] as? String == phase })
    else { return [] }
    return entry["motionIDs"] as? [String] ?? []
}
let collectEnterMotionIDs = phaseMotionIDs("wish_machine.collect", "enter")
let homeWalkApproachMotionIDs = phaseMotionIDs("home.walk", "approach")
guard collectEnterMotionIDs.isEmpty,
      homeWalkApproachMotionIDs.contains("gmgn.motion.bones.walk-loop-pmx") else {
    print("FAIL: the shipped cabin package no longer matches the timelines this harness replays")
    exit(1)
}

let harness = #"""
import Foundation
import simd
import os

// MARK: WorldRuntime shims

struct WorldVector3: Equatable, Sendable { var x: Float = 0; var y: Float = 0; var z: Float = 0 }
struct WorldQuaternion: Equatable, Sendable { var x: Float = 0; var y: Float = 0; var z: Float = 0; var w: Float = 1 }
struct WorldTransform: Equatable, Sendable { var position = WorldVector3(); var rotation = WorldQuaternion() }
enum LifeActivity: Equatable, Sendable {
    case idle
    case walk(destinationID: String)
    case interact(anchorID: String)
    var typeID: String {
        switch self {
        case .idle: "idle"
        case .walk: "walk"
        case .interact: "interact"
        }
    }
}
enum LifeActivityPhase: String, Sendable { case approach, enter, loop, exit, interrupt, failed }
enum StageAvatarFormat: String, Sendable { case vrm, pmx }
enum StageMotionFormat: String, Sendable { case procedural, vrma, vmd }
struct ActivityPhaseContract {
    let phase: LifeActivityPhase
    var requiredAnchorIDs: [String] = []
    var motionIDs: [String] = []
    var propIDs: [String] = []
    var durationSeconds: TimeInterval? = nil
}
struct StageMotionAsset: Equatable, Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL?
    var loop = true
    var playbackRate: Float = 1
    var inPlace: Bool? = nil
    var strideSpeed: Float? = nil
    \#(isLocomotionLoop)
}

extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { appendLiteral(String(describing: value)) }
}
enum Privacy { case `public` }

// MARK: Production telemetry + gait + resolver + policy

\#(telemetryDecl)
\#(gaitDecl)
\#(resolver)
\#(policy)

// MARK: Executor host shims

struct StageAvatarPlacement { let position: SIMD3<Float>; let scale: Float; let yaw: Float }
struct StageAvatarWorldActivitySnapshot: Equatable, Sendable {
    let transform: WorldTransform
    let activity: LifeActivity
    let phase: LifeActivityPhase
    let motionPlayback: StageAvatarMotionPlayback
    let sourceRevision: UInt64
    var activityRequestID: String? = nil
    var visualPlayback: StageAvatarMotionPlayback? = nil
    var renderPlayback: StageAvatarMotionPlayback {
        visualPlayback ?? motionPlayback
    }
}
struct StageAvatarAssetSnapshot { let format: StageAvatarFormat }
struct StageAvatarRuntimeSnapshotShim { let avatar: StageAvatarAssetSnapshot? }
@MainActor final class StageAvatarRuntimeStore {
    var worldActivity: StageAvatarWorldActivitySnapshot?
    var locomotion = StageAvatarLocomotionTelemetry.standing
    var snapshot = StageAvatarRuntimeSnapshotShim(avatar: StageAvatarAssetSnapshot(format: .pmx))
    func installWorldActivity(_ value: StageAvatarWorldActivitySnapshot) { worldActivity = value }
    func clearWorldActivity() { worldActivity = nil }
    func updateLocomotion(_ value: StageAvatarLocomotionTelemetry) {
        if value != locomotion { locomotion = value }
    }
}
@MainActor final class SpatialStageStore {
    var avatarPlacement = StageAvatarPlacement(position: .zero, scale: 1, yaw: 0)
    func setWorldAvatarPlacement(_ value: StageAvatarPlacement) { avatarPlacement = value }
    func clearTransientAvatarPlacement() {}
}

\#(executor)

// MARK: Fixtures

let walkPMX = StageMotionAsset(
    id: "gmgn.motion.bones.walk-loop-pmx", name: "walk", format: .vmd,
    url: URL(fileURLWithPath: "/offline/gmgn.motion.bones.walk-loop-pmx.vmd"),
    loop: true, inPlace: true, strideSpeed: 0.75)
let walkVRM = StageMotionAsset(
    id: "gmgn.motion.bones.walk-loop-vrm", name: "walk", format: .vrma,
    url: URL(fileURLWithPath: "/offline/gmgn.motion.bones.walk-loop-vrm.vrma"),
    loop: true, inPlace: true, strideSpeed: 1.4)
let idlePMX = StageMotionAsset(
    id: "gmgn.motion.bones.idle-loop-pmx", name: "idle", format: .vmd,
    url: URL(fileURLWithPath: "/offline/gmgn.motion.bones.idle-loop-pmx.vmd"),
    loop: true, inPlace: true)
let dancePMX = StageMotionAsset(
    id: "gmgn.motion.bones.jumping-jacks-pmx", name: "dance", format: .vmd,
    url: URL(fileURLWithPath: "/offline/gmgn.motion.bones.jumping-jacks-pmx.vmd"),
    loop: true, inPlace: false)
/// A walk clip the *world* declares, under its own id and a different format
/// than the avatar: it must never reach the PMX loader.
let declaredVRMWalk = StageMotionAsset(
    id: "world.declared.walk", name: "declared", format: .vrma,
    url: URL(fileURLWithPath: "/offline/declared.vrma"), loop: true, inPlace: true)
let declaredPMXWalk = StageMotionAsset(
    id: "world.declared.pmx.walk", name: "declared", format: .vmd,
    url: URL(fileURLWithPath: "/offline/declared-pmx.vmd"),
    loop: true, inPlace: true, strideSpeed: 0.75)

let approved = [walkPMX.id: walkPMX, walkVRM.id: walkVRM, idlePMX.id: idlePMX,
                dancePMX.id: dancePMX, declaredVRMWalk.id: declaredVRMWalk,
                declaredPMXWalk.id: declaredPMXWalk]

// Read from the shipped `marble-living-cabin` package by the outer script.
let wishMachineCollectEnterMotionIDs: [String] = \#(collectEnterMotionIDs)
let homeWalkApproachMotionIDs: [String] = \#(homeWalkApproachMotionIDs)

/// Drives the real executor over `translations` (metres per 30 Hz tick) and
/// hands back the last snapshot, so both channels can be inspected:
/// `motionPlayback` is the world's declaration (the report), `renderPlayback`
/// is what the renderer draws.
@MainActor
func snapshot(
    activity: LifeActivity = .walk(destinationID: "wp.center"),
    phase: LifeActivityPhase = .approach,
    contract: ActivityPhaseContract?,
    approvedMotions: [String: StageMotionAsset] = approved,
    avatarFormat: StageAvatarFormat = .pmx,
    translations: [Float] = [0, 0.025, 0.05]
) -> StageAvatarWorldActivitySnapshot? {
    let store = StageAvatarRuntimeStore()
    store.snapshot = StageAvatarRuntimeSnapshotShim(avatar: StageAvatarAssetSnapshot(format: avatarFormat))
    let stage = SpatialStageStore()
    var now: TimeInterval = 0
    let subject = StageAvatarActivityExecutor(
        runtime: store, spatialStage: stage, worldSpawn: WorldTransform(), clock: { now })
    for (index, x) in translations.enumerated() {
        var transform = WorldTransform()
        transform.position.x = x
        _ = subject.apply(
            transform: transform, activity: activity, phase: phase,
            sourceRevision: UInt64(index + 1), activityRequestID: "request-\(index)",
            phaseContract: contract, approvedMotions: approvedMotions)
        now += 1.0 / 30.0
    }
    return store.worldActivity
}

@MainActor
@main struct Test {
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
        }
        func temporaryID(_ playback: StageAvatarMotionPlayback?) -> String? {
            guard case let .temporary(motion)? = playback else { return nil }
            return motion.id
        }
        func declared(_ snap: StageAvatarWorldActivitySnapshot?) -> StageAvatarMotionPlayback? {
            snap?.motionPlayback
        }
        func visual(_ snap: StageAvatarWorldActivitySnapshot?) -> StageAvatarMotionPlayback? {
            snap?.renderPlayback
        }

        // 1. **Movement, not the phase, decides the pose.** A resident walking
        //    towards a machine passes through `.enter` / `.exit` /
        //    `.interrupt` while its ground is still moving; every one of those
        //    phases must draw the walking clip. The declaration in each case is
        //    hostile in the way the real machine is: absent, empty (the cabin's
        //    `wish_machine.collect` declares no motion at all), naming a clip
        //    nobody installed, or naming a clip in the wrong container.
        let phases: [LifeActivityPhase] = [.approach, .enter, .loop, .exit, .interrupt, .failed]
        let declarations: [(String, ActivityPhaseContract?)] = [
            ("no contract", nil),
            ("empty declaration", ActivityPhaseContract(phase: .enter, motionIDs: [])),
            ("uninstalled declaration",
             ActivityPhaseContract(phase: .enter, motionIDs: ["gmgn.motion.bones.walk-loop-gone"])),
            ("wrong-container declaration",
             ActivityPhaseContract(phase: .enter, motionIDs: [declaredVRMWalk.id])),
        ]
        for phase in phases {
            for (label, template) in declarations {
                let contract = template.map {
                    ActivityPhaseContract(phase: phase, requiredAnchorIDs: $0.requiredAnchorIDs,
                                          motionIDs: $0.motionIDs, propIDs: $0.propIDs,
                                          durationSeconds: $0.durationSeconds)
                }
                let snap = snapshot(
                    activity: .interact(anchorID: "wish_machine.device"),
                    phase: phase, contract: contract)
                expect(temporaryID(visual(snap)) == walkPMX.id,
                       "phase \(phase.rawValue) with \(label): the ground is moving, so the avatar must play the built-in walk clip (movement decides, not the phase); got \(String(describing: visual(snap)))")
            }
        }

        // 2. A declared, installed clip still outranks the default.
        let declaredWins = snapshot(contract: ActivityPhaseContract(
            phase: .approach, motionIDs: [declaredPMXWalk.id, walkPMX.id]))
        expect(temporaryID(visual(declaredWins)) == declaredPMXWalk.id,
               "a declared, installed clip stays the first choice")
        expect(temporaryID(declared(declaredWins)) == declaredPMXWalk.id,
               "the declaration channel reports the declared clip, not the default")

        // 3. The first tick of a walk already walks (the approach phase is the
        //    executor's own authoritative walking fact, before a second
        //    position sample exists to measure).
        let firstTick = snapshot(
            activity: .interact(anchorID: "wish_machine.device"),
            phase: .approach, contract: nil, translations: [0])
        expect(temporaryID(visual(firstTick)) == walkPMX.id,
               "the first tick of a walk already has a walking pose")

        // 4. Standing still must NOT walk: movement is the criterion, not the
        //    phase, so a settled `.enter` keeps the declaration's idle.
        let standingEnter = snapshot(
            activity: .interact(anchorID: "wish_machine.device"),
            phase: .enter, contract: ActivityPhaseContract(phase: .enter, motionIDs: []),
            translations: [5, 5, 5])
        expect(temporaryID(visual(standingEnter)) == nil,
               "a settled enter phase must not walk, got \(String(describing: visual(standingEnter)))")
        expect(standingEnter?.motionPlayback.fallback != nil,
               "a settled enter phase without a motion still reports the fallback")

        // 5. **The fail-closed report is separate from the drawing.** On a
        //    moving `.enter` without a usable declared motion the body walks,
        //    and the world declaration must *still* read as an unmet fallback:
        //    the host turns that into a failed capability usage, and it must
        //    not be satisfied by the walking substitute.
        let movingEnter = snapshot(
            activity: .interact(anchorID: "coffee.brew@object"),
            phase: .enter, contract: ActivityPhaseContract(phase: .enter, motionIDs: []))
        expect(movingEnter?.motionPlayback.fallback != nil,
               "an enter phase without a motion still reports the fallback the host fails closed on")
        expect(temporaryID(visual(movingEnter)) == walkPMX.id,
               "the same moving enter phase draws the walking clip (playback and receipt are separate)")

        // 6. Idle micro-motion: a standing semantic activity with no declared
        //    clip resolves to the built-in idle loop through the real renderer
        //    chain, and never to "no pose at all".
        let standingLoop = snapshot(
            activity: .interact(anchorID: "wish_machine.device"),
            phase: .loop, contract: ActivityPhaseContract(phase: .loop, motionIDs: []),
            translations: [5, 5, 5])
        let idleResolved = StageAvatarResolvedMotion.resolve(
            selectedMotion: nil,
            worldPlayback: visual(standingLoop),
            naturalIdleMotion: idlePMX)
        expect(idleResolved == .asset(idlePMX),
               "a settled activity with no declared clip plays the built-in idle loop, got \(String(describing: idleResolved))")
        let restResolved = StageAvatarResolvedMotion.resolve(
            selectedMotion: nil,
            worldPlayback: visual(standingLoop),
            naturalIdleMotion: nil)
        expect(restResolved == .asset(idlePMX) || restResolved == .naturalIdle,
               "a missing idle clip is reported as the rest pose, never as a fabricated motion")

        // 7. Moving with no walk clip installed cannot be silent: the resolver
        //    reports the fallback (which the executor logs as an error), and a
        //    dance is never promoted into the walking pose.
        let noWalk = snapshot(
            phase: .enter,
            contract: ActivityPhaseContract(phase: .enter, motionIDs: []),
            approvedMotions: [idlePMX.id: idlePMX, dancePMX.id: dancePMX])
        expect(noWalk?.motionPlayback.fallback != nil || temporaryID(visual(noWalk)) == nil,
               "moving with no installed walk clip must report the missing motion")
        expect(temporaryID(visual(noWalk)) != dancePMX.id,
               "a dance must never be promoted into the walking pose")

        // 8. The visible clip is never frozen while the world is translating
        //    the avatar, and a genuine standstill still freezes.
        let gait = StageLocomotionGait(authoredStepSpeed: 0.75)
        let stalledSample = StageAvatarLocomotionTelemetry(
            measuredSpeed: 0.01, sustainedSpeed: 0.75, isWorldMoving: true,
            isLocomotionActive: true)
        expect(stalledSample.gaitGroundSpeed > StageLocomotionGait.freezeSpeed,
               "a stalled snapshot while the world moves must not freeze the walked clip")
        expect(gait.playbackRate(forGroundSpeed: stalledSample.gaitGroundSpeed) > 0,
               "the walked clip keeps stepping while the body is being translated")
        let stopped = StageAvatarLocomotionTelemetry(
            measuredSpeed: 0.01, sustainedSpeed: 0.75, isWorldMoving: false,
            isLocomotionActive: true)
        expect(gait.playbackRate(forGroundSpeed: stopped.gaitGroundSpeed) == 0,
               "a genuine standstill still freezes instead of marching in place")

        // 9. The VRM path gets the same movement-driven default, chosen by
        //    format: a PMX clip is never handed to a VRM avatar.
        let vrmResolved = snapshot(
            phase: .enter, contract: nil,
            approvedMotions: [walkPMX.id: walkPMX, walkVRM.id: walkVRM],
            avatarFormat: .vrm)
        expect(temporaryID(visual(vrmResolved)) == walkVRM.id,
               "a VRM avatar defaults to the VRM walk clip")

        // 10. Replay of the two real-machine timelines from the shipped package.
        //     22:21:25 — the resident was walking towards the wish machine while
        //     the collect activity sat in its (motion-less) `.enter` phase, and
        //     the old rule gated the substitute on the phase, so the walking
        //     clip was never drawn and the idle loop played instead.
        let collectEnter = snapshot(
            activity: .interact(anchorID: "wish_machine.device"),
            phase: .enter,
            contract: ActivityPhaseContract(
                phase: .enter, motionIDs: wishMachineCollectEnterMotionIDs),
            approvedMotions: [walkPMX.id: walkPMX, idlePMX.id: idlePMX])
        expect(temporaryID(visual(collectEnter)) == walkPMX.id,
               "replayed 22:21:25 (interact/.enter, declared \(wishMachineCollectEnterMotionIDs), moving): the renderer must get the walking clip")
        expect(collectEnter?.motionPlayback.fallback != nil,
               "replayed 22:21:25 must still report the unmet enter motion to the host")
        //     22:22:03 — the declared `home.walk` approach keeps its own clip,
        //     unchanged by this fix.
        let homeWalk = snapshot(
            activity: .walk(destinationID: "wp.center"),
            phase: .approach,
            contract: ActivityPhaseContract(
                phase: .approach, motionIDs: homeWalkApproachMotionIDs))
        expect(temporaryID(visual(homeWalk)) == walkPMX.id,
               "replayed 22:22:03 (walk/.approach, declared home.walk) keeps the declared walking clip")
        expect(temporaryID(declared(homeWalk)) == walkPMX.id,
               "replayed 22:22:03 reports the declared clip as satisfied, unchanged")

        // Informational trace in the same field names the app logs, so the
        // decision for a real timeline can be read without guessing.
        print("REPLAY 22:21:25-like activity=interact phase=enter declared=\(wishMachineCollectEnterMotionIDs) render=\(temporaryID(visual(collectEnter)) ?? "none") walkClip=\(temporaryID(visual(collectEnter)) != nil) receiptFallback=\(collectEnter?.motionPlayback.fallback != nil)")
        print("REPLAY 22:22:03-like activity=walk phase=approach declared=\(homeWalkApproachMotionIDs) render=\(temporaryID(visual(homeWalk)) ?? "none") walkClip=\(temporaryID(visual(homeWalk)) != nil) receiptFallback=\(homeWalk?.motionPlayback.fallback != nil)")

        print("PASS: 10+ walking-motion checks (movement decides the pose in every phase, declarations still win, first tick walks, standing never walks, the enter receipt stays unmet while the body walks, idle micro-motion, missing walk reported, no frozen gait, format-correct default)")
    }
}
"""#

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-walk-motion-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("Test.swift")
let binary = directory.appendingPathComponent("test")
try harness.write(to: source, atomically: true, encoding: .utf8)
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-parse-as-library", source.path, "-o", binary.path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
