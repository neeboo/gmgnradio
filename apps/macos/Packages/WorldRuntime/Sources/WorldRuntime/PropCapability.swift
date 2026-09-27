import Foundation

/// An explicitly bound, template-backed usage capability for a generated prop.
/// Created only through the formal binding command; never inferred from a
/// prop's display name, and never a generic scripting surface.
public struct WorldPropCapability: Codable, Equatable, Sendable {
    public let objectID: String
    public let templateID: String

    public init(objectID: String, templateID: String) {
        self.objectID = objectID
        self.templateID = templateID
    }

    public var isValid: Bool {
        !objectID.isEmpty && objectID.count <= 256
            && !templateID.isEmpty && templateID.count <= 256
    }
}

public extension WorldObjectState {
    var propCapability: WorldPropCapability? {
        guard let json = metadata["gmgn.prop-capability.v1"], let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldPropCapability.self, from: data), value.isValid
        else { return nil }
        return value
    }

    /// Receipt-anchored per-object usage state. Written only by committed
    /// simulation mutations; `completed` never appears without the matching
    /// activity lifecycle transition.
    var propUsage: WorldPropUsageState? {
        guard let json = metadata[WorldPropUsageState.metadataKey], let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldPropUsageState.self, from: data), value.isValid
        else { return nil }
        return value
    }
}

/// The persisted per-object usage state of a bound capability. A run is
/// `completed` only after its activity reached the terminal transition through
/// the matching playback receipt; movement, withdrawal or a restore never
/// fabricate that.
public struct WorldPropUsageState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case running, completed, stopped, failed
    }

    static let metadataKey = "gmgn.prop-usage.v1"

    public let templateID: String
    public let status: Status
    public let activityRequestID: String
    public let updatedAt: Date
    public let reason: String?

    public init(templateID: String, status: Status, activityRequestID: String,
                updatedAt: Date, reason: String? = nil) {
        self.templateID = templateID
        self.status = status
        self.activityRequestID = activityRequestID
        self.updatedAt = updatedAt
        self.reason = reason
    }

    public var isValid: Bool {
        !templateID.isEmpty && templateID.count <= 256
            && !activityRequestID.isEmpty && activityRequestID.count <= 256
            && (reason == nil || reason!.count <= 256)
    }
}

/// The closed set of in-space simulated usage templates. Every template is an
/// authored `interact` activity: walk to the prop, face it, play the approved
/// button motion, and finish only through the matching playback receipt.
public struct WorldPropActivityTemplate: Sendable {
    public let templateID: String
    public let displayName: String
    public let approachMotionIDs: [String]
    public let enterMotionIDs: [String]
    public let cooldownSeconds: TimeInterval

    /// The enter phase has no timed duration on purpose: a fallback natural
    /// idle never completes the activity, only a real motion receipt does.
    public static let coffeeBrew = WorldPropActivityTemplate(
        templateID: "coffee.brew",
        displayName: "冲泡一杯咖啡",
        approachMotionIDs: [
            "gmgn.motion.bones.walk-loop-pmx",
            "gmgn.motion.bones.walk-loop-vrm",
        ],
        enterMotionIDs: [
            "gmgn.motion.bones.arpg.interact-button-mid-vrm",
            "gmgn.motion.bones.arpg.interact-button-mid-pmx",
        ],
        cooldownSeconds: 45
    )

    public static let supported: [String: WorldPropActivityTemplate] = [
        "coffee.brew": .coffeeBrew,
    ]

    public static func activityID(objectID: String, templateID: String) -> String {
        "\(templateID)@\(objectID)"
    }

    public func definition(objectID: String) -> LifeActivityDefinition {
        let id = Self.activityID(objectID: objectID, templateID: templateID)
        let phases: [ActivityPhaseContract] = [
            ActivityPhaseContract(
                phase: .approach,
                requiredAnchorIDs: [objectID],
                motionIDs: approachMotionIDs
            ),
            ActivityPhaseContract(phase: .enter, motionIDs: enterMotionIDs),
            ActivityPhaseContract(phase: .loop, durationSeconds: 0),
            ActivityPhaseContract(phase: .exit, durationSeconds: 0),
            ActivityPhaseContract(phase: .interrupt),
            ActivityPhaseContract(phase: .failed),
        ]
        return LifeActivityDefinition(
            id: id,
            displayName: displayName,
            activity: .interact(anchorID: objectID),
            phases: phases,
            interruptible: true,
            cooldownSeconds: cooldownSeconds
        )
    }

    /// The button-press stand window: the operating spot's capsule centre sits
    /// within this distance of the machine's footprint edge (arm's reach plus a
    /// small lean, no IK). The route waypoint may lie farther away — the
    /// approach then appends a collision-verified short final leg through
    /// `finalApproachPoint` instead of pressing the button from afar.
    public static let interactionReach: Float = 0.6

