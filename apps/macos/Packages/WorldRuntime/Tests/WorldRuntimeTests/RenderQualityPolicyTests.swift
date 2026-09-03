import Testing
@testable import WorldRuntime

@Test("Occlusion pauses rendering")
func occlusionPausesRendering() {
    var policy = RenderQualityPolicy()

    let decision = policy.update(
        deltaTime: 1,
        input: .init(isOccluded: true)
    )

    #expect(decision.shouldRender == false)
    #expect(decision.targetFramesPerSecond == 0)
}

@Test("Thermal and power pressure lower frame rate immediately")
func pressureLowersFrameRateImmediately() {
    var policy = RenderQualityPolicy()

    let normal = policy.update(deltaTime: 0, input: .init())
    let elevated = policy.update(
        deltaTime: 0,
        input: .init(thermalPressure: .elevated)
    )
    let critical = policy.update(
        deltaTime: 0,
        input: .init(powerPressure: .critical)
    )

    #expect(normal.targetFramesPerSecond == 60)
    #expect(normal.renderScale == 1)
    #expect(elevated.targetFramesPerSecond == 30)
    #expect(elevated.renderScale == 0.75)
    #expect(critical.targetFramesPerSecond == 15)
    #expect(critical.renderScale == 0.5)
}

@Test("Quality recovery waits for hysteresis and rises one tier at a time")
func qualityRecoveryUsesHysteresis() {
    var policy = RenderQualityPolicy(
        configuration: .init(recoveryDelay: 5)
    )
    _ = policy.update(
        deltaTime: 0,
        input: .init(thermalPressure: .critical)
    )

    let tooSoon = policy.update(deltaTime: 4.9, input: .init())
    let firstRecovery = policy.update(deltaTime: 0.1, input: .init())
    let stillBalanced = policy.update(deltaTime: 4.9, input: .init())
    let fullyRecovered = policy.update(deltaTime: 0.1, input: .init())

    #expect(tooSoon.targetFramesPerSecond == 15)
    #expect(firstRecovery.targetFramesPerSecond == 30)
    #expect(stillBalanced.targetFramesPerSecond == 30)
    #expect(fullyRecovered.targetFramesPerSecond == 60)
}

@Test("Occluded time does not count toward quality recovery")
func occludedTimeDoesNotAdvanceRecovery() {
    var policy = RenderQualityPolicy(
        configuration: .init(recoveryDelay: 5)
    )
    _ = policy.update(
        deltaTime: 0,
        input: .init(powerPressure: .critical)
    )
    _ = policy.update(
        deltaTime: 20,
        input: .init(isOccluded: true)
    )

    let visibleAgain = policy.update(deltaTime: 0, input: .init())

    #expect(visibleAgain.targetFramesPerSecond == 15)
}
