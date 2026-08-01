import AVFoundation
import Foundation
import Testing
@testable import GMGNRadio

@Test
func bailianPCMCodecBuildsA24kMonoPlaybackBuffer() throws {
    let pcm = Data([
        0x00, 0x00,
        0x00, 0x40,
        0x00, 0xC0,
    ])

    let buffer = try BailianPCMCodec.playbackBuffer(from: pcm)
    let samples = try #require(buffer.floatChannelData?[0])

    #expect(buffer.format.sampleRate == 24_000)
    #expect(buffer.format.channelCount == 1)
    #expect(buffer.frameLength == 3)
    #expect(abs(samples[0]) < 0.0001)
    #expect(abs(samples[1] - 0.5) < 0.001)
    #expect(abs(samples[2] + 0.5) < 0.001)
}

@Test
func bailianPCMCodecReportsNormalizedAudioLevel() {
    let pcm = Data([
        0x00, 0x00,
        0xFF, 0x7F,
        0x00, 0x40,
    ])

    let level = BailianPCMCodec.audioLevel(for: pcm)

    #expect(level.peak > 0.99)
    #expect(level.rms > 0.6)
    #expect(level.rms < 0.7)
}

@Test
func djVoiceChannelAddsGainWithSoftLimiting() {
    let quiet = DJVoicePCMEnhancer.enhancedSample(0.1)
    let medium = DJVoicePCMEnhancer.enhancedSample(0.5)
    let fullScale = DJVoicePCMEnhancer.enhancedSample(1)

    #expect(quiet > 0.2)
    #expect(quiet < 0.25)
    #expect(medium > 0.8)
    #expect(medium < 0.9)
    #expect(abs(fullScale - 1) < 0.0001)
}

@Test
func bailianMicrophoneConverterProduces16kMonoPCM() throws {
    let inputFormat = try #require(
        AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        )
    )
    let input = try #require(
        AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: 480
        )
    )
    input.frameLength = 480
    let samples = try #require(input.floatChannelData?[0])
    for index in 0 ..< 480 {
        samples[index] = 0.25
    }

    let converter = try BailianMicrophonePCMConverter(
        inputFormat: inputFormat
    )
    let pcm = try converter.convert(input)
    let level = BailianPCMCodec.audioLevel(for: pcm)

    #expect(pcm.count >= 300)
    #expect(pcm.count <= 340)
    #expect(level.peak > 0.2)
    #expect(level.peak < 0.3)
}

@Test
func bailianMicrophoneConverterAcceptsInterleavedStereoInput() throws {
    let inputFormat = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )
    )
    let input = try #require(
        AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: 1_024
        )
    )
    input.frameLength = 1_024
    let audioBuffer = input.mutableAudioBufferList.pointee.mBuffers
    let samples = try #require(
        audioBuffer.mData?.assumingMemoryBound(to: Float.self)
    )
    for index in 0 ..< 2_048 {
        samples[index] = 0.2
    }

    let converter = try BailianMicrophonePCMConverter(
        inputFormat: inputFormat
    )
    let pcm = try converter.convert(input)
    let level = BailianPCMCodec.audioLevel(for: pcm)

    #expect(pcm.count >= 650)
    #expect(pcm.count <= 720)
    #expect(level.peak > 0.15)
}

@Test
func bailianMicrophoneCaptureRequestsProviderPCMFormat() {
    let settings = BailianMicrophoneCapture.audioSettings

    #expect(settings[AVSampleRateKey] as? Double == 16_000)
    #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
    #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
}

@Test
func bailianMicrophonePrefersPhysicalInputOverVirtualDefault() {
    let devices = [
        BailianMicrophoneDeviceOption(
            id: "com.rogueamoeba.Loopback:test",
            name: "Loopback Audio"
        ),
        BailianMicrophoneDeviceOption(
            id: "BuiltInMicrophoneDevice",
            name: "MacBook Pro麦克风"
        ),
    ]

    let selected = BailianMicrophoneDeviceSelector.preferredID(
        defaultID: devices[0].id,
        devices: devices
    )

    #expect(selected == "BuiltInMicrophoneDevice")
}

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
func audioGraphDucksMusicWhileTheDJIsSpeaking() async throws {
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-ducking-\(UUID().uuidString).wav")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
    }
    try writeSineWave(to: sourceURL)

    let engine = AVAudioEngine()
    let graph = AudioGraphController(
        visualStore: VisualAudioFeatureStore(),
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
    let normalPeak = try renderPeak(
        engine: engine,
        format: renderingFormat
    )

    graph.setDJSpeaking(true)
    try await Task.sleep(for: .milliseconds(220))
    let duckedPeak = try renderPeak(
        engine: engine,
        format: renderingFormat
    )

    #expect(normalPeak > 0.2)
    #expect(duckedPeak < normalPeak * 0.4)
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

@Test
@MainActor
func djVoiceDrainWaitsForEveryScheduledBuffer() async {
    let tracker = DJVoiceDrainTracker()
    let firstGeneration = tracker.beginBuffer()
    let secondGeneration = tracker.beginBuffer()
    var drained = false

    let waiter = Task { @MainActor in
        await tracker.waitUntilDrained()
        drained = true
    }
    await Task.yield()
    #expect(drained == false)

    tracker.completeBuffer(generation: firstGeneration)
    await Task.yield()
    #expect(drained == false)

    tracker.completeBuffer(generation: secondGeneration)
    await waiter.value
    #expect(drained == true)
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
