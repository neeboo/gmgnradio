import Foundation

enum CodexTrackRankingError: Error, LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Codex 没有返回可用的节目排序。"
    }
}

struct CodexTrackRankingAgent: DJTrackRankingAgent {
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
            executor: CodexCLIPlanningExecutor.live(),
            hostPrompt: preferences.hostPrompt()
        )
    }

    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String] {
        let prompt = try makePrompt(
            brief: brief,
            candidates: candidates
        )
        let output = try await executor.execute(prompt: prompt)
        let response = try JSONDecoder().decode(
            RankingResponse.self,
            from: Data(output.utf8)
        )
        let knownIDs = Set(candidates.map(\.id))
        var seen = Set<String>()
        let ranked = response.trackIDs.filter {
            knownIDs.contains($0) && seen.insert($0).inserted
        }
        guard !ranked.isEmpty else {
            throw CodexTrackRankingError.invalidResponse
        }
        return ranked
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

        请为这一段电台节目排列歌曲。兼顾用户偏好、能量曲线、艺人间隔和主持衔接。
        只从候选歌曲中选择，按播放顺序返回 5 到 8 个 track_ids。
        不要调用工具，不要读取文件，只完成排序。

        \(inputJSON)
        """
    }
}

private struct RankingResponse: Decodable {
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
