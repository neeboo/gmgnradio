import Foundation
import WorldRuntime

struct WorldAgentCapability: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let requiresTakeover: Bool
    let parameters: [String: WorldAgentToolParameter]
    let requiredParameters: [String]

    init(
        name: String,
        description: String,
        requiresTakeover: Bool,
        parameters: [String: WorldAgentToolParameter] = [:],
        requiredParameters: [String] = []
    ) {
        self.name = name
        self.description = description
        self.requiresTakeover = requiresTakeover
        self.parameters = parameters
        self.requiredParameters = requiredParameters
    }
}

struct WorldAgentToolParameter: Codable, Equatable, Sendable {
    let type: String
    let description: String
    let allowedValues: [String]?

    init(
        type: String,
        description: String,
        allowedValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.allowedValues = allowedValues
    }
}

enum WorldAgentToolContract {
    static let capabilities: [WorldAgentCapability] = [
        WorldAgentCapability(
            name: "inspect_world",
            description: "读取世界、角色、天气、活动、移动和镜头的当前快照",
            requiresTakeover: false
        ),
        WorldAgentCapability(
            name: "list_places",
            description: "列出当前世界清单中可以到达和观察的地点",
            requiresTakeover: false
        ),
        WorldAgentCapability(
            name: "list_available_activities",
            description: "列出当前世界清单与已绑定物件使用能力中可执行的生活活动",
            requiresTakeover: false
        ),
        WorldAgentCapability(
            name: "plan_route",
            description: "从角色当前位置规划到指定地点的路线，不移动角色",
            requiresTakeover: false,
            parameters: [
                "place_id": WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单中的地点 ID"
                ),
            ],
            requiredParameters: ["place_id"]
        ),
        WorldAgentCapability(
            name: "move_to",
            description: "让角色沿世界路线移动到指定地点",
            requiresTakeover: true,
            parameters: [
                "place_id": WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单中的地点 ID"
                ),
            ],
            requiredParameters: ["place_id"]
        ),
        WorldAgentCapability(
            name: "start_activity",
            description: "让角色执行世界清单或已绑定物件使用能力的活动（如 coffee.brew@物件编号）",
            requiresTakeover: true,
            parameters: [
                "activity_id": WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单或已绑定物件能力中的活动 ID"
                ),
            ],
            requiredParameters: ["activity_id"]
        ),
        WorldAgentCapability(
            name: "stop_activity",
            description: "停止角色当前的生活活动并回到安全待机",
            requiresTakeover: true,
            parameters: [
                "reason": WorldAgentToolParameter(
                    type: "string",
                    description: "停止活动的可选原因"
                ),
            ]
        ),
        WorldAgentCapability(
            name: "look_at",
            description: "让角色转向世界中的地点",
            requiresTakeover: true,
            parameters: [
                "place_id": WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单中的地点 ID"
                ),
            ],
            requiredParameters: ["place_id"]
        ),
        WorldAgentCapability(
            name: "set_world_weather",
            description: "改变当前世界天气",
            requiresTakeover: true,
            parameters: [
                "weather": WorldAgentToolParameter(
                    type: "string",
                    description: "天气",
                    allowedValues: WorldWeather.allCases.map(\.rawValue)
                ),
            ],
            requiredParameters: ["weather"]
        ),
        WorldAgentCapability(
            name: "move_live_camera",
            description: "将 Live Cam 切换到世界清单中的机位",
            requiresTakeover: true,
            parameters: [
                "camera_id": WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单中的镜头 ID"
                ),
            ],
            requiredParameters: ["camera_id"]
        ),
        WorldAgentCapability(
            name: "complete_world_goal",
            description: "记录一个世界目标已经完成",
            requiresTakeover: true,
            parameters: [
                "goal_id": WorldAgentToolParameter(
                    type: "string",
                    description: "调用方生成并保持稳定的目标 ID"
                ),
                "summary": WorldAgentToolParameter(
                    type: "string",
                    description: "目标完成情况的可选摘要"
                ),
            ],
            requiredParameters: ["goal_id"]
        ),
    ]

    static func capabilities(for manifest: WorldManifest) -> [WorldAgentCapability] {
        let placeIDs = manifest.waypoints.filter(\.enabled).map(\.id).sorted()
        let activityIDs = manifest.activities.map(\.id).sorted()
        let cameraIDs = manifest.cameras.map(\.id).sorted()

        return capabilities.map { capability in
            var parameters = capability.parameters
            switch capability.name {
            case "plan_route", "move_to", "look_at":
                parameters["place_id"] = WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单中的地点 ID",
                    allowedValues: placeIDs
                )
            case "start_activity":
                parameters["activity_id"] = WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单或已绑定物件能力中的活动 ID",
                    allowedValues: activityIDs
                )
            case "move_live_camera":
                parameters["camera_id"] = WorldAgentToolParameter(
                    type: "string",
                    description: "世界清单中的镜头 ID",
                    allowedValues: cameraIDs
                )
            default:
                break
            }
            return WorldAgentCapability(
                name: capability.name,
                description: capability.description,
                requiresTakeover: capability.requiresTakeover,
                parameters: parameters,
                requiredParameters: capability.requiredParameters
            )
        }
    }

    static func providerTools(for manifest: WorldManifest) -> [[String: Any]] {
        capabilities(for: manifest).map { capability in
            let properties = capability.parameters.mapValues { parameter in
                var schema: [String: Any] = [
                    "type": parameter.type,
                    "description": parameter.description,
                ]
                if let allowedValues = parameter.allowedValues {
                    schema["enum"] = allowedValues
                }
                return schema
            }
            return [
                "type": "function",
                "function": [
                    "name": capability.name,
                    "description": capability.description,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": capability.requiredParameters,
                        "additionalProperties": false,
                    ],
                ],
            ]
        }
    }
}
