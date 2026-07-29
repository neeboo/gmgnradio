import Foundation
import Testing
@testable import GMGNRadio

@Test
func libraryIndexNormalizesMetadataWhenIngesting() async {
    let index = InMemoryMusicLibraryIndex()

    await index.ingest(
        [
            knowledgeCandidate(
                id: "local-1",
                title: "  Blue   Hour ",
                artist: "  The   Lights "
            )
        ],
        origin: .saved,
        seenAt: Date(timeIntervalSince1970: 100)
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(tracks[0].title == "Blue Hour")
    #expect(tracks[0].artist == "The Lights")
    #expect(tracks[0].normalizedMetadataKey == "blue hour|the lights")
    #expect(tracks[0].isSaved)
}

@Test
func libraryIndexDeduplicatesTheSameRecordingAcrossProviders() async {
    let index = InMemoryMusicLibraryIndex()
    let time = Date(timeIntervalSince1970: 100)

    await index.ingest(
        [
            knowledgeCandidate(
                id: "netease-1",
                canonicalID: "ISRC:US-ABC-24-00001",
                title: "Blue Hour",
                artist: "The Lights",
                providerID: .netease
            ),
            knowledgeCandidate(
                id: "qq-9",
                canonicalID: "isrc:us-abc-24-00001",
                title: "Blue Hour (Album Version)",
                artist: "The Lights",
                providerID: .qqMusic
            )
        ],
        origin: .saved,
        seenAt: time
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(tracks[0].identity == "canonical:isrc:us-abc-24-00001")
    #expect(Set(tracks[0].sources.map(\.trackID)) == ["netease-1", "qq-9"])
}

@Test
func libraryIndexMergesMetadataMatchWhenCanonicalIDArrivesLater() async {
    let index = InMemoryMusicLibraryIndex()
    let time = Date(timeIntervalSince1970: 100)

    await index.ingest(
        [
            knowledgeCandidate(
                id: "local-1",
                title: "Café Blue",
                artist: "Beyoncé"
            )
        ],
        origin: .recent,
        seenAt: time
    )
    await index.ingest(
        [
            knowledgeCandidate(
                id: "stream-1",
                canonicalID: "ISRC:ONE",
                title: "Cafe Blue",
                artist: "Beyonce",
                providerID: .netease
            )
        ],
        origin: .saved,
        seenAt: time
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(tracks[0].identity == "canonical:isrc:one")
    #expect(tracks[0].sources.count == 2)
    #expect(tracks[0].isSaved)
}

@Test
func libraryIndexUsesABridgingSourceToMergeExistingIdentities() async {
    let index = InMemoryMusicLibraryIndex()
    let time = Date(timeIntervalSince1970: 100)
    await index.ingest(
        [
            knowledgeCandidate(
                id: "canonical-source",
                canonicalID: "ISRC:BRIDGE",
                title: "Blue Hour Remaster",
                artist: "The Lights",
                providerID: .netease
            ),
            knowledgeCandidate(
                id: "metadata-source",
                title: "Blue Hour",
                artist: "The Lights"
            )
        ],
        origin: .recent,
        seenAt: time
    )

    await index.ingest(
        [
            knowledgeCandidate(
                id: "bridge-source",
                canonicalID: "ISRC:BRIDGE",
                title: "Blue Hour",
                artist: "The Lights",
                providerID: .qqMusic
            )
        ],
        origin: .saved,
        seenAt: time.addingTimeInterval(1)
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(Set(tracks[0].sources.map(\.trackID)) == [
        "canonical-source",
        "metadata-source",
        "bridge-source"
    ])
}

@Test
func listeningHistoryChangesAffinityInTheExpectedDirection() async {
    let index = InMemoryMusicLibraryIndex()
    let time = Date(timeIntervalSince1970: 1_000)
    await index.ingest(
        [knowledgeCandidate(id: "track-1", title: "Known")],
        origin: .saved,
        seenAt: time
    )
    let initial = await index.snapshot()[0].affinityScore

    await index.record(.played(
        trackID: "track-1",
        completed: true,
        at: time.addingTimeInterval(100)
    ))
    await index.record(.liked(
        trackID: "track-1",
        isLiked: true,
        at: time.addingTimeInterval(200)
    ))
    let positive = await index.snapshot()[0].affinityScore

    await index.record(.skipped(
        trackID: "track-1",
        at: time.addingTimeInterval(300)
    ))
    let afterSkip = await index.snapshot()[0].affinityScore

    #expect(positive > initial)
    #expect(afterSkip < positive)
}

private func knowledgeCandidate(
    id: String,
    canonicalID: String? = nil,
    title: String,
    artist: String = "Artist",
    providerID: MusicProviderID = .local,
    isPlayable: Bool = true,
    matchScore: Double = 0.7,
    userAffinity: Double = 0.5,
    energy: Double = 0.5,
    moodTags: [String] = ["calm"]
) -> MusicCandidate {
    MusicCandidate(
        id: id,
        canonicalID: canonicalID,
        providerID: providerID,
        source: providerID == .local ? .localLibrary : .streaming,
        title: title,
        artist: artist,
        album: "Album",
        duration: 240,
        isPlayable: isPlayable,
        matchScore: matchScore,
        userAffinity: userAffinity,
        energy: energy,
        moodTags: moodTags,
        genres: ["electronic"],
        releaseYear: 2024
    )
}
