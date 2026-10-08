import Foundation

/// Rust owns each fresh Claude process and its native resident MCP adapter.
actor RustResidentClaudeClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    typealias Identity = RustCodexSessionClient.Identity
    typealias Tool = RustCodexSessionClient.Tool
    typealias Image = RustCodexSessionClient.Image
    struct Configuration: Sendable {
        let executable: String; let adapterExecutable: String; let hostEndpoint: String
        let environment: [String: String]; let allowSilentCompletion: Bool
    }
    struct PendingTool: Sendable {
        let identity: Identity; let round: String; let callID: String
        let toolName: String; let arguments: Data; let phase: String; let operationID: String?
    }
    struct Receipt: Sendable {
        let identity: Identity; let round: String; let callID: String
        let operationID: String; let status: String; let output: Data; let images: [Image]
        init(identity: Identity, round: String, callID: String, operationID: String,
             status: String, output: Data, images: [Image] = []) {
            self.identity = identity; self.round = round; self.callID = callID
            self.operationID = operationID; self.status = status; self.output = output; self.images = images
        }
    }
    struct Result: Sendable { let state: String; let text: String; let round: String? }
    struct Callbacks: Sendable {
        let authorize: @Sendable (PendingTool) async throws -> String?
        let execute: @Sendable (PendingTool) async throws -> Receipt
        let textDelta: @Sendable (String) async -> Void
        let state: @Sendable (String) async -> Void
    }
    enum ClientError: Error { case busy, invalidProtocol, identityMismatch, transport, unknownExecution }
    private let call: Call
    private var active: Identity?
    private var round: String?
    private var cancellationRequested = false
    private var approvals: [String: (PendingTool, String)] = [:]
    private var handled = Set<String>()
    init(call: @escaping Call) { self.call = call }
    private func fields(_ i: Identity) -> [String: Any] {
        ["worldID": i.worldID, "residentScope": i.residentScope, "hostSessionID": i.hostSessionID,
         "runID": i.runID, "eventID": i.eventID]
    }
    private func object(_ d: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ClientError.invalidProtocol }
        return value
    }
    private func request(_ method: String, _ p: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: p); let call = self.call
        do { return try await Task.detached { try call(method, data) }.value }
        catch { throw ClientError.transport }
    }
    func run(identity: Identity, configuration c: Configuration, input: String,
             durableUserText: String? = nil, memoryContext: String? = nil,
             tools: [Tool], callbacks: Callbacks) async throws -> Result {
        guard active == nil else { throw ClientError.busy }
        guard tools.count <= 64, c.executable.hasPrefix("/"), c.adapterExecutable.hasPrefix("/") else { throw ClientError.invalidProtocol }
        active = identity; round = nil; cancellationRequested = false; approvals.removeAll(); handled.removeAll()
        var p = fields(identity)
        p.merge(["executable": c.executable, "adapterExecutable": c.adapterExecutable,
                 "hostEndpoint": c.hostEndpoint, "environment": c.environment,
                 "allowSilentCompletion": c.allowSilentCompletion, "input": input],
                uniquingKeysWith: { _, value in value })
        if let durableUserText { p["durableUserText"] = durableUserText }
        if let memoryContext { p["memoryContext"] = memoryContext }
        p["tools"] = try tools.map { t in ["name": t.name, "description": t.description, "effect": t.effect,
                                             "inputSchema": try object(t.inputSchema)] as [String: Any] }
        let started = try object(await request("agent_claude_start", p))
        guard started["started"] as? Bool == true else { throw ClientError.invalidProtocol }
        var previousText = ""; var previousState = ""
        while true {
            if Task.isCancelled && !cancellationRequested { try await cancel() }
            let snapshot = try object(await request("agent_claude_read", fields(identity)))
            guard let state = snapshot["state"] as? String, let text = snapshot["text"] as? String,
                  let pending = snapshot["pendingTools"] as? [[String: Any]], pending.count <= 64 else { throw ClientError.invalidProtocol }
            try bind(snapshot)
            if text != previousText {
                guard text.hasPrefix(previousText) else { throw ClientError.invalidProtocol }
                let delta = String(text.dropFirst(previousText.count)); previousText = text
                if !delta.isEmpty { await callbacks.textDelta(delta) }
            }
            if state != previousState { previousState = state; await callbacks.state(state) }
            if ["completed", "failed", "cancelled", "unknown"].contains(state) {
                if state == "unknown" { throw ClientError.unknownExecution }
                if state == "completed", round == nil { throw ClientError.invalidProtocol }
                active = nil
                return Result(state: state, text: text, round: round)
            }
            guard ["running", "cancel_requested"].contains(state) else { throw ClientError.invalidProtocol }
            if state == "running" && !cancellationRequested {
                for item in pending {
                    let tool = try parse(item, identity: identity); let key = tool.phase + ":" + tool.callID
                    guard !handled.contains(key) else { continue }
                    guard handled.count < 256 else { throw ClientError.invalidProtocol }; handled.insert(key)
                    if tool.phase == "authorize" {
                        let operation = try await callbacks.authorize(tool)
                        if cancellationRequested || Task.isCancelled { try await cancel(); break }
                        var approval = fields(identity); approval["round"] = tool.round
                        approval["callID"] = tool.callID; approval["toolName"] = tool.toolName
                        approval["arguments"] = try object(tool.arguments); approval["decision"] = operation == nil ? "rejected" : "approved"
                        if let operation {
                            guard !operation.isEmpty else { throw ClientError.invalidProtocol }
                            approval["operationID"] = operation; approvals[tool.callID] = (tool, operation)
                        }
                        _ = try await request("agent_claude_authorize", approval)
                    } else {
                        guard let (proposal, operation) = approvals[tool.callID], operation == tool.operationID,
                              proposal.round == tool.round, proposal.toolName == tool.toolName,
                              proposal.arguments == tool.arguments else { throw ClientError.identityMismatch }
                        if cancellationRequested || Task.isCancelled { try await cancel(); break }
                        let receipt: Receipt
                        do { receipt = try await callbacks.execute(tool) }
                        catch { receipt = .init(identity: identity, round: tool.round, callID: tool.callID,
                                               operationID: operation, status: "unknown", output: Data("{\"error\":\"host_execution_unknown\"}".utf8)) }
                        try await submit(receipt, for: tool)
                    }
                }
            }
            await Task.detached { try? await Task.sleep(nanoseconds: 150_000_000) }.value
        }
    }
    private func bind(_ p: [String: Any]) throws {
        if let session = p["round"] as? String, !session.isEmpty {
            if let old = round, old != session { throw ClientError.identityMismatch }; round = session
        }
    }
    private func parse(_ p: [String: Any], identity: Identity) throws -> PendingTool {
        for (key, value) in fields(identity) { guard p[key] as? String == value as? String else { throw ClientError.identityMismatch } }
        guard let session = p["round"] as? String, !session.isEmpty, let call = p["callID"] as? String, !call.isEmpty,
              let tool = p["toolName"] as? String, !tool.isEmpty, let arguments = p["arguments"] as? [String: Any],
              let phase = p["phase"] as? String, ["authorize", "execute"].contains(phase) else { throw ClientError.invalidProtocol }
        try bind(p); let operation = p["operationID"] as? String
        guard phase != "execute" || (operation != nil && !operation!.isEmpty) else { throw ClientError.invalidProtocol }
        return .init(identity: identity, round: session, callID: call, toolName: tool,
                     arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), phase: phase, operationID: operation)
    }
    private func submit(_ receipt: Receipt, for tool: PendingTool) async throws {
        guard receipt.identity == tool.identity, receipt.round == tool.round,
              receipt.callID == tool.callID, receipt.operationID == tool.operationID, receipt.images.count <= 4,
              ["completed", "unknown", "rejected"].contains(receipt.status) else { throw ClientError.identityMismatch }
        var p = fields(receipt.identity); p["round"] = receipt.round; p["callID"] = receipt.callID
        p["operationID"] = receipt.operationID; p["status"] = receipt.status; p["output"] = try object(receipt.output)
        if !receipt.images.isEmpty { p["images"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt.images)) }
        _ = try await request("agent_claude_tool_receipt", p)
    }
    func cancel() async throws {
        guard let identity = active else { return }
        _ = try await request("agent_claude_cancel", fields(identity)); cancellationRequested = true
    }
}
