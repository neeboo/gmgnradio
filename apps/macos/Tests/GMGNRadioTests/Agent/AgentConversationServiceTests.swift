import Foundation
import Testing
@testable import GMGNRadio

// MARK: - Test doubles

private struct StubLocator: AgentExecutableLocating {
    let installedNames: Set<String>

    func locate(executableNames: [String]) -> URL? {
        guard
            let name = executableNames.first(
                where: { installedNames.contains($0) }
            )
        else {
            return nil
        }
        return URL(filePath: "/usr/local/bin/\(name)")
    }
}

private final class RecordedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ name: String) {
        lock.lock()
        storage.append(name)
        lock.unlock()
    }
}

/// 按可执行文件名分发固定输出并记录调用的测试 runner，
/// 验证 runnerFactory 注入对所有后端生效。
private final class DispatchedRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let executableName: String
    private let outputs: [String: String]
    private let recorded: RecordedCalls

    init(
        executableName: String,
        outputs: [String: String],
        recorded: RecordedCalls
    ) {
        self.executableName = executableName
        self.outputs = outputs
        self.recorded = recorded
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        recorded.append(executableName)
        return CodexCommandResult(
            exitCode: 0,
            output: outputs[executableName] ?? ""
        )
    }
}

/// 记录最后一次 prompt（DSH 场景）的测试 runner。
private final class PromptCaptureRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String] = []

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func record(_ prompt: String) {
        lock.lock()
        storage.append(prompt)
        lock.unlock()
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        record(arguments.last ?? "")
        return CodexCommandResult(exitCode: 0, output: "好的")
    }
}

private func makeDefaults() -> UserDefaults {
    let name = "AgentConversationServiceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func jsonResultOutput(
    result: String,
    sessionID: String?
) -> String {
    var object: [String: Any] = ["result": result]
    if let sessionID {
        object["session_id"] = sessionID
    }
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func isUUID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
}

// MARK: - Registry & installation

@Test
func conversationBackendRegistryCoversAllSixBackends() {
    let ids = AgentConversationBackends.all.map(\.kind)
    #expect(ids.count == 6)
    #expect(Set(ids) == Set(AgentConversationBackendID.allCases))
    #expect(
        AgentConversationBackends.all.allSatisfy { !$0.displayName.isEmpty }
    )
    #expect(
        AgentConversationBackends.all.allSatisfy { !$0.executableNames.isEmpty }
    )
    // 唯一性
    #expect(Set(ids).count == ids.count)
    // DSH 与 Claude Code 无原生续聊（各自由服务维护有界历史）；其余支持原生续聊。
    for backend in AgentConversationBackends.all {
        #expect(
            backend.supportsNativeContinuation
                == (backend.kind != .dsh && backend.kind != .claudeCode)
        )
    }
}

@Test
func preferredOrderPutsCodexFirst() {
    #expect(AgentConversationBackends.preferredOrder.first == .codex)
}

@Test
func workbuddyProbesCodebuddyFirst() {
    let backend = AgentConversationBackends.backend(for: .workbuddy)
    #expect(backend.executableNames.first == "codebuddy")
    #expect(backend.executableNames.contains("workbuddy"))
}

@MainActor
@Test
func installedBackendsReflectLocatorResults() {
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex", "qoder"]),
        defaults: makeDefaults()
    )
    let installed = service.installedBackends().map(\.kind)
    #expect(installed.contains(.codex))
    #expect(installed.contains(.qoder))
    #expect(!installed.contains(.claudeCode))
    #expect(!installed.contains(.dsh))
    #expect(!installed.contains(.workbuddy))
    #expect(!installed.contains(.pi))
}

// MARK: - Selection persistence

@MainActor
@Test
func defaultBackendPrefersFirstInstalledBackend() {
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["dsh", "qoder"]),
        defaults: makeDefaults()
    )
    #expect(service.defaultBackendID() == .dsh)
    #expect(service.effectiveBackendID == .dsh)
}

@MainActor
@Test
func selectedBackendPersistsAcrossServiceInstances() {
    let defaults = makeDefaults()
    let first = AgentConversationService(
        locator: StubLocator(installedNames: ["codex", "claude"]),
        defaults: defaults
    )
    first.selectBackend(.claudeCode)

    let second = AgentConversationService(
        locator: StubLocator(installedNames: ["codex", "claude"]),
        defaults: defaults
    )
    #expect(second.effectiveBackendID == .claudeCode)
}

@MainActor
@Test
func defaultBackendFallsBackToCodexWhenNothingInstalled() {
    let service = AgentConversationService(
        locator: StubLocator(installedNames: []),
        defaults: makeDefaults()
    )
    #expect(service.defaultBackendID() == .codex)
}

// MARK: - Routing without realtime voice

@MainActor
@Test
func sendRoutesTextWithoutRealtimeVoiceConnection() async throws {
    RealtimeVoiceStatusStore.shared.state = .disconnected
    defer { RealtimeVoiceStatusStore.shared.state = .disconnected }

    let output = """
        {"type":"thread.started","thread_id":"thread-123"}
        {"type":"agent_message","message":"晚上好，欢迎回来。"}
        """
    let recorded = RecordedCalls()
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { url in
            DispatchedRunner(
                executableName: url.lastPathComponent,
                outputs: ["codex": output],
                recorded: recorded
            )
        }
    )
    let reply = try await service.send("你好")
    #expect(reply == "晚上好，欢迎回来。")
    #expect(recorded.names == ["codex"])
}

