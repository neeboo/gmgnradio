import Foundation
import Testing
@testable import GMGNRadio

@Test
func codexAgentRanksOnlyKnownTracksAndSendsNoAccountSecrets() async throws {
    let executor = CodexPlanningExecutorStub(
        output: #"{"track_ids":["3","unknown","1","3","2"]}"#
    )
    let agent = CodexTrackRankingAgent(
        executor: executor,
        hostPrompt: "少说一点，留意当前时间。"
    )
    let candidates = (1 ... 5).map {
        MusicCandidate.fixture(
            id: String($0),
            title: "Track \($0)"
        )
    }

    let result = try await agent.rankTracks(
        brief: ProgramBrief(
            id: "evening",
            targetDuration: 1_800,
            moodTags: ["夜晚", "专注"],
            energyArc: [0.3, 0.6, 0.4],
            conversationMode: .ambient,
            immediateUserInstruction: "少说点"
        ),
        candidates: candidates
    )

    #expect(result == ["3", "1", "2"])
    let prompt = try #require(await executor.lastPrompt())
    #expect(prompt.contains("少说一点，留意当前时间。"))
    #expect(prompt.contains("Track 3"))
    #expect(!prompt.lowercased().contains("cookie"))
    #expect(!prompt.lowercased().contains("token"))
}

@Test
func codexAgentBuildsACompleteShowProposal() async throws {
    let executor = CodexPlanningExecutorStub(
        output: """
        {
          "title": "午夜缓行",
          "direction": "从低亮度电子乐逐步升温，再平静收束",
          "slots": [
            {
              "track_id": "3",
              "selection_reason": "先用熟悉的低能量节奏进入状态",
              "should_talk_before": true,
              "transition_intent": "用短开场建立今晚的方向",
              "visual": {
                "mood": "深夜漂浮",
                "palette": "靛蓝与青色",
                "motion": "缓慢环绕",
                "intensity": 0.32
              }
            },
            {
              "track_id": "unknown",
              "selection_reason": "无效候选",
              "should_talk_before": true,
              "transition_intent": "忽略",
              "visual": {
                "mood": "忽略",
                "palette": "忽略",
                "motion": "忽略",
                "intensity": 1
              }
            },
            {
              "track_id": "1",
              "selection_reason": "把能量稍微抬高",
              "should_talk_before": false,
              "transition_intent": "保持节奏连续",
              "visual": {
                "mood": "霓虹流动",
                "palette": "蓝紫",
                "motion": "向前推进",
                "intensity": 0.55
              }
            }
          ]
        }
        """
    )
    let agent = CodexTrackRankingAgent(
        executor: executor,
        hostPrompt: "像深夜电台主持人一样策划。"
    )
    let candidates = (1 ... 5).map {
        MusicCandidate.fixture(
            id: String($0),
            title: "Track \($0)"
        )
    }

    let proposal = try await agent.proposeShow(
        brief: ProgramBrief(
            id: "midnight",
            targetDuration: 1_800,
            moodTags: ["夜晚"],
            energyArc: [0.3, 0.6, 0.4],
            conversationMode: .ambient
        ),
        candidates: candidates
    )

    #expect(proposal.title == "午夜缓行")
    #expect(proposal.direction.contains("升温"))
    #expect(proposal.slots.map(\.trackID) == ["3", "1"])
    #expect(proposal.slots[0].selectionReason.contains("进入状态"))
    #expect(proposal.slots[0].shouldTalkBefore)
    #expect(proposal.slots[0].transitionIntent.contains("短开场"))
    #expect(proposal.slots[0].visual.mood == "深夜漂浮")
    #expect(proposal.slots[0].visual.palette == "靛蓝与青色")
    #expect(proposal.slots[0].visual.motion == "缓慢环绕")
    #expect(proposal.slots[0].visual.intensity == 0.32)

    let ranked = try await agent.rankTracks(
        brief: proposalBrief,
        candidates: candidates
    )
    #expect(ranked == ["3", "1"])
}

private let proposalBrief = ProgramBrief(
    id: "compatibility",
    targetDuration: 1_800,
    moodTags: ["夜晚"],
    energyArc: [0.3, 0.6, 0.4],
    conversationMode: .ambient
)

private actor CodexPlanningExecutorStub: CodexPlanningExecuting {
    private let output: String
    private var prompt: String?

    init(output: String) {
        self.output = output
    }

    func execute(prompt: String) async throws -> String {
        self.prompt = prompt
        return output
    }

    func lastPrompt() -> String? {
        prompt
    }
}

private extension MusicCandidate {
    static func fixture(id: String, title: String) -> MusicCandidate {
        MusicCandidate(
            id: id,
            canonicalID: nil,
            providerID: .netease,
            source: .streaming,
            title: title,
            artist: "Artist \(id)",
            album: "Album \(id)",
            duration: 240,
            isPlayable: true,
            matchScore: 0.8,
            userAffinity: 0.7,
            energy: 0.5,
            moodTags: ["夜晚"],
            genres: ["电子"],
            releaseYear: 2026
        )
    }
}
