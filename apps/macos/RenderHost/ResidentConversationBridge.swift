import Foundation

/// Real conversation-service adapter, deliberately without world tools or a
/// durable world scope. It never constructs StageResidentChatState because
/// that type's attachment store cannot currently accept an isolated root.
@MainActor
final class RenderHostResidentConversation {
    let backend: String
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
    private var musicStateProvider: (@MainActor () -> [String: Any])?

    /// The playback owner supplies a fresh read on every native tool call.
    /// No file paths, credentials or frozen prompt snapshots belong here.
    func setMusicStateProvider(_ provider: @escaping @MainActor () -> [String: Any]) {
        musicStateProvider = provider
        connector.musicStateProvider = provider
    }

    init(backend: String, dataRoot: URL, defaults: UserDefaults) throws {
        self.backend = backend
        guard backend == "dsh" else { throw RenderHostDSHConnectionError.unsupportedBackend }
        let directory = dataRoot.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.dataRoot = directory
        self.defaults = defaults
        let connector = try RenderHostDSHConnector(dataRoot: directory)
        self.connector = connector
        service = Self.makeService(connector: connector, defaults: defaults)
    }

    private static func makeService(connector: RenderHostDSHConnector, defaults: UserDefaults) -> AgentConversationService {
        let service = AgentConversationService(
            defaults: defaults,
            // Fail closed if a future service change attempts a CLI fallback.
            runnerFactory: { _ in RenderHostForbiddenHeadlessRunner() },
            residentDSHImageConnector: connector,
            useResidentAgent: false
        )
        service.selectBackend(.dsh)
        service.setAutoSpeakReplies(false)
        service.resetSession()
        return service
    }

    func send(requestID: UInt64, text: String) -> Bool {
        guard task == nil else {
            enqueue(kind: "failure", requestID: requestID, message: "正在回复，请先停止当前回复。")
            return false
        }
        let submission = ResidentChatSubmission(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard submission.canSend else {
            enqueue(kind: "failure", requestID: requestID, message: "请先输入消息。")
            return false
        }
        if rebuildConnection {
            do {
                let replacement = try RenderHostDSHConnector(dataRoot: dataRoot)
                replacement.musicStateProvider = musicStateProvider
                connector = replacement
                service = Self.makeService(connector: replacement, defaults: defaults)
                rebuildConnection = false
            } catch {
                enqueue(kind: "failure", requestID: requestID, message: error.localizedDescription)
                return false
            }
        }
        generation &+= 1
        let lease = generation
        activeSubmission = submission
        activeRequestID = requestID
        draft = ""
        reply = ""
        statusNotice = nil
        recovery = ResidentDraftRecovery()
        enqueue(kind: "accepted", requestID: requestID, text: submission.text)
        // The native ACP session keeps its real continuity; only a newly
        // rebuilt session receives this bounded actual-history bootstrap.
        let previous = Array(transcript.suffix(12))
        // Cancellation can replace the service before this Task resumes.
        // Every old operation must retain only its original service/connector.
        let turnService = service
        let turnConnector = connector
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
                // This isolated text session has no worldContext (the product's
                // normal persona injection point). Read the same settings suite
                // on every turn so a GPUI persona save affects the next message.
                let persona = ResidentPreferences(defaults: defaults).persona
                let prompt = (ResidentPreferences.personaInjection(persona) ?? "") + submission.text
                let response = try await turnService.send(prompt, history: previous, userMessage: submission.text)
                guard lease == generation, !Task.isCancelled else { return }
                reply = response
                turnConnector.onTextDelta = nil
                transcript += [.init(role: .user, text: submission.text), .init(role: .agent, text: response)]
                transcript = Array(transcript.suffix(24))
                enqueue(kind: "reply", requestID: requestID, text: response)
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            } catch {
                guard lease == generation else { return }
                turnConnector.onTextDelta = nil
                draft = recovery.restore(submission, text: draft, attachments: []).text
                let notice = error is CancellationError ? "已停止本次回复。" : error.localizedDescription
                statusNotice = notice
                enqueue(kind: error is CancellationError ? "cancelled" : "failure",
                        requestID: requestID, message: notice,
                        category: error is RenderHostDSHConnectionError ? "config" : "connection")
                activeSubmission = nil
                activeRequestID = nil
                task = nil
            }
        }
        return true
    }

    @discardableResult
    func cancel(requestID: UInt64? = nil) -> Bool {
        if let requestID, requestID != activeRequestID { return false }
        guard let submission = activeSubmission else { return false }
        let cancelledID = activeRequestID
        generation &+= 1
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
        cancel()
        service.resetSession()
        connector.close()
    }

    var state: [String: Any] {
        ["configured": true, "backend": backend, "isThinking": task != nil,
         "canStop": activeSubmission != nil, "draft": draft, "reply": reply,
         "statusNotice": statusNotice as Any? ?? NSNull(),
         "deliveryMode": "streamed-response", "deltaTextMode": "replace", "worldToolsEnabled": false,
         "transcript": transcript.map { ["role": $0.role.rawValue, "text": $0.text] }]
    }

    func poll() -> [String: Any] {
        let result: [String: Any] = ["events": events, "state": state]
        events.removeAll(keepingCapacity: true)
        return result
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

enum RenderHostDSHConnectionError: Error, LocalizedError {
    case unavailable, unsupportedBackend, headlessForbidden
    var errorDescription: String? {
        switch self {
        case .unavailable: "现有 Agent 的原生连接尚未就绪，请检查 DeepSeek Harness 安装。"
        case .unsupportedBackend: "当前界面只连接现有 DeepSeek Harness Agent。"
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
    private let node: URL
    private let entry: URL
    private let dataRoot: URL
    private var native: ResidentDSHConnector?
    private var sandbox: ResidentDSHSandbox?
    private var musicTools: ResidentDSHHostToolsChannel?

    init(dataRoot: URL) throws {
        guard let transport = ResidentDSHComposition.locateNativeTransport(using: AgentExecutableLocator()) else {
            throw RenderHostDSHConnectionError.unavailable
        }
        self.node = transport.node
        self.entry = transport.entry
        self.dataRoot = dataRoot
    }

    var isUsable: Bool { native?.isUsable ?? true }

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        close()
        try Task.checkCancellation()
        if musicStateProvider != nil {
            let schema = Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)
            let registrations = ["read_current_track", "read_radio_state"].map { name in
                ResidentDSHHostToolRegistration(canonicalName: name, declaredName: "gmgn_" + name,
                    description: "读取应用播放器此刻的真实歌曲、播放状态和进度。询问正在播放的音乐时必须调用此工具；没有歌曲时明确返回空状态。只读，不控制播放。",
                    originalSchemaJSON: schema)
            }
            musicTools = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "unity-player-music", worldID: "player", registrations: registrations,
                handler: { [weak self] request in
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
    guard backend == "dsh" else { return 0 }
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
