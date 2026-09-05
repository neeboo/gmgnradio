import Foundation
import Darwin

/// Diagnostics contain only protocol enums and bounded HTTP status integers.
enum ResidentCodexSafeError {
    private static let plain: Set<String> = [
        "contextWindowExceeded", "sessionBudgetExceeded", "usageLimitExceeded", "serverOverloaded",
        "cyberPolicy", "internalServerError", "unauthorized", "badRequest", "threadRollbackFailed",
        "sandboxError", "other",
    ]
    private static let http: Set<String> = [
        "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts",
    ]

    static func projection(_ value: Any?) -> Any? {
        if let text = value as? String { return plain.contains(text) ? text : nil }
        guard let object = value as? [String: Any], object.count == 1, let key = object.keys.first else { return nil }
        if key == "activeTurnNotSteerable" { return [key: [String: Int]()] }
        guard http.contains(key), let detail = object[key] as? [String: Any] else { return nil }
        if let status = detail["httpStatusCode"] as? Int, (100...599).contains(status) {
            return [key: ["httpStatusCode": status]]
        }
        return [key: [String: Int]()]
    }

    static func code(from value: Any?) -> String? {
        guard let safe = projection(value) else { return nil }
        if let text = safe as? String { return text }
        guard let object = safe as? [String: Any], let key = object.keys.first else { return nil }
        if let detail = object[key] as? [String: Int], let status = detail["httpStatusCode"] { return "\(key):\(status)" }
        return key
    }
}

enum ResidentCodexTransportError: Error, LocalizedError {
    case notConnected, alreadyStarted, launchFailed, connectionClosed, invalidFrame, frameTooLarge
    case writeFailed, timedOut, remoteError(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "居民会话尚未连接。"
        case .alreadyStarted: return "居民会话连接已经启动。"
        case .launchFailed: return "无法启动居民会话。"
        case .connectionClosed: return "居民会话连接已结束。"
        case .invalidFrame: return "居民会话收到无效数据。"
        case .frameTooLarge: return "居民会话数据超过限制。"
        case .writeFailed: return "无法发送居民会话消息。"
        case .timedOut: return "居民会话等待超时。"
        case .remoteError(let code): return "居民会话请求失败（\(code)）。"
        }
    }
}

/// A single owned app-server process. It never launches a thread or grants permissions.
@MainActor final class ResidentCodexTransport {
    var onNotification: ((String, Data) -> Void)?
    var onServerRequest: ((String, Data) async throws -> Data)?
    var onClosed: ((Error) -> Void)?
    var processIdentifier: Int32? { process?.processIdentifier }

