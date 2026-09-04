import Foundation
import os

struct BailianSessionPayload: Codable, Equatable, Sendable {
    let apiKey: String
    let model: String
    let voiceID: String
    let microphoneDeviceID: String?

    init(
        apiKey: String,
        model: String,
        voiceID: String,
        microphoneDeviceID: String? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voiceID = voiceID
        self.microphoneDeviceID = microphoneDeviceID
    }
}

struct BailianDecodedMessage: Equatable, Sendable {
    let event: ProviderRealtimeEvent
    let audio: Data?
}

enum BailianRealtimeWireProtocolError: LocalizedError {
    case invalidEndpoint
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "百炼实时语音地址无效。"
        case .invalidMessage:
            "百炼返回了无法识别的实时消息。"
        }
    }
}

enum BailianRealtimeWireProtocol {
    private static let endpoint =
        "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

    static func makeRequest(
        payload: BailianSessionPayload
    ) throws -> URLRequest {
        guard
            var components = URLComponents(string: endpoint)
        else {
            throw BailianRealtimeWireProtocolError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: payload.model)
        ]
        guard let url = components.url else {
            throw BailianRealtimeWireProtocolError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(payload.apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    static func sessionUpdateData(
        payload: BailianSessionPayload,
        instructions: String,
        providerTools: [[String: Any]] = DJAgentCapabilityManifest.providerTools
    ) throws -> Data {
        let vadType = payload.model.hasPrefix("qwen3.5-")
            ? "semantic_vad"
            : "server_vad"
        return try JSONSerialization.data(withJSONObject: [
            "event_id": eventID(),
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": payload.voiceID,
                "instructions": instructions,
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
                "max_tokens": 256,
                "input_audio_transcription": [
                    "model": "qwen3-asr-flash-realtime"
                ],
                "turn_detection": [
                    "type": vadType,
                    "threshold": 0.5,
                    "silence_duration_ms": 650,
                ],
                "tools": providerTools,
            ],
        ])
    }

    static func inputAudioData(_ audio: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "event_id": eventID(),
            "type": "input_audio_buffer.append",
            "audio": audio.base64EncodedString(),
        ])
    }

    static func responseCancelData() throws -> Data {
        try simpleEventData(type: "response.cancel")
    }

    static func clearInputData() throws -> Data {
        try simpleEventData(type: "input_audio_buffer.clear")
    }

    static func interruptionData(
        agentResponseActive: Bool
    ) throws -> [Data] {
        guard agentResponseActive else {
            return []
        }
        return [try responseCancelData()]
    }

    static func toolResultData(
        _ result: RealtimeDJToolResult
    ) throws -> Data {
        let output = String(
            decoding: result.resultJSON,
            as: UTF8.self
        )
        return try JSONSerialization.data(withJSONObject: [
            "event_id": eventID(),
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": result.callID,
                "output": output,
            ],
        ])
    }

    static func instructionData(_ instruction: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "event_id": eventID(),
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": instruction,
                    ],
                ],
            ],
        ])
    }

    static func responseCreateData() throws -> Data {
        try simpleEventData(type: "response.create")
    }

    static func decode(_ data: Data) throws -> BailianDecodedMessage {
        guard
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let type = object["type"] as? String
        else {
            throw BailianRealtimeWireProtocolError.invalidMessage
        }

        let text: String? = switch type {
        case "conversation.item.input_audio_transcription.delta":
            (object["text"] as? String ?? "")
                + (object["stash"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed",
             "response.audio_transcript.done":
            object["transcript"] as? String
        case "response.audio_transcript.delta",
             "response.text.delta":
            object["delta"] as? String
        default:
            nil
        }

        let error = object["error"] as? [String: Any]
        let arguments = object["arguments"] as? String
        let audio = (object["delta"] as? String)
            .flatMap { Data(base64Encoded: $0) }
        let event = ProviderRealtimeEvent(
            type: type,
            text: text,
            callID: object["call_id"] as? String,
            name: object["name"] as? String,
            argumentsJSON: arguments.map { Data($0.utf8) },
            errorCode: error?["code"] as? String,
            errorMessage: error?["message"] as? String,
            recoverable: type == "error"
        )
        return BailianDecodedMessage(
            event: event,
            audio: type == "response.audio.delta" ? audio : nil
        )
    }

    private static func simpleEventData(type: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "event_id": eventID(),
            "type": type,
        ])
    }

    private static func eventID() -> String {
        let identifier = UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        )
        return "event_\(identifier)"
    }
}

