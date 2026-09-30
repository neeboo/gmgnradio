import Foundation
import Testing
@testable import WorldRuntime

private let canaryManifestURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent(
        "../../../../Resources/Worlds/warm-kitchen-canary/world.json"
    )
    .standardizedFileURL

private func loadBundledManifest() throws -> WorldManifest {
    let manifest = try JSONDecoder().decode(
        WorldManifest.self,
        from: Data(contentsOf: canaryManifestURL)
    )
    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: canaryManifestURL.deletingLastPathComponent()
    )
    #expect(findings.isEmpty)
    return manifest
}

@Test("Warm Kitchen bundle is the verified 1.3.0 collision-authored package")
func warmKitchenBundleIsTheVerified13CollisionPackage() throws {
    let manifest = try loadBundledManifest()
    #expect(manifest.packageID == "warm-kitchen-canary")
    #expect(manifest.worldID == "world-labs-example-warm-kitchen")
    #expect(manifest.packageVersion == "1.3.0")

    let generatedWaypoints = manifest.waypoints.filter { $0.id.hasPrefix("wp.auto.") }
    #expect(generatedWaypoints.count == 8)

    let autoRoutes = manifest.routes.filter { $0.id.hasPrefix("route.auto.") }
    let legacyRoutes = manifest.routes.filter { !$0.id.hasPrefix("route.auto.") }
    #expect(autoRoutes.count == 16)
    #expect(legacyRoutes.count == 3)
    #expect(autoRoutes.allSatisfy { $0.enabled })
    #expect(legacyRoutes.allSatisfy { !$0.enabled })
    #expect(Set(legacyRoutes.map(\.id)) == [
        "route.home-loop",
        "route.kitchen-dining",
        "route.window",
    ])
}

@Test("Warm Kitchen auto graph alone reaches every activity entry from spawn")
func warmKitchenAutoGraphReachesEveryActivityEntryFromSpawn() throws {
    let manifest = try loadBundledManifest()
    let enabledWaypoints = Set(manifest.waypoints.filter(\.enabled).map(\.id))
    var adjacency: [String: Set<String>] = [:]
    for route in manifest.routes
    where route.enabled && route.id.hasPrefix("route.auto.") {
        for pair in zip(route.waypointIDs, route.waypointIDs.dropFirst()) {
            guard enabledWaypoints.contains(pair.0), enabledWaypoints.contains(pair.1)
            else { continue }
            adjacency[pair.0, default: []].insert(pair.1)
            if route.bidirectional {
                adjacency[pair.1, default: []].insert(pair.0)
            }
        }
    }

    var reachable: Set<String> = []
    var queue = ["wp.spawn"]
    while !queue.isEmpty {
        let current = queue.removeFirst()
        guard !reachable.contains(current) else { continue }
        reachable.insert(current)
        queue.append(
            contentsOf: adjacency[current, default: []].subtracting(reachable)
        )
    }

    // home.walk and home.turn deliberately share the wp.center entry, so the
    // reachability requirement is about the entry set, not per-activity rows.
    let entries = Set(manifest.activities.compactMap(\.entryWaypointID))
    for entry in entries.sorted() {
        #expect(
            reachable.contains(entry),
            "activity entry \(entry) is unreachable through the auto graph"
        )
    }
}

@Test("Warm Kitchen completes the six-stop collision tour through auto waypoints")
func warmKitchenCompletesSixStopCollisionTour() throws {
    let manifest = try loadBundledManifest()
    let router = WaypointNavigationGraph(manifest: manifest)
    let collision = CollisionVolumeWorld(manifest: manifest)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let anchorsByID = Dictionary(
        uniqueKeysWithValues: manifest.activities.map { ($0.id, $0) }
    )
    let tour = [
        "home.idle",
        "home.walk",
        "home.turn",
        "chair.sit",
        "music.listen",
        "window.gaze",
    ]
    var position = manifest.spawn.position.simd3

    for activityID in tour {
        let anchor = try #require(anchorsByID[activityID])
        let path = try router.route(
            from: position,
            to: try #require(anchor.entryWaypointID)
        )
        if !path.waypointIDs.isEmpty {
            #expect(
                path.waypointIDs.contains { $0.hasPrefix("wp.auto.") },
                "Movement to \(activityID) must run through the generated auto graph"
            )
        }
        for destination in path.points.map(\.simd3) {
            #expect(
                collision.canTraverse(
                    capsule,
                    from: position,
                    to: destination,
                    maximumStepHeight: 0.3
                ),
                "Blocked route while approaching \(activityID)"
            )
            position = destination
        }

        let anchorPosition = try #require(anchor.transform).position.simd3
        #expect(
            distance(position, anchorPosition) <= 0.08,
            "Entry transform is outside the 8 cm tolerance for \(activityID)"
        )
        let ground = try #require(collision.groundHeight(at: anchorPosition))
        #expect(
            abs(anchorPosition.y - ground) <= 0.03,
            "Feet are outside the 3 cm ground tolerance for \(activityID)"
        )
        #expect(
            collision.canOccupy(capsule, at: anchorPosition),
            "Anchor intersects blocking geometry for \(activityID)"
        )
        position = anchorPosition
    }
}

