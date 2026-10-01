import Foundation
import Network

struct PropTaskDaemonSnapshot: Codable, Sendable {
    let jobs: [PropGenerationRecord]
    let sequence: UInt64
}
struct PropTaskDaemonEvent: Codable, Sendable {
    let sequence: UInt64
    let job: PropGenerationRecord
}
struct PropTaskContext: Codable, Equatable, Sendable {
    let worldID: String
    let residentScope: String
}

/// JSON payloads are data, never executable instructions.
enum PropTaskJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: PropTaskJSON]), array([PropTaskJSON]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: PropTaskJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([PropTaskJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}
struct PropTaskMessage: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sequence: UInt64
    let taskId: UUID
    let worldID: String
    let residentScope: String
    let kind: String
    let payload: [String: PropTaskJSON]
}

@MainActor protocol PropTaskDaemonConnecting: AnyObject, Sendable {
    var onEvent: ((PropTaskDaemonEvent) -> Void)? { get set }
    var onSnapshot: ((PropTaskDaemonSnapshot) -> Void)? { get set }
    var onDisconnect: ((String) -> Void)? { get set }
    func configure(endpoint: URL, token: String) async throws
    func snapshot() async throws -> PropTaskDaemonSnapshot
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource, heightMeters: Double) async throws -> PropGenerationRecord
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource, heightMeters: Double, context: PropTaskContext?) async throws -> PropGenerationRecord
    /// 带**尺寸意图**的提交（`sizeIntent`）。老调用方只实现上面两个：默认实现忽略意图并转调
    /// 六参版本，于是"没有意图 = 今天"这条兼容性也在协议层成立。
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double, sizeIntent: PropSizeIntent?, context: PropTaskContext?) async throws -> PropGenerationRecord
    func retry(id: UUID) async throws -> PropGenerationRecord
    func cancel(id: UUID) async throws -> PropGenerationRecord
    func clearConfiguration()
    func disconnect()
}
@MainActor protocol PropTaskMessageConnecting: AnyObject, Sendable {
    var onMessage: ((String, PropTaskMessage) -> Void)? { get set }
    func publishMessage(id: UUID, taskId: UUID, worldID: String, residentScope: String, kind: String, payload: [String: PropTaskJSON]) async throws -> PropTaskMessage
    func subscribeMessages(consumer: String, worldID: String, residentScope: String) async throws
    func unsubscribeMessages(consumer: String, worldID: String, residentScope: String)
    func acknowledgeMessage(id: UUID, consumer: String, worldID: String, residentScope: String) async throws
}
extension PropTaskDaemonConnecting {
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource, heightMeters: Double, context: PropTaskContext?) async throws -> PropGenerationRecord {
        try await submit(id: id, endpoint: endpoint, name: name, png: png, source: source, heightMeters: heightMeters)
    }
    /// 默认实现：**丢弃**尺寸意图，按老路径提交。离线替身（`WishMachineDaemonFixture` 等）
    /// 因此继续编译、行为与今天逐字相同；只有真客户端才把意图发到线上。
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double, sizeIntent: PropSizeIntent?, context: PropTaskContext?) async throws -> PropGenerationRecord {
        try await submit(id: id, endpoint: endpoint, name: name, png: png, source: source,
                         heightMeters: heightMeters, context: context)
    }
}

enum PropTaskDaemonError: LocalizedError {
    case helperMissing, unavailable, invalidFrame, requestRejected, timedOut
    /// 统一状态合同需要 daemon 的错误码原样透传（如 revision_conflict）。
    case requestRejectedWith(code: String)
    var errorDescription: String? {
        switch self {
        case .helperMissing: return "缺少独立任务后台，请重新安装包含 gmgn-taskd 的应用。"
        case .unavailable: return "独立任务后台暂未连接；已受理任务不会因界面断开而取消。"
        case .invalidFrame: return "独立任务后台返回了无法识别的数据。"
        case .requestRejected, .requestRejectedWith: return "独立任务后台拒绝了请求，请检查任务和服务配置。"
        case .timedOut: return "独立任务后台尚未确认请求，请先刷新任务状态。"
        }
    }
}

