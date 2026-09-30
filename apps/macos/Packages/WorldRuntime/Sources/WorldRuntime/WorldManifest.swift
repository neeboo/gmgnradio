/// 活动入口的**几何来源**。两选一 —— 这个和类型在结构上就排除了"同一件事有两份几何"。
public enum WorldActivityEntry: Equatable, Sendable {
    /// 世界固有锚点：几何随世界烘焙，`id` 是导航图里的路点（`wp.spawn`、`wp.jukebox`…）。
    case waypoint(id: String, transform: WorldTransform)
    /// 道具功能点锚点：几何**不在这里**。它由道具声明（本体坐标系下的局部点）× 摆放
    /// transform 在运行时派生，且**永不落盘**。
    ///
    /// `propID` 必须是一件 `prop.procedural` 资源，并且那件道具声明了一个
    /// `standingSpot` 功能点把这个活动绑成自己的接近锚点 —— 否则活动在运行时
    /// 没有锚点可用（`WorldPackageValidator` 会直接判包非法）。
    case functionPoint(propID: String)
}

/// `WorldActivityEntry.functionPoint` 的 JSON 形态：`{"propID": "wish_machine.device"}`。
public struct WorldActivityFunctionPointRef: Codable, Equatable, Sendable {
    public let propID: String

    public init(propID: String) {
        self.propID = propID
    }
}

public struct WorldActivityAnchor: Codable, Equatable, Sendable {
    public let id: String
    public let action: String
    public let entry: WorldActivityEntry
    public let motionID: String?
    public let propIDs: [String]
    public let interruptible: Bool

    public init(
        id: String,
        action: String,
        entry: WorldActivityEntry,
        motionID: String?,
        propIDs: [String],
        interruptible: Bool
    ) {
        self.id = id
        self.action = action
        self.entry = entry
        self.motionID = motionID
        self.propIDs = propIDs
        self.interruptible = interruptible
    }

    /// 世界固有锚点的构造形态（既有签名，逐字保留）。
    public init(
        id: String,
        action: String,
        entryWaypointID: String,
        transform: WorldTransform,
        motionID: String?,
        propIDs: [String],
        interruptible: Bool
    ) {
        self.init(
            id: id, action: action,
            entry: .waypoint(id: entryWaypointID, transform: transform),
            motionID: motionID, propIDs: propIDs, interruptible: interruptible
        )
    }

    /// 道具功能点锚点的构造形态：**只有绑定，没有几何**。
    public init(
        id: String,
        action: String,
        propID: String,
        motionID: String? = nil,
        propIDs: [String],
        interruptible: Bool
    ) {
        self.init(
            id: id, action: action,
            entry: .functionPoint(propID: propID),
            motionID: motionID, propIDs: propIDs, interruptible: interruptible
        )
    }

    /// 烘焙的入口路点。道具功能点锚点**没有**它（`nil`），调用方必须显式分支，
    /// 不能靠一个空字符串蒙混过关。
    public var entryWaypointID: String? {
        guard case let .waypoint(id, _) = entry else { return nil }
        return id
    }

    /// 烘焙的锚点变换。道具功能点锚点**没有**它。
    public var transform: WorldTransform? {
        guard case let .waypoint(_, transform) = entry else { return nil }
        return transform
    }

    /// 这个锚点的功能点属于哪件道具（世界固有锚点为 `nil`）。
    public var functionPointPropID: String? {
        guard case let .functionPoint(propID) = entry else { return nil }
        return propID
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, entryWaypointID, transform, functionPoint
        case motionID, propIDs, interruptible
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decode(String.self, forKey: .action)
        motionID = try container.decodeIfPresent(String.self, forKey: .motionID)
        propIDs = try container.decode([String].self, forKey: .propIDs)
        interruptible = try container.decode(Bool.self, forKey: .interruptible)

        let waypointID = try container.decodeIfPresent(String.self, forKey: .entryWaypointID)
        let waypointTransform = try container.decodeIfPresent(WorldTransform.self, forKey: .transform)
        let functionPoint = try container.decodeIfPresent(
            WorldActivityFunctionPointRef.self, forKey: .functionPoint
        )

        switch (waypointID, waypointTransform, functionPoint) {
        case let (.some(id), .some(transform), .none):
            entry = .waypoint(id: id, transform: transform)
        case let (.none, .none, .some(ref)) where !ref.propID.isEmpty:
            entry = .functionPoint(propID: ref.propID)
        default:
            // fail-closed：既不给几何、又给两份几何、或绑到空道具上的锚点，
            // 一律拒绝装载，而不是猜一个。
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription:
                    "活动锚点 \(id) 的入口必须**恰好**是 (entryWaypointID + transform) 或 functionPoint 之一"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(motionID, forKey: .motionID)
        try container.encode(propIDs, forKey: .propIDs)
        try container.encode(interruptible, forKey: .interruptible)
        switch entry {
        case let .waypoint(waypointID, transform):
            try container.encode(waypointID, forKey: .entryWaypointID)
            try container.encode(transform, forKey: .transform)
        case let .functionPoint(propID):
            try container.encode(
                WorldActivityFunctionPointRef(propID: propID), forKey: .functionPoint
            )
        }
    }
}

public struct WorldCameraAnchor: Codable, Equatable, Sendable {
    public let id: String
    public let transform: WorldTransform
    public let fieldOfViewDegrees: Float
    public let nearPlane: Float
    public let farPlane: Float

