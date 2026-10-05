import Foundation

/// Existing account sessions and library are read-only. Downloads belong to the
/// isolated Unity root; this adapter does not migrate or mutate account storage.
private actor UnityReadOnlyMusicSessions: MusicProviderSessionStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func session(for providerID: MusicProviderID) throws -> MusicProviderSession? {
        let name = providerID.rawValue.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MusicProviderSession.self, from: Data(contentsOf: url))
    }
    func save(_ session: MusicProviderSession, for providerID: MusicProviderID) throws { throw MusicProviderClientError.playbackUnavailable }
    func removeSession(for providerID: MusicProviderID) throws { throw MusicProviderClientError.playbackUnavailable }
}

@MainActor
final class UnityMusicLibraryBridge {
    private struct Cache: Decodable, Sendable { let version: Int; let playlists: [MusicPlaylistSnapshot] }
    private let source: URL
    private let root: URL
    private let runtime: MusicRuntime
    private var playlists: [MusicPlaylistSnapshot] = []
    private var generation: UInt64 = 0
    private var emitted: UInt64?
    private var response: [String: Any] = ["status": "idle"]
    private var task: Task<Void, Never>?
    private var selection: Task<Void, Never>?
    private var closed = false
    private var playback = UnityMusicSelectionState<MusicCandidate>()
    var queue: [MusicCandidate] { playback.queue }
    var index: Int { playback.index }
    var onPrepared: ((URL, MusicLyrics?, MusicCandidate) -> Bool)?

    init(root: URL) {
        self.root = root
        source = ProcessInfo.processInfo.environment["GMGN_UNITY_MUSIC_LIBRARY_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ai.gmgn.radio")
        let sessions = UnityReadOnlyMusicSessions(directory: source.appendingPathComponent("secrets/music-sessions"))
        runtime = MusicRuntime(netease: NeteaseMusicSource(sessions: sessions, client: NeteaseMusicProviderClient()),
            qqMusic: QQMusicSource(sessions: sessions, client: QQMusicProviderClient()),
            appleMusic: AppleMusicSource(), cache: StreamingMusicCache(rootURL: root.appendingPathComponent("music-cache")))
    }
    private func publish(_ value: [String: Any]) { response = value; generation &+= 1 }
    func snapshot() -> [String: Any] {
        var value = emitted == generation ? [:] : response
        emitted = generation
        value["generation"] = generation; value["pending"] = task != nil || selection != nil
        value["currentTrackID"] = queue.indices.contains(index) ? queue[index].id : ""
        return value
    }
    func refresh() -> Bool {
        guard task == nil, !closed else { return false }
        let file = source.appendingPathComponent("music-library.json")
        task = Task { [weak self] in
            let cache = await Task.detached(priority: .utility) { () -> Cache? in
                guard let data = try? Data(contentsOf: file), data.count <= 32 * 1024 * 1024 else { return nil }
                return try? JSONDecoder().decode(Cache.self, from: data)
            }.value
            guard let self, !self.closed else { return }
            self.task = nil
            guard let cache, cache.version == 1 else {
                self.publish(["status": "failed", "operation": "library", "code": "library_unavailable", "message": "还没有可读取的歌单，请先在音乐账户中同步歌单。"]); return
            }
            self.playlists = cache.playlists
            self.publish(["status": "completed", "operation": "library", "playlists": cache.playlists.map {
                ["id": $0.id, "name": $0.name, "provider": $0.providerID.rawValue, "count": $0.trackCount,
                 "artworkURL": $0.artworkURL?.absoluteString ?? ""]
            }])
        }
        return true
    }
    func readPlaylist(_ id: String) -> Bool {
        guard task == nil, !closed, let playlist = playlists.first(where: { $0.id == id }) else { return false }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var tracks = playlist.tracks
                // Cached rows may contain only metadata. Hydrate every page once,
                // asynchronously, so the queue really includes the entire playlist.
                while tracks.count < playlist.trackCount {
                    try Task.checkCancellation()
                    let page = try await self.runtime.fetchPlaylistPage(providerID: playlist.providerID,
                        playlistID: playlist.id, offset: tracks.count, limit: 200)
                    guard UnityMusicPageBoundary.isValid(offset: page.offset, expectedOffset: tracks.count,
                        returnedCount: page.tracks.count, total: page.totalTrackCount) else {
                        throw MusicProviderClientError.playbackUnavailable
                    }
                    guard !page.tracks.isEmpty else { break }
                    tracks.append(contentsOf: page.tracks)
                    if !page.hasMore { break }
                }
                guard !self.closed, !Task.isCancelled else { return }
                let full = MusicPlaylistSnapshot(id: playlist.id, providerID: playlist.providerID, name: playlist.name,
                    artworkURL: playlist.artworkURL, tracks: tracks, totalTrackCount: playlist.trackCount)
                if let i = self.playlists.firstIndex(where: { $0.id == id }) { self.playlists[i] = full }
                self.publish(["status": "completed", "operation": "playlist", "playlistID": id,
                    "name": playlist.name, "provider": playlist.providerID.rawValue,
                    "artworkURL": playlist.artworkURL?.absoluteString ?? "", "total": playlist.trackCount, "loaded": tracks.count,
                    "tracks": tracks.enumerated().map { ["index": $0.offset, "id": $0.element.id, "title": $0.element.title,
                        "artist": $0.element.artist, "duration": $0.element.duration, "playable": $0.element.isPlayable] }])
            } catch { self.publish(["status": "failed", "operation": "playlist", "code": "playlist_read_failed",
                "message": "歌单暂时读取失败，请检查音乐账户登录状态后重试。"] ) }
            self.task = nil
        }
        return true
    }
    func play(playlistID: String, index: Int) -> Bool {
        guard let playlist = playlists.first(where: { $0.id == playlistID }), playlist.tracks.indices.contains(index) else { return false }
        return prepare(queue: playlist.tracks, index: index)
    }
    func select(_ index: Int) -> Bool {
        return prepare(queue: queue, index: index)
    }
    private func prepare(queue: [MusicCandidate], index: Int) -> Bool {
        guard !closed, let ticket = playback.begin(queue: queue, index: index) else { return false }
        selection?.cancel()
        let candidate = queue[index]
        selection = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = try await self.runtime.preparePlayback(for: candidate)
                let lyrics = try? await self.runtime.lyrics(for: candidate)
                try Task.checkCancellation()
                guard !self.closed, self.playback.isCurrent(ticket) else { return }
                guard case let .pcmFile(url) = asset else {
                    throw MusicProviderClientError.playbackUnavailable
                }
                guard let onPrepared = self.onPrepared,
                      onPrepared(url, lyrics, candidate), self.playback.commit(ticket, accepted: true) else {
                    throw MusicProviderClientError.playbackUnavailable
                }
                self.publish(["status": "completed", "operation": "play", "title": candidate.title])
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.playback.isCurrent(ticket) else { return }
                self.publish(["status": "failed", "operation": "play", "code": "track_playback_failed",
                    "message": "这首歌暂时不能播放，请检查账户权限或选择另一首。"] )
            }
            self.selection = nil
        }
        return true
    }
    func clearQueue() { selection?.cancel(); selection = nil; playback.clear() }
    func close() { closed = true; task?.cancel(); selection?.cancel() }
}
