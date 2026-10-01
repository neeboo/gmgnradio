import Foundation
import Combine

struct PropGenerationRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let endpoint: URL
    let imagePath: String
    let imageSHA256: String
    let heightMeters: Double
    /// 提交时声明的**尺寸意图**（守护进程 `sizeIntent`）。可选、纯增量：守护进程在缺失时
    /// 根本不写这个键，于是解码得到 nil —— 与今天逐字节一致（app 仍按请求高度自动推断）。
    var sizeIntent: PropSizeIntent?
    let source: PropGenerationSource
    let idempotencyKey: String
    var receipt: PropGenerationReceipt?
    var localModelPath: String?
    /// 守护进程已核验并落盘的**碰撞代理**路径（`<id>.collider.glb`）。
    ///
    /// 纯增量：回执里没有碰撞字段时守护进程根本不写这一位，于是解码得到 nil —— 与今天
    /// 逐字节一致。有它才说明"生成侧给了代理，而且守护进程已经把它核验并落盘"。
    var localCollisionPath: String?
    var lastError: String?
    var backendStage: String?
    var cancelRequested: Bool?
    var context: PropTaskContext?
}

/// Read-only projection of Rust-owned jobs. Image decoding remains local to macOS.
@MainActor final class PropGenerationStore: ObservableObject {
    @Published private(set) var jobs: [PropGenerationRecord] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    var onChange: (@MainActor () -> Void)?
    var onMessage: ((String, PropTaskMessage) -> Void)?
    private let daemon: any PropTaskDaemonConnecting
    private var configuration: (endpoint: URL, token: String)?
    private var configurationGeneration: UInt64 = 0
    private var sequence: UInt64 = 0
    private var hasSnapshot = false
    private var jobVersions: [UUID: UInt64] = [:]
    private var creating: Set<UUID> = []
    private var operations = 0

