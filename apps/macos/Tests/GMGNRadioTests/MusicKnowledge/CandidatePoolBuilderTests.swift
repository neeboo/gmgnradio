import Foundation
import Testing
@testable import GMGNRadio

@Test
func candidatePoolExcludesRecentlySkippedTracks() async {
    let now = Date(timeIntervalSince1970: 10_000)
    let index = InMemoryMusicLibraryIndex()
    await index.ingest(
        [
            poolCandidate(id: "keep", affinity: 0.8),
            poolCandidate(id: "skip", affinity: 0.9)
        ],
        origin: .saved,
        seenAt: now.addingTimeInterval(-100)
    )
    await index.record(.skipped(
        trackID: "skip",
        at: now.addingTimeInterval(-60)
    ))

    let pool = CandidatePoolBuilder().build(
        from: await index.snapshot(),
        request: CandidatePoolRequest(
            limit: 10,
            now: now,
            recentSkipWindow: 3600
        )
    )

    #expect(pool.items.map(\.candidate.id) == ["keep"])
}

@Test
func candidatePoolUsesFamiliarRediscoveryAndExplorationBuckets() async {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let index = InMemoryMusicLibraryIndex()

    for number in 0 ..< 6 {
        let id = "familiar-\(number)"
        await index.ingest(
            [poolCandidate(id: id, affinity: 0.9 - Double(number) * 0.01)],
            origin: .saved,
            seenAt: now.addingTimeInterval(-1_000)
        )
        await index.record(.played(
            trackID: id,
            completed: true,
            at: now.addingTimeInterval(-86_400)
        ))
    }
    for number in 0 ..< 3 {
        let id = "rediscovery-\(number)"
        await index.ingest(
            [poolCandidate(id: id, affinity: 0.7 - Double(number) * 0.01)],
            origin: .saved,
            seenAt: now.addingTimeInterval(-5_000_000)
        )
        await index.record(.played(
            trackID: id,
            completed: true,
            at: now.addingTimeInterval(-60 * 86_400)
        ))
    }
    for number in 0 ..< 4 {
        await index.ingest(
            [
                poolCandidate(
                    id: "explore-\(number)",
                    affinity: 0.2,
                    matchScore: 0.9 - Double(number) * 0.01
                )
            ],
            origin: .discovery,
            seenAt: now
        )
    }

    let pool = CandidatePoolBuilder().build(
        from: await index.snapshot(),
        request: CandidatePoolRequest(limit: 10, now: now)
    )

    #expect(pool.items.count == 10)
    #expect(pool.items.filter { $0.bucket == .familiar }.count == 6)
    #expect(pool.items.filter { $0.bucket == .rediscovery }.count == 2)
    #expect(pool.items.filter { $0.bucket == .exploration }.count == 2)
}

@Test
func candidatePoolIsDeterministicAndBackfillsMissingBuckets() async {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let index = InMemoryMusicLibraryIndex()
    for id in ["z", "b", "a", "c", "y", "d", "x"] {
        await index.ingest(
            [
                poolCandidate(
                    id: id,
                    affinity: 0.5,
                    matchScore: 0.5
                )
            ],
            origin: .discovery,
            seenAt: now
        )
    }
    let request = CandidatePoolRequest(limit: 5, now: now)
    let builder = CandidatePoolBuilder()

    let first = builder.build(
        from: await index.snapshot(),
        request: request
    )
    let second = builder.build(
        from: (await index.snapshot()).reversed(),
        request: request
    )

    #expect(first.items.count == 5)
    #expect(first.items.map(\.candidate.id) == ["a", "b", "c", "d", "x"])
    #expect(second == first)
    #expect(first.items.allSatisfy { $0.bucket == .exploration })
}

private func poolCandidate(
    id: String,
    affinity: Double,
    matchScore: Double = 0.7
) -> MusicCandidate {
    MusicCandidate(
        id: id,
        canonicalID: nil,
        providerID: .netease,
        source: .streaming,
        title: "Title \(id)",
        artist: "Artist \(id)",
        album: nil,
        duration: 240,
        isPlayable: true,
        matchScore: matchScore,
        userAffinity: affinity,
        energy: 0.5,
        moodTags: ["calm"],
        genres: ["electronic"],
        releaseYear: 2024
    )
}
