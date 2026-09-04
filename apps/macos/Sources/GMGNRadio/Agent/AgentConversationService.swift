import Foundation

// MARK: - Backend registry

/// Live Cam 文字聊天可用的 Agent 后端。
enum AgentConversationBackendID:
    String, CaseIterable, Codable, Sendable, Identifiable
{
    case codex
    case dsh
    case claudeCode
    case workbuddy
    case qoder
    case pi
}

struct AgentConversationBackend: Sendable, Equatable, Identifiable {
    let kind: AgentConversationBackendID
    let displayName: String
    /// 依次探测的可执行文件名；第一个命中的作为该后端的入口。
    let executableNames: [String]
    /// 是否支持由后端原生保存会话并续聊。
    let supportsNativeContinuation: Bool

    var id: AgentConversationBackendID { kind }
}

enum AgentConversationBackends {
    /// 首选顺序：优先 Codex，其后按稳定性排列。
    static let preferredOrder: [AgentConversationBackendID] = [
        .codex,
        .claudeCode,
        .dsh,
        .workbuddy,
        .qoder,
        .pi,
    ]

    static let all: [AgentConversationBackend] = [
        AgentConversationBackend(
            kind: .codex,
            displayName: "Codex",
            executableNames: ["codex"],
            supportsNativeContinuation: true
        ),
        AgentConversationBackend(
            kind: .dsh,
            displayName: "DSH",
            executableNames: ["dsh"],
            supportsNativeContinuation: false
        ),
        AgentConversationBackend(
            kind: .claudeCode,
            displayName: "Claude Code",
            executableNames: ["claude"],
            supportsNativeContinuation: true
        ),
        AgentConversationBackend(
            kind: .workbuddy,
            displayName: "WorkBuddy",
            executableNames: ["workbuddy"],
            supportsNativeContinuation: false
        ),
        AgentConversationBackend(
            kind: .qoder,
            displayName: "Qoder",
            executableNames: ["qoder"],
            supportsNativeContinuation: false
        ),
        AgentConversationBackend(
            kind: .pi,
            displayName: "Pi",
            executableNames: ["pi"],
            supportsNativeContinuation: false
        ),
    ]

    static func backend(
        for id: AgentConversationBackendID
    ) -> AgentConversationBackend {
        all.first { $0.kind == id } ?? all[0]
    }
}

// MARK: - Messages & errors

struct AgentConversationMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case agent
    }

    let role: Role
    let text: String
}

enum AgentConversationError: Error, LocalizedError {
    case backendNotInstalled(AgentConversationBackendID)
    case protocolPending(AgentConversationBackendID)
    case emptyReply
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .backendNotInstalled(id):
            "\(AgentConversationBackends.backend(for: id).displayName) 尚未安装，"
                + "请先安装或在设置里选择其它后端。"
        case let .protocolPending(id):
            "\(AgentConversationBackends.backend(for: id).displayName) 已安装，"
                + "但接入协议尚未完成，暂时无法发送。"
        case .emptyReply:
            "Agent 没有返回内容，请稍后再试。"
        case .cancelled:
            "已取消本次回复。"
        }
    }
}

// MARK: - Executable discovery

protocol AgentExecutableLocating: Sendable {
    func locate(executableNames: [String]) -> URL?
}

