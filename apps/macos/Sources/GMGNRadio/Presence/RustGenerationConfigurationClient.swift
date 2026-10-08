import Foundation
import Darwin

/// A confirmed metadata projection. Native files transport credentials; they never enter RPC/SQL.
@MainActor final class RustGenerationConfigurationClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Snapshot: Codable, Sendable {
        let revision: Int64; let endpoint: String?; let secretRef: String?
        let imported: Bool; let configured: Bool
    }
    enum ConfigurationError: Error { case invalidProtocol, secretUnavailable }
    private let call: Call
    private let secretRoot: URL
    private var mutation: Task<Snapshot, Error>?
    private(set) var confirmed: Snapshot?
    init(secretRoot: URL, call: @escaping Call) { self.secretRoot = secretRoot; self.call = call }
    convenience init(root: URL, allowsLaunching: Bool = true) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path,
            allowsLaunching: allowsLaunching, timeout: 5)
        self.init(secretRoot: root.deletingLastPathComponent().appendingPathComponent("secrets"), call: { method, data in
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigurationError.invalidProtocol }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: object))
        })
    }
    private func request(_ method: String, _ params: [String: Any]) async throws -> Snapshot {
        let data = try JSONSerialization.data(withJSONObject: params), call = self.call
        let response = try await Task.detached { try call(method, data) }.value
        let value = try JSONDecoder().decode(Snapshot.self, from: response)
        guard value.revision >= 0, value.configured == (value.endpoint != nil && value.secretRef != nil),
              value.secretRef == nil || UUID(uuidString: value.secretRef!) != nil else { throw ConfigurationError.invalidProtocol }
        confirmed = value; return value
    }
    private nonisolated static func stage(_ bytes: Data, directory: URL) throws -> String {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ConfigurationError.secretUnavailable }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        guard chmod(directory.path, 0o700) == 0 else { throw ConfigurationError.secretUnavailable }
        let reference = UUID().uuidString.lowercased()
        let path = directory.appendingPathComponent("generation-\(reference).secret").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConfigurationError.secretUnavailable }
        defer { Darwin.close(descriptor) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ConfigurationError.secretUnavailable }; offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ConfigurationError.secretUnavailable }
        return reference
    }
    private nonisolated static func rawLegacy(_ url: URL?) throws -> (Bool, Data?) {
        guard let url else { return (false, nil) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return (false, nil) }; throw ConfigurationError.secretUnavailable
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 32768 else { return (true, nil) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return (true, nil) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        return (true, data.count <= 32768 ? data : nil)
    }
    func load(currentFile: URL, legacyFile: URL?) async throws -> Snapshot {
        let prior = mutation
        let work = Task<Snapshot, Error> { [self] in
            if let prior { _ = try? await prior.value }
            let before = try await request("generation_configuration_read", [:])
            if before.imported { return before }
            let directory = secretRoot
            let facts = try await Task.detached {
                let current = try Self.rawLegacy(currentFile)
                // A present current file forbids even reading legacy credentials.
                let legacy = current.0 ? (false, Optional<Data>.none) : try Self.rawLegacy(legacyFile)
                return (current.0, try current.1.map { try Self.stage($0, directory: directory) }, try legacy.1.map { try Self.stage($0, directory: directory) })
            }.value
            return try await request("generation_configuration_import", ["requestID": UUID().uuidString,
                "expectedRevision": before.revision, "currentExists": facts.0,
                "currentRef": facts.1 as Any? ?? NSNull(), "legacyRef": facts.2 as Any? ?? NSNull()])
        }
        mutation = work; return try await work.value
    }
    func save(endpoint: String, replacementToken: String) async throws -> Snapshot {
        let prior = mutation
        let work = Task<Snapshot, Error> { [self] in
            if let prior { _ = try? await prior.value }
            let before = try await request("generation_configuration_read", [:]), directory = secretRoot
            let reference = replacementToken.isEmpty ? nil : try await Task.detached {
                try Self.stage(Data(replacementToken.utf8), directory: directory)
            }.value
            return try await request("generation_configuration_save", ["requestID": UUID().uuidString,
                "expectedRevision": before.revision, "endpoint": endpoint,
                "tokenRef": reference as Any? ?? NSNull()])
        }
        mutation = work; return try await work.value
    }
    func configuration(_ snapshot: Snapshot) async throws -> PropGenerationConfiguration? {
        guard snapshot.configured, let endpoint = snapshot.endpoint, let reference = snapshot.secretRef,
              UUID(uuidString: reference) != nil, let url = URL(string: endpoint) else { return nil }
        let path = secretRoot.appendingPathComponent("generation-\(reference).secret")
        let bytes = try await Task.detached { try Self.rawLegacy(path) }.value
        guard let data = bytes.1, data.count <= 8192, let token = String(data: data, encoding: .utf8) else { throw ConfigurationError.secretUnavailable }
        return try PropGenerationConfiguration(endpoint: url, token: token)
    }
    func validatedConfiguration(endpoint: String) async throws -> PropGenerationConfiguration? {
        if let mutation { _ = try? await mutation.value }
        let value = try await request("generation_configuration_read", ["endpoint": endpoint])
        return try await configuration(value)
    }
}
