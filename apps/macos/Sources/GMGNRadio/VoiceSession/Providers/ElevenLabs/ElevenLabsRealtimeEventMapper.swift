import Foundation

struct ElevenLabsRealtimeEventMapper: Sendable {
    private var agentAudioActive = false

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
            return [.connectionChanged(.disconnected)]
        case "speech.user_started":
            return [.userSpeechStarted]
        case "speech.user_finished":
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