/// 只探测系统标准目录和当前 PATH，不依赖用户家目录。
struct AgentExecutableLocator: AgentExecutableLocating {
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func locate(executableNames: [String]) -> URL? {
        let standardDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for name in executableNames {
            for directory in standardDirectories + pathDirectories {
                let candidate = URL(filePath: directory)
                    .appending(path: name)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

// MARK: - Preferences

enum AgentConversationPreferenceKeys {
    static let selectedBackend = "agentConversation.backend"
    static let autoSpeakReplies = "agentConversation.autoSpeakReplies"
    static func sessionKey(
        for id: AgentConversationBackendID
    ) -> String {
        "agentConversation.session.\(id.rawValue)"
    }
}

/// 后端选择与自动朗读等轻量偏好，全部落在 UserDefaults。
@MainActor
struct AgentConversationPreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedBackendID: AgentConversationBackendID? {
        get {
            defaults
                .string(forKey: AgentConversationPreferenceKeys.selectedBackend)
                .flatMap(AgentConversationBackendID.init(rawValue:))
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.rawValue,
                    forKey: AgentConversationPreferenceKeys.selectedBackend
                )
            } else {
                defaults.removeObject(
                    forKey: AgentConversationPreferenceKeys.selectedBackend
                )
            }
        }
    }

    var autoSpeakReplies: Bool {
        get {
            defaults.object(
                forKey: AgentConversationPreferenceKeys.autoSpeakReplies
            ) as? Bool ?? true
        }
        set {
            defaults.set(
                newValue,
                forKey: AgentConversationPreferenceKeys.autoSpeakReplies
            )
        }
    }

    func sessionID(for id: AgentConversationBackendID) -> String? {
        defaults.string(
            forKey: AgentConversationPreferenceKeys.sessionKey(for: id)
        )
    }

    func saveSessionID(
        _ sessionID: String?,
        for id: AgentConversationBackendID
    ) {
        let key = AgentConversationPreferenceKeys.sessionKey(for: id)
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Outcome

struct AgentConversationOutcome: Sendable {
    let reply: String
    /// 需要持久化的会话标识（Codex thread id / Claude Code session id）。
    let sessionID: String?
}

// MARK: - Service

/// 统一的 Agent 文字对话入口：负责后端选择、安装探测、会话标识与发送。
/// Live Cam 只与这个服务对话，不感知具体后端分支。
@MainActor
final class AgentConversationService {
    static let shared = AgentConversationService()

    private let locator: any AgentExecutableLocating
    private let preferences: AgentConversationPreferences
    private let runnerFactory: @Sendable (URL) -> any CodexCommandRunning
    private var currentTask: Task<AgentConversationOutcome, Error>?

    init(
        locator: any AgentExecutableLocating = AgentExecutableLocator(),
        defaults: UserDefaults = .standard,
        runnerFactory: @escaping @Sendable (URL) -> any CodexCommandRunning =
            { AgentCommandRunner(executableURL: $0) }
    ) {
        self.locator = locator
        self.preferences = AgentConversationPreferences(defaults: defaults)
        self.runnerFactory = runnerFactory
    }

    var preferenceStore: AgentConversationPreferences {
        preferences
    }

    // MARK: Installation

    func installedBackends() -> [AgentConversationBackend] {
        AgentConversationBackends.all.filter { isInstalled($0.kind) }
    }

    func isInstalled(_ id: AgentConversationBackendID) -> Bool {
        locator.locate(
            executableNames: AgentConversationBackends
                .backend(for: id).executableNames
        ) != nil
    }

    /// 默认选第一个已安装后端（优先 Codex）；一个都没装时回退 Codex。
    func defaultBackendID() -> AgentConversationBackendID {
        let installed = Set(installedBackends().map(\.kind))
        return AgentConversationBackends.preferredOrder
            .first { installed.contains($0) } ?? .codex
    }

    /// 当前生效的后端：用户已保存的选择优先，否则取默认。
    var effectiveBackendID: AgentConversationBackendID {
        preferences.selectedBackendID ?? defaultBackendID()
    }

    func selectBackend(_ id: AgentConversationBackendID) {
        preferences.selectedBackendID = id
        currentTask?.cancel()
        currentTask = nil
    }

    func resetSession() {
        currentTask?.cancel()
        currentTask = nil
        preferences.saveSessionID(nil, for: effectiveBackendID)
    }

    func cancel() {
        currentTask?.cancel()
    }

    // MARK: Sending

    func send(
        _ text: String,
        history: [AgentConversationMessage] = []
    ) async throws -> String {
        let id = effectiveBackendID
        guard isInstalled(id) else {
            throw AgentConversationError.backendNotInstalled(id)
        }
        switch id {
        case .codex:
            let resumeSessionID = preferences.sessionID(for: .codex)
            let executableLocator = locator
            let makeRunner = runnerFactory
            let prompt = text
            let outcome = try await run {
                try await Self.sendViaCodex(
                    text: prompt,
                    resumeSessionID: resumeSessionID,
                    locator: executableLocator,
                    makeRunner: makeRunner
                )
            }
            if let sessionID = outcome.sessionID {
                preferences.saveSessionID(sessionID, for: .codex)
            }
            return outcome.reply
        case .claudeCode:
            let storedSessionID = preferences.sessionID(for: .claudeCode)
            let executableLocator = locator
            let makeRunner = runnerFactory
            let prompt = text
            let outcome = try await run {
                try await Self.sendViaClaudeCode(
                    text: prompt,
                    sessionID: storedSessionID,
                    locator: executableLocator,
                    makeRunner: makeRunner
                )
            }
            if let sessionID = outcome.sessionID {
                preferences.saveSessionID(sessionID, for: .claudeCode)
            }
            return outcome.reply
        case .dsh:
            let executableLocator = locator
            let makeRunner = runnerFactory
            let outcome = try await run {
                try await Self.sendViaDSH(
                    text: text,
                    history: history,
                    locator: executableLocator,
                    makeRunner: makeRunner
                )
            }
            return outcome.reply
        case .workbuddy, .qoder, .pi:
            throw AgentConversationError.protocolPending(id)
        }
    }

    private func run(
        _ operation: @escaping @Sendable () async throws
            -> AgentConversationOutcome
    ) async throws -> AgentConversationOutcome {
        let task = Task { try await operation() }
        currentTask = task
        defer { currentTask = nil }
        let outcome = try await task.value
        try Task.checkCancellation()
        return outcome
    }

    // MARK: - Codex

    /// `codex exec --json`：thread.started 提供 thread id，
    /// 后续轮次用 `codex exec resume <thread-id> --json` 续聊。
    private static func sendViaCodex(
        text: String,
        resumeSessionID: String?,
        locator: any AgentExecutableLocating,
        makeRunner: @Sendable (URL) -> any CodexCommandRunning
    ) async throws -> AgentConversationOutcome {
        guard
            let executable = locator.locate(
                executableNames: AgentConversationBackends
                    .backend(for: .codex).executableNames
            )
        else {
            throw AgentConversationError.backendNotInstalled(.codex)
        }
        var arguments = ["exec"]
        if let resumeSessionID, !resumeSessionID.isEmpty {
            arguments += ["resume", resumeSessionID]
        }
        arguments += ["--json", "-"]
        let result = try await makeRunner(executable)
            .run(arguments: arguments, standardInput: text)
        guard result.exitCode == 0 else {
            throw CodexCLIError.commandFailed(result.output)
        }
        let parsed = parseCodexEvents(result.output)
        guard let reply = parsed.reply, !reply.isEmpty else {
            throw AgentConversationError.emptyReply
        }
        return AgentConversationOutcome(
            reply: reply,
            sessionID: parsed.threadID
        )
    }

    /// 解析 `codex exec --json` 的事件流。
    nonisolated static func parseCodexEvents(
        _ output: String
    ) -> (threadID: String?, reply: String?) {
        var threadID: String?
        var reply: String?
        for line in output.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(
                    with: data
                )) as? [String: Any]
            else {
                continue
            }
            switch object["type"] as? String {
            case "thread.started":
                threadID = object["thread_id"] as? String ?? threadID
            case "agent_message":
                let text = messageText(from: object)
                if let text, !text.isEmpty {
                    reply = text
                }
            case "item.completed":
                if let item = object["item"] as? [String: Any],
                    (item["type"] as? String) == "agent_message",
                    let text = item["text"] as? String,
                    !text.isEmpty
                {
                    reply = text
                }
            case "turn.completed":
                if let text = object["result"] as? String, !text.isEmpty {
                    reply = text
                }
            default:
                continue
            }
        }
        return (threadID, reply)
    }

    nonisolated private static func messageText(
        from object: [String: Any]
    ) -> String? {
        (object["message"] as? String) ?? (object["text"] as? String)
    }

    // MARK: - Claude Code

    /// `claude -p --output-format json --session-id <uuid>`，
    /// 后续轮次改用 `--resume <uuid>`。
    private static func sendViaClaudeCode(
        text: String,
        sessionID: String?,
        locator: any AgentExecutableLocating,
        makeRunner: @Sendable (URL) -> any CodexCommandRunning
    ) async throws -> AgentConversationOutcome {
        guard
            let executable = locator.locate(
                executableNames: AgentConversationBackends
                    .backend(for: .claudeCode).executableNames
            )
        else {
            throw AgentConversationError.backendNotInstalled(.claudeCode)
        }
        let isResume = sessionID?.isEmpty == false
        let session = isResume ? sessionID! : UUID().uuidString
        var arguments = ["-p", text, "--output-format", "json"]
        if isResume {
            arguments += ["--resume", session]
        } else {
            arguments += ["--session-id", session]
        }
        let result = try await makeRunner(executable)
            .run(arguments: arguments, standardInput: nil)
        guard result.exitCode == 0 else {
            throw AgentConversationError.emptyReply
        }
        let parsed = parseClaudeCodeOutput(result.output)
        guard let reply = parsed.reply, !reply.isEmpty else {
            throw AgentConversationError.emptyReply
        }
        let reportedSessionID = parsed.sessionID ?? session
        return AgentConversationOutcome(
            reply: reply,
            sessionID: reportedSessionID
        )
    }

    nonisolated static func parseClaudeCodeOutput(
        _ output: String
    ) -> (reply: String?, sessionID: String?) {
        guard
            let data = output.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(
                with: data
            )) as? [String: Any]
        else {
            return (nil, nil)
        }
        return (object["result"] as? String, object["session_id"] as? String)
    }

