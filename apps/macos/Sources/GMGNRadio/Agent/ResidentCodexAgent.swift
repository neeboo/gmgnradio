import Foundation

struct ResidentCodexToolReply: Sendable {
    let resultJSON: Data
    let isError: Bool
    /// 原生图片通道：非 nil 时序列化会附加真实 PNG 的 inputImage 项。
    /// 仅元数据文本照常携带；文件路径本身绝不作为视觉输入。
    var image: ResidentVisionImage?
}

struct ResidentCodexAgentOutcome: Sendable {
    let reply: String
    let sessionID: String
}

enum ResidentCodexAgentError: Error, LocalizedError {
    case busy, invalidProtocol, invalidTools, turnFailed, noFinalAnswer, timedOut, codexUpgradeRequired
    var errorDescription: String? {
        switch self {
        case .busy: return "居民正在处理上一条消息。"
        case .invalidProtocol: return "居民会话返回的数据不完整。"
        case .invalidTools: return "当前空间的居民工具配置无效。"
        case .turnFailed: return "居民未能完成本轮回复，请重试。"
        case .noFinalAnswer: return "居民没有返回完整答复，请重试。"
        case .timedOut: return "居民回复等待超时，请重试。"
        case .codexUpgradeRequired: return "当前模型需要较新版本的 Codex，请先更新 Codex 后重试。"
        }
    }
}

/// One resident turn at a time. World execution stays in the caller's formal tool bridge.
@MainActor final class ResidentCodexAgent {
    private(set) var failureStage: String?
    private(set) var failureCode: String?
    private(set) var failureCategory: String?
    private(set) var failureDetail: String?
    /// 失败那一轮在协议里的状态，以及错误体的**形状**（只列协议字段名，绝不含值）：
    /// 当安全投影只能给出 `unclassified` 时，靠它区分「`turn.error` 缺失」和
    /// 「错误体不是预期字典」。只进 E2E/日志，不进用户界面。
    private(set) var failureTurnStatus: String?
    private(set) var failureErrorShape: String?
    private(set) var didSendTurnStart = false
    private var stage = "preflight"
    private var lastSafeErrorCode: String?
    private var lastSafeErrorCategory: String?
    private var lastSafeErrorDetail: String?
    typealias TransportFactory = (URL, [String], URL, [String: String]) -> ResidentCodexTransport
    typealias ToolHandler = @MainActor (String, String, Data) async -> ResidentCodexToolReply
    // Only the schemas supplied by the trusted application register capabilities.
    private var registeredTools: Set<String> = []
    private var allowsSilentCompletion: (@MainActor () -> Bool)?
    private var successfulToolCall = false
    private let executableURL: URL
    private let workingDirectoryURL: URL
    private let environment: [String: String]
    private let turnTimeout: TimeInterval
    private let factory: TransportFactory
    private var operationID: UUID?
    private var transport: ResidentCodexTransport?
    private var threadID: String?
    private var turnID: String?
    private var acceptingTurn = false
    private var finalMessages: [(id: String, text: String)] = []
    private var terminal: Result<ResidentCodexAgentOutcome, Error>?
    private var waiter: CheckedContinuation<ResidentCodexAgentOutcome, Error>?