// MARK: - runnerFactory injection for all six backends

@MainActor
@Test
func runnerFactoryIsUsedForEveryBackend() async throws {
    let outputs: [String: String] = [
        "codex": """
        {"type":"thread.started","thread_id":"t-1"}
        {"type":"agent_message","message":"codex 回复"}
        """,
        "dsh": "dsh 回复",
        "claude": jsonResultOutput(result: "claude 回复", sessionID: "c-1"),
        "codebuddy": jsonResultOutput(
            result: "workbuddy 回复",
            sessionID: "w-1"
        ),
        "qoder": jsonResultOutput(result: "qoder 回复", sessionID: "q-1"),
        "pi": """
        {"type":"session","id":"p-1"}
        {"type":"message_end","message":{"content":"pi 回复"}}
        """,
    ]
    let recorded = RecordedCalls()
    // Claude Code 走专用安全分支与专用 runner seam，注入白名单环境 seam。
    let claudeRunnerFactory: AgentConversationService.ClaudeRunnerFactory = { url, _, _, _ in
        DispatchedRunner(
            executableName: url.lastPathComponent,
            outputs: outputs,
            recorded: recorded
        )
    }
    let service = AgentConversationService(
        locator: StubLocator(
            installedNames: [
                "codex", "dsh", "claude", "codebuddy", "qoder", "pi",
            ]
        ),
        defaults: makeDefaults(),
        runnerFactory: { url in
            DispatchedRunner(
                executableName: url.lastPathComponent,
                outputs: outputs,
                recorded: recorded
            )
        },
        claudeRunnerFactory: claudeRunnerFactory,
        claudeEnvironmentProvider: { _ in ["ANTHROPIC_API_KEY": "test-key"] }
    )
    let expected: [AgentConversationBackendID: String] = [
        .codex: "codex 回复",
        .dsh: "dsh 回复",
        .claudeCode: "claude 回复",
        .workbuddy: "workbuddy 回复",
        .qoder: "qoder 回复",
        .pi: "pi 回复",
    ]
    for (kind, reply) in expected {
        service.selectBackend(kind)
        let actual = try await service.send("你好")
        #expect(actual == reply)
    }
    #expect(recorded.names.count == 6)
    #expect(
        Set(recorded.names)
            == ["codex", "dsh", "claude", "codebuddy", "qoder", "pi"]
    )
}

// MARK: - JSON-result CLI arguments (WorkBuddy / Qoder / Claude Code)

@Test
func workbuddyArgumentsUseResumeContinuation() {
    let first = AgentConversationService.jsonResultCLIArguments(
        kind: .workbuddy,
        text: "第一轮",
        sessionID: nil,
        isResume: false
    )
    #expect(first == ["-p", "第一轮", "--output-format", "json"])

    let resume = AgentConversationService.jsonResultCLIArguments(
        kind: .workbuddy,
        text: "第二轮",
        sessionID: "wb-session-1",
        isResume: true
    )
    #expect(
        resume
            == [
                "-p", "--resume", "wb-session-1", "第二轮",
                "--output-format", "json",
            ]
    )
}

@Test
func qoderArgumentsUseGeneratedSessionIDThenResume() {
    let first = AgentConversationService.jsonResultCLIArguments(
        kind: .qoder,
        text: "你好",
        sessionID: nil,
        isResume: false
    )
    #expect(first.count == 6)
    #expect(first.dropFirst(4).first == "--session-id")
    #expect(isUUID(first.last ?? ""))

    let resume = AgentConversationService.jsonResultCLIArguments(
        kind: .qoder,
        text: "继续",
        sessionID: "qoder-9",
        isResume: true
    )
    #expect(
        resume
            == ["-p", "继续", "--output-format", "json", "--resume", "qoder-9"]
    )
}

/// Claude Code 已从通用 JSON CLI 协议迁出：通用协议不再返回任何 Claude 参数，
/// 专用分支由 `claudeArguments` 生成固定安全前缀（无 WebSearch/WebFetch，无
/// resume/session-id，无内建工具）。
@Test
func claudeCodeIsRemovedFromGenericJSONCLIProtocol() {
    #expect(
        AgentConversationService.jsonResultCLIArguments(
            kind: .claudeCode,
            text: "你好",
            sessionID: nil,
            isResume: false
        ).isEmpty
    )
    #expect(
        AgentConversationService.jsonResultCLIArguments(
            kind: .claudeCode,
            text: "继续",
            sessionID: "claude-7",
            isResume: true
        ).isEmpty
    )
}

