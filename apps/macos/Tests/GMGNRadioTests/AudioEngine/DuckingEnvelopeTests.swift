import Testing
@testable import GMGNRadio

@Test
func duckingEnvelopeUsesFastAttackAndSlowerRelease() {
    var envelope = DuckingEnvelope(
        sampleRate: 48_000,
        attackDuration: 0.15,
        releaseDelay: 0.12,
        releaseDuration: 0.45,
        duckGain: 0.3
    )

    envelope.setDJSpeaking(true)
    let attackedGain = envelope.advance(frameCount: 7_200)
    #expect(abs(attackedGain - 0.3) < 0.001)
    #expect(abs(envelope.advance(frameCount: 48_000) - 0.3) < 0.001)

    envelope.setDJSpeaking(false)
    let heldGain = envelope.advance(frameCount: 4_800)
    #expect(abs(heldGain - 0.3) < 0.001)

    _ = envelope.advance(frameCount: 960)
    let releasedGain = envelope.advance(frameCount: 21_600)
    #expect(abs(releasedGain - 1) < 0.001)
}

@Test
func shortDJPausesDoNotPumpTheMusicVolume() {
    var envelope = DuckingEnvelope(
        sampleRate: 48_000,
        attackDuration: 0.15,
        releaseDelay: 0.14,
        releaseDuration: 0.45,
        duckGain: 0.3
    )

    envelope.setDJSpeaking(true)
    _ = envelope.advance(frameCount: 7_200)
    envelope.setDJSpeaking(false)
    _ = envelope.advance(frameCount: 4_800)
    envelope.setDJSpeaking(true)

    #expect(abs(envelope.advance(frameCount: 2_400) - 0.3) < 0.001)
}
