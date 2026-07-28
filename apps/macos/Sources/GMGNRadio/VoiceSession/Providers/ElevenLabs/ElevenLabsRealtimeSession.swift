import Foundation

struct ElevenLabsSessionPayload: Codable, Equatable, Sendable {
    let conversationToken: String
    let voiceID: String?

    init(
        conversationToken: String,
        voiceID: String? = nil
    ) {
        self.conversationToken = conversationToken
        self.voiceID = voiceID
    }
}

protocol ElevenLabsConversationTransport: Sendable {
    func eventStream() async -> AsyncStream<ProviderRealtimeEvent>
    func connect(payload: ElevenLabsSessionPayload) async throws
    func updateContext(_ context: Data) async throws
    func setMicrophoneMuted(_ muted: Bool) async throws
    func interrupt() async throws
    func submitToolResult(_ result: RealtimeDJToolResult) async throws
    func disconnect() async
}

actor ElevenLabsRealtimeSession: RealtimeDJSession {
    nonisolated let provider = RealtimeDJProvider.elevenLabs
    nonisolated let capabilities = RealtimeDJProvider.elevenLabs.capabilities

    private let transport: any ElevenLabsConversationTransport
    private let events: AsyncStream<RealtimeDJEvent>
    private let eventContinuation: AsyncStream<RealtimeDJEvent>.Continuation

    private var mapper = ElevenLabsRealtimeEventMapper()
    private var forwardingTask: Task<Void, Never>?
    private var microphoneCaptureEnabled = false
    private var microphoneTransmissionEnabled = false
    private var microphoneMuted: Bool?

    init(transport: any ElevenLabsConversationTransport) {
        self.transport = transport
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    @MainActor
    static func live() -> ElevenLabsRealtimeSession {
        ElevenLabsRealtimeSession(
            transport: ElevenLabsSDKConversationTransport()
        )
    }

    func eventStream() -> AsyncStream<RealtimeDJEvent> {
        events
    }

    func connect(ticket: RealtimeDJSessionTicket) async throws {
        let payload = try JSONDecoder().decode(
            ElevenLabsSessionPayload.self,
            from: ticket.providerPayload
        )
        let providerEvents = await transport.eventStream()

        try await transport.connect(payload: payload)
        try await syncMicrophoneMute()

        forwardingTask?.cancel()
        forwardingTask = Task { [weak self] in
            for await event in providerEvents {
                guard !Task.isCancelled else { break }
                await self?.forward(event)
            }
        }
    }

    func updateContext(_ context: RealtimeDJContext) async throws {
        try await transport.updateContext(JSONEncoder().encode(context))
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws {
        microphoneCaptureEnabled = enabled
        try await syncMicrophoneMute()
    }

    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws {
        microphoneTransmissionEnabled = enabled
        try await syncMicrophoneMute()
    }

    func interrupt() async throws {
        try await transport.interrupt()
    }

    func submitToolResult(_ result: RealtimeDJToolResult) async throws {
        try await transport.submitToolResult(result)
    }

    func disconnect() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        microphoneMuted = nil
        await transport.disconnect()
    }

    private func syncMicrophoneMute() async throws {
        let shouldMute = !microphoneCaptureEnabled
            || !microphoneTransmissionEnabled
        guard microphoneMuted != shouldMute else { return }
        try await transport.setMicrophoneMuted(shouldMute)
        microphoneMuted = shouldMute
    }

    private func forward(_ event: ProviderRealtimeEvent) {
        for normalizedEvent in mapper.map(event) {
            eventContinuation.yield(normalizedEvent)
        }
    }
}
