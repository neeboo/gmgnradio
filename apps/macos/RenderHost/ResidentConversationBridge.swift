import Foundation

/// Real conversation-service adapter with optional host-owned world leases.
/// It never constructs StageResidentChatState because
/// that type's attachment store cannot currently accept an isolated root.
@MainActor
final class RenderHostResidentConversation {
    private(set) var backend: String
    private var service: AgentConversationService
    private var connector: RenderHostDSHConnector
    private let dataRoot: URL
    private let defaults: UserDefaults
    private var rebuildConnection = false
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var events: [[String: Any]] = []
    private var activeSubmission: ResidentChatSubmission?
    private var activeRequestID: UInt64?
    private var recovery = ResidentDraftRecovery()
    private var transcript: [AgentConversationMessage] = []
    private var draft = ""
    private var reply = ""
    private var statusNotice: String?
    private var failureCode: String?
    private var musicStateProvider: (@MainActor () -> [String: Any])?
    private var replySpeechProvider: (@MainActor () -> Bool)?
    private var worldServices: WorldServices?
    private var worldLease: ResidentWorldToolSession?
    private var backgroundTask: Task<String, Error>?
    private var backgroundRunID: UUID?

    var installedBackendSnapshot: [[String: Any]] {
        // Snapshot is polled by the Unity render loop. Discovery runs only at
        // initialization or an explicit settings/selection action.
        service.cachedInstalledBackends.filter { $0.kind == .dsh || $0.kind == .codex }
            .map { ["id": $0.kind.rawValue, "name": $0.displayName, "installed": true, "selected": $0.kind.rawValue == backend] }
    }

    func refreshInstalledBackends() {
        _ = service.installedBackends(refresh: true)
    }

    @discardableResult
    func selectBackend(_ id: String) -> Bool {
        guard ["dsh", "codex"].contains(id),
              service.installedBackends(refresh: true).contains(where: { $0.kind.rawValue == id }) else { return false }
        guard id != backend else { return true }
        if let id = backgroundRunID { cancelRun(runID: id) }
        cancel()
        finishWorldLease()
        connector.close()
        service.resetSession()
        backend = id
        service = Self.makeService(connector: connector, defaults: defaults, backend: id)
        rebuildConnection = true
        return true
    }

    struct WorldServices {
        let context: WorldAgentContext
        let dispatcher: WorldAgentToolDispatcher
        let isCurrent: @MainActor () -> Bool
        /// Scope is a call ledger identity, never a generation grant. The host
        /// must independently verify any wish submission authorization.
        let additionalTools: @MainActor (UUID, String, @escaping @MainActor () -> Bool) -> [ResidentWorldToolSession.AdditionalTool]
        let onCancel: @MainActor () -> Void
        let backgroundTools: @MainActor (UUID, @escaping @MainActor () -> Bool) -> [ResidentWorldToolSession.AdditionalTool]

        init(context: WorldAgentContext, dispatcher: WorldAgentToolDispatcher,
             isCurrent: @escaping @MainActor () -> Bool,
             additionalTools: @escaping @MainActor (UUID, String, @escaping @MainActor () -> Bool) -> [ResidentWorldToolSession.AdditionalTool],
             onCancel: @escaping @MainActor () -> Void,
             backgroundTools: @escaping @MainActor (UUID, @escaping @MainActor () -> Bool) -> [ResidentWorldToolSession.AdditionalTool] = { _, _ in [] }) {
            self.context = context; self.dispatcher = dispatcher; self.isCurrent = isCurrent
            self.additionalTools = additionalTools; self.onCancel = onCancel; self.backgroundTools = backgroundTools
        }
    }

