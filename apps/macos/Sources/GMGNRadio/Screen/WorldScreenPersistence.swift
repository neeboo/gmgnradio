import Foundation

/// Confirmed Codable projections only. Rust imports the legacy file and owns every mutation.
actor WorldScreenPersistence {
    struct Record: Codable, Equatable, Sendable {
        var definitions: [String: WorldScreenDefinition] = [:]
        var contents: [String: WorldScreenContent] = [:]
    }
    private let client: RustScreenStateClient
    private let legacyURL: URL
    private var snapshots: [String: RustScreenStateClient.Snapshot] = [:]
    private var importTask: Task<Void, Error>?
    private var tails: [String: Task<RustScreenStateClient.Snapshot, Error>] = [:]
    init(fileURL: URL, endpointFile: URL? = nil) {
        legacyURL = fileURL
        client = RustScreenStateClient(endpointFile: endpointFile ?? fileURL.deletingLastPathComponent().appendingPathComponent("TaskService/taskd.endpoint.json"))
    }
    private func ensureImported() async throws {
        if importTask == nil { let client = client, legacy = legacyURL; importTask = Task { try await client.importLegacy(legacy) } }
        try await importTask!.value
    }
    private func loaded(_ worldID: String) async throws -> RustScreenStateClient.Snapshot {
        try await ensureImported()
        if let value = snapshots[worldID] { return value }
        let value = try await client.read(worldID: worldID)
        if let newer = snapshots[worldID], newer.revision > value.revision { return newer }
        snapshots[worldID] = value; return value
    }
    func record(worldID: String) async throws -> Record {
        if let tail = tails[worldID] { _ = await tail.result }
        return try await loaded(worldID).record
    }
    /// Explicit retry/readback; failed reads never replace an already confirmed snapshot.
    func reload(worldID: String) async throws -> Record {
        if let tail = tails[worldID] { _ = await tail.result }
        importTask = nil; try await ensureImported()
        let value = try await client.read(worldID: worldID)
        if let newer = snapshots[worldID], newer.revision > value.revision { return newer.record }
        snapshots[worldID] = value; return value.record
    }
    private func mutate(worldID: String, objectID: String, operation: String, value: Data?) async throws {
        guard !worldID.isEmpty else { throw RustScreenStateError.invalidResponse }
        let prior = tails[worldID], requestID = UUID().uuidString
        let task = Task { [self] in
            if let prior { _ = await prior.result }
            let current = try await loaded(worldID)
            let next = try await client.mutate(worldID: worldID, objectID: objectID, expectedRevision: current.revision,
                requestID: requestID, operation: operation, value: value)
            snapshots[worldID] = next; return next
        }
        tails[worldID] = task; _ = try await task.value
    }
    func setDefinition(_ definition: WorldScreenDefinition?, objectID: String, worldID: String) async throws {
        try await mutate(worldID: worldID, objectID: objectID, operation: "definition", value: try definition.map { try JSONEncoder().encode($0) })
    }
    func setContent(_ content: WorldScreenContent, objectID: String, worldID: String) async throws {
        try await mutate(worldID: worldID, objectID: objectID, operation: "content", value: try JSONEncoder().encode(content))
    }
    func remove(objectID: String, worldID: String) async throws { try await mutate(worldID: worldID, objectID: objectID, operation: "remove", value: nil) }
}