@Test
func claudeCodeArgumentsUseOnlyTheRestrictedMCPPrefix() {
    let path = "/private/tmp/gmgn-claude-test/config.json"
    let chat = AgentConversationService.claudeArguments(
        mcpConfigPath: path,
        allowedToolNames: []
    )
    #expect(chat.first == "--bare")
    #expect(chat.contains("--print"))
    #expect(Array(chat[chat.firstIndex(of: "--output-format")!...].prefix(2)) == ["--output-format", "json"])
    #expect(chat.contains("--no-session-persistence"))
    #expect(chat[chat.firstIndex(of: "--tools")! + 1] == "")
    #expect(chat.contains("--strict-mcp-config"))
    #expect(chat.contains("--disable-slash-commands"))
    #expect(chat[chat.firstIndex(of: "--setting-sources")! + 1] == "")
    #expect(chat[chat.firstIndex(of: "--settings")! + 1] == "{\"disableAllHooks\":true}")
    #expect(chat[chat.firstIndex(of: "--permission-mode")! + 1] == "dontAsk")
    #expect(chat[chat.firstIndex(of: "--mcp-config")! + 1] == path)
    #expect(!chat.contains("--allowedTools"))
    #expect(!chat.contains("--resume"))
    #expect(!chat.contains("--session-id"))
    #expect(!chat.contains(where: { $0.contains("WebSearch") || $0.contains("WebFetch") }))

    let tools = AgentConversationService.claudeArguments(
        mcpConfigPath: path,
        allowedToolNames: ["mcp__gmgn-resident-tools__gmgn_read_wish_generation"]
    )
    let allowedIndex = tools.firstIndex(of: "--allowedTools")!
    #expect(Array(tools[(allowedIndex + 1)...]) == ["mcp__gmgn-resident-tools__gmgn_read_wish_generation"])
    #expect(!tools.contains("mcp__gmgn-resident-tools"))
    #expect(!tools.contains(where: { $0.contains("WebSearch") || $0.contains("WebFetch") }))
    #expect(!tools.contains("--dangerously-skip-permissions"))
}

@MainActor
@Test
func claudeCodeUsesDedicatedRunnerSeamAndNeverResumes() async throws {
    let recorded = RecordedCalls()
    let environments = RecordedCalls()
    let defaults = makeDefaults()
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["claude"]),
        defaults: defaults,
        claudeRunnerFactory: { _, environment, _, _ in
            environments.append(environment["ANTHROPIC_API_KEY"] ?? "missing")
            return DispatchedRunner(
                executableName: "claude",
                outputs: ["claude": jsonResultOutput(result: "claude 回复", sessionID: "c-1")],
                recorded: recorded
            )
        },
        claudeEnvironmentProvider: { _ in ["ANTHROPIC_API_KEY": "test-key"] }
    )
    service.selectBackend(.claudeCode)
    #expect(service.supportsWorldTools)
    let reply = try await service.send("你好")
    #expect(reply == "claude 回复")
    #expect(recorded.names == ["claude"])
    #expect(environments.names == ["test-key"])
    // 假 session_id 绝不写入偏好：Claude 每轮 fresh。
    #expect(service.preferenceStore.sessionID(for: .claudeCode, scope: nil) == nil)
    _ = try await service.send("继续")
    #expect(service.preferenceStore.sessionID(for: .claudeCode, scope: nil) == nil)
    #expect(recorded.names == ["claude", "claude"])
}

@MainActor
@Test
func claudeCodeMissingCredentialFailsBeforeSpawn() async {
    let recorded = RecordedCalls()
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["claude"]),
        defaults: makeDefaults(),
        claudeRunnerFactory: { _, _, _, _ in
            recorded.append("spawned")
            return DispatchedRunner(executableName: "claude", outputs: [:], recorded: recorded)
        },
        claudeEnvironmentProvider: { _ in nil }
    )
    service.selectBackend(.claudeCode)
    await #expect(throws: (any Error).self) {
        _ = try await service.send("你好")
    }
    #expect(recorded.names.isEmpty)
}

@MainActor
@Test
func workbuddySessionResumesAcrossTurns() async throws {
    let recorded = RecordedCalls()
    let outputs = [
        "codebuddy": jsonResultOutput(
            result: "第一答",
            sessionID: "wb-session-1"
        ),
    ]
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codebuddy"]),
        defaults: makeDefaults(),
        runnerFactory: { url in
            DispatchedRunner(
                executableName: url.lastPathComponent,
                outputs: outputs,
                recorded: recorded
            )
        }
    )
    service.selectBackend(.workbuddy)
    let first = try await service.send("第一轮")
    #expect(first == "第一答")
    // session id 由 JSON 报告并持久化，后续轮次走 resume 协议。
    let stored = service.preferenceStore.sessionID(for: .workbuddy)
    #expect(stored == "wb-session-1")
}

@MainActor
@Test
func qoderStoresReportedSessionID() async throws {
    let recorded = RecordedCalls()
    let outputs = [
        "qoder": jsonResultOutput(result: "qoder 答", sessionID: "qoder-77"),
    ]
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["qoder"]),
        defaults: makeDefaults(),
        runnerFactory: { url in
            DispatchedRunner(
                executableName: url.lastPathComponent,
                outputs: outputs,
                recorded: recorded
            )
        }
    )
    service.selectBackend(.qoder)
    _ = try await service.send("第一轮")
    #expect(service.preferenceStore.sessionID(for: .qoder) == "qoder-77")
}

// MARK: - Pi protocol

