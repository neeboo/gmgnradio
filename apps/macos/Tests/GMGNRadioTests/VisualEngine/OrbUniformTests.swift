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
@MainActor
func orbAppearanceIsClampedAndRestoredLocally() async throws {
    let suiteName = "orb-appearance-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings=RustProductSettingsClient(call: { method,_ in
        var values:[String:Any]=["locale":"zh-CN","residentPersona":"fixture","backgroundTurnsPerHour":6,"autoSpeak":true,"autonomyEnabled":true,"agentBackend":"codex","selectedWorldID":NSNull(),"defaultSpace":"living-pod","djHostPrompt":"","djTakeover":true,"djPlanningModel":NSNull(),"ttsProvider":"bailian","ttsModel":"fixture","ttsVoice":"Cherry","asrProvider":"bailian","asrModel":"fixture","microphoneDeviceID":NSNull(),"orbRed":0.16,"orbGreen":0.62,"orbBlue":1.0,"orbFlowIntensity":0.82,"remoteMotionCatalogURL":"https://192.168.1.85:8765/catalog.json"]
        if method=="product_settings_apply" {values["orbRed"]=1;values["orbGreen"]=0;values["orbBlue"]=0.48;values["orbFlowIntensity"]=1.5}
        return try JSONSerialization.data(withJSONObject:["revision":method=="product_settings_apply" ? 2:1,"imported":true,"values":values])
    })
    var appearance = OrbAppearance.load(from: defaults,settings:settings)
    #expect(appearance == .default)

    appearance.red = 1.7
    appearance.green = -0.4
    appearance.blue = 0.48
    appearance.flowIntensity = 2.3
    _ = try await appearance.save(to: defaults,settings:settings)

    let restored = OrbAppearance.load(from: defaults,settings:settings)
    #expect(restored.red == 1)
    #expect(restored.green == 0)
    #expect(restored.blue == 0.48)
    #expect(restored.flowIntensity == 1.5)
    #expect(defaults.object(forKey:"orb.appearance.red")==nil)
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