    public init(
        id: String,
        transform: WorldTransform,
        fieldOfViewDegrees: Float,
        nearPlane: Float,
        farPlane: Float
    ) {
        self.id = id
        self.transform = transform
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.nearPlane = nearPlane
        self.farPlane = farPlane
    }
}

public struct WorldResource: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let sha256: String
    public let kind: String

    public init(id: String, path: String, sha256: String, kind: String) {
        self.id = id
        self.path = path
        self.sha256 = sha256
        self.kind = kind
    }
}

public struct WorldManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packageID: String
    public let packageVersion: String
    public let worldID: String
    public let displayName: String
    public let calibration: WorldCalibration
    public let spawn: WorldTransform
    public let collisionVolumes: [WorldCollisionVolume]
    public let waypoints: [WorldWaypoint]
    public let routes: [WorldRoute]
    public let activities: [WorldActivityAnchor]
    /// Complete, package-authored execution contracts for `activities`.
    ///
    /// Schema-v1 packages created before living activity contracts were added
    /// decode this field as an empty array. `ActivityCatalog` provides a
    /// deterministic compatibility adapter for those packages.
    public let activityDefinitions: [LifeActivityDefinition]
    public let cameras: [WorldCameraAnchor]
    public let capabilities: Set<WorldCapability>
    public let resources: [WorldResource]

    public init(
        schemaVersion: Int,
        packageID: String,
        packageVersion: String,
        worldID: String,
        displayName: String,
        calibration: WorldCalibration,
        spawn: WorldTransform,
        collisionVolumes: [WorldCollisionVolume],
        waypoints: [WorldWaypoint],
        routes: [WorldRoute],
        activities: [WorldActivityAnchor],
        activityDefinitions: [LifeActivityDefinition] = [],
        cameras: [WorldCameraAnchor],
        capabilities: Set<WorldCapability>,
        resources: [WorldResource]
    ) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.worldID = worldID
        self.displayName = displayName
        self.calibration = calibration
        self.spawn = spawn
        self.collisionVolumes = collisionVolumes
        self.waypoints = waypoints
        self.routes = routes
        self.activities = activities
        self.activityDefinitions = activityDefinitions
        self.cameras = cameras
        self.capabilities = capabilities
        self.resources = resources
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case packageID
        case packageVersion
        case worldID
        case displayName
        case calibration
        case spawn
        case collisionVolumes
        case waypoints
        case routes
        case activities
        case activityDefinitions
        case cameras
        case capabilities
        case resources
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        packageID = try container.decode(String.self, forKey: .packageID)
        packageVersion = try container.decode(String.self, forKey: .packageVersion)
        worldID = try container.decode(String.self, forKey: .worldID)
        displayName = try container.decode(String.self, forKey: .displayName)
        calibration = try container.decode(WorldCalibration.self, forKey: .calibration)
        spawn = try container.decode(WorldTransform.self, forKey: .spawn)
        collisionVolumes = try container.decode(
            [WorldCollisionVolume].self,
            forKey: .collisionVolumes
        )
        waypoints = try container.decode([WorldWaypoint].self, forKey: .waypoints)
        routes = try container.decode([WorldRoute].self, forKey: .routes)
        activities = try container.decode([WorldActivityAnchor].self, forKey: .activities)
        activityDefinitions = try container.decodeIfPresent(
            [LifeActivityDefinition].self,
            forKey: .activityDefinitions
        ) ?? []
        cameras = try container.decode([WorldCameraAnchor].self, forKey: .cameras)
        capabilities = try container.decode(Set<WorldCapability>.self, forKey: .capabilities)
        resources = try container.decode([WorldResource].self, forKey: .resources)
    }
}
