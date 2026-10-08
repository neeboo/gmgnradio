import Foundation

/// Reads the user's existing library and prepares one explicitly chosen track.
/// Commits playback only after authority-confirmed program construction.
@MainActor
final class MusicLibraryAgentService {
    private let store: SyncedMusicLibraryStore
    private let programClient: RustMusicProgramClient
    private let fetchPage: @MainActor (MusicProviderID, String, Int, Int) async throws -> MusicPlaylistPage
    private let makeQueue: @MainActor () -> ProgramPlaybackQueue
    private let isCurrent: @MainActor () -> Bool
    private let commit: @MainActor (ProgramPlan, ProgramPlaybackQueue, Int) async throws -> Void
    private var isPreparing = false

    init(
        store: SyncedMusicLibraryStore,
        programClient: RustMusicProgramClient? = nil,
        fetchPage: @escaping @MainActor (MusicProviderID, String, Int, Int) async throws -> MusicPlaylistPage,
        makeQueue: @escaping @MainActor () -> ProgramPlaybackQueue,
        isCurrent: @escaping @MainActor () -> Bool,
        commit: @escaping @MainActor (ProgramPlan, ProgramPlaybackQueue, Int) async throws -> Void
    ) {
        self.store = store
        self.programClient = programClient ?? RustMusicProgramClient()
        self.fetchPage = fetchPage
        self.makeQueue = makeQueue
        self.isCurrent = isCurrent
        self.commit = commit
    }

    func list(query: String?, offset: Int, limit: Int) throws -> DJAgentMusicPlaylistsPage {
        try checkCurrent()
        try validatePage(offset: offset, limit: limit)
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches = store.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let playlists = matches.dropFirst(offset).prefix(limit).map { playlist in
            DJAgentMusicPlaylist(id: playlist.id, provider: playlist.providerID.rawValue, name: playlist.name,
                trackCount: playlist.trackCount, loadedTrackCount: playlist.tracks.count,
                supportsPreparation: Self.supports(playlist.providerID))
        }
        return DJAgentMusicPlaylistsPage(playlists: playlists, offset: offset,
            nextOffset: offset + playlists.count < matches.count ? offset + playlists.count : nil,
            isSyncing: store.isSyncing)
    }

    func read(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        try checkCurrent()
        try validatePage(offset: offset, limit: limit)
        var playlist = try supportedPlaylist(id: playlistID)
        // The shared cache is a contiguous prefix; callers follow nextOffset.
        guard offset <= playlist.tracks.count else { throw DJAgentMusicLibraryError.invalidArguments }
        if playlist.tracks.count < min(offset + limit, playlist.trackCount) {
            guard store.beginLoadingPage(playlistID: playlistID) else { throw DJAgentMusicLibraryError.busy }
            defer { store.finishLoadingPage(playlistID: playlistID) }
            while playlist.tracks.count < min(offset + limit, playlist.trackCount) {
                let cachedCount = playlist.tracks.count
                let requestedCount = min(offset + limit, playlist.trackCount) - cachedCount
                let page: MusicPlaylistPage
                let ticket = try await store.beginPage(playlistID: playlistID, offset: cachedCount,
                    limit: requestedCount, strict: true)
                do {
                    page = try await fetchPage(ticket.providerID, ticket.playlistID, ticket.offset, ticket.limit)
                    try checkCurrent()
                    try await store.append(page, ticket: ticket)
                } catch {
                    await store.endPage(ticket)
                    try checkCurrent()
                    throw DJAgentMusicLibraryError.libraryUnavailable
                }
                playlist = try supportedPlaylist(id: playlistID)
            }
        }
        let tracks = playlist.tracks.dropFirst(offset).prefix(limit).map { track in
            DJAgentMusicTrack(id: track.id, provider: track.providerID.rawValue, title: track.title,
                artist: track.artist, album: track.album, duration: track.duration, isPlayable: track.isPlayable)
        }
        return DJAgentMusicPlaylistPage(playlistID: playlist.id, tracks: tracks, offset: offset,
            nextOffset: offset + tracks.count < playlist.trackCount ? offset + tracks.count : nil,
            totalTrackCount: playlist.trackCount)
    }

    func prepare(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        try checkCurrent()
        guard !isPreparing else { throw DJAgentMusicLibraryError.busy }
        let playlist = try supportedPlaylist(id: playlistID)
        guard let index = playlist.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw DJAgentMusicLibraryError.trackNotFound
        }
        guard Self.supports(playlist.tracks[index].providerID) else { throw DJAgentMusicLibraryError.sourceUnsupported }
        isPreparing = true
        defer { isPreparing = false }
        let plan = try await SyncedPlaylistProgramBuilder.makePlan(from: playlist, client: programClient)
        let queue = makeQueue()
        do {
            try await queue.select(plan, at: index)
        } catch {
            try checkCurrent()
            throw DJAgentMusicLibraryError.preparationFailed
        }
        try checkCurrent()
        guard store.playlist(id: playlistID) == playlist else { throw DJAgentMusicLibraryError.interrupted }
        guard let prepared = queue.current, prepared.slot.track.id == trackID else {
            throw DJAgentMusicLibraryError.preparationFailed
        }
        guard case .localFile = prepared.target else { throw DJAgentMusicLibraryError.sourceUnsupported }
        do {
            try await commit(plan, queue, index)
        } catch let error as DJAgentMusicLibraryError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DJAgentMusicLibraryError.preparationFailed
        }
        return DJAgentMusicPreparation(playlistID: playlistID, trackID: trackID)
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw DJAgentMusicLibraryError.interrupted }
    }

    private func validatePage(offset: Int, limit: Int) throws {
        guard offset >= 0, (1...50).contains(limit), offset <= Int.max - limit else {
            throw DJAgentMusicLibraryError.invalidArguments
        }
    }

    private func supportedPlaylist(id: String) throws -> MusicPlaylistSnapshot {
        guard let playlist = store.playlist(id: id) else { throw DJAgentMusicLibraryError.playlistNotFound }
        guard Self.supports(playlist.providerID) else { throw DJAgentMusicLibraryError.sourceUnsupported }
        return playlist
    }

    private static func supports(_ provider: MusicProviderID) -> Bool {
        provider == .local || provider == .netease || provider == .qqMusic
    }
}
