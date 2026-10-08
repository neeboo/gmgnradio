import Foundation

/// Music data uses the existing Rust task service and its SQLite database.
@MainActor
final class MusicStorageClient {
    struct Programs: Codable { let programs: [SavedDJProgram]; let pendingIDs: [String] }
    struct Library: Codable { let playlists: [MusicPlaylistSnapshot]; let revision: Int }
    struct PageTicket: Codable, Sendable {
        let batchID: String
        let providerID: MusicProviderID
        let playlistID: String
        let offset: Int
        let limit: Int
    }
    enum LibraryEdit {
        case merge([MusicPlaylistSnapshot], batchID: String)
        case remove(MusicProviderID)
        case append(MusicPlaylistPage, PageTicket)
    }
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
        throw PropTaskDaemonError.invalidFrame
    }
    func edit(_ edit: LibraryEdit, requestID: String) async throws -> Library {
        try await importLegacy()
        var value: [String:PropTaskJSON]
        switch edit {
        case .merge(let incoming, let batchID):
            value = ["kind":.string("merge"),"batchID":.string(batchID),"playlists":try payload(incoming)]
        case .remove(let provider):
            value = ["kind":.string("remove"),"providerID":.string(provider.rawValue)]
        case .append(let page, let ticket):
            value = ["kind":.string("append"),"batchID":.string(ticket.batchID),"providerID":.string(ticket.providerID.rawValue),
                "playlistID":.string(page.playlistID),"offset":.number(Double(page.offset)),
                "totalTrackCount":.number(Double(page.totalTrackCount)),"tracks":try payload(page.tracks)]
        }
        return try result(await call("music_library_edit",["requestID":.string(requestID),"edit":.object(value)]),as:Library.self)
    }
    func beginPage(playlistID: String, offset: Int, limit: Int, strict: Bool = false, cacheMode: String = "deduplicate") async throws -> PageTicket {
        try await importLegacy()
        return try result(await call("music_library_page_begin",["requestID":.string(UUID().uuidString),
            "playlistID":.string(playlistID),"offset":.number(Double(offset)),"limit":.number(Double(limit)),"strict":.bool(strict),"cacheMode":.string(cacheMode)]),as:PageTicket.self)
    }
    func endPage(_ ticket: PageTicket) async throws {
        _ = try await call("music_library_page_end",["batchID":.string(ticket.batchID)])
    }
}
