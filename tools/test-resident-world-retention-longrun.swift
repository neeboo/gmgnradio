import Foundation

// Long-resident event-retention proof, pure offline.
//
// Drives the real production runtime types (WorldAgentContext + ResidentAgentLoop
// + ResidentWorldObservation, compiled from apps/macos/Sources/GMGNRadio/Agent)
// over a simulated 30 Hz resident clock for one wall-clock-free simulated hour
// plus a formal-activity phase and a second idle tail, then asserts:
//   - the retained world event log never grows at the clock cadence,
//   - clock events never enter the retained log or observation deliveries,
//   - formal activity/weather/goal results (including a real executor failure)
//     are still observed after the long run,
//   - event sequences stay strictly monotonic and never restart,
//   - the resident loop caps what it keeps and nothing triggers a model run,
//   - the world-state archive schema and stable-byte contract are unchanged
//     (no event retention state leaks into the archive).

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent")
let contextSource = sources.appendingPathComponent("WorldAgentContext.swift")

let harness = #"""
import Foundation
import WorldRuntime
@MainActor var checks = 0, failures = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
@MainActor func isClockKind(_ kind: WorldEventKind) -> Bool {
    switch kind {
    case .timeAdvanced, .timeCaughtUp: return true
    default: return false
    }
}
@MainActor func floorWorld(y: Float) -> CollisionVolumeWorld {
    CollisionVolumeWorld(volumes: [WorldCollisionVolume(
        id: "fixture.floor", center: .init(x: 0, y: y, z: 0),
        halfExtents: .init(x: 50, y: 0.5, z: 50), rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
    )])
}
/// Starts a real multi-meter walk (spawn to the farthest reachable waypoint) so the
/// movement itself produces more pose events than the retained window can hold.
@MainActor func startFarWalk(_ walker: WorldAgentContext, in manifest: WorldManifest) -> String? {
    let spawn = manifest.spawn.position
    let candidates = manifest.waypoints
        .filter { $0.enabled }
        .map { (id: $0.id, distance: hypot($0.position.x - spawn.x, $0.position.z - spawn.z)) }
        .filter { $0.distance >= 3 }
        .sorted { $0.distance > $1.distance }
    for candidate in candidates {
        do {
            _ = try walker.move(to: candidate.id)
            if walker.currentMovementRequestID != nil { return candidate.id }
        } catch {
            continue
        }
    }
    return nil
}
@MainActor func walkUntilArrived(_ walker: WorldAgentContext, tickCap: Int) throws -> Int {
    var ticks = 0
    while walker.currentMovementRequestID != nil, ticks < tickCap {
        try walker.tick(deltaTime: 1.0 / 30.0)
        ticks += 1
    }
    return ticks
}
@main struct Tests {
    @MainActor static func main() throws {
        let manifestPath = "apps/macos/Resources/Worlds/marble-living-cabin/world.json"
        let manifest = try JSONDecoder().decode(WorldManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let context = try WorldAgentContext(manifest: manifest)
        let earlyState = context.state
        let earlyKeys = Set(try (JSONSerialization.jsonObject(with: encoder.encode(earlyState)) as! [String: Any]).keys)
        check(!earlyKeys.contains("events"), "world-state archive never contains the event log")
        context.installCollisionWorld(floorWorld(y: manifest.spawn.position.y - 0.5))

        let loop = ResidentAgentLoop(run: { _ in fatalError("retention run must never invoke a model") })
        let scopeID = "retention-\(UUID().uuidString)"
        var rawBatches: [[WorldEvent]] = []
        var raw: [WorldEvent] = []
        var residentKinds: [String] = []
        context.onEventsPublished = { batch in
            rawBatches.append(batch)
            raw += batch
            for event in batch {
                if let observation = ResidentWorldObservation.event(event, worldID: manifest.worldID, scopeID: scopeID) {
                    residentKinds.append(observation.kind)
                    loop.receiveEvent(observation)
                }
            }
        }

        // Phase 1: an idling resident for 60 simulated minutes at 30 Hz.
        let hourTicks = 60 * 60 * 30
        for _ in 0..<hourTicks { try context.tick(deltaTime: 1.0 / 30.0) }
        check(context.events.count == 1, "one simulated hour of 30 Hz ticking retains only the load fact")
        check(context.events.first != nil, "retained log still starts with the initial load fact")
        check(context.events.allSatisfy { !isClockKind($0.kind) }, "clock events never enter the retained log")
        check(context.state.revision == UInt64(hourTicks), "revision still counts every tick")
        let idleSequences = context.events.map(\.sequence)
        check(idleSequences == Array(idleSequences.sorted()) && Set(idleSequences).count == idleSequences.count,
            "retained sequences are monotonic and unique after the long idle run")
        // The load fact was delivered exactly once, on the first publish after attach.
        check(rawBatches.first?.count == 1 && rawBatches.count == 1, "the long idle run delivered no observation batches beyond the single initial load fact")
        check(residentKinds == ["world_loaded"], "resident loop saw only the initial load fact while idle")
        check(loop.snapshot.recentEvents.count == 1, "resident loop caps and keeps the load observation")

        // Phase 2: formal results after the long idle run must still be observed.
        try context.setWeather(.rain)
        check(context.events.count == 2, "weather change is retained after the long run")
        try context.completeGoal(id: "fixture.goal")
        check(context.events.contains { if case .goalCompleted("fixture.goal") = $0.kind { true } else { false } },
            "goal completion is retained after the long run")

        // Real executor failure still reaches the resident after the long run.
        try context.startActivity(id: "home.walk")
        context.installCollisionWorld(CollisionVolumeWorld(volumes: []))
        try context.tick(deltaTime: 0.1)
        check(residentKinds.contains("activity_failed"), "formal activity failure is observed after the long run")
        check(raw.contains { if case .activityFailed("home.walk", _) = $0.kind { true } else { false } },
            "activity failure stays in the retained log after the long run")
        let beforeTailCount = context.events.count
        check(beforeTailCount <= 200, "the whole scenario retains only a small formal log (\(beforeTailCount)) versus \(hourTicks) ticks")

        // Phase 3: the resident rests again — a further 15 idle minutes must not grow the log.
        for _ in 0..<(15 * 60 * 30) { try context.tick(deltaTime: 1.0 / 30.0) }
        check(context.events.count == beforeTailCount, "post-activity idle tail never grows the retained log")
        check(context.events.allSatisfy { !isClockKind($0.kind) }, "clock events never enter the retained log (tail)")

        // Phase 4: continuous real walking under per-tick observation stays inside
        // the fixed-capacity window. A resident that walks for tens of simulated
        // seconds used to append one pose event per tick forever; now the window
        // pins at capacity while every formal result still arrives and no
        // re-observation boundary is ever fabricated (the observer never lags).
        let walker = try WorldAgentContext(manifest: manifest, walkingSpeed: 0.5)
        walker.installCollisionWorld(floorWorld(y: manifest.spawn.position.y - 0.5))
        var walkerRaw: [WorldEvent] = []
        // The resident is attached before the walk starts, so it observes every tick.
        walker.onEventsPublished = { walkerRaw += $0 }
        guard let destination = startFarWalk(walker, in: manifest) else {
            print("FAIL: cabin has no far walkable waypoint for the movement phase")
            failures += 1
            exit(1)
        }
        let walkerTicks = try walkUntilArrived(walker, tickCap: 60 * 30)
        check(walker.currentMovementRequestID == nil, "long real walk completes within the sim budget")
        check(walkerTicks >= WorldSimulation.retainedEventCapacity,
            "the walk really moved continuously for enough ticks (\(walkerTicks)) to overflow the cache")
        check(walker.events.count == WorldSimulation.retainedEventCapacity,
            "continuous real movement pins the retained window at fixed capacity (\(walker.events.count))")
        check(walker.events.first.flatMap { if case .worldLoaded = $0.kind { true } else { false } } == true,
            "session marker survives the long walk at the window head")
        check(walker.events.last.flatMap { if case let .movementCompleted(_, ended) = $0.kind { ended == destination } else { false } } == true,
            "the movement result survives as the newest retained fact")
        check(walkerRaw.contains { if case let .movementCompleted(_, ended) = $0.kind { ended == destination } else { false } },
            "per-tick observation delivers the movement result during continuous walking")
        check(!walkerRaw.contains { if case .worldRestored = $0.kind { true } else { false } },
            "no world-restored boundary is fabricated while the observer keeps up with the cache")
        check(!walkerRaw.contains { if case .observationGap = $0.kind { true } else { false } },
            "no observation-gap notice is fabricated while the observer keeps up with the cache")
        try walker.setWeather(.rain)
        check(walkerRaw.contains { if case .weatherChanged(.rain) = $0.kind { true } else { false } },
            "a formal fact after the pinned window is still observed")
        check(walker.events.count == WorldSimulation.retainedEventCapacity,
            "window stays at fixed capacity after the post-walk formal fact")
        check(walker.events.first.flatMap { if case .worldLoaded = $0.kind { true } else { false } } == true,
            "marker stays pinned after the post-walk formal fact")

        // Phase 5: a consumer that lags beyond the cache — the resident attaches only
        // after an unattended long walk already overflowed the window — receives an
        // explicit OBSERVATION-GAP notice (never a fabricated world-restored fact)
        // instead of a silently trimmed history.
        let lagging = try WorldAgentContext(manifest: manifest, walkingSpeed: 0.5)
        lagging.installCollisionWorld(floorWorld(y: manifest.spawn.position.y - 0.5))
        guard let lagDestination = startFarWalk(lagging, in: manifest) else {
            print("FAIL: cabin has no far walkable waypoint for the lag phase")
            failures += 1
            exit(1)
        }
        check(lagDestination == destination, "the lag phase walks the same real route")
        let lagTicks = try walkUntilArrived(lagging, tickCap: 60 * 30)
        check(lagging.currentMovementRequestID == nil, "unattended long walk completes within the sim budget")
        check(lagTicks >= WorldSimulation.retainedEventCapacity,
            "the unattended walk moved long enough (\(lagTicks)) to overflow the cache")
        check(lagging.simulation.trimmedNewestSequence != nil,
            "the unattended walk overflowed the cache: the observer lagged beyond the fixed window")
        var lagBatches: [[WorldEvent]] = []
        lagging.onEventsPublished = { lagBatches.append($0) }
        try lagging.setWeather(.rain)
        check(lagBatches.first?.first.flatMap { event in
            if case .observationGap = event.kind { return true } else { return false }
        } == true,
            "a lagging consumer receives an explicit observation-gap notice first")
        check(!(lagBatches.first?.contains { if case .worldRestored = $0.kind { true } else { false } } ?? true),
            "the gap notice is never a fabricated world-restored fact")
        check(!(lagBatches.first?.contains { if case .worldLoaded = $0.kind { true } else { false } } ?? true),
            "the stale session marker is not replayed as if history were complete")
        let laggingDelivered = lagBatches.flatMap { $0 }
        check(laggingDelivered.contains { if case let .movementCompleted(_, ended) = $0.kind { ended == lagDestination } else { false } },
            "a recent real movement result still reaches the late observer")
        check(laggingDelivered.contains { if case .weatherChanged(.rain) = $0.kind { true } else { false } },
            "facts recorded after re-attachment reach the late observer")
        check(laggingDelivered.filter { if case .observationGap = $0.kind { true } else { false } }.count == 1,
            "the observation-gap notice is delivered exactly once")
        check(laggingDelivered.first(where: { if case .observationGap = $0.kind { true } else { false } })?
            .sequence == lagging.simulation.trimmedNewestSequence,
            "the notice anchors to the real eviction watermark, not a reserved UInt64.max band")
        check(lagging.events.count == WorldSimulation.retainedEventCapacity,
            "the lagging context stays bounded after the explicit observation gap")

        // Authored finite activity completes through the real executor and is observed.
        var authored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        var definitions = authored["activityDefinitions"] as! [[String: Any]]
        for index in definitions.indices {
            var phases = definitions[index]["phases"] as! [[String: Any]]
            for phase in phases.indices { phases[phase]["durationSeconds"] = 0.01 }
            definitions[index]["phases"] = phases
        }
        authored["activityDefinitions"] = definitions
        let finiteManifest = try JSONDecoder().decode(WorldManifest.self,
            from: JSONSerialization.data(withJSONObject: authored))
        let finite = try WorldAgentContext(manifest: finiteManifest)
        finite.installCollisionWorld(floorWorld(y: finiteManifest.spawn.position.y - 0.5))
        var finiteRaw: [WorldEvent] = []
        finite.onEventsPublished = { batch in
            finiteRaw += batch
            for event in batch {
                if let observation = ResidentWorldObservation.event(event, worldID: finiteManifest.worldID, scopeID: scopeID) {
                    loop.receiveEvent(observation)
                }
            }
        }
        try finite.startActivity(id: "home.idle")
        for _ in 0..<3 { try finite.tick(deltaTime: 0.02) }
        check(finiteRaw.contains { if case .activityCompleted("home.idle") = $0.kind { true } else { false } },
            "authored finite activity publishes an actual completion after retention change")
        check(finite.state.activeActivity == nil, "completion event agrees with world state")
        check(finite.events.allSatisfy { !isClockKind($0.kind) }, "clock events never enter the finite-run log")

        // Resident-loop stream stays bounded by its own cap and never runs a model.
        check(loop.snapshot.recentEvents.count <= 24, "resident loop keeps observations within its own cap")
        check(!loop.snapshot.isRunning, "long retention run never started a model request")

        // Archive contract: the schema of the pre-run state equals the schema of the
        // long-run state, no events/retention fields ever leak into the archive, and
        // bytes stay stable through a save -> load -> save round trip.
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-retention-\(UUID()).json")
        let persistence = AtomicJSONWorldStatePersistence(fileURL: persistenceURL)
        try persistence.save(context.state)
        let firstBytes = try Data(contentsOf: persistenceURL)
        guard let loadedState = try persistence.load() else {
            print("FAIL: long-run state does not load from its archive")
            failures += 1
            exit(1)
        }
        try persistence.save(loadedState)
        let secondBytes = try Data(contentsOf: persistenceURL)
        check(firstBytes == secondBytes, "archive bytes stay stable through save/load/save after the long run")
        let stateAfterKeys = Set(try (JSONSerialization.jsonObject(with: encoder.encode(loadedState)) as! [String: Any]).keys)
        check(stateAfterKeys == earlyKeys, "archive schema is unchanged by the retention feature")
        check(!stateAfterKeys.contains("events"), "reloaded archive still contains no event log")
        check(loadedState.revision == context.state.revision, "archived revision matches the long-run revision")
        try? FileManager.default.removeItem(at: persistenceURL)

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident retention checks, \(failures) failures; retained events \(context.events.count), ticks \(hourTicks + 15 * 60 * 30 + 1)")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-world-retention-longrun-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("tests")
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let worldRuntimeModules = worldRuntimeFlags[1]
let objects = Array(worldRuntimeFlags.dropFirst(2))
let compiled = try run("/usr/bin/swiftc", ["-j1", "-swift-version", "6", "-parse-as-library", "-I", worldRuntimeModules,
    contextSource.path, sources.appendingPathComponent("ResidentAgentLoop.swift").path,
    sources.appendingPathComponent("ResidentMemoryStore.swift").path,
    sources.appendingPathComponent("ResidentStateClient.swift").path,
    sources.appendingPathComponent("ResidentSteeringDelivery.swift").path, sources.appendingPathComponent("ResidentWorldObservation.swift").path,
    program.path, "-o", executable.path] + objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
