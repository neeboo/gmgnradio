import Foundation

struct PropGenerationConfiguration: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let endpoint: URL
    let token: String

    init(endpoint: URL, token: String) throws {
        let client = try PropGenerationClient(endpoint: endpoint, token: token)
        self.endpoint = client.endpoint
        self.token = token
    }

    var description: String { "PropGenerationConfiguration(endpoint: \(endpoint), token: <redacted>)" }
    var debugDescription: String { description }
}

/// App-private credentials are deliberately separate from task history and shared world packages.
struct PropGenerationConfigurationStore: Sendable {
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai.gmgn.radio/secrets")
        .appendingPathComponent("prop-generation.json")

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    private struct StoredValue: Codable {
        let endpoint: URL
        let token: String
    }

    func load() throws -> PropGenerationConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let value = try JSONDecoder().decode(StoredValue.self, from: Data(contentsOf: fileURL))
        return try PropGenerationConfiguration(endpoint: value.endpoint, token: value.token)
    }

    func save(_ configuration: PropGenerationConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(StoredValue(endpoint: configuration.endpoint, token: configuration.token))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

extension Notification.Name {
    static let propGenerationConfigurationDidChange = Notification.Name("ai.gmgn.radio.propGenerationConfigurationDidChange")
}
