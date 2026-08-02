import Foundation
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

@Test
func orbAppearanceIsClampedAndRestoredLocally() {
    let suiteName = "orb-appearance-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var appearance = OrbAppearance.load(from: defaults)
    #expect(appearance == .default)

    appearance.red = 1.7
    appearance.green = -0.4
    appearance.blue = 0.48
    appearance.flowIntensity = 2.3
    appearance.save(to: defaults)

    let restored = OrbAppearance.load(from: defaults)
    #expect(restored.red == 1)
    #expect(restored.green == 0)
    #expect(restored.blue == 0.48)
    #expect(restored.flowIntensity == 1.5)
}

@Test
func orbShaderUsesCleanAnalyticFlowBands() throws {
    let macOSRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: macOSRoot.appendingPathComponent(
            "Sources/GMGNRadio/VisualEngine/Shaders/Orb.metal"
        ),
        encoding: .utf8
    )

    #expect(shader.contains("flowBand"))
    #expect(!shader.contains("orbNoise"))
}