protocol BailianRealtimeTransport: Sendable {
    func eventStream() async -> AsyncStream<ProviderRealtimeEvent>
    func connect(payload: BailianSessionPayload) async throws
    func updateContext(_ context: Data) async throws
    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws
    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws
    func interrupt() async throws
    func requestAgentResponse(_ instruction: String) async throws
    func submitToolResult(_ result: RealtimeDJToolResult) async throws
    func disconnect() async
}

struct BailianPCMChunkAccumulator: Sendable {
    private let targetByteCount: Int
    private var pending = Data()

    init(targetByteCount: Int = 3_200) {
        self.targetByteCount = targetByteCount
    }

    var pendingByteCount: Int {
        pending.count
    }

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= targetByteCount {
            frames.append(Data(pending.prefix(targetByteCount)))
            pending.removeFirst(targetByteCount)
        }
        return frames
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}

struct BailianMicrophoneEchoGate: Sendable {
    private static let bytesPerSecond = 24_000 * MemoryLayout<Int16>.size

    private let tailDuration: TimeInterval
    private var playbackEndsAt = Date.distantPast

    init(tailDuration: TimeInterval = 0.35) {
        self.tailDuration = tailDuration
    }

    mutating func noteAgentAudio(
        byteCount: Int,
        now: Date = Date()
    ) {
        let duration = TimeInterval(byteCount)
            / TimeInterval(Self.bytesPerSecond)
        playbackEndsAt = max(playbackEndsAt, now)
            .addingTimeInterval(duration)
    }

    mutating func finishAgentResponse(now: Date = Date()) {
        playbackEndsAt = max(playbackEndsAt, now)
            .addingTimeInterval(tailDuration)
    }

    func allowsTransmission(now: Date = Date()) -> Bool {
        now >= playbackEndsAt
    }

    mutating func reset() {
        playbackEndsAt = .distantPast
    }
}

enum BailianRealtimeTransportError: LocalizedError {
    case notConnected
    case connectionClosed
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "百炼实时语音尚未连接。"
        case .connectionClosed:
            "百炼实时语音连接已断开。"
        case let .serverRejected(message):
            message.isEmpty
                ? "百炼拒绝了实时语音连接，请检查 API Key。"
                : "百炼实时语音连接失败：\(message)"
        }
    }
}

