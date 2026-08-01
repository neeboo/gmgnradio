import AVFoundation
import Testing
@testable import GMGNRadio

@Test
func audioExtractorSeparatesLowMidAndHighBands() throws {
    let extractor = VisualAudioFeatureExtractor()

    let low = extractor.extract(from: try makeSineBuffer(frequency: 120))
    let mid = extractor.extract(from: try makeSineBuffer(frequency: 1_000))
    let high = extractor.extract(from: try makeSineBuffer(frequency: 6_000))

    #expect(low.low > low.mid * 3)
    #expect(low.low > low.high * 3)
    #expect(mid.mid > mid.low * 3)
    #expect(mid.mid > mid.high * 3)
    #expect(high.high > high.low * 3)
    #expect(high.high > high.mid * 3)
}

@Test
func foliaAudioBridgeExposesFiveSceneBands() throws {
    let extractor = VisualAudioFeatureExtractor()

    let bass = extractor.extract(from: try makeSineBuffer(frequency: 120))
    let lowMid = extractor.extract(from: try makeSineBuffer(frequency: 250))
    let mid = extractor.extract(from: try makeSineBuffer(frequency: 800))
    let vocal = extractor.extract(from: try makeSineBuffer(frequency: 2_400))
    let treble = extractor.extract(from: try makeSineBuffer(frequency: 7_000))

    #expect(bass.bass > bass.lowMid * 2)
    #expect(lowMid.lowMid > lowMid.bass * 2)
    #expect(mid.sceneMid > mid.vocal * 2)
    #expect(vocal.vocal > vocal.sceneMid * 2)
    #expect(treble.treble > treble.vocal * 2)
    #expect(bass.amplitude > 0)
}

@Test
@MainActor
func audioDeliveryGateRejectsUpdatesFromAClosedGeneration() {
    let store = VisualAudioFeatureStore()
    let gate = VisualAudioFeatureDeliveryGate(store: store)
    let generation = gate.begin()

    gate.deliver(
        VisualAudioFeatures(low: 0.8, mid: 0.4, high: 0.2),
        generation: generation
    )
    #expect(store.current.low == 0.8)

    gate.end()
    gate.deliver(
        VisualAudioFeatures(low: 1, mid: 1, high: 1),
        generation: generation
    )

    #expect(store.current == .silent)
}

private func makeSineBuffer(
    frequency: Float,
    sampleRate: Double = 48_000,
    frameCount: AVAudioFrameCount = 2_048
) throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )
    )
    buffer.frameLength = frameCount

    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0 ..< Int(frameCount) {
        let phase = 2 * Float.pi * frequency * Float(index) / Float(sampleRate)
        samples[index] = sin(phase) * 0.8
    }
    return buffer
}
