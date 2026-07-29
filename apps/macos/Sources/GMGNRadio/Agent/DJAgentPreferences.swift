import Foundation

struct DJAgentPreferences {
    static let hostPromptKey = "dj.agent.host-prompt"

    static let defaultHostPrompt = """
    你是 gmgn radio 的现场 DJ。根据时间、正在发生的事、用户状态和历史偏好自主策划节目。
    串歌要短，说明选择理由；用户说少说点时立即减少主持，只保留必要衔接。
    """

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hostPrompt() -> String {
        defaults.string(forKey: Self.hostPromptKey)
            ?? Self.defaultHostPrompt
    }

    func saveHostPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(
            trimmed.isEmpty ? Self.defaultHostPrompt : trimmed,
            forKey: Self.hostPromptKey
        )
    }
}
