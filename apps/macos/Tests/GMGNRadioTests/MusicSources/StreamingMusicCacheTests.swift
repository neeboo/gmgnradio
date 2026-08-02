import Foundation
import Testing
@testable import GMGNRadio

@Test
func musicRedirectPolicyUpgradesHTTPAudioURLsToHTTPS() throws {
    var request = URLRequest(
        url: try #require(
            URL(string: "http://m801.music.126.net/song.mp3?token=one")
        )
    )
    request.setValue("session", forHTTPHeaderField: "Cookie")

    let secured = SecureMusicRedirectPolicy.secured(request)

    #expect(
        secured.url?.absoluteString
            == "https://m801.music.126.net/song.mp3?token=one"
    )
    #expect(secured.value(forHTTPHeaderField: "Cookie") == "session")
}

@Test
func streamingMusicCacheDownloadsWithProviderHeaders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "gmgn-stream-cache-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProviderHTTPTransportStub(responses: [
        MusicProviderHTTPResponse(
            data: mp3Fixture(),
            statusCode: 200,
            mimeType: "audio/mpeg"
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
    #expect(try Data(contentsOf: localURL) == mp3Fixture())
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Cookie")
        == "MUSIC_U=user-session")
    #expect(request.value(forHTTPHeaderField: "Referer")
        == "https://music.163.com/")
}

@Test
func streamingMusicCacheReusesAnExistingCompleteFile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "gmgn-stream-cache-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProviderHTTPTransportStub(responses: [
        MusicProviderHTTPResponse(
            data: mp3Fixture(),
            statusCode: 200,
            mimeType: "audio/mpeg"
        ),
    ])
    let cache = StreamingMusicCache(
        rootURL: root,
        transport: transport
    )
    let asset = MusicPlaybackAsset(
        url: URL(string: "https://example.com/song.mp3?token=1")!,
        requestHeaders: [:]
    )

    let first = try await cache.store(asset, trackID: "netease:42")
    let second = try await cache.store(asset, trackID: "netease:42")

    #expect(first == second)
    #expect(await transport.requests.count == 1)
}

@Test
func streamingMusicCacheReplacesAnHTMLFileMasqueradingAsAudio() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "gmgn-stream-cache-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let broken = root.appending(path: "netease-42.mp3")
    try Data("<!DOCTYPE html><title>music</title>".utf8)
        .write(to: broken)
    let transport = ProviderHTTPTransportStub(responses: [
        MusicProviderHTTPResponse(
            data: mp3Fixture(),
            statusCode: 200,
            mimeType: "audio/mpeg"
        ),
    ])
    let cache = StreamingMusicCache(
        rootURL: root,
        transport: transport
    )
    let asset = MusicPlaybackAsset(
        url: URL(string: "https://example.com/song.mp3")!,
        requestHeaders: [:]
    )

    let localURL = try await cache.store(asset, trackID: "netease:42")

    #expect(localURL == broken)
    #expect(try Data(contentsOf: localURL) == mp3Fixture())
    #expect(await transport.requests.count == 1)
}

@Test
func streamingMusicCacheRejectsHTMLDownloadsBeforePersisting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "gmgn-stream-cache-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ProviderHTTPTransportStub(responses: [
        MusicProviderHTTPResponse(
            data: Data("<!DOCTYPE html><title>login</title>".utf8),
            statusCode: 200,
            mimeType: "text/html"
        ),
    ])
    let cache = StreamingMusicCache(
        rootURL: root,
        transport: transport
    )
    let asset = MusicPlaybackAsset(
        url: URL(string: "https://music.example.com/song.mp3")!,
        requestHeaders: [:]
    )

    await #expect(throws: MusicProviderClientError.invalidAudioPayload) {
        try await cache.store(asset, trackID: "netease:42")
    }

    #expect(
        !FileManager.default.fileExists(
            atPath: root.appending(path: "netease-42.mp3").path
        )
    )
}

