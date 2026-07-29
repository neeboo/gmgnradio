import Foundation
import Testing
@testable import GMGNRadio

@Test @MainActor
func appleMusicSourceRequiresAuthorizationAndAPlayableSubscription() async {
    let denied = AppleMusicSource(
        client: AppleMusicClientStub(
            authorization: .denied,
            canPlayCatalogContent: false
        )
    )
    let noSubscription = AppleMusicSource(
        client: AppleMusicClientStub(
            authorization: .authorized,
            canPlayCatalogContent: false
        )
    )
    let connected = AppleMusicSource(
        client: AppleMusicClientStub(
            authorization: .authorized,
            canPlayCatalogContent: true
        )
    )

    #expect(await denied.access() == .accountRequired(.denied))
    #expect(await noSubscription.access() == .accountRequired(.unavailable))
    #expect(await connected.access() == .accountRequired(.connected))
}

@Test @MainActor
func appleMusicSourceMapsCatalogSearchAndControlsItsPlayer() async throws {
    let client = AppleMusicClientStub(
        authorization: .authorized,
        canPlayCatalogContent: true,
        tracks: [
            AppleMusicCatalogTrack(
                id: "apple-song-id",
                title: "Midnight City",
                artist: "M83",
                album: "Hurry Up, We're Dreaming",
                duration: 244,
                isPlayable: true,
                isrc: "GB55H1100002",
                genres: ["Alternative"],
                releaseYear: 2011
            ),
        ]
    )
    let source = AppleMusicSource(client: client)

    let results = try await source.search(
        MusicSearchRequest(text: "Midnight City", limit: 5)
    )
    #expect(results.count == 1)
    #expect(results[0].id == "apple-music:apple-song-id")
    #expect(results[0].canonicalID == "GB55H1100002")
    #expect(results[0].providerID == .appleMusic)

    try await source.play(trackID: results[0].id)
    #expect(client.playedTrackIDs == ["apple-song-id"])
}

@MainActor
final class AppleMusicClientStub: AppleMusicClient {
    let authorization: AppleMusicClientAuthorization
    let canPlayCatalogContent: Bool
    let tracks: [AppleMusicCatalogTrack]
    private(set) var playedTrackIDs: [String] = []

    init(
        authorization: AppleMusicClientAuthorization,
        canPlayCatalogContent: Bool,
        tracks: [AppleMusicCatalogTrack] = []
    ) {
        self.authorization = authorization
        self.canPlayCatalogContent = canPlayCatalogContent
        self.tracks = tracks
    }

    func authorizationStatus() -> AppleMusicClientAuthorization {
        authorization
    }

    func requestAuthorization() async -> AppleMusicClientAuthorization {
        authorization
    }

    func hasPlayableSubscription() async throws -> Bool {
        canPlayCatalogContent
    }

    func search(
        term: String,
        limit: Int
    ) async throws -> [AppleMusicCatalogTrack] {
        Array(tracks.prefix(limit))
    }

    func play(trackID: String) async throws {
        playedTrackIDs.append(trackID)
    }

    func pause() async {}

    func skipToNextEntry() async throws {}
}
