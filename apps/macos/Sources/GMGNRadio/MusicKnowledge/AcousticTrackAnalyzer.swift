import AVFoundation
import Foundation

struct AcousticTrackFeatures: Codable, Equatable, Sendable {
    let duration: TimeInterval
    let rms: Float
    let peak: Float
    let lowFrequencyRatio: Float
    let midFrequencyRatio: Float
    let highFrequencyRatio: Float
    let energy: Float
    let estimatedBPM: Float?
    let beatConfidence: Float
}

struct AcousticTrackAnalyzer: Sendable {
    private let spectrumFrameSize = 4_096
    private let maximumSpectrumFrames = 96
    private let tempoFrameSize = 1_024
    private let tempoHopSize = 512

    func analyze(
        samples: [Float],
        sampleRate: Double
    ) -> AcousticTrackFeatures {
        guard !samples.isEmpty, sampleRate > 0 else {
            return AcousticTrackFeatures(
                duration: 0,
                rms: 0,
                peak: 0,
                lowFrequencyRatio: 0,
                midFrequencyRatio: 0,
                highFrequencyRatio: 0,
                energy: 0,
                estimatedBPM: nil,
                beatConfidence: 0
            )
        }

        let levels = measureLevels(samples)
        let bands = measureFrequencyBands(samples, sampleRate: sampleRate)
        let tempo = estimateTempo(samples, sampleRate: sampleRate)

        return AcousticTrackFeatures(
            duration: Double(samples.count) / sampleRate,
            rms: levels.rms,
            peak: levels.peak,
            lowFrequencyRatio: bands.low,
            midFrequencyRatio: bands.mid,
            highFrequencyRatio: bands.high,
            energy: min(max(levels.rms * Float(2).squareRoot(), 0), 1),
            estimatedBPM: tempo.bpm,
            beatConfidence: tempo.confidence
        )
    }

    func analyze(audioAt url: URL) throws -> AcousticTrackFeatures {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ).unwrapped(or: AcousticTrackAnalyzerError.cannotCreateAudioBuffer)

