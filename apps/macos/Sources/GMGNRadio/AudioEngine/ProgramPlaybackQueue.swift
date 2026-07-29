import Foundation
import os

enum ProgramPlaybackQueueError: Error, Equatable, LocalizedError {
    case noPlayableSlots(failedTrackIDs: [String])

    var errorDescription: String? {
        switch self {
        case .noPlayableSlots:
            "这档节目里的歌曲暂时都无法播放。"
        }
    }
}

@MainActor
final class ProgramPlaybackQueue {
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "program-playback"
    )
    private let preflight: PlaybackPreflight
    private let lockedCapacity: Int

    private(set) var current: PreparedProgramPlayback?
    private(set) var locked: [PreparedProgramPlayback] = []
    private(set) var reserve: [ProgramSlot] = []
    private(set) var failedTrackIDs: [String] = []
    private(set) var history: [PreparedProgramPlayback] = []

    var canReturnToPrevious: Bool {
        !history.isEmpty
    }

    var canAdvance: Bool {
        !locked.isEmpty || !reserve.isEmpty
    }

    init(
        preflight: PlaybackPreflight,
        lockedCapacity: Int = 2
    ) {
        self.preflight = preflight
        self.lockedCapacity = max(0, lockedCapacity)
    }

    func load(_ plan: ProgramPlan) async throws {
        current = nil
        locked = []
        reserve = plan.slots
        failedTrackIDs = []
        history = []

        await fillPreparedWindow()
        guard current != nil else {
            throw ProgramPlaybackQueueError.noPlayableSlots(
                failedTrackIDs: failedTrackIDs
            )
        }
    }

    @discardableResult
    func advanceAfterCompletion() async -> PreparedProgramPlayback? {
        if let current {
            history.append(current)
        }
        current = locked.isEmpty ? nil : locked.removeFirst()
        await fillPreparedWindow()
        return current
    }

    @discardableResult
    func returnToPrevious() -> PreparedProgramPlayback? {
        guard let previous = history.popLast() else {
            return nil
        }
        if let current {
            locked.insert(current, at: 0)
        }
        current = previous
        return previous
    }

    @discardableResult
    func replaceCurrentAfterFailure() async -> PreparedProgramPlayback? {
        if let failedID = current?.slot.track.id {
            failedTrackIDs.append(failedID)
        }
        current = locked.isEmpty ? nil : locked.removeFirst()
        await fillPreparedWindow()
        return current
    }

    private func fillPreparedWindow() async {
        while needsPreparedSlot, !reserve.isEmpty {
            let slot = reserve.removeFirst()
            do {
                let prepared = try await preflight.prepare(slot)
                if current == nil {
                    current = prepared
                } else {
                    locked.append(prepared)
                }
            } catch {
                failedTrackIDs.append(slot.track.id)
                let reason = (error as? any LocalizedError)?
                    .errorDescription ?? String(reflecting: type(of: error))
                logger.error(
                    "预检失败：\(slot.track.id, privacy: .public)，\(reason, privacy: .public)"
                )
            }
        }
    }

    private var needsPreparedSlot: Bool {
        current == nil || locked.count < lockedCapacity
    }
}
