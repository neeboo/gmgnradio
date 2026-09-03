public struct WorldActivityAnchor: Codable, Equatable, Sendable {
    public let id: String
    public let action: String
    public let entryWaypointID: String
    public let transform: WorldTransform
    public let motionID: String?
    public let propIDs: [String]
    public let interruptible: Bool

    public init(
        id: String,
        action: String,
        entryWaypointID: String,
        transform: WorldTransform,
        motionID: String?,
        propIDs: [String],
        interruptible: Bool
    ) {
        self.id = id
        self.action = action
        self.entryWaypointID = entryWaypointID
        self.transform = transform
        self.motionID = motionID
        self.propIDs = propIDs
        self.interruptible = interruptible
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
