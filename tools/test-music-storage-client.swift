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
\#(declaration("struct AgentVisualDirection:", in: try read("DJCore/AgentShowProposal.swift")))
\#(declaration("enum PropTaskJSON:", in: try read("Presence/PropTaskDaemonClient.swift")))
enum PropTaskDaemonError: Error { case invalidFrame }
@MainActor final class PropTaskDaemonClient {
    init(root: URL? = nil, helperURL: URL? = nil) { }
    func call(method: String, params: [String: PropTaskJSON]) async throws -> [String: PropTaskJSON] { fatalError("Tests must not access a live daemon") }
}
enum FixtureError: Error { case conflict, unavailable }
@MainActor final class Backend {
    var programs: [SavedDJProgram] = []
    var pending: [String] = []
    var playlists: [MusicPlaylistSnapshot] = []
    var revision = 0
    var imports: [String] = []
    var rejected = false
    func encode<T: Encodable>(_ value: T) throws -> PropTaskJSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(PropTaskJSON.self, from: encoder.encode(value))
    }
    func decode<T: Decodable>(_ value: PropTaskJSON, _ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(value))
    }
    func call(_ method: String, _ params: [String: PropTaskJSON]) async throws -> [String: PropTaskJSON] {
        if rejected { throw FixtureError.unavailable }
        switch method {
        case "music_program_save":
            let saved = try decode(params["program"]!, SavedDJProgram.self)
            programs.removeAll { $0.plan.brief.id == saved.plan.brief.id }; programs.insert(saved, at: 0)
            pending.removeAll { $0 == saved.plan.brief.id }
            if params["pending"] == .bool(true) { pending.append(saved.plan.brief.id) }
            return ["saved": .bool(true)]
        case "music_program_list": return ["programs": try encode(programs), "pendingIDs": try encode(pending)]
        case "music_library_read": return ["playlists": try encode(playlists), "revision": .number(Double(revision))]
        case "music_library_commit":
            guard params["baseRevision"] == .number(Double(revision)) else { throw FixtureError.conflict }
            playlists = try decode(params["playlists"]!, [MusicPlaylistSnapshot].self); revision += 1
            return ["playlists": try encode(playlists), "revision": .number(Double(revision))]
        case "music_import":
            if case .string(let source) = params["source"]! { imports.append(source) }
            return ["imported": .bool(true)]
        default: fatalError("Unexpected method")
        }
    }
}
@main struct Test {
    @MainActor static func main() async throws {
        let backend = Backend()
        let client = MusicStorageClient(includeDefaultLegacy: false, call: backend.call)
        let store = DJProgramStore(archive: DJProgramArchive(storage: client))
        let brief = ProgramBrief(id: "draft", targetDuration: 100, moodTags: [], energyArc: [], conversationMode: .ambient, immediateUserInstruction: nil)
        let plan = ProgramPlan(brief: brief, slots: [], revision: 1, generatedAt: Date(), replanAfterTrackCount: 5, title: "draft", direction: nil)
        store.publishDraft(plan); try await store.flush()
        precondition(backend.pending == ["draft"])
        let reopened = DJProgramStore(archive: DJProgramArchive(storage: client))
        await reopened.restoreLatest()
        precondition(reopened.pendingPlan?.brief.id == "draft" && reopened.plan == nil)
        reopened.publish(plan); try await reopened.flush()
        precondition(backend.pending.isEmpty)
        let library = SyncedMusicLibraryStore(storage: client)
        let playlist = MusicPlaylistSnapshot(id: "netease:a", providerID: .netease, name: "Fixture", artworkURL: nil, tracks: [], totalTrackCount: 0)
        let merged = await library.mergeAndVerifyInBackground(playlists: [playlist])
        precondition(merged)
        let other = SyncedMusicLibraryStore(storage: client)
        try await other.reload(); precondition(other.playlists == [playlist])
        other.remove(providerID: .netease); try await other.flush()
        try await library.reload(); precondition(library.playlists.isEmpty)
        do { _ = try await client.commit([], revision: -1); preconditionFailure("Stale revision must fail") }
        catch FixtureError.conflict { }
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
        reopened.publishDraft(plan)
        do { try await reopened.flush(); preconditionFailure("Unavailable persistence cannot report success") } catch { }
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
let files = ["Domain/PlaybackContext.swift", "MusicSources/MusicSource.swift", "MusicSources/MusicStorageClient.swift", "MusicSources/SyncedMusicLibraryStore.swift", "DJCore/DJProgramStore.swift"]
let binary = temp.appendingPathComponent("test").path
let code = try run("/usr/bin/swiftc", ["-parse-as-library"] + files.map { sources.appendingPathComponent($0).path } + [file.path, "-o", binary])
guard code == 0 else { exit(code) }
exit(try run(binary, []))
