import Foundation

struct MusicProviderTrack: Equatable, Sendable {
    let id: String
    let canonicalID: String?
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let isPlayable: Bool
    let matchScore: Double
    let userAffinity: Double
    let energy: Double
    let moodTags: [String]
    let genres: [String]
    let releaseYear: Int?
    var artworkURL: URL? = nil
}

struct MusicProviderLibrary: Equatable, Sendable {
    let savedTracks: [MusicProviderTrack]
    let playlists: [MusicProviderPlaylist]
    let recentlyPlayedTrackIDs: [String]

    var playlistIDs: [String] {
        playlists.map(\.id)
    }

    init(
        savedTracks: [MusicProviderTrack],
        playlists: [MusicProviderPlaylist],
        recentlyPlayedTrackIDs: [String]
    ) {
        self.savedTracks = savedTracks
        self.playlists = playlists
        self.recentlyPlayedTrackIDs = recentlyPlayedTrackIDs
    }

    init(
        savedTracks: [MusicProviderTrack],
        playlistIDs: [String],
        recentlyPlayedTrackIDs: [String]
    ) {
        self.init(
            savedTracks: savedTracks,
            playlists: playlistIDs.map {
                MusicProviderPlaylist(
                    id: $0,
                    name: $0,
                    artworkURL: nil,
                    trackCount: 0,
                    tracks: []
                )
            },
            recentlyPlayedTrackIDs: recentlyPlayedTrackIDs
        )
    }
}

struct MusicProviderPlaylist: Equatable, Sendable {
    let id: String
    let name: String
    let artworkURL: URL?
    let trackCount: Int
    let tracks: [MusicProviderTrack]
}

struct MusicProviderPlaylistPage: Equatable, Sendable {
    let playlistID: String
    let tracks: [MusicProviderTrack]
    let offset: Int
    let totalTrackCount: Int
}

struct MusicLyrics: Equatable, Sendable {
    let original: String
    let translation: String?
    let wordByWord: String?

    init(
        original: String,
        translation: String?,
        wordByWord: String? = nil
    ) {
        self.original = original
        self.translation = translation
        self.wordByWord = wordByWord
    }
}

protocol AccountMusicProviderClient: Sendable {
    func validateAccount(session: MusicProviderSession) async throws
    func capabilities(
        session: MusicProviderSession
    ) async throws -> MusicAccountCapabilities

    func search(
        _ request: MusicSearchRequest,
        session: MusicProviderSession
    ) async throws -> [MusicProviderTrack]

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary

    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int,
        session: MusicProviderSession
    ) async throws -> MusicProviderPlaylistPage

    func playbackAsset(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicPlaybackAsset

    func lyrics(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicLyrics
}

extension AccountMusicProviderClient {
    func validateAccount(session: MusicProviderSession) async throws {
        _ = try await fetchUserLibrary(session: session)
    }
    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int,
        session: MusicProviderSession
    ) async throws -> MusicProviderPlaylistPage {
        let library = try await fetchUserLibrary(session: session)
        guard let playlist = library.playlists.first(where: {
            $0.id == playlistID
        }) else {
            return MusicProviderPlaylistPage(
                playlistID: playlistID,
                tracks: [],
                offset: max(0, offset),
                totalTrackCount: 0
            )
        }
        let safeOffset = min(max(0, offset), playlist.tracks.count)
        let end = min(
            safeOffset + max(1, limit),
            playlist.tracks.count
        )
        return MusicProviderPlaylistPage(
            playlistID: playlistID,
            tracks: Array(playlist.tracks[safeOffset ..< end]),
            offset: safeOffset,
            totalTrackCount: playlist.trackCount
        )
    }

    func playbackAsset(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicPlaybackAsset {
        throw MusicProviderClientError.playbackUnavailable
    }

    func lyrics(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicLyrics {
        throw MusicProviderClientError.playbackUnavailable
    }
}

enum MusicSourceError: Error, Equatable, LocalizedError {
    case authenticationRequired(MusicProviderID)
    case capabilityUnavailable(MusicProviderID)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "音乐账号登录状态已失效，请重新连接。"
        case .capabilityUnavailable:
            "当前音乐账号不能读取歌单。"
        }
    }
}

struct AccountMusicSource: MusicSource {
    let id: MusicProviderID

    private let sessions: any MusicProviderSessionStore
    private let client: any AccountMusicProviderClient
    private let now: @Sendable () -> Date

    init(
        id: MusicProviderID,
        sessions: any MusicProviderSessionStore,
        client: any AccountMusicProviderClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.id = id
        self.sessions = sessions
        self.client = client
        self.now = now
    }

    func access() async -> MusicSourceAccess {
        do {
            guard let session = try await sessions.session(for: id) else {
                return .accountRequired(.disconnected)
            }
            return .accountRequired(
                session.authorizationState(now: now())
            )
        } catch {
            return .accountRequired(.unavailable)
        }
    }

    func search(
        _ request: MusicSearchRequest
    ) async throws -> [MusicCandidate] {
        let session = try await connectedSession()
        let capabilities = try await client.capabilities(session: session)
        guard capabilities.canSearchCatalog else {
            throw MusicSourceError.capabilityUnavailable(id)
        }
        return try await client.search(request, session: session)
            .map(candidate(from:))
    }