@MainActor
final class BailianWebSocketRealtimeTransport:
    BailianRealtimeTransport
{
    private let audioGraph: AudioGraphController
    private let providerTools: [[String: Any]]
    private let promptBuilder = DJRealtimePromptBuilder()
    private let logger = Logger(
        subsystem: ProductIdentity.bundleIdentifier,
        category: "BailianRealtime"
    )
    private let events: AsyncStream<ProviderRealtimeEvent>
    private let eventContinuation:
        AsyncStream<ProviderRealtimeEvent>.Continuation

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var payload: BailianSessionPayload?
    private var connected = false
    private var microphoneCaptureEnabled = false
    private var microphoneTransmissionEnabled = false
    private var microphoneChunkCount = 0
    private var microphonePCM = BailianPCMChunkAccumulator()
    private var agentResponseActive = false
    private var microphoneEchoGate = BailianMicrophoneEchoGate()

    init(
        audioGraph: AudioGraphController,
        providerTools: [[String: Any]] = DJAgentCapabilityManifest.providerTools
    ) {
        self.audioGraph = audioGraph
        self.providerTools = providerTools
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    func eventStream() async -> AsyncStream<ProviderRealtimeEvent> {
        events
    }

    func connect(payload: BailianSessionPayload) async throws {
        await disconnect()
        self.payload = payload
        eventContinuation.yield(ProviderRealtimeEvent(
            type: "connection.connecting"
        ))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(
            with: try BailianRealtimeWireProtocol.makeRequest(
                payload: payload
            )
        )
        urlSession = session
        webSocketTask = task
        task.resume()

        do {
            try await send(
                BailianRealtimeWireProtocol.sessionUpdateData(
                    payload: payload,
                    instructions: try promptBuilder.build(context: nil),
                    providerTools: providerTools
                ),
                through: task
            )

            while true {
                let decoded = try await receive(from: task)
                try process(decoded)
                if decoded.event.type == "session.updated" {
                    connected = true
                    logger.info("Realtime session configured")
                    eventContinuation.yield(ProviderRealtimeEvent(
                        type: "connection.connected"
                    ))
                    break
                }
                if decoded.event.type == "error" {
                    throw BailianRealtimeTransportError.serverRejected(
                        decoded.event.errorMessage ?? ""
                    )
                }
            }

            receiveTask = Task { [weak self, weak task] in
                guard let self, let task else {
                    return
                }
                await self.receiveLoop(task)
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    func updateContext(_ context: Data) async throws {
        guard let payload else {
            throw BailianRealtimeTransportError.notConnected
        }
        let realtimeContext = try JSONDecoder().decode(
            RealtimeDJContext.self,
            from: context
        )
        let instructions = try promptBuilder.build(
            context: realtimeContext
        )
        try await send(
            BailianRealtimeWireProtocol.sessionUpdateData(
                payload: payload,
                instructions: instructions,
                providerTools: providerTools
            )
        )
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws {
        guard enabled != microphoneCaptureEnabled else {
            return
        }
        if enabled {
            try audioGraph.startBailianMicrophoneCapture(
                preferredDeviceID: payload?.microphoneDeviceID
            ) {
                [weak self] data, level in
                Task { @MainActor [weak self] in
                    await self?.handleMicrophoneData(
                        data,
                        level: level
                    )
                }
            }
        } else {
            audioGraph.stopBailianMicrophoneCapture()
        }
        microphoneCaptureEnabled = enabled
    }

    func setMicrophoneTransmissionEnabled(
        _ enabled: Bool
    ) async throws {
        microphoneTransmissionEnabled = enabled
    }

    func interrupt() async throws {
        guard connected else {
            throw BailianRealtimeTransportError.notConnected
        }
        audioGraph.stopDJVoice()
        for data in try BailianRealtimeWireProtocol.interruptionData(
            agentResponseActive: agentResponseActive
        ) {
            try await send(data)
        }
        agentResponseActive = false
        microphoneEchoGate.reset()
    }

    func requestAgentResponse(_ instruction: String) async throws {
        guard connected else {
            throw BailianRealtimeTransportError.notConnected
        }
        try await send(
            BailianRealtimeWireProtocol.instructionData(instruction)
        )
        try await send(
            BailianRealtimeWireProtocol.responseCreateData()
        )
    }

    func submitToolResult(
        _ result: RealtimeDJToolResult
    ) async throws {
        try await send(
            BailianRealtimeWireProtocol.toolResultData(result)
        )
        try await send(
            BailianRealtimeWireProtocol.responseCreateData()
        )
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        audioGraph.stopBailianMicrophoneCapture()
        audioGraph.stopDJVoice()
        microphoneCaptureEnabled = false
        microphoneTransmissionEnabled = false
        microphonePCM.reset()
        agentResponseActive = false
        microphoneEchoGate.reset()
        connected = false
        payload = nil

        webSocketTask?.cancel(
            with: .goingAway,
            reason: nil
        )
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func handleMicrophoneData(
        _ data: Data,
        level: RealtimeDJAudioLevel
    ) async {
        eventContinuation.yield(ProviderRealtimeEvent(
            type: "audio.user.level",
            rms: level.rms,
            peak: level.peak
        ))
        microphoneChunkCount += 1
        if microphoneChunkCount.isMultiple(of: 50) {
            logger.info(
                "Microphone streaming chunks=\(self.microphoneChunkCount) peak=\(level.peak)"
            )
        }
        guard
            connected,
            microphoneTransmissionEnabled,
            !agentResponseActive,
            microphoneEchoGate.allowsTransmission()
        else {
            return
        }
        for frame in microphonePCM.append(data) {
            do {
                try await send(
                    BailianRealtimeWireProtocol.inputAudioData(frame)
                )
            } catch {
                failConnection(error)
                return
            }
        }
    }

    private func receiveLoop(
        _ task: URLSessionWebSocketTask
    ) async {
        do {
            while !Task.isCancelled {
                let decoded = try await receive(from: task)
                try process(decoded)
                if decoded.event.type == "error" {
                    throw BailianRealtimeTransportError.serverRejected(
                        decoded.event.errorMessage ?? ""
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            failConnection(error)
        }
    }

    private func process(
        _ decoded: BailianDecodedMessage
    ) throws {
        if ![
            "response.audio.delta",
            "response.audio_transcript.delta",
            "conversation.item.input_audio_transcription.delta",
        ].contains(decoded.event.type) {
            logger.info(
                "Server event \(decoded.event.type, privacy: .public)"
            )
        }
        if decoded.event.type == "input_audio_buffer.speech_started" {
            audioGraph.stopDJVoice()
        }
        switch decoded.event.type {
        case "response.created", "response.audio.delta":
            agentResponseActive = true
        case "response.done":
            agentResponseActive = false
            microphoneEchoGate.finishAgentResponse()
        case "response.cancelled", "response.interrupted":
            agentResponseActive = false
            microphoneEchoGate.reset()
        default:
            break
        }
        if let audio = decoded.audio {
            microphoneEchoGate.noteAgentAudio(
                byteCount: audio.count
            )
            try audioGraph.playBailianVoicePCM(audio)
            let level = BailianPCMCodec.audioLevel(for: audio)
            eventContinuation.yield(ProviderRealtimeEvent(
                type: "audio.agent.level",
                rms: level.rms,
                peak: level.peak
            ))
        }
        if decoded.event.type == "response.done" {
            let doneEvent = decoded.event
            Task { [weak self] in
                guard let self else {
                    return
                }
                await audioGraph.waitForDJVoiceDrain()
                logger.info(
                    "本地口播播放完毕，转发 response.done"
                )
                eventContinuation.yield(doneEvent)
            }
        } else {
            eventContinuation.yield(decoded.event)
        }
    }

    private func failConnection(_ error: Error) {
        guard connected else {
            return
        }
        connected = false
        agentResponseActive = false
        microphoneEchoGate.reset()
        audioGraph.stopBailianMicrophoneCapture()
        audioGraph.stopDJVoice()
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        logger.error(
            "Realtime connection failed: \(message, privacy: .public)"
        )
        eventContinuation.yield(ProviderRealtimeEvent(
            type: "error",
            errorCode: "bailian_connection_closed",
            errorMessage: message,
            recoverable: true
        ))
        eventContinuation.yield(ProviderRealtimeEvent(
            type: "connection.disconnected"
        ))
    }

    private func receive(
        from task: URLSessionWebSocketTask
    ) async throws -> BailianDecodedMessage {
        let message = try await task.receive()
        let data: Data = switch message {
        case let .data(data):
            data
        case let .string(text):
            Data(text.utf8)
        @unknown default:
            throw BailianRealtimeWireProtocolError.invalidMessage
        }
        return try BailianRealtimeWireProtocol.decode(data)
    }

    private func send(_ data: Data) async throws {
        guard connected, let webSocketTask else {
            throw BailianRealtimeTransportError.notConnected
        }
        try await send(data, through: webSocketTask)
    }

    private func send(
        _ data: Data,
        through task: URLSessionWebSocketTask
    ) async throws {
        try await task.send(
            .string(String(decoding: data, as: UTF8.self))
        )
    }
}

actor BailianRealtimeSession: RealtimeDJSession {
    nonisolated let provider = RealtimeDJProvider.bailian
    nonisolated let capabilities =
        RealtimeDJProvider.bailian.capabilities

    private let transport: any BailianRealtimeTransport
    private let events: AsyncStream<RealtimeDJEvent>
    private let eventContinuation:
        AsyncStream<RealtimeDJEvent>.Continuation
    private var mapper = BailianRealtimeEventMapper()
    private var forwardingTask: Task<Void, Never>?

    init(transport: any BailianRealtimeTransport) {
        self.transport = transport
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    @MainActor
    static func live(
        audioGraph: AudioGraphController,
        providerTools: [[String: Any]] = DJAgentCapabilityManifest.providerTools
    ) -> BailianRealtimeSession {
        BailianRealtimeSession(
            transport: BailianWebSocketRealtimeTransport(
                audioGraph: audioGraph,
                providerTools: providerTools
            )
        )
    }

    func eventStream() -> AsyncStream<RealtimeDJEvent> {
        events
    }

    func connect(ticket: RealtimeDJSessionTicket) async throws {
        let payload = try JSONDecoder().decode(
            BailianSessionPayload.self,
            from: ticket.providerPayload
        )
        let providerEvents = await transport.eventStream()
        try await transport.connect(payload: payload)

        forwardingTask?.cancel()
        forwardingTask = Task { [weak self] in
            for await event in providerEvents {
                guard !Task.isCancelled else {
                    break
                }
                await self?.forward(event)
            }
        }
    }

    func updateContext(_ context: RealtimeDJContext) async throws {
        try await transport.updateContext(
            JSONEncoder().encode(context)
        )
    }

    func setMicrophoneCaptureEnabled(
        _ enabled: Bool
    ) async throws {
        try await transport.setMicrophoneCaptureEnabled(enabled)
    }

    func setMicrophoneTransmissionEnabled(
        _ enabled: Bool
    ) async throws {
        try await transport.setMicrophoneTransmissionEnabled(enabled)
    }

    func interrupt() async throws {
        try await transport.interrupt()
    }

    func requestAgentResponse(_ instruction: String) async throws {
        try await transport.requestAgentResponse(instruction)
    }

    func submitToolResult(
        _ result: RealtimeDJToolResult
    ) async throws {
        try await transport.submitToolResult(result)
    }

    func disconnect() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        await transport.disconnect()
    }

    private func forward(_ event: ProviderRealtimeEvent) {
        for mappedEvent in mapper.map(event) {
            eventContinuation.yield(mappedEvent)
        }
    }
}

struct BailianRealtimeEventMapper: Sendable {
    private var agentAudioActive = false

    mutating func map(_ event: ProviderRealtimeEvent) -> [RealtimeDJEvent] {
        switch event.type {
        case "qwen.open", "connection.connected":
            return [.connectionChanged(.connected)]
        case "connection.recovering":
            return [.connectionChanged(.recovering)]
        case "qwen.closed", "connection.disconnected":
            return [.connectionChanged(.disconnected)]
        case "input_audio_buffer.speech_started":
            return [.userSpeechStarted]
        case "input_audio_buffer.speech_stopped":
            return [.userSpeechFinished]
        case "conversation.item.input_audio_transcription.delta":
            return event.text.map { [.userTranscriptDelta($0)] } ?? []
        case "conversation.item.input_audio_transcription.completed":
            return event.text.map { [.userTranscriptFinal($0)] } ?? []
        case "response.created":
            return [.agentResponseStarted]
        case "response.audio.delta":
            guard !agentAudioActive else { return [] }
            agentAudioActive = true
            return [.agentAudioStarted]
        case "audio.user.level":
            guard let rms = event.rms, let peak = event.peak else {
                return []
            }
            return [.userAudioLevel(
                RealtimeDJAudioLevel(rms: rms, peak: peak)
            )]
        case "audio.agent.level":
            guard let rms = event.rms, let peak = event.peak else {
                return []
            }
            return [.agentAudioLevel(
                RealtimeDJAudioLevel(rms: rms, peak: peak)
            )]
        case "response.audio_transcript.delta":
            return event.text.map { [.agentTranscriptDelta($0)] } ?? []
        case "response.audio_transcript.done":
            return event.text.map { [.agentTranscriptFinal($0)] } ?? []
        case "response.done":
            agentAudioActive = false
            return [.agentAudioFinished]
        case "response.cancelled", "response.interrupted":
            agentAudioActive = false
            return [.interrupted]
        case "response.function_call_arguments.done":
            return toolCall(from: event).map { [.toolCall($0)] } ?? []
        case "error", "qwen.error":
            return [.failure(failure(from: event, defaultCode: "bailian_realtime_error"))]
        default:
            return []
        }
    }

    private func toolCall(from event: ProviderRealtimeEvent) -> RealtimeDJToolCall? {
        guard
            let callID = event.callID,
            let name = event.name,
            let argumentsJSON = event.argumentsJSON
        else {
            return nil
        }
        return RealtimeDJToolCall(
            id: callID,
            name: name,
            argumentsJSON: argumentsJSON
        )
    }

    private func failure(
        from event: ProviderRealtimeEvent,
        defaultCode: String
    ) -> RealtimeDJFailure {
        RealtimeDJFailure(
            code: event.errorCode ?? defaultCode,
            message: event.errorMessage ?? "百炼实时会话发生错误",
            recoverable: event.recoverable ?? false
        )
    }
}
