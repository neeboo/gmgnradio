import Foundation

enum DJDirectPlaybackIntent: Equatable, Sendable {
    case playCurrent
    case next
    case previous
    case pause

    static func resolve(_ transcript: String) -> DJDirectPlaybackIntent? {
        let normalized = transcript
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else {
            return nil
        }
        let negativeOrQuestionMarkers = [
            "不要播放",
            "别播放",
            "先不播放",
            "能播放吗",
            "可以播放吗",
            "怎么播放",
            "如何播放",
            "不要下一首",
            "别放下一首",
            "不要切歌",
        ]
        guard !negativeOrQuestionMarkers.contains(where: {
            normalized.contains($0)
        }) else {
            return nil
        }
        let questionMarkers = [
            "是什么",
            "叫什么",
            "哪一首",
            "能不能",
            "可不可以",
            "怎么",
            "如何",
            "吗",
        ]
        guard !questionMarkers.contains(where: {
            normalized.contains($0)
        }) else {
            return nil
        }

        let nextCommands: Set<String> = [
            "下一首",
            "下一曲",
            "播放下一首",
            "放下一首",
            "切到下一首",
            "换一首",
            "换歌",
            "next",
            "nexttrack",
        ]
        if nextCommands.contains(normalized)
            || normalized.contains("播放下一首")
            || normalized.contains("切下一首")
        {
            return .next
        }

        let previousCommands: Set<String> = [
            "上一首",
            "上一曲",
            "播放上一首",
            "回到上一首",
            "切到上一首",
            "previous",
            "previoustrack",
        ]
        if previousCommands.contains(normalized)
            || normalized.contains("播放上一首")
            || normalized.contains("回到上一首")
        {
            return .previous
        }

        let pauseCommands: Set<String> = [
            "暂停",
            "暂停一下",
            "暂停播放",
            "停一下",
            "pause",
            "pausemusic",
        ]
        if pauseCommands.contains(normalized) {
            return .pause
        }

        let exactCommands: Set<String> = [
            "播放",
            "播放一下",
            "开始播放",
            "继续播放",
            "请继续播放",
            "放歌",
            "开始放歌",
            "play",
            "playmusic",
            "resume",
        ]
        if exactCommands.contains(normalized) {
            return .playCurrent
        }
        if
            normalized.contains("播放当前"),
            normalized.contains("歌曲")
        {
            return .playCurrent
        }
        if normalized.contains("播放选中的歌曲") {
            return .playCurrent
        }
        return nil
    }
}

enum DJDirectProgramIntent: Equatable, Sendable {
    case replan(instruction: String)

    static func resolve(_ transcript: String) -> DJDirectProgramIntent? {
        let instruction = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalized = instruction
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else {
            return nil
        }
        let rejectionMarkers = [
            "不要重排",
            "别重排",
            "不要重新生成",
            "别重新生成",
            "怎么生成歌单",
            "如何生成歌单",
            "能生成歌单吗",
            "会不会生成歌单",
        ]
        guard !rejectionMarkers.contains(where: normalized.contains) else {
            return nil
        }
        let commands = [
            "重新生成歌单",
            "生成一个歌单",
            "生成一份歌单",
            "重新排歌",
            "重排歌单",
            "重新编排",
            "重新排节目",
            "重新排一下",
            "换个歌单",
            "换一份歌单",
        ]
        let hasProgramNoun = [
            "歌单",
            "节目单",
        ].contains(where: normalized.contains)
        let hasPlanningVerb = [
            "生成",
            "做",
            "排",
            "编排",
            "换",
        ].contains(where: normalized.contains)
        guard
            commands.contains(where: normalized.contains)
                || (hasProgramNoun && hasPlanningVerb)
        else {
            return nil
        }
        return .replan(instruction: instruction)
    }
}

enum DJDirectInsertIntent: Equatable, Sendable {
    case insert(instruction: String)

    static func resolve(_ transcript: String) -> DJDirectInsertIntent? {
        let instruction = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalized = instruction
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else {
            return nil
        }
        let rejectionMarkers = [
            "不要插播",
            "别插播",
            "先不插播",
            "怎么插播",
            "如何插播",
            "能插播吗",
            "可以插播吗",
        ]
        guard !rejectionMarkers.contains(where: normalized.contains) else {
            return nil
        }
        let explicitInsert = [
            "插播一首",
            "插一首",
            "加播一首",
        ].contains(where: normalized.contains)
        let deferredPlay = [
            "下一首放",
            "下一首播放",
            "等下放一首",
            "接下来放一首",
        ].contains(where: normalized.contains)
        guard explicitInsert || deferredPlay else {
            return nil
        }
        return .insert(instruction: instruction)
    }
}

