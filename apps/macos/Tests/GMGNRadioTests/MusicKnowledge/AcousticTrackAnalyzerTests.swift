import AVFoundation
import Foundation
import Testing
@testable import GMGNRadio

@Test
func acousticAnalysisMeasuresLevelsAndNormalizedEnergy() {
    let sampleRate = 48_000.0
    let analyzer = AcousticTrackAnalyzer()
    let quiet = makeTone(
        frequency: 440,
        sampleRate: sampleRate,
        duration: 1,
        amplitude: 0.2
    )
    let loud = makeTone(
        frequency: 440,
        sampleRate: sampleRate,
        duration: 1,
        amplitude: 0.8
    )

    let quietFeatures = analyzer.analyze(
        samples: quiet,
        sampleRate: sampleRate
    )
    let loudFeatures = analyzer.analyze(
        samples: loud,
        sampleRate: sampleRate
    )

    #expect(abs(loudFeatures.rms - Float(0.8 / sqrt(2))) < 0.015)
    #expect(abs(loudFeatures.peak - 0.8) < 0.01)
    #expect(quietFeatures.energy < loudFeatures.energy)
    #expect((0 ... 1).contains(loudFeatures.energy))
}

@Test
func acousticAnalysisSeparatesLowMidAndHighFrequencyEnergy() {
    let sampleRate = 48_000.0
    let analyzer = AcousticTrackAnalyzer()

    let low = analyzer.analyze(
        samples: makeTone(
            frequency: 120,
            sampleRate: sampleRate,
            duration: 1
        ),
        sampleRate: sampleRate
    )
    let mid = analyzer.analyze(
        samples: makeTone(
            frequency: 1_000,
            sampleRate: sampleRate,
            duration: 1
        ),
        sampleRate: sampleRate
    )
    let high = analyzer.analyze(
        samples: makeTone(
            frequency: 8_000,
            sampleRate: sampleRate,
            duration: 1
        ),
        sampleRate: sampleRate
    )

    #expect(low.lowFrequencyRatio > 0.9)
    #expect(mid.midFrequencyRatio > 0.9)
    #expect(high.highFrequencyRatio > 0.9)
    #expect(
        abs(
            low.lowFrequencyRatio
                + low.midFrequencyRatio
                + low.highFrequencyRatio
                - 1
        ) < 0.001
    )
}

@Test
func acousticAnalysisEstimatesTempoFromRegularPercussivePulses() throws {
    let sampleRate = 48_000.0
    let analyzer = AcousticTrackAnalyzer()
    let samples = makePulseTrack(
        bpm: 120,
        sampleRate: sampleRate,
        duration: 12
    )

    let features = analyzer.analyze(
        samples: samples,
        sampleRate: sampleRate
    )
    let bpm = try #require(features.estimatedBPM)

    #expect(abs(bpm - 120) < 3)
    #expect(features.beatConfidence > 0.55)
}

@Test
func acousticAnalysisReadsLocalAudioFilesThroughTheSamePipeline() throws {
    let sampleRate = 48_000.0
    let samples = makeTone(
        frequency: 220,
        sampleRate: sampleRate,
        duration: 1,
        amplitude: 0.6
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-acoustic-\(UUID().uuidString).wav")
    defer {
        try? FileManager.default.removeItem(at: url)
    }
    try writeMonoWave(samples, sampleRate: sampleRate, to: url)

    let analyzer = AcousticTrackAnalyzer()
    let direct = analyzer.analyze(samples: samples, sampleRate: sampleRate)
    let fromFile = try analyzer.analyze(audioAt: url)

    #expect(abs(fromFile.rms - direct.rms) < 0.001)
    #expect(abs(fromFile.peak - direct.peak) < 0.001)
    #expect(abs(fromFile.lowFrequencyRatio - direct.lowFrequencyRatio) < 0.01)
    #expect(abs(fromFile.duration - 1) < 0.001)
}

private func makeTone(
    frequency: Double,
    sampleRate: Double,
    duration: Double,
    amplitude: Float = 0.8
) -> [Float] {
    let count = Int(sampleRate * duration)
    return (0 ..< count).map { index in
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        return sin(Float(phase)) * amplitude
    }
}

private func makePulseTrack(
    bpm: Double,
    sampleRate: Double,
    duration: Double
) -> [Float] {
    let sampleCount = Int(sampleRate * duration)
    let beatLength = Int(sampleRate * 60 / bpm)
    let pulseLength = Int(sampleRate * 0.045)
    var samples = [Float](repeating: 0, count: sampleCount)

    for beatStart in stride(from: 0, to: sampleCount, by: beatLength) {
        let end = min(beatStart + pulseLength, sampleCount)
        for index in beatStart ..< end {
            let offset = index - beatStart
            let envelope = exp(-6 * Float(offset) / Float(pulseLength))
            let phase = 2 * Float.pi * 90 * Float(index) / Float(sampleRate)
            samples[index] = sin(phase) * envelope
        }
    }
    return samples
}

private func writeMonoWave(
    _ samples: [Float],
    sampleRate: Double,
    to url: URL
) throws {
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
            frameCapacity: AVAudioFrameCount(samples.count)
        )
    )
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try #require(buffer.floatChannelData?[0])
    channel.update(from: samples, count: samples.count)

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
