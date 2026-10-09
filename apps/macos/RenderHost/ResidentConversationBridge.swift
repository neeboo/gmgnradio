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
    private let authorityEndpointFile: String
    private let defaults: UserDefaults
    private let productSettings: RustProductSettingsClient
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
    private(set) var lastReplySpeechSource: [String: Any] = [:]

    var installedBackendSnapshot: [[String: Any]] {
        // Snapshot is polled by the Unity render loop. Discovery runs only at
        // initialization or an explicit settings/selection action.
        service.cachedInstalledBackends.filter { [.dsh, .codex, .claudeCode].contains($0.kind) }
            .map { ["id": $0.kind.rawValue, "name": $0.displayName, "installed": true, "selected": $0.kind.rawValue == backend] }
    }

    func refreshInstalledBackends() {
        _ = service.installedBackends(refresh: true)
    }

    @discardableResult
    func selectBackend(_ id: String) -> Bool {
        guard ["dsh", "codex", "claudeCode"].contains(id),
              service.installedBackends(refresh: true).contains(where: { $0.kind.rawValue == id }) else { return false }
        guard id != backend else { return true }
        if let id = backgroundRunID { cancelRun(runID: id) }
        cancel()
        finishWorldLease()
        connector.close()
        service.resetSession()
        backend = id
        service = Self.makeService(connector: connector, defaults: defaults, backend: id, productSettings: productSettings)
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

    init(backend: String, dataRoot: URL, defaults: UserDefaults, productSettings: RustProductSettingsClient = .shared) throws {
        self.productSettings = productSettings
        self.backend = backend
        guard ["dsh", "codex", "claudeCode"].contains(backend) else { throw RenderHostDSHConnectionError.unsupportedBackend }
        let directory = dataRoot.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.dataRoot = directory
        authorityEndpointFile = WorldAuthorityEndpoint(applicationSupportBase: dataRoot).endpointFile
        self.defaults = defaults
        let connector = try RenderHostDSHConnector(dataRoot: directory, requiresNative: backend == "dsh")
        self.connector = connector
        service = Self.makeService(connector: connector, defaults: defaults, backend: backend, productSettings: productSettings)
    }

    private static func makeService(connector: RenderHostDSHConnector, defaults: UserDefaults, backend: String, productSettings: RustProductSettingsClient) -> AgentConversationService {
        let service = AgentConversationService(
            defaults: defaults,
            // Fail closed if a future service change attempts a CLI fallback.
            runnerFactory: { _ in RenderHostForbiddenHeadlessRunner() },
            residentDSHImageConnector: connector,
            useResidentAgent: true,
            productSettings: productSettings
        )
        _ = service.installedBackends(refresh: true)
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
        authorizeImages: (@MainActor (UUID, @escaping @MainActor () -> Bool) async throws -> Void)? = nil,
        executionRunID: UUID? = nil,
        rustClaim: (scheduler: RustResidentSchedulerClient, ticket: RustResidentSchedulerClient.Ticket)? = nil,
        actualCompletion: (@MainActor (Result<String, Error>) -> Void)? = nil
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
                service = Self.makeService(connector: replacement, defaults: defaults, backend: backend, productSettings: productSettings)
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
        var imageAuthorization: (@MainActor () async throws -> Void)?
        if let services = worldServices {
            let scope = executionRunID ?? submission.id
            let worldID = services.context.snapshot.worldID
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.generation == lease && services.isCurrent()
                    && services.context.snapshot.worldID == worldID
            }
            if !submission.attachments.isEmpty, let authorizeImages {
                imageAuthorization = {
                    try await authorizeImages(scope, isCurrent)
                    guard isCurrent() else { throw CancellationError() }
                }
            }
            let tools = ResidentWorldToolSession(scopeID: scope, worldID: worldID,
                dispatcher: services.dispatcher, deadline: Date().addingTimeInterval(180),
                isCurrent: isCurrent, onCancel: services.onCancel,
                additionalTools: services.additionalTools(scope, submission.text, isCurrent),
                rustOperationAuthority: { name, canonical in
                    RustResidentToolBindingFactory.decision(scopeID: scope, worldID: worldID,
                        revision: services.context.snapshot.revision, name: name, canonical: canonical)
                })
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
        turnService.setRustResidentMode(true)
        let rustOwner = rustClaim.flatMap { claim in turnWorldLease.flatMap { lease in
            try? RustResidentToolBindingFactory(session: lease, claim: claim,
                endpointFile: authorityEndpointFile)
        }}
        let codexTools: ResidentConversationTools? = turnWorldLease.map { lease in
            .init(worldID: lease.worldID, schemasJSON: lease.toolSchemasJSON,
                call: { id, name, arguments in
                    let result: RealtimeDJToolResult
                    if let rustOwner { result = await rustOwner.call(callID: id, name: name, arguments: arguments) }
                    else { result = .init(callID: id, resultJSON: Data("{\"error\":\"rust_claim_required\"}".utf8), isError: true) }
                    return .init(resultJSON: result.resultJSON, isError: result.isError)
                }, cancel: { lease.cancel() }, rustBinding: rustOwner?.binding,
                rustDSHBinding: try? rustOwner?.dshBinding(),
                rustClaudeBinding: backend == "claudeCode" ? (try? rustOwner?.claudeBinding(
                    adapterExecutableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-mcpd"),
                    environment: ProcessInfo.processInfo.environment)) : nil)
        }
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
                try await imageAuthorization?()
                guard lease == generation, !Task.isCancelled else { throw CancellationError() }
                let persona = ResidentPreferences(defaults: defaults).persona
                let prompt = turnWorldContext == nil ? (ResidentPreferences.personaInjection(persona) ?? "") + submission.text : submission.text
                let response = try await turnService.send(prompt, imageURLs: imageURLs, history: previous,
                    worldContext: turnWorldContext, worldTools: codexTools,
                    nativeToolsAvailable: self.backend == "dsh" && turnWorldLease != nil,
                    userMessage: submission.text)
                actualCompletion?(.success(response))
                guard lease == generation, !Task.isCancelled else { return }
                reply = response
                lastReplySpeechSource = turnService.lastSpeechSource
                turnConnector.onTextDelta = nil
                transcript += [.init(role: .user, text: submission.text), .init(role: .agent, text: response)]
                transcript = Array(transcript.suffix(24))
                enqueue(kind: "reply", requestID: requestID, text: response)
                finishWorldLease()
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            } catch {
                // This is the actual provider return, including late returns.
                // UI cancellation alone never invokes this completion.
                actualCompletion?(.failure(error))
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
    func runBackground(input: ResidentAgentLoop.Input, preserveActualCompletion: Bool = false,
                       rustClaim: (scheduler: RustResidentSchedulerClient, ticket: RustResidentSchedulerClient.Ticket)? = nil) async throws -> String {
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
            service = Self.makeService(connector: replacement, defaults: defaults, backend: backend, productSettings: productSettings)
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
            additionalTools: services.backgroundTools(runID, isCurrent), rustOperationAuthority: { name, canonical in
                RustResidentToolBindingFactory.decision(scopeID: runID, worldID: worldID,
                    revision: services.context.snapshot.revision, name: name, canonical: canonical)
            })
        worldLease = lease
        connector.worldLease = lease
        connector.onTextDelta = nil
        let turnService = service
        turnService.setRustResidentMode(true)
        let rustOwner = try rustClaim.map { claim in
            try RustResidentToolBindingFactory(session: lease, claim: claim,
                endpointFile: authorityEndpointFile)
        }
        let tools: ResidentConversationTools? = .init(worldID: worldID, schemasJSON: lease.toolSchemasJSON,
            call: { id, name, arguments in
                let result: RealtimeDJToolResult
                if let rustOwner { result = await rustOwner.call(callID: id, name: name, arguments: arguments) }
                else { result = .init(callID: id, resultJSON: Data("{\"error\":\"rust_claim_required\"}".utf8), isError: true) }
                return .init(resultJSON: result.resultJSON, isError: result.isError)
            }, cancel: { lease.cancel() }, rustBinding: rustOwner?.binding,
            rustDSHBinding: try? rustOwner?.dshBinding(),
            rustClaudeBinding: backend == "claudeCode" ? (try? rustOwner?.claudeBinding(
                adapterExecutableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-mcpd"),
                environment: ProcessInfo.processInfo.environment)) : nil)
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
            if isCurrent() { lastReplySpeechSource = turnService.lastSpeechSource }
            if preserveActualCompletion { return result }
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

    /// The scheduler withdrew this input before send() began. Keep UI/draft
    /// ownership here; this does not claim that a provider invocation stopped.
    func cancelUnstarted(requestID: UInt64, submission: ResidentChatSubmission) {
        draft = recovery.restore(submission, text: draft, attachments: []).text
        enqueue(kind: "cancelled", requestID: requestID, message: "已停止尚未发送的消息。")
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
        if kind == "reply" { event["speechSource"] = lastReplySpeechSource }
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

/// UI callback holder only. World ACP process/tool ownership lives in taskd.
@MainActor
private final class RenderHostDSHConnector: ResidentDSHImageConnecting {
    var onTextDelta: (@MainActor (String) -> Void)?
    var musicStateProvider: (@MainActor () -> [String: Any])?
    var worldLease: ResidentWorldToolSession?
    init(dataRoot: URL, requiresNative: Bool = true) throws {
        _ = dataRoot
        if requiresNative && ResidentDSHComposition.locateNativeTransport(using: AgentExecutableLocator()) == nil { throw RenderHostDSHConnectionError.unavailable }
    }
    var isUsable: Bool { true }
    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle { throw RenderHostDSHConnectionError.headlessForbidden }
    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String { throw RenderHostDSHConnectionError.headlessForbidden }
    func cancelActivePrompt() {}
    func awaitCancellationSettled() async {}
    func close() {}
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
    guard ["dsh", "codex", "claudeCode"].contains(backend) else { return 0 }
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        do {
            host.chat?.close()
            // 必须传宿主自建的那个客户端：不传就走 `productSettings: .shared`，
            // 于是 RenderHost 里的 `SpatialStageStore` 和这里的会话各持一份
            // `RustProductSettingsClient`（各有一份 `confirmed` revision 缓存），
            // 一边写成功后另一边的 `expectedRevision` 就过期——正是
            // `product_settings_revision_conflict` 的制造机。
            host.chat = try RenderHostResidentConversation(
                backend: backend, dataRoot: host.dataRoot, defaults: host.defaults,
                productSettings: host.settings)
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
