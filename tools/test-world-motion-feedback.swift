// Hostless behavioral checks for request-scoped world/avatar playback identity.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let path = "apps/macos/Sources/GMGNRadio/Presence/StageAvatarActivityExecutor.swift"
let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
let app = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"), encoding: .utf8)
guard source.contains("activityRequestID: String? = nil"), source.contains("current.activityRequestID == snapshot.activityRequestID") else {
    print("FAIL: world executor drops request identity or suppresses repeated activity requests"); exit(1)
}
guard app.contains("activityRequestID: snapshot.activeActivity == nil ? context.currentMovementRequestID : context.currentActivityRequestID"),
      app.contains("self?.handleResidentMotionPlayback(event)"),
      let methodStart = app.range(of: "private func handleResidentMotionPlayback(")?.lowerBound,
      let methodEnd = app.range(of: "private func performLivingCabinJukeboxEffect(", range: methodStart..<app.endIndex)?.lowerBound else {
    print("FAIL: App does not bind playback identity and report world completion/failure"); exit(1)
}
let method = String(app[methodStart..<methodEnd]).replacingOccurrences(of: "private func", with: "func")
guard let refreshStart = app.range(of: "private func refreshInstalledLivingWorldMotions()")?.lowerBound,
      let refreshEnd = app.range(of: "private static func spatialCamera(", range: refreshStart..<app.endIndex)?.lowerBound,
      app[refreshStart..<refreshEnd].contains("livingWorldContext?.updateWalkingSpeed("),
      app[refreshStart..<refreshEnd].contains("avatarFormat: avatarRuntime.snapshot.avatar?.format") else {
    print("FAIL: avatar refresh leaves the world's movement speed on the previous skeleton"); exit(1)
}
let defaultMotionPolicy = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/ResidentLocomotionMotionPolicy.swift"), encoding: .utf8)
let harness = #"""
import Foundation
import simd
struct WorldVector3: Equatable, Sendable { var x: Float = 0; var y: Float = 0; var z: Float = 0 }
struct WorldQuaternion: Equatable, Sendable { var x: Float = 0; var y: Float = 0; var z: Float = 0; var w: Float = 1 }
struct WorldTransform: Equatable, Sendable { var position = WorldVector3(); var rotation = WorldQuaternion() }
struct LifeActivity: Equatable, Sendable { let typeID: String }
enum LifeActivityPhase: String, Sendable { case approach, enter, loop, exit, interrupt, failed }
enum StageAvatarFormat: String, Sendable { case vrm, pmx }
struct ActivityPhaseContract {
    let phase: LifeActivityPhase
    var requiredAnchorIDs: [String] = []
    var motionIDs: [String] = []
    var propIDs: [String] = []
    var durationSeconds: TimeInterval? = nil
}
struct StageAvatarLocomotionTelemetry: Equatable, Sendable {
    var measuredSpeed: Float = 0
    var sustainedSpeed: Float = 0
    var isWorldMoving = false
    var isLocomotionActive = false
    var sourceRevision: UInt64 = 0
    static let standing = StageAvatarLocomotionTelemetry()
    var gaitGroundSpeed: Float { isWorldMoving ? max(measuredSpeed, sustainedSpeed) : measuredSpeed }
    init(measuredSpeed: Float = 0, sustainedSpeed: Float = 0, isWorldMoving: Bool = false,
         isLocomotionActive: Bool = false, sourceRevision: UInt64 = 0) {
        self.measuredSpeed = measuredSpeed
        self.sustainedSpeed = sustainedSpeed
        self.isWorldMoving = isWorldMoving
        self.isLocomotionActive = isLocomotionActive
        self.sourceRevision = sourceRevision
    }
}
enum StageMotionFormat: String { case procedural, vrma, vmd }
/// The freeze boundary the executor's locomotion predicate reads.
enum StageLocomotionGait { static let freezeSpeed: Float = 0.06 }
struct StageMotionAsset: Equatable, Sendable {
    let id: String; let url: URL?; var format: StageMotionFormat = .vmd
    var loop = false
    var inPlace: Bool? = false
    var strideSpeed: Float? = nil
    var isLocomotionLoop: Bool {
        loop && inPlace == true && (strideSpeed ?? 0) > 0
    }
}
struct StageMotionPlaybackIdentity { let motion: StageMotionAsset; let worldActivityRequestID: String?; let worldActivityPhase: LifeActivityPhase? }
enum StageMotionPlaybackOutcome { case completed, failed(String) }
struct StageMotionPlaybackEvent { let identity: StageMotionPlaybackIdentity; let outcome: StageMotionPlaybackOutcome }
struct Fallback: Equatable { let requestedMotionIDs: [String]; let activityTypeID: String; let phase: LifeActivityPhase; let reason: LifeActivityPhase }
enum StageAvatarMotionPlayback: Equatable, Sendable {
    case temporary(StageMotionAsset)
    case naturalIdle(fallback: Fallback?)
    var fallback: Fallback? {
        guard case let .naturalIdle(fallback) = self else { return nil }
        return fallback
    }
    static func resolve(activity: LifeActivity, phase: LifeActivityPhase, phaseContract: ActivityPhaseContract?, approvedMotions: [String: StageMotionAsset]) -> Self {
        .temporary(StageMotionAsset(id: "one-shot", url: nil))
    }
}
struct StageAvatarWorldActivitySnapshot: Equatable, Sendable {
    let transform: WorldTransform; let activity: LifeActivity; let phase: LifeActivityPhase
    let motionPlayback: StageAvatarMotionPlayback; let sourceRevision: UInt64
    var activityRequestID: String? = nil
}
struct StageAvatarPlacement { let position: SIMD3<Float>; let scale: Float; let yaw: Float }
/// The one field of the avatar snapshot the executor's motion policy reads.
struct StageAvatarAssetSnapshot { let format: StageAvatarFormat }
struct StageAvatarRuntimeSnapshotShim { let avatar: StageAvatarAssetSnapshot? }
@MainActor final class StageAvatarRuntimeStore {
    var worldActivity: StageAvatarWorldActivitySnapshot?
    var installs = 0
    var locomotion = StageAvatarLocomotionTelemetry.standing
    var snapshot = StageAvatarRuntimeSnapshotShim(
        avatar: StageAvatarAssetSnapshot(format: .vrm))
    func installWorldActivity(_ value: StageAvatarWorldActivitySnapshot) { installs += 1; worldActivity = value }
    func clearWorldActivity() { worldActivity = nil }
    func updateLocomotion(_ value: StageAvatarLocomotionTelemetry) {
        if value != locomotion { locomotion = value }
    }
}
@MainActor final class SpatialStageStore {
    var selectedWorldID = "world"
    var avatarPlacement = StageAvatarPlacement(position: .zero, scale: 1, yaw: 0)
    func setWorldAvatarPlacement(_ value: StageAvatarPlacement) { avatarPlacement = value }
    func clearTransientAvatarPlacement() {}
}
@MainActor final class TestWorld {
    struct Manifest { let worldID = "world" }
    let manifest = Manifest()
    var currentActivityRequestID: String? = "current"
    var currentMovementRequestID: String? = "move"
    var completed = 0, failed = 0, movementFailed = 0
    func completeActivityPlayback(requestID: String, phase: LifeActivityPhase) throws { completed += 1 }
    func failActivityPlayback(requestID: String, phase: LifeActivityPhase) throws { failed += 1 }
    func failMovementPlayback(requestID: String) throws { movementFailed += 1 }
}
@MainActor final class TestApp {
    let spatialStage = SpatialStageStore()
    var livingWorldContext: TestWorld? = TestWorld()
    let livingWorldLogger = Logger(subsystem: "offline", category: "test")
    \#(method)
}
\#(source.replacingOccurrences(of: "import WorldRuntime", with: ""))
\#(defaultMotionPolicy)
@main struct Test {
    @MainActor static func main() {
        let runtime = StageAvatarRuntimeStore(), stage = SpatialStageStore()
        let executor = StageAvatarActivityExecutor(runtime: runtime, spatialStage: stage, worldSpawn: WorldTransform())
        let activity = LifeActivity(typeID: "backflip")
        _ = executor.apply(transform: WorldTransform(), activity: activity, phase: .loop, sourceRevision: 1, activityRequestID: "first")
        precondition(runtime.worldActivity?.activityRequestID == "first", "request identity reaches renderer snapshot")
        _ = executor.apply(transform: WorldTransform(), activity: activity, phase: .loop, sourceRevision: 2, activityRequestID: "first")
        precondition(runtime.installs == 1, "same request tick does not restart playback")
        _ = executor.apply(transform: WorldTransform(), activity: activity, phase: .loop, sourceRevision: 3, activityRequestID: "second")
        precondition(runtime.installs == 2 && runtime.worldActivity?.activityRequestID == "second", "replacement request restarts same motion")
        _ = executor.apply(transform: WorldTransform(), activity: activity, phase: .loop, sourceRevision: 2, activityRequestID: "stale")
        precondition(runtime.worldActivity?.activityRequestID == "second", "stale request cannot overwrite current playback")
        _ = executor.clear(sourceRevision: 4)
        precondition(runtime.worldActivity == nil, "clear removes world request identity")
        let app = TestApp()
        func report(_ id: String?, _ outcome: StageMotionPlaybackOutcome, loop: Bool = false) {
            app.handleResidentMotionPlayback(StageMotionPlaybackEvent(identity: StageMotionPlaybackIdentity(
                motion: StageMotionAsset(id: "shot", url: nil, loop: loop), worldActivityRequestID: id, worldActivityPhase: .loop), outcome: outcome))
        }
        report("stale", .completed); report(nil, .failed("bad"))
        precondition(app.livingWorldContext!.completed == 0 && app.livingWorldContext!.failed == 0, "stale or user motion cannot alter world")
        report("current", .completed, loop: true)
        precondition(app.livingWorldContext!.completed == 0, "looping playback does not complete activity")
        report("current", .completed); report("current", .failed("bad"))
        precondition(app.livingWorldContext!.completed == 1 && app.livingWorldContext!.failed == 1, "actual renderer results reach world")
        report("move", .completed)
        precondition(app.livingWorldContext!.completed == 1 && app.livingWorldContext!.movementFailed == 0, "clip completion cannot complete movement")
        report("move", .failed("bad"))
        precondition(app.livingWorldContext!.movementFailed == 1, "failed current gait reaches ordinary movement")
        app.spatialStage.selectedWorldID = "other"
        report("current", .completed); report("current", .failed("bad"))
        precondition(app.livingWorldContext!.completed == 1 && app.livingWorldContext!.failed == 1, "other world does not receive playback")
        print("PASS: 11 world motion identity and feedback checks")
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("world-motion-feedback-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let file = temp.appendingPathComponent("main.swift"), binary = temp.appendingPathComponent("test")
try harness.write(to: file, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", file.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
