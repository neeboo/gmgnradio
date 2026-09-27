import Foundation
import Darwin

/// One prompt content block on the ACP wire. Image bytes travel as real native
/// content blocks; they are never flattened into prompt text.
struct ResidentDSHImageBlock: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

enum ResidentDSHPromptBlock: Equatable, Sendable {
    case text(String)
    case image(ResidentDSHImageBlock)
}

struct ResidentDSHSessionHandle: Equatable, Sendable {
    let sessionID: String
    /// What the server advertised during `initialize`:
    /// `agentCapabilities.promptCapabilities.image`.
    let imagePromptCapability: Bool
}

enum ResidentDSHTransportError: Error, LocalizedError {
    case alreadyStarted, launchFailed, notConnected, connectionClosed
    case invalidFrame, frameTooLarge, writeFailed, timedOut
    case turnNotCompleted(String)
    case promptConflict

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: "居民视觉会话连接已经启动，请稍候再试。"
        case .launchFailed: "无法启动居民视觉会话，系统会重试；请重新发送消息。"
        case .notConnected: "居民视觉会话尚未连接，系统会在下一条消息时重建连接；请重新发送。"
        case .connectionClosed: "居民视觉会话连接已中断，系统会在下一条消息时重建连接；请重新发送刚才的内容。"
        case .invalidFrame: "居民视觉会话返回了无法识别的数据，系统会重建连接；请重新发送消息。"
        case .frameTooLarge: "居民视觉会话数据超过安全上限，请重试或缩短内容。"
        case .writeFailed: "无法发送居民视觉会话消息，系统会重建连接；请重新发送。"
        case .timedOut: "居民视觉会话等待超时，连接已回收；请稍后重新发送。"
        // 关联的 stopReason 只供诊断，不拼接进用户文案。
        case .turnNotCompleted: "居民视觉会话在回复完成前中断，连接已回收；请重新发送刚才的内容。"
        case .promptConflict: "居民视觉会话已有进行中的请求，请等它结束后再发送。"
        }
    }
}

/// One owned `dsh-acp-demo` process speaking ACP JSON-RPC over NDJSON stdio.
/// It never grants shell, filesystem, jobs, skills or sub-agent capability; the
/// mounted composition decides that, and it is validated before launch. The
/// composition does mount the native web seam (search + public page reading),
/// which runs inside the DSH process without any local execution surface.
@MainActor protocol ResidentDSHImageConnecting: AnyObject, Sendable {
    /// False once the connector has been hard-torn-down; a cached runtime on
    /// top of an unusable connector must be retired before the next turn.
    var isUsable: Bool { get }
    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle
    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String
    func cancelActivePrompt()
    func awaitCancellationSettled() async
    func close()
}

extension ResidentDSHImageConnecting {
    func awaitCancellationSettled() async {}
}

enum ResidentDSHTransport {
    /// Base64 image payloads legitimately exceed 1 MiB lines.
    static let maximumFrameBytes = 64 * 1_048_576

    /// Strict allowlist environment for the ACP entry process. The terminal or
    /// app environment is not inherited: credentials must come from DSH's
    /// managed credential document, and DSH_SNAPSHOT or similar overrides must
    /// never silently change the boot mode.
    static func residentEnvironment(base: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"]
        where base[key]?.isEmpty == false {
            environment[key] = base[key]
        }
        environment["PATH"] = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        return environment
    }
}

