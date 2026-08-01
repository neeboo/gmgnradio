import Foundation
import os

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
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "PlaybackPreflight"
    )
    private let preparer: any ProgramPlaybackPreparing

    init(preparer: any ProgramPlaybackPreparing) {
        self.preparer = preparer
    }

    func prepare(
        _ slot: ProgramSlot
    ) async throws -> PreparedProgramPlayback {
        logger.info(
            "预检入口：track=\(slot.track.id, privacy: .public)，provider=\(slot.track.providerID.rawValue, privacy: .public)，isPlayable=\(slot.track.isPlayable)"
        )
        guard slot.track.isPlayable else {
            logger.error(
                "预检拒绝：track=\(slot.track.id, privacy: .public) 标记为不可播放"
            )
            throw PlaybackPreflightError.trackUnavailable(slot.track.id)
        }
        do {
            let target = try await preparer.preparePlayback(
                for: slot.track
            )
            logger.info(
                "预检成功：track=\(slot.track.id, privacy: .public)，target=\(String(describing: target), privacy: .public)"
            )
            return PreparedProgramPlayback(slot: slot, target: target)
        } catch {
            logger.error(
                "预检异常：track=\(slot.track.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