        try file.read(into: buffer)
        let samples = try downmixedSamples(from: buffer)
        return analyze(samples: samples, sampleRate: format.sampleRate)
    }

    private func measureLevels(_ samples: [Float]) -> (rms: Float, peak: Float) {
        var squaredSum: Double = 0
        var peak: Float = 0
        for sample in samples {
            squaredSum += Double(sample * sample)
            peak = max(peak, abs(sample))
        }
        return (
            Float(sqrt(squaredSum / Double(samples.count))),
            peak
        )
    }

    private func measureFrequencyBands(
        _ samples: [Float],
        sampleRate: Double
    ) -> (low: Float, mid: Float, high: Float) {
        let availableStarts = max(samples.count - spectrumFrameSize + 1, 1)
        let frameCount = min(
            maximumSpectrumFrames,
            max(1, Int(ceil(Double(samples.count) / Double(spectrumFrameSize))))
        )
        let starts: [Int] = (0 ..< frameCount).map { index in
            guard frameCount > 1 else {
                return 0
            }
            return index * (availableStarts - 1) / (frameCount - 1)
        }

        let window = hannWindow(count: spectrumFrameSize)
        var bandPower = (low: Double.zero, mid: Double.zero, high: Double.zero)

        for start in starts {
            var real = [Float](repeating: 0, count: spectrumFrameSize)
            var imaginary = [Float](repeating: 0, count: spectrumFrameSize)
            for offset in 0 ..< spectrumFrameSize {
                let sourceIndex = start + offset
                if sourceIndex < samples.count {
                    real[offset] = samples[sourceIndex] * window[offset]
                }
            }

            fft(real: &real, imaginary: &imaginary)

            for bin in 1 ... spectrumFrameSize / 2 {
                let frequency = Double(bin) * sampleRate
                    / Double(spectrumFrameSize)
                let power = Double(real[bin] * real[bin])
                    + Double(imaginary[bin] * imaginary[bin])
                switch frequency {
                case ..<250:
                    bandPower.low += power
                case ..<4_000:
                    bandPower.mid += power
                default:
                    bandPower.high += power
                }
            }
        }

        let total = bandPower.low + bandPower.mid + bandPower.high
        guard total > 0 else {
            return (0, 0, 0)
        }
        return (
            Float(bandPower.low / total),
            Float(bandPower.mid / total),
            Float(bandPower.high / total)
        )
    }

    private func estimateTempo(
        _ samples: [Float],
        sampleRate: Double
    ) -> (bpm: Float?, confidence: Float) {
        guard samples.count >= tempoFrameSize * 2 else {
            return (nil, 0)
        }

        var frameEnergies: [Float] = []
        frameEnergies.reserveCapacity(samples.count / tempoHopSize)
        var start = 0
        while start + tempoFrameSize <= samples.count {
            var sum: Double = 0
            for index in start ..< start + tempoFrameSize {
                let sample = samples[index]
                sum += Double(sample * sample)
            }
            frameEnergies.append(
                Float(log1p(sum / Double(tempoFrameSize)))
            )
            start += tempoHopSize
        }

        var onsetEnvelope = [Float](repeating: 0, count: frameEnergies.count)
        for index in 1 ..< frameEnergies.count {
            onsetEnvelope[index] = max(
                frameEnergies[index] - frameEnergies[index - 1],
                0
            )
        }

        let onsetPower = onsetEnvelope.reduce(Double.zero) {
            $0 + Double($1 * $1)
        }
        guard onsetPower > 0.000_000_1 else {
            return (nil, 0)
        }

        let envelopeRate = sampleRate / Double(tempoHopSize)
        let minimumLag = max(Int(envelopeRate * 60 / 200), 1)
        let maximumLag = min(
            Int(envelopeRate * 60 / 60),
            onsetEnvelope.count - 1
        )
        guard minimumLag <= maximumLag else {
            return (nil, 0)
        }

        var scores: [(lag: Int, score: Float)] = []
        scores.reserveCapacity(maximumLag - minimumLag + 1)
        for lag in minimumLag ... maximumLag {
            var productSum: Double = 0
            var leftPower: Double = 0
            var rightPower: Double = 0
            for index in lag ..< onsetEnvelope.count {
                let left = Double(onsetEnvelope[index])
                let right = Double(onsetEnvelope[index - lag])
                productSum += left * right
                leftPower += left * left
                rightPower += right * right
            }
            let denominator = sqrt(leftPower * rightPower)
            let score = denominator > 0
                ? Float(productSum / denominator)
                : 0
            scores.append((lag, score))
        }

        guard let strongest = scores.max(by: { $0.score < $1.score }),
              strongest.score >= 0.15
        else {
            return (nil, 0)
        }

        let nearPeakThreshold = strongest.score * 0.96
        let chosen = scores.first {
            $0.score >= nearPeakThreshold
        } ?? strongest
        let bpm = Float(60 * envelopeRate / Double(chosen.lag))
        return (
            bpm,
            min(max(chosen.score, 0), 1)
        )
    }

    private func downmixedSamples(
        from buffer: AVAudioPCMBuffer
    ) throws -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard let channels = buffer.floatChannelData, channelCount > 0 else {
            throw AcousticTrackAnalyzerError.unsupportedAudioFormat
        }

        var samples = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channelCount)
        for channelIndex in 0 ..< channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0 ..< frameCount {
                samples[frameIndex] += channel[frameIndex] * scale
            }
        }
        return samples
    }

    private func hannWindow(count: Int) -> [Float] {
        guard count > 1 else {
            return [1]
        }
        return (0 ..< count).map { index in
            0.5 - 0.5 * cos(
                2 * Float.pi * Float(index) / Float(count - 1)
            )
        }
    }

    private func fft(real: inout [Float], imaginary: inout [Float]) {
        let count = real.count
        var destination = 0
        for source in 1 ..< count {
            var bit = count >> 1
            while destination & bit != 0 {
                destination ^= bit
                bit >>= 1
            }
            destination ^= bit
            if source < destination {
                real.swapAt(source, destination)
                imaginary.swapAt(source, destination)
            }
        }

        var length = 2
        while length <= count {
            let angle = -2 * Float.pi / Float(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            for start in stride(from: 0, to: count, by: length) {
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
}

private enum AcousticTrackAnalyzerError: Error {
    case cannotCreateAudioBuffer
    case unsupportedAudioFormat
}

private extension Optional {
    func unwrapped(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else {
            throw error()
        }
        return self
    }
}
