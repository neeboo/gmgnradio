import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func codexPlanningExecutorRequestsTheStructuredShowSchema() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    try fixture.mockOutput(structuredShowOutput)
    let proposal = try await fixture.client.modelProposal(
        brief: structuredShowBrief, candidates: [structuredShowCandidate],
        configuration: fixture.configuration()
    )
    let output = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
    #expect(output.contains(#""title":"测试节目""#))
    let schema = try #require(fixture.capturedSchema)
    #expect(schema.contains(#""title""#))
    #expect(schema.contains(#""direction""#))
    #expect(schema.contains(#""selection_reason""#))
    #expect(schema.contains(#""should_talk_before""#))
    #expect(schema.contains(#""transition_intent""#))
    #expect(schema.contains(#""visual""#))
    let decoded = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
    #expect(decoded["additionalProperties"] as? Bool == false)
}

@Test
@MainActor
func codexPlanningExecutorUsesTheConfiguredModel() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    try fixture.mockOutput(structuredShowOutput)
    let base = fixture.configuration()
    let configuration = DJPlanningConfiguration(hostPrompt: base.hostPrompt, executable: base.executable,
                                                environment: base.environment, model: "gpt-5.4")
    _ = try await fixture.client.modelProposal(
        brief: structuredShowBrief, candidates: [structuredShowCandidate], configuration: configuration
    )
    #expect(fixture.capturedArguments.contains(["--model", "gpt-5.4"]))
}

private let structuredShowOutput = #"{"title":"测试节目","direction":"测试方向","slots":[{"track_id":"1","selection_reason":"候选曲目","should_talk_before":true,"transition_intent":"开场","visual":{"mood":"夜晚","palette":"蓝","motion":"缓慢","intensity":0.3}}]}"#
private let structuredShowBrief = ProgramBrief(id: "structured-private", targetDuration: 1_800,
                                             moodTags: [], energyArc: [0.5], conversationMode: .ambient,
                                             immediateUserInstruction: "排一档节目")
private let structuredShowCandidate = MusicCandidate(
    id: "1", canonicalID: nil, providerID: .netease, source: .streaming,
    title: "测试歌曲", artist: "测试艺人", album: nil, duration: 240, isPlayable: true,
    matchScore: 0.8, userAffinity: 0.7, energy: 0.5, moodTags: [], genres: [], releaseYear: nil
)
private extension Array where Element == String {
    func contains(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, count >= sequence.count else { return false }
        return indices.dropLast(sequence.count - 1).contains { index in
            Array(self[index ..< index + sequence.count]) == sequence
        }
    }
}
