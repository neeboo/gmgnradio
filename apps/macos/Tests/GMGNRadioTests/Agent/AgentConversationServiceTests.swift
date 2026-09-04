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

private final class RecordingRunner: CodexCommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
        let standardInput: String?
    }

    private let lock = NSLock()
    private var storage: [Call] = []
    var result: CodexCommandResult

    init(result: CodexCommandResult) {
        self.result = result
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        lock.lock()
        storage.append(
            Call(arguments: arguments, standardInput: standardInput)
        )
        lock.unlock()
        return result
    }
}

private func makeDefaults() -> UserDefaults {
    let name = "AgentConversationServiceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Registry & installation

@Test
func conversationBackendRegistryCoversAllSixBackends() {
    let ids = AgentConversationBackends.all.map(\.kind)
    #expect(ids.count == 6)
    #expect(Set(ids) == Set(AgentConversationBackendID.allCases))
    #expect(AgentConversationBackends.all.allSatisfy { !$0.displayName.isEmpty })
    #expect(AgentConversationBackends.all.allSatisfy { !$0.executableNames.isEmpty })
    // 唯一性
    #expect(Set(ids).count == ids.count)
}

@Test
func preferredOrderPutsCodexFirst() {
    #expect(AgentConversationBackends.preferredOrder.first == .codex)
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
    let runner = RecordingRunner(
        result: CodexCommandResult(exitCode: 0, output: output)
    )
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults(),
        runnerFactory: { _ in runner }
    )
    let reply = try await service.send("你好")
    #expect(reply == "晚上好，欢迎回来。")
    #expect(runner.calls.count == 1)
    #expect(runner.calls.first?.arguments == ["exec", "--json", "-"])
    #expect(runner.calls.first?.standardInput == "你好")

    // thread id 持久化后，第二轮应走 resume。
    let second = try await service.send("继续")
    #expect(second == "晚上好，欢迎回来。")
    #expect(
        runner.calls.last?.arguments
            == ["exec", "resume", "thread-123", "--json", "-"]
    )
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
func parseClaudeCodeOutputExtractsReplyAndSessionID() {
    let output = #"{"result":"你好","session_id":"sid-1"}"#
    let parsed = AgentConversationService.parseClaudeCodeOutput(output)
    #expect(parsed.reply == "你好")
    #expect(parsed.sessionID == "sid-1")
}

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

@MainActor
@Test
func pendingBackendsReportExplicitProtocolError() async {
    let service = AgentConversationService(
        locator: StubLocator(installedNames: ["workbuddy"]),
        defaults: makeDefaults()
    )
    service.selectBackend(.workbuddy)
    do {
        _ = try await service.send("你好")
        Issue.record("应当抛出 protocolPending")
    } catch let error as AgentConversationError {
        guard case .protocolPending = error else {
            Issue.record("错误类型不对：\(error)")
            return
        }
        #expect(error.errorDescription?.contains("接入协议尚未完成") == true)
    } catch {
        Issue.record("意外错误：\(error)")
    }
}