    func setWorldServices(_ services: WorldServices?, preservingActiveReply: Bool = false) {
        if let id = backgroundRunID { cancelRun(runID: id) }
        if preservingActiveReply, activeSubmission != nil {
            // A successful scene tool retires the old world context while its
            // model turn is still waiting for that tool result. Keep only that
            // turn's connector/task/lease alive long enough to receive the
            // verified result and final reply. The lease's existing isCurrent
            // closure rejects every later old-world tool call; finishWorldLease
            // closes the connector before the next turn binds these services.
            worldServices = services
            return
        }
        cancel()
        worldLease?.cancel()
        worldLease = nil
        worldServices = services
        // Native tool declarations are installed when opening an ACP session.
        // A different world's catalog cannot reuse the old native session.
        connector.close()
        service.resetSession()
        rebuildConnection = true
    }

    /// The playback owner supplies a fresh read on every native tool call.
    /// No file paths, credentials or frozen prompt snapshots belong here.
    func setMusicStateProvider(_ provider: @escaping @MainActor () -> [String: Any]) {
        musicStateProvider = provider
        connector.musicStateProvider = provider
    }

    func setReplySpeechProvider(_ provider: @escaping @MainActor () -> Bool) {
        replySpeechProvider = provider
    }

    init(backend: String, dataRoot: URL, defaults: UserDefaults) throws {
        self.backend = backend
        guard ["dsh", "codex"].contains(backend) else { throw RenderHostDSHConnectionError.unsupportedBackend }
        let directory = dataRoot.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.dataRoot = directory
        self.defaults = defaults
        let connector = try RenderHostDSHConnector(dataRoot: directory, requiresNative: backend == "dsh")
        self.connector = connector
        service = Self.makeService(connector: connector, defaults: defaults, backend: backend)
    }

    private static func makeService(connector: RenderHostDSHConnector, defaults: UserDefaults, backend: String) -> AgentConversationService {
        let service = AgentConversationService(
            defaults: defaults,
            // Fail closed if a future service change attempts a CLI fallback.
            runnerFactory: { _ in RenderHostForbiddenHeadlessRunner() },
            residentDSHImageConnector: connector,
            useResidentAgent: true
        )
        service.selectBackend(backend == "codex" ? .codex : .dsh)
        _ = service.installedBackends(refresh: true)
        service.setAutoSpeakReplies(false)
        service.resetSession()
        return service
    }

