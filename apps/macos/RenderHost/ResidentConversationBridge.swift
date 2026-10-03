import Foundation

/// Real conversation-service adapter, deliberately without world tools or a
/// durable world scope. It never constructs StageResidentChatState because
/// that type's attachment store cannot currently accept an isolated root.
@MainActor
final class RenderHostResidentConversation {
    let backend: String
    private let service: AgentConversationService
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var events: [[String: Any]] = []
    private var activeSubmission: ResidentChatSubmission?
    private var activeRequestID: UInt64?
    private var recovery = ResidentDraftRecovery()
    private var transcript: [AgentConversationMessage] = []
    private var draft = ""
    private var reply = ""
    private var statusNotice: String?

    init(backend: String, dataRoot: URL, defaults: UserDefaults) throws {
        self.backend = backend
        let directory = dataRoot.appendingPathComponent("chat/cwd", isDirectory: true)
        let codexHome = dataRoot.appendingPathComponent("chat/codex", isDirectory: true)
        for url in [directory, codexHome] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let environment = RenderHostCodexRunner.environment(codexHome: codexHome)
        service = AgentConversationService(
            defaults: defaults,
            runnerFactory: { executable in
                RenderHostCodexRunner(executable: executable, directory: directory, environment: environment)
            },
            useResidentAgent: false
        )
        service.selectBackend(backend == "codex" ? .codex : .claudeCode)
        service.setAutoSpeakReplies(false)
        service.resetSession()
    }

    func send(requestID: UInt64, text: String) -> Bool {
        guard task == nil else {
            enqueue(kind: "failure", requestID: requestID, message: "正在回复，请先停止当前回复。")
            return false
        }
        let submission = ResidentChatSubmission(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard submission.canSend else {
            enqueue(kind: "failure", requestID: requestID, message: "请先输入消息。")
            return false
        }
        generation &+= 1
        let lease = generation
        activeSubmission = submission
        activeRequestID = requestID
        draft = ""
        reply = ""
        statusNotice = nil
        recovery = ResidentDraftRecovery()
        enqueue(kind: "accepted", requestID: requestID, text: submission.text)
        // Each Codex invocation has an ephemeral isolated session. Preserve
        // only our actual bounded conversation text, never an unrelated session.
        let previous = Array(transcript.suffix(12))
        let prompt = backend == "codex" && !previous.isEmpty
            ? previous.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
                + "\nuser: " + submission.text
            : submission.text
        if backend == "codex" { service.resetSession() }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await service.send(prompt, history: previous, userMessage: submission.text)
                guard lease == generation, !Task.isCancelled else { return }
                reply = response
                transcript += [.init(role: .user, text: submission.text), .init(role: .agent, text: response)]
                transcript = Array(transcript.suffix(24))
                enqueue(kind: "reply", requestID: requestID, text: response)
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            } catch {
                guard lease == generation else { return }
                draft = recovery.restore(submission, text: draft, attachments: []).text
                let notice = error is CancellationError ? "已停止本次回复。" : error.localizedDescription
                statusNotice = notice
                enqueue(kind: error is CancellationError ? "cancelled" : "failure",
                        requestID: requestID, message: notice,
                        category: (error as? RenderHostConversationFailure)?.rawValue)
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            }
        }
        return true
    }

    @discardableResult
    func cancel(requestID: UInt64? = nil) -> Bool {
        if let requestID, requestID != activeRequestID { return false }
        guard let submission = activeSubmission else { return false }
        let cancelledID = activeRequestID
        generation &+= 1
        task?.cancel()
        service.cancel()
        task = nil
        activeSubmission = nil
        activeRequestID = nil
        draft = recovery.restore(submission, text: draft, attachments: []).text
        statusNotice = "已停止本次回复。"
        enqueue(kind: "cancelled", requestID: cancelledID, message: statusNotice)
        return true
    }

    var state: [String: Any] {
        ["configured": true, "backend": backend, "isThinking": task != nil,
         "canStop": activeSubmission != nil, "draft": draft, "reply": reply,
         "statusNotice": statusNotice as Any? ?? NSNull(),
         "deliveryMode": "final-response", "worldToolsEnabled": false,
         "transcript": transcript.map { ["role": $0.role.rawValue, "text": $0.text] }]
    }

    func poll() -> [String: Any] {
        let result: [String: Any] = ["events": events, "state": state]
        events.removeAll(keepingCapacity: true)
        return result
    }

    private func enqueue(kind: String, requestID: UInt64?, text: String? = nil, message: String? = nil, category: String? = nil) {
        sequence &+= 1
        var event: [String: Any] = ["sequence": sequence, "kind": kind]
        if let requestID { event["requestID"] = requestID }
        if let text { event["text"] = text }
        if let message { event["message"] = message }
        if let category { event["category"] = category }
        events.append(event)
        if events.count > 64 { events.removeFirst(events.count - 64) }
    }
}

