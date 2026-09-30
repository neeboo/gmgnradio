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

// The production surfaces this harness is about must exist before it can test
// them; a rename that silently drops the default would otherwise "pass".
guard policy.contains("static func walkMotionIDs("),
      policy.contains("static func defaultMotionIDs("),
      policy.contains("func isPlayable("),
      executor.contains("ResidentLocomotionMotionPolicy.defaultMotionIDs("),
      executor.contains("No usable walking motion"),
      executor.contains("Defaulting to built-in"),
      resolver.contains("case naturalIdle") else {
    print("FAIL: the walking-motion default policy or its executor linkage is missing")
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

let approved = [walkPMX.id: walkPMX, walkVRM.id: walkVRM, idlePMX.id: idlePMX,
                dancePMX.id: dancePMX, declaredVRMWalk.id: declaredVRMWalk]

@MainActor
func playback(
    activity: LifeActivity = .walk(destinationID: "wp.center"),
    phase: LifeActivityPhase = .approach,
    contract: ActivityPhaseContract?,
    approvedMotions: [String: StageMotionAsset] = approved,
    avatarFormat: StageAvatarFormat = .pmx,
    translations: [Float] = [0, 0.025, 0.05]
) -> StageAvatarMotionPlayback? {
    let store = StageAvatarRuntimeStore()
    store.snapshot = StageAvatarRuntimeSnapshotShim(avatar: StageAvatarAssetSnapshot(format: avatarFormat))
    let stage = SpatialStageStore()
    var now: TimeInterval = 0
    let subject = StageAvatarActivityExecutor(
        runtime: store, spatialStage: stage, worldSpawn: WorldTransform(), clock: { now })
    var last: StageAvatarMotionPlayback?
    for (index, x) in translations.enumerated() {
        var transform = WorldTransform()
        transform.position.x = x
        _ = subject.apply(
            transform: transform, activity: activity, phase: phase,
            sourceRevision: UInt64(index + 1), activityRequestID: "request-\(index)",
            phaseContract: contract, approvedMotions: approvedMotions)
        last = store.worldActivity?.motionPlayback
        now += 1.0 / 30.0
    }
    return last
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

        // 1. Every moving snapshot resolves to *some* clip, and it is a walking
        //    clip. Four hostile declarations the real machine produces: no
        //    contract at all, a contract that declares nothing (the cabin's
        //    `wish_machine.collect.approach`), one that declares an id nobody
        //    installed, and one whose declared clip has the wrong format for
        //    the avatar (a .vrma declared for a PMX body).
        let movingCases: [(String, ActivityPhaseContract?)] = [
            ("no contract", nil),
            ("empty declaration", ActivityPhaseContract(phase: .approach, motionIDs: [])),
            ("uninstalled declaration",
             ActivityPhaseContract(phase: .approach, motionIDs: ["gmgn.motion.bones.walk-loop-gone"])),
            ("wrong-format declaration",
             ActivityPhaseContract(phase: .approach, motionIDs: [declaredVRMWalk.id])),
        ]
        for (label, contract) in movingCases {
            let resolved = playback(contract: contract)
            expect(temporaryID(resolved) == walkPMX.id,
                   "moving with \(label) must play the built-in walk clip, got \(String(describing: resolved))")
        }

        // 2. A declaration still wins when it is usable: the default is a
        //    fallback, never a replacement.
        let declared = playback(contract: ActivityPhaseContract(
            phase: .approach, motionIDs: [dancePMX.id, walkPMX.id]))
        expect(temporaryID(declared) == dancePMX.id,
               "a declared, installed clip stays the first choice")

        // 3. A moving avatar that is already at its target still gets the walk
        //    clip on the first tick (before a second position sample exists to
        //    measure): the phase itself is the authoritative walking fact.
        let firstTick = playback(contract: nil, translations: [0])
        expect(temporaryID(firstTick) == walkPMX.id,
               "the first tick of a walk already has a walking pose")

        // 4. Standing still with a semantic activity that declares nothing must
        //    play the built-in idle loop, not "natural idle with nothing to
        //    play" (which is the rest pose).
        let standing = playback(
            activity: .interact(anchorID: "wish_machine.device"),
            phase: .loop,
            contract: ActivityPhaseContract(phase: .loop, motionIDs: []),
            translations: [5, 5, 5])
        expect(temporaryID(standing) == idlePMX.id,
               "a settled activity without a declared clip plays the built-in idle loop, got \(String(describing: standing))")

        // 5. The generated-prop enter phase stays fail-closed: the host turns a
        //    natural-idle fallback on `.enter` into a *failed* usage, so the
        //    default must never quietly satisfy that gate.
        let enter = playback(
            activity: .interact(anchorID: "coffee.brew@object"),
            phase: .enter,
            contract: ActivityPhaseContract(phase: .enter, motionIDs: []),
            translations: [5, 5, 5])
        expect(enter?.fallback != nil,
               "an enter phase without a motion still reports the fallback the host fails closed on")

        // 6. Moving with no walk clip installed at all cannot be silent: the
        //    resolver reports a fallback (which the executor logs as an error),
        //    never a motion.
        let noWalk = playback(
            contract: nil,
            approvedMotions: [idlePMX.id: idlePMX, dancePMX.id: dancePMX])
        expect(noWalk?.fallback != nil,
               "moving with no installed walk clip must report the missing motion")
        expect(temporaryID(noWalk) == nil,
               "a dance must never be promoted into the walking pose")

        // 7. The visible clip is never frozen while the world is translating
        //    the avatar: a snapshot that landed on a stalled tick lowers the
        //    responsive estimate, and the sustained estimate must still drive
        //    the gait instead of parking the legs.
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

        // 8. The VRM path gets the same default, chosen by format: a PMX clip
        //    is never handed to a VRM avatar.
        let vrmResolved = playback(
            phase: .approach, contract: nil,
            approvedMotions: [walkPMX.id: walkPMX, walkVRM.id: walkVRM],
            avatarFormat: .vrm)
        expect(temporaryID(vrmResolved) == walkVRM.id,
               "a VRM avatar defaults to the VRM walk clip")

        print("PASS: 8 walking-motion default checks (moving always walks, dedicated still wins, idle micro-motion, enter stays fail-closed, missing walk reported, no frozen gait, format-correct default)")
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
