import Foundation

@MainActor protocol PropTaskControlConnecting: AnyObject {
    func controlRequest(method: String, params: Data) async throws -> Data
}

private final class PropTaskControlReply: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var failure: Error?
    func receive(_ bytes: Data) { lock.lock(); data = bytes; lock.unlock() }
    func finish(_ error: Error?) { lock.lock(); failure = error; lock.unlock(); done.signal() }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return data
    }
}

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
        case .helperMissing: return "缺少后台服务，请重新安装应用。"
        case .unavailable: return "后台服务还没连上，已经接下的任务不会丢。"
        case .invalidFrame: return "后台服务返回了看不懂的数据。"
        case .requestRejected, .requestRejectedWith: return "后台服务拒绝了这次请求，请稍后重试。"
        case .timedOut: return "后台服务还没确认，请稍后刷新。"
        }
    }
}

/// Local HTTP only. Task files and persistence belong to Rust.
@MainActor final class PropTaskDaemonClient: PropTaskDaemonConnecting, PropTaskMessageConnecting, PropTaskControlConnecting {
    var onEvent: ((PropTaskDaemonEvent) -> Void)?
    var onSnapshot: ((PropTaskDaemonSnapshot) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onMessage: ((String, PropTaskMessage) -> Void)?
    private let root: URL
    private let endpointFileURL: URL
    private let helperURL: URL
    private let legacyRoot: URL?
    private let allowsLaunching: Bool
    private let requestTimeout: TimeInterval
    private var connection: TaskdHTTPTransport?
    private var origin: URL?
    private var requests: [String: TaskdHTTPTransport] = [:]
    private var eventData = Data()
    private var connectionID = UUID()
    private var connectionReady = false
    private var connecting: Task<Void, Error>?
    private var reconnect: Task<Void, Never>?
    private var stopped = false
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
    nonisolated private static let maxFrame = 12 * 1024 * 1024
    private struct Configuration: Codable, Equatable { let endpoint: URL; let token: String }
    private struct Request<P: Encodable>: Encodable { let id: String; let method: String; let params: P }
    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    private var endpointToken: String?
    private struct Empty: Codable {}
    private struct Acknowledgement: Decodable { let subscribed: Bool }
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

    init(root: URL? = nil, endpointFileURL: URL? = nil, helperURL: URL? = nil, legacyRoot: URL? = nil,
         allowsLaunching: Bool = true, requestTimeout: TimeInterval = 10) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio", isDirectory: true)
        self.root = root ?? support.appendingPathComponent("TaskService", isDirectory: true)
        self.endpointFileURL = endpointFileURL ?? self.root.appendingPathComponent("taskd.endpoint.json")
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd")
        self.legacyRoot = legacyRoot ?? (root == nil ? support.appendingPathComponent("PropGeneration", isDirectory: true) : nil)
        self.allowsLaunching = allowsLaunching
        self.requestTimeout = requestTimeout
        // Construction never launches a process or contacts the HTTP service.
    }

