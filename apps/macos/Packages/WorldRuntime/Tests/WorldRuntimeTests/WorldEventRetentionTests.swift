import Foundation
import Testing
@testable import WorldRuntime

/// Retention contract for the resident world event log:
///
/// - `advance`/`catchUp` still return their clock receipts and still advance the
///   revision, but their `.timeAdvanced`/`.timeCaughtUp` events are disposable and
///   are never retained, so a resident ticking at 30 Hz cannot grow the log.
/// - Formal results (weather, goals, activities, movement, layout) and the
///   pose/camera mutations consumers read are retained.
/// - The retained window is a **fixed-capacity** cache (`retainedEventCapacity`,
///   marker included): continuous movement that would previously append one
///   `.agentTransformUpdated` per tick forever is bounded. The session-boundary
///   marker (`.worldLoaded`/`.worldRestored`) is never evicted; the newest events
///   always survive.
/// - Event sequences are the world's mutation watermark (== revision): strictly
///   monotonic, never restarting at zero after restores, long clock runs, or
///   window eviction — and eviction itself is never silent: `trimmedNewestSequence`
///   reports the newest evicted sequence so a sequence-cursor consumer can detect
///   an honest gap instead of mistaking a trimmed history for a complete one.
///   Action receipts returned by the mutating API are never affected by trimming.
@Test("Thirty-Hz resident ticking never grows the retained event log")
func thirtyHzTickingNeverGrowsRetainedLog() throws {
    let manifest = makeRetentionManifest()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)

    // 45 simulated minutes of an idling resident at 30 Hz — no real waiting.
    let ticks = 45 * 60 * 30
    var previousSequence: UInt64 = 0
    for tick in 1...ticks {
        let event = try simulation.advance(
            by: 1.0 / 30.0,
            expectedRevision: simulation.state.revision
        )
        #expect(event.sequence == UInt64(tick), "clock receipts carry the mutation watermark")
        #expect(event.sequence > previousSequence, "clock receipts stay strictly monotonic")
        previousSequence = event.sequence
        #expect(event.revision == UInt64(tick))
    }

    #expect(simulation.state.revision == UInt64(ticks))
    // Repeated 1/30 additions accumulate sub-second float error; compare with tolerance.
    let elapsed = simulation.state.worldTime.timeIntervalSince(startedAt)
    #expect(abs(elapsed - TimeInterval(ticks) / 30.0) < 2.0)
    #expect(simulation.events.count == 1, "retained log only holds the initial load fact")
    #expect(simulation.events.first?.kind == .worldLoaded(worldID: manifest.worldID))
    #expect(simulation.events.first?.sequence == 0)
}

