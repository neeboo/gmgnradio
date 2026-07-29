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