@Test("Warm Kitchen routes every activity entry from spawn through the auto graph")
func warmKitchenRoutesEveryActivityEntryFromSpawn() throws {
    let manifest = try loadBundledManifest()
    let router = WaypointNavigationGraph(manifest: manifest)
    let collision = CollisionVolumeWorld(manifest: manifest)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let spawnPosition = manifest.spawn.position.simd3

    for anchor in manifest.activities.sorted(by: { $0.id < $1.id }) {
        let path = try router.route(
            from: spawnPosition,
            to: try #require(anchor.entryWaypointID)
        )
        if anchor.entryWaypointID != "wp.spawn" {
            #expect(
                !path.waypointIDs.isEmpty,
                "No movement path to \(anchor.id)"
            )
            #expect(
                path.waypointIDs.contains { $0.hasPrefix("wp.auto.") },
                "Movement to \(anchor.id) must run through the generated auto graph"
            )
        }
        var cursor = spawnPosition
        for destination in path.points.map(\.simd3) {
            #expect(
                collision.canTraverse(
                    capsule,
                    from: cursor,
                    to: destination,
                    maximumStepHeight: 0.3
                ),
                "Blocked segment while routing to \(anchor.id)"
            )
            cursor = destination
        }
    }
}

@Test("Warm Kitchen offers a coffee-machine interaction with a one-shot motion")
func warmKitchenOffersCoffeeMachineInteraction() throws {
    let manifest = try loadBundledManifest()
    let anchor = try #require(
        manifest.activities.first(where: { $0.id == "coffee.brew" })
    )
    let definition = try #require(
        manifest.activityDefinitions.first(where: { $0.id == "coffee.brew" })
    )

    #expect(anchor.action == "interact")
    #expect(anchor.entryWaypointID == "wp.kitchen.counter")
    let transform = try #require(anchor.transform)
    #expect(abs(transform.position.x - 0.38) < 0.001)
    #expect(abs(transform.position.z + 1.28) < 0.001)
    #expect(abs(transform.rotation.w - 0.7071068) < 0.001)
    #expect(abs(transform.rotation.y - 0.7071068) < 0.001)
    #expect(definition.displayName == "操作咖啡机")
    #expect(definition.activity == .interact(anchorID: "coffee.brew"))
    #expect(
        definition.contract(for: .enter)?.motionIDs
            == ["gmgn.motion.bones.coffee-button-pmx"]
    )
    #expect(definition.contract(for: .enter)?.durationSeconds == 3.5)
}

@Test("Warm Kitchen coffee.brew sips from the cup during a timed loop phase")
func warmKitchenCoffeeBrewSipsDuringTimedLoopPhase() throws {
    let manifest = try loadBundledManifest()
    let definition = try #require(
        manifest.activityDefinitions.first(where: { $0.id == "coffee.brew" })
    )

    let loop = try #require(definition.contract(for: .loop))
    #expect(
        loop.motionIDs
            == [
                "gmgn.motion.generated.a-person-naturally-picks-up-a-coffee-cup-76b63e0f",
            ]
    )
    #expect(loop.durationSeconds == 6.95)
    #expect(loop.propIDs.isEmpty)

    let exit = try #require(definition.contract(for: .exit))
    #expect(exit.motionIDs.isEmpty)
    #expect(exit.propIDs.isEmpty)
    #expect(
        definition.contract(for: .approach)?.motionIDs.contains(
            "gmgn.motion.bones.walk-loop-pmx"
        ) == true
    )
}

