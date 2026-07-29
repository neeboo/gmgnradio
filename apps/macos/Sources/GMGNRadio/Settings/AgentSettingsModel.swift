import Foundation
import Observation

@MainActor
@Observable
final class AgentSettingsModel {
    var codexState: CodexAccountState = .signedOut
    var hostPrompt: String
    var isWorking = false
    var message: String?
    var hasError = false

    private let account: any CodexAccountServicing
    private let preferences: DJAgentPreferences

    init(
        account: any CodexAccountServicing = CodexAgentAccountService(),
        preferences: DJAgentPreferences = DJAgentPreferences()
    ) {
        self.account = account
        self.preferences = preferences
        hostPrompt = preferences.hostPrompt()
    }

    func load() async {
        codexState = await account.status()
    }

    func connectCodex() async {
        isWorking = true
        message = nil
        hasError = false
        defer { isWorking = false }
        do {
            try await account.login()
            codexState = await account.status()
            message = codexState.isSignedIn
                ? "Codex 已连接。"
                : "登录尚未完成，请重试。"
            hasError = !codexState.isSignedIn
        } catch {
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            hasError = true
        }
    }

    func disconnectCodex() async {
        isWorking = true
        message = nil
        hasError = false
        defer { isWorking = false }
        do {
            try await account.logout()
            codexState = await account.status()
            message = codexState == .signedOut
                ? "Codex 已退出登录。"
                : "退出登录尚未完成，请重试。"
            hasError = codexState != .signedOut
        } catch {
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            hasError = true
        }
    }

    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        codexState = await account.status()
    }

    func savePrompt() {
        preferences.saveHostPrompt(hostPrompt)
        hostPrompt = preferences.hostPrompt()
        message = "DJ 偏好已保存。"
        hasError = false
    }
}

extension CodexAccountState {
    var isSignedIn: Bool {
        if case .signedIn = self {
            return true
        }
        return false
    }
}
