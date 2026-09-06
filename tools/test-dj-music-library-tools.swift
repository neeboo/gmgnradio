// Hostless contract and dispatch checks; music services are injected, never contacted.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let file = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/DJAgentToolDispatcher.swift")
let source = try String(contentsOf: file, encoding: .utf8)
guard source.contains("name: \"list_music_playlists\""),
      source.contains("name: \"read_music_playlist\""),
      source.contains("name: \"prepare_music_track\"") else {
    print("FAIL: shared DJ tools cannot discover, read, and prepare existing playlists")
    exit(1)
}
let shipping = String(source[source.range(of: "struct DJAgentCapability:")!.lowerBound...])
let harness = #"""
import Foundation
enum StageVisualMood: String, CaseIterable { case afterglow, liquid, pulse }
enum StageLyricsVisualMode: String { case auto; static let agentValues = ["auto"]; init?(agentValue: String) { self.init(rawValue: agentValue) } }
enum SpatialScenePreset: String, CaseIterable { case cabin }
enum SpatialWeather: String, CaseIterable { case clear }
enum SpatialCameraCommandDirection: String, CaseIterable { case reset }
struct RealtimeDJToolCall { let id: String; let name: String; let argumentsJSON: Data }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
enum WorldAgentToolContract { static let capabilities: [DJAgentCapability] = [] }
@MainActor final class WorldAgentToolDispatcher {
    var providerTools: [[String: Any]] { [] }
    func resetSession() {}
    func handle(_ call: RealtimeDJToolCall) async -> RealtimeDJToolResult { fatalError("unexpected world call") }
}
\#(shipping)

