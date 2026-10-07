import Foundation
import CoreFoundation

/// A resident lease exports only music discovery and preparation. Playback still
/// belongs to the room's activity, and the shared dispatcher keeps the real result.
@MainActor
final class ResidentMusicToolBridge {
    static let names: Set<String> = [
        "read_radio_state", "read_current_track", "list_music_playlists",
        "read_music_playlist", "prepare_music_track",
    ]
    /// Explicitly supplied by a host implementing the existing radio actions.
    /// Program planning and spatial mutation are deliberately separate services.
    static let playbackNames: Set<String> = names.union([
        "search_music", "play_program_track", "next_track", "previous_track",
        "pause_music", "resume_music", "set_lyrics_mode",
    ])
    static let planningNames: Set<String> = ["replan_program", "activate_prepared_program", "insert_track"]
    static let spatialNames: Set<String> = ["set_spatial_environment", "move_spatial_camera"]

    private let dispatcher: DJAgentToolDispatcher
    private let actions: any DJAgentRadioActions
    private let isCurrent: @MainActor () -> Bool
    private let exportedNames: Set<String>
    private let permitsWorldTransitionResult: Bool

    init(actions: any DJAgentRadioActions, isCurrent: @escaping @MainActor () -> Bool,
         exportedNames: Set<String> = ResidentMusicToolBridge.names,
         permitsWorldTransitionResult: Bool = false,
         takeoverEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.actions = actions
        dispatcher = DJAgentToolDispatcher(takeoverEnabled: takeoverEnabled, actions: actions)
        self.isCurrent = isCurrent
        self.permitsWorldTransitionResult = permitsWorldTransitionResult
        self.exportedNames = exportedNames.intersection(Self.playbackNames.union(Self.planningNames).union(Self.spatialNames))
    }

    var tools: [ResidentWorldToolSession.AdditionalTool] {
        let available = Set(actions.snapshot(takeoverEnabled: true).capabilities.map(\.name))
        let capabilities = DJAgentCapabilityManifest.capabilities.filter { exportedNames.contains($0.name) && available.contains($0.name) }
        return DJAgentCapabilityManifest.providerTools(for: capabilities).compactMap { entry in
            guard let function = entry["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let description = function["description"] as? String,
                  let schema = function["parameters"] as? [String: Any],
                  let capability = capabilities.first(where: { $0.name == name }) else { return nil }
            return ResidentWorldToolSession.AdditionalTool(name: name, description: description,
                inputSchema: schema, validate: { Self.validate($0, for: capability) },
                handle: { [self] id, arguments in
                    await handle(id: id, capability: capability, argumentsJSON: arguments)
                })
        }
    }

    private static func validate(_ arguments: [String: Any], for capability: DJAgentCapability) -> Bool {
        guard Set(arguments.keys).isSubset(of: Set(capability.parameters.keys)),
              capability.requiredParameters.allSatisfy({ arguments[$0] != nil }) else { return false }
        for (key, value) in arguments {
            guard let parameter = capability.parameters[key] else { return false }
            switch parameter.type {
            case "string":
                guard let text = value as? String,
                      parameter.allowedValues.map({ $0.contains(text) }) ?? true else { return false }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { return false }
            case "number":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { return false }
            default: return false
            }
        }
        return true
    }

    private func handle(id: String, capability: DJAgentCapability, argumentsJSON: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else { return stale(id) }
        guard let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any],
              Self.validate(arguments, for: capability) else {
            return failure(id, code: "invalid_arguments", message: "音乐工具参数不符合当前契约")
        }
        let result = await dispatcher.handle(RealtimeDJToolCall(id: id, name: capability.name, argumentsJSON: argumentsJSON))
        guard !Task.isCancelled else { return stale(id) }
        guard var response = (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] else {
            return failure(id, code: "invalid_music_result", message: "音乐工具返回的数据无效")
        }
        let worldChanged = !isCurrent()
        if worldChanged {
            // A verified scene switch retires this tool's old world lease.
            // Preserve only its already-applied result, never another old-world call.
            guard permitsWorldTransitionResult, capability.name == "set_spatial_environment",
                  arguments["scene"] is String, !result.isError, response["ok"] as? Bool == true else { return stale(id) }
            response["worldChanged"] = true
            response["message"] = "空间已切换"
            response["instruction"] = "空间已切换，本轮旧空间操作租约已结束。请报告结果，后续操作在下一轮使用新空间。"
        }
        if var state = response["state"] as? [String: Any] {
            if let capabilities = state["capabilities"] as? [[String: Any]] {
                state["capabilities"] = capabilities.filter {
                    ($0["name"] as? String).map(exportedNames.contains) ?? false
                }
            }
            if let program = state["program"] as? [Any] {
                state["programTotalCount"] = program.count
                state["program"] = Array(program.prefix(50))
            }
            response["state"] = state
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            return failure(id, code: "invalid_music_result", message: "音乐工具返回的数据无效")
        }
        return RealtimeDJToolResult(callID: result.callID, resultJSON: data, isError: result.isError)
    }

    private func stale(_ id: String) -> RealtimeDJToolResult {
        failure(id, code: "stale_music_session", message: "本轮音乐操作已结束或被停止")
    }

    private func failure(_ id: String, code: String, message: String) -> RealtimeDJToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": false, "code": code, "message": message])) ?? Data("{}".utf8)
        return RealtimeDJToolResult(callID: id, resultJSON: data, isError: true)
    }
}
