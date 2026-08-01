import Foundation

struct RealtimeDJSessionSnapshot: Equatable, Sendable {
    let generation: UInt64
    let provider: RealtimeDJProvider
    let sessionID: String
}

enum RealtimeDJSessionControllerError: Error, Equatable {
    case providerMismatch(
        expected: RealtimeDJProvider,
        actual: RealtimeDJProvider
    )
    case noActiveSession
}

actor RealtimeDJSessionController {
    private struct ActiveSession {
        let generation: UInt64
        let session: any RealtimeDJSession
        let ticket: RealtimeDJSessionTicket
    }

    private var generation: UInt64 = 0
    private var activeSession: ActiveSession?
    private var forwardingTask: Task<Void, Never>?
    private var agentResponseActive = false
    private var pendingHostInstructions: [String] = []

    private let events: AsyncStream<RealtimeDJEvent>
    private let eventContinuation: AsyncStream<RealtimeDJEvent>.Continuation

    init() {
        let stream = AsyncStream<RealtimeDJEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func eventStream() -> AsyncStream<RealtimeDJEvent> {
        events
    }

    @discardableResult
    func activate(
        _ session: any RealtimeDJSession,
        ticket: RealtimeDJSessionTicket
    ) async throws -> RealtimeDJSessionSnapshot {
        guard session.provider == ticket.provider else {
            throw RealtimeDJSessionControllerError.providerMismatch(
                expected: ticket.provider,
                actual: session.provider
            )
        }

        generation &+= 1
        let nextGeneration = generation

        forwardingTask?.cancel()
        forwardingTask = nil

        if let previousSession = activeSession?.session {
            activeSession = nil
            await previousSession.disconnect()
        }
        agentResponseActive = false
        pendingHostInstructions.removeAll(keepingCapacity: true)

        do {
            try await session.connect(ticket: ticket)
        } catch {
            await session.disconnect()
            throw error
        }

        activeSession = ActiveSession(
            generation: nextGeneration,
            session: session,
            ticket: ticket
        )

        let providerEvents = await session.eventStream()
        forwardingTask = Task { [weak self] in
            for await event in providerEvents {
                guard !Task.isCancelled else {
                    break
                }
                await self?.forward(
                    event,
                    fromGeneration: nextGeneration
                )
            }
        }

        return RealtimeDJSessionSnapshot(
            generation: nextGeneration,
            provider: ticket.provider,
            sessionID: ticket.sessionID
        )
    }

    func updateContext(_ context: RealtimeDJContext) async throws {
        try await requireActiveSession().updateContext(context)
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws {
        try await requireActiveSession().setMicrophoneCaptureEnabled(enabled)
    }

    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws {
        try await requireActiveSession().setMicrophoneTransmissionEnabled(enabled)
    }

    func interrupt() async throws {
        try await requireActiveSession().interrupt()
    }

    func requestAgentResponse(_ instruction: String) async throws {
        guard !agentResponseActive else {
            pendingHostInstructions.append(instruction)
            return
        }
        agentResponseActive = true
        do {
            try await requireActiveSession()
                .requestAgentResponse(instruction)
        } catch {
            agentResponseActive = false
            throw error
        }
    }

    func submitToolResult(_ result: RealtimeDJToolResult) async throws {
        try await requireActiveSession().submitToolResult(result)
    }

    func deactivate() async {
        generation &+= 1
        forwardingTask?.cancel()
        forwardingTask = nil

        let session = activeSession?.session
        activeSession = nil
        agentResponseActive = false
        pendingHostInstructions.removeAll(keepingCapacity: true)
        await session?.disconnect()
    }

    private func requireActiveSession() throws -> any RealtimeDJSession {
        guard let session = activeSession?.session else {
            throw RealtimeDJSessionControllerError.noActiveSession
        }
        return session
    }

    private func forward(
        _ event: RealtimeDJEvent,
        fromGeneration eventGeneration: UInt64
    ) async {
        guard activeSession?.generation == eventGeneration else {
            return
        }
        switch event {
        case .agentResponseStarted:
            agentResponseActive = true
        case .agentAudioFinished:
            agentResponseActive = false
        case .failure, .connectionChanged(.disconnected):
            agentResponseActive = false
            pendingHostInstructions.removeAll(keepingCapacity: true)
        default:
            break
        }
        eventContinuation.yield(event)
        if event == .agentAudioFinished {
            await startNextPendingHostResponse()
        }
    }

    private func startNextPendingHostResponse() async {
        guard
            !agentResponseActive,
            !pendingHostInstructions.isEmpty
        else {
            return
        }
        let instruction = pendingHostInstructions.removeFirst()
        agentResponseActive = true
        do {
            try await requireActiveSession()
                .requestAgentResponse(instruction)
        } catch {
            agentResponseActive = false
            eventContinuation.yield(.failure(RealtimeDJFailure(
                code: "host_response_failed",
                message: error.localizedDescription,
                recoverable: true
            )))
        }
    }
}
