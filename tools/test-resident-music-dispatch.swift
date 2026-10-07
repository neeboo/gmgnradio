// Hostless check for the resident music tool dispatch chain: the session built
// exactly like the app's ResidentConversationTools assembly must both DECLARE
// the five music tools and actually DISPATCH them to the radio actions — a
// schema that cannot dispatch is the "unknown tool" failure the resident saw.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let harness = #"""
import Foundation
import WorldRuntime

// Same enum stand-ins as the music bridge harness: visual enums are playback
// side-calls the resident lease never uses; the fake actions fail on them.
enum StageVisualMood: String, CaseIterable { case afterglow, liquid, pulse }
enum StageLyricsVisualMode: String { case auto; static let agentValues = ["auto"]; init?(agentValue: String) { self.init(rawValue: agentValue) } }
enum SpatialScenePreset: String, CaseIterable { case cabin }
enum SpatialWeather: String, CaseIterable { case clear }
enum SpatialCameraCommandDirection: String, CaseIterable { case reset }

let worldJSON = try! Data(contentsOf: URL(fileURLWithPath:
    "apps/macos/Resources/Worlds/marble-living-cabin/world.json"))

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}
func json(_ result: RealtimeDJToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] ?? [:]
}

struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: Data
}
struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String
    let resultJSON: Data
    let isError: Bool
}

/// Records the formal music sequence and returns real-shaped data, so a
/// successful receipt can only come from an actual dispatch.
@MainActor
final class FakeRadioActions: DJAgentRadioActions {
    private(set) var calls: [String] = []
    var prepared = false
    var playing = false

    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState {
        calls.append("read_radio_state")
        return DJAgentRadioState(takeoverEnabled: takeoverEnabled,
            playbackState: playing ? "playing" : "paused",
            activeTrackID: prepared ? "moon" : nil,
            activeSlotIndex: nil, program: [])
    }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? {
        calls.append("read_current_track")
        guard prepared else { return nil }
        return DJAgentCurrentTrackSnapshot(
            sampledAt: "fixture", playbackState: playing ? "playing" : "paused",
            isPlaying: playing, id: "moon", provider: "fixture", source: "playlist",
            title: "Moon", artist: "Fixture", album: nil, durationSeconds: 180,
            positionSeconds: 0, remainingSeconds: 180, progress: 0,
            programID: nil, programTitle: nil, slotIndex: nil,
            previousTrack: nil, nextTrack: nil)
    }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws { calls.append("play") }
    func playNextTrack() async throws { calls.append("next") }
    func playPreviousTrack() async throws { calls.append("previous") }
    func pauseMusic() async throws { calls.append("pause") }
    func resumeMusic() async throws { calls.append("resume") }
    func replanProgram(immediateInstruction: String?) async throws { calls.append("replan") }
    func activatePreparedProgram() async throws {
        calls.append("activate")
        playing = prepared
    }
    func insertTrack(immediateInstruction: String) async throws { calls.append("insert") }
    func setVisualMood(_ mood: StageVisualMood) async throws { calls.append("mood") }
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { [] }
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage {
        calls.append("list_music_playlists")
        return DJAgentMusicPlaylistsPage(playlists: [
            DJAgentMusicPlaylist(id: "night", provider: "fixture", name: "Night Radio",
                trackCount: 1, loadedTrackCount: 1, supportsPreparation: true),
        ], offset: 0, nextOffset: nil, isSyncing: false)
    }
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        calls.append("read_music_playlist")
        return DJAgentMusicPlaylistPage(playlistID: playlistID,
            tracks: [DJAgentMusicTrack(id: "moon", provider: "fixture", title: "Moon",
                artist: "Fixture", album: nil, duration: 180, isPlayable: true)],
            offset: 0, nextOffset: nil, totalTrackCount: 1)
    }
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        calls.append("prepare_music_track")
        prepared = true
        return DJAgentMusicPreparation(playlistID: playlistID, trackID: trackID)
    }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws { calls.append("lyrics") }
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws { calls.append("environment") }
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws { calls.append("camera") }
}

@main struct Tests {
    @MainActor static func main() async throws {
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: worldJSON)
        let context = try WorldAgentContext(manifest: manifest)
        let actions = FakeRadioActions()

