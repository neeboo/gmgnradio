import Foundation
import Darwin

@MainActor protocol ProductSpeechSecretStore {
    func read(provider: String) -> String?
    func write(provider: String, key: String) throws
    func legacyImported(provider: String) -> Bool
    func markLegacyImported(provider: String) throws
}

/// Native private files; never part of settings RPC or SQLite. No Keychain access.
struct FileSpeechSecretStore: ProductSpeechSecretStore {
    enum StoreError: Error { case unavailable }
    let directory: URL
    init(directory: URL = WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase: E2ERuntime.applicationSupportBase).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("secrets")) { self.directory = directory }
    private func path(_ provider: String, marker: Bool = false) throws -> URL {
        guard ["bailian", "elevenlabs", "fish"].contains(provider) else { throw StoreError.unavailable }
        return directory.appendingPathComponent("speech-" + provider + (marker ? ".imported" : ".key"))
    }
    private func regular(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size <= 8192
    }
    private func get(_ provider: String, marker: Bool = false) -> String? {
        guard let file = try? path(provider, marker: marker), regular(file), let bytes = try? Data(contentsOf: file), bytes.count <= 8192 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    private func put(_ provider: String, _ value: String, marker: Bool = false) throws {
        let file = try path(provider, marker: marker)
        guard value.utf8.count <= 8192, !value.contains("\0") else { throw StoreError.unavailable }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw StoreError.unavailable }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        guard chmod(directory.path, 0o700) == 0 else { throw StoreError.unavailable }
        var info = stat()
        if lstat(file.path, &info) == 0 && !regular(file) { throw StoreError.unavailable }
        let temporary = directory.appendingPathComponent(".speech-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else { throw StoreError.unavailable }
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, file.path) == 0 else { throw StoreError.unavailable }
    }
    func read(provider: String) -> String? { get(provider) }
    func write(provider: String, key: String) throws { try put(provider, key) }
    func legacyImported(provider: String) -> Bool { get(provider, marker: true) == "true" }
    func markLegacyImported(provider: String) throws { try put(provider, "true", marker: true) }
}
