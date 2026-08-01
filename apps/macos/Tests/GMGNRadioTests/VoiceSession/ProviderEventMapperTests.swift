import Foundation
import Testing
@testable import GMGNRadio

@Test
func bailianBuildsAnAuthenticatedRealtimeWebSocketRequest() throws {
    let payload = BailianSessionPayload(
        apiKey: "sk-test",
        model: "qwen3.5-omni-flash-realtime",
        voiceID: "Tina"
    )

    let request = try BailianRealtimeWireProtocol.makeRequest(
        payload: payload
    )

    #expect(
        request.url?.absoluteString
            == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
                + "?model=qwen3.5-omni-flash-realtime"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer sk-test"
    )
}

@Test
func bailianSessionUpdateUsesVoiceAudioAndServerVAD() throws {
    let payload = BailianSessionPayload(
        apiKey: "sk-test",
        model: "qwen3.5-omni-flash-realtime",
        voiceID: "Tina"
    )

    let data = try BailianRealtimeWireProtocol.sessionUpdateData(
        payload: payload,
        instructions: "你是 gmgn radio 的 DJ。"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    )
    let session = try #require(object["session"] as? [String: Any])
    let turnDetection = try #require(
        session["turn_detection"] as? [String: Any]
    )
    let transcription = try #require(
        session["input_audio_transcription"] as? [String: Any]
    )
    let tools = try #require(
        session["tools"] as? [[String: Any]]
    )
    let toolNames = Set(tools.compactMap { tool in
        (tool["function"] as? [String: Any])?["name"] as? String
    })

    #expect(object["type"] as? String == "session.update")
    #expect(session["voice"] as? String == "Tina")
    #expect(session["input_audio_format"] as? String == "pcm")
    #expect(session["output_audio_format"] as? String == "pcm")
    #expect(session["max_tokens"] as? Int == 256)
    #expect(turnDetection["type"] as? String == "semantic_vad")
    #expect(
        transcription["model"] as? String
            == "qwen3-asr-flash-realtime"
    )
    #expect(
        toolNames
            == Set(DJAgentCapabilityManifest.capabilities.map(\.name))
    )
}

