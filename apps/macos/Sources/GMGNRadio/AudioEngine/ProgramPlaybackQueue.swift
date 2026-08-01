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

enum ProgramPlaybackToggleRoute: Equatable {
    case pauseLocal
    case resumeLocal
    case startPreparedProgram
    case unavailable

    static func resolve(
        playerState: LocalMusicPlaybackState,
        hasPreparedProgram: Bool
    ) -> ProgramPlaybackToggleRoute {
        switch playerState {
        case .playing:
            .pauseLocal
        case .ready, .paused, .finished:
            .resumeLocal
        case .idle:
            hasPreparedProgram ? .startPreparedProgram : .unavailable
        }
    }
}

enum ProgramPlaybackStartRoute: Equatable {
    case alreadyPlaying
    case resumeLocal
    case startPreparedProgram
    case unavailable

    static func resolve(
        playerState: LocalMusicPlaybackState,
        hasPreparedProgram: Bool
    ) -> ProgramPlaybackStartRoute {
        switch playerState {
        case .playing:
            .alreadyPlaying
        case .ready, .paused, .finished:
            .resumeLocal
        case .idle:
            hasPreparedProgram ? .startPreparedProgram : .unavailable
        }
    }
}

struct RestoredProgramPlayback {
    let plan: ProgramPlan
    let prepared: PreparedProgramPlayback
    let playbackState: LocalMusicPlaybackState
}

@MainActor
struct SavedProgramPlaybackRestorer {
    let queue: ProgramPlaybackQueue

    func restore(
        from store: DJProgramStore
    ) async throws -> RestoredProgramPlayback? {
        guard let plan = store.plan, !plan.slots.isEmpty else {
            return nil
        }
        try await queue.load(
            plan,
            startingAt: store.activeSlotIndex ?? 0
        )
        guard let prepared = queue.current else {
            return nil
        }
        return RestoredProgramPlayback(
            plan: plan,
            prepared: prepared,
            playbackState: .ready
        )
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

    func load(
        _ plan: ProgramPlan,
        startingAt requestedIndex: Int = 0
    ) async throws {
        let startingIndex = plan.slots.isEmpty
            ? 0
            : min(max(requestedIndex, 0), plan.slots.count - 1)
        current = nil
        locked = []
        reserve = Array(plan.slots.dropFirst(startingIndex))
        failedTrackIDs = []
        history = []

        logger.info(
            "加载节目队列：program=\(plan.brief.id, privacy: .public)，requestedIndex=\(requestedIndex)，startingIndex=\(startingIndex)，slots=\(plan.slots.count)"
        )
        await fillPreparedWindow()
        guard current != nil else {
            logger.error(
                "节目队列加载失败：failed=\(self.failedTrackIDs.joined(separator: ","), privacy: .public)"
            )
            throw ProgramPlaybackQueueError.noPlayableSlots(
                failedTrackIDs: failedTrackIDs
            )
        }
    }

    func select(
        _ plan: ProgramPlan,
        at requestedIndex: Int
    ) async throws {
        guard !plan.slots.isEmpty else {
            throw ProgramPlaybackQueueError.noPlayableSlots(
                failedTrackIDs: []
            )
        }
        let selectedIndex = min(
            max(requestedIndex, 0),
            plan.slots.count - 1
        )
        let selectedSlot = plan.slots[selectedIndex]
        logger.info(
            "选择歌曲：index=\(selectedIndex)，track=\(selectedSlot.track.id, privacy: .public)，title=\(selectedSlot.track.title, privacy: .public)"
        )
        let preparedByTrackID = (
            [current].compactMap { $0 }
                + locked
                + history
        ).reduce(into: [String: PreparedProgramPlayback]()) {
            result, prepared in
            result[prepared.slot.track.id] = prepared
        }

        let selected: PreparedProgramPlayback
        do {
            selected = if
                let prepared = preparedByTrackID[selectedSlot.track.id]
            {
                prepared
            } else {
                try await preflight.prepare(selectedSlot)
            }
        } catch {
            logger.error(
                "选择歌曲预检失败：track=\(selectedSlot.track.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        let remainingSlots = Array(
            plan.slots.dropFirst(selectedIndex + 1)
        )
        let preparedUpcoming = remainingSlots.compactMap {
            preparedByTrackID[$0.track.id]
        }
        current = selected
        locked = Array(preparedUpcoming.prefix(lockedCapacity))
        let lockedTrackIDs = Set(locked.map(\.slot.track.id))
        reserve = remainingSlots.filter {
            !lockedTrackIDs.contains($0.track.id)
        }
        failedTrackIDs = []
        history = []
        logger.info(
            "选择歌曲完成：current=\(self.current?.slot.track.id ?? "nil", privacy: .public)，locked=\(self.locked.map(\.slot.track.id).joined(separator: ","), privacy: .public)，reserve=\(self.reserve.count)"
        )
    }

    func replaceUpcoming(with slots: [ProgramSlot]) async {
        locked = []
        reserve = slots
        failedTrackIDs = []
        await fillPreparedWindow()
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
        logger.info(
            "替换失败歌曲：current=\(self.current?.slot.track.id ?? "nil", privacy: .public)，failed=\(self.failedTrackIDs.joined(separator: ","), privacy: .public)"
        )
        await fillPreparedWindow()
        return current
    }

    private func fillPreparedWindow() async {
        while needsPreparedSlot, !reserve.isEmpty {
            let slot = reserve.removeFirst()
            logger.info(
                "开始预检：track=\(slot.track.id, privacy: .public)，title=\(slot.track.title, privacy: .public)，provider=\(slot.track.providerID.rawValue, privacy: .public)"
            )
            do {
                let prepared = try await preflight.prepare(slot)
                if current == nil {
                    current = prepared
                } else {
                    locked.append(prepared)
                }
                logger.info(
                    "预检完成：track=\(slot.track.id, privacy: .public)，target=\(String(describing: prepared.target), privacy: .public)，current=\(self.current?.slot.track.id ?? "nil", privacy: .public)"
                )
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