enum DJDirectProgramSwitchIntent: Equatable, Sendable {
    case activatePrepared

    static func resolve(
        _ transcript: String,
        hasPreparedProgram: Bool = false
    ) -> DJDirectProgramSwitchIntent? {
        let normalized = transcript
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else {
            return nil
        }
        let rejectionMarkers = [
            "先别切",
            "不要切",
            "别切",
            "切过去会怎样",
            "怎么切",
            "如何切",
        ]
        guard !rejectionMarkers.contains(where: normalized.contains) else {
            return nil
        }
        let confirmations = [
            "切过去",
            "换到新歌单",
            "播放新歌单",
            "用新歌单",
            "就用这个歌单",
        ]
        let contextualConfirmations = [
            "好",
            "好的",
            "可以",
            "行",
            "切吧",
            "换吧",
            "播放吧",
        ]
        guard
            confirmations.contains(where: normalized.contains)
                || (
                    hasPreparedProgram
                        && contextualConfirmations.contains(normalized)
                )
        else {
            return nil
        }
        return .activatePrepared
    }
}

struct DJAgentCapability: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let requiresTakeover: Bool
    let parameters: [String: DJAgentToolParameter]
    let requiredParameters: [String]

    init(
        name: String,
        description: String,
        requiresTakeover: Bool,
        parameters: [String: DJAgentToolParameter] = [:],
        requiredParameters: [String] = []
    ) {
        self.name = name
        self.description = description
        self.requiresTakeover = requiresTakeover
        self.parameters = parameters
        self.requiredParameters = requiredParameters
    }
}

struct DJAgentToolParameter: Codable, Equatable, Sendable {
    let type: String
    let description: String
    let allowedValues: [String]?

    init(
        type: String,
        description: String,
        allowedValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.allowedValues = allowedValues
    }
}