@Test
func bailianDecodesAudioAndTranscriptMessages() throws {
    let audio = Data([0x01, 0x02, 0x03, 0x04])
    let audioJSON = Data(
        """
        {
          "type": "response.audio.delta",
          "delta": "\(audio.base64EncodedString())"
        }
        """.utf8
    )
    let transcriptJSON = Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "transcript": "换一首轻一点的"
        }
        """.utf8
    )

    let decodedAudio = try BailianRealtimeWireProtocol.decode(
        audioJSON
    )
    let decodedTranscript = try BailianRealtimeWireProtocol.decode(
        transcriptJSON
    )

    #expect(decodedAudio.event.type == "response.audio.delta")
    #expect(decodedAudio.audio == audio)
    #expect(
        decodedTranscript.event.text == "换一首轻一点的"
    )
}

@Test
func bailianMicrophoneChunksArePackedInto100msFrames() {
    var accumulator = BailianPCMChunkAccumulator(
        targetByteCount: 3_200
    )

    let first = accumulator.append(Data(repeating: 1, count: 2_000))
    let second = accumulator.append(Data(repeating: 2, count: 2_000))

    #expect(first.isEmpty)
    #expect(second.count == 1)
    #expect(second[0].count == 3_200)
    #expect(accumulator.pendingByteCount == 800)
}

@Test
func bailianInterruptionNeverClearsTheUsersLiveAudio() throws {
    let idleEvents = try BailianRealtimeWireProtocol
        .interruptionData(agentResponseActive: false)
    let speakingEvents = try BailianRealtimeWireProtocol
        .interruptionData(agentResponseActive: true)
    let types = try speakingEvents.map { data in
        try #require(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )["type"] as? String
    }

    #expect(idleEvents.isEmpty)
    #expect(types == ["response.cancel"])
}

@Test
func bailianBuildsAnInternalMessageBeforeRequestingAResponse() throws {
    let data = try BailianRealtimeWireProtocol.instructionData(
        "后台 City Pop 歌单已经准备好，请询问是否切换。"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    )
    let item = try #require(object["item"] as? [String: Any])
    let content = try #require(item["content"] as? [[String: Any]])

    #expect(object["type"] as? String == "conversation.item.create")
    #expect(item["type"] as? String == "message")
    #expect(item["role"] as? String == "user")
    #expect(content.first?["type"] as? String == "input_text")
    #expect(
        content.first?["text"] as? String
            == "后台 City Pop 歌单已经准备好，请询问是否切换。"
    )
}

@Test
func bailianEchoGateWaitsForBufferedDJAudioAndItsTail() {
    let start = Date(timeIntervalSince1970: 1_000)
    var gate = BailianMicrophoneEchoGate(tailDuration: 0.35)

    gate.noteAgentAudio(
        byteCount: 48_000,
        now: start
    )
    gate.finishAgentResponse(
        now: start.addingTimeInterval(0.1)
    )

    #expect(
        !gate.allowsTransmission(
            now: start.addingTimeInterval(1.2)
        )
    )
    #expect(
        gate.allowsTransmission(
            now: start.addingTimeInterval(1.36)
        )
    )
}

@Test
func bailianProviderHasALocalRealtimeRuntime() {
    #expect(RealtimeDJProvider.bailian.hasLocalRuntime)
}

@Test
func bailianSessionDrivesTheTransportAndMapsEvents() async throws {
    let transport = RecordingBailianRealtimeTransport()
    let session = BailianRealtimeSession(transport: transport)
    let payload = BailianSessionPayload(
        apiKey: "sk-test",
        model: "qwen3.5-omni-flash-realtime",
        voiceID: "Tina"
    )
    let ticket = RealtimeDJSessionTicket(
        provider: .bailian,
        sessionID: "bailian-test",
        expiresAt: Date(timeIntervalSinceNow: 600),
        providerPayload: try JSONEncoder().encode(payload)
    )

    try await session.connect(ticket: ticket)
    try await session.setMicrophoneCaptureEnabled(true)
    try await session.setMicrophoneTransmissionEnabled(true)
    try await session.requestAgentResponse("新歌已开始，请说一句开场词。")

    #expect(await transport.calls() == [
        .connect(payload),
        .setCapture(true),
        .setTransmission(true),
        .requestAgentResponse("新歌已开始，请说一句开场词。"),
    ])

    var iterator = await session.eventStream().makeAsyncIterator()
    await transport.emit(ProviderRealtimeEvent(
        type: "input_audio_buffer.speech_started"
    ))
    #expect(await iterator.next() == .userSpeechStarted)
}

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
func bailianFinishesAResponseEvenWhenItProducedNoAudio() {
    var mapper = BailianRealtimeEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "response.created"
    )) == [.agentResponseStarted])
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

@Test
func elevenLabsMapsConversationCallbacks() {
    var mapper = ElevenLabsRealtimeEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "connection.connected"
    )) == [.connectionChanged(.connected)])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "speech.user_started"
    )) == [.userSpeechStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "transcript.user_final",
        text: "这首放完就安静一点"
    )) == [.userTranscriptFinal("这首放完就安静一点")])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "agent.state.speaking"
    )) == [.agentResponseStarted, .agentAudioStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "transcript.agent_final",
        text: "好，后面留一点空间。"
    )) == [.agentTranscriptFinal("好，后面留一点空间。")])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "agent.state.listening"
    )) == [.agentAudioFinished])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "conversation.interrupted"
    )) == [.interrupted])
}

@Test
func elevenLabsUsesVadScoresForRealUserSpeechActivity() {
    var mapper = ElevenLabsRealtimeEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "audio.user.vad",
        rms: 0.18,
        peak: 0.18
    )) == [
        .userAudioLevel(RealtimeDJAudioLevel(rms: 0.18, peak: 0.18))
    ])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "audio.user.vad",
        rms: 0.72,
        peak: 0.72
    )) == [
        .userAudioLevel(RealtimeDJAudioLevel(rms: 0.72, peak: 0.72)),
        .userSpeechStarted,
    ])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "audio.user.vad",
        rms: 0.28,
        peak: 0.28
    )) == [
        .userAudioLevel(RealtimeDJAudioLevel(rms: 0.28, peak: 0.28)),
        .userSpeechFinished,
    ])
}

@Test
func elevenLabsMapsClientToolsWithoutChangingTheirPayload() {
    var mapper = ElevenLabsRealtimeEventMapper()
    let arguments = Data(#"{"trackId":"track-next"}"#.utf8)

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "client_tool.call",
        callID: "tool-11",
        name: "play_track",
        argumentsJSON: arguments
    )) == [.toolCall(RealtimeDJToolCall(
        id: "tool-11",
        name: "play_track",
        argumentsJSON: arguments
    ))])
}

@Test
func elevenLabsDisconnectClearsAgentAudioStateForReconnect() {
    var mapper = ElevenLabsRealtimeEventMapper()

    #expect(mapper.map(ProviderRealtimeEvent(
        type: "agent.state.speaking"
    )) == [.agentResponseStarted, .agentAudioStarted])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "connection.disconnected"
    )) == [.connectionChanged(.disconnected)])
    #expect(mapper.map(ProviderRealtimeEvent(
        type: "agent.state.speaking"
    )) == [.agentResponseStarted, .agentAudioStarted])
}

private enum RecordingBailianTransportCall: Equatable, Sendable {
    case connect(BailianSessionPayload)
    case setCapture(Bool)
    case setTransmission(Bool)
    case requestAgentResponse(String)
}

private actor RecordingBailianRealtimeTransport:
    BailianRealtimeTransport
{
    private let stream: AsyncStream<ProviderRealtimeEvent>
    private let continuation:
        AsyncStream<ProviderRealtimeEvent>.Continuation
    private var recordedCalls: [RecordingBailianTransportCall] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func eventStream() -> AsyncStream<ProviderRealtimeEvent> {
        stream
    }

    func connect(payload: BailianSessionPayload) {
        recordedCalls.append(.connect(payload))
    }

    func updateContext(_ context: Data) {}

    func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        recordedCalls.append(.setCapture(enabled))
    }

    func setMicrophoneTransmissionEnabled(_ enabled: Bool) {
        recordedCalls.append(.setTransmission(enabled))
    }

    func interrupt() {}

    func requestAgentResponse(_ instruction: String) {
        recordedCalls.append(.requestAgentResponse(instruction))
    }

    func submitToolResult(_ result: RealtimeDJToolResult) {}

    func disconnect() {}

    func emit(_ event: ProviderRealtimeEvent) {
        continuation.yield(event)
    }

    func calls() -> [RecordingBailianTransportCall] {
        recordedCalls
    }
}
