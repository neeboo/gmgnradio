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
        let low = maximum(in: 0 ..< 10)
        let mid = maximum(in: 10 ..< 23)
        let high = maximum(in: 23 ..< 32)
        let strongest = max(low, mid, high, 0.000_001)
        let amplitude = min(max(sqrt(rms) * 1.35, 0), 1)

        return VisualAudioFeatures(
            low: min(max(low / strongest * amplitude, 0), 1),
            mid: min(max(mid / strongest * amplitude, 0), 1),
            high: min(max(high / strongest * amplitude, 0), 1)
        )
    }

    private func maximum(in range: Range<Int>) -> Float {
        range.reduce(Float.zero) { result, index in
            max(result, bands[index])
        }
    }
}
