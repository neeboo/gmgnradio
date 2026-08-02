import Foundation

struct DJAgentPreferences {
    static let hostPromptKey = "dj.agent.host-prompt"
    static let takeoverEnabledKey = "dj.agent.takeover-enabled"
    static let planningModelKey = "dj.agent.planning-model"

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

    func takeoverEnabled() -> Bool {
        guard defaults.object(forKey: Self.takeoverEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: Self.takeoverEnabledKey)
    }

    func saveTakeoverEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.takeoverEnabledKey)
    }

    func planningModel() -> String? {
        normalized(defaults.string(forKey: Self.planningModelKey))
    }

    func savePlanningModel(_ model: String) {
        defaults.set(
            normalized(model),
            forKey: Self.planningModelKey
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct DJRealtimePromptBuilder {
    func build(context: RealtimeDJContext?) throws -> String {
        let preference = normalized(context?.hostPreference)
            ?? DJAgentPreferences.defaultHostPrompt
        let capabilities = DJAgentCapabilityManifest.capabilities
            .map { capability in
                let permission = capability.requiresTakeover
                    ? "需要接管"
                    : "可直接使用"
                return "- \(capability.name)：\(capability.description)（\(permission)）"
            }
            .joined(separator: "\n")
        let controlState: String
        if context?.agentControl?.takeoverEnabled == true {
            controlState = "接管已开启，可以自主执行播放、编排和视觉动作。"
        } else {
            controlState = "接管未开启，只能读取状态和搜索曲库；需要改变播放时简短说明。"
        }

        let liveContext: String
        let openingGuidance: String
        if let context {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            liveContext = String(
                decoding: try encoder.encode(context),
                as: UTF8.self
            )
            openingGuidance = makeOpeningGuidance(
                from: context.hostHint
            )
        } else {
            liveContext = "尚未生成节目。先理解用户的场景，再决定是否需要找歌和编排。"
            openingGuidance = "当前没有待执行的歌曲开场主持。"
        }

        return """
        # 身份

        你是 gmgn radio 的现场 DJ。你会听用户说话，也会自主主持、找歌、编排和控制舞台。

        # 用户设置的主持偏好

        \(preference)

        # 行动规则

        - 先判断用户是在聊天、问状态，还是要求执行动作。能执行时直接调用工具。
        - 用户询问正在播放什么、当前歌曲、歌手、专辑或播放进度时，必须在回答前调用 read_current_track。它读取调用当下的播放器状态；禁止依据当前实时上下文或此前对话回答。
        - 任何包含“上一首、这一首、下一首”的串场词，都必须先调用 read_current_track，并严格使用 previousTrack、当前快照、nextTrack 三个位置。字段为空就不要提对应歌曲，禁止根据节目单顺序或记忆补全。
        - 需要查看完整节目单或接管状态时，调用 read_radio_state。
        - 需要找具体歌曲、艺人或某种场景的音乐时，调用 search_music；搜索结果里的歌曲事实才可以用于主持。
        - 单首临时需求用 insert_track：它会立即把要求交给后台找歌，完成后自动插入下一首，不需要用户再次确认。整体方向变化用 replan_program；后台编排完成后先告诉用户歌单已经准备好，并询问是否切换，只有用户确认后才调用 activate_prepared_program。
        - insert_track 和 replan_program 返回“已开始”后继续和用户对话，不要等待，也不要提前声称歌曲已经找到。
        - replan_program 只负责创建后台任务。工具返回“已开始”以后继续和用户对话，不要声称歌单已经完成。
        - 明确指定节目内歌曲用 play_program_track。
        - 用户说“播放”“开始播放”“播放当前选中的歌曲”或“继续播放”时，一律先调用 resume_music。禁止只用语音确认。
        - 用户说暂停、上一首或下一首时，调用对应播放工具，不只口头答应。
        - 视觉和歌词表现可以跟随用户要求调用 set_visual_mood 与 set_lyrics_mode。
        - \(controlState)
        - 调用工具后根据返回状态继续主持；失败时说明实际原因，不声称已经完成。
        - 每次口播最多两句，中文通常不超过 40 个字；不要朗读整张歌单。
        - 主持简短自然。用户要求少说时，只保留一句必要确认或串歌。

        # 当前开场主持

        \(openingGuidance)

        # 可用工具

        \(capabilities)

        # 当前实时上下文

        \(liveContext)
        """
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeOpeningGuidance(
        from hint: ProgramHostHint?
    ) -> String {
        guard let hint, hint.shouldTalkBefore else {
            return "当前歌曲开场不需要主动主持；只在用户开口时回应。"
        }
        let sentenceCount = max(1, min(hint.maxSentenceCount, 2))
        let artist = hint.currentTrack.artist.map { "，\($0)" } ?? ""
        let facts = hint.facts.isEmpty
            ? "没有可靠歌曲事实时，不要补写背景资料。"
            : "可用歌曲事实：\(hint.facts.joined(separator: "；"))。"
        let transition = normalized(hint.transitionIntent)
            .map { "过渡方向：\($0)。" }
            ?? ""

        return """
        当前歌曲开场需要主持：\(hint.currentTrack.title)\(artist) 已经开始播放。
        最多 \(sentenceCount) 句。结合选歌理由“\(hint.selectionReason)”自然串场。\(transition)
        \(facts)
        收到系统的开场请求后直接说主持词，不解释内部计划，也不要调用播放工具。
        """
    }
}

struct DJTrackOpeningRequestBuilder {
    func instruction(
        for hint: ProgramHostHint,
        forceForProgramBeat: Bool = false
    ) -> String? {
        guard hint.shouldTalkBefore || forceForProgramBeat else {
            return nil
        }
        let sentenceCount = max(1, min(hint.maxSentenceCount, 2))
        return """
        系统触发：新歌已经开始播放。先调用 read_current_track 获取播放当下的真实关系。
        previousTrack 只代表刚刚实际播过的上一首；工具返回的当前快照只代表这一首；nextTrack 只代表尚未播放的下一首。
        严格按工具结果完成串场，最多 \(sentenceCount) 句。字段为空时不要提对应位置，也不要使用此前对话或节目单里的歌曲名补全。
        直接说主持词，不解释内部计划，也不要调用播放工具。
        """
    }
}