    func send(requestID: UInt64, text: String) -> Bool {
        send(requestID: requestID,
             submission: ResidentChatSubmission(text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func send(
        requestID: UInt64,
        submission: ResidentChatSubmission,
        authorizeImages: (@MainActor (UUID, @escaping @MainActor () -> Bool) throws -> Void)? = nil
    ) -> Bool {
        guard task == nil else {
            enqueue(kind: "failure", requestID: requestID, message: "正在回复，请先停止当前回复。")
            return false
        }
        guard submission.canSend else {
            enqueue(kind: "failure", requestID: requestID, message: "请先输入消息。")
            return false
        }
        // Accepted human input preempts only a background run.
        if let id = backgroundRunID { cancelRun(runID: id) }
        if rebuildConnection {
            do {
                let replacement = try RenderHostDSHConnector(dataRoot: dataRoot, requiresNative: backend == "dsh")
                replacement.musicStateProvider = musicStateProvider
                connector = replacement
                service = Self.makeService(connector: replacement, defaults: defaults, backend: backend)
                rebuildConnection = false
            } catch {
                enqueue(kind: "failure", requestID: requestID, message: error.localizedDescription)
                return false
            }
        }
        if let services = worldServices {
            guard services.dispatcher.context === services.context, services.isCurrent() else {
                enqueue(kind: "failure", requestID: requestID, message: "空间正在切换，请稍后再发送。")
                return false
            }
        }
        guard backend != "codex" || worldServices != nil else {
            enqueue(kind: "failure", requestID: requestID, message: "空间服务尚未就绪，消息已保留。")
            return false
        }
        let imageURLs = submission.attachments.map(\.url)
        do {
            try service.validateImageSupport(imageURLs: imageURLs)
        } catch {
            let recovered = recovery.restore(submission, text: draft, attachments: [])
            draft = recovered.text
            statusNotice = error.localizedDescription
            failureCode = Self.safeFailureCode(error)
            enqueue(kind: "failure", requestID: requestID, message: error.localizedDescription, category: "config")
            return false
        }
        generation &+= 1
        let lease = generation
        if let services = worldServices {
            let scope = submission.id
            let worldID = services.context.snapshot.worldID
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.generation == lease && services.isCurrent()
                    && services.context.snapshot.worldID == worldID
            }
            if !submission.attachments.isEmpty, let authorizeImages {
                do {
                    try authorizeImages(scope, isCurrent)
                } catch {
                    let recovered = recovery.restore(submission, text: draft, attachments: [])
                    draft = recovered.text
                    statusNotice = "图片授权失败，请确认当前空间后重试。"
                    failureCode = Self.safeFailureCode(error)
                    enqueue(kind: "failure", requestID: requestID,
                            message: statusNotice, category: "connection")
                    return false
                }
            }
            let tools = ResidentWorldToolSession(scopeID: scope, worldID: worldID,
                dispatcher: services.dispatcher, deadline: Date().addingTimeInterval(180),
                isCurrent: isCurrent, onCancel: services.onCancel,
                additionalTools: services.additionalTools(scope, submission.text, isCurrent))
            worldLease = tools
            connector.worldLease = tools
        }
        activeSubmission = submission
        activeRequestID = requestID
        draft = ""
        reply = ""
        statusNotice = nil
        failureCode = nil
        recovery = ResidentDraftRecovery()
        enqueue(kind: "accepted", requestID: requestID, text: submission.text)
        // The native ACP session keeps its real continuity; only a newly
        // rebuilt session receives this bounded actual-history bootstrap.
        let previous = Array(transcript.suffix(12))
        // Cancellation can replace the service before this Task resumes.
        // Every old operation must retain only its original service/connector.
        let turnService = service
        let turnConnector = connector
        let turnWorldLease = worldLease
        let turnWorldContext = worldServices.map(currentWorldContext)
        let codexTools: ResidentConversationTools? = backend == "codex" ? turnWorldLease.map { lease in
            .init(worldID: lease.worldID, schemasJSON: lease.toolSchemasJSON,
                call: { id, name, arguments in
                    let result = await lease.call(requestID: id, name: name, argumentsJSON: arguments)
                    return .init(resultJSON: result.resultJSON, isError: result.isError)
                }, cancel: { lease.cancel() })
        } : nil
        turnConnector.onTextDelta = { [weak self] text in
            guard let self, lease == self.generation,
                  self.activeRequestID == requestID, !text.isEmpty else { return }
            self.reply += text
            // Cumulative snapshots tolerate bounded polling queues dropping
            // intermediate updates. Receivers replace, never append this text.
            self.enqueue(kind: "delta", requestID: requestID, text: self.reply)
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let persona = ResidentPreferences(defaults: defaults).persona
                let prompt = turnWorldContext == nil ? (ResidentPreferences.personaInjection(persona) ?? "") + submission.text : submission.text
                let response = try await turnService.send(prompt, imageURLs: imageURLs, history: previous,
                    worldContext: turnWorldContext, worldTools: codexTools,
                    nativeToolsAvailable: self.backend == "dsh" && turnWorldLease != nil,
                    userMessage: submission.text)
                guard lease == generation, !Task.isCancelled else { return }
                reply = response
                turnConnector.onTextDelta = nil
                transcript += [.init(role: .user, text: submission.text), .init(role: .agent, text: response)]
                transcript = Array(transcript.suffix(24))
                enqueue(kind: "reply", requestID: requestID, text: response)
                finishWorldLease()
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            } catch {
                guard lease == generation else { return }
                turnConnector.onTextDelta = nil
                draft = recovery.restore(submission, text: draft, attachments: []).text
                let notice = error is CancellationError ? "已停止本次回复。" : error.localizedDescription
                statusNotice = notice
                failureCode = Self.safeFailureCode(error)
                NSLog("[UnityChat] failure code=%@", failureCode ?? "unknown")
                enqueue(kind: error is CancellationError ? "cancelled" : "failure",
                        requestID: requestID, message: notice,
                        category: error is RenderHostDSHConnectionError ? "config" : "connection")
                finishWorldLease()
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            }
        }
        return true
    }

    private func currentWorldContext(_ services: WorldServices) -> ResidentWorldContext {
        var context = Self.worldContext(services)
        context.replySpeechEnabled = replySpeechProvider?()
        if let playback = musicStateProvider?(), let hasTrack = playback["hasTrack"] as? Bool,
           let isPlaying = playback["isPlaying"] as? Bool {
            context.musicPlayback = .init(hasTrack: hasTrack, isPlaying: isPlaying,
                title: hasTrack ? playback["title"] as? String : nil,
                artist: hasTrack ? playback["artist"] as? String : nil)
        }
        return context
    }

    private static func worldContext(_ services: WorldServices) -> ResidentWorldContext {
            let state = services.context.snapshot
            let context = services.context
            let generatedIDs = context.state.objectStates.compactMap { id, value in value.generatedProp == nil ? nil : id }
            let objects = Set(context.manifest.activities.flatMap(\.propIDs)).union(generatedIDs).sorted().map { id in
                let object = context.state.objectStates[id]
                return ResidentWorldContext.Object(id: id,
                    displayName: object?.generatedProp?.displayName ?? (id == "prop.jukebox" ? "点唱机" : nil),
                    position: object.map { [$0.transform.position.x, $0.transform.position.y, $0.transform.position.z] },
                    isEnabled: object?.isEnabled,
                    activityIDs: (context.manifest.activities.filter { $0.propIDs.contains(id) }.map(\.id)
                        + context.propActivityIDs(objectID: id)).sorted())
            }
            return .init(selectedWorldID: state.worldID, worldID: state.worldID, displayName: state.displayName,
                revision: state.revision,
                residentPosition: [state.agentTransform.position.x, state.agentTransform.position.y, state.agentTransform.position.z],
                activeActivity: state.activeActivity?.id, activityPhase: state.activeActivity?.phase.rawValue,
                objects: objects, availableActivities: state.activities.map {
                    .init(id: $0.id, displayName: context.activityCatalog.definition(id: $0.id)?.displayName,
                          action: $0.action, entryPlaceID: $0.entryPlaceID)
                })
    }

    /// Autonomous input never calls the human factory or registers a human
    /// message/reference grant. It shares the selected backend and real world.
    func runBackground(input: ResidentAgentLoop.Input) async throws -> String {
        guard input.isBackground, input.userMessages.isEmpty else { throw RenderHostBackgroundError.humanInput }
        guard task == nil, backgroundRunID == nil else { throw RenderHostBackgroundError.busy }
        guard let services = worldServices, services.isCurrent(), services.dispatcher.context === services.context else {
            throw RenderHostBackgroundError.worldUnavailable
        }
        try Task.checkCancellation()
        if rebuildConnection {
            let replacement = try RenderHostDSHConnector(dataRoot: dataRoot, requiresNative: backend == "dsh")
            replacement.musicStateProvider = musicStateProvider
            connector = replacement
            service = Self.makeService(connector: replacement, defaults: defaults, backend: backend)
            rebuildConnection = false
        }
        generation &+= 1
        let leaseGeneration = generation, runID = input.runID
        backgroundRunID = runID
        let worldID = services.context.snapshot.worldID
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.backgroundRunID == runID && self.generation == leaseGeneration
                && services.isCurrent() && services.context.snapshot.worldID == worldID
        }
        let lease = ResidentWorldToolSession(scopeID: runID, worldID: worldID, dispatcher: services.dispatcher,
            deadline: Date().addingTimeInterval(180), isCurrent: isCurrent, onCancel: services.onCancel,
            additionalTools: services.backgroundTools(runID, isCurrent))
        worldLease = lease
        connector.worldLease = lease
        connector.onTextDelta = nil
        let turnService = service
        let tools: ResidentConversationTools? = backend == "codex" ? .init(worldID: worldID, schemasJSON: lease.toolSchemasJSON,
            call: { id, name, arguments in
                let result = await lease.call(requestID: id, name: name, argumentsJSON: arguments)
                return .init(resultJSON: result.resultJSON, isError: result.isError)
            }, cancel: { lease.cancel() }) : nil
        let context = currentWorldContext(services)
        let operation = Task {
            try await turnService.send(input.promptText, imageURLs: input.imageURLs,
                worldContext: context, worldTools: tools, nativeToolsAvailable: self.backend == "dsh",
                userMessage: "")
        }
        backgroundTask = operation
        defer {
            // A preempted old task cannot revoke a newly started human lease.
            if backgroundRunID == runID {
                backgroundTask = nil; backgroundRunID = nil
                finishWorldLease()
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await operation.value
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return result
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRun(runID: runID) }
        })
    }

    @discardableResult
    func cancelRun(runID: UUID) -> Bool {
        guard backgroundRunID == runID else { return false }
        generation &+= 1
        backgroundTask?.cancel()
        service.cancel()
        // A cancelled background turn can still be unwinding across an await.
        // Do not let that old service/connector housekeeping retire the next
        // human turn's runtime. send() builds a fresh owned connection.
        service.resetSession()
        connector.close()
        rebuildConnection = true
        backgroundTask = nil; backgroundRunID = nil
        finishWorldLease()
        return true
    }

    @discardableResult
    func cancel(requestID: UInt64? = nil) -> Bool {
        if let requestID, requestID != activeRequestID { return false }
        guard let submission = activeSubmission else { return false }
        let cancelledID = activeRequestID
        generation &+= 1
        finishWorldLease()
        task?.cancel()
        service.cancel()
        service.resetSession()
        connector.close()
        rebuildConnection = true
        task = nil
        activeSubmission = nil
        activeRequestID = nil
        draft = recovery.restore(submission, text: draft, attachments: []).text
        statusNotice = "已停止本次回复。"
        enqueue(kind: "cancelled", requestID: cancelledID, message: statusNotice)
        return true
    }

    func close() {
        if let id = backgroundRunID { cancelRun(runID: id) }
        cancel()
        finishWorldLease()
        service.resetSession()
        connector.close()
    }

    private func finishWorldLease() {
        worldLease?.cancel()
        worldLease = nil
        connector.worldLease = nil
        if worldServices != nil {
            connector.close()
            service.resetSession()
            rebuildConnection = true
        }
    }

    var state: [String: Any] {
        ["configured": true, "backend": backend, "isThinking": task != nil,
         "backgroundRunning": backgroundRunID != nil,
         "canStop": activeSubmission != nil, "draft": draft, "reply": reply,
         "statusNotice": statusNotice as Any? ?? NSNull(),
         "failureCode": failureCode as Any? ?? NSNull(),
         "deliveryMode": backend == "dsh" ? "streamed-response" : "final-response", "deltaTextMode": "replace", "worldToolsEnabled": worldServices != nil,
         "transcript": transcript.map { ["role": $0.role.rawValue, "text": $0.text] }]
    }

    func poll() -> [String: Any] {
        let result: [String: Any] = ["events": events, "state": state]
        events.removeAll(keepingCapacity: true)
        return result
    }

    /// Fixed enum labels only: never render associated server text, stderr,
    /// paths, credential keys or arbitrary NSError descriptions into logs.
    private static func safeFailureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let connection = error as? RenderHostDSHConnectionError {
            switch connection {
            case .unavailable: return "native_transport_unavailable"
            case .unsupportedBackend: return "unsupported_backend"
            case .headlessForbidden: return "headless_fallback_forbidden"
            }
        }
        if let transport = error as? ResidentDSHTransportError {
            switch transport {
            case .alreadyStarted: return "transport_already_started"
            case .launchFailed: return "transport_launch_failed"
            case .notConnected: return "transport_not_connected"
            case .connectionClosed: return "transport_connection_closed"
            case .invalidFrame: return "transport_invalid_frame"
            case .frameTooLarge: return "transport_frame_too_large"
            case .writeFailed: return "transport_write_failed"
            case .timedOut: return "transport_timed_out"
            case .turnNotCompleted: return "transport_turn_not_completed"
            case .promptConflict: return "transport_prompt_conflict"
            }
        }
        if let tools = error as? ResidentDSHHostToolsError {
            switch tools {
            case .malformedToolSet: return "host_tools_malformed"
            case .invalidConfiguration: return "host_tools_configuration_invalid"
            case .startupFailed: return "host_tools_startup_failed"
            case .notStarted: return "host_tools_not_started"
            }
        }
        if let conversation = error as? AgentConversationError {
            switch conversation {
            case .backendNotInstalled: return "backend_not_installed"
            case .emptyReply: return "empty_reply"
            case .cancelled: return "cancelled"
            case .worldToolsUnavailable: return "world_tools_unavailable"
            case .invalidDSHToolProtocol: return "invalid_tool_protocol"
            case .dshSecurityPatchUnavailable: return "security_configuration_invalid"
            case let .dshExecutionFailed(_, reason): return safeExecutionCode(reason)
            case .imagesUnsupported: return "images_unsupported"
            case .imageTransportUnavailable: return "image_transport_unavailable"
            case .dshTextTransportUnavailable: return "text_transport_unavailable"
            case .dshImageCapabilityUnavailable: return "image_capability_unavailable"
            case .imageFormatUnsupported: return "image_format_unsupported"
            case let .dshNativeTurnFailed(reason): return safeExecutionCode(reason)
            case .claudeExecutionFailed: return "claude_execution_failed"
            case .claudeInvalidResult: return "claude_result_invalid"
            }
        }
        return "connection_failure_unclassified"
    }

    private static func safeExecutionCode(_ reason: DSHExecutionFailureReason) -> String {
        switch reason {
        case .dependencyUnavailable: return "dsh_dependency_unavailable"
        case .missingCredential: return "dsh_credential_missing"
        case .authentication: return "dsh_authentication_failed"
        case .quota: return "dsh_quota_or_rate_limit"
        case .network: return "dsh_network_failed"
        case .unknown: return "dsh_execution_failed"
        }
    }

    private func enqueue(kind: String, requestID: UInt64?, text: String? = nil, message: String? = nil, category: String? = nil) {
        sequence &+= 1
        var event: [String: Any] = ["sequence": sequence, "kind": kind]
        if let requestID { event["requestID"] = requestID }
        if let text { event["text"] = text }
        if let message { event["message"] = message }
        if let category { event["category"] = category }
        events.append(event)
        if events.count > 64 { events.removeFirst(events.count - 64) }
    }
}

