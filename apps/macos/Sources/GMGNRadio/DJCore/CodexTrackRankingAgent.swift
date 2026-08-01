import Foundation

enum CodexTrackRankingError: Error, LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Codex 没有返回可用的节目排序。"
    }
}

struct CodexTrackRankingAgent: DJShowPlanningAgent {
    private let executor: any CodexPlanningExecuting
    private let hostPrompt: String

    init(
        executor: any CodexPlanningExecuting,
        hostPrompt: String
    ) {
        self.executor = executor
        self.hostPrompt = hostPrompt
    }

    static func live(
        preferences: DJAgentPreferences = DJAgentPreferences()
    ) throws -> CodexTrackRankingAgent {
        try CodexTrackRankingAgent(
            executor: CodexCLIPlanningExecutor.live(
                model: preferences.planningModel()
            ),
            hostPrompt: preferences.hostPrompt()
        )
    }

    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String] {
        let output = try await execute(
            brief: brief,
            candidates: candidates
        )
        if let proposal = try? decodeProposal(
            output,
            candidates: candidates
        ) {
            return proposal.slots.map(\.trackID)
        }
        let response = try JSONDecoder().decode(
            LegacyRankingResponse.self,
            from: Data(output.utf8)
        )
        let ranked = sanitizeTrackIDs(
            response.trackIDs,
            candidates: candidates
        )
        guard !ranked.isEmpty else {
            throw CodexTrackRankingError.invalidResponse
        }
        return ranked
    }

    func proposeShow(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> AgentShowProposal {
        let output = try await execute(
            brief: brief,
            candidates: candidates
        )
        return try decodeProposal(output, candidates: candidates)
    }

    private func execute(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> String {
        let prompt = try makePrompt(
            brief: brief,
            candidates: candidates
        )
        return try await executor.execute(prompt: prompt)
    }

    private func decodeProposal(
        _ output: String,
        candidates: [MusicCandidate]
    ) throws -> AgentShowProposal {
        let decoded = try JSONDecoder().decode(
            AgentShowProposal.self,
            from: Data(output.utf8)
        )
        let proposal = decoded.sanitized(
            knownTrackIDs: Set(candidates.map(\.id))
        )
        guard !proposal.slots.isEmpty else {
            throw CodexTrackRankingError.invalidResponse
        }
        return proposal
    }

    private func sanitizeTrackIDs(
        _ values: [String],
        candidates: [MusicCandidate]
    ) -> [String] {
        let knownIDs = Set(candidates.map(\.id))
        var seen = Set<String>()
        return values.filter {
            knownIDs.contains($0) && seen.insert($0).inserted
        }
    }

    private func makePrompt(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) throws -> String {
        let input = PlanningInput(
            brief: brief,
            candidates: candidates.prefix(30).map(PlanningCandidate.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let inputJSON = String(
            decoding: try encoder.encode(input),
            as: UTF8.self
        )
        return """
        \(hostPrompt)

        请策划一段完整的电台节目。兼顾用户偏好、能量曲线、艺人间隔和主持衔接。
        只从候选歌曲中选择，按播放顺序给出 5 到 8 个节目位置。
        为节目写一个简短标题和整体方向。每个位置需要说明选择理由、是否在歌前主持、
        与前后内容的转场意图，以及给视觉系统的情绪、色彩、运动和 0 到 1 强度。
        歌曲事实只能使用输入中提供的资料。用户要求少说时，减少主持位置。
        不要调用工具，不要读取文件，只完成节目策划。

        \(inputJSON)
        """
    }
}

private struct LegacyRankingResponse: Decodable {
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
    }
}

private struct PlanningInput: Encodable {
    let brief: ProgramBrief
    let candidates: [PlanningCandidate]
}

private struct PlanningCandidate: Encodable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let userAffinity: Double
    let energy: Double
    let moodTags: [String]
    let genres: [String]
    let releaseYear: Int?

    init(_ candidate: MusicCandidate) {
        id = candidate.id
        title = candidate.title
        artist = candidate.artist
        album = candidate.album
        duration = candidate.duration
        userAffinity = candidate.userAffinity
        energy = candidate.energy
        moodTags = candidate.moodTags
        genres = candidate.genres
        releaseYear = candidate.releaseYear
    }
}
