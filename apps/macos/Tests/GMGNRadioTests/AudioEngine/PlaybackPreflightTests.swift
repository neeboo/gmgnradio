import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func playbackPreflightPreparesAProviderNeutralPlaybackTarget() async throws {
    let preparer = PlaybackPreparingSpy()
    preparer.targets["one"] = .localFile(
        URL(fileURLWithPath: "/tmp/one.wav")
    )
    let preflight = PlaybackPreflight(preparer: preparer)

    let prepared = try await preflight.prepare(
        playbackSlot(id: "one")
    )

    #expect(prepared.slot.track.id == "one")
    #expect(
        prepared.target
            == .localFile(URL(fileURLWithPath: "/tmp/one.wav"))
    )
    #expect(preparer.requestedTrackIDs == ["one"])
}

@Test
@MainActor
func playbackPreflightRejectsATrackMarkedUnavailableWithoutPreparingIt() async {
    let preparer = PlaybackPreparingSpy()
    let preflight = PlaybackPreflight(preparer: preparer)

    await #expect(throws: PlaybackPreflightError.trackUnavailable("broken")) {
        try await preflight.prepare(
            playbackSlot(id: "broken", isPlayable: false)
        )
    }
    #expect(preparer.requestedTrackIDs.isEmpty)
}

@MainActor
final class PlaybackPreparingSpy: ProgramPlaybackPreparing {
    enum Failure: Error {
        case unavailable
    }

    var targets: [String: PreparedPlaybackTarget] = [:]
    var failingTrackIDs = Set<String>()
    private(set) var requestedTrackIDs: [String] = []

    func preparePlayback(
        for track: MusicCandidate
    ) async throws -> PreparedPlaybackTarget {
        requestedTrackIDs.append(track.id)
        if failingTrackIDs.contains(track.id) {
            throw Failure.unavailable
        }
        return targets[track.id]
            ?? .providerReference(
                providerID: track.providerID,
                trackID: track.id
            )
    }
}

func playbackSlot(
    id: String,
    isPlayable: Bool = true
) -> ProgramSlot {
    let track = MusicCandidate(
        id: id,
        canonicalID: nil,
        providerID: .local,
        source: .localLibrary,
        title: "Track \(id)",
        artist: "Artist \(id)",
        album: nil,
        duration: 180,
        isPlayable: isPlayable,
        matchScore: 0.8,
        userAffinity: 0.7,
        energy: 0.5,
        moodTags: ["focus"],
        genres: ["electronic"],
        releaseYear: 2025
    )
    return ProgramSlot(
        track: track,
        role: .build,
        hostHint: ProgramHostHint(
            shouldTalkBefore: false,
            maxSentenceCount: 1,
            selectionReason: "Fits the program",
            currentTrack: TrackReference(
                id: track.id,
                title: track.title,
                artist: track.artist
            ),
            nextTrack: nil,
            facts: [],
            transitionIntent: nil
        )
    )
}