@MainActor final class ResidentDSHConnector: ResidentDSHImageConnecting {
    private let nodeExecutable: URL
    private let entryPoint: URL
    private let compositionFileURL: URL
    private let requestTimeout: TimeInterval
    private let cancellationGrace: TimeInterval
    /// 测试/离线专用：在严格 allowlist 环境之上追加的键（如指向 loopback mock 的
    /// DEEPSEEK_BASE_URL / DEEPSEEK_API_KEY 与私有 DSH_HOME）。生产调用方不传，
    /// 默认空 —— 不会扩大生产子进程的环境面。
    private let environmentOverrides: [String: String]
    /// 测试/离线专用：把 ACP 子进程 stderr 落盘到该文件（诊断/组装断言用）；
    /// 生产调用方不传，默认仍只排空不落日志。
    private let stderrFileURL: URL?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var closed = false
    private var promptInFlight = false
    private var activeSessionID: String?
    private var replyChunks: String = ""
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    /// Large base64 frames must never be written synchronously on the main
    /// actor: a child that stops reading stdin would freeze the UI and make
    /// cancellation itself unrunnable.
    private let writeQueue = DispatchQueue(label: "gmgn.resident.dsh.stdin")
    /// One-shot bounded-cancellation latch: a cancelled task sends
    /// session/cancel once, then hard-tears-down after a grace window instead
    /// of waiting forever for a peer that may never answer.
    private var cancellationGraceTask: Task<Void, Never>?
    private var cancellationSent = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        nodeExecutable: URL,
        entryPoint: URL,
        compositionFileURL: URL,
        requestTimeout: TimeInterval = 600,
        cancellationGrace: TimeInterval = 8,
        environmentOverrides: [String: String] = [:],
        stderrFileURL: URL? = nil
    ) {
        self.nodeExecutable = nodeExecutable
        self.entryPoint = entryPoint
        self.compositionFileURL = compositionFileURL
        self.requestTimeout = requestTimeout.isFinite ? max(1, min(requestTimeout, 3_600)) : 600
        self.cancellationGrace = cancellationGrace.isFinite ? max(0.1, min(cancellationGrace, 60)) : 8
        self.environmentOverrides = environmentOverrides
        self.stderrFileURL = stderrFileURL
    }

    var isUsable: Bool { !closed }

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        try Task.checkCancellation()
        guard process == nil, !closed else {
            throw ResidentDSHTransportError.alreadyStarted
        }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = nodeExecutable
        child.arguments = [entryPoint.path, "--config", compositionFileURL.path]
        child.currentDirectoryURL = cwd
        var childEnvironment = ResidentDSHTransport.residentEnvironment(
            base: ProcessInfo.processInfo.environment
        )
        for (key, value) in environmentOverrides {
            childEnvironment[key] = value
        }
        child.environment = childEnvironment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.receive(bytes) }
        }
        // Diagnostics may name provider routes: default behavior drains them
        // without logging. Offline assembly tests may redirect stderr to a file
        // (stderrFileURL) for bounded diagnosis; production never passes it.
        if let stderrFileURL {
            try? Data().write(to: stderrFileURL)
            if let diagnostic = try? FileHandle(forWritingTo: stderrFileURL) {
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let bytes = handle.availableData
                    if bytes.isEmpty {
                        handle.readabilityHandler = nil
                        try? diagnostic.close()
                    } else {
                        try? diagnostic.write(contentsOf: bytes)
                    }
                }
            } else {
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    if handle.availableData.isEmpty { handle.readabilityHandler = nil }
                }
            }
        } else {
            stderr.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
        }
        do { try child.run() }
        catch {
            finish(ResidentDSHTransportError.launchFailed)
            throw ResidentDSHTransportError.launchFailed
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let initData = try await request(method: "initialize",
            params: ["protocolVersion": 1, "clientCapabilities": [String: Any]()]
        )
        guard let initObject = try? Self.decodeObject(initData),
              let capabilities = initObject["agentCapabilities"] as? [String: Any],
              let promptCapabilities = capabilities["promptCapabilities"] as? [String: Any] else {
            finish(ResidentDSHTransportError.invalidFrame)
            throw ResidentDSHTransportError.invalidFrame
        }
        let imageCapability = promptCapabilities["image"] as? Bool ?? false
        let sessionData = try await request(method: "session/new",
            params: ["cwd": cwd.path, "mcpServers": [String]()] as [String: Any]
        )
        guard let sessionObject = try? Self.decodeObject(sessionData),
              let sessionID = sessionObject["sessionId"] as? String,
              !sessionID.isEmpty else {
            finish(ResidentDSHTransportError.invalidFrame)
            throw ResidentDSHTransportError.invalidFrame
        }
        return ResidentDSHSessionHandle(
            sessionID: sessionID, imagePromptCapability: imageCapability
        )
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        // Overlapping calls are rejected before any shared state is touched:
        // entering here would otherwise clear the old grace window and
        // overwrite activeSessionID/replyChunks of the in-flight turn.
        guard !promptInFlight else {
            throw ResidentDSHTransportError.promptConflict
        }
        replyChunks = ""
        promptInFlight = true
        activeSessionID = sessionID
        // A cancellation armed by an earlier turn must not leak into this one.
        cancellationSent = false
        cancellationGraceTask?.cancel()
        cancellationGraceTask = nil
        defer {
            promptInFlight = false
            activeSessionID = nil
            // A settled turn — end_turn or a graceful cancelled stop — must
            // disarm this round's grace window so it can never hard-close a
            // healthy session afterwards.
            cancellationGraceTask?.cancel()
            cancellationGraceTask = nil
            let waiting = cancellationWaiters
            cancellationWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        let payload: [String: Any] = [
            "sessionId": sessionID,
            "prompt": blocks.map(Self.wireBlock),
        ]
        let data = try await request(method: "session/prompt", params: payload)
        guard let object = try? Self.decodeObject(data),
              let stopReason = object["stopReason"] as? String else {
            throw ResidentDSHTransportError.invalidFrame
        }
        guard stopReason == "end_turn" else {
            if stopReason == "cancelled" { throw CancellationError() }
            throw ResidentDSHTransportError.turnNotCompleted(stopReason)
        }
        return replyChunks
    }

    func cancelActivePrompt() {
        // A host tool can be running between native prompts. With no prompt
        // lease there is nothing to settle or retire.
        guard promptInFlight else { return }
        guard let id = pending.first(where: { $0.value.method == "session/prompt" })?.key else {
            // The response may already be routed while prompt is waiting to
            // resume. Keep reuse behind its defer, without starting a timeout.
            cancellationSent = true
            return
        }
        boundedCancel(requestID: id)
    }

    /// Reuse waits only for a cancelled prompt, never for an ordinary overlap.
    /// The existing cancellation grace tears down an unresponsive peer; prompt's
    /// defer then releases this lease and wakes every waiting caller.
    func awaitCancellationSettled() async {
        guard cancellationSent, promptInFlight else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    /// Task cancellation and manual cancellation converge here: send
    /// session/cancel once, then bound the wait. The session survives a
    /// graceful settle; only the grace timeout tears the process down. The
    /// sleep must propagate its own cancellation: a disarmed grace window
    /// exits instead of falling through to finish a healthy connection.
    private func boundedCancel(requestID: Int) {
        // onCancel hops to this actor asynchronously. Its original request may
        // already have settled, and a later prompt may own the same session.
        guard !closed, !cancellationSent, pending[requestID] != nil else { return }
        cancellationSent = true
        if promptInFlight, let sessionID = activeSessionID {
            try? notify(method: "session/cancel", params: ["sessionId": sessionID])
        }
        cancellationGraceTask?.cancel()
        cancellationGraceTask = Task { [weak self] in
            let grace = self?.cancellationGrace ?? 8
            do { try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000)) }
            catch { return }
            guard let self, !self.closed, self.pending[requestID] != nil else { return }
            self.finish(CancellationError())
        }
    }

    func close() {
        finish(ResidentDSHTransportError.connectionClosed)
    }

    // MARK: - Wire helpers

    static func wireBlock(_ block: ResidentDSHPromptBlock) -> [String: Any] {
        switch block {
        case let .text(text):
            return ["type": "text", "text": text]
        case let .image(image):
            return [
                "type": "image",
                "data": image.data.base64EncodedString(),
                "mimeType": image.mimeType,
            ]
        }
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let dictionary = object as? [String: Any] else {
            throw ResidentDSHTransportError.invalidFrame
        }
        return dictionary
    }

    // MARK: - JSON-RPC plumbing

    private func request(method: String, params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard process != nil, !closed else {
            throw ResidentDSHTransportError.notConnected
        }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation can win after the check above but before this
                // waiter is registered. Never put that request on the wire.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 600) * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.finish(ResidentDSHTransportError.timedOut)
                }
                pending[id] = Pending(
                    method: method, continuation: continuation, timeout: timeout
                )
                do {
                    try write([
                        "jsonrpc": "2.0", "id": id, "method": method, "params": params,
                    ])
                } catch { finish(error) }
            }
        } onCancel: { [weak self] in
            // Swift task cancellation alone must trigger bounded cancellation:
            // settle the turn gracefully, then hard-tear-down after the grace
            // window if the peer never answers.
            Task { @MainActor [weak self] in self?.boundedCancel(requestID: id) }
        }
    }

    private func notify(method: String, params: [String: Any]) throws {
        guard process != nil, !closed else {
            throw ResidentDSHTransportError.notConnected
        }
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Never runs on the main actor: a blocked pipe write stays inside the
    /// serial IO queue while timeouts, cancellation and the UI keep running.
    /// Failures hop back once to tear the connection down.
    private func write(_ object: [String: Any]) throws {
        guard !closed, let input else {
            throw ResidentDSHTransportError.notConnected
        }
        guard let bytes = try? JSONSerialization.data(
            withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]
        ) else {
            throw ResidentDSHTransportError.writeFailed
        }
        guard bytes.count <= ResidentDSHTransport.maximumFrameBytes else {
            throw ResidentDSHTransportError.frameTooLarge
        }
        writeQueue.async { [weak self] in
            do { try input.write(contentsOf: bytes + Data([10])) }
            catch {
                Task { @MainActor [weak self] in
                    self?.finish(ResidentDSHTransportError.writeFailed)
                }
            }
        }
    }

    private func receive(_ bytes: Data) {
        guard !closed else { return }
        if bytes.isEmpty { finish(ResidentDSHTransportError.connectionClosed); return }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            guard newline <= ResidentDSHTransport.maximumFrameBytes else {
                finish(ResidentDSHTransportError.frameTooLarge)
                return
            }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            do { try route(line) }
            catch {
                finish(error)
                return
            }
        }
        if buffer.count > ResidentDSHTransport.maximumFrameBytes {
            finish(ResidentDSHTransportError.frameTooLarge)
        }
    }

    private func route(_ line: Data) throws {
        guard let frame = try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed),
              let object = frame as? [String: Any] else {
            throw ResidentDSHTransportError.invalidFrame
        }
        if let method = object["method"] as? String {
            if let id = object["id"] {
                // Server-initiated requests. Permission asks stay machine policy:
                // reject once, never infer a grant.
                let options = (object["params"] as? [String: Any])?["options"] as? [[String: Any]]
                let rejectOption = options?.first {
                    ($0["kind"] as? String)?.hasPrefix("reject") == true
                }?["optionId"]
                let outcome: [String: Any] = rejectOption.map {
                    ["outcome": "selected", "optionId": $0]
                } ?? ["outcome": "cancelled"]
                try write(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
            } else if method == "session/update" {
                let params = object["params"] as? [String: Any]
                // Only the in-flight prompt's own session contributes reply
                // text: cross-session updates and chunks arriving after the
                // response settled are late data and are dropped.
                guard promptInFlight,
                      let updateSessionID = params?["sessionId"] as? String,
                      updateSessionID == activeSessionID,
                      let update = params?["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "agent_message_chunk",
                      let content = update["content"] as? [String: Any],
                      content["type"] as? String == "text",
                      let text = content["text"] as? String else {
                    return
                }
                replyChunks += text
            }
            return
        }
        guard let id = object["id"] as? Int, let waiting = pending.removeValue(forKey: id) else {
            return
        }
        waiting.timeout.cancel()
        if waiting.method == "session/prompt" {
            // Stop accepting chunks BEFORE the resumption can run: the awaiting
            // prompt only clears its own state in its defer, so a same-session
            // late chunk batched after this result line in the same stdout read
            // would otherwise be appended to a reply already considered final.
            // Keep the prompt lease until its defer finishes. Clearing only
            // the session stops chunks without admitting an overlapping turn.
            // initialize/session-new responses never take this branch.
            activeSessionID = nil
        }
        if let error = object["error"] as? [String: Any] {
            // Provider diagnostics can embed credentials; classify, never echo.
            let message = error["message"] as? String
            waiting.continuation.resume(throwing: AgentConversationError.dshNativeTurnFailed(
                DSHExecutionFailureReason(diagnostic: message ?? "")
            ))
        } else if let result = object["result"] {
            let data = try? JSONSerialization.data(
                withJSONObject: result, options: [.fragmentsAllowed]
            )
            waiting.continuation.resume(returning: data ?? Data())
        } else {
            waiting.continuation.resume(throwing: ResidentDSHTransportError.invalidFrame)
        }
    }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true
        cancellationGraceTask?.cancel()
        cancellationGraceTask = nil
        output?.readabilityHandler = nil
        if let input {
            writeQueue.async { try? input.close() }
        }
        try? output?.close()
        input = nil
        output = nil
        buffer.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for entry in waiting {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: error)
        }
        if let child = process, child.isRunning {
            child.terminate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }
}
