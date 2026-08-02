import Foundation
import Testing
@testable import GMGNRadio

@Test
func neteaseSourceMapsTracksFromTheUsersConnectedSession() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        MusicProviderSession(
            credential: .cookieHeader("MUSIC_U=test-session"),
            expiresAt: nil
        ),
        for: .netease
    )
    let source = NeteaseMusicSource(
        sessions: sessions,
        client: StubAccountMusicProviderClient(
            tracks: [
                providerTrack(
                    id: "2048",
                    title: "Blue Hour",
                    canonicalID: "ISRC-CN-2048"
                )
            ]
        )
    )

    #expect(await source.access() == .accountRequired(.connected))

    let results = try await source.search(
        MusicSearchRequest(text: "Blue Hour", limit: 10)
    )

    #expect(results.count == 1)
    #expect(results[0].id == "netease:2048")
    #expect(results[0].providerID == .netease)
    #expect(results[0].source == .streaming)
    #expect(results[0].canonicalID == "ISRC-CN-2048")

    let library = try await source.fetchUserLibrary()
    #expect(library.playlistIDs == ["netease:playlist:favorites"])
    #expect(library.playlists.count == 1)
    #expect(library.playlists[0].name == "我喜欢的音乐")
    #expect(library.playlists[0].tracks.map(\.id) == ["netease:2048"])
}

@Test
func qqMusicSourceStaysUnavailableWithoutAUserSession() async throws {
    let source = QQMusicSource(
        sessions: InMemoryMusicProviderSessionStore(),
        client: StubAccountMusicProviderClient(
            tracks: [providerTrack(id: "qq-1", title: "Unavailable")]
        )
    )

    #expect(await source.access() == .accountRequired(.disconnected))

    await #expect(throws: MusicSourceError.self) {
        try await source.search(MusicSearchRequest(text: "Unavailable"))
    }
}

@Test
func expiredProviderSessionIsNotUsedForSearch() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        MusicProviderSession(
            credential: .cookieHeader("uin=test-session"),
            expiresAt: Date(timeIntervalSince1970: 1)
        ),
        for: .qqMusic
    )
    let source = QQMusicSource(
        sessions: sessions,
        client: StubAccountMusicProviderClient(
            tracks: [providerTrack(id: "qq-2", title: "Expired")]
        ),
        now: { Date(timeIntervalSince1970: 2) }
    )

    #expect(await source.access() == .accountRequired(.expired))
    await #expect(throws: MusicSourceError.self) {
        try await source.fetchUserLibrary()
    }
}

@Test
func providerSessionStoreFailureIsReportedAsUnavailable() async {
    let source = NeteaseMusicSource(
        sessions: FailingMusicProviderSessionStore(),
        client: StubAccountMusicProviderClient()
    )

    #expect(await source.access() == .accountRequired(.unavailable))
}

@Test
func unifiedSearchContinuesWhenOneConnectedProviderFails() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        MusicProviderSession(
            credential: .cookieHeader("MUSIC_U=test-session"),
            expiresAt: nil
        ),
        for: .netease
    )
    let netease = NeteaseMusicSource(
        sessions: sessions,
        client: StubAccountMusicProviderClient(error: ProviderTestError.offline)
    )
    let local = StubProviderAwareMusicSource(
        id: .local,
        candidates: [
            candidate(
                id: "local-safe",
                title: "Local Safe Track",
                providerID: .local
            )
        ]
    )

    let results = try await UnifiedMusicSearch(
        sources: [netease, local]
    ).search(MusicSearchRequest(text: "continue", limit: 10))

    #expect(results.map(\.id) == ["local-safe"])
}

private enum ProviderTestError: Error, Sendable {
    case offline
}

private struct FailingMusicProviderSessionStore: MusicProviderSessionStore {
    func session(
        for providerID: MusicProviderID
    ) async throws -> MusicProviderSession? {
        throw ProviderTestError.offline
    }

    func save(
        _ session: MusicProviderSession,
        for providerID: MusicProviderID
    ) async throws {
        throw ProviderTestError.offline
    }

    func removeSession(
        for providerID: MusicProviderID
    ) async throws {
        throw ProviderTestError.offline
    }
}

private struct StubAccountMusicProviderClient: AccountMusicProviderClient {
    var advertisedCapabilities = MusicAccountCapabilities(
        canSearchCatalog: true,
        canReadLibrary: true,
        canReadPlaylists: true,
        canReadRecentPlays: true,
        canPlay: true
    )
    var tracks: [MusicProviderTrack] = []
    var error: ProviderTestError?

    func capabilities(
        session: MusicProviderSession
    ) async throws -> MusicAccountCapabilities {
        if let error { throw error }
        return advertisedCapabilities
    }

    func search(
        _ request: MusicSearchRequest,
        session: MusicProviderSession
    ) async throws -> [MusicProviderTrack] {
        if let error { throw error }
        return tracks
    }

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary {
        if let error { throw error }
        return MusicProviderLibrary(
            savedTracks: tracks,
            playlists: [
                MusicProviderPlaylist(
                    id: "favorites",
                    name: "我喜欢的音乐",
                    artworkURL: URL(
                        string: "https://example.com/favorites.jpg"
                    ),
                    trackCount: tracks.count,
                    tracks: tracks
                )
            ],
            recentlyPlayedTrackIDs: tracks.map(\.id)
        )
    }
}

private struct StubProviderAwareMusicSource: MusicSource {
    let id: MusicProviderID
    let candidates: [MusicCandidate]

    func search(_ request: MusicSearchRequest) async throws -> [MusicCandidate] {
        candidates
    }
}

private func providerTrack(
    id: String,
    title: String,
    canonicalID: String? = nil
) -> MusicProviderTrack {
    MusicProviderTrack(
        id: id,
        canonicalID: canonicalID,
        title: title,
        artist: "Example Artist",
        album: "Example Album",
        duration: 240,
        isPlayable: true,
        matchScore: 0.9,
        userAffinity: 0.6,
        energy: 0.4,
        moodTags: ["calm"],
        genres: ["electronic"],
        releaseYear: 2024
    )
}