enum DJAgentCapabilityManifest {
    static let capabilities = [
        DJAgentCapability(
            name: "read_radio_state",
            description: "读取当前播放、节目单和接管状态",
            requiresTakeover: false
        ),
        DJAgentCapability(
            name: "read_current_track",
            description:
                "调用当下读取真实播放关系：previousTrack 是刚刚实际播过的上一首，当前快照是扬声器中正在播放或暂停的歌曲，nextTrack 是队列中实际准备的下一首；查询歌曲或生成串场词时必须调用，不能使用历史上下文",
            requiresTakeover: false
        ),
        DJAgentCapability(
            name: "search_music",
            description:
                "搜索用户已连接的网易云、QQ 音乐和 Apple Music 曲库",
            requiresTakeover: false,
            parameters: [
                "query": DJAgentToolParameter(
                    type: "string",
                    description: "歌曲、艺人、专辑、风格或场景关键词"
                ),
                "limit": DJAgentToolParameter(
                    type: "integer",
                    description: "返回数量，建议 1 到 20"
                ),
            ],
            requiredParameters: ["query"]
        ),
        DJAgentCapability(
            name: "play_program_track",
            description: "按 track_id 或 slot_index 播放节目中的歌曲",
            requiresTakeover: true,
            parameters: [
                "track_id": DJAgentToolParameter(
                    type: "string",
                    description: "节目单中的歌曲 ID"
                ),
                "slot_index": DJAgentToolParameter(
                    type: "integer",
                    description: "节目单中从 0 开始的位置"
                ),
            ]
        ),
        DJAgentCapability(
            name: "next_track",
            description: "播放节目中的下一首",
            requiresTakeover: true
        ),
        DJAgentCapability(
            name: "previous_track",
            description: "返回节目中的上一首",
            requiresTakeover: true
        ),
        DJAgentCapability(
            name: "pause_music",
            description: "暂停当前音乐",
            requiresTakeover: true
        ),
        DJAgentCapability(
            name: "resume_music",
            description:
                "播放当前选中的歌曲。用户说播放、开始播放或继续播放时必须调用；空闲时启动当前歌曲，暂停时恢复",
            requiresTakeover: true
        ),
        DJAgentCapability(
            name: "replan_program",
            description:
                "把 immediate_instruction 交给后台编排器；立即返回，完成后会另行通知",
            requiresTakeover: true,
            parameters: [
                "immediate_instruction": DJAgentToolParameter(
                    type: "string",
                    description: "用户刚提出的节目方向或调整要求"
                ),
            ]
        ),
        DJAgentCapability(
            name: "activate_prepared_program",
            description:
                "用户确认后，切换并播放后台已经准备好的新节目单",
            requiresTakeover: true
        ),
        DJAgentCapability(
            name: "insert_track",
            description:
                "把单首插播要求交给后台找歌并验证可播；立即返回，找到后自动插到下一首并另行通知",
            requiresTakeover: true,
            parameters: [
                "immediate_instruction": DJAgentToolParameter(
                    type: "string",
                    description: "下一首需要插播的歌曲或选择条件"
                ),
            ],
            requiredParameters: ["immediate_instruction"]
        ),
        DJAgentCapability(
            name: "set_visual_mood",
            description: "将视觉切换为 afterglow、liquid 或 pulse",
            requiresTakeover: true,
            parameters: [
                "mood": DJAgentToolParameter(
                    type: "string",
                    description: "舞台视觉情绪",
                    allowedValues: StageVisualMood.allCases.map(\.rawValue)
                ),
            ],
            requiredParameters: ["mood"]
        ),
        DJAgentCapability(
            name: "set_lyrics_mode",
            description:
                "切换歌词为自动或十套播放主题：流光、心象、云阶、长文、群聊、倾诉、回环、莫奈海报、钟摆、镜台",
            requiresTakeover: true,
            parameters: [
                "mode": DJAgentToolParameter(
                    type: "string",
                    description: "歌词视觉模式",
                    allowedValues: StageLyricsVisualMode.agentValues
                ),
            ],
            requiredParameters: ["mode"]
        ),
        DJAgentCapability(
            name: "set_spatial_environment",
            description:
                "切换完整的 Marble 房间或改变天气；房间中的唱机、壁炉和家具属于空间本体",
            requiresTakeover: true,
            parameters: [
                "scene": DJAgentToolParameter(
                    type: "string",
                    description: "完整空间",
                    allowedValues: SpatialScenePreset.allCases.map(\.rawValue)
                ),
                "weather": DJAgentToolParameter(
                    type: "string",
                    description: "天气",
                    allowedValues: SpatialWeather.allCases.map(\.rawValue)
                ),
            ]
        ),
        DJAgentCapability(
            name: "move_spatial_camera",
            description:
                "让 Marble 舞台镜头短距离移动或复位；连续探索仍交给用户的 WASD 和鼠标",
            requiresTakeover: true,
            parameters: [
                "direction": DJAgentToolParameter(
                    type: "string",
                    description: "镜头移动方向",
                    allowedValues: SpatialCameraCommandDirection.allCases.map(
                        \.rawValue
                    )
                ),
                "distance": DJAgentToolParameter(
                    type: "number",
                    description: "移动距离，0.5 到 10 米"
                ),
            ],
            requiredParameters: ["direction"]
        ),
    ] + WorldAgentToolContract.capabilities.map { capability in
        DJAgentCapability(
            name: capability.name,
            description: capability.description,
            requiresTakeover: capability.requiresTakeover,
            parameters: capability.parameters.mapValues { parameter in
                DJAgentToolParameter(
                    type: parameter.type,
                    description: parameter.description,
                    allowedValues: parameter.allowedValues
                )
            },
            requiredParameters: capability.requiredParameters
        )
    }

    static var providerTools: [[String: Any]] {
        providerTools(for: capabilities)
    }

    static func providerTools(
        for capabilities: [DJAgentCapability]
    ) -> [[String: Any]] {
        capabilities.map { capability in
            let properties = capability.parameters.mapValues { parameter in
                var schema: [String: Any] = [
                    "type": parameter.type,
                    "description": parameter.description,
                ]
                if let allowedValues = parameter.allowedValues {
                    schema["enum"] = allowedValues
                }
                return schema
            }
            return [
                "type": "function",
                "function": [
                    "name": capability.name,
                    "description": capability.description,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": capability.requiredParameters,
                        "additionalProperties": false,
                    ],
                ],
            ]
        }
    }
}

struct DJAgentProgramTrack: Codable, Equatable, Sendable {
    let index: Int
    let id: String
    let title: String
    let artist: String
}

struct DJAgentMusicTrack: Codable, Equatable, Sendable {
    let id: String
    let provider: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let isPlayable: Bool
}

struct DJAgentPlaybackTrack: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
}