private enum RenderHostBackgroundError: Error, LocalizedError {
    case busy, humanInput, worldUnavailable
    var errorDescription: String? {
        switch self {
        case .busy: "居民正在处理当前消息。"
        case .humanInput: "后台轮次不能携带新的用户指令。"
        case .worldUnavailable: "当前空间服务尚未就绪。"
        }
    }
}

enum RenderHostDSHConnectionError: Error, LocalizedError {
    case unavailable, unsupportedBackend, headlessForbidden
    var errorDescription: String? {
        switch self {
        case .unavailable: "现有 Agent 的原生连接尚未就绪，请检查 DeepSeek Harness 安装。"
        case .unsupportedBackend: "请选择已安装的 DeepSeek Harness 或 Codex。"
        case .headlessForbidden: "原生 Agent 连接未能完成，消息已保留；不会切换到其他连接方式。"
        }
    }
}

private struct RenderHostForbiddenHeadlessRunner: CodexCommandRunning {
    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        throw RenderHostDSHConnectionError.headlessForbidden
    }
}

/// A lifecycle/cwd adapter around the real production ACP connector. It owns
/// no authentication policy, key or provider override. Composition emission,
/// verification, mounted modules and managed credentials remain production DSH.
@MainActor
private final class RenderHostDSHConnector: ResidentDSHImageConnecting {
    var onTextDelta: (@MainActor (String) -> Void)?
    var musicStateProvider: (@MainActor () -> [String: Any])?
    var worldLease: ResidentWorldToolSession?
    private let node: URL?
    private let entry: URL?
    private let dataRoot: URL
    private var native: ResidentDSHConnector?
    private var sandbox: ResidentDSHSandbox?
    private var musicTools: ResidentDSHHostToolsChannel?