/// Only safe categories leave the process boundary. Raw CLI output remains
/// in memory and never becomes a UI message, log line, or persisted document.
enum RenderHostConversationFailure: String, Error, LocalizedError {
    case auth, model, network, rate, config, unknown

    var errorDescription: String? {
        switch self {
        case .auth: "当前接口凭证不可用，请检查应用启动环境里的 API 配置。消息已保留。"
        case .model: "当前模型不可用，请检查所选模型和接口权限。消息已保留。"
        case .network: "暂时连不上对话服务，请检查网络后重试。消息已保留。"
        case .rate: "对话服务当前额度不足或请求过于频繁，请稍后重试。消息已保留。"
        case .config: "对话连接配置未能通过检查。消息已保留，请修正配置后重试。"
        case .unknown: "对话服务没有完成本次回复，消息已保留，请重试。"
        }
    }

    static func classify(_ output: String) -> Self {
        let text = output.lowercased()
        if ["rate_limit", "rate limit", "too many requests", "429", "insufficient_quota", "quota exceeded"].contains(where: text.contains) { return .rate }
        if ["model_not_found", "model not found", "unsupported model", "does not exist", "model is not supported", "invalid model"].contains(where: text.contains) { return .model }
        if ["unauthorized", "401", "invalid_api_key", "incorrect api key", "authentication", "not logged in", "missing api key", "missing bearer"].contains(where: text.contains) { return .auth }
        if ["connection refused", "connection reset", "timed out", "timeout", "dns", "failed to connect", "network", "error sending request", "stream disconnected"].contains(where: text.contains) { return .network }
        if ["invalid configuration", "unknown variant", "unrecognized", "unexpected argument", "error parsing", "invalid value", "config.toml", "unsupported feature"].contains(where: text.contains) { return .config }
        return .unknown
    }
}

/// Reuses the existing bounded, cancellable process operation, but only its
/// generic Process mechanics; these arguments still execute real Codex and
/// AgentConversationService parses its actual JSON result.
private struct RenderHostCodexRunner: CodexCommandRunning {
    let executable: URL
    let directory: URL
    let environment: [String: String]

