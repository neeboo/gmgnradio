import Foundation
import Testing
@testable import WorldRuntime

@Test("Simulation loads the agent at the authored spawn")
func simulationLoadsAtSpawn() {
    let manifest = makeSimulationManifest()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    let simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)

    #expect(simulation.state.revision == 0)
    #expect(simulation.state.worldID == manifest.worldID)
    #expect(simulation.state.worldTime == startedAt)
    #expect(simulation.state.lastObservedWallTime == startedAt)
    #expect(simulation.state.weather == .clear)
    #expect(simulation.state.agentTransform == manifest.spawn)
    #expect(simulation.state.activeActivity == nil)
    #expect(simulation.state.objectStates.isEmpty)
    #expect(simulation.events == [
        WorldEvent(
            sequence: 0,
            revision: 0,
            worldTime: startedAt,
            kind: .worldLoaded(worldID: manifest.worldID)
        ),
    ])
}

@Test("Advancing time changes logical state once and emits a stable event")
func simulationAdvancesLogicalTimeDeterministically() throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: startedAt
    )

    let event = try simulation.advance(by: 12.5, expectedRevision: 0)

    #expect(simulation.state.revision == 1)
    #expect(simulation.state.worldTime == startedAt.addingTimeInterval(12.5))
    #expect(simulation.state.lastObservedWallTime == startedAt)
    #expect(event == WorldEvent(
        sequence: 1,
        revision: 1,
        worldTime: startedAt.addingTimeInterval(12.5),
        kind: .timeAdvanced(duration: 12.5)
    ))
    #expect(simulation.events.last == event)
}

@Test("A stale revision cannot mutate state or append an event")
func simulationRejectsStaleRevision() throws {
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    _ = try simulation.advance(by: 1, expectedRevision: 0)
    let stateBeforeStaleWrite = simulation.state
    let eventsBeforeStaleWrite = simulation.events

    #expect(throws: WorldSimulationError.staleRevision(
        submitted: 0,
        current: 1
    )) {
        try simulation.advance(by: 5, expectedRevision: 0)
    }
    #expect(simulation.state == stateBeforeStaleWrite)
    #expect(simulation.events == eventsBeforeStaleWrite)
}

@Test("Updating the agent transform emits one stable revision")
func simulationUpdatesAgentTransform() throws {
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transform = WorldTransform(
        position: WorldVector3(x: 4, y: 0, z: -2),
        rotation: WorldQuaternion(x: 0, y: 0.707, z: 0, w: 0.707),
        scale: WorldVector3(x: 1, y: 1, z: 1)
    )

    let event = try simulation.updateAgentTransform(
        transform,
        expectedRevision: 0
    )

    #expect(simulation.state.agentTransform == transform)
    #expect(simulation.state.revision == 1)
    #expect(event == WorldEvent(
        sequence: 1,
        revision: 1,
        worldTime: simulation.state.worldTime,
        kind: .agentTransformUpdated(transform: transform)
    ))
}

@Test("Changing weather emits one stable revision")
func simulationSetsWeather() throws {
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let event = try simulation.setWeather(.rain, expectedRevision: 0)

    #expect(simulation.state.weather == .rain)
    #expect(simulation.state.revision == 1)
    #expect(event.kind == .weatherChanged(weather: .rain))
}

@Test("Moving the live camera persists its independent state")
func simulationSetsLiveCamera() throws {
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let camera = WorldCameraState(
        anchorID: "camera.window",
        transform: WorldTransform(
            position: WorldVector3(x: 2, y: 1.5, z: 3),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        fieldOfViewDegrees: 50,
        nearPlane: 0.1,
        farPlane: 100
    )

    let event = try simulation.setLiveCamera(camera, expectedRevision: 0)

    #expect(simulation.state.liveCamera == camera)
    #expect(simulation.state.revision == 1)
    #expect(event.kind == .liveCameraChanged(camera: camera))
}

@Test("Completing a goal records it once at logical world time")
func simulationCompletesGoalOnce() throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: startedAt
    )

    let event = try simulation.completeGoal(
        "goal.watch-sunrise",
        summary: "Watched from the kitchen window",
        expectedRevision: 0
    )

    #expect(simulation.state.completedGoals == [
        "goal.watch-sunrise": WorldGoalState(
            goalID: "goal.watch-sunrise",
            completedAt: startedAt,
            summary: "Watched from the kitchen window"
        ),
    ])
    #expect(simulation.state.revision == 1)
    #expect(event.kind == .goalCompleted(goalID: "goal.watch-sunrise"))
    #expect(throws: WorldSimulationError.goalAlreadyCompleted(
        goalID: "goal.watch-sunrise"
    )) {
        try simulation.completeGoal(
            "goal.watch-sunrise",
            expectedRevision: 1
        )
    }
    #expect(simulation.state.revision == 1)
    #expect(simulation.events.count == 2)
}

@Test("Activities can be interrupted, resumed, and completed without counting paused time")
func simulationRunsActivityLifecycle() throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: startedAt
    )

    _ = try simulation.startActivity("window.gaze", expectedRevision: 0)
    _ = try simulation.advance(by: 10, expectedRevision: 1)
    _ = try simulation.interruptActivity(
        reason: "conversation",
        expectedRevision: 2
    )
    _ = try simulation.advance(by: 5, expectedRevision: 3)

    #expect(simulation.state.activeActivity == WorldActivityState(
        activityID: "window.gaze",
        status: .interrupted,
        startedAt: startedAt,
        elapsedActiveTime: 10,
        interruptionReason: "conversation"
    ))

    _ = try simulation.resumeActivity(expectedRevision: 4)
    _ = try simulation.advance(by: 2, expectedRevision: 5)
    let completed = try simulation.completeActivity(expectedRevision: 6)

    #expect(simulation.state.activeActivity == nil)
    #expect(simulation.state.revision == 7)
    #expect(completed.kind == .activityCompleted(activityID: "window.gaze"))
    #expect(simulation.events.map(\.kind) == [
        .worldLoaded(worldID: "world.tests.living-room"),
        .activityStarted(activityID: "window.gaze"),
        .timeAdvanced(duration: 10),
        .activityInterrupted(activityID: "window.gaze", reason: "conversation"),
        .timeAdvanced(duration: 5),
        .activityResumed(activityID: "window.gaze"),
        .timeAdvanced(duration: 2),
        .activityCompleted(activityID: "window.gaze"),
    ])
}