@Test("Formal results are retained around a long disposable clock stream")
func formalResultsAreRetainedAroundClockStream() throws {
    let manifest = makeRetentionManifest()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)

    func tickClock(_ simulation: inout WorldSimulation, count: Int) throws {
        for _ in 0..<count {
            _ = try simulation.advance(by: 1.0 / 30.0, expectedRevision: simulation.state.revision)
        }
    }

    // Idle clock stream first: 10 simulated minutes with no results.
    try tickClock(&simulation, count: 10 * 60 * 30)
    #expect(simulation.events.count == 1)

    // A mix of formal results, each separated by further clock noise.
    try tickClock(&simulation, count: 120)
    let transform = WorldTransform(
        position: WorldVector3(x: 2, y: 0, z: 4),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        scale: WorldVector3(x: 1, y: 1, z: 1)
    )
    _ = try simulation.updateAgentTransform(transform, expectedRevision: simulation.state.revision)
    try tickClock(&simulation, count: 150)
    _ = try simulation.setLiveCamera(
        WorldCameraState(anchorID: "camera.window", transform: transform,
            fieldOfViewDegrees: 50, nearPlane: 0.1, farPlane: 100),
        expectedRevision: simulation.state.revision
    )
    try tickClock(&simulation, count: 90)
    _ = try simulation.setWeather(.rain, expectedRevision: simulation.state.revision)
    try tickClock(&simulation, count: 45)
    _ = try simulation.startActivity("window.gaze", expectedRevision: simulation.state.revision)
    try tickClock(&simulation, count: 300)
    _ = try simulation.interruptActivity(reason: "conversation", expectedRevision: simulation.state.revision)
    try tickClock(&simulation, count: 30)
    _ = try simulation.resumeActivity(expectedRevision: simulation.state.revision)
    try tickClock(&simulation, count: 300)
    _ = try simulation.failActivity(reason: "fixture.failure", expectedRevision: simulation.state.revision)
    try tickClock(&simulation, count: 30)
    _ = try simulation.completeGoal("goal.sunset", summary: "watched", expectedRevision: simulation.state.revision)
    _ = try simulation.recordMovementOutcome(requestID: "move-1", destinationID: "wp.window",
        expectedRevision: simulation.state.revision)
    _ = try simulation.recordMovementOutcome(requestID: "move-2", destinationID: "wp.door",
        failure: "blocked", expectedRevision: simulation.state.revision)
    // Final idle clock stream: 20 more simulated minutes with zero new results.
    try tickClock(&simulation, count: 20 * 60 * 30)

    #expect(simulation.events.map(\.kind) == [
        .worldLoaded(worldID: manifest.worldID),
        .agentTransformUpdated(transform: transform),
        .liveCameraChanged(camera: WorldCameraState(anchorID: "camera.window", transform: transform,
            fieldOfViewDegrees: 50, nearPlane: 0.1, farPlane: 100)),
        .weatherChanged(weather: .rain),
        .activityStarted(activityID: "window.gaze"),
        .activityInterrupted(activityID: "window.gaze", reason: "conversation"),
        .activityResumed(activityID: "window.gaze"),
        .activityFailed(activityID: "window.gaze", reason: "fixture.failure"),
        .goalCompleted(goalID: "goal.sunset"),
        .movementCompleted(requestID: "move-1", destinationID: "wp.window"),
        .movementFailed(requestID: "move-2", destinationID: "wp.door", reason: "blocked"),
    ])

    let sequences = simulation.events.map(\.sequence)
    #expect(sequences == Array(sequences.sorted()), "retained sequences stay monotonic")
    #expect(Set(sequences).count == sequences.count, "retained sequences never repeat")
    #expect(sequences.first == 0)
    #expect(simulation.events.allSatisfy { $0.sequence == $0.revision },
        "sequence is the mutation watermark")
    #expect(simulation.events.allSatisfy {
        switch $0.kind {
        case .timeAdvanced, .timeCaughtUp: false
        default: true
        }
    }, "clock events never enter the retained log")
}

@Test("Restoring a world keeps event sequences strictly above the persisted watermark")
func restoringKeepsMonotonicSequenceWatermark() throws {
    try withRetentionTemporaryDirectory { directory in
        let manifest = makeRetentionManifest()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let fileURL = directory.appendingPathComponent("world-state.json")
        let persistence = AtomicJSONWorldStatePersistence(fileURL: fileURL)

        var simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)
        _ = try simulation.startActivity("read.sofa", expectedRevision: 0)
        for _ in 0..<9_999 {
            _ = try simulation.advance(by: 1.0 / 30.0, expectedRevision: simulation.state.revision)
        }
        try persistence.save(simulation.state)
        let loaded = try persistence.load()
        let loadedState = try #require(loaded)

        // The retained log is intentionally small even though the revision is high.
        #expect(simulation.events.count == 2)
        #expect(loadedState.revision == 10_000)

        var restored = WorldSimulation(restoring: loadedState)
        #expect(restored.events.count == 1)
        #expect(restored.events.first?.kind == .worldRestored(worldID: manifest.worldID))
        #expect(restored.events.first?.sequence == loadedState.revision,
            "restore marker carries the persisted watermark")

        // A further long clock run adds nothing to the restored log.
        for _ in 0..<5_400 {
            _ = try restored.advance(by: 1.0 / 30.0, expectedRevision: restored.state.revision)
        }
        #expect(restored.events.count == 1)

        let firstAfterRestore = try restored.completeGoal("goal.after-restore",
            expectedRevision: restored.state.revision)
        #expect(firstAfterRestore.sequence == loadedState.revision + 5_400 + 1,
            "sequences continue above the watermark instead of restarting at zero")
        #expect(restored.events.count == 2)
        #expect(restored.events.last?.kind == .goalCompleted(goalID: "goal.after-restore"))
    }
}

