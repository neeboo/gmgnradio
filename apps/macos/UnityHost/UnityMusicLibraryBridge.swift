import Foundation
import WebKit

@MainActor
final class UnityMusicLibraryBridge {
    private struct Cache: Decodable, Sendable { let version: Int; let playlists: [MusicPlaylistSnapshot] }
    private let source: URL
    private let root: URL
    private let runtime: MusicRuntime
    private let accounts: MusicAccountCommandService
    private let sessions: UnityMusicSessions
    private let webLogin = MusicProviderWebLoginController(dataStore: .nonPersistent())
    private let appleMusic = AppleMusicSource()
    private let libraryStore: SyncedMusicLibraryStore
    private var accountTask: Task<Void, Never>?
    private var accountStates: [MusicProviderID: MusicAccountAuthorizationState] = [:]
    private var syncingProvider: MusicProviderID?
    private var accountNotice: String?
    private var accountError = false
    private var disconnectedProviders = Set<MusicProviderID>()
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
        let sessions = UnityMusicSessions(directory: source.appendingPathComponent("secrets/music-sessions"), root: root)
        self.sessions = sessions
        accounts = MusicAccountCommandService(sessions: sessions, neteaseClient: NeteaseMusicProviderClient(), qqMusicClient: QQMusicProviderClient())
        libraryStore = SyncedMusicLibraryStore(cacheURL: root.appendingPathComponent("music-library.json"))
        runtime = MusicRuntime(netease: NeteaseMusicSource(sessions: sessions, client: NeteaseMusicProviderClient()),
            qqMusic: QQMusicSource(sessions: sessions, client: QQMusicProviderClient()),
            appleMusic: AppleMusicSource(), cache: StreamingMusicCache(rootURL: root.appendingPathComponent("music-cache")))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-music-disconnected").path) { disconnectedProviders.insert(.appleMusic) }
    }
    var settingsSnapshot: [String: Any] {
        ["providers": [MusicProviderID.netease, .qqMusic, .appleMusic].map { provider in
            ["id": provider.rawValue, "name": provider == .netease ? "网易云音乐" : provider == .qqMusic ? "QQ 音乐" : "Apple Music",
             "connected": accountStates[provider] == .connected, "syncing": syncingProvider == provider,
             "status": (accountStates[provider] ?? .disconnected).rawValue] as [String: Any]
        }, "working": accountTask != nil || task != nil, "notice": accountNotice as Any? ?? NSNull(), "hasError": accountError]
    }
    func settingsCommand(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String, ["music.load", "music.connect", "music.disconnect", "music.sync"].contains(op), accountTask == nil, op == "music.load" || task == nil else { return false }
        let provider = MusicProviderID(rawValue: value["id"] as? String ?? "")
        guard op == "music.load" || [MusicProviderID.netease, .qqMusic, .appleMusic].contains(provider) else { return false }
        accountTask = Task { [weak self] in
            guard let self else { return }
            defer { accountTask = nil; syncingProvider = nil }
            if op == "music.load" {
                for provider in [MusicProviderID.netease, .qqMusic] {
                    accountStates[provider] = await accounts.status(providerID: provider)
                    if (try? await sessions.isDisabled(provider)) == true { disconnectedProviders.insert(provider) }
                }
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-music-disconnected").path) { disconnectedProviders.insert(.appleMusic) }
                accountStates[.appleMusic] = disconnectedProviders.contains(.appleMusic) ? .disconnected : appleState(await appleMusic.access())
                return
            }
            do {
                accountError = false
                if op == "music.disconnect" {
                    if provider != .appleMusic { try await accounts.disconnect(providerID: provider); await webLogin.clearSession(providerID: provider) }
                    disconnectedProviders.insert(provider); accountStates[provider] = .disconnected
                    if provider == .appleMusic { try Data().write(to: root.appendingPathComponent("apple-music-disconnected"), options: .atomic) }
                    try await seedLibrary()
                    libraryStore.remove(providerID: provider)
                    let readback = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: root.appendingPathComponent("music-library.json")))
                    guard readback.version == 1, readback.playlists == libraryStore.playlists else { throw MusicProviderClientError.playbackUnavailable }
                    playlists = libraryStore.playlists
                    publishLibrary()
                    accountNotice = "已断开 Unity 会话中的音乐账号。"; return
                }
                if op == "music.connect" {
                    if provider == .appleMusic {
                        let state = appleState(await appleMusic.requestAuthorization())
                        guard state == .connected else { throw MusicProviderClientError.playbackUnavailable }
                        accountStates[provider] = state
                    } else {
                        accountStates[provider] = .authorizing
                        accountNotice = "请在官方页面完成登录。"
                        await webLogin.clearSession(providerID: provider)
                        let cookie = try await webLogin.login(providerID: provider)
                        try await accounts.connect(providerID: provider, cookie: cookie)
                        accountStates[provider] = .connected
                    }
                    disconnectedProviders.remove(provider)
                    if provider == .appleMusic, FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-music-disconnected").path) {
                        try FileManager.default.removeItem(at: root.appendingPathComponent("apple-music-disconnected"))
                    }
                }
                guard accountStates[provider] == .connected else { throw MusicProviderClientError.playbackUnavailable }
                syncingProvider = provider; accountNotice = "正在同步歌单…"
                let library = try await runtime.fetchLibrary(providerID: provider)
                guard !closed, !Task.isCancelled else { return }
                try await seedLibrary()
                guard await libraryStore.mergeAndVerifyInBackground(playlists: library.playlists) else { throw MusicProviderClientError.playbackUnavailable }
                playlists = libraryStore.playlists
                publishLibrary()
                accountNotice = "已同步 \(library.playlists.count) 个歌单。"
            } catch MusicProviderWebLoginError.cancelled {
                guard !Task.isCancelled else { return }
                accountStates[provider] = await accounts.status(providerID: provider)
                accountError = false; accountNotice = "已取消登录。"
            } catch {
                guard !Task.isCancelled else { return }
                if op == "music.connect", provider != .appleMusic { accountStates[provider] = await accounts.status(providerID: provider) }
                accountError = true; accountNotice = "音乐账号操作未完成，请检查登录状态与网络后重试。"
            }
        }
        return true
    }
    private func appleState(_ access: MusicSourceAccess) -> MusicAccountAuthorizationState {
        switch access { case .local: .connected; case let .accountRequired(state): state }
    }
    private func seedLibrary() async throws {
        guard libraryStore.playlists.isEmpty else { return }
        let file = source.appendingPathComponent("music-library.json")
        let inherited = await Task.detached(priority: .utility) { () -> [MusicPlaylistSnapshot] in
            guard let bytes = try? Data(contentsOf: file), bytes.count <= 32 * 1024 * 1024,
                  let cache = try? JSONDecoder().decode(Cache.self, from: bytes), cache.version == 1 else { return [] }
            return cache.playlists
        }.value
        guard await libraryStore.mergeAndVerifyInBackground(playlists: inherited.filter { !disconnectedProviders.contains($0.providerID) }) else { throw MusicProviderClientError.playbackUnavailable }
    }
    private func publishLibrary() {
        publish(["status": "completed", "operation": "library", "playlists": playlists.map {
            ["id": $0.id, "name": $0.name, "provider": $0.providerID.rawValue, "count": $0.trackCount,
             "artworkURL": $0.artworkURL?.absoluteString ?? ""]
        }])
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
        guard task == nil, accountTask == nil, !closed else { return false }
        let isolated = root.appendingPathComponent("music-library.json")
        let file = FileManager.default.fileExists(atPath: isolated.path) ? isolated : source.appendingPathComponent("music-library.json")
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
            for provider in [MusicProviderID.netease, .qqMusic] {
                if (try? await self.sessions.isDisabled(provider)) == true { self.disconnectedProviders.insert(provider) }
            }
            self.playlists = cache.playlists.filter { !self.disconnectedProviders.contains($0.providerID) }
            self.publish(["status": "completed", "operation": "library", "playlists": self.playlists.map {
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
    func close() { closed = true; task?.cancel(); selection?.cancel(); accountTask?.cancel(); webLogin.cancel() }
}
