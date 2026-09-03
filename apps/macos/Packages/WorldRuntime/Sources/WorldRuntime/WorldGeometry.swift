public struct WorldVector3: Codable, Equatable, Hashable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct WorldQuaternion: Codable, Equatable, Hashable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

public struct WorldTransform: Codable, Equatable, Hashable, Sendable {
    public let position: WorldVector3
    public let rotation: WorldQuaternion
    public let scale: WorldVector3

    public init(
        position: WorldVector3,
        rotation: WorldQuaternion,
        scale: WorldVector3
    ) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }
}

public struct WorldCalibration: Codable, Equatable, Sendable {
    public let visualToGameplay: [Float]
    public let metersPerUnit: Float

    public init(visualToGameplay: [Float], metersPerUnit: Float) {
        self.visualToGameplay = visualToGameplay
        self.metersPerUnit = metersPerUnit
    }
}

public struct WorldCollisionVolume: Codable, Equatable, Sendable {
    public let id: String
    public let center: WorldVector3
    public let halfExtents: WorldVector3
    public let rotation: WorldQuaternion
    public let isBlocking: Bool

    public init(
        id: String,
        center: WorldVector3,
        halfExtents: WorldVector3,
        rotation: WorldQuaternion,
        isBlocking: Bool
    ) {
        self.id = id
        self.center = center
        self.halfExtents = halfExtents
        self.rotation = rotation
        self.isBlocking = isBlocking
    }
}

public struct WorldWaypoint: Codable, Equatable, Sendable {
    public let id: String
    public let position: WorldVector3
    public let arrivalRadius: Float
    public let enabled: Bool

    public init(
        id: String,
        position: WorldVector3,
        arrivalRadius: Float,
        enabled: Bool
    ) {
        self.id = id
        self.position = position
        self.arrivalRadius = arrivalRadius
        self.enabled = enabled
    }
}

public struct WorldRoute: Codable, Equatable, Sendable {
    public let id: String
    public let waypointIDs: [String]
    public let bidirectional: Bool
    public let enabled: Bool

    public init(
        id: String,
        waypointIDs: [String],
        bidirectional: Bool,
        enabled: Bool
    ) {
        self.id = id
        self.waypointIDs = waypointIDs
        self.bidirectional = bidirectional
        self.enabled = enabled
    }
}
