import ElevenLabs
import Foundation

enum ElevenLabsSDKTransportError: Error {
    case notConnected
    case invalidToolResult
}

@MainActor
final class ElevenLabsSDKConversationTransport:
    ElevenLabsConversationTransport
{
    private let events: AsyncStream<ProviderRealtimeEvent>
    private let eventContinuation:
        AsyncStream<ProviderRealtimeEvent>.Continuation

    private var conversation: Conversation?

    init() {
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    func eventStream() async -> AsyncStream<ProviderRealtimeEvent> {
        events
    }

    func connect(payload: ElevenLabsSessionPayload) async throws {
        eventContinuation.yield(ProviderRealtimeEvent(
            type: "connection.connecting"
        ))

        let continuation = eventContinuation
        let config = ConversationConfig(
            ttsOverrides: payload.voiceID.map {
                TTSOverrides(voiceId: $0)
            },
            onError: { error in
                continuation.yield(ProviderRealtimeEvent(
                    type: "error",
                    errorCode: "elevenlabs_sdk_error",
                    errorMessage: error.errorDescription,
                    recoverable: true
                ))
            },
            onAgentResponse: { text, _ in
                continuation.yield(ProviderRealtimeEvent(
                    type: "transcript.agent_final",
                    text: text
                ))
            },
            onUserTranscript: { text, _ in
                continuation.yield(ProviderRealtimeEvent(
                    type: "transcript.user_final",
                    text: text
                ))
            },
            onInterruption: { _ in
                continuation.yield(ProviderRealtimeEvent(
                    type: "conversation.interrupted"
                ))
            },
            onUnhandledClientToolCall: { toolCall in
                continuation.yield(ProviderRealtimeEvent(
                    type: "client_tool.call",
                    callID: toolCall.toolCallId,
                    name: toolCall.toolName,
                    argumentsJSON: toolCall.parametersData
                ))
            },
            agentStateConfiguration: .init(),
            onAgentStateChange: { state in
                let type = switch state {
                case .listening:
                    "agent.state.listening"
                case .speaking:
                    "agent.state.speaking"
                case .thinking:
                    "agent.state.thinking"
                }
                continuation.yield(ProviderRealtimeEvent(type: type))
            }
        )

        do {
            conversation = try await ElevenLabs.startConversation(
                conversationToken: payload.conversationToken,
                config: config,
                onAgentReady: {
                    continuation.yield(ProviderRealtimeEvent(
                        type: "connection.connected"
                    ))
                },
                onDisconnect: { _ in
                    continuation.yield(ProviderRealtimeEvent(
                        type: "connection.disconnected"
                    ))
                }
            )
        } catch {
            continuation.yield(ProviderRealtimeEvent(
                type: "error",
                errorCode: "elevenlabs_connection_failed",
                errorMessage: error.localizedDescription,
                recoverable: true
            ))
            throw error
        }
    }

    func updateContext(_ context: Data) async throws {
        guard let conversation else {
            throw ElevenLabsSDKTransportError.notConnected
        }
        try await conversation.updateContext(
            String(decoding: context, as: UTF8.self)
        )
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard let conversation else {
            throw ElevenLabsSDKTransportError.notConnected
        }
        try await conversation.setMicrophoneMuted(muted)
    }

    func interrupt() async throws {
        guard let conversation else {
            throw ElevenLabsSDKTransportError.notConnected
        }
        try await conversation.interruptAgent()
    }

    func submitToolResult(_ result: RealtimeDJToolResult) async throws {
        guard let conversation else {
            throw ElevenLabsSDKTransportError.notConnected
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: result.resultJSON,
            options: .fragmentsAllowed
        ) else {
            throw ElevenLabsSDKTransportError.invalidToolResult
        }
        try await conversation.sendToolResult(
            for: result.callID,
            result: object,
            isError: result.isError
        )
    }

    func disconnect() async {
        await conversation?.endConversation()
        conversation = nil
    }
}