@Test
func piArgumentsUseModeJSONAndSessionResume() {
    let first = AgentConversationService.piCLIArguments(
        text: "你好",
        sessionID: nil
    )
    #expect(first == ["--mode", "json", "-p", "你好"])

    let resume = AgentConversationService.piCLIArguments(
        text: "继续",
        sessionID: "pi-3"
    )
    #expect(resume == ["--mode", "json", "-p", "继续", "--session", "pi-3"])
}

@Test
func parsePiEventsReadsSessionIDAndFinalStringContent() {
    let output = """
        {"type":"session","id":"pi-42"}
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"你"}}
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"好"}}
        {"type":"message_end","message":{"content":"最终答案"}}
        """
    let parsed = AgentConversationService.parsePiEvents(output)
    #expect(parsed.sessionID == "pi-42")
    #expect(parsed.reply == "最终答案")
}

@Test
func parsePiEventsHandlesArrayContentAndDeltasOnly() {
    let arrayOutput = """
        {"type":"session","id":"pi-1"}
        {"type":"turn_end","message":{"content":[{"type":"text","text":"第一段"},{"text":"第二段"}]}}
        """
    let arrayParsed = AgentConversationService.parsePiEvents(arrayOutput)
    #expect(arrayParsed.sessionID == "pi-1")
    #expect(arrayParsed.reply == "第一段第二段")

    let deltaOnly = """
        {"type":"session","id":"pi-2"}
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"增量"}}
        """
    let deltaParsed = AgentConversationService.parsePiEvents(deltaOnly)
    #expect(deltaParsed.reply == "增量")

    // 兼容旧顶层 text_delta 字段。
    let legacyDelta = """
        {"type":"session","id":"pi-3"}
        {"type":"message_update","text_delta":"旧增量"}
        """
    let legacyParsed = AgentConversationService.parsePiEvents(legacyDelta)
    #expect(legacyParsed.reply == "旧增量")
}

@MainActor
@Test
func piSessionIDIsStoredForResume() async throws {
    let recorded = RecordedCalls()
    let outputs = [
        "pi": """
        {"type":"session","id":"pi-42"}
        {"type":"message_end","message":{"content":"pi 答"}}
        """,
    ]
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["pi"]),
        defaults: makeDefaults(),
        runnerFactory: { url in
            DispatchedRunner(
                executableName: url.lastPathComponent,
                outputs: outputs,
                recorded: recorded
            )
        }
    )
    service.selectBackend(.pi)
    let reply = try await service.send("你好")
    #expect(reply == "pi 答")
    #expect(service.preferenceStore.sessionID(for: .pi) == "pi-42")
}

// MARK: - DSH history

@Test
func dshPromptEmbedsLimitedHistory() {
    let history = [
        AgentConversationMessage(role: .user, text: "第一轮"),
        AgentConversationMessage(role: .agent, text: "第一答"),
        AgentConversationMessage(role: .user, text: "第二轮"),
        AgentConversationMessage(role: .agent, text: "第二答"),
    ]
    let prompt = AgentConversationService.dshPrompt(
        text: "第三轮",
        history: history
    )
    #expect(prompt.contains("用户：第一轮"))
    #expect(prompt.contains("助手：第二答"))
    #expect(prompt.hasSuffix("用户：第三轮"))
}

@MainActor
@Test
func dshAccumulatesHistoryAcrossTurnsAndClearsOnBackendSwitch()
async throws {
    let capture = PromptCaptureRunner()
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["dsh"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in capture }
    )
    _ = try await service.send("第一轮")
    _ = try await service.send("第二轮")
    #expect(capture.prompts.count == 2)
    #expect(capture.prompts[0].hasSuffix("用户：第一轮"))
    // 服务内部维护历史：第二轮 prompt 应包含第一轮与回复。
    #expect(capture.prompts[1].contains("用户：第一轮"))
    #expect(capture.prompts[1].contains("助手：好的"))
    #expect(capture.prompts[1].hasSuffix("用户：第二轮"))

    // 切换后端（含重选自身）清空内存历史。
    service.selectBackend(.dsh)
    _ = try await service.send("第三轮")
    #expect(capture.prompts[2] == "用户：第三轮")
}

// MARK: - Codex parsing

@Test
func parseCodexEventsExtractsThreadIDAndFinalAgentMessage() {
    let output = """
        {"type":"thread.started","thread_id":"thread-abc"}
        {"type":"agent_message","message":"第一段"}
        {"type":"item.completed","item":{"type":"agent_message","text":"最终回复"}}
        """
    let parsed = AgentConversationService.parseCodexEvents(output)
    #expect(parsed.threadID == "thread-abc")
    #expect(parsed.reply == "最终回复")
}

@Test
func parseJSONResultOutputExtractsReplyAndSessionID() {
    let output = jsonResultOutput(result: "你好", sessionID: "sid-1")
    let parsed = AgentConversationService.parseJSONResultOutput(output)
    #expect(parsed.reply == "你好")
    #expect(parsed.sessionID == "sid-1")
}

// MARK: - Errors

@MainActor
@Test
func sendFailsClearlyWhenBackendNotInstalled() async {
    let service = AgentConversationService(
        locator: StubLocator(installedNames: []),
        defaults: makeDefaults()
    )
    await #expect(throws: AgentConversationError.self) {
        _ = try await service.send("你好")
    }
    let error = AgentConversationError.backendNotInstalled(.codex)
    #expect(error.errorDescription?.contains("尚未安装") == true)
}

