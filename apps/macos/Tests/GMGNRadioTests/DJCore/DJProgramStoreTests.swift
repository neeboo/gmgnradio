import Foundation
import Testing
@testable import GMGNRadio

@MainActor
@Test
func programStoreTracksPlanningPublishedAndFailedStates() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let store = DJProgramStore(client: backend.client)
    let plan = ProgramPlan(
        brief: ProgramBrief(
            id: "night",
            targetDuration: 1_800,
            moodTags: ["夜晚"],
            energyArc: [0.3, 0.6, 0.4],
            conversationMode: .ambient
        ),
        slots: [],
        revision: 1,
        generatedAt: Date(timeIntervalSince1970: 1_000),
        replanAfterTrackCount: 2
    )

    store.beginPlanning()
    #expect(store.status == .planning)

    _ = try await backend.seed(plan)
    try await store.publish(plan)
    #expect(store.status == .ready)
    #expect(store.plan == plan)

    store.fail("暂时排不了节目")
    #expect(store.status == .failed("暂时排不了节目"))
    #expect(store.plan == plan)
}

@MainActor
@Test
func programStoreExposesTheActiveSlotForPlaybackAndVisuals() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let store = DJProgramStore(client: backend.client)
    let plan = try await backend.seed(programPlan(trackIDs: ["one", "two"]))

    try await store.publish(plan)
    try await store.activateSlot(at: 1)

    #expect(store.activeSlotIndex == 1)
    #expect(store.activeSlot?.track.id == "two")
}

@MainActor
@Test
func programStorePublishesADraftWithoutReplacingTheActiveProgram() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let store = DJProgramStore(client: backend.client)
    let current = try await backend.seed(programPlan(id: "current", trackIDs: ["one", "two"]))
    let draft = try await backend.seed(programPlan(id: "city-pop", trackIDs: ["three", "four"]))

    try await store.publish(current)
    try await store.activateSlot(at: 0)
    try await store.publishDraft(draft)

    #expect(store.plan == current)
    #expect(store.activeSlotIndex == 0)
    #expect(store.pendingPlan == draft)
    #expect(store.recentPrograms.first?.plan == draft)
    #expect(store.status == .ready)
}

@Test
@MainActor
func programEditorReplansOnlyTheUpcomingPart() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let current = try await backend.seed(programPlan(trackIDs: ["one", "two", "three"]))
    let proposal = try await backend.seed(programPlan(
        id: "proposal",
        trackIDs: ["four", "five", "one"]
    ))

    let revised = try await DJProgramEditor.revise(
        current: current,
        activeSlotIndex: 1,
        proposal: proposal,
        mode: .replanUpcoming, client: backend.client
    )

    #expect(revised.brief.id == current.brief.id)
    #expect(revised.revision == current.revision + 1)
    #expect(revised.slots.map(\.track.id) == [
        "one", "two", "four", "five",
    ])
}

@Test
@MainActor
func programEditorInsertsOneSongAndKeepsTheExistingRun() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let current = try await backend.seed(programPlan(trackIDs: ["one", "two", "three"]))
    let proposal = try await backend.seed(programPlan(
        id: "proposal",
        trackIDs: ["four", "five"]
    ))

    let revised = try await DJProgramEditor.revise(
        current: current,
        activeSlotIndex: 1,
        proposal: proposal,
        mode: .insertNext, client: backend.client
    )

    #expect(revised.slots.map(\.track.id) == [
        "one", "two", "four", "three",
    ])
}

@MainActor
@Test
func programArchivePersistsThePlanAndPlaybackPosition() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let archive = DJProgramArchive(storage: backend.storage)
    let plan = try await backend.seed(programPlan(trackIDs: ["one", "two", "three"]))

    try await backend.legacy(
        plan: plan,
        activeSlotIndex: 1,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    let latest = try await archive.latest()
    let restored = try #require(latest)
    #expect(restored.plan == plan)
    #expect(restored.activeSlotIndex == 1)
    #expect(restored.updatedAt == Date(timeIntervalSince1970: 2_000))
}

@MainActor
@Test
func programStoreRestoresTheLatestSavedProgramOnRelaunch() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let archive = DJProgramArchive(storage: backend.storage)
    let original = DJProgramStore(archive: archive, client: backend.client)
    let plan = try await backend.seed(programPlan(trackIDs: ["one", "two"]))

    try await original.publish(plan)
    try await original.activateSlot(at: 1)

    let relaunched = DJProgramStore(archive: archive, client: backend.client)
    try await original.flush()
    try await relaunched.restoreLatest()

    #expect(relaunched.status == .ready)
    #expect(relaunched.plan == plan)
    #expect(relaunched.activeSlotIndex == 1)
    #expect(relaunched.activeSlot?.track.id == "two")
}