struct DJAgentCurrentTrackSnapshot: Codable, Equatable, Sendable {
    let sampledAt: String
    let playbackState: String
    let isPlaying: Bool
    let id: String
    let provider: String
    let source: String
    let title: String
    let artist: String
    let album: String?
    let durationSeconds: TimeInterval
    let positionSeconds: TimeInterval
    let remainingSeconds: TimeInterval
    let progress: Double
    let programID: String?
    let programTitle: String?
    let slotIndex: Int?
    let previousTrack: DJAgentPlaybackTrack?
    let nextTrack: DJAgentPlaybackTrack?
}

struct DJAgentRadioState: Codable, Equatable, Sendable {
    let takeoverEnabled: Bool
    let playbackState: String
    let activeTrackID: String?
    let activeSlotIndex: Int?
    let program: [DJAgentProgramTrack]
    let capabilities: [DJAgentCapability]

    init(
        takeoverEnabled: Bool,
        playbackState: String,
        activeTrackID: String?,
        activeSlotIndex: Int?,
        program: [DJAgentProgramTrack],
        capabilities: [DJAgentCapability] =
            DJAgentCapabilityManifest.capabilities
    ) {
        self.takeoverEnabled = takeoverEnabled
        self.playbackState = playbackState
        self.activeTrackID = activeTrackID
        self.activeSlotIndex = activeSlotIndex
        self.program = program
        self.capabilities = capabilities
    }
}

struct DJAgentToolResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let code: String?
    let message: String
    let state: DJAgentRadioState?
    let tracks: [DJAgentMusicTrack]?
    let currentTrack: DJAgentCurrentTrackSnapshot?
}

@MainActor
protocol DJAgentRadioActions: AnyObject {
    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot?
    func playProgramTrack(
        trackID: String?,
        slotIndex: Int?
    ) async throws
    func playNextTrack() async throws
    func playPreviousTrack() async throws
    func pauseMusic() async throws
    func resumeMusic() async throws
    func replanProgram(immediateInstruction: String?) async throws
    func activatePreparedProgram() async throws
    func insertTrack(immediateInstruction: String) async throws
    func setVisualMood(_ mood: StageVisualMood) async throws
    func searchMusic(
        query: String,
        limit: Int
    ) async throws -> [DJAgentMusicTrack]
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws
    func setSpatialEnvironment(
        scene: SpatialScenePreset?,
        weather: SpatialWeather?
    ) async throws
    func moveSpatialCamera(
        direction: SpatialCameraCommandDirection,
        distance: Float
    ) async throws
}

@MainActor
final class DJAgentToolDispatcher {
    private struct PlayArguments: Decodable {
        let trackID: String?
        let slotIndex: Int?

        enum CodingKeys: String, CodingKey {
            case trackID = "track_id"
            case slotIndex = "slot_index"
        }
    }

    private struct ReplanArguments: Decodable {
        let immediateInstruction: String?

        enum CodingKeys: String, CodingKey {
            case immediateInstruction = "immediate_instruction"
        }
    }

    private struct VisualArguments: Decodable {
        let mood: String
    }

    private struct SearchArguments: Decodable {
        let query: String
        let limit: Int?
    }

    private struct LyricsArguments: Decodable {
        let mode: String
    }

    private struct SpatialEnvironmentArguments: Decodable {
        let scene: String?
        let weather: String?
    }

    private struct SpatialCameraArguments: Decodable {
        let direction: String
        let distance: Float?
    }

    private let takeoverEnabled: @MainActor () -> Bool
    private weak var actions: (any DJAgentRadioActions)?
    private let worldDispatcher: @MainActor () -> WorldAgentToolDispatcher?
    private var completedCalls: [String: RealtimeDJToolResult] = [:]

    init(
        takeoverEnabled: @escaping @MainActor () -> Bool,
        actions: any DJAgentRadioActions,
        worldDispatcher: @escaping @MainActor () -> WorldAgentToolDispatcher?
            = { nil }
    ) {
        self.takeoverEnabled = takeoverEnabled
        self.actions = actions
        self.worldDispatcher = worldDispatcher
    }

    var providerTools: [[String: Any]] {
        let worldNames = Set(WorldAgentToolContract.capabilities.map(\.name))
        let radioCapabilities = DJAgentCapabilityManifest.capabilities.filter {
            !worldNames.contains($0.name)
        }
        return DJAgentCapabilityManifest.providerTools(for: radioCapabilities)
            + (worldDispatcher()?.providerTools ?? [])
    }

