import AVFoundation
import Foundation

struct VisualAudioFeatureExtractor: Sendable {
    private static let lowFrequencies: [Float] = [80, 120, 220, 320]
    private static let midFrequencies: [Float] = [600, 1_000, 1_600, 2_400]
    private static let highFrequencies: [Float] = [4_000, 6_000, 8_000, 12_000]

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

        let low = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.lowFrequencies
        )
        let mid = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.midFrequencies
        )
        let high = bandEnergy(
            samples: mono,
            sampleRate: sampleRate / Float(stride),
            frequencies: Self.highFrequencies
        )
        let strongest = max(low, mid, high, 0.000_001)
        let amplitude = min(max(sqrt(rms) * 1.35, 0), 1)

        return VisualAudioFeatures(
            low: min(max(low / strongest * amplitude, 0), 1),
            mid: min(max(mid / strongest * amplitude, 0), 1),
            high: min(max(high / strongest * amplitude, 0), 1)
        )
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
