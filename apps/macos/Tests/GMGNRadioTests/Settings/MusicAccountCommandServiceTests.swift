import Foundation
import Testing
@testable import GMGNRadio

@Test
func musicProviderKeychainUsesTheStableSignatureNamespace() {
    #expect(
        KeychainMusicProviderSessionStore.defaultService
            == "ai.gmgn.radio.music-providers.stable-v1"
    )
}

@Test
func musicProviderStoreUsesMemoryWhenKeychainAccessIsDisabled() async throws {
    let store = KeychainMusicProviderSessionStore(
        service: "ai.gmgn.radio.tests.never-keychain",
        permitsKeychainAccess: false
    )
    let session = providerSession("MUSIC_U=test-session")

    try await store.save(session, for: .netease)
    #expect(try await store.session(for: .netease) == session)

    try await store.removeSession(for: .netease)
    #expect(try await store.session(for: .netease) == nil)
}

@Test
func musicAccountServiceValidatesBeforeSavingAProviderSession() async throws {
    let store = InMemoryMusicProviderSessionStore()
    let service = MusicAccountCommandService(
        sessions: store,
        neteaseClient: MusicAccountClientStub(),
        qqMusicClient: MusicAccountClientStub()
    )

    try await service.connect(
        providerID: .netease,
        cookie: "MUSIC_U=user-session"
    )

    let saved = await store.session(for: .netease)
    #expect(saved?.credential == .cookieHeader("MUSIC_U=user-session"))
}

@Test
func musicAccountServiceDoesNotSaveARejectedProviderSession() async {
    let store = InMemoryMusicProviderSessionStore()
    let service = MusicAccountCommandService(
        sessions: store,
        neteaseClient: MusicAccountClientStub(error: .rejected),
        qqMusicClient: MusicAccountClientStub()
    )

    await #expect(throws: MusicAccountTestError.self) {
        try await service.connect(
            providerID: .netease,
            cookie: "MUSIC_U=expired"
        )
    }
    #expect(await store.session(for: .netease) == nil)
}

@Test
func musicAccountServiceCanDisconnectAProvider() async throws {
    let store = InMemoryMusicProviderSessionStore()
    await store.save(
        providerSession("uin=o1; qm_keyst=key"),
        for: .qqMusic
    )
    let service = MusicAccountCommandService(
        sessions: store,
        neteaseClient: MusicAccountClientStub(),
        qqMusicClient: MusicAccountClientStub()
    )

    try await service.disconnect(providerID: .qqMusic)

    #expect(await store.session(for: .qqMusic) == nil)
}

@Test
func musicAccountServiceAcceptsQQMusicWechatLoginCookies() async throws {
    let store = InMemoryMusicProviderSessionStore()
    let service = MusicAccountCommandService(
        sessions: store,
        neteaseClient: MusicAccountClientStub(),
        qqMusicClient: MusicAccountClientStub()
    )

    try await service.connect(
        providerID: .qqMusic,
        cookie: "wxuin=12345; wxskey=playback-key"
    )

    #expect(
        await store.session(for: .qqMusic)?.credential
            == .cookieHeader("wxuin=12345; wxskey=playback-key")
    )
}

private enum MusicAccountTestError: Error {
    case rejected
}

private struct MusicAccountClientStub: AccountMusicProviderClient {
    var error: MusicAccountTestError?

    func capabilities(
        session: MusicProviderSession
    ) async throws -> MusicAccountCapabilities {
        if let error {
            throw error
        }
        return MusicAccountCapabilities(
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
        if let error {
            throw error
        }
        return MusicProviderLibrary(
            savedTracks: [],
            playlistIDs: ["verified"],
            recentlyPlayedTrackIDs: []
        )
    }
}
