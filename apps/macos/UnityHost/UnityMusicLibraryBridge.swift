import Foundation
import WebKit

@MainActor
final class UnityMusicLibraryBridge {
    private struct Cache: Decodable, Sendable { let version: Int; let playlists: [MusicPlaylistSnapshot] }
    private let source: URL
    private let root: URL
    private let runtime: MusicRuntime
    private let accounts: MusicAccountCommandService
    private let accountAuthority: RustMusicAccountClient
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
    private let playback: RustMusicSelectionProjection<MusicCandidate>
    private var preparationGeneration: UInt64 = 0
    private var programQueue: ProgramPlaybackQueue?
    private let programCall: RustMusicProgramClient.Call
    private var activeProgram: ProgramPlan?
    var queue: [MusicCandidate] { playback.queue }
    var index: Int { playback.index }
    private(set) var queuePlaylistID: String?
    var onPrepared: ((URL, MusicLyrics?, MusicCandidate) -> Bool)?
    /// Agent preparation selects a real PCM asset while remaining paused.
    /// The normal UI onPrepared auto-play callback must not be reused here.
    var onToolPrepared: ((URL, MusicLyrics?, MusicCandidate) -> Bool)?
    /// Host loads and confirms playback on its sole real player.
    var onProgramPrepared: (@MainActor (URL, MusicLyrics?, MusicCandidate) async throws -> Void)?
    var onProgramSlotCommitted: (@MainActor (Int) async throws -> Void)?
    var onProgramPlaybackReleased: (@MainActor () -> Void)?

    @discardableResult
    func showProgramHistory(_ snapshot: [String: Any]) -> Bool {
        guard !closed, snapshot["operation"] as? String == "program-history" else { return false }
        publish(snapshot)
        return true
    }
    func reportProgramSelectionFailure(_ error: Error) {
        guard !closed else { return }
        publish(["status": "failed", "operation": "program", "message": error.localizedDescription])
    }

    func makeProgramPlan(instruction: String, preferences: DJAgentPreferences) async throws -> ProgramPlan {
        guard !closed else { throw CancellationError() }
        return try await UnityDJProgramBridge.livePlanner(runtime: runtime, preferences: preferences)(instruction)
    }

