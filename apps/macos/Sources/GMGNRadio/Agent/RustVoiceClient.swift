import Foundation
import Network
import Darwin

enum RustVoiceProvider: String, Sendable, CaseIterable { case bailian, elevenlabs, fish }

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

/// Cloud protocols live in Rust. This macOS adapter reads one bounded IPC frame
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
        do {
            var params: [String: Any] = ["sessionID": session.sessionID, "provider": configuration.provider.rawValue,
                                      "apiKey": configuration.apiKey, "voiceID": configuration.voiceID]
            if let text { params["text"] = text }
            if let model = configuration.model { params["model"] = model }
            try await session.start(method: method, params: params)
            return session
        } catch { session.close(); throw error }
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
    private let connection: NWConnection
    private let token: String
    private var ready = false
    private var closed = false
    private var explicitlyClosed = false
    private var buffer = Data()
    private static let frameLimit = 256 * 1024

    private init(connection: NWConnection, token: String) { self.connection = connection; self.token = token }

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
        guard endpoint.version == 1, parts.count == 2, parts[0] == "127.0.0.1",
              let portNumber = UInt16(parts[1]), portNumber > 0,
              let port = NWEndpoint.Port(rawValue: portNumber),
              let identity = UUID(uuidString: endpoint.token), identity.uuidString.dropFirst(14).first == "4" else {
            throw RustVoiceError.invalidFrame
        }
        let session = RustVoiceSession(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), token: endpoint.token)
        session.connection.stateUpdateHandler = { [weak session] state in
            Task { @MainActor in
                guard let session else { return }
                switch state {
                case .ready: session.ready = true
                case .failed, .cancelled: session.closed = true
                default: break
                }
            }
        }
        session.connection.start(queue: DispatchQueue(label: "gmgn.voice.ipc"))
        do {
            let deadline = Date().addingTimeInterval(1)
            while !session.ready {
                try Task.checkCancellation()
                guard !session.closed, Date() < deadline else { throw RustVoiceError.unavailable }
                try await Task.sleep(for: .milliseconds(10))
            }
            return session
        } catch { session.close(); throw error }
    }

    fileprivate func start(method: String, params: [String: Any]) async throws {
        let id = try await send(method: method, params: params)
        let reply = try await readObject()
        guard reply["id"] as? String == id else { throw RustVoiceError.invalidFrame }
        try checkError(reply)
        guard let result = reply["result"] as? [String: Any], result["started"] as? Bool == true,
              result["sessionID"] as? String == sessionID else { throw RustVoiceError.invalidFrame }
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
    func cancel() {
        guard !closed else { return }
        // Session ownership is connection-local; closing guarantees cancellation
        // even when the cancel frame cannot be delivered.
        let request: [String: Any] = ["id": UUID().uuidString, "auth": token, "method": "voice_cancel", "params": ["sessionID": sessionID]]
        if var frame = try? JSONSerialization.data(withJSONObject: request) {
            frame.append(10); connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        close()
    }
    func close() { explicitlyClosed = true; closed = true; ready = false; buffer.removeAll(); connection.cancel() }

    @discardableResult private func send(method: String, params: [String: Any]) async throws -> String {
        guard ready, !closed else { throw RustVoiceError.unavailable }
        try Task.checkCancellation()
        let id = UUID().uuidString
        var frame = try JSONSerialization.data(withJSONObject: ["id": id, "auth": token, "method": method, "params": params])
        guard frame.count < Self.frameLimit else { throw RustVoiceError.invalidFrame }
        frame.append(10)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: RustVoiceError.unavailable) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
        try Task.checkCancellation()
        return id
    }

    private func readObject() async throws -> [String: Any] {
        while true {
            try Task.checkCancellation()
            if closed {
                if explicitlyClosed { throw CancellationError() }
                throw RustVoiceError.unavailable
            }
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw RustVoiceError.invalidFrame }
                return object
            }
            guard buffer.count < Self.frameLimit else { throw RustVoiceError.invalidFrame }
            let data: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                        guard error == nil, let data, !data.isEmpty else {
                            continuation.resume(throwing: RustVoiceError.unavailable); return
                        }
                        continuation.resume(returning: data)
                    }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.close() } }
            if closed {
                if explicitlyClosed { throw CancellationError() }
                throw RustVoiceError.unavailable
            }
            buffer.append(data)
            guard buffer.count <= Self.frameLimit else { throw RustVoiceError.invalidFrame }
        }
    }
    private func checkError(_ reply: [String: Any]) throws {
        if let error = reply["error"] as? [String: Any] { throw RustVoiceError.rejected(error["code"] as? String ?? "voice_failed") }
    }
}
