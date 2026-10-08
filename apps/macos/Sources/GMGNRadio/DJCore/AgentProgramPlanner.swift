import Foundation

protocol DJTrackRankingAgent: Sendable {
    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String]
}

protocol DJShowPlanningAgent: DJTrackRankingAgent {
    func proposeShow(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> AgentShowProposal
}

extension DJShowPlanningAgent {
    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String] {
        try await proposeShow(
            brief: brief,
            candidates: candidates
        ).slots.map(\.trackID)
    }
}

protocol DJPlanningConfigurationProviding: DJTrackRankingAgent {
    var planningConfiguration: DJPlanningConfiguration { get }
}

@MainActor struct AgentProgramPlanner {
    private let agent: any DJTrackRankingAgent
    private let client: RustMusicProgramClient

    init(
        agent: any DJTrackRankingAgent,
        client: RustMusicProgramClient? = nil
    ) {
        self.agent = agent
        self.client = client ?? RustMusicProgramClient()
    }

    func makePlan(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> ProgramPlan {
        try await makePlan(brief: brief, discoveryCandidates: candidates, libraryCandidates: [])
    }
    func makePlan(brief: ProgramBrief, discoveryCandidates: [MusicCandidate],
                  libraryCandidates: [MusicCandidate]) async throws -> ProgramPlan {
        guard let config = (agent as? any DJPlanningConfigurationProviding)?.planningConfiguration else {
            throw CodexTrackRankingError.invalidResponse
        }
        return try await client.plan(brief: brief, discoveryCandidates: discoveryCandidates,
            libraryCandidates: libraryCandidates, hostPrompt: config.hostPrompt,
            executable: config.executable, environment: config.environment, model: config.model)
    }
}