        // Assembled exactly like the app's ResidentConversationTools lease:
        // world dispatcher + music bridge in additionalTools.
        let isCurrent = { true }
        let musicTools = ResidentMusicToolBridge(actions: actions, isCurrent: isCurrent)
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
            onActivityStarted: { _, _ in }, availableActivity: { _ in true })
        let session = ResidentWorldToolSession(
            scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date().addingTimeInterval(300),
            isCurrent: isCurrent,
            additionalTools: musicTools.tools,
            maximumCalls: nil)

        // 1. Declaration: all five music tools are in the schema the model sees.
        let schemaNames = (try JSONSerialization.jsonObject(with: session.toolSchemasJSON) as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        for name in ["read_radio_state", "read_current_track", "list_music_playlists",
                     "read_music_playlist", "prepare_music_track"] {
            check(schemaNames.contains(name), "schema declares \(name)")
        }

        func call(_ id: String, _ name: String, _ arguments: String = "{}") async -> RealtimeDJToolResult {
            await session.call(requestID: id, name: name, argumentsJSON: Data(arguments.utf8))
        }

        // 2. Dispatch: the formal sequence must reach the radio actions and the
        //    final read_current_track must report real playing state.
        let listed = await call("t1", "list_music_playlists")
        check(!listed.isError && json(listed)["ok"] as? Bool == true,
            "list_music_playlists dispatches instead of unknown tool")
        let read = await call("t2", "read_music_playlist", #"{"playlist_id":"night"}"#)
        check(!read.isError, "read_music_playlist dispatches")
        let prepared = await call("t3", "prepare_music_track",
            #"{"playlist_id":"night","track_id":"moon"}"#)
        check(!prepared.isError, "prepare_music_track dispatches")
        let started = await call("t4", "start_activity", #"{"activity_id":"music.listen"}"#)
        let startedCode = json(started)["code"] as? String
        // 无宿主碰撞数据时宿主侧可返回域内错误（如 route_blocked）；协议层
        // 失败只允许是 unknown/未开放，那才是本测试要抓的 schema 分叉。
        check(startedCode != "unknown_world_tool" && startedCode != "tool_not_allowed",
            "start_activity music.listen reaches the world executor, not an unknown-tool reply")
        check(actions.calls.isEmpty == false, "dispatch happened")
        // Strict evidence: this harness has no activity outcome and no real
        // playback, so preparation must NOT read as playing. Real playing
        // success is proven only by ResidentActivityOutcome + the live host.
        let track = await call("t5", "read_current_track")
        let trackBody = json(track)
        let state = trackBody["state"] as? [String: Any]
        let snapshot = trackBody["current"] as? [String: Any]
        check(!track.isError, "read_current_track reaches the real dispatcher after preparation")
        check(actions.calls.contains("read_current_track"),
            "the read reached the radio actions, not an unknown-tool echo")
        check((state?["playbackState"] as? String) != "playing"
            && (snapshot?["isPlaying"] as? Bool) != true,
            "no fabricated playing state: prepared-but-not-playing stays paused in this harness (activeTrackID alone is not playback)")
        check(actions.calls.contains("list_music_playlists")
            && actions.calls.contains("read_music_playlist")
            && actions.calls.contains("prepare_music_track")
            && actions.calls.contains("read_current_track"),
            "the receipts came from real dispatch, not a fabricated echo")

        // 3. A hallucinated tool stays an honest failure — never a success.
        let hallucinated = await call("t6", "play_music_now")
        check(hallucinated.isError, "an undeclared tool fails honestly")

        // 4. No selection: reading the current track before preparation is a
        //    real failure, not a made-up playing state.
        let freshActions = FakeRadioActions()
        let freshSession = ResidentWorldToolSession(
            scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
                onActivityStarted: { _, _ in }, availableActivity: { _ in true }),
            deadline: Date().addingTimeInterval(300),
            isCurrent: { true },
            additionalTools: ResidentMusicToolBridge(actions: freshActions, isCurrent: { true }).tools,
            maximumCalls: nil)
        let unprepared = await freshSession.call(requestID: "u1", name: "read_current_track",
            argumentsJSON: Data("{}".utf8))
        check(unprepared.isError || json(unprepared)["current"] == nil,
            "reading without a selected track reports the real empty state")

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident music dispatch checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-music-dispatch-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("music-dispatch")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let files = ["WorldAgentContext", "WorldAgentToolContract", "WorldAgentToolDispatcher",
             "ResidentWorldToolSession", "DJAgentToolDispatcher", "ResidentMusicToolBridge"]
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
var arguments = ["-j1", "-parse-as-library", sources.appendingPathComponent("Presence/RetryBackoff.swift").path] + worldRuntimeHarnessFlags()
for name in files {
    arguments.append(sources.appendingPathComponent("Agent/\(name).swift").path)
}
arguments += [program.path, "-o", executable.path]
compile.arguments = arguments
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = URL(fileURLWithPath: executable.path)
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
