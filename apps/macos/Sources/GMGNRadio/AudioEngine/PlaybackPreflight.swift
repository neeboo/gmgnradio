import Foundation

enum PreparedPlaybackTarget: Equatable, Sendable {
    case localFile(URL)
    case providerReference(
        providerID: MusicProviderID,
        trackID: String
    )
}

struct PreparedProgramPlayback: Equatable, Sendable {
    let slot: ProgramSlot
    let target: PreparedPlaybackTarget
}

enum PlaybackPreflightError: Error, Equatable {
    case trackUnavailable(String)
}

@MainActor
protocol ProgramPlaybackPreparing {
    func preparePlayback(
        for track: MusicCandidate
    ) async throws -> PreparedPlaybackTarget
}

@MainActor
struct PlaybackPreflight {
    private let preparer: any ProgramPlaybackPreparing

    init(preparer: any ProgramPlaybackPreparing) {
        self.preparer = preparer
    }

    func prepare(
        _ slot: ProgramSlot
    ) async throws -> PreparedProgramPlayback {
        guard slot.track.isPlayable else {
            throw PlaybackPreflightError.trackUnavailable(slot.track.id)
        }
        return PreparedProgramPlayback(
            slot: slot,
            target: try await preparer.preparePlayback(for: slot.track)
        )
    }
}
