import Foundation

public enum WorldWeather: String, Codable, CaseIterable, Equatable, Sendable {
    case clear
    case cloudy
    case rain
    case snow
}

public struct WorldObjectState: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var transform: WorldTransform
    public var metadata: [String: String]

    public init(
        isEnabled: Bool = true,
        transform: WorldTransform,
        metadata: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.transform = transform
        self.metadata = metadata
    }
}

public enum WorldActivityStatus: String, Codable, Equatable, Sendable {
    case running
    case interrupted
}

public struct WorldActivityState: Codable, Equatable, Sendable {
    public var activityID: String
    public var status: WorldActivityStatus
    public var startedAt: Date
    public var elapsedActiveTime: TimeInterval
    public var interruptionReason: String?

    public init(
        activityID: String,
        status: WorldActivityStatus,
        startedAt: Date,
        elapsedActiveTime: TimeInterval = 0,
        interruptionReason: String? = nil
    ) {
        self.activityID = activityID
        self.status = status
        self.startedAt = startedAt
        self.elapsedActiveTime = elapsedActiveTime
        self.interruptionReason = interruptionReason
    }
}

public struct WorldState: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var worldID: String
    public var worldTime: Date
    public var lastObservedWallTime: Date
    public var weather: WorldWeather
    public var agentTransform: WorldTransform
    public var liveCamera: WorldCameraState?
    public var activeActivity: WorldActivityState?
    public var objectStates: [String: WorldObjectState]
    public var completedGoals: [String: WorldGoalState]

    public init(
        revision: UInt64,
        worldID: String,
        worldTime: Date,
        lastObservedWallTime: Date,
        weather: WorldWeather,
        agentTransform: WorldTransform,
        liveCamera: WorldCameraState? = nil,
        activeActivity: WorldActivityState? = nil,
        objectStates: [String: WorldObjectState] = [:],
        completedGoals: [String: WorldGoalState] = [:]
    ) {
        self.revision = revision
        self.worldID = worldID
        self.worldTime = worldTime
        self.lastObservedWallTime = lastObservedWallTime
        self.weather = weather
        self.agentTransform = agentTransform
        self.liveCamera = liveCamera
        self.activeActivity = activeActivity
        self.objectStates = objectStates
        self.completedGoals = completedGoals
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case worldID
        case worldTime
        case lastObservedWallTime
        case weather
        case agentTransform
        case liveCamera
        case activeActivity
        case objectStates
        case completedGoals
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        worldID = try container.decode(String.self, forKey: .worldID)
        worldTime = try container.decode(Date.self, forKey: .worldTime)
        lastObservedWallTime = try container.decode(
            Date.self,
            forKey: .lastObservedWallTime
        )
        weather = try container.decode(WorldWeather.self, forKey: .weather)
        agentTransform = try container.decode(
            WorldTransform.self,
            forKey: .agentTransform
        )
        liveCamera = try container.decodeIfPresent(
            WorldCameraState.self,
            forKey: .liveCamera
        )
        activeActivity = try container.decodeIfPresent(
            WorldActivityState.self,
            forKey: .activeActivity
        )
        objectStates = try container.decodeIfPresent(
            [String: WorldObjectState].self,
            forKey: .objectStates
        ) ?? [:]
        completedGoals = try container.decodeIfPresent(
            [String: WorldGoalState].self,
            forKey: .completedGoals
        ) ?? [:]
    }
}
