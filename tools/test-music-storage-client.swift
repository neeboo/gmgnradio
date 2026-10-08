import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ file: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8) }
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
let planner = try read("DJCore/ProgramPlanner.swift")
let planTypes = String(planner[..<planner.range(of: "enum ProgramPlannerError:")!.lowerBound])
let harness = #"""
import Foundation
\#(planTypes)
\#(try read("DJCore/AgentShowProposal.swift"))
\#(try String(contentsOf: root.appendingPathComponent("tools/fixtures/MusicStorageRPCFixture.swift"), encoding: .utf8))
@MainActor final class Backend {
    let actual = MusicStorageRPCFixture()
    var imports: [String] = []
    var rejected: Bool {
        get { actual.rejected }
        set { actual.rejected = newValue }
    }
    func call(_ method: String, _ params: [String: PropTaskJSON]) async throws -> [String: PropTaskJSON] {
        let result = try await actual.call(method, params)
        if method == "music_import", case .string(let source) = params["source"] { imports.append(source) }
        return result
    }
}
@main struct Test {
    @MainActor static func main() async throws {
        let backend = Backend()
        let client = MusicStorageClient(includeDefaultLegacy: false, call: backend.call)
        let programClient = RustMusicProgramClient(call: backend.call)
        let store = DJProgramStore(archive: DJProgramArchive(storage: client), client: programClient)
        let seed = SyncedMusicLibraryStore(storage: client)
        seed.merge(playlists: [MusicPlaylistSnapshot(id: "draft", providerID: .local, name: "draft", artworkURL: nil, tracks: [], totalTrackCount: 0)])
        try await seed.flush()
        let plan = try await programClient.playlistPlan(playlistID: "draft")
        seed.remove(providerID: .local); try await seed.flush()
        try await store.publishDraft(plan); try await store.flush()
        let draftReadback = try await client.programs()
        precondition(draftReadback.pendingIDs == ["draft"])
        let reopened = DJProgramStore(archive: DJProgramArchive(storage: client), client: programClient)
        try await reopened.restoreLatest()
        precondition(reopened.pendingPlan?.brief.id == "draft" && reopened.plan == nil)
        try await reopened.publish(plan); try await reopened.flush()
        let publishedReadback = try await client.programs()
        precondition(publishedReadback.pendingIDs.isEmpty)
        let library = SyncedMusicLibraryStore(storage: client)
        let playlist = MusicPlaylistSnapshot(id: "netease:a", providerID: .netease, name: "Fixture", artworkURL: nil, tracks: [], totalTrackCount: 0)
        let merged = await library.mergeAndVerifyInBackground(playlists: [playlist])
        precondition(merged)
        let other = SyncedMusicLibraryStore(storage: client)
        try await other.reload(); precondition(other.playlists == [playlist])
        other.remove(providerID: .netease); try await other.flush()
        try await library.reload(); precondition(library.playlists.isEmpty)
        do { _ = try await client.commit([], revision: -1); preconditionFailure("Stale revision must fail") }
        catch { }
        let beforeCAS = try await programClient.read()
        do { _ = try await backend.call("music_dj_command", ["op": .string("activate_slot"), "index": .number(0), "expectedRevision": .number(Double(beforeCAS.revision - 1))]); preconditionFailure("Actual stale CAS must fail") }
        catch { }
        let afterCAS = try await programClient.read()
        precondition(afterCAS.revision == beforeCAS.revision && afterCAS.plan == beforeCAS.plan)
        let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("music-legacy-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacy = legacyRoot.appendingPathComponent("music-library.json")
        let original = Data(#"{"version":1,"playlists":[]}"#.utf8)
        try original.write(to: legacy)
        let importer = MusicStorageClient(legacyFiles: [legacy], includeDefaultLegacy: false, call: backend.call)
        _ = try await importer.library(); _ = try await importer.library()
        precondition(backend.imports == [legacy.standardizedFileURL.resolvingSymlinksInPath().path])
        let preserved = try Data(contentsOf: legacy)
        precondition(preserved == original)
        backend.rejected = true
        do { try await reopened.publishDraft(plan); try await reopened.flush(); preconditionFailure("Unavailable persistence cannot report success") } catch { }
        if case .failed = reopened.status { } else { preconditionFailure("Save failure must be visible") }
        backend.rejected = false
        try await reopened.refreshRecentPrograms()
        try await library.reload()
        precondition(library.storageError == nil)
        print("PASS: client RPC encoding, confirmed writes, pending restart/no autoplay, shared library, removal, CAS rejection, read-only legacy import, visible failures")
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-music-storage-test-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let file = temp.appendingPathComponent("Tests.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
func run(_ command: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let files = ["Domain/PlaybackContext.swift", "MusicSources/MusicSource.swift", "MusicSources/MusicStorageClient.swift", "MusicSources/SyncedMusicLibraryStore.swift", "DJCore/DJProgramStore.swift", "DJCore/RustMusicProgramClient.swift", "MusicKnowledge/TrackKnowledge.swift", "MusicKnowledge/CandidatePoolBuilder.swift"]
let binary = temp.appendingPathComponent("test").path
let code = try run("/usr/bin/swiftc", ["-parse-as-library"] + files.map { sources.appendingPathComponent($0).path } + [file.path, "-o", binary])
guard code == 0 else { exit(code) }
exit(try run(binary, []))
