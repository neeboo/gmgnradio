import Foundation
import Testing
@testable import GMGNRadio

@Test
func activatingANewProviderDisconnectsTheOldSessionAndAdvancesGeneration() async throws {
    let controller = RealtimeDJSessionController()
    let bailian = RecordingRealtimeDJSession(provider: .bailian)
    let doubao = RecordingRealtimeDJSession(provider: .doubao)

    let first = try await controller.activate(
        bailian,
        ticket: ticket(provider: .bailian, sessionID: "bailian-1")
    )
    let second = try await controller.activate(
        doubao,
        ticket: ticket(provider: .doubao, sessionID: "doubao-1")
    )

    #expect(first.generation == 1)
    #expect(second.generation == 2)
    #expect(second.provider == .doubao)
    #expect(await bailian.calls().contains(.disconnect))
}

@Test
func staleSessionEventsAreDroppedAfterProviderSwitch() async throws {
    let controller = RealtimeDJSessionController()
    let bailian = RecordingRealtimeDJSession(provider: .bailian)
    let doubao = RecordingRealtimeDJSession(provider: .doubao)
    var iterator = await controller.eventStream().makeAsyncIterator()

    try await controller.activate(
        bailian,
        ticket: ticket(provider: .bailian, sessionID: "bailian-1")
    )
    try await controller.activate(
        doubao,
        ticket: ticket(provider: .doubao, sessionID: "doubao-1")
    )

    await bailian.emit(.agentTranscriptFinal("旧会话迟到内容"))
    await doubao.emit(.agentTranscriptFinal("当前会话内容"))

    let event = await iterator.next()
    #expect(event == .agentTranscriptFinal("当前会话内容"))
}

@Test
func realtimeCommandsOnlyReachTheActiveSession() async throws {
    let controller = RealtimeDJSessionController()
    let session = RecordingRealtimeDJSession(provider: .doubao)
    let context = RealtimeDJContext(
        playback: PlaybackContext(),
        showPlanSummary: "安静的工作时段",
        immediateUserInstruction: "少说一点"
    )
    let result = RealtimeDJToolResult(
        callID: "call-1",
        resultJSON: Data(#"{"ok":true}"#.utf8),
        isError: false
    )

    try await controller.activate(
        session,
        ticket: ticket(provider: .doubao, sessionID: "doubao-1")
    )
    try await controller.updateContext(context)
    try await controller.setMicrophoneCaptureEnabled(true)
    try await controller.setMicrophoneTransmissionEnabled(false)
    try await controller.interrupt()
    try await controller.submitToolResult(result)

    #expect(await session.calls() == [
        .connect("doubao-1"),
        .updateContext(context),
        .setCapture(true),
        .setTransmission(false),
        .interrupt,
        .submitToolResult(result),
    ])
}

private func ticket(
    provider: RealtimeDJProvider,
    sessionID: String
) -> RealtimeDJSessionTicket {
    RealtimeDJSessionTicket(
        provider: provider,
        sessionID: sessionID,
        expiresAt: Date(timeIntervalSinceNow: 600),
        providerPayload: Data()
    )
}

private enum RecordingSessionCall: Equatable, Sendable {
    case connect(String)
    case updateContext(RealtimeDJContext)
    case setCapture(Bool)
    case setTransmission(Bool)
    case interrupt
    case submitToolResult(RealtimeDJToolResult)
    case disconnect
}

private actor RecordingRealtimeDJSession: RealtimeDJSession {
    nonisolated let provider: RealtimeDJProvider
    nonisolated let capabilities: RealtimeDJCapabilities

    private let stream: AsyncStream<RealtimeDJEvent>
    private let continuation: AsyncStream<RealtimeDJEvent>.Continuation
    private var recordedCalls: [RecordingSessionCall] = []

    init(provider: RealtimeDJProvider) {
        self.provider = provider
        capabilities = provider.capabilities
        (stream, continuation) = AsyncStream.makeStream()
    }

    func eventStream() -> AsyncStream<RealtimeDJEvent> {
        stream
    }

    func connect(ticket: RealtimeDJSessionTicket) {
        recordedCalls.append(.connect(ticket.sessionID))
    }

    func updateContext(_ context: RealtimeDJContext) {
        recordedCalls.append(.updateContext(context))
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        recordedCalls.append(.setCapture(enabled))
    }

    func setMicrophoneTransmissionEnabled(_ enabled: Bool) {
        recordedCalls.append(.setTransmission(enabled))
    }

    func interrupt() {
        recordedCalls.append(.interrupt)
    }

    func submitToolResult(_ result: RealtimeDJToolResult) {
        recordedCalls.append(.submitToolResult(result))
    }

    func disconnect() {
        recordedCalls.append(.disconnect)
    }

    func emit(_ event: RealtimeDJEvent) {
        continuation.yield(event)
    }

    func calls() -> [RecordingSessionCall] {
        recordedCalls
    }
}
