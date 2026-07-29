import Testing
@testable import GMGNRadio

@Test
func agentProgramPlannerUsesTheAgentsTrackOrder() async throws {
    let agent = DJTrackRankingAgentStub(
        trackIDs: ["5", "2", "4", "1", "3"]
    )
    let planner = AgentProgramPlanner(agent: agent)
    let brief = ProgramBrief(
        id: "agent-show",
        targetDuration: 20 * 60,
        moodTags: ["warm"],
        energyArc: [0.3, 0.5, 0.6],
        conversationMode: .ambient
    )
    let candidates = [
        candidate(id: "1", title: "One", artist: "A"),
        candidate(id: "2", title: "Two", artist: "B"),
        candidate(id: "3", title: "Three", artist: "C"),
        candidate(id: "4", title: "Four", artist: "D"),
        candidate(id: "5", title: "Five", artist: "E"),
        candidate(id: "6", title: "Six", artist: "F"),
    ]

    let plan = try await planner.makePlan(
        brief: brief,
        candidates: candidates
    )

    #expect(plan.slots.map(\.track.id) == ["5", "2", "4", "1", "3"])
}

private struct DJTrackRankingAgentStub: DJTrackRankingAgent {
    let trackIDs: [String]

    func rankTracks(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> [String] {
        trackIDs
    }
}
