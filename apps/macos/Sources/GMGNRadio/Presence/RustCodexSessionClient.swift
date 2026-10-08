import Foundation

/// Opt-in Rust-owned CLI session. Executable, environment and input are supplied
/// by the trusted caller; no credential discovery, process spawning or fallback.
actor RustCodexSessionClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Identity: Codable, Sendable, Equatable {
        let worldID: String
        let residentScope: String
        let hostSessionID: String
        let runID: String
        let eventID: String
    }
    struct Configuration: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let root: String
        let cwd: String
        let resumeThreadID: String?
        let allowSilentCompletion: Bool
        init(executable: String, arguments: [String], environment: [String: String], root: String,
             cwd: String, resumeThreadID: String? = nil, allowSilentCompletion: Bool = false) {
            self.executable = executable; self.arguments = arguments; self.environment = environment
            self.root = root; self.cwd = cwd; self.resumeThreadID = resumeThreadID
            self.allowSilentCompletion = allowSilentCompletion
        }
    }
    enum Input: Sendable {
        case text(String)
        case image(url: String)
        case localImage(path: String)
        fileprivate var wire: [String: Any] {
            switch self {
            case .text(let text): return ["type": "text", "text": text, "text_elements": [[String: Any]]()]
            case .image(let url): return ["type": "image", "url": url]
            case .localImage(let path): return ["type": "localImage", "path": path]
            }
        }
    }
    struct Tool: Sendable {
        let name: String; let description: String; let effect: String; let inputSchema: Data
    }
    struct PendingTool: Sendable {
        let identity: Identity
        let threadID: String
        let turnID: String
        let callID: String
        let toolName: String
        let arguments: Data
        let phase: String
        let operationID: String?
    }
    struct Receipt: Sendable {
        let identity: Identity
        let threadID: String
        let turnID: String
        let callID: String
        let operationID: String
        let status: String
        let output: Data
        let images: [Image]
        init(identity: Identity, threadID: String, turnID: String, callID: String,
             operationID: String, status: String, output: Data, images: [Image] = []) {
            self.identity = identity; self.threadID = threadID; self.turnID = turnID
            self.callID = callID; self.operationID = operationID; self.status = status
            self.output = output; self.images = images
        }
    }
    struct Image: Codable, Sendable {
        let mediaType: String
        let base64: String
        init(bytes: Data, mediaType: String) { self.mediaType = mediaType; self.base64 = bytes.base64EncodedString() }
    }
    struct Result: Sendable {
        let state: String
        let text: String
        let threadID: String?
        let turnID: String?
    }
    struct Callbacks: Sendable {
        let authorize: @Sendable (PendingTool) async throws -> String?
        let execute: @Sendable (PendingTool) async throws -> Receipt
        let textDelta: @Sendable (String) async -> Void
        let state: @Sendable (String) async -> Void
    }
    enum ClientError: Error { case busy, invalidProtocol, identityMismatch, transport, unknownExecution }
    private let call: Call
    private var active: Identity?
    private var cancellationRequested = false
    private var approvals: [String: (PendingTool, String)] = [:]
    private var handled = Set<String>()
    private var threadID: String?
    private var turnID: String?
    init(call: @escaping Call) { self.call = call }
    struct Continuity: Sendable { let threadID: String?; let freshSession: Bool }
    func continuity(identity: Identity, importLegacyThreadID: String? = nil) async throws -> Continuity {
        var p = fields(identity); p["continuity"] = true
        if let legacy = importLegacyThreadID { p["importLegacyThreadID"] = legacy }
        let response = try object(await request("agent_cli_read", p))
        let thread = response["threadID"] as? String
        guard let fresh = response["freshSession"] as? Bool, fresh == (thread == nil),
              thread == nil || thread?.isEmpty == false else { throw ClientError.invalidProtocol }
        return .init(threadID: thread, freshSession: fresh)
    }
    func reset(identity: Identity) async throws {
        let response = try object(await request("agent_cli_reset", fields(identity)))
        guard response["reset"] as? Bool == true else { throw ClientError.invalidProtocol }
    }

    private func fields(_ i: Identity) -> [String: Any] {
        ["worldID": i.worldID, "residentScope": i.residentScope, "hostSessionID": i.hostSessionID,
         "runID": i.runID, "eventID": i.eventID]
    }
    private func object(_ d: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ClientError.invalidProtocol }
        return object
    }
    private func request(_ method: String, _ p: [String: Any]) async throws -> Data {
        let d = try JSONSerialization.data(withJSONObject: p)
        let call = self.call
        do { return try await Task.detached { try call(method, d) }.value }
        catch { throw ClientError.transport }
    }
    func run(identity: Identity, configuration: Configuration, input: [Input], tools: [Tool], callbacks: Callbacks) async throws -> Result {
        guard active == nil else { throw ClientError.busy }
        guard configuration.executable.hasPrefix("/"), configuration.root.hasPrefix("/"),
              configuration.cwd.hasPrefix("/"), tools.count <= 64 else { throw ClientError.invalidProtocol }
        active = identity; cancellationRequested = false; approvals.removeAll(); handled.removeAll()
        threadID = nil; turnID = nil
        var p = fields(identity)
        p["executable"] = configuration.executable; p["arguments"] = configuration.arguments
        p["environment"] = configuration.environment; p["root"] = configuration.root; p["cwd"] = configuration.cwd
        p["allowSilentCompletion"] = configuration.allowSilentCompletion; p["input"] = input.map(\.wire)
        if let legacy = configuration.resumeThreadID { p["importLegacyThreadID"] = legacy }
        p["tools"] = try tools.map { t in ["name": t.name, "description": t.description, "effect": t.effect, "inputSchema": try object(t.inputSchema)] as [String: Any] }
        // Keep the identity reserved after ambiguous transport failures.
        _ = try await request("agent_cli_start", p)
        var previousText = ""; var previousState = ""
        while true {
            if Task.isCancelled && !cancellationRequested { try await cancel() }
            let snapshot = try object(await request("agent_cli_read", fields(identity)))
            guard let state = snapshot["state"] as? String, let text = snapshot["text"] as? String,
                  let pending = snapshot["pendingTools"] as? [[String: Any]], pending.count <= 128 else { throw ClientError.invalidProtocol }
            try bindSession(snapshot)
            if text != previousText {
                guard text.hasPrefix(previousText) else { throw ClientError.invalidProtocol }
                let delta = String(text.dropFirst(previousText.count)); previousText = text
                if !delta.isEmpty { await callbacks.textDelta(delta) }
            }
            if state != previousState { previousState = state; await callbacks.state(state) }
            if ["completed", "failed", "cancelled", "unknown"].contains(state) {
                if state == "unknown" { throw ClientError.unknownExecution }
                if state == "completed", threadID == nil || turnID == nil { throw ClientError.invalidProtocol }
                active = nil
                return Result(state: state, text: text, threadID: threadID, turnID: turnID)
            }
            guard ["preflight", "running", "cancel_requested"].contains(state) else { throw ClientError.invalidProtocol }
            if state == "running" && !cancellationRequested {
                for item in pending {
                    let tool = try parse(item, identity: identity)
                    let key = tool.phase + ":" + tool.callID
                    guard !handled.contains(key) else { continue }
                    guard handled.count < 256 else { throw ClientError.invalidProtocol }
                    handled.insert(key)
                    if tool.phase == "authorize" {
                        let operation = try await callbacks.authorize(tool)
                        if cancellationRequested || Task.isCancelled { try await cancel(); break }
                        var approval = fields(identity)
                        approval["threadID"] = tool.threadID; approval["turnID"] = tool.turnID
                        approval["callID"] = tool.callID; approval["toolName"] = tool.toolName
                        approval["arguments"] = try object(tool.arguments); approval["decision"] = operation == nil ? "rejected" : "approved"
                        if let operation {
                            guard !operation.isEmpty else { throw ClientError.invalidProtocol }
                            approval["operationID"] = operation; approvals[tool.callID] = (tool, operation)
                        }
                        _ = try await request("agent_cli_authorize", approval)
                    } else {
                        guard let (proposal, operation) = approvals[tool.callID], operation == tool.operationID,
                              proposal.toolName == tool.toolName, proposal.arguments == tool.arguments,
                              proposal.threadID == tool.threadID, proposal.turnID == tool.turnID else { throw ClientError.identityMismatch }
                        if cancellationRequested || Task.isCancelled { try await cancel(); break }
                        let receipt: Receipt
                        do { receipt = try await callbacks.execute(tool) }
                        catch { receipt = Receipt(identity: identity, threadID: tool.threadID, turnID: tool.turnID,
                            callID: tool.callID, operationID: operation, status: "unknown", output: Data("{\"error\":\"host_execution_unknown\"}".utf8)) }
                        try await submit(receipt, tool: tool)
                    }
                }
            }
            await Task.detached { try? await Task.sleep(nanoseconds: 150_000_000) }.value
        }
    }
    private func bindSession(_ p: [String: Any]) throws {
        if let id = p["threadID"] as? String, !id.isEmpty {
            if let old = threadID, old != id { throw ClientError.identityMismatch }; threadID = id
        }
        if let id = p["turnID"] as? String, !id.isEmpty {
            if let old = turnID, old != id { throw ClientError.identityMismatch }; turnID = id
        }
    }
    private func parse(_ p: [String: Any], identity: Identity) throws -> PendingTool {
        for (k, v) in fields(identity) { guard p[k] as? String == v as? String else { throw ClientError.identityMismatch } }
        guard let thread = p["threadID"] as? String, !thread.isEmpty,
              let turn = p["turnID"] as? String, !turn.isEmpty,
              let call = p["callID"] as? String, !call.isEmpty,
              let name = p["toolName"] as? String, !name.isEmpty,
              let args = p["arguments"] as? [String: Any],
              let phase = p["phase"] as? String, ["authorize", "execute"].contains(phase) else { throw ClientError.invalidProtocol }
        try bindSession(p)
        let operation = p["operationID"] as? String
        guard phase != "execute" || (operation != nil && !operation!.isEmpty) else { throw ClientError.invalidProtocol }
        return PendingTool(identity: identity, threadID: thread, turnID: turn, callID: call, toolName: name,
                           arguments: try JSONSerialization.data(withJSONObject: args, options: .sortedKeys), phase: phase, operationID: operation)
    }
    private func submit(_ receipt: Receipt, tool: PendingTool) async throws {
        guard receipt.identity == tool.identity, receipt.threadID == tool.threadID, receipt.turnID == tool.turnID,
              receipt.callID == tool.callID, receipt.operationID == tool.operationID,
              ["completed", "unknown", "rejected"].contains(receipt.status) else { throw ClientError.identityMismatch }
        var p = fields(receipt.identity)
        p["threadID"] = receipt.threadID; p["turnID"] = receipt.turnID; p["callID"] = receipt.callID
        p["operationID"] = receipt.operationID; p["status"] = receipt.status; p["output"] = try object(receipt.output)
        if !receipt.images.isEmpty { p["images"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt.images)) }
        _ = try await request("agent_cli_tool_receipt", p)
    }
    func cancel() async throws {
        guard let identity = active else { return }
        _ = try await request("agent_cli_cancel", fields(identity))
        cancellationRequested = true
    }
}