    init(dataRoot: URL, requiresNative: Bool = true) throws {
        let transport = ResidentDSHComposition.locateNativeTransport(using: AgentExecutableLocator())
        guard !requiresNative || transport != nil else {
            throw RenderHostDSHConnectionError.unavailable
        }
        self.node = transport?.node
        self.entry = transport?.entry
        self.dataRoot = dataRoot
    }

    var isUsable: Bool { native?.isUsable ?? true }

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        close()
        guard let node, let entry else { throw RenderHostDSHConnectionError.unavailable }
        try Task.checkCancellation()
        if worldLease != nil || musicStateProvider != nil {
            let schema = Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
            var registrations = try worldLease.map { try ResidentDSHHostToolSet.parse(schemasJSON: $0.toolSchemasJSON) } ?? []
            let registeredNames = Set(registrations.map(\.canonicalName))
            registrations += ["read_current_track", "read_radio_state"].filter { musicStateProvider != nil && !registeredNames.contains($0) }.map { name in
                ResidentDSHHostToolRegistration(canonicalName: name, declaredName: "gmgn_" + name,
                    description: "读取应用播放器此刻的真实歌曲、播放状态和进度。询问正在播放的音乐时必须调用此工具；没有歌曲时明确返回空状态。只读，不控制播放。",
                    originalSchemaJSON: schema)
            }
            musicTools = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: worldLease?.scopeID.uuidString ?? "unity-player-music", worldID: worldLease?.worldID ?? "player", registrations: registrations,
                handler: { [weak self] request in
                    if let lease = self?.worldLease,
                       !(request.canonicalName == "read_current_track" || request.canonicalName == "read_radio_state") || registeredNames.contains(request.canonicalName) {
                        let result = await lease.call(requestID: request.callID, name: request.canonicalName, argumentsJSON: request.argumentsJSON)
                        return .init(resultJSON: result.resultJSON, isError: result.isError)
                    }
                    guard let provider = self?.musicStateProvider,
                          ["read_current_track", "read_radio_state"].contains(request.canonicalName),
                          let args = try? JSONSerialization.jsonObject(with: request.argumentsJSON) as? [String: Any],
                          args.isEmpty else {
                        return .init(resultJSON: Data(#"{"ok":false,"code":"music_state_unavailable"}"#.utf8), isError: true)
                    }
                    // Read-only public playback facts only. A host accidentally
                    // returning its full snapshot must not expose paths/tokens.
                    let allowed: Set<String> = ["title", "artist", "trackID", "provider", "isPlaying", "position", "duration", "queueIndex", "queueCount", "hasTrack"]
                    let state = provider().filter { allowed.contains($0.key) }
                    guard let result = try? JSONSerialization.data(withJSONObject: ["ok": true, "state": state], options: [.sortedKeys]) else {
                        return .init(resultJSON: Data(#"{"ok":false,"code":"invalid_music_state"}"#.utf8), isError: true)
                    }
                    return .init(resultJSON: result, isError: false)
                }))
            musicTools?.revoke()
        }
        let box: ResidentDSHSandbox
        do {
            box = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: entry, rootDirectory: dataRoot,
                hostToolsPluginPath: musicTools?.pluginFileURL.path)
        } catch { close(); throw error }
        let connection = ResidentDSHConnector(nodeExecutable: node, entryPoint: entry,
            compositionFileURL: box.compositionFileURL, requestTimeout: 120)
        sandbox = box
        native = connection
        do {
            // The service's injected-connector fallback cwd is intentionally
            // ignored: both the Process and ACP session use the owned sandbox.
            let handle = try await connection.openSession(cwd: box.workspace)
            guard native === connection, !Task.isCancelled else { throw CancellationError() }
            return handle
        } catch {
            if native === connection {
                close()
            } else {
                // A cancelled handshake can finish after a replacement has
                // started. Release only the old operation's owned resources.
                connection.close()
                box.removeAll()
            }
            throw error
        }
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        guard let native else { throw ResidentDSHTransportError.notConnected }
        let turnTools = musicTools
        try turnTools?.arm(worldRevision: nil)
        defer { turnTools?.revoke() }
        return try await native.prompt(sessionID: sessionID, blocks: blocks, onTextDelta: onTextDelta)
    }
    func cancelActivePrompt() { musicTools?.revoke(); native?.cancelActivePrompt() }
    func awaitCancellationSettled() async { await native?.awaitCancellationSettled() }
    func close() {
        musicTools?.stop()
        musicTools = nil
        native?.close()
        native = nil
        sandbox?.removeAll()
        sandbox = nil
    }
}