    func handle(
        _ call: RealtimeDJToolCall
    ) async -> RealtimeDJToolResult {
        if WorldAgentToolContract.capabilities.contains(where: {
            $0.name == call.name
        }) {
            guard let dispatcher = worldDispatcher() else {
                return worldUnavailableResult(callID: call.id)
            }
            return await dispatcher.handle(call)
        }
        if let completed = completedCalls[call.id] {
            return completed
        }

        let result = await execute(call)
        completedCalls[call.id] = result
        return result
    }

    func resetSession() {
        completedCalls.removeAll(keepingCapacity: true)
        worldDispatcher()?.resetSession()
    }

    private func worldUnavailableResult(callID: String) -> RealtimeDJToolResult {
        RealtimeDJToolResult(
            callID: callID,
            resultJSON: Data(
                #"{"ok":false,"code":"world_unavailable","message":"生活空间当前不可用"}"#.utf8
            ),
            isError: true
        )
    }

    private func execute(
        _ call: RealtimeDJToolCall
    ) async -> RealtimeDJToolResult {
        guard let actions else {
            return makeResult(
                callID: call.id,
                ok: false,
                code: "radio_unavailable",
                message: "播放器当前不可用",
                state: nil,
                tracks: nil
            )
        }

        let enabled = takeoverEnabled()
        guard
            let capability = DJAgentCapabilityManifest.capabilities
                .first(where: { $0.name == call.name })
        else {
            return makeResult(
                callID: call.id,
                ok: false,
                code: "unknown_tool",
                message: "未知的 DJ 工具：\(call.name)",
                state: actions.snapshot(takeoverEnabled: enabled),
                tracks: nil
            )
        }
        guard enabled || !capability.requiresTakeover else {
            return makeResult(
                callID: call.id,
                ok: false,
                code: "takeover_disabled",
                message: "用户尚未允许 DJ 接管播放与编排",
                state: actions.snapshot(takeoverEnabled: false),
                tracks: nil
            )
        }

        do {
            let message: String
            var tracks: [DJAgentMusicTrack]?
            var currentTrack: DJAgentCurrentTrackSnapshot?
            switch call.name {
            case "read_radio_state":
                message = "已读取当前电台状态"
            case "read_current_track":
                currentTrack = actions.currentTrackSnapshot()
                message = currentTrack == nil
                    ? "当前没有正在播放或暂停中的歌曲"
                    : "已读取调用当下的歌曲信息"
            case "search_music":
                let arguments = try decode(
                    SearchArguments.self,
                    from: call.argumentsJSON
                )
                let query = arguments.query.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !query.isEmpty else {
                    throw DJAgentToolError.missingSearchQuery
                }
                let limit = min(max(arguments.limit ?? 10, 1), 20)
                tracks = try await actions.searchMusic(
                    query: query,
                    limit: limit
                )
                message = "找到 \(tracks?.count ?? 0) 首候选歌曲"
            case "play_program_track":
                let arguments = try decode(
                    PlayArguments.self,
                    from: call.argumentsJSON
                )
                guard
                    arguments.trackID != nil
                        || arguments.slotIndex != nil
                else {
                    throw DJAgentToolError.missingTrack
                }
                try await actions.playProgramTrack(
                    trackID: arguments.trackID,
                    slotIndex: arguments.slotIndex
                )
                message = "已切换到指定歌曲"
            case "next_track":
                try await actions.playNextTrack()
                message = "下一首已经开始，请结合当前歌曲提示自然串场"
            case "previous_track":
                try await actions.playPreviousTrack()
                message = "已返回上一首"
            case "pause_music":
                try await actions.pauseMusic()
                message = "音乐已暂停"
            case "resume_music":
                try await actions.resumeMusic()
                message = "音乐已继续"
            case "replan_program":
                let arguments = try decode(
                    ReplanArguments.self,
                    from: call.argumentsJSON
                )
                try await actions.replanProgram(
                    immediateInstruction:
                        arguments.immediateInstruction
                )
                message = "已开始重新编排后续节目"
            case "activate_prepared_program":
                try await actions.activatePreparedProgram()
                message = "已切换到准备好的新节目"
            case "insert_track":
                let arguments = try decode(
                    ReplanArguments.self,
                    from: call.argumentsJSON
                )
                guard
                    let instruction = arguments.immediateInstruction?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !instruction.isEmpty
                else {
                    throw DJAgentToolError.missingInstruction
                }
                try await actions.insertTrack(
                    immediateInstruction: instruction
                )
                message = "已把插播要求交给后台找歌，完成后会主动通知"
            case "set_visual_mood":
                let arguments = try decode(
                    VisualArguments.self,
                    from: call.argumentsJSON
                )
                guard
                    let mood = StageVisualMood(
                        rawValue: arguments.mood
                    )
                else {
                    throw DJAgentToolError.invalidVisualMood
                }
                try await actions.setVisualMood(mood)
                message = "视觉情绪已更新"
            case "set_lyrics_mode":
                let arguments = try decode(
                    LyricsArguments.self,
                    from: call.argumentsJSON
                )
                guard
                    let mode = StageLyricsVisualMode(
                        agentValue: arguments.mode
                    )
                else {
                    throw DJAgentToolError.invalidLyricsMode
                }
                try await actions.setLyricsMode(mode)
                message = "歌词视觉已更新"
            case "set_spatial_environment":
                let arguments = try decode(
                    SpatialEnvironmentArguments.self,
                    from: call.argumentsJSON
                )
                let scene = try arguments.scene.map {
                    guard let value = SpatialScenePreset(rawValue: $0) else {
                        throw DJAgentToolError.invalidSpatialEnvironment
                    }
                    return value
                }
                let weather = try arguments.weather.map {
                    guard let value = SpatialWeather(rawValue: $0) else {
                        throw DJAgentToolError.invalidSpatialEnvironment
                    }
                    return value
                }
                guard scene != nil || weather != nil else {
                    throw DJAgentToolError.invalidSpatialEnvironment
                }
                try await actions.setSpatialEnvironment(
                    scene: scene,
                    weather: weather
                )
                message = scene == nil ? "空间天气已更新" : "正在切换完整空间"
            case "move_spatial_camera":
                let arguments = try decode(
                    SpatialCameraArguments.self,
                    from: call.argumentsJSON
                )
                guard let direction = SpatialCameraCommandDirection(
                    rawValue: arguments.direction
                ) else {
                    throw DJAgentToolError.invalidSpatialCamera
                }
                let distance = min(max(arguments.distance ?? 2, 0.5), 10)
                try await actions.moveSpatialCamera(
                    direction: direction,
                    distance: distance
                )
                message = direction == .reset
                    ? "空间镜头已复位"
                    : "空间镜头已移动"
            default:
                throw DJAgentToolError.unknownTool
            }
            return makeResult(
                callID: call.id,
                ok: true,
                code: nil,
                message: message,
                state: actions.snapshot(takeoverEnabled: enabled),
                tracks: tracks,
                currentTrack: currentTrack
            )
        } catch {
            return makeResult(
                callID: call.id,
                ok: false,
                code: "tool_failed",
                message: error.localizedDescription,
                state: actions.snapshot(takeoverEnabled: enabled),
                tracks: nil
            )
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DJAgentToolError.invalidArguments
        }
    }

