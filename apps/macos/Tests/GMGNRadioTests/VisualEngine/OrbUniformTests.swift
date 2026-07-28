import Testing
@testable import GMGNRadio

@Test(arguments: [
    (DJState.idle, Float(0.18)),
    (DJState.listening, Float(0.72)),
    (DJState.speaking, Float(0.90))
])
func energyMatchesState(state: DJState, expected: Float) {
    #expect(OrbUniforms.forState(state).energy == expected)
}

@Test
func idleRenderingUsesLowFrameRate() {
    #expect(OrbUniforms.preferredFramesPerSecond(for: .idle, screenMaximumFPS: 120) == 15)
    #expect(OrbUniforms.preferredFramesPerSecond(for: .dormant, screenMaximumFPS: 120) == 15)
}

@Test
func activeRenderingUsesDisplayCapability() {
    #expect(
        OrbUniforms.preferredFramesPerSecond(for: .speaking, screenMaximumFPS: 120) == 120
    )
    #expect(
        OrbUniforms.preferredFramesPerSecond(for: .listening, screenMaximumFPS: 60) == 60
    )
}

@Test
func privacyStateRemovesVisibleEnergy() {
    let uniforms = OrbUniforms.forState(.privacyOff)

    #expect(uniforms.energy <= 0.05)
    #expect(uniforms.opacity <= 0.35)
}
