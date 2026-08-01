import Foundation

struct ElevenLabsRealtimeEventMapper: Sendable {
    private var agentAudioActive = false
    private var userSpeechActive = false

    mutating func map(_ event: ProviderRealtimeEvent) -> [RealtimeDJEvent] {
        switch event.type {
        case "connection.connecting":
            return [.connectionChanged(.connecting)]
        case "connection.connected":
            return [.connectionChanged(.connected)]
        case "connection.recovering":
            return [.connectionChanged(.recovering)]
        case "connection.disconnected":
            agentAudioActive = false
            userSpeechActive = false
            return [.connectionChanged(.disconnected)]
        case "audio.user.vad":
            return userVADEvents(from: event)
        case "speech.user_started":
            userSpeechActive = true
            return [.userSpeechStarted]
        case "speech.user_finished":
            userSpeechActive = false
            return [.userSpeechFinished]
        case "transcript.user_final":
            return event.text.map { [.userTranscriptFinal($0)] } ?? []
        case "agent.state.speaking":
            guard !agentAudioActive else { return [] }
            agentAudioActive = true
            return [.agentResponseStarted, .agentAudioStarted]
        case "agent.state.listening":
            guard agentAudioActive else { return [] }
            agentAudioActive = false
            return [.agentAudioFinished]
        case "audio.agent.level":
            guard let rms = event.rms, let peak = event.peak else {
                return []
            }
            return [.agentAudioLevel(RealtimeDJAudioLevel(
                rms: rms,
                peak: peak
            ))]
        case "transcript.agent_final":
            return event.text.map { [.agentTranscriptFinal($0)] } ?? []
        case "conversation.interrupted":
            agentAudioActive = false
            return [.interrupted]
        case "client_tool.call":
            return toolCall(from: event).map { [.toolCall($0)] } ?? []
        case "error":
            return [.failure(failure(from: event))]
        default:
            return []
        }
    }

    private mutating func userVADEvents(
        from event: ProviderRealtimeEvent
    ) -> [RealtimeDJEvent] {
        guard let rms = event.rms else {
            return []
        }
        let level = RealtimeDJAudioLevel(
            rms: rms,
            peak: event.peak ?? rms
        )
        var events: [RealtimeDJEvent] = [.userAudioLevel(level)]
        if !userSpeechActive, level.rms >= 0.58 {
            userSpeechActive = true
            events.append(.userSpeechStarted)
        } else if userSpeechActive, level.rms <= 0.32 {
            userSpeechActive = false
            events.append(.userSpeechFinished)
        }
        return events
    }

    private func toolCall(
        from event: ProviderRealtimeEvent
    ) -> RealtimeDJToolCall? {
        guard
            let callID = event.callID,
            let name = event.name,
            let argumentsJSON = event.argumentsJSON
        else {
            return nil
        }
        return RealtimeDJToolCall(
            id: callID,
            name: name,
            argumentsJSON: argumentsJSON
        )
    }

    private func failure(
        from event: ProviderRealtimeEvent
    ) -> RealtimeDJFailure {
        RealtimeDJFailure(
            code: event.errorCode ?? "elevenlabs_realtime_error",
            message: event.errorMessage ?? "ElevenLabs 实时会话发生错误",
            recoverable: event.recoverable ?? false
        )
    }
}