// MARK: - 居民记忆服务测试支撑（VoiceMem 编排 fixture）

/// 记录每次 codex 调用携带的 prompt 并回放固定会话输出的测试 runner。
private final class RecordingCodexRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String] = []
    let replyText: String

    init(replyText: String = "房间回复") { self.replyText = replyText }

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func record(_ prompt: String) {
        lock.lock()
        storage.append(prompt)
        lock.unlock()
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        record(arguments.last ?? "")
        return CodexCommandResult(exitCode: 0, output: """
            {"type":"thread.started","thread_id":"thread-session-1"}
            {"type":"agent_message","message":"\(replyText)"}
            """)
    }
}

/// 挂起直到测试显式 resume 的 runner（取消路径用）。
private final class SuspendableRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var pending: CheckedContinuation<CodexCommandResult, Error>?
    private var started = false

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        markStarted()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if Task.isCancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            pending = continuation
            lock.unlock()
        }
    }

    private func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func resume(_ result: CodexCommandResult) {
        lock.lock()
        pending?.resume(returning: result)
        pending = nil
        lock.unlock()
    }
}


/// 记录 resident sender 收到的 prompt/session 的测试容器。
@MainActor
private final class ResidentSenderRecorder {
    var prompts: [String] = []
    var sessions: [String?] = []
}

private func makeResidentWorld(id: String = "cabin") -> ResidentWorldContext {
    ResidentWorldContext(
        selectedWorldID: id, worldID: id, displayName: nil, revision: 1,
        residentPosition: nil, activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: []
    )
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(8)
    while !(await condition()) {
        if Date() >= deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
}


// MARK: - VoiceMem 记忆接线（ResidentConversationMemory fixture）

/// 记忆 IPC fixture：立即回放 memory_recall/memory_ingest 并记录每笔请求。
/// 只做内存模拟，不启动 daemon、不落库（替代旧的 conversation 域 store stub）。
@MainActor
private final class ConversationMemoryStubTransport: ResidentStateTransport {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var recallContext = "这位居民喜欢在雨天听爵士乐。"
    /// 注入连续 N 次调用失败（daemon 故障）。
    var failNextCalls = 0

    func call(
        method: String,
        params: [String: ResidentStateJSON]
    ) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        if failNextCalls > 0 {
            failNextCalls -= 1
            throw ResidentStateError.daemon("memory_storage_failed")
        }
        switch method {
        case "memory_recall":
            return [
                "status": .string("ok"), "revision": .number(0),
                "vectorGeneration": .number(0), "facts": .array([]),
                "notes": .array([]), "context": .string(recallContext),
                "pendingTurns": .number(0),
            ]
        case "memory_ingest":
            return [
                "accepted": .bool(true), "replayed": .bool(false),
                "pendingTurns": .number(0), "consolidation": .string("pending"),
            ]
        default:
            throw ResidentStateError.daemon("unsupported_method")
        }
    }

    func calls(_ method: String) -> [[String: ResidentStateJSON]] {
        recorded.filter { $0.method == method }.map(\.params)
    }
}

/// 记录 codex 调用真实 standardInput 的 runner（codex 文字走 standardInput；
/// 旧的 RecordingCodexRunner 记的是 arguments.last，不适合核对 prompt 内容）。
@MainActor
private final class ConversationMemoryCodexRunner: CodexCommandRunning {
    private var storage: [String] = []
    let replyText: String

    init(replyText: String = "房间回复") { self.replyText = replyText }

    var prompts: [String] { storage }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        storage.append(standardInput ?? "")
        return CodexCommandResult(exitCode: 0, output: """
            {"type":"thread.started","thread_id":"thread-session-1"}
            {"type":"agent_message","message":"\(replyText)"}
            """)
    }
}

@MainActor
@Test
func freshCodexResidentTurnRecallsRealUserTextAndIngestsOnlyAfterDeliveryConfirmation()
async throws {
    let transport = ConversationMemoryStubTransport()
    let memory = ResidentConversationMemory(transport: transport)
    let runner = ConversationMemoryCodexRunner(replyText: "嗨，欢迎回来。")
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in runner }
    )
    service.attachConversationMemory(memory)
    let world = makeResidentWorld()
    let reply = try await service.send("你好", worldContext: world)
    #expect(reply == "嗨，欢迎回来。")

    let recalls = transport.calls("memory_recall")
    #expect(recalls.count == 1, "one recall per real-text resident turn")
    #expect(recalls.first?["query"]?.stringValue == "你好", "recall query is the real user text")
    #expect(recalls.first?["freshSession"]?.boolValue == true, "no native thread -> freshSession=true")
    #expect(runner.prompts[0].contains(transport.recallContext) == true,
            "memory context is injected ahead of the fresh-session prompt")
    #expect(runner.prompts[0].contains("居民对话记录") == false,
            "no legacy durable transcript wording is injected")

    #expect(transport.calls("memory_ingest").isEmpty,
            "model return alone never ingests (no memory_ingest yet)")
    guard let requestID = service.lastTurnDeliveryRequestID else {
        #expect(Bool(false), "successful real-text turn registers a pending delivery requestID")
        return
    }
    let delivery = service.confirmDeliveredTurn(
        requestID: requestID, userText: "你好", reply: reply, source: .voice
    )
    #expect(delivery == .accepted, "explicit delivery confirmation after run/world checks is accepted")
    await eventually { !transport.calls("memory_ingest").isEmpty }
    let ingests = transport.calls("memory_ingest")
    #expect(ingests.count == 1, "confirmed delivery enqueues exactly one ingest")
    if let params = ingests.first {
        #expect(params["userText"]?.stringValue == "你好")
        #expect(params["agentReply"]?.stringValue == reply)
        #expect(params["source"]?.stringValue == "voice")
        #expect(params["requestID"]?.stringValue == requestID.uuidString)
        if case let .object(scopeObject)? = params["scope"] {
            #expect(scopeObject["worldID"]?.stringValue == "cabin")
        } else {
            #expect(Bool(false), "ingest carries an embedded scope object")
        }
    }
    let second = service.confirmDeliveredTurn(
        requestID: requestID, userText: "你好", reply: reply
    )
    #expect(second == .notCurrent, "a second confirmation for an accepted requestID is not current")
    #expect(transport.calls("memory_ingest").count == 1, "no duplicate ingest after repeated confirm")
}