private func bridgeJSON(_ value: [String: Any]) -> UInt? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return strdup(string).map { UInt(bitPattern: $0) }
}

@_cdecl("gmgn_render_host_chat_configure")
func gmgnRenderHostChatConfigure(_ pointer: UnsafeMutableRawPointer?, _ backendPointer: UnsafePointer<CChar>?) -> Int32 {
    guard Thread.isMainThread, let pointer, let backendPointer else { return 0 }
    let address = UInt(bitPattern: pointer)
    let backend = String(cString: backendPointer)
    guard ["dsh", "codex"].contains(backend) else { return 0 }
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        do {
            host.chat?.close()
            host.chat = try RenderHostResidentConversation(backend: backend, dataRoot: host.dataRoot, defaults: host.defaults)
            return 1
        } catch { return 0 }
    }
}

@_cdecl("gmgn_render_host_chat_send")
func gmgnRenderHostChatSend(_ pointer: UnsafeMutableRawPointer?, _ requestID: UInt64, _ textPointer: UnsafePointer<CChar>?) -> Int32 {
    guard Thread.isMainThread, let pointer, let textPointer else { return 0 }
    let address = UInt(bitPattern: pointer), text = String(cString: textPointer)
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        return host.chat?.send(requestID: requestID, text: text) == true ? 1 : 0
    }
}