    private func makeResult(
        callID: String,
        ok: Bool,
        code: String?,
        message: String,
        state: DJAgentRadioState?,
        tracks: [DJAgentMusicTrack]?,
        currentTrack: DJAgentCurrentTrackSnapshot? = nil
    ) -> RealtimeDJToolResult {
        let response = DJAgentToolResponse(
            ok: ok,
            code: code,
            message: message,
            state: state,
            tracks: tracks,
            currentTrack: currentTrack
        )
        let data = (try? JSONEncoder().encode(response))
            ?? Data(#"{"ok":false,"message":"结果编码失败"}"#.utf8)
        return RealtimeDJToolResult(
            callID: callID,
            resultJSON: data,
            isError: !ok
        )
    }
}

private enum DJAgentToolError: LocalizedError {
    case invalidArguments
    case missingTrack
    case missingInstruction
    case missingSearchQuery
    case invalidVisualMood
    case invalidLyricsMode
    case invalidSpatialEnvironment
    case invalidSpatialCamera
    case unknownTool

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "DJ 工具参数格式不正确"
        case .missingTrack:
            "需要提供 track_id 或 slot_index"
        case .missingInstruction:
            "需要说明想插播什么"
        case .missingSearchQuery:
            "需要提供找歌关键词"
        case .invalidVisualMood:
            "视觉情绪只能是 afterglow、liquid 或 pulse"
        case .invalidLyricsMode:
            "歌词视觉模式无效"
        case .invalidSpatialEnvironment:
            "空间环境参数无效"
        case .invalidSpatialCamera:
            "空间镜头方向无效"
        case .unknownTool:
            "未知的 DJ 工具"
        }
    }
}
