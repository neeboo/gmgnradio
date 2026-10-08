import Foundation
import Observation

enum SyncedMusicLibraryError: Error { case unavailable, pageTicketRequired }

@MainActor
@Observable
final class SyncedMusicLibraryStore {
    static let shared = SyncedMusicLibraryStore(storage: .shared)
    private(set) var playlists: [MusicPlaylistSnapshot] = []
    private(set) var isSyncing = false
    private(set) var loadingPlaylistIDs = Set<String>()
    private(set) var storageError: String?
    private(set) var isLoaded = false
    private let storage: MusicStorageClient?
    private var revision = 0
    private var mutation: Task<Void, Error>?

    /// Nil storage is explicitly unavailable and never touches the user's daemon.
    init(storage: MusicStorageClient? = nil) {
        self.storage = storage
        isLoaded = false
    }

    func reload() async throws {
        do { try await flush() } catch { mutation = nil }
        guard let storage else { throw SyncedMusicLibraryError.unavailable }
        do {
            let value = try await storage.library()
            playlists = value.playlists; revision = value.revision; isLoaded = true; storageError = nil
        } catch { storageError = "歌单读取失败：\(error.localizedDescription)"; throw error }
    }
    func flush() async throws { try await mutation?.value }
    private func commit(_ edit: MusicStorageClient.LibraryEdit, requestID: String) async throws {
        guard let storage else { throw SyncedMusicLibraryError.unavailable }
        _ = try await storage.edit(edit,requestID:requestID)
        // Receipt replay can carry an older snapshot. Publish only a current verified readback.
        let latest = try await storage.library()
        guard latest.revision >= revision else { throw PropTaskDaemonError.invalidFrame }
        playlists = latest.playlists; revision = latest.revision; isLoaded = true; storageError = nil
    }
    private func enqueue(_ edit: MusicStorageClient.LibraryEdit) {
        let previous = mutation
        let requestID = UUID().uuidString
        mutation = Task {
            do { try await previous?.value } catch { }
            do { try await commit(edit,requestID:requestID) }
            catch { storageError = "歌单保存失败：\(error.localizedDescription)"; throw error }
        }
    }
    func mergeAndVerifyInBackground(playlists incoming: [MusicPlaylistSnapshot]) async -> Bool {
        enqueue(.merge(incoming,batchID:UUID().uuidString))
        do { try await flush(); return true } catch { return false }
    }
    func merge(playlists incoming: [MusicPlaylistSnapshot]) {
        enqueue(.merge(incoming,batchID:UUID().uuidString))
    }
    @discardableResult
    func mergeAndVerify(playlists incoming: [MusicPlaylistSnapshot]) -> Bool {
        merge(playlists: incoming)
        return false
    }
    func setSyncing(_ syncing: Bool) { isSyncing = syncing }
    func remove(providerID: MusicProviderID) { enqueue(.remove(providerID)) }
    func playlist(id: String) -> MusicPlaylistSnapshot? { playlists.first { $0.id == id } }
    func beginLoadingPage(playlistID: String) -> Bool { loadingPlaylistIDs.insert(playlistID).inserted }
    func finishLoadingPage(playlistID: String) { loadingPlaylistIDs.remove(playlistID) }
    func beginPage(playlistID: String, offset: Int, limit: Int, strict: Bool = false, cacheMode: String = "deduplicate") async throws -> MusicStorageClient.PageTicket {
        try await flush()
        guard let storage else { throw SyncedMusicLibraryError.unavailable }
        return try await storage.beginPage(playlistID:playlistID,offset:offset,limit:limit,strict:strict,cacheMode:cacheMode)
    }
    func endPage(_ ticket: MusicStorageClient.PageTicket) async {
        guard let storage else { return }
        // Provider cancellation must not cancel the independent batch-release RPC.
        await Task { @MainActor in try? await storage.endPage(ticket) }.value
    }
    func append(_ page: MusicPlaylistPage, ticket: MusicStorageClient.PageTicket) async throws {
        enqueue(.append(page,ticket))
        try await flush()
    }
    /// Old callers must supply the batch admitted before their provider fetch.
    func append(_ page: MusicPlaylistPage) {
        let previous = mutation
        mutation = Task {
            _ = try? await previous?.value
            storageError = "歌单分页未保存：缺少读取批次。"
            throw SyncedMusicLibraryError.pageTicketRequired
        }
    }
}

@MainActor
enum SyncedPlaylistProgramBuilder {
    static func makePlan(from playlist: MusicPlaylistSnapshot, client: RustMusicProgramClient? = nil) async throws -> ProgramPlan {
        try await (client ?? RustMusicProgramClient()).playlistPlan(playlistID: playlist.id)
    }
}
