import Foundation

struct ResidentCodexToolReply: Sendable {
    let resultJSON: Data
    let isError: Bool
}

struct ResidentCodexAgentOutcome: Sendable {
    let reply: String
    let sessionID: String
}

enum ResidentCodexAgentError: Error, LocalizedError {
    case busy, invalidProtocol, invalidTools, turnFailed, noFinalAnswer, timedOut
    var errorDescription: String? {
        switch self {
        case .busy: return "居民正在处理上一条消息。"
        case .invalidProtocol: return "居民会话返回的数据不完整。"
        case .invalidTools: return "当前空间的居民工具配置无效。"
        case .turnFailed: return "居民未能完成本轮回复，请重试。"
        case .noFinalAnswer: return "居民没有返回完整答复，请重试。"
        case .timedOut: return "居民回复等待超时，请重试。"
        }
    }
}

/// One resident turn at a time. World execution stays in the caller's formal tool bridge.
@MainActor final class ResidentCodexAgent {
    typealias TransportFactory = (URL, [String], URL, [String: String]) -> ResidentCodexTransport
    typealias ToolHandler = @MainActor (String, String, Data) async -> ResidentCodexToolReply
    private static let allowedTools: Set<String> = ["inspect_world", "list_available_activities", "start_activity", "stop_activity"]
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

    func send(prompt: String, sessionID: String?, toolsJSON: Data,
              onToolCall: @escaping ToolHandler) async throws -> ResidentCodexAgentOutcome {
        try Task.checkCancellation()
        guard operationID == nil else { throw ResidentCodexAgentError.busy }
        let tools = try Self.dynamicTools(toolsJSON)
        let token = UUID()
        operationID = token
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
                let turnResponse = try Self.object(await connection.request(method: "turn/start", params: Self.encode([
                    "threadId": threadID, "environments": [], "approvalPolicy": "never",
                    "cwd": workingDirectoryURL.path, "runtimeWorkspaceRoots": [],
                    "input": [["type": "text", "text": prompt, "text_elements": []]],
                ])))
                guard let turn = turnResponse["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty,
                      self.turnID == nil || self.turnID == id else { throw ResidentCodexAgentError.invalidProtocol }
                self.turnID = id
                if let terminal { return try terminal.get() }
                return try await withCheckedThrowingContinuation { waiter = $0 }
            } catch {
                // A queued success notification cannot validate a mismatched RPC response.
                if case .failure(let terminalError) = terminal { throw terminalError }
                throw error
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

    private func fail(_ error: Error) {
        complete(.failure(error))
        transport?.close()
    }

    private func complete(_ result: Result<ResidentCodexAgentOutcome, Error>) {
        guard terminal == nil else { return }
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
            guard turn["status"] as? String == "completed" else { complete(.failure(ResidentCodexAgentError.turnFailed)); return }
            let reply = finalMessages.map(\.text).joined(separator: "\n\n")
            guard !reply.isEmpty else { complete(.failure(ResidentCodexAgentError.noFinalAnswer)); return }
            complete(.success(ResidentCodexAgentOutcome(reply: reply, sessionID: threadID)))
        } else if method == "error" {
            guard let turnID, params["turnId"] as? String == turnID else { return }
            complete(.failure(ResidentCodexAgentError.turnFailed))
        }
    }

    private func performTool(_ data: Data, token: UUID, handler: ToolHandler) async -> Data {
        guard terminal == nil, acceptingTurn, let threadID, let turnID,
              let params = try? Self.object(data), params["threadId"] as? String == threadID,
              params["turnId"] as? String == turnID,
              params["namespace"] == nil || params["namespace"] is NSNull,
              let callID = params["callId"] as? String, !callID.isEmpty,
              let name = params["tool"] as? String, Self.allowedTools.contains(name),
              let arguments = params["arguments"] as? [String: Any],
              let encoded = try? Self.encode(arguments) else { return Self.failedTool("工具请求不属于当前居民会话。") }
        let result = await handler(callID, name, encoded)
        guard operationID == token, terminal == nil, !Task.isCancelled else { return Self.failedTool("居民会话已结束。") }
        guard (try? JSONSerialization.jsonObject(with: result.resultJSON, options: .fragmentsAllowed)) != nil,
              let text = String(data: result.resultJSON, encoding: .utf8) else { return Self.failedTool("空间工具返回无效结果。") }
        return (try? Self.encode(["success": !result.isError, "contentItems": [["type": "inputText", "text": text]]])) ?? Self.failedTool("空间工具返回无效结果。")
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
            guard let name = tool["name"] as? String, allowedTools.contains(name), names.insert(name).inserted,
                  let description = tool["description"] as? String,
                  let schema = tool["inputSchema"] as? [String: Any] else { throw ResidentCodexAgentError.invalidTools }
            return ["type": "function", "name": name, "description": description, "inputSchema": schema]
        }
    }

    private static func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ResidentCodexAgentError.invalidProtocol }
        return value
    }
}