    init(executableURL: URL, workingDirectoryURL: URL,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         turnTimeout: TimeInterval = 180, transportFactory: TransportFactory? = nil) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = ResidentCodexPolicy.environment(from: environment)
        self.turnTimeout = turnTimeout.isFinite ? max(0.01, min(turnTimeout, 3_600)) : 180
        self.factory = transportFactory ?? { executable, arguments, directory, environment in
            ResidentCodexTransport(executableURL: executable, arguments: arguments,
                                   currentDirectoryURL: directory, environment: environment)
        }
    }

    func send(prompt: String, imageURLs: [URL] = [], sessionID: String?, toolsJSON: Data,
              allowsSilentCompletion: @escaping @MainActor () -> Bool = { false },
              onToolCall: @escaping ToolHandler) async throws -> ResidentCodexAgentOutcome {
        try Task.checkCancellation()
        guard operationID == nil else { throw ResidentCodexAgentError.busy }
        let tools = try Self.dynamicTools(toolsJSON)
        registeredTools = Set(tools.compactMap { $0["name"] as? String })
        self.allowsSilentCompletion = allowsSilentCompletion
        successfulToolCall = false
        let token = UUID()
        operationID = token
        failureStage = nil; failureCode = nil; failureCategory = nil; failureDetail = nil
        failureTurnStatus = nil; failureErrorShape = nil; didSendTurnStart = false
        stage = "preflight"; lastSafeErrorCode = nil; lastSafeErrorCategory = nil; lastSafeErrorDetail = nil
        terminal = nil; threadID = nil; turnID = nil; acceptingTurn = false; finalMessages = []
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((self?.turnTimeout ?? 180) * 1_000_000_000)) }
            catch { return }
            guard let self, self.operationID == token else { return }
            self.fail(ResidentCodexAgentError.timedOut)
        }
        defer {
            deadline.cancel()
            transport?.onClosed = nil
            transport?.onNotification = nil
            transport?.onServerRequest = nil
            transport?.close(); transport = nil
            operationID = nil; acceptingTurn = false
            registeredTools = []; self.allowsSilentCompletion = nil
        }
        return try await withTaskCancellationHandler {
            do {
                // First process exposes only configuration metadata, never starts a model turn.
                let preflight = factory(executableURL, try ResidentCodexPolicy.arguments(disabling: []), workingDirectoryURL, environment)
                transport = preflight
                try await preflight.start()
                let names = try ResidentCodexPolicy.serverNames(in: await preflight.request(method: "config/read", params: Self.encode(["includeLayers": false])))
                preflight.close()
                try Task.checkCancellation()
                if let terminal { return try terminal.get() }

                let connection = factory(executableURL, try ResidentCodexPolicy.arguments(disabling: names), workingDirectoryURL, environment)
                stage = "config"
                transport = connection
                connection.onClosed = { [weak self] error in
                    guard let self, self.operationID == token else { return }
                    self.complete(.failure(error))
                }
                connection.onNotification = { [weak self] method, data in
                    guard let self, self.operationID == token else { return }
                    self.receive(method: method, data: data)
                }
                connection.onServerRequest = { [weak self] _, params in
                    guard let self, self.operationID == token else { return Self.failedTool("居民会话已结束。") }
                    return await self.performTool(params, token: token, handler: onToolCall)
                }
                try await connection.start()
                try ResidentCodexPolicy.verify(await connection.request(method: "config/read", params: Self.encode(["includeLayers": false])))
                stage = "thread"
                var threadParams: [String: Any] = [
                    "cwd": workingDirectoryURL.path, "approvalPolicy": "never", "sandbox": "read-only",
                    "runtimeWorkspaceRoots": [],
                ]
                let method: String
                if let sessionID, !sessionID.isEmpty {
                    method = "thread/resume"; threadParams["threadId"] = sessionID
                } else {
                    method = "thread/start"
                    threadParams["environments"] = []
                    threadParams["dynamicTools"] = tools
                    threadParams["selectedCapabilityRoots"] = []
                }
                let threadResponse = try Self.object(await connection.request(method: method, params: Self.encode(threadParams)))
                guard let thread = threadResponse["thread"] as? [String: Any],
                      let threadID = thread["id"] as? String, !threadID.isEmpty,
                      sessionID == nil || sessionID == "" || sessionID == threadID else { throw ResidentCodexAgentError.invalidProtocol }
                self.threadID = threadID
                acceptingTurn = true
                stage = "turn"
                didSendTurnStart = true
                // App-prepared attachments use the protocol's native image input.
                // This grants no file tools or additional workspace roots.
                var input: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt, "text_elements": []]]
                input += imageURLs.map { ["type": "localImage", "path": $0.path] }
                let turnResponse = try Self.object(await connection.request(method: "turn/start", params: Self.encode([
                    "threadId": threadID, "environments": [], "approvalPolicy": "never",
                    "cwd": workingDirectoryURL.path, "runtimeWorkspaceRoots": [],
                    "input": input,
                ])))
                guard let turn = turnResponse["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty,
                      self.turnID == nil || self.turnID == id else { throw ResidentCodexAgentError.invalidProtocol }
                self.turnID = id
                if let terminal { return try terminal.get() }
                stage = "wait"
                return try await withCheckedThrowingContinuation { waiter = $0 }
            } catch {
                if failureStage == nil { failureStage = stage; failureCode = lastSafeErrorCode }
                if failureCategory == nil { failureCategory = lastSafeErrorCategory ?? transport?.failureCategory }
                if failureDetail == nil { failureDetail = lastSafeErrorDetail ?? transport?.failureDetail }
                // A queued success notification cannot validate a mismatched RPC response.
                var reportedError = error
                if case .failure(let terminalError) = terminal { reportedError = terminalError }
                if failureDetail?.split(separator: ";").first == "codex_upgrade_required" {
                    switch reportedError {
                    case ResidentCodexAgentError.turnFailed, ResidentCodexTransportError.remoteError:
                        throw ResidentCodexAgentError.codexUpgradeRequired
                    default: break
                    }
                }
                throw reportedError
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == token else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        guard operationID != nil else { return }
        if let threadID, let turnID, let transport {
            // Notification is best effort: closing our process never waits on interruption acknowledgement.
            try? transport.notify(method: "turn/interrupt", params: Self.encode(["threadId": threadID, "turnId": turnID]))
        }
        fail(CancellationError())
    }

    /// Uses the server's active-turn precondition; a missing acknowledgement is
    /// deliberately not retried because the human input may already be accepted.
    func steer(_ text: String) async -> ResidentSteeringDelivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              operationID != nil, terminal == nil, acceptingTurn,
              let threadID, let turnID, let transport else { return .notDelivered }
        do {
            let response = try Self.object(await transport.request(method: "turn/steer", params: Self.encode([
                "threadId": threadID, "expectedTurnId": turnID,
                "input": [["type": "text", "text": text, "text_elements": []]],
            ])))
            // A matching acknowledgement remains proof of delivery even when
            // turn/completed arrives immediately afterwards.
            return response["turnId"] as? String == turnID ? .delivered : .unknown
        } catch ResidentCodexTransportError.remoteError(let code) where [-32600, -32601, -32602].contains(code) {
            return .notDelivered
        } catch { return .unknown }
    }

    private func fail(_ error: Error) {
        complete(.failure(error))
        transport?.close()
    }

    private func complete(_ result: Result<ResidentCodexAgentOutcome, Error>) {
        guard terminal == nil else { return }
        if case .failure = result {
            failureStage = stage; failureCode = lastSafeErrorCode
            failureCategory = lastSafeErrorCategory ?? transport?.failureCategory
            failureDetail = lastSafeErrorDetail ?? transport?.failureDetail
        }
        terminal = result
        if let waiter { self.waiter = nil; waiter.resume(with: result) }
    }

    private func receive(method: String, data: Data) {
        guard terminal == nil, acceptingTurn,
              let params = try? Self.object(data), params["threadId"] as? String == threadID else { return }
        if method == "turn/started" {
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String,
                  !id.isEmpty, turnID == nil || turnID == id else { return }
            turnID = id
        } else if method == "item/completed" {
            guard let turnID, params["turnId"] as? String == turnID,
                  let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                  item["phase"] == nil || item["phase"] is NSNull || item["phase"] as? String == "final_answer",
                  let id = item["id"] as? String, let text = item["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let index = finalMessages.firstIndex(where: { $0.id == id }) { finalMessages[index].text = text }
            else { finalMessages.append((id, text)) }
        } else if method == "turn/completed" {
            guard let turnID, let threadID, let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == turnID else { return }
            guard turn["status"] as? String == "completed" else {
                failureTurnStatus = turn["status"] as? String
                recordSafeError(turn["error"])
                complete(.failure(ResidentCodexAgentError.turnFailed)); return
            }
            let reply = finalMessages.map(\.text).joined(separator: "\n\n")
            guard !reply.isEmpty || (successfulToolCall && allowsSilentCompletion?() == true) else {
                complete(.failure(ResidentCodexAgentError.noFinalAnswer)); return
            }
            complete(.success(ResidentCodexAgentOutcome(reply: reply, sessionID: threadID)))
        } else if method == "error" {
            guard let turnID, params["turnId"] as? String == turnID else { return }
            if params["error"] != nil { recordSafeError(params["error"]) }
            if params["willRetry"] as? Bool == true { return }
            complete(.failure(ResidentCodexAgentError.turnFailed))
        }
    }

    /// 只记录**安全投影**后的失败因与错误形状（协议字段名集合，绝不含值/文案）。
    /// 形状是最后一个诊断出口：当 `category`/`detail` 只能给出 `unclassified`
    /// 时，它能说明错误体到底是缺失、是字符串、还是带了未识别的 `codexErrorInfo`。
    private func recordSafeError(_ raw: Any?) {
        guard let error = raw as? [String: Any] else {
            failureErrorShape = raw == nil ? "absent" : "non-object"
            return
        }
        failureErrorShape = error.keys.sorted().joined(separator: ",")
        lastSafeErrorCode = ResidentCodexSafeError.code(from: error["codexErrorInfo"])
        lastSafeErrorCategory = error["category"] as? String
            ?? ResidentCodexSafeError.category(message: error["message"] as? String)
        lastSafeErrorDetail = error["detail"] as? String
            ?? ResidentCodexSafeError.detail(message: error["message"] as? String)
    }

    private func performTool(_ data: Data, token: UUID, handler: ToolHandler) async -> Data {
        guard terminal == nil, acceptingTurn, let threadID, let turnID,
              let params = try? Self.object(data), params["threadId"] as? String == threadID,
              params["turnId"] as? String == turnID,
              params["namespace"] == nil || params["namespace"] is NSNull,
              let callID = params["callId"] as? String, !callID.isEmpty,
              let name = params["tool"] as? String, registeredTools.contains(name),
              let arguments = params["arguments"] as? [String: Any],
              let encoded = try? Self.encode(arguments) else { return Self.failedTool("工具请求不属于当前居民会话。") }
        let result = await handler(callID, name, encoded)
        guard operationID == token, terminal == nil, !Task.isCancelled else { return Self.failedTool("居民会话已结束。") }
        guard (try? JSONSerialization.jsonObject(with: result.resultJSON, options: .fragmentsAllowed)) != nil,
              let text = String(data: result.resultJSON, encoding: .utf8) else { return Self.failedTool("空间工具返回无效结果。") }
        // 原生图片通道：仅当工具回执携带强类型真实 PNG 时才附加 inputImage；
        // 文件路径或纯文本永不伪装成视觉输入，超预算按失败处理。
        var contentItems: [[String: String]] = [["type": "inputText", "text": text]]
        if let image = result.image {
            let png = image.pngData
            guard !png.isEmpty, png.count <= ResidentCodexAgent.maximumToolImageBytes else {
                return Self.failedTool("画面数据超出预算，无法作为视觉输入。")
            }
            contentItems.append(["type": "inputImage",
                "imageUrl": "data:image/png;base64," + png.base64EncodedString()])
        }
        // 全部验证（JSON 有效性 + 图片预算）通过后才承认本轮工具成功。
        if !result.isError { successfulToolCall = true }
        return (try? Self.encode(["success": !result.isError, "contentItems": contentItems])) ?? Self.failedTool("空间工具返回无效结果。")
    }

    private static func failedTool(_ text: String) -> Data {
        // All strings are fixed local messages; serialization of these literals cannot fail.
        (try? encode(["success": false, "contentItems": [["type": "inputText", "text": text]]])) ?? Data("{}".utf8)
    }

    private static func dynamicTools(_ data: Data) throws -> [[String: Any]] {
        guard let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !tools.isEmpty else { throw ResidentCodexAgentError.invalidTools }
        var names = Set<String>()
        return try tools.map { tool in
            guard let name = tool["name"] as? String,
                  name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
                  names.insert(name).inserted,
                  let description = tool["description"] as? String,
                  let schema = tool["inputSchema"] as? [String: Any], schema["type"] as? String == "object" else { throw ResidentCodexAgentError.invalidTools }
            return ["type": "function", "name": name, "description": description, "inputSchema": schema]
        }
    }

    /// 单张工具回执图片的宿主侧预算（与捕获策略 512 KiB 对齐）。
    private static let maximumToolImageBytes = 512 * 1024

    private static func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ResidentCodexAgentError.invalidProtocol }
        return value
    }
}
