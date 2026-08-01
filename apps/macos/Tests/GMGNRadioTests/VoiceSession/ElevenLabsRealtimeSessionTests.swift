import Foundation
import Testing
@testable import GMGNRadio

@MainActor
@Test
func liveElevenLabsSessionUsesOfficialSDKTransport() {
    let session = ElevenLabsRealtimeSession.live()

    #expect(session.provider == .elevenLabs)
}

@Test
func elevenLabsManualAPIKeyBuildsAndParsesAConversationTokenRequest()
    throws
{
    let tokenRequest = ElevenLabsConversationTokenRequest()
    let request = try tokenRequest.makeRequest(
        agentID: "agent_radio",
        apiKey: "sk-local"
    )
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    ))

    #expect(
        request.url?.absoluteString.contains(
            "/v1/convai/conversation/token"
        ) == true
    )
    #expect(
        request.value(forHTTPHeaderField: "xi-api-key")
            == "sk-local"
    )
    #expect(
        try tokenRequest.parse(
            Data(#"{"token":"signed-token"}"#.utf8),
            response: response
        ) == "signed-token"
    )
}

@Test
func elevenLabsConnectionFailureKeepsTheActionableMessage() {
    let error = ElevenLabsSDKTransportError.connectionFailed(
        "ElevenLabs Agent ID 无效，或该 Agent 未公开。"
    )

    #expect(
        error.errorDescription
            == "ElevenLabs Agent ID 无效，或该 Agent 未公开。"
    )
}

@Test
func elevenLabsSessionDecodesOpaqueTicketAndForwardsEvents() async throws {
    let transport = RecordingElevenLabsConversationTransport()
    let session = ElevenLabsRealtimeSession(transport: transport)
    var iterator = await session.eventStream().makeAsyncIterator()
    let payload = try JSONEncoder().encode(ElevenLabsSessionPayload(
        conversationToken: "signed-token",
        voiceID: "voice-blue"
    ))

    try await session.connect(ticket: RealtimeDJSessionTicket(
        provider: .elevenLabs,
        sessionID: "eleven-1",
        expiresAt: Date(timeIntervalSinceNow: 600),
        providerPayload: payload
    ))
    await transport.emit(ProviderRealtimeEvent(
        type: "transcript.agent_final",
        text: "接下来继续听歌。"
    ))

    #expect(await transport.connectedPayload() == ElevenLabsSessionPayload(
        conversationToken: "signed-token",
        voiceID: "voice-blue"
    ))
    #expect(await iterator.next() == .agentTranscriptFinal("接下来继续听歌。"))
}

@Test
func elevenLabsSessionCombinesCaptureAndTransmissionIntoSDKMute() async throws {
    let transport = RecordingElevenLabsConversationTransport()
    let session = ElevenLabsRealtimeSession(transport: transport)

    try await session.connect(ticket: elevenLabsTicket())
    try await session.setMicrophoneCaptureEnabled(true)
    try await session.setMicrophoneTransmissionEnabled(true)
    try await session.setMicrophoneTransmissionEnabled(false)
    try await session.setMicrophoneCaptureEnabled(false)

    #expect(await transport.muteValues() == [true, false, true])
}

@Test
func elevenLabsSessionReappliesMicrophoneStateAfterReconnect() async throws {
    let transport = RecordingElevenLabsConversationTransport()
    let session = ElevenLabsRealtimeSession(transport: transport)

    try await session.connect(ticket: elevenLabsTicket())
    try await session.setMicrophoneCaptureEnabled(true)
    try await session.setMicrophoneTransmissionEnabled(true)
    await session.disconnect()
    try await session.connect(ticket: elevenLabsTicket())

    #expect(await transport.muteValues() == [true, false, false])
}

@Test
func elevenLabsSessionForwardsContextInterruptAndToolResults() async throws {
    let transport = RecordingElevenLabsConversationTransport()
    let session = ElevenLabsRealtimeSession(transport: transport)
    let context = RealtimeDJContext(
        playback: PlaybackContext(),
        showPlanSummary: "专注工作，不主动长聊。",
        immediateUserInstruction: "少说点"
    )
    let result = RealtimeDJToolResult(
        callID: "tool-1",
        resultJSON: Data(#"{"ok":true}"#.utf8),
        isError: false
    )

    try await session.connect(ticket: elevenLabsTicket())
    try await session.updateContext(context)
    try await session.interrupt()
    try await session.requestAgentResponse("新歌已开始，请说一句开场词。")
    try await session.submitToolResult(result)
    await session.disconnect()

    let calls = await transport.recordedCalls()
    let updatedContext = try await transport.updatedContext()
    #expect(updatedContext == context)
    #expect(calls.contains(.interrupt))
    #expect(calls.contains(
        .requestAgentResponse("新歌已开始，请说一句开场词。")
    ))
    #expect(calls.contains(.toolResult(result)))
    #expect(calls.last == .disconnect)
}

private func elevenLabsTicket() throws -> RealtimeDJSessionTicket {
    let payload = try JSONEncoder().encode(ElevenLabsSessionPayload(
        conversationToken: "signed-token"
    ))
    return RealtimeDJSessionTicket(
        provider: .elevenLabs,
        sessionID: "eleven-1",
        expiresAt: Date(timeIntervalSinceNow: 600),
        providerPayload: payload
    )
}

private enum ElevenLabsTransportCall: Equatable, Sendable {
    case connect(ElevenLabsSessionPayload)
    case updateContext(Data)
    case setMuted(Bool)
    case interrupt
    case requestAgentResponse(String)
    case toolResult(RealtimeDJToolResult)
    case disconnect
}

private actor RecordingElevenLabsConversationTransport:
    ElevenLabsConversationTransport
{
    private let stream: AsyncStream<ProviderRealtimeEvent>
    private let continuation: AsyncStream<ProviderRealtimeEvent>.Continuation
    private var calls: [ElevenLabsTransportCall] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func eventStream() -> AsyncStream<ProviderRealtimeEvent> {
        stream
    }

    func connect(payload: ElevenLabsSessionPayload) {
        calls.append(.connect(payload))
    }

    func updateContext(_ context: Data) {
        calls.append(.updateContext(context))
    }

    func setMicrophoneMuted(_ muted: Bool) {
        calls.append(.setMuted(muted))
    }

    func interrupt() {
        calls.append(.interrupt)
    }

    func requestAgentResponse(_ instruction: String) {
        calls.append(.requestAgentResponse(instruction))
    }

    func submitToolResult(_ result: RealtimeDJToolResult) {
        calls.append(.toolResult(result))
    }

    func disconnect() {
        calls.append(.disconnect)
    }

    func emit(_ event: ProviderRealtimeEvent) {
        continuation.yield(event)
    }

    func connectedPayload() -> ElevenLabsSessionPayload? {
        for call in calls {
            if case let .connect(payload) = call {
                return payload
            }
        }
        return nil
    }

    func muteValues() -> [Bool] {
        calls.compactMap { call in
            if case let .setMuted(value) = call {
                return value
            }
            return nil
        }
    }

    func recordedCalls() -> [ElevenLabsTransportCall] {
        calls
    }

    func updatedContext() throws -> RealtimeDJContext? {
        for call in calls {
            if case let .updateContext(data) = call {
                return try JSONDecoder().decode(
                    RealtimeDJContext.self,
                    from: data
                )
            }
        }
        return nil
    }
}
