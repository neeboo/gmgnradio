import Foundation
import Darwin

enum RustVoiceProvider: String, Sendable, CaseIterable { case bailian, elevenlabs, fish }

struct RustVoiceOption: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct RustVoiceProviderCapabilities: Decodable, Identifiable, Sendable {
    let id: String
    let ttsModels: [RustVoiceOption]
    let asrModels: [RustVoiceOption]
    let defaultTTSModel: String
    let defaultASRModel: String?
}

struct RustVoiceCapabilities: Decodable, Sendable {
    let version: Int
    let providers: [RustVoiceProviderCapabilities]
}

struct RustVoiceConfiguration: Sendable {
    let provider: RustVoiceProvider
    let apiKey: String
    let voiceID: String
    let model: String?
    init(provider: RustVoiceProvider = .bailian, apiKey: String, voiceID: String = "Cherry", model: String? = nil) {
        self.provider = provider; self.apiKey = apiKey; self.voiceID = voiceID; self.model = model
    }
}

enum RustVoiceError: LocalizedError {
    case unavailable, invalidFrame, rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "语音服务暂时不可用；文字回复不受影响。"
        case .invalidFrame: "语音服务返回的数据无法播放；文字回复不受影响。"
        case .rejected: "语音服务请求失败，请检查语音设置和服务额度；文字回复不受影响。"
        }
    }
}

struct RustVoiceEvent: Decodable, Sendable {
    let sessionID: String
    let type: String
    let audioBase64: String?
    let sampleRate: Int?
    let channels: Int?
    let encoding: String?
    let text: String?
    let code: String?
}

/// Cloud protocols live in Rust. This macOS adapter reads one bounded HTTP SSE frame
/// at a time; callers naturally backpressure taskd by delaying nextEvent().
@MainActor final class RustVoiceClient {
    private let root: URL
    private let endpointURL: URL
    private let helperURL: URL
    private let allowsLaunching: Bool
    private var helper: Process?

    init(root: URL? = nil, endpointURL: URL? = nil, helperURL: URL? = nil, allowsLaunching: Bool = true) {
        let serviceRoot = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/TaskService", isDirectory: true)
        self.root = serviceRoot
        self.endpointURL = endpointURL ?? serviceRoot.appendingPathComponent("taskd.endpoint.json")
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd")
        self.allowsLaunching = allowsLaunching
    }

    func startTTS(text: String, configuration: RustVoiceConfiguration) async throws -> RustVoiceSession {
        try await start(method: "voice_tts_start", text: text, configuration: configuration)
    }

    func listVoices(configuration: RustVoiceConfiguration) async throws -> [RustVoiceOption] {
        let session = try await connect()
        defer { session.close() }
        return try await session.listVoices(configuration: configuration)
    }

    func capabilities() async throws -> RustVoiceCapabilities {
        let session = try await connect()
        defer { session.close() }
        return try await session.capabilities()
    }

