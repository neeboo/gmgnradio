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
