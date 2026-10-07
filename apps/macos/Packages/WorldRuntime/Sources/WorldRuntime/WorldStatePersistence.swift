import Foundation

public protocol WorldStatePersisting: Sendable {
    func save(_ state: WorldState) throws
    func load() throws -> WorldState?
    /// Readback must not renew a writer's revision lease without adopting its state.
    func readSnapshot() throws -> WorldState?
    func acceptSnapshot(_ state: WorldState) throws
}

public extension WorldStatePersisting {
    func readSnapshot() throws -> WorldState? { try load() }
    func acceptSnapshot(_ state: WorldState) throws {}
}

public struct AtomicJSONWorldStatePersistence: WorldStatePersisting, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func save(_ state: WorldState) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func load() throws -> WorldState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            WorldState.self,
            from: Data(contentsOf: fileURL)
        )
    }
}
