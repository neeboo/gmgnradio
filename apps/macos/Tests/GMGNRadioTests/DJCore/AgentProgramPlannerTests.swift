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

@Test
func agentProgramPlannerAppliesShowStoryHostingAndVisualSemantics() async throws {
    let agent = DJShowPlanningAgentStub(
        proposal: AgentShowProposal(
            title: "午后推进",
            direction: "先舒展，再提亮，最后回到专注",
            slots: [
                AgentShowSlotProposal(
                    trackID: "5",
                    selectionReason: "熟悉的节奏适合开场",
                    shouldTalkBefore: true,
                    transitionIntent: "一句话说明节目方向",
                    visual: AgentVisualDirection(
                        mood: "清醒",
                        palette: "电光蓝",
                        motion: "缓慢公转",
                        intensity: 0.4
                    )
                ),
                AgentShowSlotProposal(
                    trackID: "2",
                    selectionReason: "把鼓点往前推",
                    shouldTalkBefore: false,
                    transitionIntent: "直接衔接",
                    visual: AgentVisualDirection(
                        mood: "推进",
                        palette: "蓝紫",
                        motion: "向前穿行",
                        intensity: 0.7
                    )
                ),
            ]
        )
    )
    let planner = AgentProgramPlanner(agent: agent)
    let candidates = [
        candidate(id: "1", title: "One", artist: "A"),
        candidate(id: "2", title: "Two", artist: "B"),
        candidate(id: "3", title: "Three", artist: "C"),
        candidate(id: "4", title: "Four", artist: "D"),
        candidate(id: "5", title: "Five", artist: "E"),
        candidate(id: "6", title: "Six", artist: "F"),
    ]

    let plan = try await planner.makePlan(
        brief: ProgramBrief(
            id: "show",
            targetDuration: 20 * 60,
            moodTags: ["focus"],
            energyArc: [0.3, 0.7, 0.4],
            conversationMode: .ambient
        ),
        candidates: candidates
    )

    #expect(plan.title == "午后推进")
    #expect(plan.direction == "先舒展，再提亮，最后回到专注")
    #expect(plan.slots.map(\.track.id).starts(with: ["5", "2"]))
    #expect(plan.slots[0].hostHint.selectionReason == "熟悉的节奏适合开场")
    #expect(plan.slots[0].hostHint.shouldTalkBefore)
    #expect(plan.slots[0].hostHint.transitionIntent == "一句话说明节目方向")
    #expect(plan.slots[0].visualDirection?.mood == "清醒")
    #expect(plan.slots[1].hostHint.selectionReason == "把鼓点往前推")
    #expect(plan.slots[1].visualDirection?.intensity == 0.7)
}

@Test
func agentProgramPlannerFallsBackSafelyWhenShowPlanningFails() async throws {
    let planner = AgentProgramPlanner(
        agent: FailingDJShowPlanningAgentStub()
    )
    let candidates = [
        candidate(id: "1", title: "One", artist: "A"),
        candidate(id: "2", title: "Two", artist: "B"),
        candidate(id: "3", title: "Three", artist: "C"),
        candidate(id: "4", title: "Four", artist: "D"),
        candidate(id: "5", title: "Five", artist: "E"),
    ]

    let plan = try await planner.makePlan(
        brief: ProgramBrief(
            id: "fallback",
            targetDuration: 20 * 60,
            moodTags: ["warm"],
            energyArc: [0.3, 0.6, 0.4],
            conversationMode: .quiet,
            immediateUserInstruction: "少说点"
        ),
        candidates: candidates
    )

    #expect(plan.title == nil)
    #expect(plan.direction == nil)
    #expect(plan.slots.count == 5)
    #expect(plan.slots.filter(\.hostHint.shouldTalkBefore).count == 1)
    #expect(plan.slots.allSatisfy { !$0.hostHint.selectionReason.isEmpty })
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

private struct DJShowPlanningAgentStub: DJShowPlanningAgent {
    let proposal: AgentShowProposal

    func proposeShow(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> AgentShowProposal {
        proposal
    }
}

private struct FailingDJShowPlanningAgentStub: DJShowPlanningAgent {
    struct ExpectedFailure: Error {}

    func proposeShow(
        brief: ProgramBrief,
        candidates: [MusicCandidate]
    ) async throws -> AgentShowProposal {
        throw ExpectedFailure()
    }
}
