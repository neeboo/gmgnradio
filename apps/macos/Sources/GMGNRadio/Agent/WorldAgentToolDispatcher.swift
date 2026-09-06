import Foundation
import WorldRuntime

struct WorldAgentToolResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let code: String?
    let message: String
    let snapshot: WorldAgentSnapshot
    let route: WorldPath?
}

@MainActor
final class WorldAgentToolDispatcher {
    private struct PlaceArguments: Decodable {
        let placeID: String

        enum CodingKeys: String, CodingKey {
            case placeID = "place_id"
        }
    }

    private struct ActivityArguments: Decodable {
        let activityID: String

        enum CodingKeys: String, CodingKey {
            case activityID = "activity_id"
        }
    }

    private struct StopActivityArguments: Decodable {
        let reason: String?
    }

    private struct WeatherArguments: Decodable {
        let weather: String
    }

    private struct CameraArguments: Decodable {
        let cameraID: String

        enum CodingKeys: String, CodingKey {
            case cameraID = "camera_id"
        }
    }

    private struct GoalArguments: Decodable {
        let goalID: String
        let summary: String?

        enum CodingKeys: String, CodingKey {
            case goalID = "goal_id"
            case summary
        }
    }

    private let takeoverEnabled: @MainActor () -> Bool
    private let onActivityStarted: @MainActor (WorldAgentContext, String) -> Void
    let context: WorldAgentContext
    private var completedCalls: [String: RealtimeDJToolResult] = [:]

    init(
        takeoverEnabled: @escaping @MainActor () -> Bool,
        context: WorldAgentContext,
        onActivityStarted: @escaping @MainActor (WorldAgentContext, String) -> Void = { _, _ in }
    ) {
        self.takeoverEnabled = takeoverEnabled
        self.context = context
        self.onActivityStarted = onActivityStarted
    }

    var providerTools: [[String: Any]] {
        WorldAgentToolContract.providerTools(for: context.manifest)
    }

    func handles(_ name: String) -> Bool {
        WorldAgentToolContract.capabilities.contains { $0.name == name }
    }

    func handle(_ call: RealtimeDJToolCall) async -> RealtimeDJToolResult {
        if let completed = completedCalls[call.id] {
            return completed
        }
        let result = execute(call)
        completedCalls[call.id] = result
        return result
    }

    func resetSession() {
        completedCalls.removeAll(keepingCapacity: true)
    }

    private func execute(_ call: RealtimeDJToolCall) -> RealtimeDJToolResult {
        guard let capability = WorldAgentToolContract.capabilities.first(where: {
            $0.name == call.name
        }) else {
            return makeResult(
                callID: call.id,
                ok: false,
                code: "unknown_world_tool",
                message: "未知的世界工具：\(call.name)"
            )
        }
        guard takeoverEnabled() || !capability.requiresTakeover else {
            return makeResult(
                callID: call.id,
                ok: false,
                code: "world_takeover_disabled",
                message: "用户尚未允许 AI 控制角色和世界"
            )
        }

        do {
            var route: WorldPath?
            let message: String
            switch call.name {
            case "inspect_world":
                message = "已读取当前世界状态"
            case "list_places":
                message = "当前世界有 \(context.snapshot.places.count) 个可到达地点"
            case "list_available_activities":
                message = "当前世界有 \(context.snapshot.activities.count) 个可执行活动"
            case "plan_route":
                let arguments = try decode(PlaceArguments.self, from: call.argumentsJSON)
                route = try context.planRoute(to: arguments.placeID)
                message = "已规划前往 \(arguments.placeID) 的路线"
            case "move_to":
                let arguments = try decode(PlaceArguments.self, from: call.argumentsJSON)
                route = try context.move(to: arguments.placeID)
                message = "角色开始前往 \(arguments.placeID)"
            case "start_activity":
                let arguments = try decode(ActivityArguments.self, from: call.argumentsJSON)
                try context.startActivity(id: arguments.activityID)
                if let requestID = context.currentActivityRequestID {
                    onActivityStarted(context, requestID)
                }
                message = "角色开始执行 \(arguments.activityID)"
            case "stop_activity":
                let arguments = try decode(
                    StopActivityArguments.self,
                    from: call.argumentsJSON
                )
                try context.stopActivity(reason: arguments.reason)
                message = "角色已停止当前活动"
            case "look_at":
                let arguments = try decode(PlaceArguments.self, from: call.argumentsJSON)
                try context.look(at: arguments.placeID)
                message = "角色已转向 \(arguments.placeID)"
            case "set_world_weather":
                let arguments = try decode(WeatherArguments.self, from: call.argumentsJSON)
                guard let weather = WorldWeather(rawValue: arguments.weather) else {
                    throw WorldAgentDispatchError.invalidWeather(arguments.weather)
                }
                try context.setWeather(weather)
                message = "世界天气已切换为 \(weather.rawValue)"
            case "move_live_camera":
                let arguments = try decode(CameraArguments.self, from: call.argumentsJSON)
                try context.selectCamera(id: arguments.cameraID)
                message = "Live Cam 已切换到 \(arguments.cameraID)"
            case "complete_world_goal":
                let arguments = try decode(GoalArguments.self, from: call.argumentsJSON)
                try context.completeGoal(
                    id: arguments.goalID,
                    summary: arguments.summary
                )
                message = "已记录目标 \(arguments.goalID) 完成"
            default:
                preconditionFailure("Capability and dispatcher are out of sync")
            }
            return makeResult(
                callID: call.id,
                ok: true,
                code: nil,
                message: message,
                route: route
            )
        } catch {
            return makeResult(
                callID: call.id,
                ok: false,
                code: Self.errorCode(for: error),
                message: Self.errorMessage(for: error)
            )
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WorldAgentDispatchError.invalidArguments
        }
    }

