import Foundation

final class AudioAnalyzer: @unchecked Sendable {
    let sampleRate: Float
    let frameSize: Int

    private let window: [Float]
    private let bitReversedIndices: [Int]
    private let bandRanges: [Range<Int>]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var previousRMS: Float = 0

    init(sampleRate: Float, frameSize: Int) {
        precondition(sampleRate > 0)
        precondition(frameSize > 1 && frameSize.nonzeroBitCount == 1)

        self.sampleRate = sampleRate
        self.frameSize = frameSize
        window = (0 ..< frameSize).map { index in
            0.5 - 0.5 * cos(
                2 * Float.pi * Float(index) / Float(frameSize - 1)
            )
        }

        let bitCount = frameSize.trailingZeroBitCount
        bitReversedIndices = (0 ..< frameSize).map { index in
            var value = index
            var reversed = 0
            for _ in 0 ..< bitCount {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            return reversed
        }

        let nyquist = sampleRate * 0.5
        let minimumFrequency: Float = 60
        let maximumFrequency = min(16_000, nyquist * 0.96)
        let ratio = pow(maximumFrequency / minimumFrequency, 1 / 32)
        bandRanges = (0 ..< 32).map { index in
            let lowerFrequency = minimumFrequency * pow(ratio, Float(index))
            let upperFrequency = minimumFrequency * pow(ratio, Float(index + 1))
            let lowerBin = max(
                Int(floor(lowerFrequency * Float(frameSize) / sampleRate)),
                1
            )
            let upperBin = min(
                max(
                    Int(ceil(upperFrequency * Float(frameSize) / sampleRate)),
                    lowerBin + 1
                ),
                frameSize / 2
            )
            return lowerBin ..< upperBin
        }

        real = .init(repeating: 0, count: frameSize)
        imaginary = .init(repeating: 0, count: frameSize)
        magnitudes = .init(repeating: 0, count: frameSize / 2 + 1)
    }

    func analyze(
        _ samples: [Float],
        hostTime: UInt64 = 0
    ) -> AudioFeatureFrame {
        samples.withUnsafeBufferPointer {
            analyze($0, hostTime: hostTime)
        }
    }

    func analyze(
        _ samples: UnsafeBufferPointer<Float>,
        hostTime: UInt64 = 0
    ) -> AudioFeatureFrame {
        var squaredSum: Float = 0
        var peak: Float = 0

        for index in 0 ..< frameSize {
            let sample = index < samples.count ? samples[index] : 0
            squaredSum += sample * sample
            peak = max(peak, abs(sample))

            let destination = bitReversedIndices[index]
            real[destination] = sample * window[index]
            imaginary[destination] = 0
        }

        performFFT()

        var totalMagnitude: Float = 0
        var weightedFrequency: Float = 0
        var dominantBin = 1

        for bin in 0 ... frameSize / 2 {
            let magnitude = hypot(real[bin], imaginary[bin])
            magnitudes[bin] = magnitude

            guard bin > 0 else {
                continue
            }
            let frequency = Float(bin) * sampleRate / Float(frameSize)
            totalMagnitude += magnitude
            weightedFrequency += magnitude * frequency
            if magnitude > magnitudes[dominantBin] {
                dominantBin = bin
            }
        }

        var bands = SIMD32<Float>(repeating: 0)
        for index in 0 ..< 32 {
            let range = bandRanges[index]
            var maximum: Float = 0
            for bin in range {
                maximum = max(maximum, magnitudes[bin])
            }
            bands[index] = maximum / Float(frameSize)
        }

        let rms = sqrt(squaredSum / Float(frameSize))
        let onset = min(max((rms - previousRMS) * 4, 0), 1)
        previousRMS = rms

        let lowMagnitude = (1 ..< min(
            Int(220 * Float(frameSize) / sampleRate) + 1,
            magnitudes.count
        )).reduce(Float.zero) { $0 + magnitudes[$1] }
        let lowImpact = totalMagnitude > 0
            ? min(max(lowMagnitude / totalMagnitude * 4, 0), 1)
            : 0

        return AudioFeatureFrame(
            rms: rms,
            peak: peak,
            bands: bands,
            spectralCentroid: totalMagnitude > 0
                ? weightedFrequency / totalMagnitude
                : 0,
            lowFrequencyImpact: lowImpact,
            onset: onset,
            beatPulse: min(max(lowImpact * 0.65 + onset * 0.75, 0), 1),
            dominantFrequency: interpolatedFrequency(around: dominantBin),
            hostTime: hostTime
        )
    }

    private func performFFT() {
        var length = 2
        while length <= frameSize {
            let angle = -2 * Float.pi / Float(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)

            for start in stride(from: 0, to: frameSize, by: length) {
                var twiddleReal: Float = 1
                var twiddleImaginary: Float = 0
                let halfLength = length / 2

                for offset in 0 ..< halfLength {
                    let even = start + offset
                    let odd = even + halfLength
                    let oddReal = real[odd] * twiddleReal
                        - imaginary[odd] * twiddleImaginary
                    let oddImaginary = real[odd] * twiddleImaginary
                        + imaginary[odd] * twiddleReal
                    let evenReal = real[even]
                    let evenImaginary = imaginary[even]

                    real[even] = evenReal + oddReal
                    imaginary[even] = evenImaginary + oddImaginary
                    real[odd] = evenReal - oddReal
                    imaginary[odd] = evenImaginary - oddImaginary

                    let nextReal = twiddleReal * stepReal
                        - twiddleImaginary * stepImaginary
                    twiddleImaginary = twiddleReal * stepImaginary
                        + twiddleImaginary * stepReal
                    twiddleReal = nextReal
                }
            }
            length <<= 1
        }
    }

    private func interpolatedFrequency(around bin: Int) -> Float {
        guard bin > 0, bin < magnitudes.count - 1 else {
            return Float(bin) * sampleRate / Float(frameSize)
        }

        let left = magnitudes[bin - 1]
        let center = magnitudes[bin]
        let right = magnitudes[bin + 1]
        let denominator = left - 2 * center + right
        let offset = abs(denominator) > 0.000_001
            ? 0.5 * (left - right) / denominator
            : 0
        return (Float(bin) + min(max(offset, -0.5), 0.5))
            * sampleRate / Float(frameSize)
    }
}
