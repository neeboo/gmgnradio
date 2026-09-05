import Foundation

/// A short-lived capability lease for one user request in one selected world.
/// Transport-provided IDs identify calls only; they cannot select a different world.
@MainActor
final class ResidentWorldToolSession {
    struct CallRecord: Codable, Equatable, Sendable {
        let scopeID: UUID
        let worldID: String
        let callID: String
        let toolName: String
        let activityID: String?
        let ok: Bool
        let replayed: Bool
    }

    private struct CallIdentity: Equatable {
        let name: String
        let arguments: Data
    }

    static let allowedToolNames: Set<String> = [
        "inspect_world", "list_available_activities", "start_activity", "stop_activity",
    ]

    let scopeID: UUID
    let worldID: String
    let toolSchemasJSON: Data
    private let dispatcher: WorldAgentToolDispatcher
    private let deadline: Date
    private let now: @MainActor () -> Date
    private let isCurrent: @MainActor () -> Bool
    private let beforeDispatch: (@MainActor (String, String, Data) -> Void)?
    private let afterDispatch: (@MainActor (String, Data, RealtimeDJToolResult) async -> RealtimeDJToolResult)?
    private let onCancel: (@MainActor () -> Void)?
    private var cancelled = false
    private var identities: [String: CallIdentity] = [:]
    private var results: [String: RealtimeDJToolResult] = [:]
    private var pending: [String: Task<RealtimeDJToolResult, Never>] = [:]
    private(set) var records: [CallRecord] = []

    init(
        scopeID: UUID,
        worldID: String,
        dispatcher: WorldAgentToolDispatcher,
        deadline: Date,
        now: @escaping @MainActor () -> Date = { Date() },
        isCurrent: @escaping @MainActor () -> Bool,
        beforeDispatch: (@MainActor (String, String, Data) -> Void)? = nil,
        afterDispatch: (@MainActor (String, Data, RealtimeDJToolResult) async -> RealtimeDJToolResult)? = nil,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        self.scopeID = scopeID
        self.worldID = worldID
        self.dispatcher = dispatcher
        self.deadline = deadline
        self.now = now
        self.isCurrent = isCurrent
        self.beforeDispatch = beforeDispatch
        self.afterDispatch = afterDispatch
        self.onCancel = onCancel
        let schemas = dispatcher.providerTools.compactMap { tool -> [String: Any]? in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  Self.allowedToolNames.contains(name) else { return nil }
            return [
                "name": name,
                "description": function["description"] ?? "",
                "inputSchema": function["parameters"] ?? [:],
            ]
        }
        // The existing contract consists only of JSON primitives.
        toolSchemasJSON = (try? JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel?()
        for task in pending.values { task.cancel() }
    }

    func call(requestID: String, name: String, argumentsJSON: Data) async -> RealtimeDJToolResult {
        var activityID: String?
        var replayed = false
        let result: RealtimeDJToolResult
        if cancelled || Task.isCancelled {
            result = failure(requestID, "tool_session_cancelled", "本次空间操作已取消")
        } else if !isCurrent() || dispatcher.context.snapshot.worldID != worldID {
            result = failure(requestID, "stale_world_session", "空间或会话已经切换，请重新发起操作")
        } else if now() >= deadline {
            result = failure(requestID, "tool_session_expired", "本次空间操作已超时")
        } else if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = failure(requestID, "invalid_call_id", "工具调用编号不能为空")
        } else if !Self.allowedToolNames.contains(name) {
            result = failure(requestID, "tool_not_allowed", "本次会话未开放这个工具")
        } else if let arguments = validatedArguments(name: name, data: argumentsJSON),
                  let canonical = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) {
            if let requestedActivity = arguments["activity_id"] as? String,
               dispatcher.context.manifest.activities.contains(where: { $0.id == requestedActivity }) {
                activityID = requestedActivity
            }
            let identity = CallIdentity(name: name, arguments: canonical)
            if let existing = identities[requestID], existing != identity {
                result = failure(requestID, "call_id_conflict", "同一调用编号不能用于不同操作或参数")
            } else if let completed = results[requestID] {
                replayed = true
                result = completed
            } else if let running = pending[requestID] {
                replayed = true
                result = await awaitResult(running)
            } else {
                identities[requestID] = identity
                let task = Task { @MainActor in
                    guard !self.cancelled, !Task.isCancelled else {
                        return self.failure(requestID, "tool_session_cancelled", "本次空间操作已取消")
                    }
                    guard self.isCurrent(), self.dispatcher.context.snapshot.worldID == self.worldID else {
                        return self.failure(requestID, "stale_world_session", "空间或会话已经切换")
                    }
                    guard self.now() < self.deadline else {
                        return self.failure(requestID, "tool_session_expired", "本次空间操作已超时")
                    }
                    self.beforeDispatch?(requestID, name, canonical)
                    let dispatched = await self.dispatcher.handle(RealtimeDJToolCall(
                        id: self.scopeID.uuidString + ":" + requestID,
                        name: name, argumentsJSON: canonical
                    ))
                    let response = RealtimeDJToolResult(callID: requestID, resultJSON: dispatched.resultJSON, isError: dispatched.isError)
                    if let afterDispatch = self.afterDispatch { return await afterDispatch(name, canonical, response) }
                    return response
                }
                pending[requestID] = task
                result = await awaitResult(task)
                pending[requestID] = nil
                results[requestID] = result
            }
        } else {
            result = failure(requestID, "invalid_arguments", "工具参数不符合当前空间契约")
        }
        records.append(CallRecord(
            scopeID: scopeID,
            worldID: worldID,
            callID: requestID,
            toolName: Self.allowedToolNames.contains(name) ? name : "unsupported",
            activityID: activityID,
            ok: !result.isError,
            replayed: replayed
        ))
        return result
    }

    private func awaitResult(_ task: Task<RealtimeDJToolResult, Never>) async -> RealtimeDJToolResult {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func validatedArguments(name: String, data: Data) -> [String: Any]? {
        guard let capability = WorldAgentToolContract.capabilities.first(where: { $0.name == name }),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(arguments.keys).isSubset(of: Set(capability.parameters.keys)),
              capability.requiredParameters.allSatisfy({ arguments[$0] != nil }) else { return nil }
        // The four exposed tools currently accept strings only. Fail closed if
        // the shared contract introduces another type until this bridge supports it.
        for (key, value) in arguments {
            guard capability.parameters[key]?.type == "string", value is String else { return nil }
        }
        return arguments
    }

    private func failure(_ callID: String, _ code: String, _ message: String) -> RealtimeDJToolResult {
        struct Failure: Encodable { let ok = false; let code: String; let message: String }
        let data = (try? JSONEncoder().encode(Failure(code: code, message: message))) ?? Data("{\"ok\":false}".utf8)
        return RealtimeDJToolResult(callID: callID, resultJSON: data, isError: true)
    }
}