@MainActor
@Test
func nativeResumeAndFreshSessionDriveMemoryFreshFlag() async throws {
    // 全新 defaults（无原生线程）→ freshSession=true。
    let freshTransport = ConversationMemoryStubTransport()
    let freshMemory = ResidentConversationMemory(transport: freshTransport)
    let freshRunner = ConversationMemoryCodexRunner(replyText: "第一答。")
    let fresh = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in freshRunner }
    )
    fresh.attachConversationMemory(freshMemory)
    let world = makeResidentWorld()
    _ = try await fresh.send("今天做什么", worldContext: world)
    #expect(freshTransport.calls("memory_recall").count == 1)
    #expect(freshTransport.calls("memory_recall")[0]["freshSession"]?.boolValue == true,
            "a brand-new native session restores with freshSession=true")
    #expect(freshTransport.calls("memory_recall")[0]["query"]?.stringValue == "今天做什么")

    // 已保存原生线程 → 续聊 freshSession=false（只取本轮相关记忆，不整段恢复）。
    let resumedDefaults = makeDefaults()
    resumedDefaults.set(
        "existing-thread", forKey: "agentConversation.session.codex.\(world.sessionScope)"
    )
    let resumedTransport = ConversationMemoryStubTransport()
    let resumedMemory = ResidentConversationMemory(transport: resumedTransport)
    let resumedRunner = ConversationMemoryCodexRunner(replyText: "第二答。")
    let resumed = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: resumedDefaults,
        runnerFactory: { _ in resumedRunner }
    )
    resumed.attachConversationMemory(resumedMemory)
    _ = try await resumed.send("继续", worldContext: world)
    #expect(resumedTransport.calls("memory_recall").count == 1)
    #expect(resumedTransport.calls("memory_recall")[0]["freshSession"]?.boolValue == false,
            "existing native thread never re-injects a full restore")
    #expect(resumedTransport.calls("memory_recall")[0]["query"]?.stringValue == "继续")
}

@MainActor
@Test
func dshFreshProcessRecallsFreshAndContinuationTurnsRecallNonFresh() async throws {
    let transport = ConversationMemoryStubTransport()
    let memory = ResidentConversationMemory(transport: transport)
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["dsh"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in PromptCaptureRunner() }
    )
    service.selectBackend(.dsh)
    service.attachConversationMemory(memory)
    let world = makeResidentWorld()
    _ = try await service.send("第一句", worldContext: world)
    #expect(transport.calls("memory_recall").count == 1)
    #expect(transport.calls("memory_recall")[0]["freshSession"]?.boolValue == true,
            "DSH without in-process history is a fresh session")
    #expect(transport.calls("memory_recall")[0]["query"]?.stringValue == "第一句")

    _ = try await service.send("第二句", worldContext: world)
    let recalls = transport.calls("memory_recall")
    #expect(recalls.count == 2, "each real-text DSH turn recalls")
    #expect(recalls[1]["freshSession"]?.boolValue == false,
            "DSH continuation with in-process history is not fresh")
    #expect(recalls[1]["query"]?.stringValue == "第二句")
    #expect(transport.calls("memory_ingest").isEmpty, "DSH turns never ingest at model return")

    guard let requestID = service.lastTurnDeliveryRequestID else {
        #expect(Bool(false), "DSH turn registers a delivery requestID")
        return
    }
    #expect(service.confirmDeliveredTurn(requestID: requestID, userText: "第二句", reply: "好的") == .accepted)
    await eventually { !transport.calls("memory_ingest").isEmpty }
    #expect(transport.calls("memory_ingest").count == 1, "DSH confirmed turn ingests exactly once")
}