    static func environment(codexHome: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowed = Set(["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
                           "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
                           "OPENAI_API_KEY"])
        var result = inherited.filter { allowed.contains($0.key) }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (result["PATH"] ?? "")
        result["CODEX_HOME"] = codexHome.path
        result["CODEX_EXEC_SERVER_URL"] = "none"
        return result
    }

    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        guard arguments.first == "exec", !arguments.contains("resume") else {
            throw ResidentCodexPolicyError.unsafeConfiguration
        }
        guard environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw RenderHostConversationFailure.auth
        }
        // These flags and feature names were verified against this host's
        // `codex exec --help` and `codex features list`, not assumed from docs.
        let features = ["plugins", "apps", "hooks", "multi_agent", "multi_agent_v2", "shell_tool", "image_generation"]
        var safe = ["exec", "--sandbox", "read-only", "--cd", directory.path,
                    "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"]
        safe += features.flatMap { ["--disable", $0] }
        safe += ["-c", "cli_auth_credentials_store=\"file\"", "-c", "mcp_oauth_credentials_store=\"file\"",
                 "-c", "mcp_servers={}", "-c", "notify=[]", "-c", "agents.enabled=false"]
        // The built-in OpenAI provider may select stored ChatGPT/API auth.
        // This explicit provider bypasses auth-store selection entirely and
        // resolves only the already supplied environment API key.
        safe += ["-c", "model_provider=\"gmgn_probe_openai\"",
                 "-c", "model_providers.gmgn_probe_openai={name=\"OpenAI API\",base_url=\"https://api.openai.com/v1\",env_key=\"OPENAI_API_KEY\",wire_api=\"responses\",requires_openai_auth=false}"]
        safe += Array(arguments.dropFirst())
        let result = try await ResidentClaudeProcessRunner(executableURL: executable,
            environment: environment, workingDirectoryURL: directory).run(arguments: safe, standardInput: standardInput)
        guard result.exitCode == 0 else { throw RenderHostConversationFailure.classify(result.output) }
        return result
    }
}

private func bridgeJSON(_ value: [String: Any]) -> UInt? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return strdup(string).map { UInt(bitPattern: $0) }
}

@_cdecl("gmgn_render_host_chat_configure")
func gmgnRenderHostChatConfigure(_ pointer: UnsafeMutableRawPointer?, _ backendPointer: UnsafePointer<CChar>?) -> Int32 {
    guard Thread.isMainThread, let pointer, let backendPointer else { return 0 }
    let address = UInt(bitPattern: pointer)
    let backend = String(cString: backendPointer)
    guard ["codex", "claude-code"].contains(backend) else { return 0 }
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        do {
            host.chat?.cancel()
            host.chat = try RenderHostResidentConversation(backend: backend, dataRoot: host.dataRoot, defaults: host.defaults)
            return 1
        } catch { return 0 }
    }
}

@_cdecl("gmgn_render_host_chat_send")
func gmgnRenderHostChatSend(_ pointer: UnsafeMutableRawPointer?, _ requestID: UInt64, _ textPointer: UnsafePointer<CChar>?) -> Int32 {
    guard Thread.isMainThread, let pointer, let textPointer else { return 0 }
    let address = UInt(bitPattern: pointer), text = String(cString: textPointer)
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        return host.chat?.send(requestID: requestID, text: text) == true ? 1 : 0
    }
}

@_cdecl("gmgn_render_host_chat_cancel")
func gmgnRenderHostChatCancel(_ pointer: UnsafeMutableRawPointer?, _ requestID: UInt64) -> Int32 {
    guard Thread.isMainThread, let pointer else { return 0 }
    let address = UInt(bitPattern: pointer)
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        guard let chat = host.chat else { return 0 }
        return chat.cancel(requestID: requestID) ? 1 : 0
    }
}

@_cdecl("gmgn_render_host_chat_poll")
func gmgnRenderHostChatPoll(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    renderHostChatSnapshot(pointer, drain: true)
}

@_cdecl("gmgn_render_host_chat_context")
func gmgnRenderHostChatContext(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    renderHostChatSnapshot(pointer, drain: false)
}

private func renderHostChatSnapshot(_ pointer: UnsafeMutableRawPointer?, drain: Bool) -> UnsafeMutablePointer<CChar>? {
    guard Thread.isMainThread, let pointer else { return nil }
    let address = UInt(bitPattern: pointer)
    let stringAddress: UInt? = MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        guard let chat = host.chat else {
            let state: [String: Any] = ["configured": false, "isThinking": false, "canStop": false,
                                       "draft": "", "reply": "", "transcript": [], "deliveryMode": "final-response"]
            return bridgeJSON(drain ? ["events": [], "state": state] : state)
        }
        return bridgeJSON(drain ? chat.poll() : chat.state)
    }
    return stringAddress.flatMap { UnsafeMutablePointer<CChar>(bitPattern: $0) }
}