@_cdecl("gmgn_render_host_chat_cancel")
func gmgnRenderHostChatCancel(_ pointer: UnsafeMutableRawPointer?, _ requestID: UInt64) -> Int32 {
    guard Thread.isMainThread, let pointer else { return 0 }
    let address = UInt(bitPattern: pointer)
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        guard let chat = host.chat else { return 0 }
        return chat.cancel(requestID: requestID) ? 1 : 0
    }
}

@_cdecl("gmgn_render_host_chat_poll")
func gmgnRenderHostChatPoll(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    renderHostChatSnapshot(pointer, drain: true)
}

@_cdecl("gmgn_render_host_chat_context")
func gmgnRenderHostChatContext(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    renderHostChatSnapshot(pointer, drain: false)
}

private func renderHostChatSnapshot(_ pointer: UnsafeMutableRawPointer?, drain: Bool) -> UnsafeMutablePointer<CChar>? {
    guard Thread.isMainThread, let pointer else { return nil }
    let address = UInt(bitPattern: pointer)
    let stringAddress: UInt? = MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        guard let chat = host.chat else {
            let state: [String: Any] = ["configured": false, "isThinking": false, "canStop": false,
                                       "draft": "", "reply": "", "transcript": [], "deliveryMode": "final-response"]
            return bridgeJSON(drain ? ["events": [], "state": state] : state)
        }
        return bridgeJSON(drain ? chat.poll() : chat.state)
    }
    return stringAddress.flatMap { UnsafeMutablePointer<CChar>(bitPattern: $0) }
}
