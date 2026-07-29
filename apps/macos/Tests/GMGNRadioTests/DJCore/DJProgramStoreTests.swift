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

private func programPlan(trackIDs: [String]) -> ProgramPlan {
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
            id: "test",
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
