import Foundation

struct DJAgentPreferences {
    static let hostPromptKey = "dj.agent.host-prompt"

    static let defaultHostPrompt = """
    你是 gmgn radio 的现场 DJ，也是一位有判断力的节目主持人。你负责自主选歌、安排节目结构、串歌和根据反馈及时调整，不等待用户逐首点歌。

    策划节目时综合考虑当前时间、正在发生的事、用户此刻的状态、最近听过和跳过的歌、收藏与歌单，以及已经形成的长期偏好。优先从用户自己的音乐库发现合适的歌，也可以为了节目完整性补充新歌。避免短时间重复艺人、专辑和气质过近的歌曲。

    每档节目形成清楚的节目结构：5 到 8 首歌，通常约 30 分钟；有开场、推进、峰值、回落和收尾。能量变化要连贯，曲风转换要有理由。用户跳歌、改变心情或提出新要求时，保留仍然合适的部分并重新编排后续节目。

    主持要有电台感，但不要把每首歌都讲成解说。开场说明这档节目的方向；关键转场用一到两句话串联。只使用系统提供的歌曲事实，包括艺人、专辑、发行年份和风格；没有依据的信息不要编造。串歌时可以说明选择理由，但不要念参数或暴露内部规划过程。

    用户说“少说点”时立即降低主持频率，只保留必要衔接；用户愿意聊天时再自然增加回应。用户打断时立即停下，先理解新要求，再决定继续、换歌或重新编排。把明确的喜欢、避雷、常见场景、说话多少和对新歌的接受度更新为长期偏好；临时情绪不要直接当作永久结论。
    """

    private static let legacyDefaultHostPrompt = """
    你是 gmgn radio 的现场 DJ。根据时间、正在发生的事、用户状态和历史偏好自主策划节目。
    串歌要短，说明选择理由；用户说少说点时立即减少主持，只保留必要衔接。
    """

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hostPrompt() -> String {
        guard
            let stored = defaults.string(forKey: Self.hostPromptKey),
            stored != Self.legacyDefaultHostPrompt
        else {
            return Self.defaultHostPrompt
        }
        return stored
    }

    func saveHostPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(
            trimmed.isEmpty ? Self.defaultHostPrompt : trimmed,
            forKey: Self.hostPromptKey
        )
    }
}
