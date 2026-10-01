// Test-only daemon substitute. Every HTTP request is intercepted by the caller's URLProtocol.
// This verifies Coordinator/Facade behavior, not Rust process lifetime, IPC or concurrency.
import Foundation
import CryptoKit

@MainActor
final class WishMachineDaemonFixture: PropTaskDaemonConnecting {
    var onEvent: ((PropTaskDaemonEvent) -> Void)?
    var onSnapshot: ((PropTaskDaemonSnapshot) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private(set) var jobs: [PropGenerationRecord] = []
    private(set) var contexts: [UUID: PropTaskContext] = [:]
    var rejectSubmit = false
    private var sequence: UInt64 = 0
    private let directory: URL
    private let session: URLSession
    private var client: PropGenerationClient?
    private var active: Set<UUID> = []
    private var readable = true

    init(directory: URL, session: URLSession) {
        self.directory = directory
        self.session = session
        let file = directory.appendingPathComponent("tasks.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { jobs = try JSONDecoder().decode([PropGenerationRecord].self, from: Data(contentsOf: file)) }
            catch { readable = false }
        }
    }

    func configure(endpoint: URL, token: String) async throws {
        guard readable else { throw PropGenerationError.historyUnavailable }
        client = try PropGenerationClient(endpoint: endpoint, token: token, session: session)
        onSnapshot?(.init(jobs: jobs, sequence: sequence))
    }

    func clearConfiguration() { client = nil }
    func disconnect() { /* A client's disappearance does not cancel accepted work. */ }

    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double) async throws -> PropGenerationRecord {
        try await submit(id: id, endpoint: endpoint, name: name, png: png, source: source,
            heightMeters: heightMeters, context: nil)
    }

    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double, context: PropTaskContext?) async throws -> PropGenerationRecord {
        guard readable, let client else { throw PropGenerationError.missingToken }
        if rejectSubmit { throw PropGenerationError.invalidResponse }
        if let context { contexts[id] = context }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        if let known = jobs.first(where: { $0.id == id }) {
            guard known.endpoint == endpoint, known.imageSHA256 == digest, known.name == name,
                  known.source == source, known.heightMeters == heightMeters else { throw PropGenerationError.invalidInput }
            return known
        }
        try PropGenerationClient.validateInput(png: png, name: name, source: source, heightMeters: heightMeters)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(id.uuidString + ".png")
        try png.write(to: path, options: .atomic)
        let record = PropGenerationRecord(id: id, name: name, endpoint: endpoint, imagePath: path.path,
            imageSHA256: digest, heightMeters: heightMeters, source: source, idempotencyKey: id.uuidString,
            backendStage: "queued", cancelRequested: false)
        jobs.append(record)
        try publish(id)
        startSubmit(id, client: client)
        return record // Durable local queue acceptance, never waits for fixture HTTP response.
    }

    func retry(id: UUID) async throws -> PropGenerationRecord {
        guard let client, let index = jobs.firstIndex(where: { $0.id == id }) else { throw PropGenerationError.missingTask }
        if jobs[index].receipt == nil {
            jobs[index].backendStage = "queued"
            jobs[index].lastError = nil
            try publish(id)
            startSubmit(id, client: client)
        } else if jobs[index].receipt?.state == .completed && jobs[index].localModelPath == nil {
            await advance(id, client: client)
        }
        return jobs.first { $0.id == id }!
    }

    func cancel(id: UUID) async throws -> PropGenerationRecord {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw PropGenerationError.missingTask }
        jobs[index].cancelRequested = true
        if jobs[index].receipt == nil && !active.contains(id) { jobs[index].backendStage = "cancelled" }
        else { jobs[index].backendStage = "cancel_requested" }
        try publish(id)
        if let client, jobs[index].receipt != nil { await advance(id, client: client) }
        return jobs.first { $0.id == id }!
    }

    func snapshot() async throws -> PropTaskDaemonSnapshot {
        guard readable else { throw PropGenerationError.historyUnavailable }
        // The fake daemon runs one deterministic backend cycle before answering the local snapshot.
        if let client {
            for id in jobs.map(\.id) where !active.contains(id) { await advance(id, client: client) }
        }
        return .init(jobs: jobs, sequence: sequence)
    }

    /// Explicit fake-backend push, used to prove a completed task reaches the app without a model read.
    func pushBackendChanges() async {
        guard let client else { return }
        for id in jobs.map(\.id) where !active.contains(id) { await advance(id, client: client) }
    }

    private func startSubmit(_ id: UUID, client: PropGenerationClient) {
        guard active.insert(id).inserted else { return }
        Task { @MainActor [self] in
            defer { active.remove(id) }
            guard let record = jobs.first(where: { $0.id == id }) else { return }
            do {
                let receipt = try await client.submit(png: Data(contentsOf: URL(fileURLWithPath: record.imagePath)),
                    name: record.name, source: record.source, heightMeters: record.heightMeters,
                    idempotencyKey: record.idempotencyKey)
                try update(id, receipt: receipt)
            } catch {
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
                jobs[index].backendStage = "submission_uncertain"
                // 与真实守护进程逐字一致：传输失败（含提交响应丢失）在 provider 层映射为
                // `network_unavailable`（services/gmgn-taskd/src/provider.rs:45），调度器此后
                // 不再自动重发 `submission_uncertain`（daemon.rs:770/:787）。宿主据此区分
                // "网络类未知结果"（可在恢复后确认）与"真实被拒/未授权"（绝不重发）。
                jobs[index].lastError = "network_unavailable"
                try? publish(id)
            }
            if let current = jobs.first(where: { $0.id == id }),
               current.cancelRequested == true || current.receipt?.state == .completed {
                await advance(id, client: client)
            }
        }
    }

    private func advance(_ id: UUID, client: PropGenerationClient) async {
        guard let record = jobs.first(where: { $0.id == id }), let receipt = record.receipt else { return }
        do {
            if !receipt.state.isTerminal {
                let refreshed: PropGenerationReceipt
                if record.cancelRequested == true && receipt.state != .cancelRequested {
                    refreshed = try await client.cancel(id: receipt.id)
                } else { refreshed = try await client.status(id: receipt.id) }
                try update(id, receipt: refreshed)
            }
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  let completed = jobs[index].receipt, completed.state == .completed,
                  jobs[index].localModelPath == nil else { return }
            let bytes = try await client.download(completed)
            let path = directory.appendingPathComponent(id.uuidString + ".glb")
            try bytes.write(to: path, options: .atomic)
            jobs[index].localModelPath = path.path
            jobs[index].backendStage = "ready"
            jobs[index].lastError = nil
            try publish(id)
        } catch {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].lastError = "fixture backend observation/download failed"
            try? publish(id)
        }
    }

    private func update(_ id: UUID, receipt: PropGenerationReceipt) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].receipt = receipt
        jobs[index].lastError = nil
        switch receipt.state {
        case .completed: jobs[index].backendStage = jobs[index].localModelPath == nil ? "downloading" : "ready"
        case .failed: jobs[index].backendStage = "failed"
        case .cancelled: jobs[index].backendStage = "cancelled"
        case .interrupted: jobs[index].backendStage = "interrupted"
        case .cancelRequested: jobs[index].backendStage = "cancel_requested"
        default: jobs[index].backendStage = "running"
        }
        try publish(id)
    }

    private func publish(_ id: UUID) throws {
        guard readable, let record = jobs.first(where: { $0.id == id }) else { throw PropGenerationError.historyUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: directory.appendingPathComponent("tasks.json"), options: .atomic)
        sequence += 1
        onEvent?(.init(sequence: sequence, job: record))
    }
}

@MainActor
func fixtureWishStore(directory: URL, session: URLSession) -> PropGenerationStore {
    PropGenerationStore(directory: directory, session: session,
        daemonClient: WishMachineDaemonFixture(directory: directory, session: session))
}