    /// Route-level discovery: standable waypoints within this horizontal
    /// distance of the machine may anchor an approach. Usability is decided by
    /// the final approach, never by the waypoint alone.
    public static let waypointDiscoveryDistance: Float = 2.5

    /// Standable waypoints that may anchor an approach, nearest to the machine
    /// first; ties break by ID so discovery stays stable across rebuilds.
    public static func operationAnchorCandidates(
        propCenter: WorldVector3,
        waypoints: [WorldWaypoint],
        maximumCenterDistance: Float = waypointDiscoveryDistance,
        canStand: (WorldVector3) -> Bool
    ) -> [WorldWaypoint] {
        waypoints
            .filter { $0.enabled }
            .compactMap { waypoint -> (WorldWaypoint, Float)? in
                let dx = waypoint.position.x - propCenter.x
                let dz = waypoint.position.z - propCenter.z
                let distance = (dx * dx + dz * dz).squareRoot()
                guard distance > 0, distance <= maximumCenterDistance,
                      canStand(waypoint.position)
                else { return nil }
                return (waypoint, distance)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 < rhs.1
            }
            .map(\.0)
    }

    /// Distance from the machine's yaw-rotated footprint boundary to a point:
    /// `|point - center| - boundary`, where the boundary is the ray-box exit
    /// parameter of the center→point ray (yaw-only placement, so the box
    /// rotates into local space directly).
    public static func footprintEdgeDistance(
        from point: WorldVector3,
        propCenter: WorldVector3,
        propYaw: Float,
        propHalfExtents: WorldVector3
    ) -> Float {
        let dx = point.x - propCenter.x
        let dz = point.z - propCenter.z
        let distance = (dx * dx + dz * dz).squareRoot()
        return footprintEdgeDistance(
            directionX: dx, directionZ: dz, distance: distance,
            propYaw: propYaw, propHalfExtents: propHalfExtents
        )
    }

    /// Marches from the anchor waypoint toward the machine in short steps and
    /// returns the grounded point where the footprint edge first comes within
    /// `maximumEdgeDistance`. Every candidate must resolve to an occupiable
    /// position (grounded, capsule fits); the first blocked step ends the
    /// march. Returns nil when the machine is not operable through this
    /// waypoint — unreachability is explicit, never bridged by assumption.
    public static func finalApproachPoint(
        from waypoint: WorldVector3,
        propCenter: WorldVector3,
        propYaw: Float,
        propHalfExtents: WorldVector3,
        maximumEdgeDistance: Float = interactionReach,
        step: Float = 0.05,
        maximumMarch: Float = 2,
        resolve: (WorldVector3) -> WorldVector3?
    ) -> WorldVector3? {
        let dx = propCenter.x - waypoint.x
        let dz = propCenter.z - waypoint.z
        let distance = (dx * dx + dz * dz).squareRoot()
        guard distance > 0, step > 0, step <= maximumMarch else { return nil }
        let directionX = dx / distance
        let directionZ = dz / distance
        var travelled: Float = 0
        while travelled < min(maximumMarch, distance) {
            travelled = min(travelled + step, distance)
            let candidate = WorldVector3(
                x: waypoint.x + directionX * travelled,
                y: waypoint.y,
                z: waypoint.z + directionZ * travelled
            )
            guard let grounded = resolve(candidate) else { return nil }
            let edge = footprintEdgeDistance(
                from: grounded, propCenter: propCenter,
                propYaw: propYaw, propHalfExtents: propHalfExtents
            )
            guard edge > 0 else { return nil }
            if edge <= maximumEdgeDistance { return grounded }
        }
        return nil
    }

    /// Distance from the machine's yaw-rotated footprint boundary to a point
    /// along the ray through the waypoint: `|waypoint - center| - boundary`,
    /// where the boundary is the ray-box exit parameter of the center→waypoint
    /// ray (yaw-only placement, so the box rotates into local space directly).
    private static func footprintEdgeDistance(
        directionX: Float,
        directionZ: Float,
        distance: Float,
        propYaw: Float,
        propHalfExtents: WorldVector3
    ) -> Float {
        let cosine = cos(propYaw)
        let sine = sin(propYaw)
        let localX = cosine * directionX + sine * directionZ
        let localZ = -sine * directionX + cosine * directionZ
        let boundaryX = abs(localX) > 1e-6 ? propHalfExtents.x * distance / abs(localX) : Float.infinity
        let boundaryZ = abs(localZ) > 1e-6 ? propHalfExtents.z * distance / abs(localZ) : Float.infinity
        return distance - min(boundaryX, boundaryZ)
    }
}
