import Testing
@testable import GMGNRadio

@Test
@MainActor
func realtimeEventsDuckMusicAndInterruptTheDJ() async {
    let audio = InterruptionAudioSpy()
    var interruptCallCount = 0
    var states: [DJState] = []
    let coordinator = InterruptionCoordinator(
        audio: audio,
        interruptSession: {
            interruptCallCount += 1
        },
        updateState: {
            states.append($0)
        }
    )

    await coordinator.consume(.agentAudioStarted)
    #expect(audio.duckingValues == [true])
    #expect(states.last == .speaking)

    await coordinator.consume(.userSpeechStarted)
    #expect(audio.stopDJVoiceCallCount == 1)
    #expect(audio.duckingValues.last == true)
    #expect(interruptCallCount == 1)
    #expect(states.last == .listening)

    await coordinator.consume(.userSpeechFinished)
    #expect(states.last == .thinking)

    audio.isMusicPlaying = true
    await coordinator.consume(.agentAudioFinished)
    #expect(audio.duckingValues.last == false)
    #expect(states.last == .playing)
}

@MainActor
private final class InterruptionAudioSpy: DJInterruptionAudioControlling {
    var isMusicPlaying = false
    private(set) var duckingValues: [Bool] = []
    private(set) var stopDJVoiceCallCount = 0

    func setDJSpeaking(_ speaking: Bool) {
        duckingValues.append(speaking)
    }

    func stopDJVoice() {
        stopDJVoiceCallCount += 1
    }
}
