import Foundation

/// Native reads are limited to one-time original-file observations. Rust owns selection and writes.
actor RustMusicProviderSessionStore: MusicProviderSessionStore {
    private let authority: RustMusicAccountClient
    private let legacyDirectory: URL
    private let legacyOverrideDirectory: URL?
    private let legacyIsolatedDirectory: URL?
    init(authority: RustMusicAccountClient, legacyDirectory: URL,
         legacyOverrideDirectory: URL? = nil, legacyIsolatedDirectory: URL? = nil) {
        self.authority = authority; self.legacyDirectory = legacyDirectory
        self.legacyOverrideDirectory = legacyOverrideDirectory; self.legacyIsolatedDirectory = legacyIsolatedDirectory
    }
    func session(for providerID: MusicProviderID) async throws -> MusicProviderSession? {
        let current = try await authority.session(providerID)
        if !current.useLegacy { return current.session }
        let name = providerID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        let override = legacyOverrideDirectory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name + ".override").path) } ?? false
        let directory = override ? legacyIsolatedDirectory ?? legacyDirectory : legacyDirectory
        let file = directory.appendingPathComponent(name + ".json")
        let observed: MusicProviderSession?
        if FileManager.default.fileExists(atPath: file.path) {
            observed = try JSONDecoder().decode(MusicProviderSession.self, from: Data(contentsOf: file))
        } else { observed = nil }
        _ = try await authority.importLegacy(providerID, session: observed, disabled: override && observed == nil)
        return try await authority.session(providerID).session
    }
    func save(_ session: MusicProviderSession, for providerID: MusicProviderID) async throws {
        // Direct credential writes cannot bypass account validation.
        throw MusicAccountConnectionError.accountCannotPlay
    }
    func removeSession(for providerID: MusicProviderID) async throws { _ = try await authority.disconnect(providerID) }
}
