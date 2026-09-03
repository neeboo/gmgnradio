import Foundation
import Testing
import WorldRuntime
@testable import GMGNRadio

@MainActor
@Test
func worldAgentCapabilityManifestExposesElevenAtomicTools() {
    #expect(WorldAgentToolContract.capabilities.map(\.name) == [
        "inspect_world",
        "list_places",
        "list_available_activities",
        "plan_route",
        "move_to",
        "start_activity",
        "stop_activity",
        "look_at",
        "set_world_weather",
        "move_live_camera",
        "complete_world_goal",
    ])
    #expect(
        WorldAgentToolContract.capabilities
            .filter { $0.requiresTakeover }
            .map(\.name) == [
                "move_to",
                "start_activity",
                "stop_activity",
                "look_at",
                "set_world_weather",
                "move_live_camera",
                "complete_world_goal",
            ]
    )

    let stop = WorldAgentToolContract.capabilities.first {
        $0.name == "stop_activity"
    }
    let complete = WorldAgentToolContract.capabilities.first {
        $0.name == "complete_world_goal"
    }
    #expect(stop?.parameters.keys.sorted() == ["reason"])
    #expect(stop?.requiredParameters == [])
    #expect(complete?.parameters.keys.sorted() == ["goal_id", "summary"])
    #expect(complete?.requiredParameters == ["goal_id"])
}

@MainActor
@Test
func providerSchemaUsesManifestAuthoredEnumsAndDispatcherReportsOwnership() throws {
    let context = try WorldAgentContext(manifest: .agentToolFixture)
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { true },
        context: context
    )

    #expect(dispatcher.handles("move_to"))
    #expect(dispatcher.handles("complete_world_goal"))
    #expect(dispatcher.handles("next_track") == false)
    #expect(providerEnum("place_id", for: "move_to", in: dispatcher.providerTools) == [
        "chair", "spawn", "window",
    ])
    #expect(providerEnum("activity_id", for: "start_activity", in: dispatcher.providerTools) == [
        "sit-chair",
    ])
    #expect(providerEnum("camera_id", for: "move_live_camera", in: dispatcher.providerTools) == [
        "wide",
    ])
    #expect(providerPropertyNames(for: "stop_activity", in: dispatcher.providerTools) == [
        "reason",
    ])
    #expect(providerPropertyNames(for: "complete_world_goal", in: dispatcher.providerTools) == [
        "goal_id", "summary",
    ])
}

@MainActor
@Test
func worldAgentContextCanInstallDownloadedTriangleCollision() throws {
    let context = try WorldAgentContext(manifest: .agentToolFixture)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let wall = TriangleMeshCollisionWorld(triangles: [
        WorldTriangle(SIMD3(0, 0, -1), SIMD3(0, 2, -1), SIMD3(0, 0, 1)),
        WorldTriangle(SIMD3(0, 2, -1), SIMD3(0, 2, 1), SIMD3(0, 0, 1)),
    ])

    context.installCollisionWorld(wall)

    #expect(!context.collisionWorld.canOccupy(capsule, at: .zero))
}

@MainActor
@Test
func downloadedCollisionRelocatesACharacterTrappedAtTheSavedSpawn() throws {
    let context = try WorldAgentContext(manifest: .agentToolFixture)
    let floor = [
        WorldTriangle(SIMD3(-1, 0, -2), SIMD3(5, 0, -2), SIMD3(5, 0, 2)),
        WorldTriangle(SIMD3(-1, 0, -2), SIMD3(5, 0, 2), SIMD3(-1, 0, 2)),
    ]
    let wall = [
        WorldTriangle(SIMD3(0, 0, -1), SIMD3(0, 2, -1), SIMD3(0, 0, 1)),
        WorldTriangle(SIMD3(0, 2, -1), SIMD3(0, 2, 1), SIMD3(0, 0, 1)),
    ]
    let mesh = TriangleMeshCollisionWorld(triangles: floor + wall)

    let corrected = try context
        .installCollisionWorldAndReconcilePlacement(mesh)

    #expect(corrected == WorldVector3(x: 2, y: 0, z: 0))
    #expect(context.state.agentTransform.position == corrected)
}

@MainActor
@Test
func readToolsExposeManifestAuthoredPlacesActivitiesAndCameras() async throws {
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        startedAt: Date(timeIntervalSince1970: 1_000)
    )
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { false },
        context: context
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "inspect-1",
        name: "inspect_world",
        argumentsJSON: Data("{}".utf8)
    ))
    let body = try JSONDecoder().decode(
        WorldAgentToolResponse.self,
        from: result.resultJSON
    )

    #expect(result.isError == false)
    #expect(body.snapshot.worldID == "test-room")
    #expect(body.snapshot.places.map(\.id) == ["chair", "spawn", "window"])
    #expect(body.snapshot.activities.map(\.id) == ["sit-chair"])
    #expect(body.snapshot.cameras.map(\.id) == ["wide"])
}

