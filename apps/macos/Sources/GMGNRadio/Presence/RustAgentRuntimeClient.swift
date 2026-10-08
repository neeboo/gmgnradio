import Foundation
import CryptoKit

/// Opt-in host seam. Provider credentials remain in the caller and HTTP request;
/// this client neither discovers credentials nor writes them to disk or logs.
actor RustAgentRuntimeClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Identity: Codable, Sendable, Equatable {
        let worldID: String
        let residentScope: String
        let hostSessionID: String
        let runID: String
        let eventID: String
    }
    struct Provider: Codable, Sendable {
        let backend: String
        let endpoint: String
        let model: String
        let apiKey: String
        let imageInput: Bool
        init(backend: String, endpoint: String, model: String, apiKey: String, imageInput: Bool = false) {
            self.backend = backend; self.endpoint = endpoint; self.model = model
            self.apiKey = apiKey; self.imageInput = imageInput
        }
    }
    struct Image: Codable, Sendable {
        let mediaType: String
        let base64: String
        init(bytes: Data, mimeType: String) {
            self.mediaType = mimeType; self.base64 = bytes.base64EncodedString()
        }
    }
    struct Tool: Sendable {
        let name: String
        let description: String
        let effect: String
        /// JSON object, provided by the trusted host catalog.
        let inputSchema: Data
    }
    struct PendingTool: Sendable {
        let identity: Identity
        let callID: String
        let toolName: String
        let arguments: Data
        let operationID: String?
        let phase: String
    }
    struct Receipt: Sendable {
        let identity: Identity
        let callID: String
        let operationID: String
        let status: String
        let output: Data
        let images: [Image]
        init(identity: Identity, callID: String, operationID: String, status: String,
             output: Data, images: [Image] = []) {
            self.identity = identity; self.callID = callID; self.operationID = operationID
            self.status = status; self.output = output; self.images = images
        }
    }
    struct Callbacks: Sendable {
        /// Business permission validator returns a stable business operation ID.
        /// This is never derived here from the model's call ID.
        let authorize: @Sendable (PendingTool) async throws -> String?
        let execute: @Sendable (PendingTool) async throws -> Receipt
        let text: @Sendable (String) async -> Void
        let terminal: @Sendable (String) async -> Void
    }
    enum ClientError: Error { case invalidProtocol, receiptMismatch, busy, unknownExecution, transport }
    enum SteeringDelivery: String, Decodable, Sendable { case delivered; case notDelivered = "not_delivered" }
    struct SteeringResult: Decodable, Sendable {
        let delivery: SteeringDelivery
        let duplicate: Bool
        let grantsApplied: Bool
    }
    private let call: Call
    private var active: Identity?
    private var running = false
    private var handled = Set<String>()
    private var approvals: [String: (PendingTool, String)] = [:]
    private var lastText = ""
    private var cancellationRequested = false

    init(call: @escaping Call) { self.call = call }

    private func fields(_ i: Identity) -> [String: Any] {
        ["worldID": i.worldID, "residentScope": i.residentScope,
         "hostSessionID": i.hostSessionID, "runID": i.runID, "eventID": i.eventID]
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidProtocol
        }
        return value
    }
    private func request(_ method: String, _ values: [String: Any]) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: values)
        let call = self.call
        do { return try await Task.detached { try call(method, input) }.value }
        catch { throw ClientError.transport }
    }

    func configure(identity: Identity, provider: Provider, systemPrompt: String, tools: [Tool]) async throws {
        guard active == nil, !running, tools.count <= 64 else { throw ClientError.busy }
        var p = fields(identity)
        p["provider"] = try object(JSONEncoder().encode(provider))
        p["systemPrompt"] = systemPrompt
        p["tools"] = try tools.map { tool in
            ["name": tool.name, "description": tool.description, "effect": tool.effect,
             "inputSchema": try object(tool.inputSchema)] as [String: Any]
        }
        p["operations"] = [[String: Any]]()
        p["dynamicAuthorization"] = true
        _ = try await request("agent_runtime_configure", p)
        active = identity; handled.removeAll(); approvals.removeAll(); lastText = ""; cancellationRequested = false
    }

    /// Single sender. Unknown execution exits without replaying the tool or turn.
    func run(input: String, images: [Image] = [], callbacks: Callbacks) async throws {
        guard let identity = active, !running else { throw ClientError.busy }
        running = true
        defer { running = false }
        var start = fields(identity); start["input"] = input
        if !images.isEmpty { start["images"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(images)) }
        _ = try await request("agent_runtime_start", start)
        while true {
            if Task.isCancelled && !cancellationRequested { try await cancel() }
            let snapshot = try object(await request("agent_runtime_read", fields(identity)))
            guard let state = snapshot["state"] as? String,
                  let text = snapshot["text"] as? String,
                  let pending = snapshot["pendingTools"] as? [[String: Any]], pending.count <= 128 else {
                throw ClientError.invalidProtocol
            }
            if text != lastText { lastText = text; await callbacks.text(text) }
            if ["completed", "failed", "cancelled", "unknown"].contains(state) {
                await callbacks.terminal(state)
                if state == "unknown" { throw ClientError.unknownExecution }
                active = nil
                return
            }
            guard ["running", "cancel_requested"].contains(state) else { throw ClientError.invalidProtocol }
            if !cancellationRequested && state == "running" {
                for value in pending {
                    let tool = try parse(value, identity: identity)
                    let key = tool.phase + ":" + tool.callID
                    guard !handled.contains(key) else { continue }
                    guard handled.count < 256 else { throw ClientError.invalidProtocol }
                    // Mark before yielding: a lost reply must never dispatch again.
                    handled.insert(key)
                    if tool.phase == "authorize" {
                        let operation = try await callbacks.authorize(tool)
                        if cancellationRequested || Task.isCancelled { try await cancel(); break }
                        var approval = fields(identity)
                        approval["callID"] = tool.callID; approval["toolName"] = tool.toolName
                        approval["arguments"] = try object(tool.arguments)
                        approval["decision"] = operation == nil ? "rejected" : "approved"
                        if let operation {
                            guard !operation.isEmpty else { throw ClientError.invalidProtocol }
                            approval["operationID"] = operation
                            approvals[tool.callID] = (tool, operation)
                        }
                        _ = try await request("agent_runtime_authorize", approval)
                    } else {
                        guard let (proposal, operation) = approvals[tool.callID],
                              operation == tool.operationID, proposal.toolName == tool.toolName,
                              proposal.arguments == tool.arguments else { throw ClientError.receiptMismatch }
                        if cancellationRequested || Task.isCancelled { try await cancel(); break }
                        let receipt: Receipt
                        do { receipt = try await callbacks.execute(tool) }
                        catch {
                            // The callback may have performed a world effect before throwing.
                            // Report unknown, never invent success or retry the operation.
                            receipt = Receipt(identity: identity, callID: tool.callID,
                                operationID: tool.operationID!, status: "unknown",
                                output: Data("{\"error\":\"host_execution_unknown\"}".utf8))
                        }
                        try await submit(receipt, for: tool)
                    }
                }
            }
            // Detached sleep avoids a cancelled task spinning while remote cancellation settles.
            await Task.detached { try? await Task.sleep(nanoseconds: 150_000_000) }.value
        }
    }

    private func parse(_ p: [String: Any], identity: Identity) throws -> PendingTool {
        for (key, value) in fields(identity) where key != "eventID" {
            guard p[key] as? String == value as? String else { throw ClientError.receiptMismatch }
        }
        guard let call = p["callID"] as? String, !call.isEmpty,
              let name = p["toolName"] as? String, !name.isEmpty,
              let arguments = p["arguments"] as? [String: Any],
              let phase = p["phase"] as? String, ["authorize", "execute"].contains(phase) else {
            throw ClientError.invalidProtocol
        }
        let op = p["operationID"] as? String
        guard phase != "execute" || (op != nil && !op!.isEmpty) else { throw ClientError.invalidProtocol }
        return PendingTool(identity: identity, callID: call, toolName: name,
                           arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), operationID: op, phase: phase)
    }

    private func submit(_ receipt: Receipt, for tool: PendingTool) async throws {
        guard receipt.identity == tool.identity, receipt.callID == tool.callID,
              receipt.operationID == tool.operationID,
              ["completed", "unknown", "rejected"].contains(receipt.status) else { throw ClientError.receiptMismatch }
        var p = fields(receipt.identity)
        p["callID"] = receipt.callID; p["operationID"] = receipt.operationID
        p["status"] = receipt.status; p["output"] = try object(receipt.output)
        if !receipt.images.isEmpty {
            p["images"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt.images))
        }
        _ = try await request("agent_runtime_tool_receipt", p)
    }

    func cancel() async throws {
        guard let identity = active else { return }
        _ = try await request("agent_runtime_cancel", fields(identity))
        cancellationRequested = true
    }

    /// Caller must first obtain the scheduler's durable steering admission using
    /// precisely this input reference, then finish that admission with the returned
    /// delivery. HTTP acceptance alone does not establish provider delivery.
    func steer(identity: Identity, messageID: String, text: String, inputSHA256: String) async throws -> SteeringResult {
        guard active == identity, running, !cancellationRequested else { throw ClientError.busy }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard !messageID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65536, inputSHA256 == digest else { throw ClientError.invalidProtocol }
        var p = fields(identity)
        p["messageID"] = messageID; p["input"] = text
        p["inputRef"] = ["submissionID": messageID, "inputSHA256": digest, "imageReferences": [String]()] as [String: Any]
        // Dynamic authorization continues to validate each subsequent business operation.
        p["operations"] = [[String: Any]]()
        let data = try await request("agent_runtime_steer", p)
        do { return try JSONDecoder().decode(SteeringResult.self, from: data) }
        catch { throw ClientError.invalidProtocol }
    }

    /// Explicit trusted verification only; never called automatically after unknown.
    func reconcile(verification: Data) async throws {
        _ = try await request("agent_runtime_reconcile", object(verification))
    }
}
