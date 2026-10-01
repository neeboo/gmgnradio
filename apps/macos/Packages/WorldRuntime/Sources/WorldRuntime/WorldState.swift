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
    public var layoutRevision: UInt64 = 0
    public var layoutReceipts: [String: WorldPropLayoutCommand] = [:]
    public var layoutUndo: WorldPropLayoutUndo?
    public var heldProp: WorldHeldProp?
    /// 被**有意删除**的生成资产留下的墓碑：物件编号 → 墓碑。
    ///
    /// 为什么它不是"objectStates 里少了一条"就够：
    /// - "有意删掉"与"意外丢了"必须分得开（对账器、读回、面板都要按前者解释）；
    /// - 被删物件引用过的内容（模型字节 / 碰撞代理）在删除之后仍要答得出来 —— 否则
    ///   引用计数就无从派生，"共享文件该不该留"再没有输入；
    /// - 权威 `world_records` 的墓碑是**记录级**的（行不删只标记），这一份是同一件事在
    ///   世界文档里的对应物：删的是"它在这个世界里存在"，不是"它曾经存在过"。
    ///
    /// 可选、纯增量：为空时合成 `Codable` **不编码这个键**（`encodeIfPresent`），
    /// 于是没有任何删除的存档其 JSON 与改造前逐字节相同。
    public var propTombstones: [String: WorldPropTombstone]?
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
        heldProp: WorldHeldProp? = nil,
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
        self.heldProp = heldProp
        self.objectStates = objectStates
        self.completedGoals = completedGoals
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case layoutRevision, layoutReceipts, layoutUndo, heldProp
        case propTombstones
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
        layoutRevision = try container.decodeIfPresent(UInt64.self, forKey: .layoutRevision) ?? 0
        layoutReceipts = try container.decodeIfPresent([String: WorldPropLayoutCommand].self, forKey: .layoutReceipts) ?? [:]
        layoutUndo = try container.decodeIfPresent(WorldPropLayoutUndo.self, forKey: .layoutUndo)
        heldProp = try container.decodeIfPresent(WorldHeldProp.self, forKey: .heldProp)
        // 旧存档没有这个键 ⇒ nil（= "没有任何删除"），不是空字典：编码时 nil 不写键，
        // 于是没有删除的存档与改造前**逐字节相同**。
        propTombstones = try container.decodeIfPresent(
            [String: WorldPropTombstone].self, forKey: .propTombstones)
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
