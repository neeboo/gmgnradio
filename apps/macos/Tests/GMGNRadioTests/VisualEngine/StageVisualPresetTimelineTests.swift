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
