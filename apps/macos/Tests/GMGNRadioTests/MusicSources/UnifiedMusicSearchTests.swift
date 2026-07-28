import Testing
@testable import GMGNRadio

@Test
func unifiedSearchKeepsPlayableCandidatesAndDeduplicatesRecordings() async throws {
    let local = StubMusicSource(
        id: "local",
        candidates: [
            candidate(
                id: "local-blue",
                canonicalID: "isrc:blue",
                title: "Blue Hour",
                source: .localLibrary,
                matchScore: 0.7
            ),
            candidate(
                id: "local-broken",
                title: "Broken File",
                source: .localLibrary,
                isPlayable: false,
                matchScore: 1
            )
        ]
    )
    let streaming = StubMusicSource(
        id: "streaming",
        candidates: [
            candidate(
                id: "stream-blue",
                canonicalID: "isrc:blue",
                title: "Blue Hour",
                source: .streaming,
                matchScore: 0.9
            ),
            candidate(
                id: "stream-night",
                title: "Night Drive",
                source: .streaming,
                matchScore: 0.8
            )
        ]
    )
    let search = UnifiedMusicSearch(sources: [local, streaming])

    let results = try await search.search(MusicSearchRequest(
        text: "安静但不伤感",
        moodTags: ["calm", "warm"],
        limit: 10
    ))

    #expect(results.map(\.id) == ["stream-blue", "stream-night"])
    #expect(results.allSatisfy { $0.isPlayable })
}

@Test
func unifiedSearchSkipsStreamingSourcesUntilTheirAccountIsReady() async throws {
    let disconnected = StubMusicSource(
        id: "streaming",
        access: .accountRequired(.disconnected),
        candidates: [
            candidate(
                id: "private-track",
                title: "Private Track",
                source: .streaming
            )
        ]
    )
    let local = StubMusicSource(
        id: "local",
        candidates: [
            candidate(id: "local-track", title: "Local Track")
        ]
    )

    let results = try await UnifiedMusicSearch(
        sources: [disconnected, local]
    ).search(MusicSearchRequest(text: "night", limit: 10))

    #expect(results.map(\.id) == ["local-track"])
}

private struct StubMusicSource: MusicSource {
    let id: String
    var access: MusicSourceAccess = .local
    let candidates: [MusicCandidate]

    func search(_ request: MusicSearchRequest) async throws -> [MusicCandidate] {
        candidates
    }
}
