import AVFoundation
import Synchronization
import Testing
@testable import GMGNRadio

@Test
func elevenLabsAudioRendererPublishesNormalizedLevels() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 4
    ))
    buffer.frameLength = 4
    let samples = try #require(buffer.floatChannelData?[0])
    samples[0] = 0
    samples[1] = 0.5
    samples[2] = -1
    samples[3] = 0.5

    let received = Mutex<RealtimeDJAudioLevel?>(nil)
    let renderer = ElevenLabsAudioLevelRenderer { level in
        received.withLock { $0 = level }
    }

    renderer.render(pcmBuffer: buffer)

    let level = try #require(received.withLock { $0 })
    #expect(abs(level.rms - 0.612_372_4) < 0.000_1)
    #expect(level.peak == 1)
}

@Test
func elevenLabsMapperNormalizesAgentAudioLevels() {
    var mapper = ElevenLabsRealtimeEventMapper()

    let events = mapper.map(ProviderRealtimeEvent(
        type: "audio.agent.level",
        rms: 0.25,
        peak: 0.75
    ))

    #expect(events == [
        .agentAudioLevel(RealtimeDJAudioLevel(rms: 0.25, peak: 0.75))
    ])
}