@Test("Continuous movement is bounded by the fixed-capacity retained window")
func continuousMovementWindowStaysBounded() throws {
    let manifest = makeRetentionManifest()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)

    let capacity = WorldSimulation.retainedEventCapacity
    let nonMarkerCapacity = capacity - 1
    #expect(nonMarkerCapacity >= 4, "capacity must leave room for recent facts")
    // A walk that previously grew the log without limit: ~34 simulated minutes of
    // 30 Hz pose movement would be 61,440 appends; 2,048 is enough to overflow the
    // window dozens of times while staying instant.
    let steps = capacity * 32
    var previousReceipt: UInt64 = 0
    for step in 1...steps {
        let receipt = try simulation.updateAgentTransform(
            retentionPose(x: Float(step)),
            expectedRevision: simulation.state.revision
        )
        #expect(receipt.sequence == receipt.revision,
            "movement receipts carry the mutation watermark")
        #expect(receipt.sequence > previousReceipt,
            "receipts stay strictly monotonic even while the window trims")
        previousReceipt = receipt.sequence
    }
    // Bounded: the window holds exactly the marker plus the newest events.
    #expect(simulation.events.count == capacity,
        "continuous movement never grows the window past capacity")
    #expect(simulation.events.first?.kind == .worldLoaded(worldID: manifest.worldID),
        "the session marker is never evicted")
    // The retained window is the newest suffix, and eviction is explicit.
    let expectedTrimmed = UInt64(steps - nonMarkerCapacity)
    #expect(simulation.trimmedNewestSequence == expectedTrimmed,
        "eviction watermark equals the newest evicted sequence")
    #expect(simulation.events[1].sequence == expectedTrimmed + 1,
        "window head (after the marker) is the first surviving movement event")
    #expect(simulation.events.last?.sequence == UInt64(steps),
        "window tail is the newest movement event")
    #expect(simulation.state.revision == UInt64(steps),
        "revision still counts every mutation")
    let sequences = simulation.events.map(\.sequence)
    #expect(sequences == Array(sequences.sorted()) && Set(sequences).count == sequences.count,
        "retained sequences stay monotonic and unique through trimming")
    #expect(simulation.events.allSatisfy { $0.sequence == $0.revision },
        "sequence stays the mutation watermark through trimming")

    // A newest formal fact still lands in the window after all that movement.
    _ = try simulation.recordMovementOutcome(requestID: "walk-final", destinationID: "wp.end",
        expectedRevision: simulation.state.revision)
    #expect(simulation.events.last?.kind == .movementCompleted(requestID: "walk-final", destinationID: "wp.end"),
        "a real action receipt after movement is retained, never trimmed away instantly")
    #expect(simulation.events.count == capacity)
    #expect(simulation.trimmedNewestSequence == expectedTrimmed + 1,
        "trimming advances monotonically past the newest evicted event")
    #expect(simulation.events.first?.kind == .worldLoaded(worldID: manifest.worldID),
        "marker survives continued trimming")
}

@Test("Trimming exposes an honest gap watermark under clock noise")
func trimmingKeepsDetectableGapWatermark() throws {
    let manifest = makeRetentionManifest()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)
    let capacity = WorldSimulation.retainedEventCapacity
    let nonMarkerCapacity = capacity - 1

    // Each retained pose is separated by a disposable clock tick, so retained
    // sequences skip (2, 4, 6, ...) exactly as they do in a real 30 Hz resident.
    let steps = capacity * 24
    for step in 1...steps {
        _ = try simulation.advance(by: 1.0 / 30.0, expectedRevision: simulation.state.revision)
        _ = try simulation.updateAgentTransform(
            retentionPose(x: Float(step)),
            expectedRevision: simulation.state.revision
        )
    }
    #expect(simulation.events.count == capacity)
    #expect(simulation.state.revision == UInt64(steps * 2))
    let expectedTrimmed = UInt64((steps - nonMarkerCapacity) * 2)
    #expect(simulation.trimmedNewestSequence == expectedTrimmed,
        "eviction watermark is the newest evicted sequence under clock noise")
    #expect(simulation.events[1].sequence == expectedTrimmed + 2,
        "surviving head is the first un-evicted pose after the gap frontier")

    // A formal fact recorded mid-walk falls out of the window once the walk passes
    // the fixed capacity — never silently: the gap is measurable from the public
    // watermark, and a late cursor detects it instead of assuming completeness.
    _ = try simulation.completeGoal("goal.walk-middle",
        expectedRevision: simulation.state.revision)   // becomes window tail
    #expect(simulation.events.last?.kind == .goalCompleted(goalID: "goal.walk-middle"),
        "newest formal fact is retained")
    _ = try simulation.recordMovementOutcome(requestID: "walk-a", destinationID: "wp.a",
        expectedRevision: simulation.state.revision)
    #expect(simulation.events.last?.kind == .movementCompleted(requestID: "walk-a", destinationID: "wp.a"))

    // Simulate a consumer cursor that scanned through a middle pose sequence.
    let upToDateCursor = simulation.state.revision
    #expect(simulation.trimmedNewestSequence.map { upToDateCursor < $0 } ?? false == false,
        "a consumer that scanned everything sees no gap")
    let laggingCursor: UInt64 = 4
    #expect(simulation.trimmedNewestSequence.map { laggingCursor < $0 } ?? false == true,
        "a consumer lagging behind the eviction frontier detects a real gap")
    #expect(simulation.events.allSatisfy { $0.sequence > simulation.trimmedNewestSequence! || $0.sequence == 0 },
        "window contains only the marker and events strictly above the gap frontier")
}