@Test("Warm Kitchen walks between the kitchen counter and dining table")
func warmKitchenWalksBetweenKitchenAndDiningTable() throws {
    let manifest = try loadBundledManifest()
    let waypoints = Dictionary(
        uniqueKeysWithValues: manifest.waypoints.map { ($0.id, $0) }
    )
    let definitions = try ActivityCatalog(manifest: manifest)
    let router = WaypointNavigationGraph(manifest: manifest)
    let collision = CollisionVolumeWorld(manifest: manifest)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let kitchen = try #require(waypoints["wp.kitchen.counter"])
    let dining = try #require(waypoints["wp.dining.table"])

    let outbound = try router.route(
        from: dining.position.simd3,
        to: kitchen.id
    )
    #expect(outbound.waypointIDs.last == kitchen.id)
    #expect(
        outbound.waypointIDs.dropLast().allSatisfy { $0.hasPrefix("wp.auto.") },
        "The kitchen/dining route must not rely on legacy manual waypoints"
    )
    var cursor = dining.position.simd3
    for destination in outbound.points.map(\.simd3) {
        #expect(
            collision.canTraverse(capsule, from: cursor, to: destination, maximumStepHeight: 0.3),
            "Blocked outbound segment"
        )
        cursor = destination
    }
    try verifyWalkActivity(
        id: "kitchen.walk",
        from: dining.position,
        expectedDestination: kitchen.position,
        definitions: definitions,
        router: router,
        collision: collision
    )

    let returning = try router.route(
        from: kitchen.position.simd3,
        to: dining.id
    )
    #expect(returning.waypointIDs.last == dining.id)
    #expect(
        returning.waypointIDs.dropLast().allSatisfy { $0.hasPrefix("wp.auto.") },
        "The kitchen/dining route must not rely on legacy manual waypoints"
    )
    cursor = kitchen.position.simd3
    for destination in returning.points.map(\.simd3) {
        #expect(
            collision.canTraverse(capsule, from: cursor, to: destination, maximumStepHeight: 0.3),
            "Blocked returning segment"
        )
        cursor = destination
    }
    try verifyWalkActivity(
        id: "dining.walk",
        from: kitchen.position,
        expectedDestination: dining.position,
        definitions: definitions,
        router: router,
        collision: collision
    )
}

@Test("Warm Kitchen blocks the authored cabinets and room furniture")
func warmKitchenBlocksAuthoredCabinetsAndRoomFurniture() throws {
    let manifest = try loadBundledManifest()
    let collisionIDs = Set(manifest.collisionVolumes.map(\.id))
    #expect(collisionIDs.isSuperset(of: [
        "collision.cabinet.left",
        "collision.cabinet.right",
        "collision.counter.back",
        "collision.dining.chair",
    ]))

    let collision = CollisionVolumeWorld(manifest: manifest)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let occupiedFurnitureCenters: [SIMD3<Float>] = [
        SIMD3(-0.78, 0, 0),
        SIMD3(0.78, 0, 0),
        SIMD3(0, 0, -1.35),
        SIMD3(0.1, 0, 0.65),
    ]
    for position in occupiedFurnitureCenters {
        #expect(
            !collision.canOccupy(capsule, at: position),
            "The character capsule can still enter authored furniture at \(position)"
        )
    }

    let walkablePlaces: [SIMD3<Float>] = [
        SIMD3(0, 0, 0.2),
        SIMD3(0.2, 0, -0.55),
        SIMD3(-0.35, 0, 1.0),
    ]
    for position in walkablePlaces {
        #expect(
            collision.canOccupy(capsule, at: position),
            "An authored activity entry is trapped by collision at \(position)"
        )
    }
}