    func startASR(configuration: RustVoiceConfiguration, readyTimeout: TimeInterval = 10) async throws -> RustVoiceSession {
        guard readyTimeout.isFinite, readyTimeout > 0 else { throw RustVoiceError.invalidFrame }
        let session = try await start(method: "voice_asr_start", text: nil, configuration: configuration)
        do {
            // Local acknowledgement allocates a session; only Rust's ready
            // event proves the provider handshake completed and can accept PCM.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let event = try await session.nextEvent()
                    if event.type == "error" { throw RustVoiceError.rejected(event.code ?? "voice_failed") }
                    guard event.type == "ready" else { throw RustVoiceError.invalidFrame }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(readyTimeout))
                    throw RustVoiceError.unavailable
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            try Task.checkCancellation()
            return session
        } catch { session.close(); throw error }
    }

    private func start(method: String, text: String?, configuration: RustVoiceConfiguration) async throws -> RustVoiceSession {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RustVoiceError.rejected("missing_key")
        }
        let session = try await connect()
        do {
            var params: [String: Any] = ["sessionID": session.sessionID, "provider": configuration.provider.rawValue,
                                      "apiKey": configuration.apiKey, "voiceID": configuration.voiceID]
            if let text { params["text"] = text }
            if let model = configuration.model { params["model"] = model }
            try await session.start(method: method, params: params)
            return session
        } catch { session.close(); throw error }
    }

    private func connect() async throws -> RustVoiceSession {
        var session: RustVoiceSession?
        do { session = try await RustVoiceSession.open(endpointURL: endpointURL) }
        catch {
            try Task.checkCancellation()
            if case RustVoiceError.invalidFrame = error { throw error }
            guard allowsLaunching else { throw error }
            if helper?.isRunning != true {
                guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw RustVoiceError.unavailable }
                let process = Process(); process.executableURL = helperURL
                process.arguments = ["--root", root.path, "--endpoint-file", endpointURL.path, "--concurrency", "2"]
                    + TaskdBundledMediaConfiguration.arguments(nextTo: helperURL)
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); helper = process
            }
            let deadline = Date().addingTimeInterval(5)
            while session == nil {
                try Task.checkCancellation()
                do { session = try await RustVoiceSession.open(endpointURL: endpointURL) }
                catch { guard Date() < deadline else { throw RustVoiceError.unavailable } }
                if session == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        guard let session else { throw RustVoiceError.unavailable }
        return session
    }
}

@MainActor protocol RustVoiceStreaming: AnyObject {
    var sessionID: String { get }
    func nextEvent() async throws -> RustVoiceEvent
    func cancel()
    func close()
}

@MainActor final class RustVoiceSession: RustVoiceStreaming {
    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    let sessionID = UUID().uuidString
    private let endpoint: URL
    private let clientID = UUID().uuidString
    private var stream: TaskdHTTPTransport?
    private let inbox = TaskdVoiceHTTPInbox()
    private let token: String
    private var closed = false
    private static let frameLimit = 256 * 1024

    private init(endpoint: URL, token: String) { self.endpoint = endpoint; self.token = token }

