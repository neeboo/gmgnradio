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

    static func category(message: String?) -> String {
        guard let message else { return "unclassified" }
        let prefixes = [
            ("Fatal error: failed to read current time:", "clock_callback_failed"),
            ("Missing environment variable: `", "missing_provider_env"),
            ("Fatal error: failed to load rules:", "rules_load_failed"),
            ("stream disconnected", "stream_disconnected"),
        ]
        for (prefix, category) in prefixes where message.hasPrefix(prefix) { return category }
        if message == "request timed out" { return "request_timeout" }
        let statusPrefix = "unexpected status "
        if message.hasPrefix(statusPrefix) {
            let remainder = message.dropFirst(statusPrefix.count)
            let digits = remainder.prefix { $0 >= "0" && $0 <= "9" }
            let suffix = remainder.dropFirst(digits.count)
            if let status = Int(digits), (100...599).contains(status),
               suffix.isEmpty || suffix.first == ":" || suffix.first?.isWhitespace == true {
                return "unexpected_http_status:\(status)"
            }
        }
        if let root = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
           let error = root["error"] as? [String: Any], error["type"] as? String == "invalid_request_error" {
            let allowed: Set<String> = ["model", "tools", "input", "reasoning", "service_tier"]
            if let param = error["param"] as? String, allowed.contains(param) { return "upstream_invalid_request:\(param)" }
            return "upstream_invalid_request"
        }
        return "unclassified"
    }

    /// Keep rejection structure, never model names, tool names, property keys, or values.
    static func detail(message: String?) -> String {
        guard let message else { return "unclassified" }
        let envelope = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any]
        let error = envelope?["error"] as? [String: Any]
        let text = (error?["message"] as? String ?? message).lowercased()
        let code = error?["code"] as? String
        let reason: String
        if text.contains("model"), text.contains("version of codex"),
           text.contains("requires") || (text.contains("please") && text.contains("try again")),
           ["update", "upgrade", "newer", "latest"].contains(where: text.contains) {
            reason = "codex_upgrade_required"
        } else if code == "model_not_found" || (text.contains("model") && text.contains("does not exist")) {
            reason = "model_not_found"
        } else if code == "model_access_denied" || (text.contains("model") && (text.contains("do not have access") || text.contains("access denied"))) {
            reason = "model_access_denied"
        } else if text.contains("unsupported model") || text.contains("model is not supported") {
            reason = "unsupported_model"
        } else if text.contains("invalid schema") || (text.contains("schema") && text.contains("unsupported")) {
            reason = "invalid_schema"
        } else if text.contains("tools") && (text.contains("empty") || text.contains("at least one")) {
            reason = "empty_tools"
        } else if text.contains("must be set to") {
            reason = "required_value"
        } else if text.contains("missing required parameter") || text.contains("is required") || text.contains("are required") {
            reason = "missing_required_parameter"
        } else if text.contains("unsupported parameter") || text.contains("unknown parameter") || text.contains("unrecognized request argument") {
            reason = "unsupported_parameter"
        } else if text.contains("unsupported value") || text.contains("unsupported tool namespace") {
            reason = "unsupported_value"
        } else if text.contains("invalid value:") || text.contains("invalid value for") {
            reason = "invalid_value"
        } else { reason = "unclassified" }

        let parameters: Set<String> = [
            "model", "input", "input[].type", "input[].role", "input[].content", "input[].content[].type",
            "tools", "tools[].type", "tools[].name", "tools[].namespace", "tools[].parameters",
            "tools[].parameters.type", "tools[].parameters.properties", "tools[].parameters.required",
            "tools[].parameters.additionalproperties", "tools[].function", "tools[].function.name",
            "tools[].function.parameters", "tools[].strict", "tool_choice", "tool_choice.type",
            "tool_choice.name", "tool_choice.namespace", "environment", "environments", "reasoning",
            "reasoning.effort", "reasoning.summary", "service_tier", "text", "text.verbosity",
            "store", "include", "parallel_tool_calls", "truncation", "max_output_tokens", "instructions",
        ]
        func parameter(_ candidate: String) -> String? {
            let normalized = candidate.lowercased()
                .replacingOccurrences(of: #"\[\d+\]"#, with: "[]", options: .regularExpression)
                .replacingOccurrences(of: #"\.\d+(?=\.|$)"#, with: "[]", options: .regularExpression)
            return parameters.contains(normalized) ? normalized : nil
        }
        var selectedParameter: String?
        if let supplied = error?["param"] as? String { selectedParameter = parameter(supplied) }
        else if let regex = try? NSRegularExpression(pattern: #"[a-z_][a-z0-9_]*(?:\[\d*\]|\.[a-z0-9_]+)*"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let tokenRange = Range(match.range, in: text) else { continue }
                if let value = parameter(String(text[tokenRange])) { selectedParameter = value; break }
            }
        }
        var result = reason
        if let selectedParameter { result += ";parameter=" + selectedParameter }
        for feature in ["namespace", "tool_choice", "environment", "function"] {
            if text.range(of: #"\b"# + feature + #"\b"#, options: .regularExpression) != nil {
                result += ";feature=" + feature
                break
            }
        }
        return result
    }
}

enum ResidentCodexTransportError: Error, LocalizedError {
    case notConnected, alreadyStarted, launchFailed, connectionClosed, invalidFrame, frameTooLarge
    case writeFailed, timedOut, remoteError(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "居民会话尚未连接，请重新发送消息。"
        case .alreadyStarted: return "居民会话连接已经启动，请稍候再试。"
        case .launchFailed: return "无法启动居民会话，请检查安装后重试。"
        case .connectionClosed: return "居民会话连接已中断，请重新发送刚才的内容。"
        case .invalidFrame: return "居民会话返回了无法识别的数据，请重新发送消息。"
        case .frameTooLarge: return "居民会话数据超过安全上限，请重试或缩短内容。"
        case .writeFailed: return "无法发送居民会话消息，请重新发送。"
        case .timedOut: return "居民会话等待超时，请稍后重新发送。"
        // 关联的远端错误码只供诊断，不拼接进用户文案。
        case .remoteError: return "居民会话请求失败，请重新发送消息。"
        }
    }
}

/// A single owned app-server process. It never launches a thread or grants permissions.
@MainActor final class ResidentCodexTransport {
    private(set) var failureCategory: String?
    private(set) var failureDetail: String?
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
                let error = raw["error"] as? [String: Any] ?? [:]
                let category = ResidentCodexSafeError.category(message: error["message"] as? String)
                failureCategory = category
                let detail = ResidentCodexSafeError.detail(message: error["message"] as? String)
                failureDetail = detail
                var safeError: [String: Any] = ["code": "server_error", "category": category, "detail": detail]
                if let info = ResidentCodexSafeError.projection(error["codexErrorInfo"]) {
                    safeError["codexErrorInfo"] = info
                }
                var safe: [String: Any] = ["error": safeError]
                if let willRetry = raw["willRetry"] as? Bool { safe["willRetry"] = willRetry }
                for key in ["threadId", "turnId"] { if let value = raw[key] as? String { safe[key] = value } }
                onNotification?(method, try Self.encode(safe))
            } else { onNotification?(method, params) }
            return
        }
        guard let id = frame["id"] as? Int, let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeout.cancel()
        if let error = frame["error"] as? [String: Any] {
            failureCategory = ResidentCodexSafeError.category(message: error["message"] as? String)
            failureDetail = ResidentCodexSafeError.detail(message: error["message"] as? String)
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
