import Foundation
import Testing
@testable import GMGNRadio

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
private final class CodexAccountServiceStub: CodexAccountServicing {
    var state: CodexAccountState
    var loginCount = 0

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
}
