import Foundation
import Darwin

/// Private HTTP daemon fixture. The model runner remains a native test leaf;
/// every intent update is authorized by a real SQLite-backed scheduler ticket.
final class ResidentIntentDaemonFixture: @unchecked Sendable {
    private struct Endpoint: Decodable { let address: String; let token: String }
    private struct Envelope: Decodable {
        struct Failure: Decodable { let code: String }
        let id: String?; let result: ResidentStateJSON?; let error: Failure?
    }
    private final class Response: @unchecked Sendable {
        let lock = NSLock(); var data: Data?; var error: Error?
        func receive(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func fail(_ value: Error) { lock.lock(); error = value; lock.unlock() }
    }
    let directory: URL
    private var process: Process?
    init() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/gmgn-intent-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TASKD_BIN"] ?? "target/debug/gmgn-taskd")
        process.arguments = ["--root", directory.path, "--endpoint-file", directory.appendingPathComponent("endpoint.json").path, "--concurrency", "1"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        try process.run(); self.process = process
        // Fatal Swift assertions skip defer/deinit. This bounded ownership
        // watcher stops only this fixture child after its host exits.
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null && kill -0 \(process.processIdentifier) 2>/dev/null; do sleep 1; done; kill -TERM \(process.processIdentifier) 2>/dev/null || true"]
        watcher.standardOutput = FileHandle.nullDevice; watcher.standardError = FileHandle.nullDevice
        try watcher.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            if (try? endpoint()) != nil { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop(); throw ResidentStateError.invalidResponse
    }
    private func endpoint() throws -> Endpoint {
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: directory.appendingPathComponent("endpoint.json")))
        guard endpoint.address.hasPrefix("127.0.0.1:"), UUID(uuidString: endpoint.token) != nil else { throw ResidentStateError.invalidResponse }
        return endpoint
    }
    func call(_ method: String, _ params: Data) throws -> Data {
        let endpoint = try endpoint(), id = UUID().uuidString
        let tree = try JSONSerialization.jsonObject(with: params)
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/rpc")!, timeoutInterval: 8)
        request.httpMethod = "POST"; request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": tree])
        let response = Response(), signal = DispatchSemaphore(value: 0)
        let transport = TaskdHTTPTransport(streaming: false, receive: { response.receive($0) }, completion: { error in
            if let error { response.fail(error) }; signal.signal()
        })
        transport.start(request)
        guard signal.wait(timeout: .now() + 10) == .success else { transport.cancel(); throw ResidentStateError.invalidResponse }
        if let error = response.error { throw error }
        guard let data = response.data else { throw ResidentStateError.invalidResponse }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.id == id else { throw ResidentStateError.invalidResponse }
        if let error = envelope.error {
            print("FIXTURE RPC ERROR: \(method): \(error.code)"); fflush(nil)
            throw ResidentStateError.daemon(error.code)
        }
        guard let value = envelope.result else { throw ResidentStateError.invalidResponse }
        return try JSONEncoder().encode(value)
    }
    func stop() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil
    }
    deinit { stop(); try? FileManager.default.removeItem(at: directory) }
}
@MainActor private final class ResidentIntentFixtureTransport: ResidentStateTransport {
    let daemon: ResidentIntentDaemonFixture
    init(_ daemon: ResidentIntentDaemonFixture) { self.daemon = daemon }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        let input = try JSONEncoder().encode(params), daemon = self.daemon
        let data = try await Task.detached { try daemon.call(method, input) }.value
        return try JSONDecoder().decode([String: ResidentStateJSON].self, from: data)
    }
}
@MainActor var residentIntentFixtureDaemon: ResidentIntentDaemonFixture?
@MainActor private var residentIntentFixtureSchedulers: [RustResidentSchedulerClient] = []
@MainActor private final class FixtureLoopReference {
    weak var loop: ResidentAgentLoop?
    init(_ loop: ResidentAgentLoop) { self.loop = loop }
}
@MainActor private var residentIntentFixtureLoops: [String: FixtureLoopReference] = [:]
/// Called only by the private provider after its exact invocation continuation
/// has returned cancellation. There are no remote side effects in this leaf.
@MainActor func fixtureNativeCancellationReturned(runID: UUID, awaitProjection: Bool = true) async throws {
    guard let daemon = residentIntentFixtureDaemon else { throw ResidentStateError.invalidResponse }
    for scheduler in residentIntentFixtureSchedulers {
        let params = try JSONSerialization.data(withJSONObject: ["worldID": scheduler.worldID, "residentScope": scheduler.residentScope])
        let data = try await Task.detached { try daemon.call("agent_loop_read", params) }.value
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = state["events"] as? [[String: Any]] else { throw ResidentStateError.invalidResponse }
        guard let event = events.first(where: { $0["runID"] as? String == runID.uuidString }) else { continue }
        guard let eventID = event["eventID"] as? String,
              event["hostSessionID"] as? String == scheduler.hostSessionID,
              ["claimed", "cancel_requested"].contains(event["state"] as? String ?? "") else { throw ResidentStateError.invalidResponse }
        let receipt = try await scheduler.finish(.init(eventID: eventID, runID: runID, hostSessionID: scheduler.hostSessionID),
            outcome: "cancelled", invocationStarted: true, cancellationConfirmed: true)
        guard case .terminal = receipt else { throw ResidentStateError.invalidResponse }
        if let loop = residentIntentFixtureLoops[scheduler.hostSessionID]?.loop {
            loop.reconcileFinishedRun()
            // In-flight steering legitimately keeps presentation settlement
            // open even after the provider's real terminal receipt is durable.
            if !awaitProjection { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while loop.snapshot.runID == runID, ProcessInfo.processInfo.systemUptime < deadline {
                loop.reconcileFinishedRun()
                try await Task.sleep(for: .milliseconds(50))
            }
            guard loop.snapshot.runID != runID else { throw ResidentStateError.invalidResponse }
        }
        return
    }
    throw ResidentStateError.invalidResponse
}
@MainActor func fixtureResidentLoop(
    now: @escaping @MainActor () -> Date = { Date() },
    configuration: ResidentAgentLoop.Configuration = .init(),
    run: @escaping @MainActor (ResidentAgentLoop.Input) async throws -> String,
    steer: @escaping @MainActor (String) async -> ResidentSteeringDelivery = { _ in .notDelivered },
    onReply: @escaping @MainActor (String) -> Void = { _ in },
    onFailure: @escaping @MainActor (String) -> Void = { _ in },
    onInterruption: @escaping @MainActor ([UUID], ResidentChatTurn.Interruption) -> Void = { _, _ in },
    onChange: @escaping @MainActor () -> Void = {},
    onCancel: @escaping @MainActor () -> Void = {},
    onUserStop: @escaping @MainActor () -> Void = {}
) async -> ResidentAgentLoop {
    guard let daemon = residentIntentFixtureDaemon else { fatalError("private intent fixture was not started") }
    let scope = ResidentStateScope(worldID: "fixture-loop-\(UUID().uuidString)", residentScope: "resident")
    let scheduler = RustResidentSchedulerClient(worldID: scope.worldID, residentScope: scope.residentScope,
        call: { method, params in try daemon.call(method, params) })
    residentIntentFixtureSchedulers.append(scheduler)
    let loop = ResidentAgentLoop(now: now, configuration: configuration, run: run, steer: steer,
        onReply: onReply, onFailure: onFailure, onInterruption: onInterruption, onChange: onChange,
        onCancel: onCancel, onUserStop: onUserStop, rustScheduler: scheduler, rustSchedulerAvailability: { true },
        rustSteer: { input in await steer(input.text) })
    loop.bindMemory(store: ResidentMemoryStore(client: ResidentStateClient(transport: ResidentIntentFixtureTransport(daemon))), scope: scope)
    residentIntentFixtureLoops[scheduler.hostSessionID] = FixtureLoopReference(loop)
    // Formal bootstrap performs this authority read before autonomous claims.
    // Empty private scope is a real Rust receipt, never a synthetic local plan.
    _ = await loop.restoreMemory()
    return loop
}
