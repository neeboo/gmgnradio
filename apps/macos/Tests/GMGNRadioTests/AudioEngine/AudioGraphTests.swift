import AVFoundation
import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func audioGraphRendersLocalMusicAndPausesToSilence() throws {
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-audio-graph-\(UUID().uuidString).wav")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
    }
    try writeSineWave(to: sourceURL)

    let engine = AVAudioEngine()
    let visualStore = VisualAudioFeatureStore()
    let graph = AudioGraphController(
        visualStore: visualStore,
        engine: engine
    )
    let renderingFormat = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
    )
    try engine.enableManualRenderingMode(
        .offline,
        format: renderingFormat,
        maximumFrameCount: 1_024
    )

    _ = try graph.load(sourceURL) {}
    try graph.play()

    let playingPeak = try renderPeak(engine: engine, format: renderingFormat)
    #expect(playingPeak > 0.2)

    graph.pause()
    let pausedPeak = try renderPeak(engine: engine, format: renderingFormat)
    #expect(pausedPeak < 0.001)
}

@Test
@MainActor
func audioGraphCompletionDispatcherIgnoresAReplacedTrackCallback() {
    let dispatcher = AudioGraphCompletionDispatcher()
    var firstCompletionCount = 0
    var secondCompletionCount = 0

    let first = dispatcher.prepare {
        firstCompletionCount += 1
    }
    let second = dispatcher.prepare {
        secondCompletionCount += 1
    }

    first()
    second()

    #expect(firstCompletionCount == 0)
    #expect(secondCompletionCount == 1)
}

private func writeSineWave(to url: URL) throws {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )
    )
    let frameCount: AVAudioFrameCount = 48_000
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )
    )
    buffer.frameLength = frameCount
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0 ..< Int(frameCount) {
        let phase = 2 * Float.pi * 440 * Float(index) / 48_000
        samples[index] = sin(phase) * 0.7
    }

    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings
    )
    try file.write(from: buffer)
}

private func renderPeak(
    engine: AVAudioEngine,
    format: AVAudioFormat
) throws -> Float {
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1_024
        )
    )

    var successfulRenders = 0
    var lastPeak: Float = 0
    for _ in 0 ..< 32 {
        let status = try engine.renderOffline(1_024, to: buffer)
        switch status {
        case .success:
            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)
            var peak: Float = 0
            for channel in 0 ..< channelCount {
                let samples = try #require(buffer.floatChannelData?[channel])
                for index in 0 ..< frameCount {
                    peak = max(peak, abs(samples[index]))
                }
            }
            lastPeak = peak
            successfulRenders += 1
            if successfulRenders == 8 {
                return lastPeak
            }
        case .cannotDoInCurrentContext:
            continue
        case .error:
            Issue.record("离线音频图渲染失败")
            return 0
        case .insufficientDataFromInputNode:
            Issue.record("离线音频图意外依赖输入设备")
            return 0
        @unknown default:
            Issue.record("离线音频图返回未知状态")
            return 0
        }
    }

    Issue.record("离线音频图持续忙碌")
    return 0
}
