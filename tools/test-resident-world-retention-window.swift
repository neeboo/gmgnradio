import Foundation

// Independent event-window retention proof, pure offline.
//
// Compiles the production WorldAgentContext + ResidentWorldObservation (a local
// ResidentAgentLoop.Event stub stands in for the loop-owned type; no
// ResidentAgentLoop / memory layer, which is owned by a parallel workstream)
// against the rebuilt WorldRuntime objects, then drives the real marble-living-cabin
// manifest:
//   - per-tick observation delivers the load fact once and never grows the log
//     while the resident idles at 30 Hz,
//   - formal activity/weather/goal results (including a real executor failure)
//     still reach the observer,
//   - continuous REAL walking with the observer attached pins the retained window
//     at WorldSimulation.retainedEventCapacity (marker at the head), delivers the
//     movement result, and never fabricates a re-observation boundary,
//   - an observer that attaches only after an unattended walk already overflowed
//     the cache receives an explicit observation-gap notice FIRST: kind
//     `.observationGap`, resident kind "observation_gap" — never a fabricated
//     `.worldRestored` "the world recovered" fact, never a stale `.worldLoaded`
//     masquerading as complete history; the newest real movement fact still arrives
//     and is not swallowed by id-dedupe,
//   - the notice's sequence is the real eviction watermark (`trimmedNewestSequence`,
//     inside the live mutation-watermark range) — no reserved top-of-UInt64 band —
//     and its resident identity lives in a dedupe namespace disjoint from
//     `world:<scope>:<worldID>:<sequence>`,
//   - the sequence cursor advances before a synchronous re-entrant mutation (also
//     on the gap path: the notice is delivered exactly once),
//   - a late observer with no trimming still receives the initial load fact,
//   - a GENUINE restore keeps the .worldRestored marker at the head and maps to the
//     normal world_restored fact across a bounded post-restore walk, while sequences
//     keep rising above the persisted watermark,
//   - the world-state archive schema is unchanged (no event retention state leaks).

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent")
let contextSource = sources.appendingPathComponent("WorldAgentContext.swift")

