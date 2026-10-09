import Foundation

/// Cached native projection. All authoritative selection I/O runs detached;
/// synchronous package readers never wait for HTTP or write a selection file.
final class RustPresenceSelectionClient: @unchecked Sendable {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Snapshot: Codable, Sendable {
        struct Removal: Codable, Sendable {
            let intentID: String
            let hostSessionID: String
            let kind: String
            let id: String
            let path: String
            let status: String
            let execute: Bool
        }
        let revision: Int64
        let avatarID: String
        let motionID: String
        let effectiveMotionID: String?
        let confirmedAvatarID: String
        let confirmedMotionID: String
        let pendingRenderer: Bool
        let rendererStatus: String
        let engine: String
        let policy: String
        let removal: Removal?
    }
    enum SelectionError: Error { case unavailable, requiresAsyncSelection, invalidProtocol }
    private struct State { var snapshot: Snapshot? }
    private let lock = NSLock()
    private var state = State()
    private let call: Call
    let scope: String
    private let serial = Serial()
    private let removalSession = UUID().uuidString
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: RustPresenceSelectionClient] = [:]
    static func forCatalogRoot(_ root: URL) -> RustPresenceSelectionClient {
        let scope = root.standardizedFileURL.path
        return registryLock.withLock {
            if let client = registry[scope] { return client }
            let client = RustPresenceSelectionClient(scope: scope, serviceRoot: WorldAuthorityEndpoint.taskServiceRoot())
            registry[scope] = client; return client
        }
    }
    init(scope: String, call: @escaping Call) { self.scope = scope; self.call = call }
    convenience init(scope: String, serviceRoot: URL) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: serviceRoot.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path,
            allowsLaunching: false, timeout: 5)
        self.init(scope: scope, call: { method, data in
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SelectionError.invalidProtocol }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
        })
    }
    var confirmed: Snapshot? { lock.withLock { state.snapshot } }
    private func request(_ method: String, _ data: Data) async throws -> Snapshot {
        let call = self.call
        let output = try await Task.detached { try call(method, data) }.value
        let result = try JSONDecoder().decode(Snapshot.self, from: output)
        guard result.revision >= 0 else { throw SelectionError.invalidProtocol }
        lock.withLock { if state.snapshot == nil || result.revision >= state.snapshot!.revision { state.snapshot = result } }
        return result
    }
    func bind(packages: [PresencePackage], motions: [StageMotionAsset], packageRoot: URL, motionRoot: URL,
              policy: String, supportedEngines: Set<String>, builtInMotionIDs: Set<String>,
              legacyPreferences: [String: String] = [:]) async throws -> Snapshot {
        let avatars = packages.map { package -> [String: Any] in
            let path = package.installPath.map { URL(filePath: $0).appending(path: package.manifest.entry).path }
            return ["id": package.manifest.id, "engine": package.manifest.engine.rawValue,
                    "builtIn": package.isBuiltIn, "rendererAvailable": package.rendererAvailable,
                    "path": path as Any? ?? NSNull()]
        }
        let clips = motions.map { motion -> [String: Any] in
            ["id": motion.id, "format": motion.format.rawValue, "path": motion.url?.path as Any? ?? NSNull(),
             "loop": motion.loop, "builtIn": builtInMotionIDs.contains(motion.id)]
        }
        let data = try JSONSerialization.data(withJSONObject: ["scope": scope, "requestID": UUID().uuidString,
            "packageRoot": packageRoot.path, "motionRoot": motionRoot.path, "policy": policy,
            "supportedEngines": supportedEngines.sorted(), "avatars": avatars, "motions": clips,
            "legacyPreferences": legacyPreferences])
        return try await serial.run { [self] in try await request("presence_selection_bind_catalog", data) }
    }
    @discardableResult
    func event(_ event: String, id: String? = nil, success: Bool? = nil, expectedRevision: Int64? = nil) async throws -> Snapshot {
        try await serial.run { [self] in
            guard let before = confirmed else { throw SelectionError.unavailable }
            var value: [String: Any] = ["scope": scope, "requestID": UUID().uuidString,
                "expectedRevision": expectedRevision ?? before.revision, "event": event]
            if let id { value["id"] = id }; if let success { value["success"] = success }
            return try await request("presence_selection_event", JSONSerialization.data(withJSONObject: value))
        }
    }
    /// Filesystem deletion is a native leaf, dispatched only by a fresh Rust claim.
    /// A failed/unknown HTTP response never causes a second filesystem dispatch.
    func remove(kind: String, id: String, root: URL) async throws {
        _ = try await serial.run { [self] in
            guard let before = confirmed else { throw SelectionError.unavailable }
            let intentID = UUID().uuidString
            func params(_ requestID: String, revision: Int64) -> [String: Any] {
                ["scope": scope, "requestID": requestID, "expectedRevision": revision,
                 "hostSessionID": removalSession, "intentID": intentID]
            }
            var intent = params(intentID, revision: before.revision)
            intent["kind"] = kind; intent["id"] = id
            let queued = try await request("presence_selection_remove_intent", JSONSerialization.data(withJSONObject: intent))
            let claimed = try await request("presence_selection_remove_claim", JSONSerialization.data(withJSONObject: params(UUID().uuidString, revision: queued.revision)))
            guard let action = claimed.removal, action.execute, action.status == "inflight",
                  action.intentID == intentID, action.hostSessionID == removalSession,
                  action.kind == kind, action.id == id else { throw SelectionError.invalidProtocol }
            let expected = root.appendingPathComponent(id, isDirectory: true)
            guard action.path == expected.path, expected.deletingLastPathComponent().path == root.path,
                  !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { throw SelectionError.invalidProtocol }
            let outcome: String = await Task.detached {
                let manager = FileManager.default
                do {
                    let values = try expected.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    guard values.isSymbolicLink != true, values.isDirectory == true else { return "unknown" }
                    try manager.removeItem(at: expected)
                    return "removed"
                } catch {
                    // Partial filesystem failure is uncertain; Rust independently verifies
                    // absence before it can acknowledge removal.
                    return "unknown"
                }
            }.value
            var receipt = params(UUID().uuidString, revision: claimed.revision)
            receipt["outcome"] = outcome
            let result = try await request("presence_selection_remove_receipt", JSONSerialization.data(withJSONObject: receipt))
            guard result.removal?.status == "removed" else { throw SelectionError.unavailable }
            return result
        }
    }
    private actor Serial {
        private var prior: Task<Snapshot, Error>?
        /// Upper bound on waiting for the previous authoritative call. One call
        /// that never returned used to wedge every later call behind it, so a
        /// selection's `event` never reached the daemon and the host answered
        /// `presence_selection_busy` for ever (2026-10-09).
        static let priorWaitMillis: UInt64 = 5_000
        func run(_ body: @escaping @Sendable () async throws -> Snapshot) async throws -> Snapshot {
            let previous = prior
            let task = Task {
                if let previous { await Self.awaitPrior(previous, timeoutMillis: Self.priorWaitMillis) }
                return try await body()
            }
            prior = task; return try await task.value
        }
        /// Waits for `prior` but never longer than `timeoutMillis`: the body then
        /// runs anyway, and its own transport timeout still applies to its request.
        private static func awaitPrior(_ prior: Task<Snapshot, Error>, timeoutMillis: UInt64) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(continuation)
                Task { _ = try? await prior.value; once.finish() }
                Task { try? await Task.sleep(nanoseconds: timeoutMillis * 1_000_000); once.finish() }
            }
        }

        /// Resumes the continuation exactly once, whichever of the predecessor or
        /// the deadline finishes first. The loser keeps running unattended and is
        /// never waited on — that is the whole point of the bound (a task group
        /// would structurally wait for the uncancellable `prior.value`).
        private final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            private let continuation: CheckedContinuation<Void, Never>
            init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
            func finish() {
                lock.lock(); let alreadyDone = done; done = true; lock.unlock()
                if !alreadyDone { continuation.resume() }
            }
        }
    }
}
