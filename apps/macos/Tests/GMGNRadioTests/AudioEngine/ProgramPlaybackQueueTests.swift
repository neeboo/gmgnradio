import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func programPlaybackQueueKeepsCurrentTwoLockedAndTheRestInReserve() async throws {
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    )

    try await queue.load(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"]))

    #expect(queue.current?.slot.track.id == "1")
    #expect(queue.locked.map(\.slot.track.id) == ["2", "3"])
    #expect(queue.reserve.map(\.track.id) == ["4", "5", "6"])
    #expect(preparer.requestedTrackIDs == ["1", "2", "3"])
}

@Test
@MainActor
func programPlaybackQueueUsesReserveWhenAnUpcomingTrackFailsPreflight() async throws {
    let preparer = PlaybackPreparingSpy()
    preparer.failingTrackIDs = ["2"]
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    )

    try await queue.load(playbackPlan(ids: ["1", "2", "3", "4", "5"]))

    #expect(queue.current?.slot.track.id == "1")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "4"])
    #expect(queue.reserve.map(\.track.id) == ["5"])
    #expect(queue.failedTrackIDs == ["2"])
    #expect(preparer.requestedTrackIDs == ["1", "2", "3", "4"])
}

@Test
@MainActor
func programPlaybackQueueAdvancesAndRefillsAfterCompletion() async throws {
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    )
    try await queue.load(playbackPlan(ids: ["1", "2", "3", "4", "5"]))

    let next = await queue.advanceAfterCompletion()

    #expect(next?.slot.track.id == "2")
    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "4"])
    #expect(queue.reserve.map(\.track.id) == ["5"])
    #expect(preparer.requestedTrackIDs == ["1", "2", "3", "4"])
}

@Test
@MainActor
func programPlaybackQueueSkipsFailedReserveTracksWhileRefilling() async throws {
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    )
    try await queue.load(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"]))
    preparer.failingTrackIDs = ["4"]

    _ = await queue.advanceAfterCompletion()

    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "5"])
    #expect(queue.reserve.map(\.track.id) == ["6"])
    #expect(queue.failedTrackIDs == ["4"])
}

@Test
@MainActor
func programPlaybackQueueReplacesTheCurrentTrackAfterPlaybackFailure() async throws {
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    )
    try await queue.load(playbackPlan(ids: ["1", "2", "3", "4"]))

    let replacement = await queue.replaceCurrentAfterFailure()

    #expect(replacement?.slot.track.id == "2")
    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "4"])
    #expect(queue.failedTrackIDs == ["1"])
}

@Test
@MainActor
func programPlaybackQueueReportsWhenNoSlotCanBePrepared() async {
    let preparer = PlaybackPreparingSpy()
    preparer.failingTrackIDs = ["1", "2"]
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    )

    await #expect(
        throws: ProgramPlaybackQueueError.noPlayableSlots(
            failedTrackIDs: ["1", "2"]
        )
    ) {
        try await queue.load(playbackPlan(ids: ["1", "2"]))
    }
}

@Test
func programPlaybackQueueErrorExplainsTheFailureInChinese() {
    let error = ProgramPlaybackQueueError.noPlayableSlots(
        failedTrackIDs: ["1", "2"]
    )

    #expect(
        error.errorDescription
            == "这档节目里的歌曲暂时都无法播放。"
    )
}

private func playbackPlan(ids: [String]) -> ProgramPlan {
    ProgramPlan(
        brief: ProgramBrief(
            id: "queue-test",
            targetDuration: 30 * 60,
            moodTags: ["focus"],
            energyArc: [0.4, 0.6],
            conversationMode: .ambient
        ),
        slots: ids.map { playbackSlot(id: $0) },
        revision: 1,
        generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
        replanAfterTrackCount: 2
    )
}
