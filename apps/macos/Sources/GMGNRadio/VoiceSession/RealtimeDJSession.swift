import Foundation

enum RealtimeDJTransport: String, Codable, Sendable {
    case streamingWebSocket
    case rtcRoom
    case webRTC
}

enum RealtimeDJProvider: String, Codable, CaseIterable, Sendable {
    case bailian
    case doubao
    case elevenLabs = "elevenlabs"

    var capabilities: RealtimeDJCapabilities {
        switch self {
        case .bailian:
            RealtimeDJCapabilities(
                transport: .streamingWebSocket,
                serverVoiceActivityDetection: true,
                nativeInterruption: true,
                liveContextUpdates: true,
                clientTools: true,
                independentMicrophoneCaptureAndTransmission: true
            )
        case .doubao:
            RealtimeDJCapabilities(
                transport: .rtcRoom,
                serverVoiceActivityDetection: true,
                nativeInterruption: true,
                liveContextUpdates: true,
                clientTools: true,
                independentMicrophoneCaptureAndTransmission: true
            )
        case .elevenLabs:
            RealtimeDJCapabilities(
                transport: .webRTC,
                serverVoiceActivityDetection: true,
                nativeInterruption: true,
                liveContextUpdates: true,
                clientTools: true,
                independentMicrophoneCaptureAndTransmission: false
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
    let independentMicrophoneCaptureAndTransmission: Bool
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
    var hostHint: ProgramHostHint?
    var immediateUserInstruction: String?

    init(
        playback: PlaybackContext,
        showPlanSummary: String,
        hostHint: ProgramHostHint? = nil,
        immediateUserInstruction: String? = nil
    ) {
        self.playback = playback
        self.showPlanSummary = showPlanSummary
        self.hostHint = hostHint
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

struct ProviderRealtimeEvent: Equatable, Sendable {
    let type: String
    let text: String?
    let callID: String?
    let name: String?
    let argumentsJSON: Data?
    let errorCode: String?
    let errorMessage: String?
    let recoverable: Bool?
    let rms: Double?
    let peak: Double?

    init(
        type: String,
        text: String? = nil,
        callID: String? = nil,
        name: String? = nil,
        argumentsJSON: Data? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        recoverable: Bool? = nil,
        rms: Double? = nil,
        peak: Double? = nil
    ) {
        self.type = type
        self.text = text
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.recoverable = recoverable
        self.rms = rms
        self.peak = peak
    }
}

struct RealtimeDJAudioLevel: Codable, Equatable, Sendable {
    let rms: Double
    let peak: Double

    init(rms: Double, peak: Double) {
        self.rms = min(1, max(0, rms))
        self.peak = min(1, max(0, peak))
    }
}

enum RealtimeDJEvent: Equatable, Sendable {
    case connectionChanged(RealtimeDJConnectionState)
    case userSpeechStarted
    case userSpeechFinished
    case userTranscriptDelta(String)
    case userTranscriptFinal(String)
    case agentResponseStarted
    case agentAudioStarted
    case agentAudioLevel(RealtimeDJAudioLevel)
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