@MainActor
@Test
func writeToolsRequireTakeoverAndDoNotMutateWorldWhenDenied() async throws {
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        startedAt: Date(timeIntervalSince1970: 1_000)
    )
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { false },
        context: context
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "weather-denied",
        name: "set_world_weather",
        argumentsJSON: Data(#"{"weather":"rain"}"#.utf8)
    ))

    #expect(result.isError)
    #expect(context.snapshot.weather == .clear)
    #expect(context.snapshot.revision == 0)
}

@MainActor
@Test
func duplicateMoveCallPlansOnlyOneRouteAndTicksPersistAuthoritativeState() async throws {
    let persistence = WorldAgentPersistenceSpy()
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        startedAt: Date(timeIntervalSince1970: 1_000),
        persistence: persistence,
        walkingSpeed: 1
    )
    var observedRevisions: [UInt64] = []
    context.onSnapshotChanged = { observedRevisions.append($0.revision) }
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { true },
        context: context
    )
    let call = RealtimeDJToolCall(
        id: "move-1",
        name: "move_to",
        argumentsJSON: Data(#"{"place_id":"window"}"#.utf8)
    )

    let first = await dispatcher.handle(call)
    let duplicate = await dispatcher.handle(call)
    try context.tick(deltaTime: 1)

    #expect(first == duplicate)
    #expect(context.snapshot.movement?.destinationID == "window")
    #expect(context.snapshot.agentTransform.position.x == 1)
    #expect(context.snapshot.revision > 0)
    #expect(persistence.savedStates.last == context.state)
    #expect(observedRevisions.last == context.snapshot.revision)
}

@MainActor
@Test
func startActivityUsesExecutorAndWritesMovementAndActivityEventsToSimulation() async throws {
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        startedAt: Date(timeIntervalSince1970: 1_000),
        walkingSpeed: 4
    )
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { true },
        context: context
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "activity-1",
        name: "start_activity",
        argumentsJSON: Data(#"{"activity_id":"sit-chair"}"#.utf8)
    ))
    try context.tick(deltaTime: 1)

    #expect(result.isError == false)
    #expect(context.snapshot.activeActivity?.id == "sit-chair")
    #expect(context.snapshot.activeActivity?.phase == .enter)
    #expect(context.snapshot.agentTransform.position.x == 2)
    #expect(context.events.contains {
        if case .activityStarted(activityID: "sit-chair") = $0.kind { true }
        else { false }
    })
    #expect(context.events.contains {
        if case .agentTransformUpdated = $0.kind { true }
        else { false }
    })
}

@MainActor
@Test
func cameraWeatherLookAndGoalToolsMutateOneSimulation() async throws {
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        startedAt: Date(timeIntervalSince1970: 1_000)
    )
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { true },
        context: context
    )

    for call in [
        RealtimeDJToolCall(
            id: "camera-1",
            name: "move_live_camera",
            argumentsJSON: Data(#"{"camera_id":"wide"}"#.utf8)
        ),
        RealtimeDJToolCall(
            id: "weather-1",
            name: "set_world_weather",
            argumentsJSON: Data(#"{"weather":"rain"}"#.utf8)
        ),
        RealtimeDJToolCall(
            id: "look-1",
            name: "look_at",
            argumentsJSON: Data(#"{"place_id":"window"}"#.utf8)
        ),
        RealtimeDJToolCall(
            id: "goal-1",
            name: "complete_world_goal",
            argumentsJSON: Data(
                #"{"goal_id":"morning-routine","summary":"看过窗外并开始一天"}"#.utf8
            )
        ),
    ] {
        #expect(await dispatcher.handle(call).isError == false)
    }

    #expect(context.snapshot.weather == .rain)
    #expect(context.snapshot.liveCamera?.anchorID == "wide")
    #expect(context.snapshot.completedGoalIDs == ["morning-routine"])
    #expect(
        context.state.completedGoals["morning-routine"]?.summary
            == "看过窗外并开始一天"
    )
    #expect(context.snapshot.revision == 4)
}

@MainActor
@Test
func stopActivityCarriesOptionalReasonIntoTheWorldEvent() async throws {
    let context = try WorldAgentContext(manifest: .agentToolFixture)
    let dispatcher = WorldAgentToolDispatcher(
        takeoverEnabled: { true },
        context: context
    )

    _ = await dispatcher.handle(RealtimeDJToolCall(
        id: "start-for-stop",
        name: "start_activity",
        argumentsJSON: Data(#"{"activity_id":"sit-chair"}"#.utf8)
    ))
    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "stop-with-reason",
        name: "stop_activity",
        argumentsJSON: Data(#"{"reason":"用户开始对话"}"#.utf8)
    ))

    #expect(result.isError == false)
    #expect(context.snapshot.activeActivity == nil)
    #expect(context.events.contains {
        if case let .activityCancelled(activityID, reason) = $0.kind {
            activityID == "sit-chair" && reason == "用户开始对话"
        } else {
            false
        }
    })
}

