import Foundation

/// Thin provider-session projection over the same Rust account authority.
actor UnityMusicSessions: MusicProviderSessionStore {
    let directory: URL
    private let store: RustMusicProviderSessionStore
    private let authority: RustMusicAccountClient
    init(directory: URL, root: URL, authority: RustMusicAccountClient) {
        self.directory = directory
        self.authority = authority
        store = RustMusicProviderSessionStore(authority: authority, legacyDirectory: directory,
            legacyOverrideDirectory: root.appendingPathComponent("secrets/music-overrides"),
            legacyIsolatedDirectory: root.appendingPathComponent("secrets/music-sessions"))
    }
    func session(for providerID: MusicProviderID) async throws -> MusicProviderSession? { try await store.session(for: providerID) }
    func isDisabled(_ providerID: MusicProviderID) async throws -> Bool {
        _ = try await store.session(for: providerID)
        return try await authority.account(providerID).disabled
    }
    func save(_ session: MusicProviderSession, for providerID: MusicProviderID) async throws { try await store.save(session, for: providerID) }
    func removeSession(for providerID: MusicProviderID) async throws { try await store.removeSession(for: providerID) }
}