@MainActor
@Test
func failedOrCancelledTurnNeverStagesNorIngests() async throws {
    let world = makeResidentWorld()

    // 后端命令失败：整轮 throw，不 stage、不 ingest。
    let failingTransport = ConversationMemoryStubTransport()
    let failingMemory = ResidentConversationMemory(transport: failingTransport)
    let failing = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in
            DispatchedRunner(
                executableName: "codex",
                outputs: ["codex": ""],
                recorded: RecordedCalls()
            )
        }
    )
    failing.attachConversationMemory(failingMemory)
    var didFail = false
    do {
        _ = try await failing.send("你好", worldContext: world)
    } catch {
        didFail = true
    }
    #expect(didFail)
    #expect(failing.lastTurnDeliveryRequestID == nil, "a failed turn stages nothing")
    #expect(failingTransport.calls("memory_ingest").isEmpty, "a failed turn never ingests")

    // 取消：挂起中的轮次被取消后即使迟到成功也不能 stage/写记忆。
    let cancelledTransport = ConversationMemoryStubTransport()
    let cancelledMemory = ResidentConversationMemory(transport: cancelledTransport)
    let suspended = SuspendableRunner()
    let cancellable = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in suspended }
    )
    cancellable.attachConversationMemory(cancelledMemory)
    let task = Task { @MainActor in
        try? await cancellable.send("你好", worldContext: world)
    }
    await eventually { suspended.didStart }
    cancellable.cancel()
    #expect(cancellable.lastTurnDeliveryRequestID == nil, "cancelled turn stages no delivery credential")
    suspended.resume(CodexCommandResult(exitCode: 0, output: """
        {"type":"thread.started","thread_id":"late-thread"}
        {"type":"agent_message","message":"迟到回复"}
        """))
    _ = await task.value
    #expect(cancelledTransport.calls("memory_ingest").isEmpty, "late success after cancel never ingests")
    #expect(cancellable.confirmDeliveredTurn(requestID: UUID(), userText: "你好", reply: "迟到回复") == .notCurrent,
            "confirming a cancelled/unknown requestID writes nothing")
}

@MainActor
@Test
func scopeSwitchAndMemoryResetRejectLateConfirmation() async throws {
    let transport = ConversationMemoryStubTransport()
    let memory = ResidentConversationMemory(transport: transport)
    let scopeRunner = ConversationMemoryCodexRunner(replyText: "先答。")
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in scopeRunner }
    )
    service.attachConversationMemory(memory)

    let cabin = makeResidentWorld(id: "cabin")
    _ = try await service.send("世界甲", worldContext: cabin)
    guard let cabinRequestID = service.lastTurnDeliveryRequestID else {
        #expect(Bool(false), "first world registers a delivery credential")
        return
    }
    let room = makeResidentWorld(id: "room")
    _ = try await service.send("世界乙", worldContext: room)
    #expect(transport.calls("memory_recall").count == 2, "each world turn recalls under its own scope")
    #expect(
        service.confirmDeliveredTurn(
            requestID: cabinRequestID, userText: "世界甲", reply: "先答。"
        ) == .notCurrent,
        "confirmation from a superseded world/scope is rejected (scope switch)"
    )
    #expect(transport.calls("memory_ingest").isEmpty, "scope-switched stale confirmation writes nothing")

    guard let roomRequestID = service.lastTurnDeliveryRequestID else {
        #expect(Bool(false), "second world registers a delivery credential")
        return
    }
    memory.reset()
    #expect(
        service.confirmDeliveredTurn(
            requestID: roomRequestID, userText: "世界乙", reply: "先答。"
        ) == .notCurrent,
        "confirmation after memory reset is rejected by the scope/generation gate"
    )
    #expect(transport.calls("memory_ingest").isEmpty, "post-reset confirmation writes nothing")
}

@MainActor
@Test
func chatWithoutMemoryWiringOrWorldScopeStillWorks() async throws {
    let world = makeResidentWorld()

    // 未接线记忆：resident 聊天照常；确认入口报 unavailable。
    let noMemoryRunner = ConversationMemoryCodexRunner(replyText: "无记忆回复。")
    let plain = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in noMemoryRunner }
    )
    let reply = try await plain.send("你好", worldContext: world)
    #expect(reply == "无记忆回复。")
    #expect(plain.confirmDeliveredTurn(requestID: UUID(), userText: "你好", reply: reply) == .unavailable,
            "no memory attached -> confirmation reports unavailable")
    #expect(plain.lastTurnDeliveryRequestID == nil, "no delivery credential without memory")

    // 召回失败：错误可见但聊天照常，不阻断。
    let failureTransport = ConversationMemoryStubTransport()
    failureTransport.failNextCalls = 1
    let failureMemory = ResidentConversationMemory(transport: failureTransport)
    var reported: String?
    let failingRunner = ConversationMemoryCodexRunner(replyText: "故障后仍可聊。")
    let failing = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in failingRunner }
    )
    failing.attachConversationMemory(failureMemory) { message in reported = message }
    let failedReply = try await failing.send("召回失败仍可聊", worldContext: world)
    #expect(failedReply == "故障后仍可聊。")
    #expect(reported?.contains("记忆召回失败") == true, "recall failure is visible through the service handler")

    // 无 worldContext：没有 worldID/scope，绝不召回、不绑定、无凭据。
    let chatTransport = ConversationMemoryStubTransport()
    let chatMemory = ResidentConversationMemory(transport: chatTransport)
    let chatRunner = ConversationMemoryCodexRunner(replyText: "普通聊天。")
    let chat = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in chatRunner }
    )
    chat.attachConversationMemory(chatMemory)
    _ = try await chat.send("你好")
    #expect(chatMemory.activeScope == nil, "plain chat without a world scope never binds memory")
    #expect(chatTransport.calls("memory_recall").isEmpty, "plain chat never recalls")
    #expect(chat.lastTurnDeliveryRequestID == nil, "plain chat registers no delivery credential")
}

