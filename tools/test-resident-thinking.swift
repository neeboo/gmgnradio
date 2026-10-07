// No host, preferences, audio, GPU or network. Compile the real runtime store.
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
let playback = try read("apps/macos/Sources/GMGNRadio/VisualEngine/StageAvatarMotionPlayback.swift")
let app = try read("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let bootstrap = try read("apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift")
let installedIDs = String(bootstrap[bootstrap.range(of: "static let installedLivingMotionIDs:")!.lowerBound..<bootstrap.range(of: "static func loadBundledCanary(")!.lowerBound])
let performancePath = "apps/macos/Sources/GMGNRadio/Presence/ResidentPerformanceMotionPolicy.swift"
guard FileManager.default.fileExists(atPath: root.appendingPathComponent(performancePath).path) else {
    print("FAIL: installed performance motions have no in-place/availability policy"); exit(1)
}
let performance = try read(performancePath)
guard !(try read("apps/macos/project.yml")).contains("Resources/ResidentMotions"),
      !(try read("apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift")).contains("gmgn.motion.resident-hold-display") else {
    print("FAIL: authored resident motions are still bundled or exposed by a runtime factory"); exit(1)
}
guard runtime.contains("func beginResidentThinking(runID:"), runtime.contains("func endResidentThinking(runID:") else {
    print("FAIL: resident thinking has no run-owned lifecycle"); exit(1)
}
let harness = #"""
import Foundation
import Observation
struct WorldTransform: Equatable, Sendable {}
struct LifeActivity: Equatable, Sendable {}
struct LifeActivityPhase: Equatable, Sendable {}
enum StageAvatarMotionPlayback: Equatable, Sendable {
    case temporary(StageMotionAsset)
    case naturalIdle(fallback: String?)
}
enum StageAvatarActivity: Equatable, Sendable { case idle, listening, speaking }
struct PresencePackageStore {
    var avatar: StageAvatarAsset? = nil
    static func liveStore() throws -> Self { Self() }
    func activeAvatar() throws -> StageAvatarAsset? { avatar }
}
struct MotionPackageStore {
    var storedMotions: [StageMotionAsset] = []
    var selected: StageMotionAsset? = nil
    static let naturalIdleID = "idle"
    static let iluvSlapBassVRMID = "builtin.motion.iluvslapbass-vrm"
    static func liveStore() throws -> Self { Self() }
    func activeMotion() throws -> StageMotionAsset? { selected }
    func activate(id: String) throws {}
    func listMotions() throws -> [StageMotionAsset] { storedMotions }
}
\#(runtime.replacingOccurrences(of: "import WorldRuntime", with: ""))
\#(performance)
\#(String(playback[playback.range(of: "enum StageAvatarResolvedMotion:")!.lowerBound..<playback.range(of: "struct StageAvatarMotionFallback:")!.lowerBound]))
enum LivingWorldBootstrap {
    static let fallbackWalkingSpeed: Float = 1.2
    \#(installedIDs)
    static let bonesWalkCompatibility = StageMotionLocomotion(strideSpeed: 0.75, playbackRate: 1, inPlace: true)
    static let ardyWalkCompatibility = StageMotionLocomotion(strideSpeed: 0.45, playbackRate: 4, inPlace: true)
    \#(declaration("static func approvedInstalledMotions(", in: bootstrap))
    \#(declaration("static func walkingSpeed(", in: bootstrap))
}
@MainActor final class RefreshHost {
    final class Context {
        let snapshot = "snapshot"
        var walkingSpeed: Float = 0
        func updateWalkingSpeed(_ speed: Float) { walkingSpeed = speed }
    }
    let avatarRuntime = StageAvatarRuntimeStore(packageStore: nil, motionPackageStore: nil)
    var motionPackageStore: MotionPackageStore? = MotionPackageStore()
    var livingWorldApprovedMotions: [String: StageMotionAsset] = [:]
    var livingWorldContext: Context? = Context()
    var menuRefreshes = 0
    func refreshResidentActivityMenu() { menuRefreshes += 1 }
    func applyLivingWorldSnapshot(_ snapshot: String) {}
    \#(declaration("private func refreshInstalledLivingWorldMotions(", in: app))
    func refresh() { refreshInstalledLivingWorldMotions() }
}
@main struct Test {
    @MainActor static func main() {
        let modelURL = URL(fileURLWithPath: "/test/avatar.pmx")
        let avatar = StageAvatarAsset(id: "pmx", name: "PMX", format: .pmx, modelURL: modelURL, resourceRootURL: modelURL.deletingLastPathComponent())
        let bonesThinking = StageMotionAsset(id: "gmgn.motion.bones.thinking-loop-pmx", name: "BONES thinking", format: .vmd, url: URL(fileURLWithPath: "/test/bones-thinking.vmd"))
        let bonesIdle = StageMotionAsset(id: "gmgn.motion.bones.idle-loop-pmx", name: "BONES idle", format: .vmd, url: URL(fileURLWithPath: "/test/bones-idle.vmd"))
        let sourceStore = StageAvatarRuntimeStore(packageStore: PresencePackageStore(avatar: avatar), motionPackageStore: MotionPackageStore(storedMotions: [bonesThinking, bonesIdle]))
        sourceStore.refresh()
        let sourceRun = UUID()
        sourceStore.beginResidentThinking(runID: sourceRun)
        precondition(sourceStore.residentThinkingMotion == bonesThinking, "thinking must use the installed BONES clip, never a bundled authored pose")
        sourceStore.endResidentThinking(runID: sourceRun)
        precondition(sourceStore.residentThinkingMotion == nil)
        precondition(sourceStore.snapshot.motion == bonesIdle, "default rest must resolve to installed BONES idle")
        precondition(StageAvatarResolvedMotion.resolve(selectedMotion: nil, worldPlayback: .naturalIdle(fallback: "missing"), naturalIdleMotion: bonesIdle) == .asset(bonesIdle), "missing semantic activity returns to BONES idle without inventing an activity animation")
        let rejected = StageMotionAsset(id: "gmgn.motion.ardy-walk-loop-pmx", name: "ARDY", format: .vmd, url: modelURL)
        let rejectedStore = StageAvatarRuntimeStore(packageStore: PresencePackageStore(avatar: avatar), motionPackageStore: MotionPackageStore(storedMotions: [bonesIdle, rejected], selected: rejected))
        rejectedStore.refresh()
        precondition(rejectedStore.snapshot.motion == rejected, "verified manual motion selection must remain unchanged")
        precondition(LivingWorldBootstrap.approvedInstalledMotions([rejected])[rejected.id] == nil,
            "manual selection must not bypass the automatic resident activity allow-list")
        for id in ["builtin.motion.iluvslapbass", "gmgn.motion.ardy-backflip"] {
            let kept = StageMotionAsset(id: id, name: id, format: .vmd, url: modelURL)
            let exceptionStore = StageAvatarRuntimeStore(packageStore: PresencePackageStore(avatar: avatar), motionPackageStore: MotionPackageStore(storedMotions: [bonesIdle, kept], selected: kept))
            exceptionStore.refresh()
            precondition(exceptionStore.snapshot.motion == kept, "explicit slap bass/backflip exceptions must remain unchanged")
        }
        let store = StageAvatarRuntimeStore(packageStore: nil, motionPackageStore: nil)
        let a = UUID(), b = UUID()
        let original = store.snapshot
        precondition(!store.isResidentThinking)
        store.beginResidentThinking(runID: a)
        precondition(store.isResidentThinking)
        store.beginResidentThinking(runID: b)
        store.endResidentThinking(runID: a)
        precondition(store.isResidentThinking, "stale turn must not clear a newer thinking turn")
        store.setResidentSpeechPlayback(isPlaying: true, level: 0.6)
        store.endResidentThinking(runID: b)
        precondition(!store.isResidentThinking)
        precondition(store.residentSpeechLevel == 0.6 && store.snapshot == original)
        store.beginResidentThinking(runID: a)
        store.clearResidentThinking()
        precondition(!store.isResidentThinking, "stop must clear thinking immediately")
        let thought = StageMotionAsset(id: "thinking", name: "Thinking", format: .vmd, url: nil)
        let walk = StageMotionAsset(id: "walk", name: "Walk", format: .vmd, url: nil)
        let dance = StageMotionAsset(id: "dance", name: "Dance", format: .vmd, url: nil)
        precondition(StageAvatarResolvedMotion.resolve(selectedMotion: dance, worldPlayback: nil, residentThinkingMotion: thought) == .asset(thought))
        precondition(StageAvatarResolvedMotion.resolve(selectedMotion: dance, worldPlayback: .temporary(walk), residentThinkingMotion: thought) == .asset(walk), "thinking must never override formal movement")
        precondition(StageAvatarResolvedMotion.resolve(selectedMotion: dance, worldPlayback: .naturalIdle(fallback: "missing"), residentThinkingMotion: thought) == .naturalIdle, "failed activity keeps its truthful fallback")
        precondition(StageAvatarResolvedMotion.resolve(selectedMotion: dance, worldPlayback: nil, residentThinkingMotion: nil) == .asset(dance), "end of thinking restores selected motion")
        precondition(StageAvatarResolvedMotion.resolve(selectedMotion: nil, worldPlayback: .naturalIdle(fallback: nil), residentThinkingMotion: thought) == .asset(thought))
        let source = StageMotionAsset(id: "gmgn.motion.ardy-backflip", name: "后空翻", format: .vmd, url: URL(fileURLWithPath: "/test/backflip.vmd"), loop: false)
        let normalized = ResidentPerformanceMotionPolicy.approvedMotion(source)!
        precondition(normalized.inPlace == true && !normalized.loop && normalized.url == source.url)
        let approved = [normalized.id: normalized]
        precondition(ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.backflip", avatarFormat: .pmx, approvedMotions: approved))
        precondition(!ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.backflip", avatarFormat: .vrm, approvedMotions: approved))
        precondition(!ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.backflip", avatarFormat: .pmx, approvedMotions: [:]))
        precondition(ResidentPerformanceMotionPolicy.approvedMotion(dance) == nil)
        precondition(ResidentPerformanceMotionPolicy.isAvailable(activityID: "home.walk", avatarFormat: .vrm, approvedMotions: [:]), "unrelated activity availability remains unchanged")
        let refreshHost = RefreshHost()
        refreshHost.livingWorldApprovedMotions["bundled.dance"] = dance
        refreshHost.motionPackageStore?.storedMotions = [source]
        refreshHost.refresh()
        precondition(ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.backflip", avatarFormat: .pmx, approvedMotions: refreshHost.livingWorldApprovedMotions))
        refreshHost.motionPackageStore?.storedMotions = []
        refreshHost.refresh()
        if refreshHost.livingWorldApprovedMotions[source.id] != nil {
            print("FAIL: uninstall + actual App refresh keeps stale performance motion"); exit(1)
        }
        precondition(!ResidentPerformanceMotionPolicy.isAvailable(activityID: "performance.backflip", avatarFormat: .pmx, approvedMotions: refreshHost.livingWorldApprovedMotions))
        precondition(refreshHost.livingWorldApprovedMotions["bundled.dance"] == dance && refreshHost.menuRefreshes == 2)
        print("PASS: thinking starts, stale completion ignored, ends and cancels without changing speech or assets")
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-thinking-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let source = dir.appendingPathComponent("main.swift"), binary = dir.appendingPathComponent("test")
try harness.write(to: source, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", source.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