    // MARK: - DSH

    /// `dsh --profile headless <prompt>`；无原生续聊，
    /// 由应用附带有限的最近历史保持语境。
    private static func sendViaDSH(
        text: String,
        history: [AgentConversationMessage],
        locator: any AgentExecutableLocating,
        makeRunner: @Sendable (URL) -> any CodexCommandRunning
    ) async throws -> AgentConversationOutcome {
        guard
            let executable = locator.locate(
                executableNames: AgentConversationBackends
                    .backend(for: .dsh).executableNames
            )
        else {
            throw AgentConversationError.backendNotInstalled(.dsh)
        }
        let prompt = dshPrompt(text: text, history: history)
        let result = try await makeRunner(executable)
            .run(
                arguments: ["--profile", "headless", prompt],
                standardInput: nil
            )
        guard result.exitCode == 0, !result.output.isEmpty else {
            throw AgentConversationError.emptyReply
        }
        return AgentConversationOutcome(reply: result.output, sessionID: nil)
    }

    /// DSH 没有原生续聊，由应用附带有限的最近历史保持语境。
    nonisolated static func dshPrompt(
        text: String,
        history: [AgentConversationMessage]
    ) -> String {
        var lines = [String]()
        for message in history.suffix(6) {
            switch message.role {
            case .user:
                lines.append("用户：\(message.text)")
            case .agent:
                lines.append("助手：\(message.text)")
            }
        }
        lines.append("用户：\(text)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Generic command runner

/// 基于 Process 的通用命令执行器，复用 CodexProcessRunner 的进程封装。
struct AgentCommandRunner: CodexCommandRunning {
    private let base: CodexProcessRunner

    init(executableURL: URL? = nil) {
        let url = executableURL
            ?? CodexProcessRunner.locate()
            ?? URL(filePath: "/usr/bin/false")
        base = CodexProcessRunner(executableURL: url)
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        try await base.run(
            arguments: arguments,
            standardInput: standardInput
        )
    }
}
