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

@MainActor
@Test
func musicRuntimeBuildsAnAgentProgramFromTheConnectedLibrary() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        providerSession("MUSIC_U=user-session"),
        for: .netease
    )
    let tracks = (1 ... 5).map { index in
        MusicProviderTrack(
            id: String(index),
            canonicalID: nil,
            title: "Library Track \(index)",
            artist: "Artist \(index)",
            album: nil,
            duration: 240,
            isPlayable: true,
            matchScore: 0.7,
            userAffinity: 1,
            energy: Double(index) / 10,
            moodTags: ["夜晚"],
            genres: [],
            releaseYear: nil
        )
    }
    let runtime = MusicRuntime(
        netease: NeteaseMusicSource(
            sessions: sessions,
            client: PlaybackAccountClientStub(
                asset: MusicPlaybackAsset(
                    url: URL(string: "https://example.com/song.mp3")!,
                    requestHeaders: [:]
                ),
                libraryTracks: tracks
            )
        ),
        qqMusic: QQMusicSource(
            sessions: InMemoryMusicProviderSessionStore(),
            client: PlaybackAccountClientStub(
                asset: MusicPlaybackAsset(
                    url: URL(string: "https://example.com/song.mp3")!,
                    requestHeaders: [:]
                )
            )
        ),
        appleMusic: AppleMusicSource(
            client: AppleMusicClientStub(
                authorization: .denied,
                canPlayCatalogContent: false
            )
        ),
        cache: MusicAssetCacheStub(
            localURL: URL(fileURLWithPath: "/tmp/song.mp3")
        )
    )

    let plan = try await runtime.makeProgramPlan(
        brief: ProgramBrief(
            id: "night",
            targetDuration: 1_200,
            moodTags: ["夜晚"],
            energyArc: [0.2, 0.6],
            conversationMode: .ambient
        ),
        agent: FixedTrackRankingAgent(
            trackIDs: [
                "netease:5",
                "netease:3",
                "netease:1",
                "netease:4",
                "netease:2",
            ]
        )
    )

    #expect(plan.slots.map(\.track.id) == [
        "netease:5",
        "netease:3",
        "netease:1",
        "netease:4",
        "netease:2",
    ])
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
    var libraryTracks: [MusicProviderTrack] = []

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
            savedTracks: libraryTracks,
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

private struct FixedTrackRankingAgent: DJTrackRankingAgent {
    let trackIDs: [String]

    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String] {
        trackIDs
    }
}
