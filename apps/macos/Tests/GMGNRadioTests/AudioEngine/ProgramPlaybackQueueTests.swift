import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func programPlaybackQueueKeepsCurrentTwoLockedAndTheRestInReserve() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    , call: fixture.call)

    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"])))

    #expect(queue.current?.slot.track.id == "1")
    #expect(queue.locked.map(\.slot.track.id) == ["2", "3"])
    #expect(queue.reserve.map(\.track.id) == ["4", "5", "6"])
    #expect(preparer.requestedTrackIDs == ["1", "2", "3"])
}

@Test
@MainActor
func programPlaybackQueueRestoresAtTheSavedTrack() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    , call: fixture.call)

    try await queue.load(
        try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"])),
        startingAt: 2
    )

    #expect(queue.current?.slot.track.id == "3")
    #expect(queue.locked.map(\.slot.track.id) == ["4", "5"])
    #expect(queue.reserve.map(\.track.id) == ["6"])
    #expect(preparer.requestedTrackIDs == ["3", "4", "5"])
}

@Test
@MainActor
func selectingPreparedTrackReusesItWithoutAnotherPreflight() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer), call: fixture.call
    )
    let plan = try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"]))
    try await queue.load(plan)

    try await queue.select(plan, at: 1)

    #expect(queue.current?.slot.track.id == "2")
    #expect(preparer.requestedTrackIDs == ["1", "2", "3"])
}

@Test
@MainActor
func selectingUnpreparedTrackOnlyPreparesTheRequestedSong() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer), call: fixture.call
    )
    let plan = try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"]))
    try await queue.load(plan)

    try await queue.select(plan, at: 4)

    #expect(queue.current?.slot.track.id == "5")
    #expect(preparer.requestedTrackIDs == ["1", "2", "3", "5"])
}

@Test
@MainActor
func savedProgramRestorerReturnsAPlayableReadyState() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let plan = try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5"]))
    let store = DJProgramStore(client: fixture.client)
    try await store.publish(plan)
    try await store.activateSlot(at: 2)
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: PlaybackPreparingSpy()), call: fixture.call
    )
    let restorer = SavedProgramPlaybackRestorer(queue: queue)

    let candidate = try await restorer.restore(from: store)
    let restored = try #require(candidate)

    #expect(restored.plan == plan)
    #expect(restored.prepared.slot.track.id == "3")
    #expect(restored.playbackState == .ready)
}

@Test
func playbackToggleRoutesAnIdlePlayerToTheRestoredProgram() {
    #expect(
        ProgramPlaybackToggleRoute.resolve(
            playerState: .idle,
            hasPreparedProgram: true
        ) == .startPreparedProgram
    )
    #expect(
        ProgramPlaybackToggleRoute.resolve(
            playerState: .idle,
            hasPreparedProgram: false
        ) == .unavailable
    )
}

@Test
func agentPlayCommandStartsTheCurrentlySelectedProgramWhenIdle() {
    #expect(
        ProgramPlaybackStartRoute.resolve(
            playerState: .idle,
            hasPreparedProgram: true
        ) == .startPreparedProgram
    )
    #expect(
        ProgramPlaybackStartRoute.resolve(
            playerState: .paused,
            hasPreparedProgram: true
        ) == .resumeLocal
    )
    #expect(
        ProgramPlaybackStartRoute.resolve(
            playerState: .playing,
            hasPreparedProgram: true
        ) == .alreadyPlaying
    )
}

@Test
@MainActor
func programPlaybackQueueUsesReserveWhenAnUpcomingTrackFailsPreflight() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    preparer.failingTrackIDs = ["2"]
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer)
    , call: fixture.call)

    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5"])))

    #expect(queue.current?.slot.track.id == "1")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "4"])
    #expect(queue.reserve.map(\.track.id) == ["5"])
    #expect(queue.failedTrackIDs == ["2"])
    #expect(preparer.requestedTrackIDs == ["1", "2", "3", "4"])
}

@Test
@MainActor
func programPlaybackQueueAdvancesAndRefillsAfterCompletion() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer), call: fixture.call
    )
    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5"])))

    let next = try await queue.advanceAfterCompletion()

    #expect(next?.slot.track.id == "2")
    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "4"])
    #expect(queue.reserve.map(\.track.id) == ["5"])
    #expect(preparer.requestedTrackIDs == ["1", "2", "3", "4"])
}

@Test
@MainActor
func programPlaybackQueueSkipsFailedReserveTracksWhileRefilling() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer), call: fixture.call
    )
    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4", "5", "6"])))
    preparer.failingTrackIDs = ["4"]

    _ = try await queue.advanceAfterCompletion()

    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "5"])
    #expect(queue.reserve.map(\.track.id) == ["6"])
    #expect(queue.failedTrackIDs == ["4"])
}

@Test
@MainActor
func programPlaybackQueueReplacesTheCurrentTrackAfterPlaybackFailure() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer), call: fixture.call
    )
    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4"])))

    let replacement = try await queue.replaceCurrentAfterFailure()

    #expect(replacement?.slot.track.id == "2")
    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.locked.map(\.slot.track.id) == ["3", "4"])
    #expect(queue.failedTrackIDs == ["1"])
}

@Test
@MainActor
func programPlaybackQueueReturnsToThePreviousTrackWithoutLosingTheCurrentOne() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: PlaybackPreparingSpy()), call: fixture.call
    )
    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4"])))

    _ = try await queue.advanceAfterCompletion()
    let previous = try await queue.returnToPrevious()

    #expect(previous?.slot.track.id == "1")
    #expect(queue.current?.slot.track.id == "1")
    #expect(queue.locked.map(\.slot.track.id) == ["2", "3", "4"])
    #expect(queue.canReturnToPrevious == false)
    #expect(queue.canAdvance == true)
}

@Test
@MainActor
func replacingUpcomingTracksKeepsTheSongThatIsPlaying() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: PlaybackPreparingSpy()), call: fixture.call
    )
    try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2", "3", "4"])))
    _ = try await queue.advanceAfterCompletion()

    let replacement = try await fixture.seed(playbackPlan(ids: ["5", "6"]))
    try await queue.replaceUpcoming(programID: replacement.brief.id, programRevision: replacement.revision, startingAt: 0)

    #expect(queue.current?.slot.track.id == "2")
    #expect(queue.history.map(\.slot.track.id) == ["1"])
    #expect(queue.locked.map(\.slot.track.id) == ["5", "6"])

    let next = try await queue.advanceAfterCompletion()
    #expect(next?.slot.track.id == "5")
}

@Test
@MainActor
func programPlaybackQueueReportsWhenNoSlotCanBePrepared() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let preparer = PlaybackPreparingSpy()
    preparer.failingTrackIDs = ["1", "2"]
    let queue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(preparer: preparer), call: fixture.call
    )

    await #expect(
        throws: ProgramPlaybackQueueError.noPlayableSlots(
            failedTrackIDs: ["1", "2"]
        )
    ) {
        try await queue.load(try await fixture.seed(playbackPlan(ids: ["1", "2"])))
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