    static func validateConfiguration(endpoint: URL, token: String) throws {
        _ = try normalizedEndpoint(endpoint)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw PropGenerationError.missingToken }
    }

    /// Local transactions run off the main actor; no helper launch or health probe.
    func controlRequest(method: String, params: Data) async throws -> Data {
        let endpointFileURL = self.endpointFileURL
        return try await Task.detached(priority: .userInitiated) {
            try Self.performControlRequest(endpointFileURL: endpointFileURL, method: method, params: params)
        }.value
    }

    nonisolated private static func performControlRequest(endpointFileURL: URL, method: String, params: Data) throws -> Data {
        guard method.hasPrefix("wish_control_"),
              let descriptor = try? Data(contentsOf: endpointFileURL), descriptor.count <= 64 * 1024,
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: descriptor) else {
            throw PropTaskDaemonError.unavailable
        }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
              let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4",
              let url = URL(string: "http://\(endpoint.address)/rpc") else {
            throw PropTaskDaemonError.unavailable
        }
        let id = UUID().uuidString
        guard let fields = try JSONSerialization.jsonObject(with: params) as? [String: Any] else {
            throw PropTaskDaemonError.invalidFrame
        }
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": fields])
        guard body.count <= Self.maxFrame else { throw PropTaskDaemonError.invalidFrame }
        let reply = PropTaskControlReply()
        let transport = TaskdHTTPTransport(streaming: false, maximumBytes: Self.maxFrame,
            receive: { reply.receive($0) }, completion: { reply.finish($0) })
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(id, forHTTPHeaderField: "X-GMGN-Client-ID")
        transport.start(request)
        defer { transport.cancel() }
        guard reply.done.wait(timeout: .now() + 1) == .success else { throw PropTaskDaemonError.timedOut }
        guard let envelope = try JSONSerialization.jsonObject(with: reply.result()) as? [String: Any],
              envelope["id"] as? String == id else { throw PropTaskDaemonError.invalidFrame }
        if let error = envelope["error"] as? [String: Any], let code = error["code"] as? String {
            throw PropTaskDaemonError.requestRejectedWith(code: code)
        }
        guard let result = envelope["result"] as? [String: Any] else { throw PropTaskDaemonError.invalidFrame }
        return try JSONSerialization.data(withJSONObject: result)
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
        let child = PropTaskDaemonClient(root: root, endpointFileURL: endpointFileURL, helperURL: helperURL,
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
    /// 复用 HTTP 请求、超时与重连；daemon 错误码原样透传给调用方。
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
        guard endpointFileURL.isFileURL else { throw PropTaskDaemonError.unavailable }
        do { try await openHTTP() }
        catch {
            guard allowsLaunching else { throw error }
            try launchHelper()
            let limit = Date().addingTimeInterval(5)
            while true {
                try Task.checkCancellation()
                do { try await openHTTP(); break }
                catch { if Date() >= limit { throw PropTaskDaemonError.unavailable } }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        switch mode {
        case .command:
            if let configuration { let _: Empty = try await request("configure", configuration) }
            if stateConnection == nil {
                let child = PropTaskDaemonClient(root: root, endpointFileURL: endpointFileURL, helperURL: helperURL,
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
            try await subscribe("subscribe", Subscribe(after: sequence))
        case .message:
            for subscription in subscriptions { try await subscribe("subscribe_messages", subscription) }
        }
        hasConnected = true
    }
    private func launchHelper() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw PropTaskDaemonError.helperMissing }
        if helperProcess?.isRunning == true { return }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--root", root.path, "--endpoint-file", endpointFileURL.path, "--concurrency", "2"]
            + TaskdBundledMediaConfiguration.arguments(nextTo: helperURL)
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
    private func openHTTP() async throws {
        tearDown()
        guard let data = try? Data(contentsOf: endpointFileURL), data.count <= 64 * 1024,
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data) else {
            throw PropTaskDaemonError.unavailable
        }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
              let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4",
              let url = URL(string: "http://\(endpoint.address)") else { throw PropTaskDaemonError.unavailable }
        endpointToken = endpoint.token; origin = url
        let response = try await http(path: "health", id: UUID().uuidString, body: nil)
        struct Health: Decodable { let version: Int; let transport: String }
        guard let health = try? JSONDecoder().decode(Health.self, from: response),
              health.version == 2, health.transport == "http" else { tearDown(); throw PropTaskDaemonError.unavailable }
        connectionReady = true
    }
    private func consumeLine(_ line: Data, identity: UUID) {
        guard connectionID == identity else { return }
        var line = line
        if line.last == 13 { line.removeLast() }
        if line.isEmpty {
            guard !eventData.isEmpty else { return }
            let frame = eventData; eventData.removeAll()
            do { try consumeEnvelope(frame) }
            catch { lostConnection(identity: identity) }
        } else if line.starts(with: Data("data:".utf8)) {
            var payload = Data(line.dropFirst(5)); if payload.first == 32 { payload.removeFirst() }
            if !eventData.isEmpty { eventData.append(10) }
            guard eventData.count + payload.count <= Self.maxFrame else { lostConnection(identity: identity); return }
            eventData.append(payload)
        }
    }
    private func consumeEnvelope(_ data: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if let event = envelope.event {
            if event.sequence > sequence { sequence = event.sequence; onEvent?(event) }
        } else if let message = envelope.message {
            if let consumer = messageConsumer { onMessage?(consumer, message) }
        } else if let id = envelope.id, let continuation = pending.removeValue(forKey: id) {
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = envelope.error { continuation.resume(throwing: PropTaskDaemonError.requestRejectedWith(code: error.code)) }
            else { continuation.resume(returning: data) }
        }
    }
    private func urlRequest(path: String, body: Data?) throws -> URLRequest {
        guard let origin, let endpointToken else { throw PropTaskDaemonError.unavailable }
        var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: requestTimeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(endpointToken)", forHTTPHeaderField: "Authorization")
        if let body {
            guard body.count <= Self.maxFrame else { throw PropTaskDaemonError.invalidFrame }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
    private func http(path: String, id: String, body: Data?) async throws -> Data {
        let request = try urlRequest(path: path, body: body)
        let identity = connectionID
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                let transport = TaskdHTTPTransport(streaming: false, receive: { [weak self] data in
                    Task { @MainActor in
                        guard let self, self.connectionID == identity else { return }
                        self.requests.removeValue(forKey: id)
                        self.pending.removeValue(forKey: id)?.resume(returning: data)
                    }
                }, completion: { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self, self.connectionID == identity else { return }
                        self.finish(id: id, error: Self.transportError(error))
                    }
                })
                requests[id] = transport; transport.start(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, error: CancellationError()) }
        }
    }
    private func subscribe<P: Encodable>(_ method: String, _ params: P) async throws {
        let id = UUID().uuidString
        let body = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        var request = try urlRequest(path: "events", body: body)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let identity = connectionID
        let response: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.requestTimeout ?? 10)) } catch { return }
                    self?.finish(id: id, error: PropTaskDaemonError.timedOut)
                    self?.lostConnection(identity: identity)
                }
                let transport = TaskdHTTPTransport(streaming: true, receive: { [weak self] line in
                    // The serial delegate queue enqueues these in SSE wire order.
                    DispatchQueue.main.async { self?.consumeLine(line, identity: identity) }
                }, completion: { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.connectionID == identity else { return }
                        if let error { self.finish(id: id, error: Self.transportError(error)) }
                        self.lostConnection(identity: identity)
                    }
                })
                connection = transport; transport.start(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, error: CancellationError())
                self?.lostConnection(identity: identity)
            }
        }
        guard (try? JSONDecoder().decode(Result<Acknowledgement>.self, from: response).result.subscribed) == true
        else { tearDown(); throw PropTaskDaemonError.invalidFrame }
    }
    private func request<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        guard connectionReady else { throw PropTaskDaemonError.unavailable }
        let id = UUID().uuidString
        let body = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let response = try await http(path: "rpc", id: id, body: body)
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: response)
            guard envelope.id == id else { throw PropTaskDaemonError.invalidFrame }
            if let error = envelope.error { throw PropTaskDaemonError.requestRejectedWith(code: error.code) }
            return try JSONDecoder().decode(Result<R>.self, from: response).result
        } catch let error as PropTaskDaemonError { throw error }
        catch { throw PropTaskDaemonError.invalidFrame }
    }
    private func finish(id: String, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private static func transportError(_ error: Error) -> Error {
        switch error {
        case TaskdHTTPError.invalidFrame: return PropTaskDaemonError.invalidFrame
        case TaskdHTTPError.timedOut: return PropTaskDaemonError.timedOut
        case TaskdHTTPError.unavailable: return PropTaskDaemonError.unavailable
        case TaskdHTTPError.rejected(let code): return PropTaskDaemonError.requestRejectedWith(code: code)
        default: return error
        }
    }
    private func accept(_ snapshot: PropTaskDaemonSnapshot) {
        guard !hasSnapshot || snapshot.sequence >= sequence else { return }
        sequence = snapshot.sequence; hasSnapshot = true
        onSnapshot?(snapshot)
    }
    private func tearDown() {
        endpointToken = nil
        origin = nil
        connectionID = UUID()
        connection?.cancel(); connection = nil; connectionReady = false; eventData.removeAll()
        let transports = requests; requests.removeAll()
        for transport in transports.values { transport.cancel() }
        let waiting = pending; pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }; deadlines.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: PropTaskDaemonError.unavailable) }
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
