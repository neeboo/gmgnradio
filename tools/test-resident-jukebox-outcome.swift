import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let outcome = sources.appendingPathComponent("Agent/ResidentActivityOutcome.swift")
guard FileManager.default.fileExists(atPath: outcome.path) else {
    print("FAIL: jukebox tool returns acceptance without actual playback outcome")
    exit(1)
}
let bootstrap = try String(contentsOf: sources.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let start = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let end = bootstrap.range(of: "struct BundledLivingWorldPackage:")!.lowerBound
let physicsAndGate = String(bootstrap[start..<end])
func declaration(_ signature: String, in text: String) -> String {
    let start = text.range(of: signature)!.lowerBound
    // 花括号在**默认参数值**里也会出现：
    //   `humanOrderedClaim: @escaping @MainActor () -> Bool = { false }`
    // 函数体的 `{` 一定是参数表（小括号）闭合之后的第一个。取"第一个 `{`"会把
    // 整个 `makeResidentWorldTools` 截断在默认闭包参数处，于是 deadline 断言
    // 看的是一个没有函数体的残缺文本，永远红着也没人发现它是测试自己的 bug。
    var parenDepth = 0
    var opening: String.Index?
    var scan = start
    while scan < text.endIndex, opening == nil {
        switch text[scan] {
        case "(": parenDepth += 1
        case ")": parenDepth -= 1
        case "{": if parenDepth == 0 { opening = scan }
        default: break
        }
        scan = text.index(after: scan)
    }
    guard let opening else { fatalError("no body for declaration \(signature)") }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}
let appSource = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
let toolLeaseMethod = declaration("private func makeResidentWorldTools(", in: appSource)
guard toolLeaseMethod.contains("let deadline = Date().addingTimeInterval(300)"),
      toolLeaseMethod.components(separatedBy: "deadline: deadline").count == 3 else {
    print("FAIL: activity result and world tools must share the same 300-second turn deadline")
    exit(1)
}
// 抽取器必须抽到**整个函数体**：结尾的 `return ResidentConversationTools(` 在参数表
// 之后，只有抽全了才看得到。默认闭包参数（`= { false }`）曾让它在这里截断，
// 于是上面那条 deadline 断言看的是一个没有函数体的残缺文本，红着也无人察觉。
guard toolLeaseMethod.contains("return ResidentConversationTools("),
      toolLeaseMethod.contains("additionalTools:") else {
    print("FAIL: the declaration extractor must capture the whole makeResidentWorldTools body")
    exit(1)
}
// 抽取器修好后，`performLivingCabinJukeboxEffect` 才第一次真的进了这份 harness，
// 它引用的错误类型必须一并抽出来（照抄源码，不在测试里另写一份语义）。
let radioActionError = declaration("private enum DJAgentRadioActionError:", in: appSource)
let resumeMethod = declaration("private func resumeResidentJukebox(", in: appSource)
let pauseMethod = declaration("private func pauseResidentJukebox(", in: appSource)
let toggleMethod = declaration("func toggleLocalPlayback() {", in: appSource)
let automaticEffectMethod = declaration("private func performLivingCabinJukeboxEffect(", in: appSource)
let silenceReportMethod = declaration("private func reportJukeboxSilence(", in: appSource)
let playerSource = try String(contentsOf: sources.appendingPathComponent("AudioEngine/LocalMusicPlayer.swift"), encoding: .utf8)
let queueSource = try String(contentsOf: sources.appendingPathComponent("AudioEngine/ProgramPlaybackQueue.swift"), encoding: .utf8)
// 播放器**整份**原样进 harness（协议、错误、玩家）。要断言的是"接受了一次 play
// 调用"与"音频图真的在出声"之间的差别，用替身测这个差别等于什么都没测。
// 只去掉顶部的 import：文件级 import 不能在文件中间重复。（按 `.newlines` 切，
// 这个文件是 CRLF；`split(separator: "\n")` 在 CRLF 上什么都切不出来。）
let playerImplementation = playerSource
    .components(separatedBy: .newlines)
    .filter { !$0.hasPrefix("import ") }
    .joined(separator: "\n")
let playbackRoute = declaration("enum ProgramPlaybackStartRoute:", in: queueSource)
let toggleRoute = declaration("enum ProgramPlaybackToggleRoute:", in: queueSource)
let harness = #"""
import Foundation
import WorldRuntime
import os
\#(physicsAndGate)
struct RealtimeDJToolCall: Codable, Equatable, Sendable { let id: String; let name: String; let argumentsJSON: Data }
struct RealtimeDJToolResult: Codable, Equatable, Sendable { let callID: String; let resultJSON: Data; let isError: Bool }
struct Config: Decodable { struct Framing: Decodable { let origin: [Float]; let scale: Float }; let framing: Framing }
enum PlayerError: Error { case missingTrack, pauseFailed }
\#(playerImplementation)
\#(playbackRoute)
\#(toggleRoute)
\#(radioActionError)
@MainActor final class AppPlaybackHarness {
    final class ResidentLoop { func stop() {} }
    var residentAgentLoop: ResidentLoop?
    struct Cabin { var worldID: String }
    struct Stage { var selectedWorldID: String; var marbleLivingCabin: Cabin? }
    struct Player {
        var state: LocalMusicPlaybackState = .idle
        mutating func pause() { state = .paused }
        mutating func play() throws { state = .playing }
    }
    struct Prepared {
        enum Target { case localFile, providerReference }; var target: Target
        struct Track { let id = "fixture" }; struct Slot { let track = Track() }; let slot = Slot()
    }
    struct Queue { var current: Prepared? }
    enum DisplayState { case idle, paused, playing }
    final class Display {
        func setState(_ state: DisplayState) {}
        func setPlaybackState(_ state: DisplayState) {}
    }
    /// 屏上状态是用户唯一能看到"为什么没出声"的地方：这里把它记下来当断言对象。
    final class LiveCam {
        var messages: [String] = []
        func showChatStatus(_ message: String) { messages.append(message) }
    }
    let playbackLogger = Logger(subsystem: "gmgn.hostless.test", category: "jukebox")
    var orbWindowController: Display? = Display()
    var stageWindowController: Display? = Display()
    var liveCamWindowController: LiveCam? = LiveCam()
    var livingWorldLogger: Logger { playbackLogger }
    var residentActivityOutcome: ResidentActivityOutcome?
    var livingWorldContext: WorldAgentContext?
    var spatialStage: Stage
    var localMusicPlayer = Player()
    var activeProgram: Bool? = true
    var programPlaybackQueue = Queue(current: Prepared(target: .localFile))
    var livingCabinJukeboxGate = LivingCabinJukeboxGate()
    var reportedJukeboxSilenceInstance: String?
    var residentJukeboxPlaybackOwner: UUID?
    var musicSelectionGeneration: UInt64 = 0
    var resumes = 0
    var pauses = 0
    init(_ context: WorldAgentContext) {
        livingWorldContext = context
        spatialStage = Stage(selectedWorldID: context.manifest.worldID, marbleLivingCabin: Cabin(worldID: context.manifest.worldID))
    }
    func resumeMusic() async throws {
        resumes += 1
        let route = ProgramPlaybackStartRoute.resolve(playerState: localMusicPlayer.state,
            hasPreparedProgram: activeProgram != nil && programPlaybackQueue.current != nil)
        if route == .unavailable { throw PlayerError.missingTrack }
        if route != .alreadyPlaying { residentJukeboxPlaybackOwner = ResidentActivityOutcome.playbackOwner }
        localMusicPlayer.state = .playing
    }
    func pauseMusic() async throws { pauses += 1; localMusicPlayer.state = .paused; residentJukeboxPlaybackOwner = nil }
    func stopResidentLoop(reason: String) -> Bool { residentAgentLoop?.stop(); return true }
    func presentPlaybackError(_ error: Error) { check(false, "unexpected fake local player failure") }
    func startPreparedProgramPlayback() {}
    \#(resumeMethod)
    \#(pauseMethod)
    \#(toggleMethod)
    \#(automaticEffectMethod)
    \#(silenceReportMethod)
    func play(_ owner: UUID) async throws { try await resumeResidentJukebox(owner: owner) }
    func pause(_ owner: UUID?) async throws { try await pauseResidentJukebox(owner: owner) }
    func scheduleAutomaticEffect(_ snapshot: WorldAgentSnapshot) { performLivingCabinJukeboxEffect(snapshot) }
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures += 1; print("FAIL: \(message)") } }
func unwrap<T>(_ value: T?, _ message: String = "fixture could not read its input") throws -> T {
    guard let value else { print("FAIL: \(message)"); exit(1) }
    return value
}
func code(_ result: RealtimeDJToolResult) -> String? { (try? JSONSerialization.jsonObject(with: result.resultJSON) as? [String: Any])?["code"] as? String }
@MainActor final class Fixture {
    let context: WorldAgentContext
    var current = true
    /// 「不再 current」的**具体**原因；工具必须把它逐字带给 agent / 用户。
    var currentBlockerReason: String? = "空间正在装修（摆放模式），居民的点唱机操作已失去授权"
    var starts = 0
    var pauses = 0
    var fails = false
    var musicNotPrepared = false
    var unsupported = false
    var pauseFails = false
    var navigationHeld = false
    var playerHeld = false
    var playerWait: CheckedContinuation<Void, Never>?
    var playing = false
    var playbackOwner: UUID?
    var gate = LivingCabinJukeboxGate()
    var suppressed = 0
    var outcome: ResidentActivityOutcome!
    var session: ResidentWorldToolSession!
    init(deadline: Date = Date().addingTimeInterval(180)) throws {
        let base = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: base.appendingPathComponent("world.json")))
        // `music.listen` **不是**烘焙在世界包里的固有活动：它是 `prop.jukebox` 声明的
        // 功能点，运行时由（声明 × 摆放）派生。生产路径从包里每件 `prop.procedural`
        // 读声明（`LivingWorldBootstrap.propFunctionSources`），这份 fixture 过去只喂
        // manifest，于是 `start_activity music.listen` 恒得 `unknown_activity`，
        // 整套断言都在测一个没有点唱机的世界。
        let functionSources: [WorldPropFunctionSource] = try manifest.resources
            .filter { $0.kind == "prop.procedural" }
            .sorted { $0.id < $1.id }
            .map { resource in
                let declaration = try JSONDecoder().decode(
                    WorldProceduralPropDeclaration.self,
                    from: Data(contentsOf: base.appendingPathComponent(resource.path))
                )
                return try unwrap(declaration.functionSource,
                    "declaration \(declaration.objectID) must declare a function point")
            }
        context = try WorldAgentContext(manifest: manifest, startedAt: Date(timeIntervalSince1970: 1000),
            propFunctionSources: functionSources)
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: base.appendingPathComponent("marble.json")))
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: base.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ,
                origin: SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2]), uniformScale: config.framing.scale))
        _ = try context.installCollisionWorldAndReconcilePlacement(MarbleLivingCabinCollisionWorld(
            environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes.filter { $0.id == "collision.jukebox" })))
        outcome = ResidentActivityOutcome(context: context, isCurrent: { [unowned self] in self.current },
            currentBlocker: { [unowned self] in self.currentBlockerReason },
            play: { [unowned self] owner in
                let active = self.context.state.activeActivity!
                check(self.gate.consume(worldID: manifest.worldID, activityID: active.activityID,
                    startedAt: active.startedAt, phase: self.context.snapshot.activeActivity!.phase.rawValue,
                    requestID: self.context.currentActivityRequestID), "tracked playback consumes existing gate once")
                if self.unsupported { throw ResidentActivityOutcomeError.unsupportedPlaybackSource }
                if self.musicNotPrepared { throw ResidentActivityOutcomeError.musicNotPrepared }
                self.starts += 1
                self.playbackOwner = owner
                if self.playerHeld { await withCheckedContinuation { self.playerWait = $0 } }
                try Task.checkCancellation()
                if self.fails { throw PlayerError.missingTrack }
                self.playing = true
            }, pause: { [unowned self] owner in
                guard owner == nil || self.playbackOwner == owner else { return }
                if self.pauseFails { throw PlayerError.pauseFailed }
                self.pauses += 1; self.playing = false; self.playbackOwner = nil
            }, sleep: { [unowned self] in
                try Task.checkCancellation()
                if !self.navigationHeld { try self.context.tick(deltaTime: 0.1) }
                await Task.yield()
            }, deadline: deadline)
        context.onSnapshotChanged = { [unowned self] snapshot in
            if snapshot.activeActivity?.id == "music.listen", self.outcome.suppressesAutomaticEffect(snapshot) { self.suppressed += 1 }
        }
        session = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context),
            deadline: Date().addingTimeInterval(300), isCurrent: { [unowned self] in self.current },
            beforeDispatch: { [unowned self] id, name, arguments in self.outcome.prepare(callID: id, name: name, argumentsJSON: arguments) },
            afterDispatch: { [unowned self] name, arguments, result in await self.outcome.complete(name: name, argumentsJSON: arguments, result: result) },
            onCancel: { [unowned self] in self.outcome.abort() })
    }
    func start(_ id: String = "start") async -> RealtimeDJToolResult {
        await session.call(requestID: id, name: "start_activity", argumentsJSON: Data(#"{"activity_id":"music.listen"}"#.utf8))
    }
    func stop() async -> RealtimeDJToolResult {
        await session.call(requestID: "stop", name: "stop_activity", argumentsJSON: Data("{}".utf8))
    }
    func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100_000 { if condition() { return }; await Task.yield() }
        fatalError("fixture condition never reached")
    }
}
@MainActor final class SilentGraphDouble: LocalMusicPlaybackGraph {
    /// 接受了 `play()`，但图自报**没有**在播 —— 注入"只标完成不播"。
    var isPlaying: Bool { false }
    var playbackPosition: TimeInterval { 0 }
    func load(_ url: URL, completion: @escaping @MainActor @Sendable () -> Void) throws -> LocalTrack {
        LocalTrack(url: url, title: url.deletingPathExtension().lastPathComponent, duration: 300)
    }
    func play() throws {}
    func pause() {}
    func stop() {}
}
@MainActor final class FrozenPositionGraphDouble: LocalMusicPlaybackGraph {
    /// 自报在播，但播放位置**永不前进** —— 扬声器没有收到声音的真机形态。
    var isPlaying: Bool { true }
    var playbackPosition: TimeInterval { 0 }
    func load(_ url: URL, completion: @escaping @MainActor @Sendable () -> Void) throws -> LocalTrack {
        LocalTrack(url: url, title: url.deletingPathExtension().lastPathComponent, duration: 300)
    }
    func play() throws {}
    func pause() {}
    func stop() {}
}
@MainActor final class AdvancingGraphDouble: LocalMusicPlaybackGraph {
    private var startedAt: Date?
    var isPlaying: Bool { true }
    var playbackPosition: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }
    func load(_ url: URL, completion: @escaping @MainActor @Sendable () -> Void) throws -> LocalTrack {
        startedAt = nil
        return LocalTrack(url: url, title: url.deletingPathExtension().lastPathComponent, duration: 300)
    }
    func play() throws { startedAt = Date() }
    func pause() {}
    func stop() {}
}
@MainActor final class UnplayableGraphDouble: LocalMusicPlaybackGraph {
    struct Unplayable: Error, LocalizedError {
        var errorDescription: String? { "文件缺失或格式不支持" }
    }
    var isPlaying: Bool { false }
    var playbackPosition: TimeInterval { 0 }
    func load(_ url: URL, completion: @escaping @MainActor @Sendable () -> Void) throws -> LocalTrack {
        throw Unplayable()
    }
    func play() throws { throw Unplayable() }
    func pause() {}
    func stop() {}
}
@main struct Tests {
    @MainActor static func main() async throws {
        do {
            let f = try Fixture()
            async let a = f.start()
            async let b = f.start()
            let (first, duplicate) = await (a, b)
            check(!first.isError && code(first) == "music_playing" && f.playing, "tool reports success only after actual player succeeds")
            check(first == duplicate && f.starts == 1, "concurrent duplicate call awaits same player operation")
            check(f.suppressed > 0, "ordinary frame effect is suppressed while formal request owns playback")
            let cached = await f.start()
            check(cached == first && f.starts == 1, "completed duplicate never replays music")
            f.session.cancel()
            await Task.yield()
            check(f.playing && f.context.state.activeActivity?.activityID == "music.listen", "normal release keeps completed playback and activity")
        }
        do {
            let f = try Fixture(); f.fails = true
            let result = await f.start()
            check(result.isError && code(result) == "music_playback_failed", "missing track or player failure reaches same formal tool")
            let payload = try JSONSerialization.jsonObject(with: result.resultJSON) as! [String: Any]
            check(!(payload["message"] as? String ?? "").contains("请先在播放器选择"),
                  "generic player failure does not force user to select music manually")
            check(!f.playing && f.context.state.activeActivity == nil, "failed playback ends owned activity")
        }
        do {
            let f = try Fixture(); f.musicNotPrepared = true
            let result = await f.start()
            check(result.isError && code(result) == "music_not_prepared", "missing preparation has a distinct actionable fact code")
            let payload = try JSONSerialization.jsonObject(with: result.resultJSON) as! [String: Any]
            let message = payload["message"] as? String ?? ""
            check(message.contains("可用音乐工具") && message.contains("音乐尚未播放"),
                  "missing preparation describes actual state and available tool recovery")
            check(!f.playing && f.starts == 0 && f.context.state.activeActivity == nil,
                  "missing preparation ends owned activity without claiming playback")
        }
        do {
            let f = try Fixture(); f.unsupported = true
            let result = await f.start()
            check(result.isError && code(result) == "playback_source_unsupported" && f.starts == 0, "unsupported source is explicit and never starts external playback")
        }
        do {
            let f = try Fixture(deadline: Date(timeIntervalSince1970: 1))
            let result = await f.start()
            check(code(result) == "activity_timed_out" && f.starts == 0 && f.context.state.activeActivity == nil, "navigation timeout ends owned activity without playing")
        }
        do {
            let f = try Fixture()
            _ = await f.start()
            let stopped = await f.stop()
            check(!stopped.isError && code(stopped) == "music_paused" && !f.playing && f.pauses == 1, "stop activity waits for actual pause")
        }
        do {
            let f = try Fixture(); _ = await f.start(); f.pauseFails = true
            let stopped = await f.stop()
            check(stopped.isError && code(stopped) == "music_pause_failed", "pause failure is not reported as success")
        }
        for mode in ["cancel-navigation", "cancel-player", "caller-cancel", "world-change", "new-activity", "same-time-replacement", "manual-playback", "new-request-playback"] {
            let f = try Fixture()
            f.navigationHeld = mode != "cancel-player" && mode != "manual-playback" && mode != "new-request-playback"
            f.playerHeld = !f.navigationHeld
            let task = Task { await f.start() }
            await f.wait { f.context.state.activeActivity != nil && (f.navigationHeld || f.playerWait != nil) }
            switch mode {
            case "world-change": f.current = false; f.navigationHeld = false
            case "new-activity":
                try f.context.stopActivity(); try f.context.tick(deltaTime: 0.1); try f.context.startActivity(id: "home.idle")
                f.navigationHeld = false
            case "same-time-replacement":
                let oldStartedAt = f.context.state.activeActivity?.startedAt
                let oldRequestID = f.context.currentActivityRequestID
                check(f.context.activityCatalog.definition(id: "music.listen")?.cooldownSeconds == 45,
                      "same-frame replacement uses shipping 45-second cooldown definition")
                var instanceGate = LivingCabinJukeboxGate()
                check(instanceGate.consume(worldID: f.context.manifest.worldID, activityID: "music.listen",
                    startedAt: oldStartedAt!, phase: "loop", requestID: oldRequestID), "first executor identity can trigger effect")
                try f.context.startActivity(id: "music.listen")
                check(f.context.state.activeActivity?.startedAt == oldStartedAt,
                      "real explicit request replacement succeeds with exactly same world timestamp")
                check(f.context.currentActivityRequestID != oldRequestID, "real executor request identity distinguishes same-frame replacement")
                check(instanceGate.consume(worldID: f.context.manifest.worldID, activityID: "music.listen",
                    startedAt: oldStartedAt!, phase: "loop", requestID: f.context.currentActivityRequestID), "replacement gets its own effect despite identical timestamp")
                f.session.cancel()
            case "manual-playback", "new-request-playback":
                f.playbackOwner = UUID(); f.playing = true; f.session.cancel()
            case "caller-cancel": task.cancel()
            default: f.session.cancel()
            }
            f.playerWait?.resume(); f.playerWait = nil
            let result = await task.value
            check(result.isError, "\(mode): cancelled or replaced work cannot return playback success")
            if mode == "world-change" {
                // 失去授权上下文**不是**"被取消"。原因必须逐字回到工具调用方，
                // 否则用户只能看到"已取消"，而"空间正在装修"这种真原因无人知晓。
                check(code(result) == "activity_context_changed",
                      "world-change: a lost authorization context is reported as its own fact, not as a cancellation, got \(code(result) ?? "nil")")
                let payload = try JSONSerialization.jsonObject(with: result.resultJSON) as! [String: Any]
                let message = payload["message"] as? String ?? ""
                check(message.contains(f.currentBlockerReason ?? "\u{0}"),
                      "world-change: the tool must carry the concrete blocker verbatim, got \(message)")
            } else {
                check(code(result) == "activity_cancelled",
                      "\(mode): a real cancellation still reports cancellation, got \(code(result) ?? "nil")")
            }
            let expectedActivity = mode == "new-activity" ? "home.idle" : mode == "same-time-replacement" ? "music.listen" : nil
            check(f.context.state.activeActivity?.activityID == expectedActivity,
                  "\(mode): cleanup only stops its own activity")
            check(mode == "manual-playback" || mode == "new-request-playback" ? f.playing : !f.playing, "\(mode): cancellation cannot affect newer playback")
            if mode == "cancel-navigation" || mode == "world-change" || mode == "new-activity" {
                check(f.starts == 0, "\(mode): old navigation never starts music later")
            }
        }
        do {
            let f = try Fixture(); _ = await f.start()
            let reloaded = try Fixture(); _ = await reloaded.start()
            check(f.context.currentActivityRequestID != reloaded.context.currentActivityRequestID,
                  "independent world contexts isolate executor request IDs")
            let staleApp = AppPlaybackHarness(f.context)
            staleApp.scheduleAutomaticEffect(f.context.snapshot)
            staleApp.livingWorldContext = reloaded.context
            for _ in 0..<100 { await Task.yield() }
            check(staleApp.resumes == 0, "actual delayed App effect cannot play into reloaded world context")
            // 「没出声」必须**上屏**，不能只进日志：静默的失败在真机上与"什么都没发生"
            // 无法区分，这正是 2026-10-01 点唱机缺陷的形态。
            let quiet = AppPlaybackHarness(f.context)
            quiet.spatialStage.selectedWorldID = "some-other-world"
            quiet.scheduleAutomaticEffect(f.context.snapshot)
            check(quiet.liveCamWindowController?.messages.contains { $0.contains("点唱机没有出声") } == true,
                  "a jukebox that cannot play must say why on screen, got \(quiet.liveCamWindowController?.messages ?? [])")
            for state: LocalMusicPlaybackState in [.idle, .paused, .ready, .playing] {
                let app = AppPlaybackHarness(f.context)
                app.localMusicPlayer.state = state
                app.programPlaybackQueue.current = .init(target: .providerReference)
                do {
                    try await app.play(UUID())
                    check(state != .idle && app.resumes == 1, "actual App helper preserves local resume/already-playing despite queued provider source")
                } catch {
                    check(state == .idle && error as? ResidentActivityOutcomeError == .unsupportedPlaybackSource && app.resumes == 0,
                          "actual App helper rejects provider start before calling player")
                }
            }
            let local = AppPlaybackHarness(f.context)
            let owner = UUID()
            try await local.play(owner)
            check(local.resumes == 1 && local.residentJukeboxPlaybackOwner == owner, "actual App helper carries playback ownership into existing resume")
            try await local.pause(UUID())
            check(local.pauses == 0, "actual App helper cannot cancel another playback owner")
            try await local.pause(owner)
            check(local.pauses == 1 && local.localMusicPlayer.state == .paused, "actual App helper pauses its own local playback")
            let manual = AppPlaybackHarness(f.context)
            let oldOwner = UUID()
            try await manual.play(oldOwner)
            manual.toggleLocalPlayback()
            check(manual.residentJukeboxPlaybackOwner == nil && manual.localMusicPlayer.state == .paused,
                  "actual bottom-bar toggle releases resident ownership when manually paused")
            manual.toggleLocalPlayback()
            try await manual.pause(oldOwner)
            check(manual.localMusicPlayer.state == .playing && manual.pauses == 0,
                  "old request cleanup cannot stop music manually resumed by actual toggle")
            let absent = AppPlaybackHarness(f.context)
            absent.activeProgram = nil; absent.programPlaybackQueue.current = nil
            do { try await absent.play(UUID()); check(false, "missing program must fail") }
            catch { check(error as? ResidentActivityOutcomeError == .musicNotPrepared && absent.resumes == 0,
                          "actual App reports missing preparation before calling player") }
            let provider = AppPlaybackHarness(f.context)
            provider.programPlaybackQueue.current = .init(target: .providerReference)
            do { try await provider.pause(nil); check(false, "unsupported provider cannot be reported paused") }
            catch { check(provider.pauses == 0, "provider pause is rejected before local-only pause function") }
        }
        // ── 「请求被接受 ⇒ 播放器真的开始播放」的判据在**真实播放器**上 ─────────
        do {
            let url = URL(fileURLWithPath: "/tmp/fragile.mp3")
            // 注入"只标完成不播"：图接受了 play()，但自报 isPlaying=false。
            let silent = LocalMusicPlayer(graph: SilentGraphDouble())
            try silent.load(url)
            do {
                try silent.play()
                check(false, "a play call the graph never honours must not be reported as playing")
            } catch let error as LocalMusicPlaybackError {
                check(error == .graphNotPlaying,
                      "a graph that never plays must fail as graphNotPlaying, got \(error)")
            }
            check(silent.state != .playing,
                  "the player must not claim .playing while the graph reports isPlaying=false")

            // 图自报在播但位置**不前进**：引擎没有在渲染 = 扬声器没有声音。
            let frozen = LocalMusicPlayer(graph: FrozenPositionGraphDouble())
            try frozen.load(url)
            try frozen.play()
            do {
                _ = try await frozen.confirmPlaybackProgress(timeout: 0.2, minimumAdvance: 0.05)
                check(false, "a frozen playback position must not be accepted as audible playback")
            } catch let error as LocalMusicPlaybackError {
                if case .playbackSilent = error {
                    check(true, "")
                } else {
                    check(false, "a frozen position must fail as playbackSilent, got \(error)")
                }
            }

            // 位置真的在前进 = 唯一成立的"出声"证据。
            let audible = LocalMusicPlayer(graph: AdvancingGraphDouble())
            try audible.load(url)
            try audible.play()
            let observed = try await audible.confirmPlaybackProgress(timeout: 1, minimumAdvance: 0.05)
            check(observed.current > observed.start,
                  "advancing playback position is the audible evidence, got \(observed.start)→\(observed.current)")

            // 没有音轨就播 / 文件缺失或格式不支持：**可见失败**，不静默。
            let noTrack = LocalMusicPlayer(graph: SilentGraphDouble())
            do {
                try noTrack.play()
                check(false, "playing without a loaded track must fail visibly")
            } catch let error as LocalMusicPlaybackError {
                check(error == .trackNotLoaded, "playing without a track must fail as trackNotLoaded, got \(error)")
            }
            let unplayable = LocalMusicPlayer(graph: UnplayableGraphDouble())
            do {
                try unplayable.load(url)
                check(false, "an unplayable file must fail visibly instead of silencing playback")
            } catch {
                check(!(error is LocalMusicPlaybackError),
                      "the graph's own decode error must reach the caller unchanged, got \(error)")
            }
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) jukebox outcome checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-jukebox-outcome-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let program = temp.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
func run(_ binary: String, _ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let worldRuntimeModules = worldRuntimeFlags[1]
let files = ["WorldAgentContext", "WorldAgentToolContract", "WorldAgentToolDispatcher", "ResidentWorldToolSession", "ResidentActivityOutcome"]
let sourcePaths = files.map { sources.appendingPathComponent("Agent/\($0).swift").path }
let objects = Array(worldRuntimeFlags.dropFirst(2))
let arguments = ["-j1", "-parse-as-library", "-I", worldRuntimeModules] + sourcePaths +
    [program.path, "-o", temp.appendingPathComponent("test").path] + objects
let compiled = try run("/usr/bin/swiftc", arguments)
guard compiled == 0 else { exit(compiled) }
exit(try run(temp.appendingPathComponent("test").path, []))
