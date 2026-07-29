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