@MainActor
@Test
func programStoreExposesRecentProgramsForTheStageLibrary() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let archive = DJProgramArchive(storage: backend.storage)
    let first = try await backend.seed(programPlan(id: "first", trackIDs: ["one"]))
    let second = try await backend.seed(programPlan(id: "second", trackIDs: ["two"]))
    try await backend.legacy(
        plan: first,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try await backend.legacy(
        plan: second,
        activeSlotIndex: 0,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    let store = DJProgramStore(archive: archive, client: backend.client)
    try await store.restoreLatest()

    #expect(store.recentPrograms.map(\.plan.brief.id) == [
        "second", "first",
    ])
    #expect(store.plan?.brief.id == "second")
}

@MainActor
@Test
func programArchiveKeepsRecentProgramsAndUpdatesTheSameProgram() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let archive = DJProgramArchive(storage: backend.storage)
    let first = try await backend.seed(programPlan(trackIDs: ["one"]))
    let second = try await backend.seed(programPlan(
        id: "second",
        trackIDs: ["two"]
    ))
    let third = try await backend.seed(programPlan(
        id: "third",
        trackIDs: ["three"]
    ))

    try await backend.legacy(
        plan: first,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try await backend.legacy(
        plan: second,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    try await backend.legacy(
        plan: first,
        activeSlotIndex: 0,
        updatedAt: Date(timeIntervalSince1970: 3_000)
    )
    try await backend.legacy(
        plan: third,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 4_000)
    )

    let recent = try await archive.recent()
    #expect(recent.map(\.plan.brief.id) == ["third", "test", "second"])
    #expect(recent.filter { $0.plan.brief.id == "test" }.count == 1)
    #expect(recent[1].activeSlotIndex == 0)
}

private func programPlan(
    id: String = "test",
    trackIDs: [String]
) -> ProgramPlan {
    let tracks = trackIDs.map { id in
        MusicCandidate(
            id: id,
            canonicalID: nil,
            providerID: .netease,
            source: .streaming,
            title: "Track \(id)",
            artist: "Artist \(id)",
            album: nil,
            duration: 240,
            isPlayable: true,
            matchScore: 1,
            userAffinity: 1,
            energy: 0.5,
            moodTags: [],
            genres: [],
            releaseYear: nil
        )
    }
    let slots = tracks.enumerated().map { index, track in
        ProgramSlot(
            track: track,
            role: index == 0 ? .opener : .closer,
            hostHint: ProgramHostHint(
                shouldTalkBefore: index == 0,
                maxSentenceCount: 1,
                selectionReason: "测试",
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
    return ProgramPlan(
        brief: ProgramBrief(
            id: id,
            targetDuration: 1_800,
            moodTags: [],
            energyArc: [],
            conversationMode: .ambient
        ),
        slots: slots,
        revision: 1,
        generatedAt: Date(timeIntervalSince1970: 1_000),
        replanAfterTrackCount: 2
    )
}



@MainActor
@Test
func programStoragePersistsPendingWithoutSelectingItOnRelaunch() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let archive = DJProgramArchive(storage: backend.storage)
    let original = DJProgramStore(archive: archive, client: backend.client)
    let active = try await backend.seed(programPlan(id: "active", trackIDs: ["one"]))
    let pending = try await backend.seed(programPlan(id: "pending", trackIDs: ["two"]))
    try await original.publish(active)
    try await original.publishDraft(pending)
    try await original.flush()
    let reopened = DJProgramStore(archive: archive, client: backend.client)
    try await reopened.restoreLatest()
    #expect(reopened.plan == active)
    #expect(reopened.pendingPlan == pending)
    #expect(reopened.activeSlotIndex == nil)
}

@MainActor
@Test
func programStorageReadCanRecoverAfterVisibleSaveFailure() async throws {
    let backend = try await PrivateMusicAuthorityFixture.start()
    let store = DJProgramStore(archive: DJProgramArchive(storage: backend.storage), client: backend.client)
    let unsaved = try await backend.seed(programPlan(id: "unsaved", trackIDs: ["one"]))
    backend.rejected = true
    do { try await store.publish(unsaved); Issue.record("Unavailable save cannot succeed") } catch { }
    if case .failed = store.status { } else { Issue.record("Save failure must be visible") }
    backend.rejected = false
    try await store.refreshRecentPrograms()
    #expect(store.recentPrograms.isEmpty)
}