    /// The token descriptor is a small owner-only regular file, not arbitrary
    /// Foundation URL input. Open the final component without following links.
    private static func readEndpoint(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw RustVoiceError.invalidFrame }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RustVoiceError.unavailable }
            throw RustVoiceError.invalidFrame
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        let limit = 64 * 1024
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= limit else { throw RustVoiceError.invalidFrame }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, limit + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw RustVoiceError.invalidFrame
            }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= limit else { throw RustVoiceError.invalidFrame }
        }
    }

    static func open(endpointURL: URL) async throws -> RustVoiceSession {
        let endpoint: Endpoint
        do { endpoint = try JSONDecoder().decode(Endpoint.self, from: readEndpoint(endpointURL)) }
        catch let error as RustVoiceError { throw error }
        catch { throw RustVoiceError.invalidFrame }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
              let portNumber = UInt16(parts[1]), portNumber > 0,
              let identity = UUID(uuidString: endpoint.token), identity.uuidString.dropFirst(14).first == "4" else {
            throw RustVoiceError.invalidFrame
        }
        let session = RustVoiceSession(endpoint: URL(string: "http://\(endpoint.address)")!, token: endpoint.token)
        var request = URLRequest(url: session.endpoint.appendingPathComponent("health"), timeoutInterval: 1)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let inbox = TaskdVoiceHTTPInbox()
        let transport = TaskdHTTPTransport(streaming: false, maximumBytes: frameLimit, receive: { inbox.body($0) }, completion: { if let error = $0 { inbox.finish(error) } })
        transport.start(request)
        let data = try await withTaskCancellationHandler { try await inbox.next() } onCancel: { transport.cancel() }
        guard let health = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              health["version"] as? Int == 2, health["transport"] as? String == "http" else { throw RustVoiceError.invalidFrame }
        return session
    }

    fileprivate func start(method: String, params: [String: Any]) async throws {
        let id = UUID().uuidString
        let request = try request(path: "events", id: id, method: method, params: params)
        let inbox = self.inbox
        let transport = TaskdHTTPTransport(streaming: true, maximumBytes: Self.frameLimit, receive: { inbox.receive($0) }, completion: { inbox.finish($0 ?? RustVoiceError.unavailable) })
        stream = transport
        transport.start(request)
        let reply = try await readObject()
        guard reply["id"] as? String == id else { throw RustVoiceError.invalidFrame }
        try checkError(reply)
        guard let result = reply["result"] as? [String: Any], result["started"] as? Bool == true,
              result["sessionID"] as? String == sessionID else { throw RustVoiceError.invalidFrame }
    }

    fileprivate func listVoices(configuration: RustVoiceConfiguration) async throws -> [RustVoiceOption] {
        let id = UUID().uuidString
        let reply = try await rpc(id: id, method: "voice_list", params: ["provider": configuration.provider.rawValue, "apiKey": configuration.apiKey])
        guard reply["id"] as? String == id else { throw RustVoiceError.invalidFrame }
        try checkError(reply)
        guard let result = reply["result"] as? [String: Any],
              result["provider"] as? String == configuration.provider.rawValue,
              let raw = result["voices"] as? [[String: Any]], raw.count <= 200 else { throw RustVoiceError.invalidFrame }
        let voices = try JSONDecoder().decode([RustVoiceOption].self, from: JSONSerialization.data(withJSONObject: raw))
        guard voices.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 200 && !$0.name.isEmpty && $0.name.utf8.count <= 512 }),
              Set(voices.map(\.id)).count == voices.count else { throw RustVoiceError.invalidFrame }
        return voices
    }

    fileprivate func capabilities() async throws -> RustVoiceCapabilities {
        let id = UUID().uuidString
        let reply = try await rpc(id: id, method: "voice_capabilities", params: [:])
        guard reply["id"] as? String == id else { throw RustVoiceError.invalidFrame }
        try checkError(reply)
        guard let result = reply["result"] as? [String: Any] else { throw RustVoiceError.invalidFrame }
        let decoded = try JSONDecoder().decode(RustVoiceCapabilities.self, from: JSONSerialization.data(withJSONObject: result))
        guard decoded.version == 1, decoded.providers.count <= 10,
              Set(decoded.providers.map(\.id)).count == decoded.providers.count else { throw RustVoiceError.invalidFrame }
        for provider in decoded.providers {
            guard provider.ttsModels.count <= 30, provider.asrModels.count <= 30,
                  provider.ttsModels.contains(where: { $0.id == provider.defaultTTSModel }),
                  provider.defaultASRModel.map({ value in provider.asrModels.contains(where: { $0.id == value }) }) ?? provider.asrModels.isEmpty else { throw RustVoiceError.invalidFrame }
            for models in [provider.ttsModels, provider.asrModels] {
                guard Set(models.map(\.id)).count == models.count,
                      models.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && !$0.name.isEmpty && $0.name.utf8.count <= 512 }) else { throw RustVoiceError.invalidFrame }
            }
        }
        return decoded
    }

    func nextEvent() async throws -> RustVoiceEvent {
        while true {
            let object = try await readObject()
            try checkError(object)
            guard let event = object["voice_event"] else { continue } // append/commit acknowledgements
            let decoded = try JSONDecoder().decode(RustVoiceEvent.self, from: JSONSerialization.data(withJSONObject: event))
            guard decoded.sessionID == sessionID else { throw RustVoiceError.invalidFrame }
            return decoded
        }
    }

    func sendAudio(_ pcm16LE: Data) async throws {
        guard !pcm16LE.isEmpty, pcm16LE.count <= 32_768, pcm16LE.count % 2 == 0 else { throw RustVoiceError.invalidFrame }
        _ = try await send(method: "voice_audio_append", params: ["sessionID": sessionID, "audioBase64": pcm16LE.base64EncodedString()])
    }
    func commit() async throws { _ = try await send(method: "voice_asr_commit", params: ["sessionID": sessionID]) }
    func cancel() { close() }
    func close() {
        closed = true
        stream?.cancel(); stream = nil
        inbox.finish(CancellationError())
    }

    private func request(path: String, id: String, method: String, params: [String: Any]) throws -> URLRequest {
        guard !closed else { throw CancellationError() }
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        guard body.count < Self.frameLimit else { throw RustVoiceError.invalidFrame }
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-GMGN-Client-ID")
        return request
    }
    @discardableResult private func send(method: String, params: [String: Any]) async throws -> String {
        let id = UUID().uuidString
        let reply = try await rpc(id: id, method: method, params: params)
        try checkError(reply)
        return id
    }
    private func rpc(id: String, method: String, params: [String: Any]) async throws -> [String: Any] {
        let queue = TaskdVoiceHTTPInbox()
        let transport = TaskdHTTPTransport(streaming: false, maximumBytes: Self.frameLimit, receive: { queue.body($0) }, completion: { if let error = $0 { queue.finish(error) } })
        let request = try request(path: "rpc", id: id, method: method, params: params)
        transport.start(request)
        let data = try await withTaskCancellationHandler { try await queue.next() } onCancel: { transport.cancel() }
        guard data.count <= Self.frameLimit, let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? String == id else { throw RustVoiceError.invalidFrame }
        return reply
    }
    private func readObject() async throws -> [String: Any] {
        let stream = self.stream
        let data = try await withTaskCancellationHandler { try await inbox.next() } onCancel: { stream?.cancel() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RustVoiceError.invalidFrame }
        return object
    }
    private func checkError(_ reply: [String: Any]) throws {
        if let error = reply["error"] as? [String: Any] { throw RustVoiceError.rejected(error["code"] as? String ?? "voice_failed") }
    }
}