@Test("Warm Kitchen routes around the dining chair instead of crossing it")
func warmKitchenRoutesAroundDiningChair() throws {
    let manifest = try loadBundledManifest()
    let waypoints = Dictionary(
        uniqueKeysWithValues: manifest.waypoints.map { ($0.id, $0) }
    )
    let kitchen = try #require(waypoints["wp.kitchen.counter"])
    let dining = try #require(waypoints["wp.dining.table"])
    let collision = CollisionVolumeWorld(manifest: manifest)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)

    #expect(
        !collision.canTraverse(
            capsule,
            from: kitchen.position.simd3,
            to: dining.position.simd3,
            maximumStepHeight: 0.3
        ),
        "The direct kitchen-to-dining segment must cross the authored chair blocker"
    )

    let path = try WaypointNavigationGraph(manifest: manifest).route(
        from: kitchen.position.simd3,
        to: dining.id
    )
    #expect(path.points.count >= 3)
    #expect(path.totalLength > distance(kitchen.position.simd3, dining.position.simd3))

    var cursor = kitchen.position.simd3
    for destination in path.points.map(\.simd3) {
        #expect(
            collision.canTraverse(
                capsule,
                from: cursor,
                to: destination,
                maximumStepHeight: 0.3
            ),
            "The detour itself crosses collision from \(cursor) to \(destination)"
        )
        cursor = destination
    }
}

@Test("Warm Kitchen rejects the obsolete saved position inside the right cabinet")
func warmKitchenRejectsObsoletePositionInsideRightCabinet() throws {
    let manifest = try loadBundledManifest()
    let definitions = try ActivityCatalog(manifest: manifest)
    let definition = try #require(definitions.definition(id: "home.walk"))
    let anchor = try #require(
        manifest.activities.first(where: { $0.id == "home.walk" })
    )
    let legacyPosition = WorldVector3(x: 0.72, y: 0, z: 0.55)
    let collision = CollisionVolumeWorld(manifest: manifest)
    #expect(
        !collision.canOccupy(
            WorldCapsule(radius: 0.2, height: 1.8),
            at: legacyPosition.simd3
        )
    )
    var executor = ActivityExecutor(
        position: legacyPosition,
        collisionQuery: collision
    )
    let request = ScheduledActivity(
        id: "legacy-home-walk",
        definitionID: definition.id,
        activity: definition.activity,
        priority: .explicitUserRequest,
        requestedAt: Date(timeIntervalSince1970: 1)
    )
    let startEffects = executor.start(
        request,
        definition: definition,
        at: request.requestedAt
    )
    #expect(!startEffects.contains(where: isRejectedOrFailed))

    let path = try WaypointNavigationGraph(manifest: manifest).route(
        from: legacyPosition.simd3,
        to: try #require(anchor.entryWaypointID)
    )
    let approachEffects = try executor.supplyApproach(
        ActivityApproachPlan(waypoints: path.points)
    )
    #expect(approachEffects.contains(where: isRejectedOrFailed))

    let tickEffects = executor.tick(deltaTime: 0.25)
    #expect(!tickEffects.contains(where: isMovement))
}

private func isRejectedOrFailed(_ effect: ActivityExecutionEffect) -> Bool {
    switch effect {
    case .rejected, .failed:
        true
    default:
        false
    }
}

private func isMovement(_ effect: ActivityExecutionEffect) -> Bool {
    if case .moved = effect { true } else { false }
}

private func verifyWalkActivity(
    id: String,
    from start: WorldVector3,
    expectedDestination: WorldVector3,
    definitions: ActivityCatalog,
    router: WaypointNavigationGraph,
    collision: CollisionVolumeWorld
) throws {
    let definition = try #require(definitions.definition(id: id))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var executor = ActivityExecutor(
        position: start,
        walkingSpeed: 1.2,
        collisionQuery: collision
    )
    let request = ScheduledActivity(
        id: "test-\(id)",
        definitionID: id,
        activity: definition.activity,
        priority: .explicitUserRequest,
        requestedAt: now
    )
    let startEffects = executor.start(request, definition: definition, at: now)
    #expect(startEffects.contains { effect in
        if case .requestPath = effect { return true }
        return false
    })
    _ = try executor.acquireApproach(using: router)

    var ticks = 0
    while executor.status.phase == .approach, ticks < 300 {
        let effects = executor.tick(deltaTime: 1.0 / 30.0)
        #expect(!effects.contains { effect in
            if case .failed = effect { return true }
            return false
        })
        ticks += 1
    }

    #expect(executor.status.phase == .enter)
    #expect(distance(executor.status.position.simd3, expectedDestination.simd3) < 0.001)
}

private func distance(
    _ lhs: SIMD3<Float>,
    _ rhs: SIMD3<Float>
) -> Float {
    let delta = lhs - rhs
    return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
}