    // session remains source compatible; it is never used for task networking.
    init(directory: URL? = nil, session: URLSession = .shared, daemonClient: (any PropTaskDaemonConnecting)? = nil) {
        if let daemonClient { daemon = daemonClient }
        else if let directory {
            daemon = PropTaskDaemonClient(root: directory.appendingPathComponent("TaskService"), legacyRoot: directory)
        } else { daemon = PropTaskDaemonClient() }
        daemon.onSnapshot = { [weak self] in self?.apply($0) }
        daemon.onEvent = { [weak self] in self?.apply($0) }
        daemon.onDisconnect = { [weak self] message in self?.errorMessage = message; self?.onChange?() }
        if let messages = daemon as? any PropTaskMessageConnecting {
            messages.onMessage = { [weak self] consumer, message in self?.onMessage?(consumer, message) }
        }
    }
    func configure(endpoint: URL, token: String) throws {
        clearConfiguration()
        try PropTaskDaemonClient.validateConfiguration(endpoint: endpoint, token: token)
        let endpoint = try PropTaskDaemonClient.normalizedEndpoint(endpoint)
        configuration = (endpoint, token)
        let generation = configurationGeneration
        Task { [weak self] in
            guard let self, self.configurationGeneration == generation else { return }
            do {
                try await self.daemon.configure(endpoint: endpoint, token: token)
                guard self.configurationGeneration == generation else { return }
                await self.refreshSnapshot()
            } catch {
                guard self.configurationGeneration == generation else { return }
                self.errorMessage = self.message(error)
            }
        }
    }
    func clearConfiguration() {
        configurationGeneration += 1
        configuration = nil
        daemon.clearConfiguration()
    }
    @discardableResult func create(imageURL: URL, name: String, author: String, license: String,
        heightMeters: Double, sizeIntent: PropSizeIntent? = nil, id: UUID = UUID(), context: PropTaskContext? = nil) async -> UUID? {
        guard !creating.contains(id), !jobs.contains(where: { $0.id == id }) else {
            errorMessage = PropGenerationError.knownSubmission.localizedDescription; return nil
        }
        creating.insert(id); begin()
        defer { creating.remove(id); end() }
        do {
            guard let configuration else { throw PropGenerationError.missingToken }
            let generation = configurationGeneration
            let png = try await PropImagePreparation.prepare(url: imageURL)
            try Task.checkCancellation()
            guard generation == configurationGeneration else { throw PropGenerationError.configurationChangedBeforeSubmit }
            let source = PropGenerationSource(author: author, license: license)
            try PropGenerationClient.validateInput(png: png, name: name, source: source,
                heightMeters: heightMeters, sizeIntent: sizeIntent)
            try await daemon.configure(endpoint: configuration.endpoint, token: configuration.token)
            try Task.checkCancellation()
            guard generation == configurationGeneration else { throw PropGenerationError.configurationChangedBeforeSubmit }
            let version = jobVersions[id]
            let record = try await daemon.submit(id: id, endpoint: configuration.endpoint, name: name, png: png,
                source: source, heightMeters: heightMeters, sizeIntent: sizeIntent, context: context)
            guard record.id == id, record.endpoint == configuration.endpoint, record.idempotencyKey == id.uuidString else {
                throw PropGenerationError.invalidResponse
            }
            if jobVersions[id] == version { upsert(record) }
            errorMessage = nil
            return id // Only a durable Rust queue ACK accepts a wish.
        } catch { errorMessage = message(error); return nil }
    }
    func refreshSnapshot() async {
        do { apply(try await daemon.snapshot()); errorMessage = nil }
        catch { errorMessage = message(error) }
    }
    func refresh(id: UUID) async { await refreshSnapshot() }
    func retrySubmission(id: UUID) async {
        begin(); defer { end() }
        do {
            guard let configuration else { throw PropGenerationError.missingToken }
            guard let job = jobs.first(where: { $0.id == id }) else { throw PropGenerationError.missingTask }
            guard job.endpoint == configuration.endpoint else { throw PropGenerationError.providerChanged }
            try await daemon.configure(endpoint: configuration.endpoint, token: configuration.token)
            let version = jobVersions[id]
            let record = try await daemon.retry(id: id)
            guard record.id == id else { throw PropGenerationError.invalidResponse }
            if jobVersions[id] == version { upsert(record) }; errorMessage = nil
        } catch { errorMessage = message(error) }
    }
    func cancel(id: UUID) async {
        begin(); defer { end() }
        do {
            // Cancellation is durable local intent; unrelated busy jobs never block it.
            let version = jobVersions[id]
            let record = try await daemon.cancel(id: id)
            guard record.id == id else { throw PropGenerationError.invalidResponse }
            if jobVersions[id] == version { upsert(record) }; errorMessage = nil
        } catch { errorMessage = message(error) }
    }
    @discardableResult func download(id: UUID) async -> URL? {
        await refreshSnapshot()
        guard let record = jobs.first(where: { $0.id == id }), record.backendStage == "ready",
              let path = record.localModelPath, path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }
    func publishMessage(id: UUID, taskId: UUID, worldID: String, residentScope: String, kind: String,
                        payload: [String: PropTaskJSON]) async throws -> PropTaskMessage {
        guard let messages = daemon as? any PropTaskMessageConnecting else { throw PropTaskDaemonError.unavailable }
        return try await messages.publishMessage(id: id, taskId: taskId, worldID: worldID, residentScope: residentScope, kind: kind, payload: payload)
    }
    func subscribeMessages(consumer: String, worldID: String, residentScope: String) async throws {
        guard let messages = daemon as? any PropTaskMessageConnecting else { throw PropTaskDaemonError.unavailable }
        try await messages.subscribeMessages(consumer: consumer, worldID: worldID, residentScope: residentScope)
    }
    func unsubscribeMessages(consumer: String, worldID: String, residentScope: String) {
        (daemon as? any PropTaskMessageConnecting)?.unsubscribeMessages(consumer: consumer, worldID: worldID, residentScope: residentScope)
    }
    func acknowledgeMessage(id: UUID, consumer: String, worldID: String, residentScope: String) async throws {
        guard let messages = daemon as? any PropTaskMessageConnecting else { throw PropTaskDaemonError.unavailable }
        try await messages.acknowledgeMessage(id: id, consumer: consumer, worldID: worldID, residentScope: residentScope)
    }
    private func apply(_ snapshot: PropTaskDaemonSnapshot) {
        guard !hasSnapshot || snapshot.sequence >= sequence else { return }
        sequence = snapshot.sequence; hasSnapshot = true; jobs = snapshot.jobs
        for job in jobs { jobVersions[job.id] = sequence }
        onChange?()
    }
    private func apply(_ event: PropTaskDaemonEvent) {
        guard event.sequence > sequence else { return }
        sequence = event.sequence; hasSnapshot = true; jobVersions[event.job.id] = event.sequence
        upsert(event.job)
    }
    private func upsert(_ job: PropGenerationRecord) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
        onChange?()
    }
    private func begin() { operations += 1; isBusy = true }
    private func end() { operations -= 1; isBusy = operations > 0 }
    private func message(_ error: Error) -> String {
        if let known = error as? PropGenerationError { return known.localizedDescription }
        if let known = error as? PropTaskDaemonError { return known.localizedDescription }
        if error is CancellationError { return "本次操作已停止；已受理任务继续由独立后台保存。" }
        return "独立任务后台尚未确认请求，请刷新原任务后再操作。"
    }
}