@MainActor
@Test
func toolTurnUsesExplicitUserMessageAndBackgroundTurnDoesNotFabricateInput() async throws {
    let world = makeResidentWorld(id: "room")
    let tools = ResidentConversationTools(
        worldID: "room",
        schemasJSON: Data("[]".utf8),
        call: { _, _, _ in
            ResidentCodexToolReply(resultJSON: Data("{}".utf8), isError: false)
        },
        cancel: {}
    )
    // 工具会话 + 显式 userMessage：召回 query 是真实用户文字，不是宿主拼装 prompt。
    let transport = ConversationMemoryStubTransport()
    let memory = ResidentConversationMemory(transport: transport)
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        residentSender: { _, _, _, _ in
            AgentConversationOutcome(reply: "已开始播放。", sessionID: "tools-thread")
        }
    )
    service.attachConversationMemory(memory)
    _ = try await service.send(
        "请放一首爵士乐", worldContext: world, worldTools: tools,
        userMessage: "请放首歌"
    )
    let recalls = transport.calls("memory_recall")
    #expect(recalls.count == 1, "tool turn with explicit userMessage recalls once")
    #expect(recalls[0]["query"]?.stringValue == "请放首歌",
            "tool turn recall query is the real user message, not the assembled prompt")

    // 后台/自驱轮（无 userMessage）：不虚构输入、不召回、不登记假 user turn。
    let backgroundTransport = ConversationMemoryStubTransport()
    let backgroundMemory = ResidentConversationMemory(transport: backgroundTransport)
    let background = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        residentSender: { _, _, _, _ in
            AgentConversationOutcome(reply: "自驱完成。", sessionID: "bg-thread")
        }
    )
    background.attachConversationMemory(backgroundMemory)
    _ = try await background.send(
        "自主检查一下空间", worldContext: world, worldTools: tools
    )
    #expect(backgroundTransport.calls("memory_recall").isEmpty,
            "background turn without real user input never recalls/fabricates a query")
    #expect(background.lastTurnDeliveryRequestID == nil,
            "background turn registers no fake user delivery credential")
}

@MainActor
@Test
func contractViolatingConfirmationIsRejectedAndChatStaysUsable() async throws {
    let transport = ConversationMemoryStubTransport()
    let memory = ResidentConversationMemory(transport: transport)
    let contractRunner = ConversationMemoryCodexRunner(replyText: "已收到。")
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in contractRunner }
    )
    service.attachConversationMemory(memory)
    let world = makeResidentWorld()
    let reply = try await service.send("重要的事", worldContext: world)
    guard let requestID = service.lastTurnDeliveryRequestID else {
        #expect(Bool(false), "staged delivery credential exists for rejection cases")
        return
    }
    #expect(
        service.confirmDeliveredTurn(
            requestID: requestID, userText: "重要的事", reply: "第一段\n第二段"
        ) == .rejectedText,
        "control-character reply is rejected without persisting"
    )
    let longReply = String(repeating: "长", count: 2001)
    #expect(
        service.confirmDeliveredTurn(requestID: requestID, userText: "重要的事", reply: longReply)
            == .rejectedText,
        "over-long reply is rejected without persisting"
    )
    #expect(
        service.confirmDeliveredTurn(requestID: requestID, userText: "重要的事", reply: "  ")
            == .rejectedText,
        "blank reply is rejected without persisting"
    )
    #expect(transport.calls("memory_ingest").isEmpty,
            "rejected confirmations never reach memory_ingest and never persist raw text")
    // 修正后同一 requestID 重试仍可成功（凭据未被拒绝消费）。
    #expect(
        service.confirmDeliveredTurn(requestID: requestID, userText: "重要的事", reply: reply)
            == .accepted
    )
    await eventually { !transport.calls("memory_ingest").isEmpty }
    #expect(transport.calls("memory_ingest").count == 1,
            "accepted corrected confirmation ingests exactly once")

    // 真实用户文字本身含控制字符：登记后确认被合理拒绝，聊天已成功不受影响。
    let controlTransport = ConversationMemoryStubTransport()
    let controlMemory = ResidentConversationMemory(transport: controlTransport)
    let controlRunner = ConversationMemoryCodexRunner(replyText: "收到控制字符输入。")
    let controlService = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in controlRunner }
    )
    controlService.attachConversationMemory(controlMemory)
    let controlText = "重要\u{0001}的事"
    _ = try await controlService.send(controlText, worldContext: world)
    guard let controlRequestID = controlService.lastTurnDeliveryRequestID else {
        #expect(Bool(false), "control-character user turn still stages a credential")
        return
    }
    #expect(
        controlService.confirmDeliveredTurn(
            requestID: controlRequestID, userText: controlText, reply: "收到控制字符输入。"
        ) == .rejectedText,
        "control-character user text is rejected without persisting"
    )
    #expect(controlTransport.calls("memory_ingest").isEmpty,
            "control-character user turn never reaches memory_ingest")
}
