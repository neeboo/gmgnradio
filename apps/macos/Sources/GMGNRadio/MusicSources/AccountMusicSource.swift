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
}

struct MusicProviderLibrary: Equatable, Sendable {
    let savedTracks: [MusicProviderTrack]
    let playlistIDs: [String]
    let recentlyPlayedTrackIDs: [String]
}

protocol AccountMusicProviderClient: Sendable {
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
}

enum MusicSourceError: Error, Equatable {
    case authenticationRequired(MusicProviderID)
    case capabilityUnavailable(MusicProviderID)
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
            playlistIDs: library.playlistIDs.map(namespacedPlaylistID),
            recentlyPlayedTrackIDs: library.recentlyPlayedTrackIDs.map(
                namespacedTrackID
            )
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
            releaseYear: track.releaseYear
        )
    }

    private func namespacedTrackID(_ trackID: String) -> String {
        "\(id.rawValue):\(trackID)"
    }

    private func namespacedPlaylistID(_ playlistID: String) -> String {
        "\(id.rawValue):playlist:\(playlistID)"
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
}
