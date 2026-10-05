import Foundation

/// Original sessions are read-only fallback. Connect/disconnect affect only the
/// Unity root, including a durable tombstone that prevents fallback after logout.
actor UnityMusicSessions: MusicProviderSessionStore {
    let directory: URL
    private let isolated: LocalMusicProviderSessionStore
    private let overrides: URL
    init(directory: URL, root: URL) {
        self.directory = directory
        overrides = root.appendingPathComponent("secrets/music-overrides", isDirectory: true)
        isolated = LocalMusicProviderSessionStore(directoryURL: root.appendingPathComponent("secrets/music-sessions", isDirectory: true))
    }
    private func marker(for provider: MusicProviderID) -> URL {
        overrides.appendingPathComponent(provider.rawValue.utf8.map { String(format: "%02x", $0) }.joined() + ".override")
    }
    func session(for providerID: MusicProviderID) async throws -> MusicProviderSession? {
        if FileManager.default.fileExists(atPath: marker(for: providerID).path) { return try await isolated.session(for: providerID) }
        let name = providerID.rawValue.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MusicProviderSession.self, from: Data(contentsOf: url))
    }
    private func override(_ provider: MusicProviderID) throws {
        try FileManager.default.createDirectory(at: overrides, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: marker(for: provider), options: .atomic)
    }
    func save(_ session: MusicProviderSession, for providerID: MusicProviderID) async throws {
        try await isolated.save(session, for: providerID); try override(providerID)
    }
    func removeSession(for providerID: MusicProviderID) async throws {
        try override(providerID); try await isolated.removeSession(for: providerID)
    }
    func isDisabled(_ providerID: MusicProviderID) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: marker(for: providerID).path) else { return false }
        return try await isolated.session(for: providerID) == nil
    }
}
