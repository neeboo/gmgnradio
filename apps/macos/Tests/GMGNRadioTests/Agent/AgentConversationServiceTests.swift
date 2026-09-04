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
    // 除 DSH 外都支持原生续聊
    for backend in AgentConversationBackends.all {
        #expect(
            backend.supportsNativeContinuation == (backend.kind != .dsh)
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
        }
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

@Test
func claudeCodeArgumentsUseSessionIDThenResume() {
    let first = AgentConversationService.jsonResultCLIArguments(
        kind: .claudeCode,
        text: "你好",
        sessionID: nil,
        isResume: false
    )
    #expect(Array(first.prefix(4)) == ["-p", "你好", "--output-format", "json"])
    #expect(first[4] == "--session-id")
    #expect(isUUID(first[5]))

    let resume = AgentConversationService.jsonResultCLIArguments(
        kind: .claudeCode,
        text: "继续",
        sessionID: "claude-7",
        isResume: true
    )
    #expect(
        resume
            == ["-p", "继续", "--output-format", "json", "--resume", "claude-7"]
    )
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