    func activateProgram(_ plan: ProgramPlan, startingAt selectedIndex: Int? = nil) async throws -> Int {
        preparationGeneration &+= 1
        let lease = preparationGeneration
        selection?.cancel(); selection = nil
        guard !closed, let accept = onProgramPrepared else { throw DJAgentMusicLibraryError.unsupported }
        // Preflight a replacement without discarding the currently playing queue.
        let proposedQueue = ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: MusicRuntimePlaybackPreparer(runtime: runtime)), call: programCall)
        if let selectedIndex {
            guard plan.slots.indices.contains(selectedIndex) else { throw DJAgentMusicLibraryError.trackNotFound }
            try await proposedQueue.select(plan, at: selectedIndex)
        } else {
            try await proposedQueue.load(plan)
        }
        guard let prepared = proposedQueue.current,
              let index = selectedIndex ?? plan.slots.firstIndex(where: { $0.track.id == prepared.slot.track.id }),
              case let .localFile(url) = prepared.target else { throw DJAgentMusicLibraryError.sourceUnsupported }
        let lyrics = try? await runtime.lyrics(for: prepared.slot.track)
        try Task.checkCancellation()
        guard !closed, lease == preparationGeneration else { throw CancellationError() }
        let tracks = plan.slots.map { $0.track }
        guard let ticket = playback.begin(queue: tracks, index: index) else { throw DJAgentMusicLibraryError.trackNotFound }
        try await accept(url, lyrics, prepared.slot.track)
        try Task.checkCancellation()
        guard !closed, lease == preparationGeneration, playback.commit(ticket, accepted: true) else { throw CancellationError() }
        activeProgram = plan; programQueue = proposedQueue; queuePlaylistID = nil
        publish(["status": "completed", "operation": "program", "title": plan.title ?? "节目"])
        return index
    }

    /// Startup-only preparation. Ordinary playlist intent always wins, including
    /// an intent still awaiting its provider asset. No autoplay hook is invoked.
    func restoreProgram(_ plan: ProgramPlan, startingAt savedIndex: Int) async throws -> Int {
        guard !closed, preparationGeneration == 0, selection == nil, queue.isEmpty,
              let accept = onToolPrepared else { throw CancellationError() }
        preparationGeneration &+= 1
        let lease = preparationGeneration
        let restoredQueue = ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: MusicRuntimePlaybackPreparer(runtime: runtime)), call: programCall)
        try await restoredQueue.load(plan, startingAt: savedIndex)
        guard let prepared = restoredQueue.current,
              let index = plan.slots.firstIndex(where: { $0.track.id == prepared.slot.track.id }),
              case let .localFile(url) = prepared.target else { throw DJAgentMusicLibraryError.sourceUnsupported }
        let lyrics = try? await runtime.lyrics(for: prepared.slot.track)
        try Task.checkCancellation()
        guard !closed, preparationGeneration == lease, queue.isEmpty,
              let ticket = playback.begin(queue: plan.slots.map { $0.track }, index: index) else { throw CancellationError() }
        guard accept(url, lyrics, prepared.slot.track) else { throw DJAgentMusicLibraryError.unsupported }
        guard playback.commit(ticket, accepted: true) else { throw CancellationError() }
        activeProgram = plan; programQueue = restoredQueue; queuePlaylistID = nil
        publish(["status": "completed", "operation": "restore-program", "title": plan.title ?? "节目", "paused": true])
        return index
    }

    func replaceUpcomingProgram(_ revised: ProgramPlan, at index: Int) async throws {
        guard !closed, let programQueue, activeProgram?.brief.id == revised.brief.id,
              self.index == index, queue.indices.contains(index), revised.slots.indices.contains(index),
              queue[index].id == revised.slots[index].track.id else { throw DJAgentMusicLibraryError.trackNotFound }
        let lease = preparationGeneration
        try await programQueue.replaceUpcoming(programID: revised.brief.id, programRevision: revised.revision, startingAt: index + 1)
        try Task.checkCancellation()
        guard !closed, lease == preparationGeneration else { throw CancellationError() }
        try playback.client.replaceUpcoming(queue: revised.slots.map { $0.track }, ids: revised.slots.map { $0.track.id })
        activeProgram = revised
    }

    private func prepareProgramTrack(_ index: Int, start: Bool = false) async throws -> DJAgentMusicPreparation {
        guard !closed, let plan = activeProgram, queue.indices.contains(index) else { throw DJAgentMusicLibraryError.trackNotFound }
        preparationGeneration &+= 1
        let lease = preparationGeneration
        let proposedQueue = ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: MusicRuntimePlaybackPreparer(runtime: runtime)), call: programCall)
        try await proposedQueue.select(plan, at: index)
        guard let prepared = proposedQueue.current, prepared.slot.track.id == plan.slots[index].track.id,
              case let .localFile(url) = prepared.target else { throw DJAgentMusicLibraryError.sourceUnsupported }
        let lyrics = try? await runtime.lyrics(for: prepared.slot.track)
        try Task.checkCancellation()
        guard !closed, lease == preparationGeneration,
              let ticket = playback.begin(queue: plan.slots.map { $0.track }, index: index) else { throw CancellationError() }
        if start {
            guard let accept = onProgramPrepared else { throw DJAgentMusicLibraryError.unsupported }
            try await accept(url, lyrics, prepared.slot.track)
        } else {
            guard let accept = onToolPrepared, accept(url, lyrics, prepared.slot.track) else { throw DJAgentMusicLibraryError.unsupported }
        }
        try Task.checkCancellation()
        guard !closed, lease == preparationGeneration, playback.commit(ticket, accepted: true) else { throw CancellationError() }
        programQueue = proposedQueue
        try await onProgramSlotCommitted?(index)
        return .init(playlistID: plan.brief.id, trackID: prepared.slot.track.id)
    }

    private func toolLibrary() async throws -> [MusicPlaylistSnapshot] {
        guard !closed else { throw DJAgentMusicLibraryError.unsupported }
        do {
            try await libraryStore.reload()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            for provider in [MusicProviderID.netease, .qqMusic] {
                if (try? await sessions.isDisabled(provider)) == true { disconnectedProviders.insert(provider) }
            }
            guard !closed else { throw DJAgentMusicLibraryError.unsupported }
            playlists = libraryStore.playlists.filter { !disconnectedProviders.contains($0.providerID) }
        }
        return playlists
    }
    func toolList(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage {
        guard offset >= 0, (1...50).contains(limit) else { throw DJAgentMusicLibraryError.invalidArguments }
        let library = try await toolLibrary().filter { item in
            guard let query, !query.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(query)
        }
        let start = min(offset, library.count), end = min(start + limit, library.count)
        return .init(playlists: library[start..<end].map {
            .init(id: $0.id, provider: $0.providerID.rawValue, name: $0.name, trackCount: $0.trackCount,
                  loadedTrackCount: $0.tracks.count, supportsPreparation: $0.providerID != .appleMusic)
        }, offset: offset, nextOffset: end < library.count ? end : nil, isSyncing: syncingProvider != nil)
    }
    private static func toolTrack(_ track: MusicCandidate) -> DJAgentMusicTrack {
        .init(id: track.id, provider: track.providerID.rawValue, title: track.title, artist: track.artist,
              album: track.album, duration: track.duration, isPlayable: track.isPlayable)
    }
    func toolRead(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        guard offset >= 0, (1...50).contains(limit), offset <= Int.max - limit else { throw DJAgentMusicLibraryError.invalidArguments }
        guard let playlist = try await toolLibrary().first(where: { $0.id == playlistID }) else { throw DJAgentMusicLibraryError.playlistNotFound }
        if offset + limit <= playlist.tracks.count || playlist.tracks.count >= playlist.trackCount {
            let start = min(offset, playlist.tracks.count), end = min(start + limit, playlist.tracks.count)
            return .init(playlistID: playlistID, tracks: playlist.tracks[start..<end].map(Self.toolTrack), offset: offset,
                         nextOffset: end < playlist.trackCount ? end : nil, totalTrackCount: playlist.trackCount)
        }
        let ticket = try await libraryStore.beginPage(playlistID: playlistID, offset: offset,
            limit: limit, cacheMode: "window")
        defer { Task { await self.libraryStore.endPage(ticket) } }
        let page = try await runtime.fetchPlaylistPage(providerID: ticket.providerID,
            playlistID: ticket.playlistID, offset: ticket.offset, limit: ticket.limit)
        try Task.checkCancellation()
        guard !closed else { throw DJAgentMusicLibraryError.interrupted }
        try await libraryStore.append(page, ticket: ticket)
        playlists = libraryStore.playlists.filter { !disconnectedProviders.contains($0.providerID) }
        return .init(playlistID: playlistID, tracks: page.tracks.map(Self.toolTrack), offset: offset,
                     nextOffset: page.hasMore && !page.tracks.isEmpty ? offset + page.tracks.count : nil, totalTrackCount: page.totalTrackCount)
    }
    func toolSearch(query: String, limit: Int) async throws -> [DJAgentMusicTrack] {
        guard !closed, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...20).contains(limit) else { throw DJAgentMusicLibraryError.invalidArguments }
        return try await runtime.search(.init(text: query, limit: limit)).map(Self.toolTrack)
    }
    func toolPrepare(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        preparationGeneration &+= 1
        let lease = preparationGeneration
        selection?.cancel(); selection = nil
        guard let playlist = try await toolLibrary().first(where: { $0.id == playlistID }) else { throw DJAgentMusicLibraryError.playlistNotFound }
        var tracks = playlist.tracks
        while tracks.count < playlist.trackCount {
            try Task.checkCancellation()
            guard preparationGeneration == lease else { throw CancellationError() }
            let page = try await runtime.fetchPlaylistPage(providerID: playlist.providerID, playlistID: playlistID, offset: tracks.count, limit: 200)
            guard !closed, UnityMusicPageBoundary.isValid(offset: page.offset, expectedOffset: tracks.count,
                returnedCount: page.tracks.count, total: page.totalTrackCount), !page.tracks.isEmpty else { throw DJAgentMusicLibraryError.trackNotFound }
            tracks.append(contentsOf: page.tracks)
            if !page.hasMore { break }
        }
        try Task.checkCancellation()
        guard preparationGeneration == lease, !closed else { throw CancellationError() }
        guard let index = tracks.firstIndex(where: { $0.id == trackID }),
              let accept = onToolPrepared, let ticket = playback.begin(queue: tracks, index: index) else { throw DJAgentMusicLibraryError.trackNotFound }
        let candidate = tracks[index]
        let asset = try await runtime.preparePlayback(for: candidate)
        let lyrics = try? await runtime.lyrics(for: candidate)
        try Task.checkCancellation()
        guard !closed, preparationGeneration == lease, playback.isCurrent(ticket) else { throw CancellationError() }
        guard case let .pcmFile(url) = asset else { throw DJAgentMusicLibraryError.sourceUnsupported }
        guard accept(url, lyrics, candidate), playback.commit(ticket, accepted: true) else { throw DJAgentMusicLibraryError.unsupported }
        queuePlaylistID = playlistID
        activeProgram = nil; programQueue = nil
        onProgramPlaybackReleased?()
        if let i = playlists.firstIndex(where: { $0.id == playlistID }) {
            playlists[i] = .init(id: playlist.id, providerID: playlist.providerID, name: playlist.name,
                                artworkURL: playlist.artworkURL, tracks: tracks, totalTrackCount: playlist.trackCount)
        }
        publish(["status": "completed", "operation": "prepare", "title": candidate.title])
        return .init(playlistID: playlistID, trackID: trackID)
    }

    /// Completes only after the requested provider asset was loaded paused and
    /// the real queue committed. The host explicitly resumes afterwards.
    func toolSelect(_ index: Int) async throws -> DJAgentMusicPreparation {
        if activeProgram != nil { selection?.cancel(); selection = nil; return try await prepareProgramTrack(index) }
        guard !closed, let playlistID = queuePlaylistID, queue.indices.contains(index) else {
            throw DJAgentMusicLibraryError.trackNotFound
        }
        let trackID = queue[index].id
        return try await toolPrepare(playlistID: playlistID, trackID: trackID)
    }

    func toolNavigate(_ delta: Int) async throws -> DJAgentMusicPreparation {
        let ticket = try playback.client.navigate(delta: delta)
        return try await toolSelect(ticket.index)
    }

    init(root: URL, runtime suppliedRuntime: MusicRuntime? = nil, storage: MusicStorageClient? = nil,
         playbackClient: RustMusicPlaybackClient? = nil, programCall: RustMusicProgramClient.Call? = nil) {
        self.root = root
        let programDaemon = PropTaskDaemonClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true))
        self.programCall = programCall ?? { try await programDaemon.call(method: $0, params: $1) }
        playback = RustMusicSelectionProjection(client: playbackClient ?? RustMusicPlaybackClient(root: root), identity: { $0.id })
        source = ProcessInfo.processInfo.environment["GMGN_UNITY_MUSIC_LIBRARY_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ai.gmgn.radio")
        let accountAuthority = RustMusicAccountClient(applicationSupportBase: root)
        self.accountAuthority = accountAuthority
        let sessions = UnityMusicSessions(directory: source.appendingPathComponent("secrets/music-sessions"), root: root, authority: accountAuthority)
        self.sessions = sessions
        accounts = MusicAccountCommandService(authority: accountAuthority, sessions: sessions)
        libraryStore = SyncedMusicLibraryStore(storage: storage ?? MusicStorageClient(supportRoot: root,
            legacyFiles: [root.appendingPathComponent("music-library.json")]))
        let cacheEndpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        let cacheAuthority = RustMusicCacheClient(endpointFile: cacheEndpoint.endpointFile,
            helperPath: cacheEndpoint.helperPath, allowsLaunching: false,
            taskRoot: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true),
            hostSessionID: UUID().uuidString)
        runtime = suppliedRuntime ?? MusicRuntime(netease: NeteaseMusicSource(sessions: sessions, client: NeteaseMusicProviderClient()),
            qqMusic: QQMusicSource(sessions: sessions, client: QQMusicProviderClient()),
            appleMusic: AppleMusicSource(), cache: StreamingMusicCache(authority: cacheAuthority),
            programClient: RustMusicProgramClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true)))
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
                    if let view = try? await accountAuthority.account(provider) { adoptAccount(view, provider: provider) }
                }
                do { try await refreshAppleAccount(requestAuthorization: false) }
                catch { accountStates[.appleMusic] = .unavailable }
                return
            }
            do {
                accountError = false
                if op == "music.disconnect" {
                    let receipt = try await accountAuthority.disconnect(provider)
                    adoptAccount(receipt, provider: provider)
                    if provider != .appleMusic { await webLogin.clearSession(providerID: provider) }
                    try await seedLibrary()
                    libraryStore.remove(providerID: provider)
                    try await libraryStore.flush()
                    playlists = libraryStore.playlists
                    publishLibrary()
                    accountNotice = "已断开 Unity 会话中的音乐账号。"; return
                }
                if op == "music.connect" {
                    if provider == .appleMusic {
                        try await refreshAppleAccount(requestAuthorization: true)
                        guard accountStates[provider] == .connected else { throw MusicProviderClientError.playbackUnavailable }
                    } else {
                        accountStates[provider] = .authorizing
                        accountNotice = "请在官方页面完成登录。"
                        await webLogin.clearSession(providerID: provider)
                        let cookie = try await webLogin.login(providerID: provider)
                        try await accounts.connect(providerID: provider, cookie: cookie)
                        adoptAccount(try await accountAuthority.account(provider), provider: provider)
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
    private func adoptAccount(_ view: RustMusicAccountClient.Account, provider: MusicProviderID) {
        accountStates[provider] = view.state
        if view.disabled { disconnectedProviders.insert(provider) } else { disconnectedProviders.remove(provider) }
    }
    private func refreshAppleAccount(requestAuthorization: Bool) async throws {
        let current = try await accountAuthority.account(.appleMusic)
        if current.revision == 0 {
            _ = try await accountAuthority.importLegacy(.appleMusic, session: nil,
                disabled: FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-music-disconnected").path))
        }
        let facts = await appleMusic.accountAuthorizationFacts(requestAuthorization: requestAuthorization)
        adoptAccount(try await accountAuthority.appleAuthorization(authorization: facts.authorization,
            hasPlayableSubscription: facts.hasPlayableSubscription, reconnect: requestAuthorization), provider: .appleMusic)
    }
    private func seedLibrary() async throws {
        try await libraryStore.reload()
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
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                try await libraryStore.reload()
                guard !closed else { return }
                for provider in [MusicProviderID.netease, .qqMusic] {
                    if (try? await sessions.isDisabled(provider)) == true { disconnectedProviders.insert(provider) }
                }
                playlists = libraryStore.playlists.filter { !disconnectedProviders.contains($0.providerID) }
                publishLibrary()
            } catch {
                publish(["status": "failed", "operation": "library", "code": "library_unavailable",
                         "message": error.localizedDescription])
            }
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
                    let ticket = try await self.libraryStore.beginPage(playlistID: playlist.id,
                        offset: tracks.count, limit: 200, strict: true)
                    do {
                        let page = try await self.runtime.fetchPlaylistPage(providerID: ticket.providerID,
                            playlistID: ticket.playlistID, offset: ticket.offset, limit: ticket.limit)
                        try Task.checkCancellation()
                        guard !self.closed else { throw CancellationError() }
                        try await self.libraryStore.append(page, ticket: ticket)
                    } catch {
                        await self.libraryStore.endPage(ticket)
                        throw error
                    }
                    guard let confirmed = self.libraryStore.playlist(id: id) else {
                        throw MusicProviderClientError.playbackUnavailable
                    }
                    tracks = confirmed.tracks
                }
                guard !self.closed, !Task.isCancelled else { return }
                self.playlists = self.libraryStore.playlists.filter { !self.disconnectedProviders.contains($0.providerID) }
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
        return prepare(queue: playlist.tracks, index: index, playlistID: playlistID)
    }
    func select(_ index: Int) -> Bool {
        if activeProgram != nil {
            guard !closed, queue.indices.contains(index) else { return false }
            selection?.cancel()
            selection = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.prepareProgramTrack(index, start: true)
                } catch { self.publish(["status": "failed", "operation": "play", "message": error.localizedDescription]) }
            }
            return true
        }
        return prepare(queue: queue, index: index, playlistID: queuePlaylistID)
    }
    private func prepare(queue: [MusicCandidate], index: Int, playlistID: String?) -> Bool {
        guard !closed, let ticket = playback.begin(queue: queue, index: index) else { return false }
        preparationGeneration &+= 1
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
                self.queuePlaylistID = playlistID
                self.activeProgram = nil; self.programQueue = nil
                self.onProgramPlaybackReleased?()
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
    func cancelPreparation() { preparationGeneration &+= 1; selection?.cancel(); selection = nil; queuePlaylistID = nil; activeProgram = nil; programQueue = nil; onProgramPlaybackReleased?() }
    func clearQueue() { cancelPreparation(); playback.clear() }
    func close() { preparationGeneration &+= 1; closed = true; task?.cancel(); selection?.cancel(); accountTask?.cancel(); webLogin.cancel() }
}
