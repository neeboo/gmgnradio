import Foundation
import Testing
@testable import GMGNRadio

@Test
func audioAnalyzerFindsTheDominantFrequencyAndLevels() {
    let analyzer = AudioAnalyzer(sampleRate: 48_000, frameSize: 4_096)
    let samples = makeSineSamples(
        frequency: 440,
        sampleRate: 48_000,
        count: 4_096,
        amplitude: 0.8
    )

    let frame = analyzer.analyze(samples, hostTime: 42)

    #expect(abs(frame.dominantFrequency - 440) < 12)
    #expect(abs(frame.rms - 0.566) < 0.02)
    #expect(frame.peak > 0.79)
    #expect(frame.hostTime == 42)
}

@Test
func audioAnalyzerMapsLowMidAndHighEnergyForTheStage() {
    let lowAnalyzer = AudioAnalyzer(sampleRate: 48_000, frameSize: 4_096)
    let midAnalyzer = AudioAnalyzer(sampleRate: 48_000, frameSize: 4_096)
    let highAnalyzer = AudioAnalyzer(sampleRate: 48_000, frameSize: 4_096)

    let low = lowAnalyzer.analyze(
        makeSineSamples(frequency: 120, sampleRate: 48_000, count: 4_096)
    ).visualFeatures
    let mid = midAnalyzer.analyze(
        makeSineSamples(frequency: 1_000, sampleRate: 48_000, count: 4_096)
    ).visualFeatures
    let high = highAnalyzer.analyze(
        makeSineSamples(frequency: 7_000, sampleRate: 48_000, count: 4_096)
    ).visualFeatures

    #expect(low.low > low.mid)
    #expect(low.low > low.high)
    #expect(mid.mid > mid.low)
    #expect(mid.mid > mid.high)
    #expect(high.high > high.low)
    #expect(high.high > high.mid)
}

@Test
func visualFeaturesPreserveBeatOnsetAndAmplitude() {
    let frame = AudioFeatureFrame(
        rms: 0.25,
        peak: 0.8,
        bands: SIMD32<Float>(repeating: 0.2),
        spectralCentroid: 1_200,
        lowFrequencyImpact: 0.7,
        onset: 0.8,
        beatPulse: 0.9,
        dominantFrequency: 120,
        hostTime: 42
    )

    let features = frame.visualFeatures

    #expect(features.beat == 0.9)
    #expect(features.onset == 0.8)
    #expect(abs(features.amplitude - 0.675) < 0.001)
}

@Test
func waveformEnvelopeKeepsTheShapeOfTheCurrentAudioFrame() {
    var samples = [Float](repeating: 0, count: 80)
    for index in 30 ..< 40 {
        samples[index] = index.isMultiple(of: 2) ? 0.8 : -0.8
    }

    let waveform = samples.withUnsafeBufferPointer {
        WaveformEnvelopeSampler.sample($0)
    }

    #expect(waveform[3] > 0.99)
    #expect(waveform[0] == 0)
    #expect(waveform[7] == 0)
}

@Test
func beatPulseFiresOnTheLowFrequencyAttackAndFallsDuringASteadyTone() {
    let analyzer = AudioAnalyzer(sampleRate: 48_000, frameSize: 2_048)
    let silence = [Float](repeating: 0, count: 2_048)
    let kick = makeSineSamples(
        frequency: 90,
        sampleRate: 48_000,
        count: 2_048,
        amplitude: 0.9
    )

    _ = analyzer.analyze(silence)
    let attack = analyzer.analyze(kick)
    let sustained = analyzer.analyze(kick)

    #expect(attack.beatPulse > 0.7)
    #expect(sustained.beatPulse < 0.2)
}

private func makeSineSamples(
    frequency: Float,
    sampleRate: Float,
    count: Int,
    amplitude: Float = 0.8
) -> [Float] {
    (0 ..< count).map { index in
        let phase = 2 * Float.pi * frequency * Float(index) / sampleRate
        return sin(phase) * amplitude
    }
}
