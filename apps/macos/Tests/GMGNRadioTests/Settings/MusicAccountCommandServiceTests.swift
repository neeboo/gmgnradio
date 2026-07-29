import Foundation
import Testing
@testable import GMGNRadio

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
