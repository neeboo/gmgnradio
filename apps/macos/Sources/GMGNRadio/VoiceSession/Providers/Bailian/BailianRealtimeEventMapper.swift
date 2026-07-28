import Foundation

struct BailianRealtimeEventMapper: Sendable {
    private var agentAudioActive = false

    mutating func map(_ event: ProviderRealtimeEvent) -> [RealtimeDJEvent] {
        switch event.type {
        case "qwen.open", "connection.connected":
            return [.connectionChanged(.connected)]
        case "connection.recovering":
            return [.connectionChanged(.recovering)]
        case "qwen.closed", "connection.disconnected":
            return [.connectionChanged(.disconnected)]
        case "input_audio_buffer.speech_started":
            return [.userSpeechStarted]
        case "input_audio_buffer.speech_stopped":
            return [.userSpeechFinished]
        case "conversation.item.input_audio_transcription.delta":
            return event.text.map { [.userTranscriptDelta($0)] } ?? []
        case "conversation.item.input_audio_transcription.completed":
            return event.text.map { [.userTranscriptFinal($0)] } ?? []
        case "response.created":
            return [.agentResponseStarted]
        case "response.audio.delta":
            guard !agentAudioActive else { return [] }
            agentAudioActive = true
            return [.agentAudioStarted]
        case "response.audio_transcript.delta":
            return event.text.map { [.agentTranscriptDelta($0)] } ?? []
        case "response.audio_transcript.done":
            return event.text.map { [.agentTranscriptFinal($0)] } ?? []
        case "response.done":
            guard agentAudioActive else { return [] }
            agentAudioActive = false
            return [.agentAudioFinished]
        case "response.cancelled", "response.interrupted":
            agentAudioActive = false
            return [.interrupted]
        case "response.function_call_arguments.done":
            return toolCall(from: event).map { [.toolCall($0)] } ?? []
        case "error", "qwen.error":
            return [.failure(failure(from: event, defaultCode: "bailian_realtime_error"))]
        default:
            return []
        }
    }

    private func toolCall(from event: ProviderRealtimeEvent) -> RealtimeDJToolCall? {
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
        from event: ProviderRealtimeEvent,
        defaultCode: String
    ) -> RealtimeDJFailure {
        RealtimeDJFailure(
            code: event.errorCode ?? defaultCode,
            message: event.errorMessage ?? "百炼实时会话发生错误",
            recoverable: event.recoverable ?? false
        )
    }
}