@Test("Restored worlds keep a bounded window with the restore marker at the head")
func restoredWorldKeepsBoundedWindowAndWatermark() throws {
    try withRetentionTemporaryDirectory { directory in
        let manifest = makeRetentionManifest()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let fileURL = directory.appendingPathComponent("world-state.json")
        let persistence = AtomicJSONWorldStatePersistence(fileURL: fileURL)

        var simulation = WorldSimulation(manifest: manifest, startedAt: startedAt)
        _ = try simulation.startActivity("read.sofa", expectedRevision: 0)
        for _ in 0..<9_999 {
            _ = try simulation.advance(by: 1.0 / 30.0, expectedRevision: simulation.state.revision)
        }
        try persistence.save(simulation.state)
        let loaded = try persistence.load()
        let loadedState = try #require(loaded)

        var restored = WorldSimulation(restoring: loadedState)
        #expect(restored.events == [WorldEvent(sequence: loadedState.revision,
            revision: loadedState.revision, worldTime: loadedState.worldTime,
            kind: .worldRestored(worldID: manifest.worldID))])

        // A long post-restore walk (each pose preceded by a clock tick) overflows
        // the fixed capacity many times.
        let capacity = WorldSimulation.retainedEventCapacity
        let steps = capacity * 16
        for step in 1...steps {
            _ = try restored.advance(by: 1.0 / 30.0, expectedRevision: restored.state.revision)
            _ = try restored.updateAgentTransform(
                retentionPose(x: Float(step)),
                expectedRevision: restored.state.revision
            )
        }
        #expect(restored.events.count == capacity,
            "post-restore movement stays within the fixed capacity")
        #expect(restored.events.first?.kind == .worldRestored(worldID: manifest.worldID),
            "the restore marker survives capacity overflow")
        #expect(restored.events.first?.sequence == loadedState.revision,
            "restore marker keeps the persisted watermark as its sequence")

        // Watermark arithmetic: each of the `steps` iterations consumed one clock
        // revision and one pose revision after the restore.
        let revisionAfterWalk = loadedState.revision + UInt64(steps * 2)
        #expect(restored.state.revision == revisionAfterWalk)
        let firstAfterRestore = try restored.completeGoal("goal.after-restore",
            expectedRevision: restored.state.revision)
        #expect(firstAfterRestore.sequence == revisionAfterWalk + 1,
            "sequences continue above the persisted watermark instead of restarting")
        #expect(restored.events.last?.kind == .goalCompleted(goalID: "goal.after-restore"))
        #expect(restored.events.count == capacity,
            "a formal fact after the walk is retained within the bounded window")
    }
}

private func retentionPose(x: Float) -> WorldTransform {
    WorldTransform(
        position: WorldVector3(x: x, y: 0, z: 0),
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        scale: WorldVector3(x: 1, y: 1, z: 1)
    )
}

private func makeRetentionManifest() -> WorldManifest {
    WorldManifest(
        schemaVersion: 1,
        packageID: "retention-tests",
        packageVersion: "1.0.0",
        worldID: "world.tests.retention",
        displayName: "Retention",
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

private func withRetentionTemporaryDirectory(
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
