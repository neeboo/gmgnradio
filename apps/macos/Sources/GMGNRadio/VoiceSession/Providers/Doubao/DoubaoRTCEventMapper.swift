import Foundation

struct DoubaoRTCEventMapper: Sendable {
    private var agentAudioActive = false

    mutating func map(_ event: ProviderRealtimeEvent) -> [RealtimeDJEvent] {
        switch event.type {
        case "connection.connected":
            return [.connectionChanged(.connected)]
        case "connection.recovering":
            return [.connectionChanged(.recovering)]
        case "connection.disconnected":
            return [.connectionChanged(.disconnected)]
        case "local_audio.speech_started":
            return [.userSpeechStarted]
        case "local_audio.speech_stopped":
            return [.userSpeechFinished]
        case "doubao.rtc.input_transcript.delta":
            return event.text.map { [.userTranscriptDelta($0)] } ?? []
        case "doubao.rtc.input_transcript.done":
            return event.text.map { [.userTranscriptFinal($0)] } ?? []
        case "agent.response.started":
            return [.agentResponseStarted]
        case "remote_audio_first_frame", "remote_audio.speech_started":
            guard !agentAudioActive else { return [] }
            agentAudioActive = true
            return [.agentAudioStarted]
        case "remote_audio.speech_stopped":
            guard agentAudioActive else { return [] }
            agentAudioActive = false
            return [.agentAudioFinished]
        case "doubao.rtc.output_transcript.delta":
            return event.text.map { [.agentTranscriptDelta($0)] } ?? []
        case "doubao.rtc.output_transcript.done":
            return event.text.map { [.agentTranscriptFinal($0)] } ?? []
        case "story_tool.call":
            return toolCall(from: event).map { [.toolCall($0)] } ?? []
        case "assistant.interrupted":
            agentAudioActive = false
            return [.interrupted]
        case "error", "doubao.rtc.error":
            return [.failure(failure(from: event))]
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

    private func failure(from event: ProviderRealtimeEvent) -> RealtimeDJFailure {
        RealtimeDJFailure(
            code: event.errorCode ?? "doubao_rtc_error",
            message: event.errorMessage ?? "豆包实时会话发生错误",
            recoverable: event.recoverable ?? false
        )
    }
}