private func mp3Fixture() -> Data {
    Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 12])
        + Data(repeating: 0x41, count: 32)
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
func musicRuntimeRecoversArtworkForPersistedTracksThatLackIt() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        providerSession("MUSIC_U=user-session"),
        for: .netease
    )
    let artworkURL = URL(string: "https://example.com/cover.jpg")!
    let runtime = MusicRuntime(
        netease: NeteaseMusicSource(
            sessions: sessions,
            client: PlaybackAccountClientStub(
                asset: MusicPlaybackAsset(
                    url: URL(string: "https://example.com/song.mp3")!,
                    requestHeaders: [:]
                ),
                searchTracks: [
                    MusicProviderTrack(
                        id: "42",
                        canonicalID: nil,
                        title: "Plastic Love",
                        artist: "Mariya Takeuchi",
                        album: "Variety",
                        duration: 291,
                        isPlayable: true,
                        matchScore: 1,
                        userAffinity: 0,
                        energy: 0.7,
                        moodTags: [],
                        genres: ["City Pop"],
                        releaseYear: 1984,
                        artworkURL: artworkURL
                    )
                ],
                expectedSearchText: "Plastic Love Mariya Takeuchi"
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
    let persistedTrack = MusicCandidate(
        id: "netease:42",
        canonicalID: nil,
        providerID: .netease,
        source: .streaming,
        title: "Plastic Love",
        artist: "Mariya Takeuchi",
        album: "Variety",
        duration: 291,
        isPlayable: true,
        matchScore: 1,
        userAffinity: 0,
        energy: 0.7,
        moodTags: [],
        genres: ["City Pop"],
        releaseYear: 1984
    )

    #expect(await runtime.artworkURL(for: persistedTrack) == artworkURL)
}

@MainActor
@Test
func musicRuntimeKeepsExistingArtworkWithoutSearching() async throws {
    let artworkURL = URL(string: "https://example.com/saved-cover.jpg")!
    let runtime = MusicRuntime(
        netease: NeteaseMusicSource(
            sessions: InMemoryMusicProviderSessionStore(),
            client: PlaybackAccountClientStub(
                asset: MusicPlaybackAsset(
                    url: URL(string: "https://example.com/song.mp3")!,
                    requestHeaders: [:]
                )
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
    let track = MusicCandidate(
        id: "netease:saved",
        canonicalID: nil,
        providerID: .netease,
        source: .streaming,
        title: "Saved",
        artist: "Artist",
        album: nil,
        duration: 180,
        isPlayable: true,
        matchScore: 1,
        userAffinity: 0,
        energy: 0.5,
        moodTags: [],
        genres: [],
        releaseYear: nil,
        artworkURL: artworkURL
    )

    #expect(await runtime.artworkURL(for: track) == artworkURL)
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

@MainActor
@Test
func musicRuntimeReturnsNamedPlaylistsFromConnectedAccounts() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        providerSession("MUSIC_U=user-session"),
        for: .netease
    )
    let track = MusicProviderTrack(
        id: "liked-1",
        canonicalID: nil,
        title: "夜航",
        artist: "Example",
        album: nil,
        duration: 240,
        isPlayable: true,
        matchScore: 0.8,
        userAffinity: 1,
        energy: 0.4,
        moodTags: [],
        genres: [],
        releaseYear: nil
    )
    let runtime = MusicRuntime(
        netease: NeteaseMusicSource(
            sessions: sessions,
            client: PlaybackAccountClientStub(
                asset: MusicPlaybackAsset(
                    url: URL(string: "https://example.com/song.mp3")!,
                    requestHeaders: [:]
                ),
                libraryTracks: [track],
                playlists: [
                    MusicProviderPlaylist(
                        id: "liked",
                        name: "我喜欢的音乐",
                        artworkURL: nil,
                        trackCount: 1,
                        tracks: [track]
                    )
                ]
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

    let libraries = await runtime.fetchConnectedLibraries()

    #expect(libraries.flatMap(\.playlists).map(\.name) == ["我喜欢的音乐"])
    #expect(
        libraries.flatMap(\.playlists).first?.tracks.map(\.id)
            == ["netease:liked-1"]
    )
}

@MainActor
@Test
func musicRuntimeUsesTheUserInstructionForDiscoveryCandidates() async throws {
    let sessions = InMemoryMusicProviderSessionStore()
    await sessions.save(
        providerSession("MUSIC_U=user-session"),
        for: .netease
    )
    let cityPop = (1 ... 5).map { index in
        MusicProviderTrack(
            id: "city-\(index)",
            canonicalID: nil,
            title: "City Pop \(index)",
            artist: "Tokyo Artist \(index)",
            album: nil,
            duration: 240,
            isPlayable: true,
            matchScore: 1,
            userAffinity: 0,
            energy: 0.6,
            moodTags: [],
            genres: ["City Pop"],
            releaseYear: 1980 + index
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
                searchTracks: cityPop,
                expectedSearchText: "City Pop"
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
            id: "city-pop",
            targetDuration: 1_200,
            moodTags: ["夜晚"],
            energyArc: [0.4, 0.7],
            conversationMode: .ambient,
            immediateUserInstruction: "给我生成一个 City Pop 的歌单"
        ),
        agent: FixedTrackRankingAgent(
            trackIDs: cityPop.map { "netease:\($0.id)" }
        )
    )

    #expect(plan.slots.map(\.track.id) == cityPop.map {
        "netease:\($0.id)"
    })
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
    var playlists: [MusicProviderPlaylist] = []
    var searchTracks: [MusicProviderTrack] = []
    var expectedSearchText: String?

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
        if let expectedSearchText, request.text != expectedSearchText {
            throw PlaybackAccountClientStubError.unexpectedSearchText(
                request.text
            )
        }
        return searchTracks
    }

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary {
        MusicProviderLibrary(
            savedTracks: libraryTracks,
            playlists: playlists,
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

private enum PlaybackAccountClientStubError: Error {
    case unexpectedSearchText(String?)
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
