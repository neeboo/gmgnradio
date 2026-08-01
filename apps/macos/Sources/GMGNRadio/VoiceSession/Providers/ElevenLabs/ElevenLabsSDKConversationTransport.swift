import ElevenLabs
import Foundation
import LiveKit

enum ElevenLabsSDKTransportError: LocalizedError {
    case notConnected
    case invalidToolResult
    case missingCredential
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "ElevenLabs 实时会话尚未连接。"
        case .invalidToolResult:
            "DJ 工具结果格式无效。"
        case .missingCredential:
            "填写 ElevenLabs Agent ID、API Key 或会话令牌。"
        case let .connectionFailed(message):
            message
        }
    }
}

enum ElevenLabsConversationTokenError: LocalizedError {
    case invalidRequest
    case rejected(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "ElevenLabs 令牌请求地址无效。"
        case let .rejected(status):
            "ElevenLabs 密钥或 Agent ID 无效（HTTP \(status)）。"
        case .invalidResponse:
            "ElevenLabs 没有返回可用的会话令牌。"
        }
    }
}

struct ElevenLabsConversationTokenRequest: Sendable {
    private static let endpoint =
        "https://api.elevenlabs.io/v1/convai/conversation/token"

    func makeRequest(
        agentID: String,
        apiKey: String
    ) throws -> URLRequest {
        guard
            var components = URLComponents(string: Self.endpoint)
        else {
            throw ElevenLabsConversationTokenError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "agent_id", value: agentID),
            URLQueryItem(name: "source", value: "gmgn_radio"),
        ]
        guard let url = components.url else {
            throw ElevenLabsConversationTokenError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    func parse(
        _ data: Data,
        response: HTTPURLResponse
    ) throws -> String {
        guard response.statusCode == 200 else {
            throw ElevenLabsConversationTokenError.rejected(
                response.statusCode
            )
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let token = object["token"] as? String,
            !token.isEmpty
        else {
            throw ElevenLabsConversationTokenError.invalidResponse
        }
        return token
    }
}

@MainActor
final class ElevenLabsSDKConversationTransport:
    ElevenLabsConversationTransport
{
    private let events: AsyncStream<ProviderRealtimeEvent>
    private let eventContinuation:
        AsyncStream<ProviderRealtimeEvent>.Continuation

    private var conversation: Conversation?
    private var observedAudioTrack: RemoteAudioTrack?
    private let tokenRequest = ElevenLabsConversationTokenRequest()
    private lazy var audioLevelRenderer = ElevenLabsAudioLevelRenderer {
        [eventContinuation] level in
        eventContinuation.yield(ProviderRealtimeEvent(
            type: "audio.agent.level",
            rms: level.rms,
            peak: level.peak
        ))
    }

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
            onVadScore: { score in
                continuation.yield(ProviderRealtimeEvent(
                    type: "audio.user.vad",
                    rms: score,
                    peak: score
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
            let onAgentReady: @Sendable () -> Void = {
                continuation.yield(ProviderRealtimeEvent(
                    type: "connection.connected"
                ))
            }
            let onDisconnect: @Sendable (DisconnectionReason) -> Void = { _ in
                continuation.yield(ProviderRealtimeEvent(
                    type: "connection.disconnected"
                ))
            }
            let startedConversation: Conversation
            if let conversationToken = try await conversationToken(
                for: payload
            ) {
                startedConversation = try await ElevenLabs.startConversation(
                    conversationToken: conversationToken,
                    config: config,
                    onAgentReady: onAgentReady,
                    onDisconnect: onDisconnect
                )
            } else if let agentID = payload.agentID, !agentID.isEmpty {
                startedConversation = try await ElevenLabs.startConversation(
                    agentId: agentID,
                    config: config,
                    onAgentReady: onAgentReady,
                    onDisconnect: onDisconnect
                )
            } else {
                throw ElevenLabsSDKTransportError.missingCredential
            }
            conversation = startedConversation
            if let track = startedConversation.agentAudioTrack {
                track.add(audioRenderer: audioLevelRenderer)
                observedAudioTrack = track
            }
        } catch {
            let message = friendlyMessage(for: error)
            continuation.yield(ProviderRealtimeEvent(
                type: "error",
                errorCode: "elevenlabs_connection_failed",
                errorMessage: message,
                recoverable: true
            ))
            throw ElevenLabsSDKTransportError.connectionFailed(message)
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

    func requestAgentResponse(_ instruction: String) async throws {
        guard let conversation else {
            throw ElevenLabsSDKTransportError.notConnected
        }
        try await conversation.sendMessage(instruction)
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
        if let observedAudioTrack {
            observedAudioTrack.remove(audioRenderer: audioLevelRenderer)
            self.observedAudioTrack = nil
        }
        await conversation?.endConversation()
        conversation = nil
    }

    private func conversationToken(
        for payload: ElevenLabsSessionPayload
    ) async throws -> String? {
        if
            let token = payload.conversationToken,
            !token.isEmpty
        {
            return token
        }
        guard
            let apiKey = payload.apiKey,
            !apiKey.isEmpty
        else {
            return nil
        }
        guard
            let agentID = payload.agentID,
            !agentID.isEmpty
        else {
            throw ElevenLabsSDKTransportError.missingCredential
        }
        let request = try tokenRequest.makeRequest(
            agentID: agentID,
            apiKey: apiKey
        )
        let (data, response) = try await URLSession.shared.data(
            for: request
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsConversationTokenError.invalidResponse
        }
        return try tokenRequest.parse(
            data,
            response: httpResponse
        )
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        let description = error.localizedDescription
        if description.contains("HTTP error: 400") {
            return "ElevenLabs Agent ID 无效，或该 Agent 未公开。"
        }
        if description.contains("HTTP error: 401") {
            return "ElevenLabs API Key 无效。"
        }
        return description
    }
}
