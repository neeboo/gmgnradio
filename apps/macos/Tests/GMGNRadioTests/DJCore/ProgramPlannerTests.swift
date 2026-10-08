import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func programPlannerBuildsPlayableRollingProgramWithArtistSpacing() async throws {
    let candidates = [
        candidate(id: "a1", title: "A One", artist: "Artist A", energy: 0.30),
        candidate(id: "a2", title: "A Two", artist: "Artist A", energy: 0.45),
        candidate(id: "b1", title: "B One", artist: "Artist B", energy: 0.38),
        candidate(id: "c1", title: "C One", artist: "Artist C", energy: 0.50),
        candidate(id: "d1", title: "D One", artist: "Artist D", energy: 0.62),
        candidate(id: "e1", title: "E One", artist: "Artist E", energy: 0.55),
        candidate(
            id: "broken",
            title: "Broken",
            artist: "Artist F",
            energy: 0.5,
            isPlayable: false
        )
    ]
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let planner = ProgramPlanner(client: fixture.client)

    let plan = try await planner.makePlan(
        brief: ProgramBrief(
            id: "late-night",
            targetDuration: 24 * 60,
            moodTags: ["calm", "warm"],
            energyArc: [0.3, 0.4, 0.55, 0.65, 0.5],
            conversationMode: .ambient
        ),
        candidates: candidates
    )

    #expect((5 ... 8).contains(plan.slots.count))
    #expect(plan.replanAfterTrackCount == 2)
    #expect(plan.slots.allSatisfy { $0.track.isPlayable })
    #expect(!plan.slots.map(\.track.id).contains("broken"))

    for index in plan.slots.indices.dropFirst() {
        #expect(
            plan.slots[index].track.artist
                != plan.slots[index - 1].track.artist
        )
    }
}

@Test
@MainActor
func quietInstructionReducesHostTalkWithoutRemovingTrackHints() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let planner = ProgramPlanner(client: fixture.client)
    let plan = try await planner.makePlan(
        brief: ProgramBrief(
            id: "focus",
            targetDuration: 20 * 60,
            moodTags: ["focus"],
            energyArc: [0.35, 0.45, 0.55],
            conversationMode: .quiet,
            immediateUserInstruction: "少说点"
        ),
        candidates: [
            candidate(id: "1", title: "One", artist: "A", energy: 0.35),
            candidate(id: "2", title: "Two", artist: "B", energy: 0.4),
            candidate(id: "3", title: "Three", artist: "C", energy: 0.5),
            candidate(id: "4", title: "Four", artist: "D", energy: 0.55),
            candidate(id: "5", title: "Five", artist: "E", energy: 0.45)
        ]
    )

    #expect(plan.slots.filter(\.hostHint.shouldTalkBefore).count <= 1)
    #expect(plan.slots.allSatisfy { !$0.hostHint.selectionReason.isEmpty })
    #expect(plan.slots.dropLast().allSatisfy {
        $0.hostHint.nextTrack?.id != nil
    })
}

@Test
@MainActor
func programPlannerExcludesBlockedAndRecentlySkippedTracks() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    let planner = ProgramPlanner(client: fixture.client)
    let plan = try await planner.makePlan(
        brief: ProgramBrief(
            id: "recovery",
            targetDuration: 20 * 60,
            moodTags: ["warm"],
            energyArc: [0.4, 0.5],
            conversationMode: .ambient,
            blockedTrackIDs: ["blocked"],
            recentlySkippedTrackIDs: ["skipped"]
        ),
        candidates: [
            candidate(id: "blocked", title: "Blocked", artist: "A"),
            candidate(id: "skipped", title: "Skipped", artist: "B"),
            candidate(id: "1", title: "One", artist: "C"),
            candidate(id: "2", title: "Two", artist: "D"),
            candidate(id: "3", title: "Three", artist: "E"),
            candidate(id: "4", title: "Four", artist: "F"),
            candidate(id: "5", title: "Five", artist: "G")
        ]
    )

    let ids = plan.slots.map(\.track.id)
    #expect(!ids.contains("blocked"))
    #expect(!ids.contains("skipped"))
}

func candidate(
    id: String,
    canonicalID: String? = nil,
    title: String,
    artist: String = "Example Artist",
    providerID: MusicProviderID = .local,
    source: MusicSourceKind = .localLibrary,
    duration: TimeInterval = 240,
    energy: Double = 0.5,
    isPlayable: Bool = true,
    matchScore: Double = 0.8
) -> MusicCandidate {
    MusicCandidate(
        id: id,
        canonicalID: canonicalID,
        providerID: providerID,
        source: source,
        title: title,
        artist: artist,
        album: nil,
        duration: duration,
        isPlayable: isPlayable,
        matchScore: matchScore,
        userAffinity: 0.5,
        energy: energy,
        moodTags: ["calm", "warm"],
        genres: ["electronic"],
        releaseYear: 2024
    )
}