@MainActor
@Test
func tickingNotifiesEveryFrameButCheckpointsMovingStateAtMostOncePerSecond() throws {
    let persistence = WorldAgentPersistenceSpy()
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        startedAt: Date(timeIntervalSince1970: 1_000),
        persistence: persistence,
        walkingSpeed: 0.1
    )
    var notificationCount = 0
    context.onSnapshotChanged = { _ in notificationCount += 1 }

    _ = try context.move(to: "window")
    #expect(persistence.savedStates.count == 1)

    try context.tick(deltaTime: 0.25)
    try context.tick(deltaTime: 0.25)
    try context.tick(deltaTime: 0.25)
    #expect(persistence.savedStates.count == 1)

    try context.tick(deltaTime: 0.25)
    #expect(persistence.savedStates.count == 2)
    #expect(notificationCount == 5)

    context.stopTicking()
    #expect(persistence.savedStates.count == 3)
    #expect(persistence.savedStates.last == context.state)
}

@MainActor
@Test
func movementCompletionForcesCheckpointBeforeOneSecond() throws {
    let persistence = WorldAgentPersistenceSpy()
    let context = try WorldAgentContext(
        manifest: .agentToolFixture,
        persistence: persistence,
        walkingSpeed: 10
    )

    _ = try context.move(to: "chair")
    try context.tick(deltaTime: 0.25)

    #expect(context.snapshot.movement == nil)
    #expect(persistence.savedStates.count == 2)
}

private final class WorldAgentPersistenceSpy: WorldStatePersisting, @unchecked Sendable {
    var savedStates: [WorldState] = []

    func save(_ state: WorldState) throws {
        savedStates.append(state)
    }

    func load() throws -> WorldState? { nil }
}

private func providerEnum(
    _ parameterName: String,
    for toolName: String,
    in tools: [[String: Any]]
) -> [String]? {
    providerProperties(for: toolName, in: tools)?[parameterName]
        .flatMap { $0 as? [String: Any] }?["enum"] as? [String]
}

private func providerPropertyNames(
    for toolName: String,
    in tools: [[String: Any]]
) -> [String] {
    providerProperties(for: toolName, in: tools)?.keys.sorted() ?? []
}

private func providerProperties(
    for toolName: String,
    in tools: [[String: Any]]
) -> [String: Any]? {
    for tool in tools {
        guard let function = tool["function"] as? [String: Any],
              function["name"] as? String == toolName,
              let parameters = function["parameters"] as? [String: Any],
              let properties = parameters["properties"] as? [String: Any]
        else {
            continue
        }
        return properties
    }
    return nil
}

private extension WorldManifest {
    static var agentToolFixture: WorldManifest {
        let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
        let unit = WorldVector3(x: 1, y: 1, z: 1)
        let transform: (Float, Float, Float) -> WorldTransform = { x, y, z in
            WorldTransform(
                position: WorldVector3(x: x, y: y, z: z),
                rotation: identity,
                scale: unit
            )
        }
        let phases = LifeActivityPhase.allCases.map {
            ActivityPhaseContract(phase: $0)
        }

        return WorldManifest(
            schemaVersion: 1,
            packageID: "test-package",
            packageVersion: "1.0.0",
            worldID: "test-room",
            displayName: "Test Room",
            calibration: WorldCalibration(
                visualToGameplay: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                metersPerUnit: 1
            ),
            spawn: transform(0, 0, 0),
            collisionVolumes: [
                WorldCollisionVolume(
                    id: "ground",
                    center: WorldVector3(x: 2, y: -0.5, z: 0),
                    halfExtents: WorldVector3(x: 5, y: 0.5, z: 5),
                    rotation: identity,
                    isBlocking: true
                ),
            ],
            waypoints: [
                WorldWaypoint(id: "spawn", position: transform(0, 0, 0).position, arrivalRadius: 0.1, enabled: true),
                WorldWaypoint(id: "chair", position: transform(2, 0, 0).position, arrivalRadius: 0.1, enabled: true),
                WorldWaypoint(id: "window", position: transform(4, 0, 0).position, arrivalRadius: 0.1, enabled: true),
            ],
            routes: [
                WorldRoute(
                    id: "main",
                    waypointIDs: ["spawn", "chair", "window"],
                    bidirectional: true,
                    enabled: true
                ),
            ],
            activities: [
                WorldActivityAnchor(
                    id: "sit-chair",
                    action: "sit",
                    entryWaypointID: "chair",
                    transform: transform(2, 0, 0),
                    motionID: nil,
                    propIDs: [],
                    interruptible: true
                ),
            ],
            activityDefinitions: [
                LifeActivityDefinition(
                    id: "sit-chair",
                    activity: .sit(anchorID: "sit-chair"),
                    phases: phases,
                    interruptible: true,
                    cooldownSeconds: 0
                ),
            ],
            cameras: [
                WorldCameraAnchor(
                    id: "wide",
                    transform: transform(0, 2, 5),
                    fieldOfViewDegrees: 50,
                    nearPlane: 0.1,
                    farPlane: 100
                ),
            ],
            capabilities: [
                WorldCapability("navigation"),
                .activity("sit-chair"),
                .camera("wide"),
            ],
            resources: []
        )
    }
}
