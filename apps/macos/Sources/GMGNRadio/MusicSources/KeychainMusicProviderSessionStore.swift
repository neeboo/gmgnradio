import Foundation

enum MusicProviderSessionStoreError: Error, Equatable, LocalizedError {
    case invalidStoredSession

    var errorDescription: String? {
        "本机保存的音乐登录信息已损坏，请重新登录。"
    }
}

// The historical filename remains in the Xcode project. This implementation
// uses only local files; it never attempts to migrate old system credentials.
actor LocalMusicProviderSessionStore: MusicProviderSessionStore {
    static let defaultDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai.gmgn.radio/secrets/music-sessions", isDirectory: true)

    private let directoryURL: URL
    private let files = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directoryURL: URL = LocalMusicProviderSessionStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    func session(for providerID: MusicProviderID) throws -> MusicProviderSession? {
        let url = sessionURL(for: providerID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        do {
            return try decoder.decode(MusicProviderSession.self, from: data)
        } catch {
            throw MusicProviderSessionStoreError.invalidStoredSession
        }
    }

    func save(_ session: MusicProviderSession, for providerID: MusicProviderID) throws {
        let data = try encoder.encode(session)
        try files.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let url = sessionURL(for: providerID)
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func removeSession(for providerID: MusicProviderID) throws {
        do {
            try files.removeItem(at: sessionURL(for: providerID))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // Removing an already-disconnected provider is idempotent.
        }
    }

    private func sessionURL(for providerID: MusicProviderID) -> URL {
        // Provider IDs are extensible strings. Hex encoding keeps each session
        // inside this directory even when an ID contains a path separator.
        let filename = providerID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename + ".json")
    }
}
