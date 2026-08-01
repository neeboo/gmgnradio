import Foundation

@MainActor
protocol DJInterruptionAudioControlling: AnyObject {
    var isMusicPlaying: Bool { get }
    func setDJSpeaking(_ speaking: Bool)
    func stopDJVoice()
}

@MainActor
final class InterruptionCoordinator {
    private let audio: any DJInterruptionAudioControlling
    private let interruptSession: @MainActor () async -> Void
    private let updateState: @MainActor (DJState) -> Void
    private var userIsSpeaking = false

    init(
        audio: any DJInterruptionAudioControlling,
        interruptSession: @escaping @MainActor () async -> Void,
        updateState: @escaping @MainActor (DJState) -> Void
    ) {
        self.audio = audio
        self.interruptSession = interruptSession
        self.updateState = updateState
    }

    func consume(_ event: RealtimeDJEvent) async {
        switch event {
        case .userSpeechStarted:
            userIsSpeaking = true
            audio.stopDJVoice()
            audio.setDJSpeaking(true)
            updateState(.listening)
            await interruptSession()
        case .userSpeechFinished:
            userIsSpeaking = false
            updateState(.thinking)
        case .agentResponseStarted:
            updateState(.thinking)
        case .agentAudioStarted:
            userIsSpeaking = false
            audio.setDJSpeaking(true)
            updateState(.speaking)
        case .agentAudioFinished:
            if !userIsSpeaking {
                audio.setDJSpeaking(false)
            }
            updateState(audio.isMusicPlaying ? .playing : .idle)
        case .interrupted:
            audio.stopDJVoice()
            if !userIsSpeaking {
                audio.setDJSpeaking(false)
                updateState(audio.isMusicPlaying ? .playing : .idle)
            }
        case let .connectionChanged(state):
            if state == .recovering {
                updateState(.reconnecting)
            } else if state == .disconnected {
                audio.setDJSpeaking(false)
            }
        case .failure:
            audio.stopDJVoice()
            audio.setDJSpeaking(false)
            updateState(.failed)
        case .userAudioLevel,
             .userTranscriptDelta,
             .userTranscriptFinal,
             .agentAudioLevel,
             .agentTranscriptDelta,
             .agentTranscriptFinal,
             .toolCall:
            break
        }
    }
}
