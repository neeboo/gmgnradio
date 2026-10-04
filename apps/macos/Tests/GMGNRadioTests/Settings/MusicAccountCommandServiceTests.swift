import Foundation
import Testing
@testable import GMGNRadio

@Test
func musicProviderSessionsUseTheLocalPrivateDirectory() {
    #expect(LocalMusicProviderSessionStore.defaultDirectoryURL.path.hasSuffix(
        "/Library/Application Support/ai.gmgn.radio/secrets/music-sessions"
    ))
}

@Test
func musicProviderStorePersistsAndSharesLocalSessions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-local-sessions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalMusicProviderSessionStore(directoryURL: directory)
    let reopened = LocalMusicProviderSessionStore(directoryURL: directory)
    let session = providerSession("MUSIC_U=test-session")

    #expect(try await store.session(for: .netease) == nil)
    try await store.removeSession(for: .netease)
    try await store.save(session, for: .netease)
    #expect(try await reopened.session(for: .netease) == session)
    #expect(try await reopened.session(for: .qqMusic) == nil)
    let file = try #require(FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ).first)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    let replacement = providerSession("MUSIC_U=replacement")
    try await reopened.save(replacement, for: .netease)
    #expect(try await store.session(for: .netease) == replacement)

    try await reopened.removeSession(for: .netease)
    #expect(try await store.session(for: .netease) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test
func musicProviderStoreReportsCorruptLocalSessions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-corrupt-sessions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalMusicProviderSessionStore(directoryURL: directory)
    try await store.save(providerSession("MUSIC_U=test-session"), for: .netease)
    let file = try #require(FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ).first)
    try Data("invalid-session".utf8).write(to: file)
    await #expect(throws: MusicProviderSessionStoreError.invalidStoredSession) {
        try await store.session(for: .netease)
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test
func musicProviderLocalWriteFailureDoesNotReportSuccessfulLogin() async throws {
    let blocked = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-blocked-sessions-\(UUID())")
    try Data().write(to: blocked)
    defer { try? FileManager.default.removeItem(at: blocked) }
    let store = LocalMusicProviderSessionStore(directoryURL: blocked)
    let service = MusicAccountCommandService(
        sessions: store,
        neteaseClient: MusicAccountClientStub(),
        qqMusicClient: MusicAccountClientStub()
    )
    await #expect(throws: (any Error).self) {
        try await service.connect(providerID: .netease, cookie: "MUSIC_U=test-session")
    }
    #expect(await service.status(providerID: .netease) == .unavailable)
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

@MainActor
@Test
func musicAccountLoginValidatesOffMainWithoutFetchingTheLibrary() async throws {
    let client = LoginOnlyMusicClient()
    let store = InMemoryMusicProviderSessionStore()
    let service = MusicAccountCommandService(sessions: store, neteaseClient: client, qqMusicClient: client)
    try await service.connect(providerID: .netease, cookie: "MUSIC_U=test-only")
    #expect(await client.validations == 1)
    #expect(await client.libraryFetches == 0)
    #expect(await client.validatedOnMain == false)
    #expect(await store.session(for: .netease) != nil)
}

private actor LoginOnlyMusicClient: AccountMusicProviderClient {
    private func isOnMainThread() -> Bool { Thread.isMainThread }
    let rejectsValidation: Bool
    init(rejectsValidation: Bool = false) { self.rejectsValidation = rejectsValidation }
    var validations = 0
    var libraryFetches = 0
    var validatedOnMain = false
    func capabilities(session: MusicProviderSession) async throws -> MusicAccountCapabilities {
        MusicAccountCapabilities(canSearchCatalog: true, canReadLibrary: true, canReadPlaylists: true,
            canReadRecentPlays: false, canPlay: true)
    }
    func validateAccount(session: MusicProviderSession) async throws {
        validations += 1
        validatedOnMain = isOnMainThread()
        if rejectsValidation { throw MusicAccountTestError.rejected }
    }
    func fetchUserLibrary(session: MusicProviderSession) async throws -> MusicProviderLibrary {
        libraryFetches += 1
        throw MusicAccountTestError.rejected
    }
    func search(_ request: MusicSearchRequest, session: MusicProviderSession) async throws -> [MusicProviderTrack] { [] }
}

@Test
func musicAccountValidationFailureDoesNotPersistAConnection() async {
    let client = LoginOnlyMusicClient(rejectsValidation: true)
    let store = InMemoryMusicProviderSessionStore()
    let service = MusicAccountCommandService(sessions: store, neteaseClient: client, qqMusicClient: client)
    await #expect(throws: MusicAccountTestError.self) {
        try await service.connect(providerID: .netease, cookie: "MUSIC_U=test-only")
    }
    #expect(await store.session(for: .netease) == nil)
    #expect(await client.libraryFetches == 0)
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