@Test("Cancelling an activity clears simulation state with one event")
func simulationCancelsActivity() throws {
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    _ = try simulation.startActivity("read.sofa", expectedRevision: 0)

    let event = try simulation.cancelActivity(
        reason: "user_request",
        expectedRevision: 1
    )

    #expect(simulation.state.activeActivity == nil)
    #expect(simulation.state.revision == 2)
    #expect(event.kind == .activityCancelled(
        activityID: "read.sofa",
        reason: "user_request"
    ))
}

@Test("Sleep catch-up advances logical time with one event instead of frame replay")
func simulationCatchesUpAfterSleepInOneStep() throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(
        manifest: makeSimulationManifest(),
        startedAt: startedAt
    )
    _ = try simulation.startActivity("read.sofa", expectedRevision: 0)
    let eventCountBeforeSleep = simulation.events.count
    let wakeTime = startedAt.addingTimeInterval(6 * 60 * 60)

    let event = try simulation.catchUp(
        to: wakeTime,
        expectedRevision: 1
    )

    #expect(simulation.state.revision == 2)
    #expect(simulation.state.worldTime == wakeTime)
    #expect(simulation.state.lastObservedWallTime == wakeTime)
    let elapsedActiveTime = try #require(
        simulation.state.activeActivity?.elapsedActiveTime
    )
    #expect(abs(elapsedActiveTime - 6 * 60 * 60) < 0.001)
    #expect(simulation.events.count == eventCountBeforeSleep + 1)
    guard case let .timeCaughtUp(duration) = event.kind else {
        Issue.record("Expected a single timeCaughtUp event")
        return
    }
    #expect(abs(duration - 6 * 60 * 60) < 0.001)
}

@Test("Atomic JSON persistence restores exact state with stable bytes")
func persistenceSavesAndRestoresState() throws {
    try withTemporaryDirectory { directory in
        let fileURL = directory.appendingPathComponent("world-state.json")
        let persistence = AtomicJSONWorldStatePersistence(fileURL: fileURL)
        var simulation = WorldSimulation(
            manifest: makeSimulationManifest(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        _ = try simulation.startActivity("read.sofa", expectedRevision: 0)
        _ = try simulation.advance(by: 42, expectedRevision: 1)

        try persistence.save(simulation.state)
        let firstEncoding = try Data(contentsOf: fileURL)
        let loadedState = try persistence.load()
        let restoredState = try #require(loadedState)
        try persistence.save(restoredState)
        let secondEncoding = try Data(contentsOf: fileURL)
        var restoredSimulation = WorldSimulation(restoring: restoredState)
        _ = try restoredSimulation.advance(
            by: 1,
            expectedRevision: restoredState.revision
        )

        #expect(restoredState == simulation.state)
        #expect(firstEncoding == secondEncoding)
        #expect(restoredSimulation.events.first?.kind == .worldRestored(
            worldID: restoredState.worldID
        ))
        #expect(restoredSimulation.state.revision == restoredState.revision + 1)
    }
}

@Test("Persistence reports no state before the first save")
func persistenceReturnsNilForMissingFile() throws {
    try withTemporaryDirectory { directory in
        let persistence = AtomicJSONWorldStatePersistence(
            fileURL: directory.appendingPathComponent("missing.json")
        )

        let restoredState = try persistence.load()
        #expect(restoredState == nil)
    }
}

@Test("Persistence loads state written before camera and goal fields existed")
func persistenceLoadsLegacyState() throws {
    try withTemporaryDirectory { directory in
        let fileURL = directory.appendingPathComponent("legacy-world-state.json")
        let persistence = AtomicJSONWorldStatePersistence(fileURL: fileURL)
        let state = WorldState(
            revision: 7,
            worldID: "world.tests.legacy",
            worldTime: Date(timeIntervalSince1970: 1_800_000_000),
            lastObservedWallTime: Date(timeIntervalSince1970: 1_800_000_001),
            weather: .cloudy,
            agentTransform: makeSimulationManifest().spawn
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(state))
                as? [String: Any]
        )
        object.removeValue(forKey: "liveCamera")
        object.removeValue(forKey: "completedGoals")
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: fileURL, options: .atomic)

        let loadedState = try persistence.load()
        let restored = try #require(loadedState)

        #expect(restored.liveCamera == nil)
        #expect(restored.completedGoals.isEmpty)
        #expect(restored.revision == 7)
        #expect(restored.worldID == "world.tests.legacy")
    }
}

private func makeSimulationManifest() -> WorldManifest {
    WorldManifest(
        schemaVersion: 1,
        packageID: "simulation-tests",
        packageVersion: "1.0.0",
        worldID: "world.tests.living-room",
        displayName: "Living Room",
        calibration: WorldCalibration(
            visualToGameplay: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ],
            metersPerUnit: 1
        ),
        spawn: WorldTransform(
            position: WorldVector3(x: 1, y: 0, z: 2),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        collisionVolumes: [],
        waypoints: [],
        routes: [],
        activities: [],
        cameras: [],
        capabilities: [],
        resources: []
    )
}

private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
