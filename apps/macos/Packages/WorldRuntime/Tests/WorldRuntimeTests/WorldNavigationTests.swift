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

@Test("Traversal filtering takes an authored detour around a blocked short edge")
func traversalFilteredDetour() throws {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("a", 0, 0, 0), waypoint("b", 1, 0, 0),
                    waypoint("c", 0, 0, 2), waypoint("d", 2, 0, 0)],
        routes: [route("short", ["a", "b", "d"]), route("detour", ["a", "c", "d"])]
    )
    let path = try router.route(from: .zero, to: "d", canTraverse: { from, to in
        !(from == SIMD3<Float>(0, 0, 0) && to == SIMD3<Float>(1, 0, 0))
    })
    #expect(path.waypointIDs == ["c", "d"])
}

@Test("Traversal filtering rejects all blocked edges and blocked graph entry")
func traversalFilteredUnreachable() {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("a", 0, 0, 0), waypoint("d", 2, 0, 0)],
        routes: [route("link", ["a", "d"])]
    )
    #expect(throws: WorldNavigationError.unreachable(destinationID: "d")) {
        try router.route(from: .zero, to: "d", canTraverse: { _, _ in false })
    }
    #expect(throws: WorldNavigationError.unreachable(destinationID: "d")) {
        try router.route(from: SIMD3(-1, 0, 0), to: "d", canTraverse: { from, _ in
            from.x >= 0
        })
    }
}

@Test("Blocked entry selects the next nearest reachable waypoint")
func traversalFilteredEntry() throws {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("a", 0, 0, 0), waypoint("b", 0, 0, 2),
                    waypoint("d", 2, 0, 2)],
        routes: [route("links", ["a", "b", "d"])]
    )
    let position = SIMD3<Float>(-1, 0, 0)
    let path = try router.route(from: position, to: "d", canTraverse: { from, to in
        !(from == position && to == .zero)
    })
    #expect(path.waypointIDs == ["b", "d"])
}

@Test("Waypoint entry preserves deterministic ID ties and route direction")
func deterministicRoutingTies() throws {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("b", -1, 0, 0), waypoint("a", 1, 0, 0),
                    waypoint("right", 1, 0, 2), waypoint("left", -1, 0, 2),
                    waypoint("d", 0, 0, 3)],
        routes: [route("b-path", ["b", "left", "d"], bidirectional: false),
                 route("a-path", ["a", "right", "d"], bidirectional: false)]
    )
    #expect(try router.route(from: .zero, to: "d").waypointIDs == ["a", "right", "d"])
    #expect(throws: WorldNavigationError.unreachable(destinationID: "a")) {
        try router.route(from: SIMD3(0, 0, 3), to: "a")
    }
}

@Test("Equal length paths retain the original deterministic predecessor tie")
func deterministicPathTies() throws {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("start", 0, 0, 0), waypoint("b", -1, 0, 1),
                    waypoint("a", 1, 0, 1), waypoint("d", 0, 0, 2)],
        routes: [route("b-path", ["start", "b", "d"]),
                 route("a-path", ["start", "a", "d"])]
    )
    #expect(try router.route(from: .zero, to: "d").waypointIDs == ["a", "d"])
    #expect(try router.route(from: .zero, to: "d", canTraverse: { _, _ in true })
        .waypointIDs == ["a", "d"])
}

@Test("A 631 waypoint route avoids repeated graph searches and edge collision queries")
func largeWaypointGraphPerformance() throws {
    let count = 631
    let ids = (0..<count).map { String(format: "wp.%04d", $0) }
    let router = WaypointNavigationGraph(
        waypoints: (0..<count).map { waypoint(ids[$0], Float($0), 0, 0) },
        routes: [route("chain", ids)]
    )
    var checkedEdges = Set<String>()
    var repeatedEdge = false
    let started = ContinuousClock.now
    let path = try router.route(from: .zero, to: ids[count - 1], canTraverse: { from, to in
        let key = "\(from.x):\(to.x)"
        if !checkedEdges.insert(key).inserted { repeatedEdge = true }
        return true
    })
    #expect(path.waypointIDs == Array(ids.dropFirst()))
    #expect(path.totalLength == Float(count - 1))
    #expect(!repeatedEdge)
    #expect(checkedEdges.count <= 2 * (count - 1) + 1)
    #expect(started.duration(to: .now) < .seconds(3))
}

@Test("A short route in a wide 631 waypoint graph only collision checks its own segments")
func wideWaypointGraphLazyCollisionChecks() throws {
    let branches = (0..<629).map { waypoint("branch.\($0)", Float($0 + 100), 0, 10) }
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("start", 0, 0, 0), waypoint("destination", 1, 0, 0)] + branches,
        routes: [route("direct", ["start", "destination"])] + branches.map {
            route("via.\($0.id)", ["start", $0.id, "destination"])
        }
    )
    var collisionChecks = 0
    let path = try router.route(from: .zero, to: "destination", canTraverse: { _, _ in
        collisionChecks += 1
        return true
    })
    #expect(path.waypointIDs == ["destination"])
    #expect(collisionChecks == 2)
}

@Test("Lazy replanning caches shared route edges and the entry segment")
func lazyReplanningCachesSegments() throws {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("a", 0, 0, 0), waypoint("b", 1, 0, 0),
                    waypoint("c", 2, 0, 1), waypoint("d", 3, 0, 0)],
        routes: [route("short", ["a", "b", "d"], bidirectional: false),
                 route("detour", ["b", "c", "d"], bidirectional: false)]
    )
    var calls: [String: Int] = [:]
    let path = try router.route(from: .zero, to: "d", canTraverse: { from, to in
        calls["\(from.x):\(to.x)", default: 0] += 1
        return !(from.x == 1 && to.x == 3)
    })
    #expect(path.waypointIDs == ["b", "c", "d"])
    #expect(calls.count == 5)
    #expect(calls.values.allSatisfy { $0 == 1 })
}

@Test("Lazy replanning exhausts blocked graph edges without repeating physical checks")
func lazyReplanningExhaustsBlockedEdges() {
    let router = WaypointNavigationGraph(
        waypoints: [waypoint("a", 0, 0, 0), waypoint("b", 1, 0, 0),
                    waypoint("d", 2, 0, 0)],
        routes: [route("chain", ["a", "b", "d"], bidirectional: false)]
    )
    var calls = 0
    #expect(throws: WorldNavigationError.unreachable(destinationID: "d")) {
        try router.route(from: SIMD3(-1, 0, 0), to: "d", canTraverse: { from, _ in
            calls += 1
            return from.x == -1
        })
    }
    #expect(calls == 4)
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
