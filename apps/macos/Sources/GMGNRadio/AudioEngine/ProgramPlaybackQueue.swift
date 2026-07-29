import Foundation

enum ProgramPlaybackQueueError: Error, Equatable {
    case noPlayableSlots(failedTrackIDs: [String])
}

@MainActor
final class ProgramPlaybackQueue {
    private let preflight: PlaybackPreflight
    private let lockedCapacity: Int

    private(set) var current: PreparedProgramPlayback?
    private(set) var locked: [PreparedProgramPlayback] = []
    private(set) var reserve: [ProgramSlot] = []
    private(set) var failedTrackIDs: [String] = []

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

        await fillPreparedWindow()
        guard current != nil else {
            throw ProgramPlaybackQueueError.noPlayableSlots(
                failedTrackIDs: failedTrackIDs
            )
        }
    }

    @discardableResult
    func advanceAfterCompletion() async -> PreparedProgramPlayback? {
        current = locked.isEmpty ? nil : locked.removeFirst()
        await fillPreparedWindow()
        return current
    }

    @discardableResult
    func replaceCurrentAfterFailure() async -> PreparedProgramPlayback? {
        if let failedID = current?.slot.track.id {
            failedTrackIDs.append(failedID)
        }
        return await advanceAfterCompletion()
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
            }
        }
    }

    private var needsPreparedSlot: Bool {
        current == nil || locked.count < lockedCapacity
    }
}
