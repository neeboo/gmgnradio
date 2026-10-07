import Foundation

/// Music data uses the existing Rust task service and its SQLite database.
@MainActor
final class MusicStorageClient {
    struct Programs: Codable { let programs: [SavedDJProgram]; let pendingIDs: [String] }
    struct Library: Codable { let playlists: [MusicPlaylistSnapshot]; let revision: Int }
    private struct LegacyPrograms: Decodable { let programs: [SavedDJProgram] }
    private struct LegacyLibrary: Decodable { let playlists: [MusicPlaylistSnapshot] }
    private let call: @MainActor (String, [String: PropTaskJSON]) async throws -> [String: PropTaskJSON]
    private let legacyFiles: [URL]
    private var imported = false
    static let shared = MusicStorageClient()
    nonisolated static var productionSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    nonisolated static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.gmgn.radio", isDirectory: true)
    }
    init(supportRoot: URL = MusicStorageClient.productionSupportRoot, helperURL: URL? = nil,
         legacyFiles: [URL] = [], includeDefaultLegacy: Bool? = nil,
         call: (@MainActor (String, [String: PropTaskJSON]) async throws -> [String: PropTaskJSON])? = nil) {
        let daemon = PropTaskDaemonClient(root: supportRoot.appendingPathComponent("gmgn radio/TaskService", isDirectory: true), helperURL: helperURL)
        self.call = call ?? { try await daemon.call(method: $0, params: $1) }
        let useDefaults = includeDefaultLegacy ?? (call == nil && supportRoot.standardizedFileURL.resolvingSymlinksInPath() == Self.productionSupportRoot.standardizedFileURL.resolvingSymlinksInPath())
        var seen = Set<String>()
        self.legacyFiles = ((useDefaults ? [Self.legacyDirectory.appendingPathComponent("programs.json"),
                            Self.legacyDirectory.appendingPathComponent("music-library.json")] : []) + legacyFiles
            ).map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }
    private func payload<T: Encodable>(_ value: T) throws -> PropTaskJSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(PropTaskJSON.self, from: encoder.encode(value))
    }
    private func result<T: Decodable>(_ value: [String: PropTaskJSON], as: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: JSONEncoder().encode(value))
    }
    func importLegacy() async throws {
        guard !imported else { return }
        for file in legacyFiles {
            let values = try await Task.detached(priority: .utility) { () -> ([SavedDJProgram], [MusicPlaylistSnapshot])? in
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                let bytes = try Data(contentsOf: file)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if file.lastPathComponent.contains("program") {
                    return (try decoder.decode(LegacyPrograms.self, from: bytes).programs, [])
                }
                return ([], try decoder.decode(LegacyLibrary.self, from: bytes).playlists)
            }.value
            guard let values else { continue }
            _ = try await call("music_import", ["source": .string(file.path),
                "programs": try payload(values.0), "playlists": try payload(values.1)])
        }
        imported = true
    }
    func programs() async throws -> Programs {
        try await importLegacy()
        return try result(await call("music_program_list", [:]), as: Programs.self)
    }
    func save(_ program: SavedDJProgram, pending: Bool) async throws {
        try await importLegacy()
        let reply = try await call("music_program_save", ["program": try payload(program), "pending": .bool(pending)])
        guard reply["saved"] == .bool(true) else { throw PropTaskDaemonError.invalidFrame }
    }
    func library() async throws -> Library {
        try await importLegacy()
        return try result(await call("music_library_read", [:]), as: Library.self)
    }
    func commit(_ playlists: [MusicPlaylistSnapshot], revision: Int) async throws -> Library {
        try await importLegacy()
        return try result(await call("music_library_commit", ["playlists": try payload(playlists),
            "baseRevision": .number(Double(revision))]), as: Library.self)
    }
}
