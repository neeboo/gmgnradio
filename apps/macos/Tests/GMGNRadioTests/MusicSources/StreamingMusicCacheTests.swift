import Foundation
import Testing
@testable import GMGNRadio

@Test
func streamingMusicCacheDownloadsWithProviderHeaders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "gmgn-stream-cache-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProviderHTTPTransportStub(responses: [
        MusicProviderHTTPResponse(
            data: Data("audio-bytes".utf8),
            statusCode: 200
        ),
    ])
    let cache = StreamingMusicCache(
        rootURL: root,
        transport: transport
    )
    let asset = MusicPlaybackAsset(
        url: URL(string: "https://example.com/song.mp3?token=1")!,
        requestHeaders: [
            "Cookie": "MUSIC_U=user-session",
            "Referer": "https://music.163.com/",
        ]
    )

    let localURL = try await cache.store(asset, trackID: "netease:42")

    #expect(localURL.pathExtension == "mp3")
    #expect(try Data(contentsOf: localURL) == Data("audio-bytes".utf8))
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Cookie")
        == "MUSIC_U=user-session")
    #expect(request.value(forHTTPHeaderField: "Referer")
        == "https://music.163.com/")
}

@MainActor
@Test
func musicRuntimePreparesAccountTracksForThePCMPlayer() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        providerSession("MUSIC_U=user-session"),
        for: .netease
    )
    let expectedAsset = MusicPlaybackAsset(
        url: URL(string: "https://example.com/song.mp3")!,
        requestHeaders: [:]
    )
    let cachedURL = URL(fileURLWithPath: "/tmp/gmgn-cached-song.mp3")
    let cache = MusicAssetCacheStub(localURL: cachedURL)
    let runtime = MusicRuntime(
        netease: NeteaseMusicSource(
            sessions: sessions,
            client: PlaybackAccountClientStub(asset: expectedAsset)
        ),
        qqMusic: QQMusicSource(
            sessions: InMemoryMusicProviderSessionStore(),
            client: PlaybackAccountClientStub(asset: expectedAsset)
        ),
        appleMusic: AppleMusicSource(
            client: AppleMusicClientStub(
                authorization: .denied,
                canPlayCatalogContent: false
            )
        ),
        cache: cache
    )
    let candidate = MusicCandidate(
        id: "netease:42",
        canonicalID: nil,
        providerID: .netease,
        source: .streaming,
        title: "Example",
        artist: "Artist",
        album: nil,
        duration: 180,
        isPlayable: true,
        matchScore: 1,
        userAffinity: 0,
        energy: 0.5,
        moodTags: [],
        genres: [],
        releaseYear: nil
    )

    let prepared = try await runtime.preparePlayback(for: candidate)

    #expect(prepared == .pcmFile(cachedURL))
    #expect(await cache.assets == [expectedAsset])
}

private actor MusicAssetCacheStub: MusicAssetCaching {
    let localURL: URL
    private(set) var assets: [MusicPlaybackAsset] = []

    init(localURL: URL) {
        self.localURL = localURL
    }

    func store(
        _ asset: MusicPlaybackAsset,
        trackID: String
    ) async throws -> URL {
        assets.append(asset)
        return localURL
    }
}

private struct PlaybackAccountClientStub: AccountMusicProviderClient {
    let asset: MusicPlaybackAsset

    func capabilities(
        session: MusicProviderSession
    ) async throws -> MusicAccountCapabilities {
        MusicAccountCapabilities(
            canSearchCatalog: true,
            canReadLibrary: true,
            canReadPlaylists: true,
            canReadRecentPlays: false,
            canPlay: true
        )
    }

    func search(
        _ request: MusicSearchRequest,
        session: MusicProviderSession
    ) async throws -> [MusicProviderTrack] {
        []
    }

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary {
        MusicProviderLibrary(
            savedTracks: [],
            playlistIDs: [],
            recentlyPlayedTrackIDs: []
        )
    }

    func playbackAsset(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicPlaybackAsset {
        asset
    }
}