@MainActor class LegacyActions: DJAgentRadioActions {
    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState { .init(takeoverEnabled: takeoverEnabled, playbackState: "idle", activeTrackID: nil, activeSlotIndex: nil, program: []) }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? { nil }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws {}
    func playNextTrack() async throws {}
    func playPreviousTrack() async throws {}
    func pauseMusic() async throws {}
    func resumeMusic() async throws {}
    func replanProgram(immediateInstruction: String?) async throws {}
    func activatePreparedProgram() async throws {}
    func insertTrack(immediateInstruction: String) async throws {}
    func setVisualMood(_ mood: StageVisualMood) async throws {}
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { [] }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws {}
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws {}
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float?) async throws {}
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws {}
}
@MainActor final class LibraryActions: DJAgentRadioActions {
    let legacy = LegacyActions()
    var calls: [String] = []
    var failure: Error?
    var gate: CheckedContinuation<Void, Never>?
    var waitForPreparation = false
    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState { legacy.snapshot(takeoverEnabled: takeoverEnabled) }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? { nil }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws {}
    func playNextTrack() async throws {}
    func playPreviousTrack() async throws {}
    func pauseMusic() async throws {}
    func resumeMusic() async throws {}
    func replanProgram(immediateInstruction: String?) async throws {}
    func activatePreparedProgram() async throws {}
    func insertTrack(immediateInstruction: String) async throws {}
    func setVisualMood(_ mood: StageVisualMood) async throws {}
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { [] }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws {}
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws {}
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws {}
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage {
        calls.append("list:\(query ?? "nil"):\(offset):\(limit)")
        if let failure { throw failure }
        return .init(playlists: [.init(id: "netease:p", provider: "netease", name: "爵士", trackCount: 23, loadedTrackCount: 2, supportsPreparation: true)], offset: offset, nextOffset: 2, isSyncing: false)
    }
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        calls.append("read:\(playlistID):\(offset):\(limit)")
        if let failure { throw failure }
        return .init(playlistID: playlistID, tracks: [.init(id: "netease:t", provider: "netease", title: "song", artist: "artist", album: nil, duration: 123, isPlayable: true)], offset: offset, nextOffset: 1, totalTrackCount: 23)
    }
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        calls.append("prepare:\(playlistID):\(trackID)")
        if waitForPreparation { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        return .init(playlistID: playlistID, trackID: trackID)
    }
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures += 1; print("FAIL: \(message)") } }
@MainActor func call(_ dispatcher: DJAgentToolDispatcher, _ name: String, _ json: String = "{}") async -> DJAgentToolResponse {
    let result = await dispatcher.handle(.init(id: UUID().uuidString, name: name, argumentsJSON: Data(json.utf8)))
    return try! JSONDecoder().decode(DJAgentToolResponse.self, from: result.resultJSON)
}
@main struct Tests {
    @MainActor static func main() async {
        let actions = LibraryActions()
        let dispatcher = DJAgentToolDispatcher(takeoverEnabled: { true }, actions: actions)
        let names = ["list_music_playlists", "read_music_playlist", "prepare_music_track"]
        for name in names {
            let capability = DJAgentCapabilityManifest.capabilities.first { $0.name == name }
            check(capability != nil, "\(name) registered in shared manifest")
            check(capability?.requiresTakeover == (name == "prepare_music_track"), "read/write permission for \(name)")
        }
        let listed = await call(dispatcher, names[0])
        check(listed.ok && listed.playlistsPage?.playlists.first?.id == "netease:p", "list real IDs returned")
        check(listed.playlistsPage?.nextOffset == 2 && listed.playlistsPage?.playlists.first?.trackCount == 23, "list paging/counts retained")
        check(actions.calls.last == "list:nil:0:20", "default pagination")
        _ = await call(dispatcher, names[0], #"{"query":" 爵士 ","offset":1,"limit":50}"#)
        check(actions.calls.last == "list:爵士:1:50", "query trimmed and bounded page forwarded")
        let read = await call(dispatcher, names[1], #"{"playlist_id":"netease:p"}"#)
        check(read.ok && read.playlistPage?.tracks.first?.id == "netease:t" && read.playlistPage?.totalTrackCount == 23, "track page payload retained")
        let prepared = await call(dispatcher, names[2], #"{"playlist_id":"netease:p","track_id":"netease:t"}"#)
        check(prepared.ok && prepared.preparation?.status == "prepared" && prepared.preparation?.isPlaying == false, "preparation never claims playing")
        let malformed: [(String,String)] = [
            (names[0], #"{"limit":0}"#), (names[0], #"{"limit":51}"#), (names[0], #"{"offset":-1}"#),
            (names[0], #"{"offset":true}"#), (names[0], #"{"limit":2.5}"#), (names[0], #"{"offset":"1"}"#),
            (names[0], #"{"query":3}"#), (names[0], #"{"query":null}"#), (names[0], #"{"unknown":1}"#),
            (names[1], "{}"), (names[1], #"{"playlist_id":" "}"#), (names[1], #"{"playlist_id":7}"#),
            (names[1], #"{"playlist_id":"p","offset":false}"#), (names[1], #"{"playlist_id":"p","limit":null}"#),
            (names[2], #"{"playlist_id":"p"}"#), (names[2], #"{"playlist_id":"p","track_id":""}"#),
            (names[2], #"{"playlist_id":"p","track_id":"t","url":"https://example.invalid"}"#),
            (names[2], #"{"playlist_id":"p\n","track_id":"t"}"#), (names[0], "[]")
        ]
        for (name, json) in malformed {
            let count = actions.calls.count
            let response = await call(dispatcher, name, json)
            check(!response.ok && response.code == "invalid_arguments", "reject malformed \(name): \(json)")
            check(actions.calls.count == count, "invalid args never reach executor")
        }
        let readOnly = DJAgentToolDispatcher(takeoverEnabled: { false }, actions: actions)
        check((await call(readOnly, names[0])).ok, "discovery allowed without takeover")
        let denied = await call(readOnly, names[2], #"{"playlist_id":"p","track_id":"t"}"#)
        check(!denied.ok && denied.code == "takeover_disabled", "preparation needs write scope")
        actions.failure = DJAgentMusicLibraryError.playlistNotFound
        let notFound = await call(dispatcher, names[1], #"{"playlist_id":"missing"}"#)
        check(notFound.code == "playlist_not_found", "known failure code preserved")
        actions.failure = NSError(domain: "https://host.invalid/?key=secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://host.invalid/?key=secret"])
        let safe = await call(dispatcher, names[1], #"{"playlist_id":"p"}"#)
        check(!safe.ok && !safe.message.contains("secret") && !safe.message.contains("https:"), "unknown errors do not leak provider URLs or keys")
        actions.failure = CancellationError()
        check((await call(dispatcher, names[0])).code == "operation_cancelled", "cancellation reported distinctly")
        actions.failure = nil
        actions.waitForPreparation = true
        var finished = false
        let pending = Task { @MainActor in
            let result = await call(dispatcher, names[2], #"{"playlist_id":"p","track_id":"t"}"#)
            finished = true
            return result
        }
        while actions.gate == nil { await Task.yield() }
        check(!finished, "preparation waits for actual executor result")
        actions.gate?.resume(); actions.gate = nil
        check((await pending.value).ok, "preparation completes after executor")
        let legacy = LegacyActions()
        let old = DJAgentToolDispatcher(takeoverEnabled: { true }, actions: legacy)
        check((await call(old, names[0])).code == "music_library_unsupported", "legacy conformer safely defaults to unsupported")
        let encoded = try! JSONEncoder().encode(DJAgentToolResponse(ok: true, code: nil, message: "old", state: nil, tracks: nil, currentTrack: nil))
        check((try! JSONDecoder().decode(DJAgentToolResponse.self, from: encoded)).playlistsPage == nil, "old response construction remains compatible")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) shared music tool checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dj-music-tests-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let tests = directory.appendingPathComponent("Tests.swift")
try harness.write(to: tests, atomically: true, encoding: .utf8)
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let binary = directory.appendingPathComponent("test")
let status = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", tests.path, "-o", binary.path])
guard status == 0 else { exit(status) }
exit(try run(binary.path, []))
