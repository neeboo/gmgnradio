// Hostless checks of the real resident lease and shared music dispatcher.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent")
guard FileManager.default.fileExists(atPath: sources.appendingPathComponent("ResidentMusicToolBridge.swift").path) else {
    print("FAIL: resident music bridge is not implemented")
    exit(1)
}
let harness = #"""
import Foundation
import WorldRuntime
enum StageVisualMood: String, CaseIterable { case afterglow, liquid, pulse }
enum StageLyricsVisualMode: String { case auto; static let agentValues = ["auto"]; init?(agentValue: String) { self.init(rawValue: agentValue) } }
enum SpatialScenePreset: String, CaseIterable { case cabin }
enum SpatialWeather: String, CaseIterable { case clear }
enum SpatialCameraCommandDirection: String, CaseIterable { case reset }
struct RealtimeDJToolCall { let id: String; let name: String; let argumentsJSON: Data }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class Actions: DJAgentRadioActions {
    var calls: [String] = []
    var failure: Error?
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState {
        .init(takeoverEnabled: takeoverEnabled, playbackState: "idle", activeTrackID: nil, activeSlotIndex: nil,
              program: (0..<75).map { .init(index: $0, id: "track-\($0)", title: "Title", artist: "Artist") })
    }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? { calls.append("current"); return nil }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws { fatalError("forbidden playback") }
    func playNextTrack() async throws { fatalError("forbidden playback") }
    func playPreviousTrack() async throws { fatalError("forbidden playback") }
    func pauseMusic() async throws { fatalError("forbidden playback") }
    func resumeMusic() async throws { fatalError("forbidden playback") }
    func replanProgram(immediateInstruction: String?) async throws { fatalError("forbidden replan") }
    func activatePreparedProgram() async throws { fatalError("forbidden playback") }
    func insertTrack(immediateInstruction: String) async throws { fatalError("forbidden insert") }
    func setVisualMood(_ mood: StageVisualMood) async throws { fatalError("forbidden visual") }
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { fatalError("forbidden search") }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws { fatalError("forbidden visual") }
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws { fatalError("forbidden world") }
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws { fatalError("forbidden camera") }
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage {
        calls.append("list:\(query ?? "nil"):\(offset):\(limit)")
        if let failure { throw failure }
        return .init(playlists: [.init(id: "fixture:playlist", provider: "fixture", name: "舒缓", trackCount: 60,
            loadedTrackCount: 2, supportsPreparation: true)], offset: offset, nextOffset: 2, isSyncing: false)
    }
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        calls.append("read:\(playlistID)")
        if let failure { throw failure }
        return .init(playlistID: playlistID, tracks: [.init(id: "fixture:track", provider: "fixture", title: "Song",
            artist: "Artist", album: nil, duration: 180, isPlayable: true)], offset: offset, nextOffset: 1, totalTrackCount: 60)
    }
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        calls.append("prepare:\(trackID)")
        if hold { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        return .init(playlistID: playlistID, trackID: trackID)
    }
}
@MainActor var count = 0
@MainActor func check(_ value: Bool, _ message: String) { if !value { fatalError("FAIL: " + message) }; count += 1 }
func json(_ result: RealtimeDJToolResult) -> [String: Any] { try! JSONSerialization.jsonObject(with: result.resultJSON) as! [String: Any] }
@main struct Tests {
    @MainActor static func main() async throws {
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
        let context = try WorldAgentContext(manifest: manifest)
        let actions = Actions()
        var current = true
        let bridge = ResidentMusicToolBridge(actions: actions, isCurrent: { current })
        let expected: Set<String> = ["read_radio_state", "read_current_track", "list_music_playlists", "read_music_playlist", "prepare_music_track"]
        check(Set(bridge.tools.map(\.name)) == expected, "exactly five resident music capabilities")
        let session = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context),
            deadline: Date().addingTimeInterval(30), isCurrent: { current }, additionalTools: bridge.tools)
        let schemas = try JSONSerialization.jsonObject(with: session.toolSchemasJSON) as! [[String: Any]]
        check(schemas.count == 13, "real session registers music and eight world tools")
        for tool in bridge.tools {
            check(tool.inputSchema["additionalProperties"] as? Bool == false, "shared schema closes extra arguments")
        }
        func call(_ name: String, _ arguments: String = "{}", id: String = UUID().uuidString) async -> RealtimeDJToolResult {
            await session.call(requestID: id, name: name, argumentsJSON: Data(arguments.utf8))
        }
        for forbidden in ["search_music", "resume_music", "replan_program", "insert_track", "shell"] {
            let denied = await call(forbidden)
            check(denied.isError && json(denied)["code"] as? String == "tool_not_allowed", "broader DJ capability never enters resident lease")
        }
        let stateResult = await call("read_radio_state")
        let state = json(stateResult)["state"] as! [String: Any]
        check(!stateResult.isError && (state["program"] as? [Any])?.count == 50, "large program is bounded")
        check(state["programTotalCount"] as? Int == 75, "truncation exposes actual total")
        check(Set((state["capabilities"] as! [[String: Any]]).compactMap { $0["name"] as? String }) == expected, "state never advertises wider DJ privileges")
        let currentTrack = await call("read_current_track")
        check(!currentTrack.isError && json(currentTrack)["currentTrack"] == nil, "absence of real current track remains absent")
        let listed = await call("list_music_playlists", #"{"query":"舒缓","offset":0,"limit":2}"#)
        check(!listed.isError && actions.calls.last == "list:舒缓:0:2", "real dispatcher forwards playlist query")
        check((json(listed)["playlistsPage"] as? [String: Any])?["nextOffset"] as? Int == 2, "playlist pagination retained")
        let page = await call("read_music_playlist", #"{"playlist_id":"fixture:playlist"}"#)
        check(!page.isError && (json(page)["playlistPage"] as? [String: Any])?["totalTrackCount"] as? Int == 60, "real playlist facts retained")
        let arguments = #"{"playlist_id":"fixture:playlist","track_id":"fixture:track"}"#
        let prepared = await call("prepare_music_track", arguments, id: "prepare-once")
        let preparedPayload = json(prepared)["preparation"] as! [String: Any]
        check(!prepared.isError && preparedPayload["status"] as? String == "prepared" && preparedPayload["isPlaying"] as? Bool == false, "preparation does not claim music playback")
        _ = await call("prepare_music_track", arguments, id: "prepare-once")
        check(actions.calls.filter { $0 == "prepare:fixture:track" }.count == 1, "real lease deduplicates preparation")
        for (name, malformed) in [("read_radio_state", #"{"secret":"bad"}"#), ("read_current_track", #"{"id":3}"#),
            ("list_music_playlists", #"{"offset":true}"#), ("list_music_playlists", #"{"limit":1.5}"#),
            ("read_music_playlist", #"{"playlist_id":null}"#), ("prepare_music_track", #"{"playlist_id":"p","track_id":"t","url":"bad"}"#)] {
            let before = actions.calls.count
            let result = await call(name, malformed)
            check(result.isError && json(result)["code"] as? String == "invalid_arguments", "invalid parameters rejected before DJ dispatch")
            check(actions.calls.count == before, "invalid request never touches music service")
        }
        actions.failure = DJAgentMusicLibraryError.playlistNotFound
        let missing = await call("read_music_playlist", #"{"playlist_id":"missing"}"#)
        check(missing.isError && json(missing)["code"] as? String == "playlist_not_found", "shared failure code remains truthful")
        actions.failure = nil
        current = false
        let before = actions.calls.count
        let stale = await call("prepare_music_track", arguments)
        check(stale.isError && actions.calls.count == before, "stale lease performs no preparation")
        current = true
        actions.hold = true
        let direct = bridge.tools.first { $0.name == "prepare_music_track" }!
        let pending = Task { await direct.handle("pending", Data(arguments.utf8)) }
        while actions.pending == nil { await Task.yield() }
        current = false
        actions.pending?.resume(); actions.pending = nil
        let late = await pending.value
        check(late.isError && json(late)["code"] as? String == "stale_music_session", "bridge suppresses result after world changes mid-operation")
        current = true
        let cancelled = Task { await direct.handle("cancelled", Data(arguments.utf8)) }
        while actions.pending == nil { await Task.yield() }
        cancelled.cancel()
        actions.pending?.resume(); actions.pending = nil
        let cancelledResult = await cancelled.value
        check(cancelledResult.isError && json(cancelledResult)["code"] as? String == "stale_music_session", "cancelled operation cannot report successful preparation")
        let freshBridge = ResidentMusicToolBridge(actions: actions, isCurrent: { true })
        actions.hold = false
        let fresh = freshBridge.tools.first { $0.name == "prepare_music_track" }!
        let freshResult = await fresh.handle("prepare-once", Data(arguments.utf8))
        check(!freshResult.isError && actions.calls.filter { $0 == "prepare:fixture:track" }.count == 4, "new bridge owns its own dispatcher ledger")
        print("PASS: \(count) resident music bridge checks")
    }
}
"""#
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-music-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let modules = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects = try FileManager.default.contentsOfDirectory(at: modules.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
let files = ["WorldAgentContext", "WorldAgentToolContract", "WorldAgentToolDispatcher", "ResidentWorldToolSession", "DJAgentToolDispatcher", "ResidentMusicToolBridge"]
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-parse-as-library", "-I", modules.appendingPathComponent("Modules").path] + files.map { sources.appendingPathComponent($0 + ".swift").path } + objects + [main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
