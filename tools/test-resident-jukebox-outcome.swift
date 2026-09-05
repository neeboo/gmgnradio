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
    let opening = text[start...].firstIndex(of: "{")!
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}
let appSource = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
let resumeMethod = declaration("private func resumeResidentJukebox(", in: appSource)
let pauseMethod = declaration("private func pauseResidentJukebox(", in: appSource)
let playerSource = try String(contentsOf: sources.appendingPathComponent("AudioEngine/LocalMusicPlayer.swift"), encoding: .utf8)
let queueSource = try String(contentsOf: sources.appendingPathComponent("AudioEngine/ProgramPlaybackQueue.swift"), encoding: .utf8)
let playerState = declaration("enum LocalMusicPlaybackState:", in: playerSource)
let playbackRoute = declaration("enum ProgramPlaybackStartRoute:", in: queueSource)
let harness = #"""
import Foundation
import WorldRuntime
\#(physicsAndGate)
struct RealtimeDJToolCall: Codable, Equatable, Sendable { let id: String; let name: String; let argumentsJSON: Data }
struct RealtimeDJToolResult: Codable, Equatable, Sendable { let callID: String; let resultJSON: Data; let isError: Bool }
struct Config: Decodable { struct Framing: Decodable { let origin: [Float]; let scale: Float }; let framing: Framing }
enum PlayerError: Error { case missingTrack, pauseFailed }
\#(playerState)
\#(playbackRoute)
@MainActor final class AppPlaybackHarness {
    struct Stage { var selectedWorldID: String }
    struct Player { var state: LocalMusicPlaybackState = .idle }
    struct Prepared { enum Target { case localFile, providerReference }; var target: Target }
    struct Queue { var current: Prepared? }
    var livingWorldContext: WorldAgentContext?
    var spatialStage: Stage
    var localMusicPlayer = Player()
    var activeProgram: Bool? = true
    var programPlaybackQueue = Queue(current: Prepared(target: .localFile))
    var livingCabinJukeboxGate = LivingCabinJukeboxGate()
    var residentJukeboxPlaybackOwner: UUID?
    var resumes = 0
    var pauses = 0
    init(_ context: WorldAgentContext) { livingWorldContext = context; spatialStage = Stage(selectedWorldID: context.manifest.worldID) }
    func resumeMusic() async throws {
        resumes += 1
        let route = ProgramPlaybackStartRoute.resolve(playerState: localMusicPlayer.state,
            hasPreparedProgram: activeProgram != nil && programPlaybackQueue.current != nil)
        if route == .unavailable { throw PlayerError.missingTrack }
        if route != .alreadyPlaying { residentJukeboxPlaybackOwner = ResidentActivityOutcome.playbackOwner }
        localMusicPlayer.state = .playing
    }
    func pauseMusic() async throws { pauses += 1; localMusicPlayer.state = .paused; residentJukeboxPlaybackOwner = nil }
    \#(resumeMethod)
    \#(pauseMethod)
    func play(_ owner: UUID) async throws { try await resumeResidentJukebox(owner: owner) }
    func pause(_ owner: UUID?) async throws { try await pauseResidentJukebox(owner: owner) }
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures += 1; print("FAIL: \(message)") } }
func code(_ result: RealtimeDJToolResult) -> String? { (try? JSONSerialization.jsonObject(with: result.resultJSON) as? [String: Any])?["code"] as? String }
@MainActor final class Fixture {
    let context: WorldAgentContext
    var current = true
    var starts = 0
    var pauses = 0
    var fails = false
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
        context = try WorldAgentContext(manifest: manifest, startedAt: Date(timeIntervalSince1970: 1000))
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: base.appendingPathComponent("marble.json")))
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: base.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ,
                origin: SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2]), uniformScale: config.framing.scale))
        _ = try context.installCollisionWorldAndReconcilePlacement(MarbleLivingCabinCollisionWorld(
            environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes.filter { $0.id == "collision.jukebox" })))
        outcome = ResidentActivityOutcome(context: context, isCurrent: { [unowned self] in self.current },
            play: { [unowned self] owner in
                let active = self.context.state.activeActivity!
                check(self.gate.consume(worldID: manifest.worldID, activityID: active.activityID,
                    startedAt: active.startedAt, phase: self.context.snapshot.activeActivity!.phase.rawValue), "tracked playback consumes existing gate once")
                if self.unsupported { throw ResidentActivityOutcomeError.unsupportedPlaybackSource }
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
            check(!f.playing && f.context.state.activeActivity == nil, "failed playback ends owned activity")
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
        for mode in ["cancel-navigation", "cancel-player", "caller-cancel", "world-change", "new-activity", "manual-playback", "new-request-playback"] {
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
            case "manual-playback", "new-request-playback":
                f.playbackOwner = UUID(); f.playing = true; f.session.cancel()
            case "caller-cancel": task.cancel()
            default: f.session.cancel()
            }
            f.playerWait?.resume(); f.playerWait = nil
            let result = await task.value
            check(result.isError, "\(mode): cancelled or replaced work cannot return playback success")
            check(mode == "new-activity" ? f.context.state.activeActivity?.activityID == "home.idle" : f.context.state.activeActivity == nil,
                  "\(mode): cleanup only stops its own activity")
            check(mode == "manual-playback" || mode == "new-request-playback" ? f.playing : !f.playing, "\(mode): cancellation cannot affect newer playback")
            if mode == "cancel-navigation" || mode == "world-change" || mode == "new-activity" {
                check(f.starts == 0, "\(mode): old navigation never starts music later")
            }
        }
        do {
            let f = try Fixture(); _ = await f.start()
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
            let absent = AppPlaybackHarness(f.context)
            absent.activeProgram = nil; absent.programPlaybackQueue.current = nil
            do { try await absent.play(UUID()); check(false, "missing program must fail") }
            catch { check(absent.resumes == 1, "missing program error comes from existing resume function") }
            let provider = AppPlaybackHarness(f.context)
            provider.programPlaybackQueue.current = .init(target: .providerReference)
            do { try await provider.pause(nil); check(false, "unsupported provider cannot be reported paused") }
            catch { check(provider.pauses == 0, "provider pause is rejected before local-only pause function") }
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
let build = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let files = ["WorldAgentContext", "WorldAgentToolContract", "WorldAgentToolDispatcher", "ResidentWorldToolSession", "ResidentActivityOutcome"]
let sourcePaths = files.map { sources.appendingPathComponent("Agent/\($0).swift").path }
let objects = try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "o" }.map(\.path)
let arguments = ["-j1", "-parse-as-library", "-I", build.appendingPathComponent("Modules").path] + sourcePaths +
    [program.path, "-o", temp.appendingPathComponent("test").path] + objects
let compiled = try run("/usr/bin/swiftc", arguments)
guard compiled == 0 else { exit(compiled) }
exit(try run(temp.appendingPathComponent("test").path, []))
