import Foundation

struct AudioFeatureFrame: Equatable, Sendable {
    var rms: Float
    var peak: Float
    var bands: SIMD32<Float>
    var spectralCentroid: Float
    var lowFrequencyImpact: Float
    var onset: Float
    var beatPulse: Float
    var dominantFrequency: Float
    var hostTime: UInt64

    var visualFeatures: VisualAudioFeatures {
        let bass = maximum(in: 0 ..< 7)
        let lowMid = maximum(in: 7 ..< 12)
        let sceneMid = maximum(in: 12 ..< 19)
        let vocal = maximum(in: 19 ..< 25)
        let treble = maximum(in: 25 ..< 32)
        let strongest = max(
            bass,
            lowMid,
            sceneMid,
            vocal,
            treble,
            0.000_001
        )
        let amplitude = min(max(sqrt(rms) * 1.35, 0), 1)
        let normalizedBass = normalized(bass, strongest: strongest, amplitude: amplitude)
        let normalizedLowMid = normalized(lowMid, strongest: strongest, amplitude: amplitude)
        let normalizedMid = normalized(sceneMid, strongest: strongest, amplitude: amplitude)
        let normalizedVocal = normalized(vocal, strongest: strongest, amplitude: amplitude)
        let normalizedTreble = normalized(treble, strongest: strongest, amplitude: amplitude)

        return VisualAudioFeatures(
            low: max(normalizedBass, normalizedLowMid),
            mid: legacyMid(
                sceneMid: normalizedMid,
                vocal: normalizedVocal,
                treble: normalizedTreble
            ),
            high: normalizedTreble,
            bass: normalizedBass,
            lowMid: normalizedLowMid,
            sceneMid: normalizedMid,
            vocal: normalizedVocal,
            treble: normalizedTreble,
            beat: min(max(beatPulse, 0), 1),
            onset: min(max(onset, 0), 1),
            amplitude: amplitude,
            spectrum: spectrumEnvelope(strongest: strongest, amplitude: amplitude)
        )
    }

    private func normalized(
        _ value: Float,
        strongest: Float,
        amplitude: Float
    ) -> Float {
        min(max(value / strongest * amplitude, 0), 1)
    }

    private func legacyMid(
        sceneMid: Float,
        vocal: Float,
        treble: Float
    ) -> Float {
        let value = max(sceneMid, vocal * 0.72)
        return treble > value * 2 ? value * 0.72 : value
    }

    private func spectrumEnvelope(
        strongest: Float,
        amplitude: Float
    ) -> SIMD8<Float> {
        var result = SIMD8<Float>(repeating: 0)
        for bucket in 0 ..< 8 {
            let start = bucket * 32 / 8
            let end = (bucket + 1) * 32 / 8
            result[bucket] = normalized(
                maximum(in: start ..< end),
                strongest: strongest,
                amplitude: amplitude
            )
        }
        return result
    }

    private func maximum(in range: Range<Int>) -> Float {
        range.reduce(Float.zero) { result, index in
            max(result, bands[index])
        }
    }
}

enum WaveformEnvelopeSampler {
    static func sample(
        _ samples: UnsafeBufferPointer<Float>
    ) -> SIMD8<Float> {
        guard !samples.isEmpty else {
            return .zero
        }

        var envelope = SIMD8<Float>(repeating: 0)
        var strongest: Float = 0

        for bucket in 0 ..< 8 {
            let start = bucket * samples.count / 8
            let end = max((bucket + 1) * samples.count / 8, start + 1)
            var peak: Float = 0
            for index in start ..< min(end, samples.count) {
                peak = max(peak, abs(samples[index]))
            }
            envelope[bucket] = peak
            strongest = max(strongest, peak)
        }

        guard strongest > 0.000_001 else {
            return .zero
        }
        return envelope / SIMD8<Float>(repeating: strongest)
    }
}
