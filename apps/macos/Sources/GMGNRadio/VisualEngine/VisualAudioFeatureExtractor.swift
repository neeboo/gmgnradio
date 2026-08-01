import AVFoundation
import Foundation

struct VisualAudioFeatureExtractor: Sendable {
    private static let bassFrequencies: [Float] = [50, 80, 120, 145]
    private static let lowMidFrequencies: [Float] = [180, 250, 320, 390]
    private static let midFrequencies: [Float] = [500, 800, 1_000, 1_150]
    private static let vocalFrequencies: [Float] = [1_400, 2_000, 2_400, 3_200]
    private static let trebleFrequencies: [Float] = [4_500, 7_000, 9_000, 11_000]

    func extract(from buffer: AVAudioPCMBuffer) -> VisualAudioFeatures {
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return .silent
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = Float(buffer.format.sampleRate)
        guard channelCount > 0, sampleRate > 0 else {
            return .silent
        }

        let sampleLimit = 2_048
        let stride = max(frameCount / sampleLimit, 1)
        var mono: [Float] = []
        mono.reserveCapacity(min(frameCount, sampleLimit))

        for index in Swift.stride(from: 0, to: frameCount, by: stride) {
            var sample: Float = 0
            for channel in 0 ..< channelCount {
                sample += channels[channel][index]
            }
            sample /= Float(channelCount)

            let progress = Float(mono.count) / Float(max(min(frameCount, sampleLimit) - 1, 1))
            let hann = 0.5 - 0.5 * cos(2 * .pi * progress)
            mono.append(sample * hann)
        }

        let rms = sqrt(
            mono.reduce(Float.zero) { partial, sample in
                partial + sample * sample
            } / Float(mono.count)
        )
        guard rms > 0.001 else {
            return .silent
        }

        let bass = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.bassFrequencies
        )
        let lowMid = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.lowMidFrequencies
        )
        let sceneMid = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.midFrequencies
        )
        let vocal = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.vocalFrequencies
        )
        let treble = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.trebleFrequencies
        )
        let strongest = max(
            bass,
            lowMid,
            sceneMid,
            vocal,
            treble,
            0.000_001
        )
        let amplitude = min(max(sqrt(rms) * 1.35, 0), 1)
        let normalizedBass = normalized(
            bass,
            strongest: strongest,
            amplitude: amplitude
        )
        let normalizedLowMid = normalized(
            lowMid,
            strongest: strongest,
            amplitude: amplitude
        )
        let normalizedMid = normalized(
            sceneMid,
            strongest: strongest,
            amplitude: amplitude
        )
        let normalizedVocal = normalized(
            vocal,
            strongest: strongest,
            amplitude: amplitude
        )
        let normalizedTreble = normalized(
            treble,
            strongest: strongest,
            amplitude: amplitude
        )

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
            amplitude: amplitude,
            waveform: waveformEnvelope(mono),
            spectrum: SIMD8<Float>(
                normalizedBass,
                normalizedLowMid,
                normalizedMid,
                normalizedVocal,
                normalizedTreble,
                (normalizedBass + normalizedLowMid) * 0.5,
                (normalizedMid + normalizedVocal) * 0.5,
                (normalizedVocal + normalizedTreble) * 0.5
            )
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

    private func waveformEnvelope(_ samples: [Float]) -> SIMD8<Float> {
        guard !samples.isEmpty else {
            return .zero
        }
        var result = SIMD8<Float>(repeating: 0)
        var strongest: Float = 0
        for bucket in 0 ..< 8 {
            let start = bucket * samples.count / 8
            let end = max((bucket + 1) * samples.count / 8, start + 1)
            let peak = samples[start ..< min(end, samples.count)]
                .reduce(Float.zero) { max($0, abs($1)) }
            result[bucket] = peak
            strongest = max(strongest, peak)
        }
        guard strongest > 0.000_001 else {
            return .zero
        }
        return result / SIMD8<Float>(repeating: strongest)
    }

    private func bandEnergy(
        samples: [Float],
        sampleRate: Float,
        frequencies: [Float]
    ) -> Float {
        frequencies
            .filter { $0 < sampleRate * 0.48 }
            .map { goertzelEnergy(samples: samples, sampleRate: sampleRate, frequency: $0) }
            .max() ?? 0
    }

    private func goertzelEnergy(
        samples: [Float],
        sampleRate: Float,
        frequency: Float
    ) -> Float {
        let omega = 2 * Float.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous: Float = 0
        var secondPrevious: Float = 0

        for sample in samples {
            let current = sample + coefficient * previous - secondPrevious
            secondPrevious = previous
            previous = current
        }

        let power = previous * previous
            + secondPrevious * secondPrevious
            - coefficient * previous * secondPrevious
        return sqrt(max(power, 0)) / Float(samples.count)
    }
}

@MainActor
protocol VisualAudioMonitoring: AnyObject {
    func start() throws
    func stop()
}

@MainActor
final class VisualAudioFeatureDeliveryGate {
    private let store: VisualAudioFeatureStore
    private var generation: UInt64 = 0

    init(store: VisualAudioFeatureStore) {
        self.store = store
    }

    func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func deliver(_ features: VisualAudioFeatures, generation: UInt64) {
        guard generation == self.generation else {
            return
        }
        store.update(features)
    }

    func end() {
        generation &+= 1
        store.update(.silent)
    }
}

@MainActor
final class VisualAudioInputMonitor: VisualAudioMonitoring {
    private let engine: AVAudioEngine
    private let extractor: VisualAudioFeatureExtractor
    private let deliveryGate: VisualAudioFeatureDeliveryGate
    private var tapInstalled = false

    init(
        store: VisualAudioFeatureStore,
        engine: AVAudioEngine = AVAudioEngine(),
        extractor: VisualAudioFeatureExtractor = VisualAudioFeatureExtractor()
    ) {
        self.engine = engine
        self.extractor = extractor
        deliveryGate = VisualAudioFeatureDeliveryGate(store: store)
    }

    func start() throws {
        guard !engine.isRunning else {
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            return
        }

        let generation = deliveryGate.begin()
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format,
            block: Self.makeTapBlock(
                extractor: extractor,
                deliveryGate: deliveryGate,
                generation: generation
            )
        )
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            deliveryGate.end()
            throw error
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        deliveryGate.end()
    }

    private nonisolated static func makeTapBlock(
        extractor: VisualAudioFeatureExtractor,
        deliveryGate: VisualAudioFeatureDeliveryGate,
        generation: UInt64
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let features = extractor.extract(from: buffer)
            Task { @MainActor in
                deliveryGate.deliver(
                    features,
                    generation: generation
                )
            }
        }
    }
}