    func fetchUserLibrary() async throws -> MusicLibrarySnapshot {
        let session = try await connectedSession()
        let capabilities = try await client.capabilities(session: session)
        guard
            capabilities.canReadLibrary
                || capabilities.canReadPlaylists
                || capabilities.canReadRecentPlays
        else {
            throw MusicSourceError.capabilityUnavailable(id)
        }

        let library = try await client.fetchUserLibrary(session: session)
        return MusicLibrarySnapshot(
            savedTracks: library.savedTracks.map(candidate(from:)),
            playlists: library.playlists.map { playlist in
                MusicPlaylistSnapshot(
                    id: namespacedPlaylistID(playlist.id),
                    providerID: id,
                    name: playlist.name,
                    artworkURL: playlist.artworkURL,
                    tracks: playlist.tracks.map(candidate(from:)),
                    totalTrackCount: playlist.trackCount
                )
            },
            recentlyPlayedTrackIDs: library.recentlyPlayedTrackIDs.map(
                namespacedTrackID
            )
        )
    }

    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int
    ) async throws -> MusicPlaylistPage {
        let session = try await connectedSession()
        let rawPlaylistID = rawPlaylistID(playlistID)
        let page = try await client.fetchPlaylistPage(
            playlistID: rawPlaylistID,
            offset: offset,
            limit: limit,
            session: session
        )
        return MusicPlaylistPage(
            playlistID: namespacedPlaylistID(page.playlistID),
            tracks: page.tracks.map(candidate(from:)),
            offset: page.offset,
            totalTrackCount: page.totalTrackCount
        )
    }

    func playbackAsset(for trackID: String) async throws -> MusicPlaybackAsset {
        let session = try await connectedSession()
        let capabilities = try await client.capabilities(session: session)
        guard capabilities.canPlay else {
            throw MusicSourceError.capabilityUnavailable(id)
        }
        return try await client.playbackAsset(
            for: rawTrackID(trackID),
            session: session
        )
    }

    func lyrics(for trackID: String) async throws -> MusicLyrics {
        let session = try await connectedSession()
        return try await client.lyrics(
            for: rawTrackID(trackID),
            session: session
        )
    }

    private func connectedSession() async throws -> MusicProviderSession {
        guard let session = try await sessions.session(for: id) else {
            throw MusicSourceError.authenticationRequired(id)
        }
        guard session.authorizationState(now: now()) == .connected else {
            throw MusicSourceError.authenticationRequired(id)
        }
        return session
    }

    private func candidate(
        from track: MusicProviderTrack
    ) -> MusicCandidate {
        MusicCandidate(
            id: namespacedTrackID(track.id),
            canonicalID: track.canonicalID,
            providerID: id,
            source: .streaming,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            isPlayable: track.isPlayable,
            matchScore: track.matchScore,
            userAffinity: track.userAffinity,
            energy: track.energy,
            moodTags: track.moodTags,
            genres: track.genres,
            releaseYear: track.releaseYear,
            artworkURL: track.artworkURL
        )
    }

    private func namespacedTrackID(_ trackID: String) -> String {
        "\(id.rawValue):\(trackID)"
    }

    private func rawTrackID(_ trackID: String) -> String {
        let prefix = "\(id.rawValue):"
        guard trackID.hasPrefix(prefix) else {
            return trackID
        }
        return String(trackID.dropFirst(prefix.count))
    }

    private func namespacedPlaylistID(_ playlistID: String) -> String {
        "\(id.rawValue):playlist:\(playlistID)"
    }

    private func rawPlaylistID(_ playlistID: String) -> String {
        let prefix = "\(id.rawValue):playlist:"
        guard playlistID.hasPrefix(prefix) else {
            return playlistID
        }
        return String(playlistID.dropFirst(prefix.count))
    }
}

struct NeteaseMusicSource: MusicSource {
    let id = MusicProviderID.netease
    private let source: AccountMusicSource

    init(
        sessions: any MusicProviderSessionStore,
        client: any AccountMusicProviderClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        source = AccountMusicSource(
            id: .netease,
            sessions: sessions,
            client: client,
            now: now
        )
    }

    func access() async -> MusicSourceAccess {
        await source.access()
    }

    func search(
        _ request: MusicSearchRequest
    ) async throws -> [MusicCandidate] {
        try await source.search(request)
    }

    func fetchUserLibrary() async throws -> MusicLibrarySnapshot {
        try await source.fetchUserLibrary()
    }

    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int
    ) async throws -> MusicPlaylistPage {
        try await source.fetchPlaylistPage(
            playlistID: playlistID,
            offset: offset,
            limit: limit
        )
    }

    func playbackAsset(for trackID: String) async throws -> MusicPlaybackAsset {
        try await source.playbackAsset(for: trackID)
    }

    func lyrics(for trackID: String) async throws -> MusicLyrics {
        try await source.lyrics(for: trackID)
    }
}

struct QQMusicSource: MusicSource {
    let id = MusicProviderID.qqMusic
    private let source: AccountMusicSource

    init(
        sessions: any MusicProviderSessionStore,
        client: any AccountMusicProviderClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        source = AccountMusicSource(
            id: .qqMusic,
            sessions: sessions,
            client: client,
            now: now
        )
    }

    func access() async -> MusicSourceAccess {
        await source.access()
    }

    func search(
        _ request: MusicSearchRequest
    ) async throws -> [MusicCandidate] {
        try await source.search(request)
    }

    func fetchUserLibrary() async throws -> MusicLibrarySnapshot {
        try await source.fetchUserLibrary()
    }

    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int
    ) async throws -> MusicPlaylistPage {
        try await source.fetchPlaylistPage(
            playlistID: playlistID,
            offset: offset,
            limit: limit
        )
    }

    func playbackAsset(for trackID: String) async throws -> MusicPlaybackAsset {
        try await source.playbackAsset(for: trackID)
    }
}
