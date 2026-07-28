@preconcurrency import AVFoundation
import Foundation
import LiveKit

final class ElevenLabsAudioLevelRenderer:
    NSObject,
    AudioRenderer,
    @unchecked Sendable
{
    private let publish: @Sendable (RealtimeDJAudioLevel) -> Void

    init(
        publish: @escaping @Sendable (RealtimeDJAudioLevel) -> Void
    ) {
        self.publish = publish
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return }

        let channelCount = Int(pcmBuffer.format.channelCount)
        let interleaved = pcmBuffer.format.isInterleaved
        var sumOfSquares = 0.0
        var peak = 0.0
        var sampleCount = 0

        switch pcmBuffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = pcmBuffer.floatChannelData else { return }
            analyze(
                channels: channels,
                frameCount: frameCount,
                channelCount: channelCount,
                interleaved: interleaved,
                normalize: { Double($0) },
                sumOfSquares: &sumOfSquares,
                peak: &peak,
                sampleCount: &sampleCount
            )
        case .pcmFormatInt16:
            guard let channels = pcmBuffer.int16ChannelData else { return }
            analyze(
                channels: channels,
                frameCount: frameCount,
                channelCount: channelCount,
                interleaved: interleaved,
                normalize: { Double($0) / Double(Int16.max) },
                sumOfSquares: &sumOfSquares,
                peak: &peak,
                sampleCount: &sampleCount
            )
        default:
            return
        }

        guard sampleCount > 0 else { return }
        publish(RealtimeDJAudioLevel(
            rms: sqrt(sumOfSquares / Double(sampleCount)),
            peak: peak
        ))
    }

    private func analyze<Sample>(
        channels: UnsafePointer<UnsafeMutablePointer<Sample>>,
        frameCount: Int,
        channelCount: Int,
        interleaved: Bool,
        normalize: (Sample) -> Double,
        sumOfSquares: inout Double,
        peak: inout Double,
        sampleCount: inout Int
    ) {
        let bufferCount = interleaved ? 1 : channelCount
        let samplesPerBuffer = interleaved
            ? frameCount * channelCount
            : frameCount

        for channel in 0 ..< bufferCount {
            let samples = channels[channel]
            for index in 0 ..< samplesPerBuffer {
                let value = normalize(samples[index])
                sumOfSquares += value * value
                peak = max(peak, abs(value))
                sampleCount += 1
            }
        }
    }
}