/// Bounded SSE inbox. No provider credentials are retained or logged.
private final class TaskdVoiceHTTPInbox: @unchecked Sendable {
    private let lock = NSCondition()
    private var pending: [Data] = []
    private var bytes = 0
    private var event = Data()
    private var error: Error?
    private var waiter: CheckedContinuation<Data, Error>?
    func receive(_ line: Data) {
        var line = line
        if line.last == 13 { line.removeLast() }
        lock.lock()
        if line.isEmpty {
            let data = event; event.removeAll(); lock.unlock()
            if !data.isEmpty { body(data) }
            return
        }
        if line.starts(with: Data("data:".utf8)) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            if !event.isEmpty { event.append(10) }
            event.append(contentsOf: value)
        }
        let overflow = event.count > 256 * 1024
        lock.unlock()
        if overflow { finish(RustVoiceError.invalidFrame) }
    }
    func body(_ data: Data) {
        lock.lock()
        guard error == nil else { lock.unlock(); return }
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: data); return }
        guard data.count <= 256 * 1024 else { lock.unlock(); finish(RustVoiceError.invalidFrame); return }
        // URLSession suspend is asynchronous: its current delegate callback can
        // already contain many SSE events. Apply pressure at this producer
        // boundary so a synthesis burst cannot overflow or discard valid PCM.
        // The delegate queue is separate from the main-actor playback consumer.
        while error == nil && bytes + data.count > 256 * 1024 { lock.wait() }
        guard error == nil else { lock.unlock(); return }
        // A consumer can drain the queue and install its next continuation
        // while this producer is waiting to reacquire the condition lock.
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: data); return }
        pending.append(data); bytes += data.count
        lock.unlock()
    }
    func finish(_ error: Error) {
        let error: Error = {
            if error is CancellationError { return error }
            if let http = error as? TaskdHTTPError {
                if case .invalidFrame = http { return RustVoiceError.invalidFrame }
                if case .rejected(let code) = http { return RustVoiceError.rejected(code) }
                return RustVoiceError.unavailable
            }
            if error is URLError { return RustVoiceError.unavailable }
            return error
        }()
        lock.lock()
        if self.error == nil { self.error = error }
        lock.broadcast()
        if error is CancellationError { pending.removeAll(); bytes = 0; event.removeAll() }
        let waiter = waiter; self.waiter = nil; lock.unlock()
        waiter?.resume(throwing: error)
    }
    func next() async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let data = pending.removeFirst(); bytes -= data.count
                lock.broadcast()
                lock.unlock(); continuation.resume(returning: data)
            }
            else if let error { lock.unlock(); continuation.resume(throwing: error) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}