let harness = #"""
import Foundation
import WorldRuntime
/// Minimal stand-in for the loop-owned `ResidentAgentLoop.Event` (same shape as the
/// production type) so the real ResidentWorldObservation mapper can be compiled and
/// proven offline without depending on the parallel workstream's unfinished loop.
@MainActor final class ResidentAgentLoop {
    struct Event: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let summary: String
    }
}
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
@MainActor func isResync(_ event: WorldEvent) -> Bool {
    if case .worldRestored = event.kind { return true }
    return false
}
@MainActor func isObservationGap(_ event: WorldEvent) -> Bool {
    if case .observationGap = event.kind { return true }
    return false
}
@MainActor func isMovementTo(_ event: WorldEvent, _ destination: String) -> Bool {
    if case let .movementCompleted(_, ended) = event.kind { ended == destination } else { false }
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

        var rawBatches: [[WorldEvent]] = []
        var raw: [WorldEvent] = []
        context.onEventsPublished = { batch in
            rawBatches.append(batch)
            raw += batch
        }

        // Phase 1: an idling resident for 30 simulated minutes at 30 Hz with the
        // observer attached from the start.
        let halfHourTicks = 30 * 60 * 30
        for _ in 0..<halfHourTicks { try context.tick(deltaTime: 1.0 / 30.0) }
        check(context.events.count == 1, "one idle half hour retains only the load fact")
        check(context.events.allSatisfy { !isClockKind($0.kind) }, "clock events never enter the retained window")
        check(context.state.revision == UInt64(halfHourTicks), "revision still counts every tick")
        check(rawBatches.first?.count == 1 && rawBatches.count == 1,
            "the idle run delivered exactly the single initial load fact")
        check(rawBatches.first?.first.flatMap { if case .worldLoaded = $0.kind { true } else { false } } == true,
            "the first batch is the world-loaded boundary")

        // Phase 2: formal results after the long idle run must still be observed.
        try context.setWeather(.rain)
        check(context.events.count == 2, "weather change is retained after the long run")
        check(raw.contains { if case .weatherChanged(.rain) = $0.kind { true } else { false } },
            "weather change is observed after the long run")
        try context.completeGoal(id: "fixture.goal")
        check(context.events.contains { if case .goalCompleted("fixture.goal") = $0.kind { true } else { false } },
            "goal completion is retained after the long run")

        // Real executor failure still reaches the observer after the long run.
        try context.startActivity(id: "home.walk")
        context.installCollisionWorld(CollisionVolumeWorld(volumes: []))
        try context.tick(deltaTime: 0.1)
        check(raw.contains { if case .activityFailed("home.walk", _) = $0.kind { true } else { false } },
            "formal activity failure is observed after the long run")

        // Re-entrancy: an observer that mutates the world synchronously from the
        // delivery callback must never cause a redelivery or a duplicate sequence.
        context.installCollisionWorld(floorWorld(y: manifest.spawn.position.y - 0.5))
        var reentered = false
        context.onEventsPublished = { batch in
            rawBatches.append(batch)
            raw += batch
            if !reentered {
                reentered = true
                try! context.completeGoal(id: "fixture.reentrant")
            }
        }
        try context.setWeather(.clear)
        check(Set(raw.map(\.sequence)).count == raw.count, "cursor advances before reentrant mutation")
        check(raw.contains { if case .goalCompleted("fixture.reentrant") = $0.kind { true } else { false } },
            "reentrant fact is delivered once from its own drain")
        context.onEventsPublished = { batch in
            rawBatches.append(batch)
            raw += batch
        }

        // Phase 3: continuous real walking under per-tick observation stays inside
        // the fixed-capacity window and never fabricates a re-observation boundary.
        let walker = try WorldAgentContext(manifest: manifest, walkingSpeed: 0.5)
        walker.installCollisionWorld(floorWorld(y: manifest.spawn.position.y - 0.5))
        var walkerRaw: [WorldEvent] = []
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
        check(walkerRaw.contains { isMovementTo($0, destination) },
            "per-tick observation delivers the movement result during continuous walking")
        check(!walkerRaw.contains(where: isResync),
            "no world-restored boundary is fabricated while the observer keeps up with the cache")
        check(!walkerRaw.contains(where: isObservationGap),
            "no observation-gap notice is fabricated while the observer keeps up with the cache")
        try walker.setWeather(.rain)
        check(walkerRaw.contains { if case .weatherChanged(.rain) = $0.kind { true } else { false } },
            "a formal fact after the pinned window is still observed")
        check(walker.events.count == WorldSimulation.retainedEventCapacity,
            "window stays at fixed capacity after the post-walk formal fact")
        for _ in 0..<(5 * 60 * 30) { try walker.tick(deltaTime: 1.0 / 30.0) }
        check(walker.events.count == WorldSimulation.retainedEventCapacity,
            "post-walk idle tail never changes the pinned window")

        // Phase 4: a consumer that lags beyond the cache — the observer attaches only
        // after an unattended long walk already overflowed the window — receives an
        // explicit OBSERVATION-GAP notice instead of a silently trimmed history or a
        // fabricated world-restored "the world recovered" fact.
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
        let gapScopeID = "gap-\(UUID().uuidString)"
        var lagBatches: [[WorldEvent]] = []
        // Re-entrancy on the gap path: the observer mutates the world synchronously
        // from the first delivery. The cursor must already have advanced, so the
        // re-entrant goal lands in its own drain and the gap notice is not repeated.
        var firstBatchTrimmed: UInt64?
        var gapReentered = false
        lagging.onEventsPublished = { batch in
            lagBatches.append(batch)
            if firstBatchTrimmed == nil { firstBatchTrimmed = lagging.simulation.trimmedNewestSequence }
            if !gapReentered {
                gapReentered = true
                try! lagging.completeGoal(id: "fixture.gap-reentrant")
            }
        }
        try lagging.setWeather(.rain)
        let firstLagBatch = lagBatches.first ?? []
        check(firstLagBatch.first.flatMap(isObservationGap) == true,
            "a lagging consumer receives an explicit observation-gap notice first")
        check(!firstLagBatch.contains(where: isResync),
            "the gap notice is never a fabricated world-restored fact")
        check(!(firstLagBatch.contains { if case .worldLoaded = $0.kind { true } else { false } }),
            "the stale session marker is not replayed as if history were complete")
        let laggingDelivered = lagBatches.flatMap { $0 }
        check(laggingDelivered.contains { isMovementTo($0, lagDestination) },
            "a recent real movement result still reaches the late observer")
        check(laggingDelivered.contains { if case .weatherChanged(.rain) = $0.kind { true } else { false } },
            "facts recorded after re-attachment reach the late observer")
        check(laggingDelivered.contains { if case .goalCompleted("fixture.gap-reentrant") = $0.kind { true } else { false } },
            "the re-entrant fact is delivered from its own drain")
        check(laggingDelivered.filter(isObservationGap).count == 1,
            "the observation-gap notice is delivered exactly once across the re-entrant drain")
        check(Set(laggingDelivered.map(\.sequence)).count == laggingDelivered.count,
            "no sequence/id is reused across the re-entrant gap drain")
        let gapNotice = laggingDelivered.first(where: isObservationGap)
        check(gapNotice?.sequence == firstBatchTrimmed,
            "the notice anchors its sequence to the real eviction watermark (no reserved band)")
        check((gapNotice?.sequence ?? 1) <= lagging.state.revision,
            "the notice sequence stays inside the live mutation-watermark range, never a top-of-UInt64 reserve")
        // Resident-side mapping and id-dedupe: kinds are explicit and honest, and the
        // newest movement completion is never swallowed by the notice's identity.
        let mappedDelivered = lagBatches.flatMap { $0 }.compactMap {
            ResidentWorldObservation.event($0, worldID: manifest.worldID, scopeID: gapScopeID)
        }
        check(mappedDelivered.first?.kind == "observation_gap",
            "the resident sees an explicit observation_gap kind first, not world_restored")
        check(!mappedDelivered.contains { $0.kind == "world_restored" },
            "a cache gap never maps to a world_restored fact")
        check(!mappedDelivered.contains { $0.kind == "world_loaded" },
            "the stale load boundary never replays across a gap")
        let mappedGap = mappedDelivered.first { $0.kind == "observation_gap" }
        check(mappedGap?.id.hasPrefix("observation-gap:\(gapScopeID):\(manifest.worldID):") == true,
            "the gap notice dedupes in its own id namespace, disjoint from world:<scope>:<worldID>:<sequence>")
        check(mappedGap?.summary.contains("缺口") == true && mappedGap?.summary.contains("不代表世界已恢复或重置") == true,
            "the notice names the observation gap and explicitly denies a world recovery")
        check(mappedDelivered.contains { $0.kind == "movement_completed" && $0.summary.contains(lagDestination) },
            "the newest movement completion is mapped with its real destination")
        var residentSeen: Set<String> = []
        var residentKindsAfterDedupe: [String] = []
        for observation in mappedDelivered where residentSeen.insert(observation.id).inserted {
            residentKindsAfterDedupe.append(observation.kind)
        }
        check(residentKindsAfterDedupe.contains("movement_completed"),
            "the newest movement completion is not swallowed by resident id-dedupe")
        check(residentKindsAfterDedupe.filter { $0 == "observation_gap" }.count == 1,
            "the gap notice survives resident id-dedupe exactly once")
        check(lagging.events.count == WorldSimulation.retainedEventCapacity,
            "the lagging context stays bounded after the explicit observation gap")
        check(lagging.simulation.trimmedNewestSequence.flatMap { $0 < lagging.state.revision } == true,
            "the eviction watermark stays below the live watermark")

        // Phase 5: a late observer attaches with NO trimming and still receives the
        // initial load fact (nothing was dropped, so no resync is needed).
        let fresh = try WorldAgentContext(manifest: manifest)
        try fresh.tick(deltaTime: 1.0 / 30.0)
        var lateEvents: [WorldEvent] = []
        fresh.onEventsPublished = { lateEvents += $0 }
        try fresh.tick(deltaTime: 1.0 / 30.0)
        check(lateEvents.contains { if case .worldLoaded = $0.kind { true } else { false } },
            "late observer still receives the initial load fact when nothing was trimmed")

        // Phase 6: restore keeps the marker at the head across a bounded post-restore
        // walk and sequences keep rising above the persisted watermark.
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-retention-window-\(UUID()).json")
        let persistence = AtomicJSONWorldStatePersistence(fileURL: persistenceURL)
        try persistence.save(context.state)
        let restored = try WorldAgentContext(manifest: manifest, persistence: persistence)
        restored.installCollisionWorld(floorWorld(y: manifest.spawn.position.y - 0.5))
        check(restored.events.first.flatMap { if case .worldRestored = $0.kind { true } else { false } } == true,
            "restore session begins with the world-restored boundary")
        var restoredRaw: [WorldEvent] = []
        restored.onEventsPublished = { restoredRaw += $0 }
        guard let restoredDestination = startFarWalk(restored, in: manifest) else {
            print("FAIL: restored cabin has no far walkable waypoint")
            failures += 1
            exit(1)
        }
        let restoredTicks = try walkUntilArrived(restored, tickCap: 60 * 30)
        check(restoredTicks >= WorldSimulation.retainedEventCapacity,
            "post-restore walk moved long enough (\(restoredTicks)) to overflow the cache")
        check(restored.events.count == WorldSimulation.retainedEventCapacity,
            "post-restore walk stays within the fixed capacity")
        check(restored.events.first.flatMap { if case .worldRestored = $0.kind { true } else { false } } == true,
            "the restore marker survives post-restore capacity overflow")
        check(restored.events.last.flatMap { if case let .movementCompleted(_, ended) = $0.kind { ended == restoredDestination } else { false } } == true,
            "post-restore movement result is retained at the window tail")
        check(restoredRaw.contains { if case let .movementCompleted(_, ended) = $0.kind { ended == restoredDestination } else { false } },
            "post-restore movement result reaches the observer")
        // A GENUINE restore is still delivered and mapped as the normal world_restored
        // fact — it must not be conflated with a cache-gap notice.
        check(restoredRaw.first.flatMap { event -> Bool in
            if case .worldRestored = event.kind { return true } else { return false }
        } == true,
            "a genuine restore delivers the world-restored boundary normally")
        check(!restoredRaw.contains(where: isObservationGap),
            "an attached observer across the post-restore walk never sees a fabricated gap notice")
        let restoredScopeID = "restore-\(UUID().uuidString)"
        let mappedRestored = restoredRaw.compactMap {
            ResidentWorldObservation.event($0, worldID: manifest.worldID, scopeID: restoredScopeID)
        }
        check(mappedRestored.first?.kind == "world_restored",
            "a genuine restore maps to the normal world_restored resident fact")
        check(mappedRestored.contains { $0.kind == "movement_completed" && $0.summary.contains(restoredDestination) },
            "the post-restore movement completion still reaches the resident as a real fact")
        check(!mappedRestored.contains { $0.kind == "observation_gap" },
            "genuine restores never carry the cache-gap notice")
        check(restored.state.revision > restored.events.first!.sequence,
            "sequences rise strictly above the restore watermark")
        check(restored.simulation.trimmedNewestSequence.flatMap { $0 >= restored.events.first!.sequence } == true,
            "evictions only ever touch events above the session marker")
        try? FileManager.default.removeItem(at: persistenceURL)

        // Archive contract: schema unchanged, no retention state leaks into bytes.
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-retention-window-archive-\(UUID()).json")
        let archive = AtomicJSONWorldStatePersistence(fileURL: archiveURL)
        try archive.save(walker.state)
        let firstBytes = try Data(contentsOf: archiveURL)
        guard let loadedState = try archive.load() else {
            print("FAIL: walked state does not load from its archive")
            failures += 1
            exit(1)
        }
        try archive.save(loadedState)
        check(try Data(contentsOf: archiveURL) == firstBytes,
            "archive bytes stay stable through save/load/save after the walk")
        let afterKeys = Set(try (JSONSerialization.jsonObject(with: encoder.encode(loadedState)) as! [String: Any]).keys)
        check(afterKeys == earlyKeys, "archive schema is unchanged by the bounded window feature")
        check(!afterKeys.contains("events"), "reloaded archive still contains no event log")
        check(loadedState.revision == walker.state.revision, "archived revision matches the walked revision")
        try? FileManager.default.removeItem(at: archiveURL)

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident window checks, \(failures) failures; walk ticks \(walkerTicks)")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-world-retention-window-\(UUID())")
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
    contextSource.path, sources.appendingPathComponent("ResidentWorldObservation.swift").path,
    program.path, "-o", executable.path] + objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