    private func makeResult(
        callID: String,
        ok: Bool,
        code: String?,
        message: String,
        route: WorldPath? = nil
    ) -> RealtimeDJToolResult {
        let response = WorldAgentToolResponse(
            ok: ok,
            code: code,
            message: message,
            snapshot: context.snapshot,
            route: route
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let resultJSON = (try? encoder.encode(response)) ?? Data(
            #"{"ok":false,"code":"encoding_failed","message":"世界状态编码失败"}"#.utf8
        )
        return RealtimeDJToolResult(
            callID: callID,
            resultJSON: resultJSON,
            isError: !ok
        )
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case WorldAgentDispatchError.invalidArguments: "invalid_arguments"
        case WorldAgentDispatchError.invalidWeather: "invalid_weather"
        case WorldAgentContextError.unknownPlace: "unknown_place"
        case WorldAgentContextError.unknownActivity: "unknown_activity"
        case WorldAgentContextError.unknownCamera: "unknown_camera"
        case WorldAgentContextError.invalidGoalID: "invalid_goal_id"
        case WorldAgentContextError.activityRejected: "activity_rejected"
        case WorldAgentContextError.routeBlocked: "route_blocked"
        case WorldSimulationError.goalAlreadyCompleted: "goal_already_completed"
        default: "world_tool_failed"
        }
    }

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case WorldAgentDispatchError.invalidArguments:
            "工具参数无法解析"
        case let WorldAgentDispatchError.invalidWeather(weather):
            "世界不支持天气 \(weather)"
        case let WorldAgentContextError.unknownPlace(id):
            "世界中没有地点 \(id)"
        case let WorldAgentContextError.unknownActivity(id):
            "世界中没有活动 \(id)"
        case let WorldAgentContextError.unknownCamera(id):
            "世界中没有镜头 \(id)"
        case WorldAgentContextError.invalidGoalID:
            "目标 ID 不能为空"
        case let WorldAgentContextError.activityRejected(id):
            "当前状态无法开始活动 \(id)"
        case let WorldAgentContextError.routeBlocked(id):
            "前往 \(id) 的路线被阻挡"
        case let WorldSimulationError.goalAlreadyCompleted(goalID):
            "目标 \(goalID) 已经完成"
        default:
            "世界操作失败：\(String(describing: error))"
        }
    }
}

private enum WorldAgentDispatchError: Error, Equatable {
    case invalidArguments
    case invalidWeather(String)
}
