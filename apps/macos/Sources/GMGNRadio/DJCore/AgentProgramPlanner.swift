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
        let proposal: AgentShowProposal?
        let preferredTrackIDs: [String]
        if let showAgent = agent as? any DJShowPlanningAgent {
            proposal = try? await showAgent.proposeShow(
                brief: brief,
                candidates: candidates
            )
            preferredTrackIDs = proposal?.slots.map(\.trackID) ?? []
        } else {
            proposal = nil
            preferredTrackIDs = (
                try? await agent.rankTracks(
                    brief: brief,
                    candidates: candidates
                )
            ) ?? []
        }
        return try fallback.makePlan(
            brief: brief,
            candidates: candidates,
            preferredTrackIDs: preferredTrackIDs,
            showProposal: proposal,
            revision: revision,
            generatedAt: generatedAt
        )
    }
}