/// One local socket only. Remote HTTP, task files and persistence belong to Rust.
@MainActor final class PropTaskDaemonClient: PropTaskDaemonConnecting, PropTaskMessageConnecting {
    var onEvent: ((PropTaskDaemonEvent) -> Void)?
    var onSnapshot: ((PropTaskDaemonSnapshot) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onMessage: ((String, PropTaskMessage) -> Void)?
    private let root: URL
    private let socketURL: URL
    private let helperURL: URL
    private let legacyRoot: URL?
    private let allowsLaunching: Bool
    private let requestTimeout: TimeInterval
    private var connection: NWConnection?
    private var connectionID = UUID()
    private var connectionReady = false
    private var connecting: Task<Void, Error>?
    private var reconnect: Task<Void, Never>?
    private var stopped = false
    private var buffer = Data()
    private var scannedBytes = 0
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var configuration: Configuration?
    private var configurationGeneration: UInt64 = 0
    private var hasConnected = false
    private var sequence: UInt64 = 0
    private var hasSnapshot = false
    private var subscriptions: [MessageSubscription] = []
    private var messageConnections: [MessageSubscription: PropTaskDaemonClient] = [:]
    private var messageConsumer: String?
    private enum ConnectionMode { case command, state, message }
    private var mode: ConnectionMode = .command
    private var stateConnection: PropTaskDaemonClient?
    private var helperProcess: Process?
    private static let maxFrame = 12 * 1024 * 1024
    private struct Configuration: Codable, Equatable { let endpoint: URL; let token: String }
    private struct Request<P: Encodable>: Encodable { let id: String; let method: String; let params: P }
    private struct Empty: Codable {}
    private struct ID: Codable { let id: UUID }
    private struct JobResult: Decodable { let job: PropGenerationRecord }
    private struct SnapshotPage: Decodable {
        let jobs: [PropGenerationRecord]
        let sequence: UInt64
        let nextCursor: String?
    }
    private struct MessageResult: Decodable { let message: PropTaskMessage }
    private struct MessageSubscription: Codable, Hashable { let consumer: String; let worldID: String; let residentScope: String }
    private struct Result<T: Decodable>: Decodable { let result: T }
    private struct Envelope: Decodable {
        struct Failure: Decodable { let code: String }
        let id: String?
        let error: Failure?
        let event: PropTaskDaemonEvent?
        let message: PropTaskMessage?
    }

    init(root: URL? = nil, socketURL: URL? = nil, helperURL: URL? = nil, legacyRoot: URL? = nil,
         allowsLaunching: Bool = true, requestTimeout: TimeInterval = 10) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio", isDirectory: true)
        self.root = root ?? support.appendingPathComponent("TaskService", isDirectory: true)
        self.socketURL = socketURL ?? self.root.appendingPathComponent("taskd.sock")
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd")
        self.legacyRoot = legacyRoot ?? (root == nil ? support.appendingPathComponent("PropGeneration", isDirectory: true) : nil)
        self.allowsLaunching = allowsLaunching
        self.requestTimeout = requestTimeout
        // Construction never launches a process or contacts a socket.
    }

