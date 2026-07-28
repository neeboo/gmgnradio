import Foundation

enum RealtimeDJTransport: String, Codable, Sendable {
    case streamingWebSocket
    case rtcRoom
}

enum RealtimeDJProvider: String, Codable, CaseIterable, Sendable {
    case bailian
    case doubao

    var capabilities: RealtimeDJCapabilities {
        switch self {
        case .bailian:
            RealtimeDJCapabilities(
                transport: .streamingWebSocket,
                serverVoiceActivityDetection: true,
                nativeInterruption: true,
                liveContextUpdates: true,
                clientTools: true
            )
        case .doubao:
            RealtimeDJCapabilities(
                transport: .rtcRoom,
                serverVoiceActivityDetection: true,
                nativeInterruption: true,
                liveContextUpdates: true,
                clientTools: true
            )
        }
    }
}

struct RealtimeDJCapabilities: Codable, Equatable, Sendable {
    let transport: RealtimeDJTransport
    let serverVoiceActivityDetection: Bool
    let nativeInterruption: Bool
    let liveContextUpdates: Bool
    let clientTools: Bool
}

struct RealtimeDJSessionTicket: Codable, Equatable, Sendable {
    let provider: RealtimeDJProvider
    let sessionID: String
    let expiresAt: Date
    let providerPayload: Data
}

struct RealtimeDJContext: Codable, Equatable, Sendable {
    var playback: PlaybackContext
    var showPlanSummary: String
    var immediateUserInstruction: String?

    init(
        playback: PlaybackContext,
        showPlanSummary: String,
        immediateUserInstruction: String? = nil
    ) {
        self.playback = playback
        self.showPlanSummary = showPlanSummary
        self.immediateUserInstruction = immediateUserInstruction
    }
}

enum RealtimeDJConnectionState: String, Codable, Sendable {
    case connecting
    case connected
    case recovering
    case disconnected
}

struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: Data
}

struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String
    let resultJSON: Data
    let isError: Bool
}

struct RealtimeDJFailure: Error, Codable, Equatable, Sendable {
    let code: String
    let message: String
    let recoverable: Bool
}

enum RealtimeDJEvent: Equatable, Sendable {
    case connectionChanged(RealtimeDJConnectionState)
    case userSpeechStarted
    case userSpeechFinished
    case userTranscriptDelta(String)
    case userTranscriptFinal(String)
    case agentResponseStarted
    case agentAudioStarted
    case agentAudioFinished
    case agentTranscriptDelta(String)
    case agentTranscriptFinal(String)
    case interrupted
    case toolCall(RealtimeDJToolCall)
    case failure(RealtimeDJFailure)
}

protocol RealtimeDJSession: Sendable {
    nonisolated var provider: RealtimeDJProvider { get }
    nonisolated var capabilities: RealtimeDJCapabilities { get }

    func eventStream() async -> AsyncStream<RealtimeDJEvent>
    func connect(ticket: RealtimeDJSessionTicket) async throws
    func updateContext(_ context: RealtimeDJContext) async throws
    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws
    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws
    func interrupt() async throws
    func submitToolResult(_ result: RealtimeDJToolResult) async throws
    func disconnect() async
}
