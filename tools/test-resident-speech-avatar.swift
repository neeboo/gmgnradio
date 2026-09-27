// Run actual avatar store, mouth resolver, and App playback/selection callbacks.
// Package data and UI are inert; no app, GPU, audio, network, or user preferences.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String {
    try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
}
let runtime = try read("Presence/StageAvatarRuntime.swift")
let spatial = try read("VisualEngine/SpatialStageStore.swift")
let app = try read("App/GMGNRadioApp.swift")
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)"); exit(1)
    }
    var depth = 0
    for i in source[open...].indices {
        if source[i] == "{" { depth += 1 }
        if source[i] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...i]) }
    }
    fatalError("Unbalanced declaration")
}
guard runtime.contains("func setResidentSpeechPlayback(") else {
    print("FAIL: actual TTS playback has no independent avatar mouth overlay")
    exit(1)
}
let callback = declaration("onPlaybackChanged: {", in: app)
let callbackClosure = String(callback[callback.firstIndex(of: "{")!...])
let worldBinding = declaration("spatialStage.onWorldSelectionChanged = {", in: app)
let worldSelection = declaration("func selectWorld(id:", in: spatial)
let harness = #"""
import Foundation
import Observation
// Only asset/world data dependencies are replaced; all store mutations below
// come from the complete production StageAvatarRuntime.swift source.
struct WorldTransform: Equatable, Sendable { var value = 0 }
struct LifeActivity: Equatable, Sendable { var id = "walk" }
struct LifeActivityPhase: Equatable, Sendable { var id = "loop" }
struct StageAvatarMotionPlayback: Equatable, Sendable { var id = "walk-motion" }
struct PresencePackageStore {
    static func liveStore() throws -> Self { Self() }
    func activeAvatar() throws -> StageAvatarAsset? { nil }
}
struct MotionPackageStore {
    static let naturalIdleID = "idle"
    static func liveStore() throws -> Self { Self() }
    func activeMotion() throws -> StageMotionAsset? { nil }
    func listMotions() throws -> [StageMotionAsset] { [] }
    func activate(id: String) throws {}
}
\#(declaration("enum StageAvatarActivity:", in: spatial))
\#(declaration("struct StageAvatarMotionFrame:", in: spatial))
\#(runtime.replacingOccurrences(of: "import WorldRuntime", with: ""))
struct AgentSpeechPlaybackState { let isPlaying: Bool; let level: Float }
struct Placement { static func forScene(_ scene: String) -> Self { Self() } }
typealias StageAvatarPlacement = Placement
struct CameraHome { static let defaultHome = Self() }
struct Camera { mutating func reset(to: CameraHome) {} }
@MainActor final class Spatial {
    final class Ownership { func invalidate() {} }
    let residentPropRenderOwnership = Ownership()
    func clearResidentPropRendererHooks() {}
    var residentPropPreview: Int?
    var residentHeldProp: Int?
    var residentPropDisplayStand: Int?
    var residentPropOutputs: [Int] = []
    var residentPropRenderStatuses: [String: Int] = [:]
    var residentPropViewProjection: Int?
    var selectedWorldID: String? = "cabin"
    var onWorldSelectionChanged: (() -> Void)?
    var calibratedWorldID: String?
    var cameraHome = CameraHome()
    var camera = Camera()
    var selectedScene = "cabin"
    func clearSceneOccluderTriangles() {}
    func installBaseAvatarPlacement(_ placement: Placement) {}
    \#(worldSelection)
}
@MainActor final class App {
    func safelyReturnHeldProp(reason: String) {}
    var residentWishImages: [String: String] = [:]
    final class AudioGraph { func setResidentSpeechPlaying(_ playing: Bool) {} }
    let audioGraph = AudioGraph()
    final class Loop { func invalidate() {} }
    var residentAgentLoop: Loop?
    var lastResidentActivityRequestID: String?
    let avatarRuntime: StageAvatarRuntimeStore
    let spatialStage = Spatial()
    var cancellations = 0
    init(_ runtime: StageAvatarRuntimeStore) {
        self.avatarRuntime = runtime
        \#(worldBinding)
    }
    func cancelResidentMessage() {
        cancellations += 1
        // The speech dependency responds to stop with the same production callback.
        receive(AgentSpeechPlaybackState(isPlaying: false, level: 0))
    }
    func receive(_ state: AgentSpeechPlaybackState) {
        let callback: @MainActor (AgentSpeechPlaybackState) -> Void = \#(callbackClosure)
        callback(state)
    }
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(label)") }
}
@main struct Tests {
    @MainActor static func main() {
        let runtime = StageAvatarRuntimeStore(packageStore: nil, motionPackageStore: nil)
        let app = App(runtime)
        let worldActivity = StageAvatarWorldActivitySnapshot(transform: WorldTransform(), activity: LifeActivity(), phase: LifeActivityPhase(), motionPlayback: StageAvatarMotionPlayback(), sourceRevision: 9)
        runtime.installWorldActivity(worldActivity)
        runtime.setActivity(.listening)
        runtime.setVoiceLevel(0.3)
        let originalSnapshot = runtime.snapshot
        let time: TimeInterval = 2
        func frame() -> StageAvatarMotionFrame {
            StageAvatarMotionFrame.resolve(activity: runtime.activity, voiceLevel: runtime.voiceLevel, time: time, residentSpeechLevel: runtime.residentSpeechLevel)
        }
        let before = frame()
        check(runtime.residentSpeechLevel == nil && before.mouthWeight == 0, "no TTS keeps old idle/listening behavior")
        app.receive(AgentSpeechPlaybackState(isPlaying: true, level: 0.5))
        let speaking = frame()
        check(speaking.mouthWeight > 0.5, "actual playback amplitude opens VRM mouth")
        check(runtime.activity == .listening && runtime.voiceLevel == 0.3, "TTS never overwrites microphone/legacy speaking state")
        check(runtime.worldActivity == worldActivity && runtime.snapshot == originalSnapshot, "walking/world motion and selected assets stay unchanged")
        check(speaking.headTilt == before.headTilt && speaking.spineYaw == before.spineYaw && speaking.bodyLift == before.bodyLift, "TTS changes mouth only, not body motion")
        app.receive(AgentSpeechPlaybackState(isPlaying: true, level: 0))
        check(frame().mouthWeight == 0, "actual silent sample closes mouth without synthetic sine fallback")
        runtime.setActivity(.speaking)
        runtime.setVoiceLevel(0.9)
        check(frame().mouthWeight == 0, "silent TTS overrides legacy fallback only while playback active")
        app.receive(AgentSpeechPlaybackState(isPlaying: false, level: 0))
        check(runtime.residentSpeechLevel == nil && frame().mouthWeight > 0, "playback end removes overlay and restores legacy speaking output")
        check(runtime.activity == .speaking && runtime.voiceLevel == 0.9 && runtime.worldActivity == worldActivity, "ending TTS does not reset the user's activity")
        let samples: [(Float, Float)] = [(-1, 0), (2, 1), (.nan, 0)]
        for (level, expected) in samples {
            app.receive(AgentSpeechPlaybackState(isPlaying: true, level: level))
            check(runtime.residentSpeechLevel == expected, "audio sample is normalized before renderer")
        }
        app.receive(AgentSpeechPlaybackState(isPlaying: true, level: 0.6))
        app.spatialStage.selectWorld(id: "cabin")
        check(app.cancellations == 0, "reselecting same world does not interrupt speech")
        app.spatialStage.selectWorld(id: "another-world")
        check(app.cancellations == 1 && runtime.residentSpeechLevel == nil, "changing world stops old speech and clears only mouth overlay")
        check(runtime.worldActivity == worldActivity, "world selection speech cleanup does not mutate movement")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident speech avatar checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-speech-avatar-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("SpeechAvatar.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("speech-avatar")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", program.path, "-o", executable.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = executable
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
