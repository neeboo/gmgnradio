import Foundation
import Testing
@testable import WorldRuntime

@Test("Waypoint routing chooses the shortest enabled authored path")
func shortestAuthoredRoute() throws {
    let router = WaypointNavigationGraph(
        waypoints: [
            waypoint("a", 0, 0, 0),
            waypoint("b", 4, 0, 0),
            waypoint("c", 0, 0, 1),
            waypoint("d", 0, 0, 2, arrivalRadius: 0.35),
        ],
        routes: [
            route("long-1", ["a", "b"]),
            route("long-2", ["b", "d"]),
            route("short", ["a", "c", "d"]),
        ]
    )

    let path = try router.route(from: SIMD3(0, 0, 0), to: "d")

    #expect(path.waypointIDs == ["c", "d"])
    #expect(abs(path.totalLength - 2) < 0.0001)
    #expect(path.destinationID == "d")
    #expect(path.arrivalTolerance == 0.35)
    #expect(!path.hasArrived)
}

@Test("Waypoint routing reports an unreachable destination")
func unreachableDestination() {
    let router = WaypointNavigationGraph(
        waypoints: [
            waypoint("a", 0, 0, 0),
            waypoint("isolated", 10, 0, 0),
        ],
        routes: []
    )

    #expect(throws: WorldNavigationError.unreachable(destinationID: "isolated")) {
        try router.route(from: SIMD3(0, 0, 0), to: "isolated")
    }
}

@Test("Disabled authored routes do not participate in shortest path routing")
func disabledRouteIsIgnored() throws {
    let router = WaypointNavigationGraph(
        waypoints: [
            waypoint("a", 0, 0, 0),
            waypoint("blocked", 1, 0, 0),
            waypoint("detour", 0, 0, 2),
            waypoint("d", 2, 0, 0),
        ],
        routes: [
            route("disabled-shortcut", ["a", "blocked", "d"], enabled: false),
            route("detour", ["a", "detour", "d"]),
        ]
    )

    let path = try router.route(from: SIMD3(0, 0, 0), to: "d")

    #expect(path.waypointIDs == ["detour", "d"])
}

@Test("Disabled waypoints cannot be destinations")
func disabledDestinationIsRejected() {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("disabled", 0, 0, 0, enabled: false)],
        routes: []
    )

    #expect(throws: WorldNavigationError.disabledAnchor(anchorID: "disabled")) {
        try router.route(from: SIMD3(0, 0, 0), to: "disabled")
    }
}

@Test("A position inside the authored arrival radius is already at the destination")
func arrivalTolerance() throws {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("chair", 2, 0, 2, arrivalRadius: 0.5)],
        routes: []
    )

    let path = try router.route(from: SIMD3(2.3, 0, 2), to: "chair")

    #expect(path.hasArrived)
    #expect(path.waypointIDs.isEmpty)
    #expect(path.totalLength == 0)
}

@Test("A vertical capsule is rejected by a rotated blocking box")
func orientedBlockingVolumeRejectsCapsule() {
    let world = CollisionVolumeWorld(volumes: [
        collisionBox(
            "wall",
            center: .init(x: 0, y: 1, z: 0),
            halfExtents: .init(x: 1, y: 1, z: 0.1),
            yawDegrees: 45
        ),
    ])
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)

    #expect(!world.canOccupy(capsule, at: SIMD3(0.6, 0, -0.6)))
    #expect(world.canOccupy(capsule, at: SIMD3(1.4, 0, 1.4)))
}

@Test("Non-blocking authored volumes do not reject occupancy")
func nonBlockingVolumeAllowsCapsule() {
    let world = CollisionVolumeWorld(volumes: [
        WorldCollisionVolume(
            id: "trigger",
            center: .init(x: 0, y: 1, z: 0),
            halfExtents: .init(x: 1, y: 1, z: 1),
            rotation: .identity,
            isBlocking: false
        ),
    ])

    #expect(world.canOccupy(.init(radius: 0.25, height: 1.8), at: .zero))
}

@Test("Ground height returns the top surface of the highest authored box")
func authoredGroundHeight() {
    let world = CollisionVolumeWorld(volumes: [
        collisionBox(
            "floor",
            center: .init(x: 0, y: -0.1, z: 0),
            halfExtents: .init(x: 2, y: 0.1, z: 2)
        ),
        collisionBox(
            "platform",
            center: .init(x: 0, y: 0.2, z: 0),
            halfExtents: .init(x: 0.5, y: 0.2, z: 0.5)
        ),
    ])

    #expect(abs((world.groundHeight(at: SIMD3(0, 4, 0)) ?? -1) - 0.4) < 0.0001)
    #expect(world.groundHeight(at: SIMD3(3, 4, 3)) == nil)
}

@Test("Traversal honors the maximum authored step height")
func maximumStepHeight() {
    let world = CollisionVolumeWorld(volumes: [
        collisionBox(
            "low-floor",
            center: .init(x: -1, y: -0.1, z: 0),
            halfExtents: .init(x: 1, y: 0.1, z: 1)
        ),
        collisionBox(
            "step",
            center: .init(x: 1, y: 0.025, z: 0),
            halfExtents: .init(x: 1, y: 0.225, z: 1)
        ),
    ])
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let start = SIMD3<Float>(-1, 0, 0)
    let destination = SIMD3<Float>(1, 0.25, 0)

    #expect(world.canTraverse(capsule, from: start, to: destination, maximumStepHeight: 0.3))
    #expect(!world.canTraverse(capsule, from: start, to: destination, maximumStepHeight: 0.2))
}

@Test("Traversal rejects a free endpoint when the segment crosses a wall")
func segmentCrossingWallIsRejected() {
    let world = CollisionVolumeWorld(volumes: [
        collisionBox(
            "floor",
            center: .init(x: 0, y: -0.1, z: 0),
            halfExtents: .init(x: 2, y: 0.1, z: 2)
        ),
        collisionBox(
            "wall",
            center: .init(x: 0, y: 1, z: 0),
            halfExtents: .init(x: 0.05, y: 1, z: 2)
        ),
    ])
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let start = SIMD3<Float>(-1, 0, 0)
    let destination = SIMD3<Float>(1, 0, 0)

    #expect(world.canOccupy(capsule, at: destination))
    #expect(!world.canTraverse(
        capsule,
        from: start,
        to: destination,
        maximumStepHeight: 0.3
    ))
}

private func waypoint(
    _ id: String,
    _ x: Float,
    _ y: Float,
    _ z: Float,
    arrivalRadius: Float = 0.2,
    enabled: Bool = true
) -> WorldWaypoint {
    WorldWaypoint(
        id: id,
        position: .init(x: x, y: y, z: z),
        arrivalRadius: arrivalRadius,
        enabled: enabled
    )
}

private func route(
    _ id: String,
    _ waypointIDs: [String],
    bidirectional: Bool = true,
    enabled: Bool = true
) -> WorldRoute {
    WorldRoute(
        id: id,
        waypointIDs: waypointIDs,
        bidirectional: bidirectional,
        enabled: enabled
    )
}

private func collisionBox(
    _ id: String,
    center: WorldVector3,
    halfExtents: WorldVector3,
    yawDegrees: Float = 0
) -> WorldCollisionVolume {
    let halfAngle = yawDegrees * .pi / 360
    return WorldCollisionVolume(
        id: id,
        center: center,
        halfExtents: halfExtents,
        rotation: .init(x: 0, y: sin(halfAngle), z: 0, w: cos(halfAngle)),
        isBlocking: true
    )
}

private extension WorldQuaternion {
    static let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
}
