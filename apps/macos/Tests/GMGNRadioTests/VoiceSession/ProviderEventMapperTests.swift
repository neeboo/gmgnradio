import Foundation
import Testing
@testable import GMGNRadio

@Test
func bailianMapsServerVADAndTranscripts() {
    var mapper = BailianRealtimeEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "input_audio_buffer.speech_started"
    )) == [.userSpeechStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "input_audio_buffer.speech_stopped"
    )) == [.userSpeechFinished])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "conversation.item.input_audio_transcription.delta",
        text: "少说"
    )) == [.userTranscriptDelta("少说")])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "conversation.item.input_audio_transcription.completed",
        text: "少说一点"
    )) == [.userTranscriptFinal("少说一点")])
}

@Test
func bailianStartsAgentAudioOnlyOnTheFirstDelta() {
    var mapper = BailianRealtimeEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "response.created"
    )) == [.agentResponseStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "response.audio.delta"
    )) == [.agentAudioStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "response.audio.delta"
    )).isEmpty)
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "response.done"
    )) == [.agentAudioFinished])
}

@Test
func bailianMapsToolCallsWithoutInterpretingArguments() {
    var mapper = BailianRealtimeEventMapper()
    let arguments = Data(#"{"gain":0.35}"#.utf8)

    let events = mapper.map(ProviderRealtimeEvent(
        type: "response.function_call_arguments.done",
        callID: "call-1",
        name: "set_music_gain",
        argumentsJSON: arguments
    ))

    #expect(events == [.toolCall(RealtimeDJToolCall(
        id: "call-1",
        name: "set_music_gain",
        argumentsJSON: arguments
    ))])
}

@Test
func doubaoMapsRTCAndVoiceChatEvents() {
    var mapper = DoubaoRTCEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "connection.connected"
    )) == [.connectionChanged(.connected)])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "local_audio.speech_started"
    )) == [.userSpeechStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "doubao.rtc.input_transcript.done",
        text: "沿着这首继续"
    )) == [.userTranscriptFinal("沿着这首继续")])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "remote_audio_first_frame"
    )) == [.agentAudioStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "doubao.rtc.output_transcript.done",
        text: "好，我们沿着这个颜色继续。"
    )) == [.agentTranscriptFinal("好，我们沿着这个颜色继续。")])
}

@Test
func providerMappersIgnoreUnknownEventsAndNormalizeErrors() {
    var bailian = BailianRealtimeEventMapper()
    var doubao = DoubaoRTCEventMapper()

    #expect(bailian.map(ProviderRealtimeEvent(type: "session.updated")).isEmpty)
    #expect(doubao.map(ProviderRealtimeEvent(type: "rtc.vendor.debug")).isEmpty)
    #expect(doubao.map(ProviderRealtimeEvent(
        type: "error",
        errorCode: "rtc-1001",
        errorMessage: "room disconnected",
        recoverable: true
    )) == [.failure(RealtimeDJFailure(
        code: "rtc-1001",
        message: "room disconnected",
        recoverable: true
    ))])
}
