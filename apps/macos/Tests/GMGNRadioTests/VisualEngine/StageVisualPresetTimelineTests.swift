import Testing
@testable import GMGNRadio

@Test
func visualPresetTimelineHoldsThenCrossfadesToTheNextPreset() {
    let timeline = StageVisualPresetTimeline(
        presetDuration: 20,
        transitionDuration: 4
    )

    let held = timeline.sample(at: 12)
    #expect(held.weights == SIMD3<Float>(1, 0, 0))

    let blending = timeline.sample(at: 17)
    #expect(blending.weights == SIMD3<Float>(0.75, 0.25, 0))

    let advanced = timeline.sample(at: 20)
    #expect(advanced.weights == SIMD3<Float>(0, 1, 0))
}

@Test
func visualPresetTimelineWrapsAcrossTheLastPreset() {
    let timeline = StageVisualPresetTimeline(
        presetDuration: 20,
        transitionDuration: 4
    )

    let blending = timeline.sample(at: 59)

    #expect(blending.weights == SIMD3<Float>(0.75, 0, 0.25))
    #expect(abs(blending.weights.x + blending.weights.y + blending.weights.z - 1) < 0.000_1)
}

@Test
func DJVisualMoodsMapToDistinctStagePresets() {
    #expect(
        StageVisualPresetFrame.forMood(.afterglow).weights
            == SIMD3<Float>(1, 0, 0)
    )
    #expect(
        StageVisualPresetFrame.forMood(.liquid).weights
            == SIMD3<Float>(0, 1, 0)
    )
    #expect(
        StageVisualPresetFrame.forMood(.pulse).weights
            == SIMD3<Float>(0, 0, 1)
    )
}

@Test
@MainActor
func stageVisualDirectionStoreAcceptsAndClearsDJDirection() {
    let store = StageVisualDirectionStore()

    store.update(.pulse)
    #expect(store.currentMood == .pulse)

    store.update(nil)
    #expect(store.currentMood == nil)
}

@Test
@MainActor
func stageVisualDirectionStoreKeepsTheActiveProgramCue() {
    let store = StageVisualDirectionStore()
    let cue = ProgramVisualDirector().cue(
        for: .peak,
        mood: .pulse,
        intensity: 0.72
    )

    store.update(cue)

    #expect(store.currentMood == .pulse)
    #expect(store.currentIntensity == 0.72)
    #expect(store.transitionDuration == 2)
}