    private let executableURL: URL
    private let arguments: [String]
    private let currentDirectoryURL: URL?
    private let environment: [String: String]?
    private let requestTimeout: TimeInterval
    private let maximumFrameBytes = 1_048_576
    private let writeQueue = DispatchQueue(label: "gmgn.resident.codex.stdin")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var started = false
    private var closed = false
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    private var callbacks: [UUID: Task<Void, Never>] = [:]

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL? = nil,
         environment: [String: String]? = nil, requestTimeout: TimeInterval = 60) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.requestTimeout = requestTimeout.isFinite ? max(0.01, min(requestTimeout, 3_600)) : 60
    }

    func start() async throws {
        try Task.checkCancellation()
        guard !started, !closed else { throw ResidentCodexTransportError.alreadyStarted }
        started = true
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.currentDirectoryURL = currentDirectoryURL
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.receive(bytes) }
        }
        // Drain stderr without retaining, forwarding, or logging potentially private content.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do { try child.run() }
        catch { finish(ResidentCodexTransportError.launchFailed); throw ResidentCodexTransportError.launchFailed }
        // A closed child pipe must report EPIPE instead of terminating the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            _ = try await request(method: "initialize", params: Self.encode([
                "clientInfo": ["name": "gmgn_resident", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ]))
            try notify(method: "initialized", params: Self.encode([:]))
        } catch { finish(error); throw error }
    }

    func request(method: String, params: Data) async throws -> Data {
        try Task.checkCancellation()
        guard started, !closed else { throw ResidentCodexTransportError.notConnected }
        let paramsObject = try Self.decode(params)
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 60) * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.finish(ResidentCodexTransportError.timedOut)
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout)
                do { try write(["id": id, "method": method, "params": paramsObject]) }
                catch { finish(error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(CancellationError()) }
        }
    }

    func notify(method: String, params: Data) throws {
        try write(["method": method, "params": Self.decode(params)])
    }

    func close() { finish(ResidentCodexTransportError.connectionClosed) }

    private static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func decode(_ bytes: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) }
        catch { throw ResidentCodexTransportError.invalidFrame }
    }

    private func write(_ object: [String: Any]) throws {
        guard !closed, let input else { throw ResidentCodexTransportError.notConnected }
        let bytes = try Self.encode(object)
        guard bytes.count <= maximumFrameBytes else { throw ResidentCodexTransportError.frameTooLarge }
        // A stalled peer must not block the UI or prevent its own timeout/cancellation.
        writeQueue.async { [weak self] in
            do { try input.write(contentsOf: bytes + Data([10])) }
            catch { Task { @MainActor [weak self] in self?.finish(ResidentCodexTransportError.writeFailed) } }
        }
    }

    private func receive(_ bytes: Data) {
        guard !closed else { return }
        if bytes.isEmpty { finish(ResidentCodexTransportError.connectionClosed); return }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            guard newline <= maximumFrameBytes else { finish(ResidentCodexTransportError.frameTooLarge); return }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            do {
                guard let frame = try Self.decode(line) as? [String: Any] else { throw ResidentCodexTransportError.invalidFrame }
                try route(frame)
            } catch { finish(error); return }
        }
        if buffer.count > maximumFrameBytes { finish(ResidentCodexTransportError.frameTooLarge) }
    }

    private func route(_ frame: [String: Any]) throws {
        if let method = frame["method"] as? String {
            let params = try Self.encode(frame["params"] ?? [:])
            if let id = frame["id"] {
                guard id is String || id is NSNumber else { throw ResidentCodexTransportError.invalidFrame }
                guard method == "item/tool/call", let handler = onServerRequest else {
                    try write(["id": id, "error": ["code": -32601, "message": "Resident tool unavailable"]])
                    return
                }
                let token = UUID()
                callbacks[token] = Task { [weak self] in
                    guard let self else { return }
                    defer { self.callbacks.removeValue(forKey: token) }
                    do {
                        let result = try await handler(method, params)
                        guard !self.closed, !Task.isCancelled else { return }
                        try self.write(["id": id, "result": Self.decode(result)])
                    } catch {
                        guard !self.closed else { return }
                        do { try self.write(["id": id, "error": ["code": -32603, "message": "Resident tool failed"]]) }
                        catch { self.finish(error) }
                    }
                }
            } else if method == "error" {
                let raw = frame["params"] as? [String: Any] ?? [:]
                var safe: [String: Any] = ["error": ["code": "server_error"]]
                if let error = raw["error"] as? [String: Any], let info = ResidentCodexSafeError.projection(error["codexErrorInfo"]) {
                    safe["error"] = ["code": "server_error", "codexErrorInfo": info]
                }
                if let willRetry = raw["willRetry"] as? Bool { safe["willRetry"] = willRetry }
                for key in ["threadId", "turnId"] { if let value = raw[key] as? String { safe[key] = value } }
                onNotification?(method, try Self.encode(safe))
            } else { onNotification?(method, params) }
            return
        }
        guard let id = frame["id"] as? Int, let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeout.cancel()
        if let error = frame["error"] as? [String: Any] {
            waiting.continuation.resume(throwing: ResidentCodexTransportError.remoteError(error["code"] as? Int ?? -32603))
        } else if let result = frame["result"] {
            waiting.continuation.resume(returning: try Self.encode(result))
        } else { waiting.continuation.resume(throwing: ResidentCodexTransportError.invalidFrame) }
    }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true
        let closedHandler = onClosed
        onClosed = nil
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        if let input { writeQueue.async { try? input.close() } }
        try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
        buffer.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for entry in waiting { entry.timeout.cancel(); entry.continuation.resume(throwing: error) }
        for callback in callbacks.values { callback.cancel() }
        callbacks.removeAll()
        if let child = process, child.isRunning {
            child.terminate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                // Check this exact Process, never find or signal other Codex instances.
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        closedHandler?(error)
    }
}
