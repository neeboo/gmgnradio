import Foundation
import Testing
@testable import GMGNRadio

@Test
func defaultDJPreferenceCoversACompleteRadioShow() {
    let prompt = DJAgentPreferences.defaultHostPrompt

    #expect(prompt.count > 320)
    #expect(prompt.contains("节目结构"))
    #expect(prompt.contains("歌曲事实"))
    #expect(prompt.contains("重新编排"))
    #expect(prompt.contains("长期偏好"))
}

@MainActor
@Test
func agentSettingsLoadsCodexLoginAndPersistsTheHostPrompt() async throws {
    let account = CodexAccountServiceStub(
        state: .signedIn(method: "ChatGPT")
    )
    let suiteName = "AgentSettingsModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = AgentSettingsModel(
        account: account,
        preferences: DJAgentPreferences(defaults: defaults)
    )

    await model.load()
    model.hostPrompt = "少说一点，多留意时间和用户刚才说的话。"
    model.savePrompt()

    #expect(model.codexState == .signedIn(method: "ChatGPT"))
    #expect(
        defaults.string(forKey: DJAgentPreferences.hostPromptKey)
            == "少说一点，多留意时间和用户刚才说的话。"
    )
}

@MainActor
@Test
func agentSettingsStartsCodexLoginAndRefreshesTheState() async {
    let account = CodexAccountServiceStub(state: .signedOut)
    let model = AgentSettingsModel(account: account)

    await model.connectCodex()

    #expect(account.loginCount == 1)
    #expect(model.codexState == .signedIn(method: "ChatGPT"))
}

@MainActor
@Test
func agentSettingsLogsOutOfCodexAndReturnsToSignedOut() async {
    let account = CodexAccountServiceStub(
        state: .signedIn(method: "ChatGPT")
    )
    let model = AgentSettingsModel(account: account)

    await model.disconnectCodex()

    #expect(account.logoutCount == 1)
    #expect(model.codexState == .signedOut)
}

@MainActor
private final class CodexAccountServiceStub: CodexAccountServicing {
    var state: CodexAccountState
    var loginCount = 0
    var logoutCount = 0

    init(state: CodexAccountState) {
        self.state = state
    }

    func status() async -> CodexAccountState {
        state
    }

    func login() async throws {
        loginCount += 1
        state = .signedIn(method: "ChatGPT")
    }

    func logout() async throws {
        logoutCount += 1
        state = .signedOut
    }
}
