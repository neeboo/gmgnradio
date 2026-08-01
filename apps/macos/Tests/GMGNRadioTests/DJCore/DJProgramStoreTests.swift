import Foundation
import Testing
@testable import GMGNRadio

@MainActor
@Test
func programStoreTracksPlanningPublishedAndFailedStates() {
    let store = DJProgramStore()
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

    store.publish(plan)
    #expect(store.status == .ready)
    #expect(store.plan == plan)

    store.fail("暂时排不了节目")
    #expect(store.status == .failed("暂时排不了节目"))
    #expect(store.plan == plan)
}

@MainActor
@Test
func programStoreExposesTheActiveSlotForPlaybackAndVisuals() {
    let store = DJProgramStore()
    let plan = programPlan(trackIDs: ["one", "two"])

    store.publish(plan)
    store.activateSlot(at: 1)

    #expect(store.activeSlotIndex == 1)
    #expect(store.activeSlot?.track.id == "two")
}

@MainActor
@Test
func programStorePublishesADraftWithoutReplacingTheActiveProgram() {
    let store = DJProgramStore()
    let current = programPlan(id: "current", trackIDs: ["one", "two"])
    let draft = programPlan(id: "city-pop", trackIDs: ["three", "four"])

    store.publish(current)
    store.activateSlot(at: 0)
    store.publishDraft(draft)

    #expect(store.plan == current)
    #expect(store.activeSlotIndex == 0)
    #expect(store.pendingPlan == draft)
    #expect(store.recentPrograms.first?.plan == draft)
    #expect(store.status == .ready)
}

@Test
func programEditorReplansOnlyTheUpcomingPart() {
    let current = programPlan(trackIDs: ["one", "two", "three"])
    let proposal = programPlan(
        id: "proposal",
        trackIDs: ["four", "five", "one"]
    )

    let revised = DJProgramEditor.revise(
        current: current,
        activeSlotIndex: 1,
        proposal: proposal,
        mode: .replanUpcoming
    )

    #expect(revised.brief.id == current.brief.id)
    #expect(revised.revision == current.revision + 1)
    #expect(revised.slots.map(\.track.id) == [
        "one", "two", "four", "five",
    ])
}

@Test
func programEditorInsertsOneSongAndKeepsTheExistingRun() {
    let current = programPlan(trackIDs: ["one", "two", "three"])
    let proposal = programPlan(
        id: "proposal",
        trackIDs: ["four", "five"]
    )

    let revised = DJProgramEditor.revise(
        current: current,
        activeSlotIndex: 1,
        proposal: proposal,
        mode: .insertNext
    )

    #expect(revised.slots.map(\.track.id) == [
        "one", "two", "four", "three",
    ])
}

@MainActor
@Test
func programArchivePersistsThePlanAndPlaybackPosition() throws {
    let location = temporaryProgramArchiveURL()
    defer {
        try? FileManager.default.removeItem(
            at: location.deletingLastPathComponent()
        )
    }
    let archive = DJProgramArchive(fileURL: location)
    let plan = programPlan(trackIDs: ["one", "two", "three"])

    try archive.save(
        plan: plan,
        activeSlotIndex: 1,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    let latest = try archive.latest()
    let restored = try #require(latest)
    #expect(restored.plan == plan)
    #expect(restored.activeSlotIndex == 1)
    #expect(restored.updatedAt == Date(timeIntervalSince1970: 2_000))
}

@MainActor
@Test
func programStoreRestoresTheLatestSavedProgramOnRelaunch() {
    let location = temporaryProgramArchiveURL()
    defer {
        try? FileManager.default.removeItem(
            at: location.deletingLastPathComponent()
        )
    }
    let archive = DJProgramArchive(fileURL: location)
    let original = DJProgramStore(archive: archive)
    let plan = programPlan(trackIDs: ["one", "two"])

    original.publish(plan)
    original.activateSlot(at: 1)

    let relaunched = DJProgramStore(archive: archive)
    relaunched.restoreLatest()

    #expect(relaunched.status == .ready)
    #expect(relaunched.plan == plan)
    #expect(relaunched.activeSlotIndex == 1)
    #expect(relaunched.activeSlot?.track.id == "two")
}

@MainActor
@Test
func programStoreExposesRecentProgramsForTheStageLibrary() throws {
    let location = temporaryProgramArchiveURL()
    defer {
        try? FileManager.default.removeItem(
            at: location.deletingLastPathComponent()
        )
    }
    let archive = DJProgramArchive(fileURL: location)
    let first = programPlan(id: "first", trackIDs: ["one"])
    let second = programPlan(id: "second", trackIDs: ["two"])
    try archive.save(
        plan: first,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try archive.save(
        plan: second,
        activeSlotIndex: 0,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    let store = DJProgramStore(archive: archive)
    store.restoreLatest()

    #expect(store.recentPrograms.map(\.plan.brief.id) == [
        "second", "first",
    ])
    #expect(store.plan?.brief.id == "second")
}

@MainActor
@Test
func programArchiveKeepsRecentProgramsAndUpdatesTheSameProgram() throws {
    let location = temporaryProgramArchiveURL()
    defer {
        try? FileManager.default.removeItem(
            at: location.deletingLastPathComponent()
        )
    }
    let archive = DJProgramArchive(fileURL: location, capacity: 2)
    let first = programPlan(trackIDs: ["one"])
    let second = programPlan(
        id: "second",
        trackIDs: ["two"]
    )
    let third = programPlan(
        id: "third",
        trackIDs: ["three"]
    )

    try archive.save(
        plan: first,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try archive.save(
        plan: second,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    try archive.save(
        plan: first,
        activeSlotIndex: 0,
        updatedAt: Date(timeIntervalSince1970: 3_000)
    )
    try archive.save(
        plan: third,
        activeSlotIndex: nil,
        updatedAt: Date(timeIntervalSince1970: 4_000)
    )

    let recent = try archive.recent()
    #expect(recent.map(\.plan.brief.id) == ["third", "test"])
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

private func temporaryProgramArchiveURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "gmgn-radio-program-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        .appendingPathComponent("programs.json")
}