    static func validateConfiguration(endpoint: URL, token: String) throws {
        _ = try normalizedEndpoint(endpoint)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw PropGenerationError.missingToken }
    }
    static func normalizedEndpoint(_ endpoint: URL) throws -> URL {
        guard var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              c.scheme?.lowercased() == "https" || (c.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw PropGenerationError.invalidEndpoint }
        c.scheme = c.scheme?.lowercased(); c.host = host; c.path = ""
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        guard let origin = c.url else { throw PropGenerationError.invalidEndpoint }
        return origin
    }
    func configure(endpoint: URL, token: String) async throws {
        try Self.validateConfiguration(endpoint: endpoint, token: token)
        let value = Configuration(endpoint: try Self.normalizedEndpoint(endpoint), token: token)
        if configuration != value { configurationGeneration += 1 }
        let generation = configurationGeneration
        configuration = value
        try await ensureConnected()
        guard generation == configurationGeneration else { throw PropGenerationError.configurationChangedBeforeSubmit }
        let _: Empty = try await request("configure", value)
    }
    func clearConfiguration() { configurationGeneration += 1; configuration = nil }
    func snapshot() async throws -> PropTaskDaemonSnapshot {
        try await ensureConnected()
        let result = try await readSnapshot()
        accept(result)
        return result
    }
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource, heightMeters: Double) async throws -> PropGenerationRecord {
        try await submit(id: id, endpoint: endpoint, name: name, png: png, source: source, heightMeters: heightMeters, context: nil)
    }
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource, heightMeters: Double, context: PropTaskContext?) async throws -> PropGenerationRecord {
        try await submit(id: id, endpoint: endpoint, name: name, png: png, source: source,
                         heightMeters: heightMeters, sizeIntent: nil, context: context)
    }
    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double, sizeIntent: PropSizeIntent?, context: PropTaskContext?) async throws -> PropGenerationRecord {
        struct Submit: Encodable {
            let id: UUID; let endpoint: URL; let name: String; let pngBase64: String
            let source: PropGenerationSource; let heightMeters: Double
            /// nil ⇒ 这个键根本不出现（合成 `Encodable` 用 `encodeIfPresent`）：
            /// 没有尺寸意图的提交在线上与今天**逐字节相同**。
            let sizeIntent: PropSizeIntent?
            let context: PropTaskContext?
        }
        try await ensureConnected()
        let result: JobResult = try await request("submit", Submit(id: id, endpoint: endpoint, name: name,
            pngBase64: png.base64EncodedString(), source: source, heightMeters: heightMeters,
            sizeIntent: sizeIntent, context: context))
        return result.job
    }
    func retry(id: UUID) async throws -> PropGenerationRecord {
        try await ensureConnected()
        let result: JobResult = try await request("retry", ID(id: id)); return result.job
    }
    func cancel(id: UUID) async throws -> PropGenerationRecord {
        try await ensureConnected()
        let result: JobResult = try await request("cancel", ID(id: id)); return result.job
    }
    func publishMessage(id: UUID, taskId: UUID, worldID: String, residentScope: String, kind: String,
                        payload: [String: PropTaskJSON]) async throws -> PropTaskMessage {
        struct Publish: Encodable {
            let id: UUID; let taskId: UUID; let worldID: String; let residentScope: String
            let kind: String; let payload: [String: PropTaskJSON]
        }
        try await ensureConnected()
        let result: MessageResult = try await request("publish_message", Publish(id: id, taskId: taskId,
            worldID: worldID, residentScope: residentScope, kind: kind, payload: payload))
        return result.message
    }
    func subscribeMessages(consumer: String, worldID: String, residentScope: String) async throws {
        let subscription = MessageSubscription(consumer: consumer, worldID: worldID, residentScope: residentScope)
        guard messageConnections[subscription] == nil else { return }
        let child = PropTaskDaemonClient(root: root, socketURL: socketURL, helperURL: helperURL,
            legacyRoot: legacyRoot, allowsLaunching: allowsLaunching, requestTimeout: requestTimeout)
        child.messageConsumer = consumer
        child.mode = .message
        child.subscriptions = [subscription]
        child.onMessage = { [weak self] consumer, message in self?.onMessage?(consumer, message) }
        messageConnections[subscription] = child
        do {
            try await child.ensureConnected()
        } catch { messageConnections.removeValue(forKey: subscription)?.disconnect(); throw error }
    }
    func unsubscribeMessages(consumer: String, worldID: String, residentScope: String) {
        let subscription = MessageSubscription(consumer: consumer, worldID: worldID, residentScope: residentScope)
        messageConnections.removeValue(forKey: subscription)?.disconnect()
    }
    func acknowledgeMessage(id: UUID, consumer: String, worldID: String, residentScope: String) async throws {
        struct Ack: Encodable { let id: UUID; let consumer: String; let worldID: String; let residentScope: String }
        try await ensureConnected()
        let _: Empty = try await request("ack_message", Ack(id: id, consumer: consumer, worldID: worldID, residentScope: residentScope))
    }
    /// gmgn-taskd 统一状态合同（state_* / event_read / message_*）的共享运输口：
    /// 复用既有 socket 帧、超时与重连；daemon 错误码原样透传给调用方。
    func call(method: String, params: [String: PropTaskJSON]) async throws -> [String: PropTaskJSON] {
        try await ensureConnected()
        return try await request(method, params)
    }

    func disconnect() {
        stopped = true
        reconnect?.cancel(); reconnect = nil
        connecting?.cancel(); connecting = nil
        configuration = nil
        configurationGeneration += 1
        let children = Array(messageConnections.values); messageConnections.removeAll()
        for child in children { child.disconnect() }
        stateConnection?.disconnect(); stateConnection = nil
        tearDown()
    }

    private func ensureConnected() async throws {
        stopped = false
        if let connecting { return try await connecting.value }
        if connectionReady { return }
        let task = Task { try await self.connectAndSubscribe() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }
    private func connectAndSubscribe() async throws {
        guard socketURL.isFileURL, socketURL.path.utf8.count < 104 else { throw PropTaskDaemonError.unavailable }
        do { try await openSocket() }
        catch {
            guard allowsLaunching else { throw error }
            try launchHelper()
            let limit = Date().addingTimeInterval(5)
            while true {
                try Task.checkCancellation()
                do { try await openSocket(); break }
                catch { if Date() >= limit { throw PropTaskDaemonError.unavailable } }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        switch mode {
        case .command:
            if let configuration { let _: Empty = try await request("configure", configuration) }
            if stateConnection == nil {
                let child = PropTaskDaemonClient(root: root, socketURL: socketURL, helperURL: helperURL,
                    legacyRoot: legacyRoot, allowsLaunching: allowsLaunching, requestTimeout: requestTimeout)
                child.mode = .state
                child.onSnapshot = { [weak self] in self?.accept($0) }
                child.onEvent = { [weak self] event in
                    guard let self, event.sequence > self.sequence else { return }
                    self.sequence = event.sequence; self.onEvent?(event)
                }
                child.onDisconnect = { [weak self] in self?.onDisconnect?($0) }
                stateConnection = child
                do { try await child.ensureConnected() }
                catch { stateConnection = nil; child.disconnect(); throw error }
            }
        case .state:
            if !hasSnapshot {
                let initial = try await readSnapshot()
                accept(initial)
            }
            struct Subscribe: Encodable { let after: UInt64 }
            let _: Empty = try await request("subscribe", Subscribe(after: sequence))
        case .message:
            for subscription in subscriptions { let _: Empty = try await request("subscribe_messages", subscription) }
        }
        hasConnected = true
    }
    private func launchHelper() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw PropTaskDaemonError.helperMissing }
        if helperProcess?.isRunning == true { return }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--root", root.path, "--socket", socketURL.path, "--concurrency", "2"]
        if let legacyRoot { process.arguments! += ["--legacy-root", legacyRoot.path] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        helperProcess = process
    }
    private func readSnapshot() async throws -> PropTaskDaemonSnapshot {
        struct PageRequest: Encodable { let cursor: String? }
        var cursor: String?
        var visited = Set<String>()
        var identities = Set<UUID>()
        var jobs: [PropGenerationRecord] = []
        var version: UInt64?
        repeat {
            try Task.checkCancellation()
            let page: SnapshotPage = try await request("snapshot", PageRequest(cursor: cursor))
            guard version == nil || version == page.sequence else { throw PropTaskDaemonError.invalidFrame }
            version = page.sequence
            for job in page.jobs {
                guard identities.insert(job.id).inserted else { throw PropTaskDaemonError.invalidFrame }
                jobs.append(job)
            }
            cursor = page.nextCursor
            if let cursor {
                guard !cursor.isEmpty, visited.insert(cursor).inserted else { throw PropTaskDaemonError.invalidFrame }
            }
        } while cursor != nil
        return PropTaskDaemonSnapshot(jobs: jobs, sequence: version ?? 0)
    }
    private func openSocket() async throws {
        tearDown()
        let identity = UUID(); connectionID = identity
        let socket = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        connection = socket
        socket.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connectionID == identity else { return }
                switch state {
                case .ready: self.connectionReady = true; self.receive(socket, identity: identity)
                case .failed, .cancelled: self.lostConnection(identity: identity)
                default: break
                }
            }
        }
        socket.start(queue: DispatchQueue(label: "gmgn.taskd.socket"))
        let limit = Date().addingTimeInterval(1)
        while !connectionReady {
            try Task.checkCancellation()
            guard connection != nil, Date() < limit else { tearDown(); throw PropTaskDaemonError.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func receive(_ socket: NWConnection, identity: UUID) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connectionID == identity else { return }
                if let data { self.consume(data, identity: identity) }
                if complete || error != nil { self.lostConnection(identity: identity) }
                else if self.connectionID == identity { self.receive(socket, identity: identity) }
            }
        }
    }
    private func consume(_ data: Data, identity: UUID) {
        buffer.append(data)
        let newline = Data([10])
        while let range = buffer.range(of: newline, in: buffer.index(buffer.startIndex, offsetBy: scannedBytes)..<buffer.endIndex) {
            let end = range.lowerBound
            guard buffer.distance(from: buffer.startIndex, to: end) <= Self.maxFrame else { lostConnection(identity: identity); return }
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            scannedBytes = 0
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: line)
                if let event = envelope.event {
                    if event.sequence > sequence { sequence = event.sequence; onEvent?(event) }
                } else if let message = envelope.message {
                    // Rust owns ACK/replay; each consumer decides whether it has handled this message.
                    if let consumer = messageConsumer { onMessage?(consumer, message) }
                } else if let id = envelope.id, let continuation = pending.removeValue(forKey: id) {
                    deadlines.removeValue(forKey: id)?.cancel()
                    if let error = envelope.error {
                        continuation.resume(throwing: PropTaskDaemonError.requestRejectedWith(code: error.code))
                    }
                    else { continuation.resume(returning: line) }
                }
            } catch { lostConnection(identity: identity); return }
        }
        scannedBytes = buffer.count
        if buffer.count > Self.maxFrame { lostConnection(identity: identity) }
    }
    private func request<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        guard let socket = connection, connectionReady else { throw PropTaskDaemonError.unavailable }
        let id = UUID().uuidString
        var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        guard data.count <= Self.maxFrame else { throw PropTaskDaemonError.invalidFrame }
        data.append(10)
        let identity = connectionID
        let response: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.requestTimeout ?? 10)) }
                    catch { return }
                    self?.finish(id: id, error: PropTaskDaemonError.timedOut)
                }
                socket.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { Task { @MainActor in self?.lostConnection(identity: identity) } }
                })
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, error: CancellationError()) }
        }
        do { return try JSONDecoder().decode(Result<R>.self, from: response).result }
        catch { throw PropTaskDaemonError.invalidFrame }
    }
    private func finish(id: String, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func accept(_ snapshot: PropTaskDaemonSnapshot) {
        guard !hasSnapshot || snapshot.sequence >= sequence else { return }
        sequence = snapshot.sequence; hasSnapshot = true
        onSnapshot?(snapshot)
    }
    private func tearDown() {
        connectionID = UUID()
        connection?.cancel(); connection = nil; connectionReady = false; buffer.removeAll(); scannedBytes = 0
        let requests = pending; pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }; deadlines.removeAll()
        for continuation in requests.values { continuation.resume(throwing: PropTaskDaemonError.unavailable) }
    }
    private func lostConnection(identity: UUID) {
        guard connectionID == identity else { return }
        tearDown()
        guard !stopped else { return }
        onDisconnect?(PropTaskDaemonError.unavailable.localizedDescription)
        guard hasConnected else { return }
        guard reconnect == nil else { return }
        reconnect = Task { [weak self] in
            var delay = 0.25
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                guard let self, !self.stopped else { break }
                do { try await self.ensureConnected(); break } catch {}
                delay = min(delay * 2, 5)
            }
            self?.reconnect = nil
        }
    }
}
