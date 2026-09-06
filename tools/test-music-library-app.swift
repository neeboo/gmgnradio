// Compile the production commit boundary without audio, network or the app host.
import Foundation
let appSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", encoding: .utf8)
let app = String(appSource[appSource.range(of: "final class AppDelegate:")!.lowerBound...])
guard app.contains("private func commitMusicLibraryPreparation("),
      app.contains("ResidentMusicToolBridge(actions: self, isCurrent: isCurrent)"),
      app.contains("additionalTools: additionalTools + musicTools.tools") else {
    print("FAIL: shared music library capabilities are not wired into the resident lease")
    exit(1)
}
func method(_ signature: String) -> String {
    let start = app.range(of: signature)!.lowerBound
    let body = app.range(of: #"\)\s*(?:async\s*)?(?:throws\s*)?(?:->\s*[A-Za-z_][A-Za-z0-9_<>?\[\]:. ]*\s*)?\{"#, options: .regularExpression, range: start..<app.endIndex)!
    let opening = app.index(before: body.upperBound)
    var depth = 0
    for i in app[opening...].indices {
        if app[i] == "{" { depth += 1 }
        if app[i] == "}" { depth -= 1 }
        if depth == 0 { return String(app[start...i]) }
    }
    fatalError("unterminated declaration")
}
let playbackIntentEntrypoints = [
    "private func startAIProgram(", "private func cancelResidentMessage(",
    "func chooseLocalTrack(", "func toggleLocalPlayback(", "private func playLocalTrack(",
    "private func playProgramTrack(", "private func playPreviousProgramTrack(",
    "private func playNextProgramTrack(", "\n    func playProgramTrack(",
    "func playNextTrack(", "func playPreviousTrack(", "func pauseMusic(", "func resumeMusic(",
    "func activatePreparedProgram(", "private func scheduleBackgroundTrackInsertion(", "private func playPrepared(",
]
for entrypoint in playbackIntentEntrypoints {
    guard method(entrypoint).contains("musicSelectionGeneration &+= 1") else {
        print("FAIL: playback intent does not invalidate late preparation: \(entrypoint)")
        exit(1)
    }
}
for query in ["func listMusicPlaylists(", "func readMusicPlaylist(", "private func makeMusicLibraryAgentService("] {
    precondition(!method(query).contains("musicSelectionGeneration &+= 1"), "library observation must not take over playback")
}
let source = #"""
import Foundation
struct ProgramPlan { let id: String }
final class ProgramPlaybackQueue {
    init() {}
    init(preflight: PlaybackPreflight, lockedCapacity: Int) {}
}
enum DJAgentMusicLibraryError: Error { case busy, interrupted }
struct PlaybackPreflight { let preparer: MusicRuntimePlaybackPreparer }
struct MusicRuntimePlaybackPreparer { let runtime: Runtime }
final class Runtime {
    func fetchPlaylistPage(providerID: Int, playlistID: String, offset: Int, limit: Int) async throws -> Int { 0 }
}
final class World {}
final class Space { var selectedWorldID = "room" }
@MainActor final class MusicLibraryAgentService {
    let isCurrent: @MainActor () -> Bool
    let commit: @MainActor (ProgramPlan, ProgramPlaybackQueue, Int) throws -> Void
    init(store: Store, fetchPage: @escaping @MainActor (Int, String, Int, Int) async throws -> Int,
         makeQueue: @escaping @MainActor () -> ProgramPlaybackQueue,
         isCurrent: @escaping @MainActor () -> Bool,
         commit: @escaping @MainActor (ProgramPlan, ProgramPlaybackQueue, Int) throws -> Void) {
        self.isCurrent = isCurrent; self.commit = commit
    }
}
enum State { case ready }
final class Player { var stops = 0; func stop() { stops += 1 } }
final class Store {
    var plan: ProgramPlan?; var index: Int?
    func publish(_ plan: ProgramPlan) { self.plan = plan }
    func activateSlot(at index: Int) { self.index = index }
}
final class Stage { var state: State?; func setPlaybackState(_ state: State) { self.state = state } }
@MainActor final class App {
    var isStartingProgramPlayback = false
    var musicSelectionGeneration: UInt64 = 0
    let spatialStage = Space()
    let livingWorldContext = World()
    let musicRuntime = Runtime()
    let musicLibraryStore = Store()
    let localMusicPlayer = Player()
    var residentJukeboxPlaybackOwner: UUID? = UUID()
    var committedPlaybackTrack: String? = "old"
    var previousCommittedPlaybackTrack: String? = "previous"
    var activeProgram: ProgramPlan?
    var programPlaybackQueue = ProgramPlaybackQueue()
    let programStore = Store()
    var stageWindowController: Stage? = Stage()
    var refreshes = 0
    func updateStageProgramNavigation() { refreshes += 1 }
    \#(method("private func makeMusicLibraryAgentService("))
    \#(method("private func commitMusicLibraryPreparation("))
    func service() -> MusicLibraryAgentService { makeMusicLibraryAgentService() }
    func commit(_ plan: ProgramPlan, _ queue: ProgramPlaybackQueue, _ index: Int) throws {
        try commitMusicLibraryPreparation(plan: plan, queue: queue, index: index)
    }
}
@main struct Test {
    @MainActor static func main() throws {
        let app = App(); let queue = ProgramPlaybackQueue(); let plan = ProgramPlan(id: "playlist")
        app.isStartingProgramPlayback = true
        do { try app.commit(plan, queue, 2); fatalError("busy commit accepted") } catch DJAgentMusicLibraryError.busy {}
        precondition(app.localMusicPlayer.stops == 0 && app.activeProgram == nil)
        app.isStartingProgramPlayback = false
        try app.commit(plan, queue, 2)
        precondition(app.programPlaybackQueue === queue && app.activeProgram?.id == plan.id)
        precondition(app.programStore.plan?.id == plan.id && app.programStore.index == 2)
        precondition(app.localMusicPlayer.stops == 1 && app.committedPlaybackTrack == nil)
        precondition(app.residentJukeboxPlaybackOwner == nil && app.stageWindowController?.state == .ready)
        precondition(app.refreshes == 1)
        let delayed = app.service()
        precondition(delayed.isCurrent())
        _ = app.service() // Ordinary query service construction is read-only.
        precondition(delayed.isCurrent(), "ordinary library queries must not invalidate preparation")
        app.musicSelectionGeneration &+= 1 // A later manual/shared DJ playback choice.
        guard !delayed.isCurrent() else {
            print("FAIL: a prepared selection remains current after playback intent changed")
            exit(1)
        }
        let stops = app.localMusicPlayer.stops
        do {
            try delayed.commit(ProgramPlan(id: "late"), ProgramPlaybackQueue(), 0)
            print("FAIL: delayed shared DJ preparation overwrote the newer playback choice")
            exit(1)
        } catch DJAgentMusicLibraryError.interrupted {}
        precondition(app.localMusicPlayer.stops == stops && app.activeProgram?.id == "playlist")
        let current = app.service()
        let sameGeneration = app.service()
        try current.commit(ProgramPlan(id: "current"), ProgramPlaybackQueue(), 1)
        precondition(app.activeProgram?.id == "current", "fresh preparation still commits")
        precondition(!sameGeneration.isCurrent(), "successful preparation must invalidate earlier service captures")
        do {
            try sameGeneration.commit(ProgramPlan(id: "superseded"), ProgramPlaybackQueue(), 0)
            fatalError("earlier preparation overwrote a newer successful commit")
        } catch DJAgentMusicLibraryError.interrupted {}
        print("PASS: production preparation commit preserves busy playback, selects exact slot, and does not play")
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-music-app-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("Test.swift")
try source.write(to: file, atomically: true, encoding: .utf8)
func run(_ path: String, _ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let output = dir.appendingPathComponent("test").path
let status = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", file.path, "-o", output])
guard status == 0 else { exit(status) }
exit(try run(output, []))
