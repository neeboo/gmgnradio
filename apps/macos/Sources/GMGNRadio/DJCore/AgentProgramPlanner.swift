import Foundation

protocol DJTrackRankingAgent: Sendable {
    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String]
}

struct AgentProgramPlanner: Sendable {
    private let agent: any DJTrackRankingAgent
    private let fallback: ProgramPlanner

    init(
        agent: any DJTrackRankingAgent,
        fallback: ProgramPlanner = ProgramPlanner()
    ) {
        self.agent = agent
        self.fallback = fallback
    }

    func makePlan(
        brief: ProgramBrief,
        candidates: [MusicCandidate],
        revision: Int = 1,
        generatedAt: Date = Date()
    ) async throws -> ProgramPlan {
        let preferredTrackIDs = (
            try? await agent.rankTracks(
                brief: brief,
                candidates: candidates
            )
        ) ?? []
        return try fallback.makePlan(
            brief: brief,
            candidates: candidates,
            preferredTrackIDs: preferredTrackIDs,
            revision: revision,
            generatedAt: generatedAt
        )
    }
}
