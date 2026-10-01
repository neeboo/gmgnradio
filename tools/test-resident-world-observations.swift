import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent")
let contextSource = sources.appendingPathComponent("WorldAgentContext.swift")
let observationSource = try String(contentsOf: sources.appendingPathComponent("ResidentWorldObservation.swift"), encoding: .utf8)
guard observationSource.contains("case let .movementCompleted("),
      observationSource.contains("case let .movementFailed("),
      observationSource.contains("case let .activityFailed(") else {
    print("FAIL: navigation completion and real playback failure are not mapped to resident facts"); exit(1)
}
let app = try String(contentsOf: sources.deletingLastPathComponent().appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
guard let wireStart = app.range(of: "let observationScopeID = UUID().uuidString"),
      let wireEnd = app.range(of: "context.onSnapshotChanged =", range: wireStart.upperBound..<app.endIndex) else {
    print("FAIL: application does not wire formal world observations")
    exit(1)
}
let wiring = String(app[wireStart.lowerBound..<wireEnd.lowerBound])
guard try String(contentsOf: contextSource, encoding: .utf8).contains("onEventsPublished") else {
    print("FAIL: real world events are not delivered to the resident loop")
    exit(1)
}
let harness = #"""
import Foundation
import WorldRuntime
@MainActor var checks = 0, failures = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
@MainActor final class AppFixture {
    struct Stage { var selectedWorldID: String }
    var livingWorldContext: WorldAgentContext?
    var spatialStage = Stage(selectedWorldID: "")
    let loop = ResidentAgentLoop(run: { _ in fatalError("observation must not invoke model") })
    func ensureResidentLoop() -> ResidentAgentLoop { loop }
    func attach(_ context: WorldAgentContext) {
        livingWorldContext = context
        spatialStage.selectedWorldID = context.manifest.worldID
        \#(wiring)
    }
}
@main struct Tests {
    @MainActor static func main() throws {
        let path = "apps/macos/Resources/Worlds/marble-living-cabin/world.json"
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let context = try WorldAgentContext(manifest: manifest)
        let floor = CollisionVolumeWorld(volumes: [WorldCollisionVolume(
            id: "fixture.floor", center: .init(x: 0, y: manifest.spawn.position.y - 0.5, z: 0),
            halfExtents: .init(x: 50, y: 0.5, z: 50), rotation: .init(x: 0, y: 0, z: 0, w: 1), isBlocking: true
        )])
        context.installCollisionWorld(floor)
        var events: [WorldEvent] = []
        var batches: [[WorldEvent]] = []
        context.onEventsPublished = { batch in events += batch; batches.append(batch) }
        try context.setWeather(.rain)
        check(events.contains { if case .weatherChanged(.rain) = $0.kind { true } else { false } }, "actual weather mutation is observable")
        check(events.contains { if case .worldLoaded = $0.kind { true } else { false } }, "initial load is observed once")
        let count = events.count
        for _ in 0..<100 { try context.tick(deltaTime: 1.0 / 30) }
        check(events.count == count, "time ticks do not produce semantic observation batches")
        var reentered = false
        context.onEventsPublished = { batch in
            events += batch
            if !reentered { reentered = true; try! context.completeGoal(id: "fixture.goal") }
        }
        try context.setWeather(.clear)
        check(Set(events.map(\.sequence)).count == events.count, "cursor advances before reentrant callback")
        check(events.contains { if case .goalCompleted("fixture.goal") = $0.kind { true } else { false } }, "goal fact delivered from reentrant publication")
        context.onEventsPublished = { events += $0; batches.append($0) }
        try context.startActivity(id: "home.idle")
        try context.startActivity(id: "home.walk")
        let replacement = batches.last!
        check(replacement.count == 2, "replacement preserves cancellation and start in one batch")
        check(replacement.contains { if case .activityCancelled("home.idle", _) = $0.kind { true } else { false } }, "old activity cancellation remains a distinct fact")
        check(replacement.contains { if case .activityStarted("home.walk") = $0.kind { true } else { false } }, "new activity start remains a distinct fact")
        try context.stopActivity(reason: "fixture.user.stop")
        let mapped = events.compactMap { ResidentWorldObservation.event($0, worldID: manifest.worldID, scopeID: "fixture") }
        check(mapped.contains { $0.kind == "activity_cancelled" && $0.summary.contains("fixture.user.stop") }, "actual cancellation reason reaches model context")
        let completed = WorldEvent(sequence: 999, revision: 999, worldTime: Date(), kind: .activityCompleted(activityID: "home.walk"))
        check(ResidentWorldObservation.event(completed, worldID: manifest.worldID, scopeID: "fixture")?.kind == "activity_completed", "completion is not conflated with cancellation")
        let failure = WorldEvent(sequence: 1000, revision: 1000, worldTime: Date(), kind: .activityCancelled(activityID: "home.walk", reason: "execution_failed:blocked"))
        check(ResidentWorldObservation.event(failure, worldID: manifest.worldID, scopeID: "fixture")?.kind == "activity_cancelled", "caller supplied reason cannot forge a formal failure type")
        check(ResidentWorldObservation.event(failure, worldID: manifest.worldID, scopeID: "fixture")?.summary.contains("execution_failed:blocked") == true, "cancellation reason is preserved as data")
        let movementDone = WorldEvent(sequence: 1010, revision: 1010, worldTime: Date(),
            kind: .movementCompleted(requestID: "walk-instance", destinationID: "wp.window"))
        let movementDoneObservation = ResidentWorldObservation.event(movementDone, worldID: manifest.worldID, scopeID: "fixture")
        check(movementDoneObservation?.kind == "movement_completed", "real route completion has its own fact")
        check(movementDoneObservation?.summary.contains("walk-instance") == true && movementDoneObservation?.summary.contains("wp.window") == true, "movement completion retains request and destination")
        let movementFailed = WorldEvent(sequence: 1011, revision: 1011, worldTime: Date(),
            kind: .movementFailed(requestID: "walk-instance", destinationID: "wp.window", reason: "blocked"))
        let movementFailureObservation = ResidentWorldObservation.event(movementFailed, worldID: manifest.worldID, scopeID: "fixture")
        check(movementFailureObservation?.kind == "movement_failed" && movementFailureObservation?.summary.contains("blocked") == true, "blocked route reaches resident without inventing arrival")
        let playbackFailed = WorldEvent(sequence: 1012, revision: 1012, worldTime: Date(),
            kind: .activityFailed(activityID: "performance.backflip", reason: "missingMotion"))
        let playbackFailureObservation = ResidentWorldObservation.event(playbackFailed, worldID: manifest.worldID, scopeID: "fixture")
        check(playbackFailureObservation?.kind == "activity_failed" && playbackFailureObservation?.summary.contains("missingMotion") == true, "playback failure is distinct from user cancellation")
        let first = ResidentWorldObservation.event(completed, worldID: manifest.worldID, scopeID: "first")
        let second = ResidentWorldObservation.event(completed, worldID: manifest.worldID, scopeID: "second")
        check(first?.id != second?.id, "reloaded same world uses separate event identity")
        check(ResidentWorldObservation.event(WorldEvent(sequence: 1001, revision: 1001, worldTime: Date(), kind: .timeAdvanced(duration: 1)), worldID: manifest.worldID, scopeID: "fixture") == nil, "mapper excludes frame noise")
        let layoutEvent = WorldEvent(sequence: 1002, revision: 1002, worldTime: Date(), kind: .propLayoutChanged(objectID: "coffee", layoutRevision: 7))
        let layoutObservation = ResidentWorldObservation.event(layoutEvent, worldID: manifest.worldID, scopeID: "fixture")
        check(layoutObservation?.kind == "prop_layout_changed", "committed prop layout wakes observation")
        check(layoutObservation?.summary.contains("coffee") == true && layoutObservation?.summary.contains("7") == true, "layout observation retains object and revision without inventing an action")
        let failedContext = try WorldAgentContext(manifest: manifest)
        var failureEvents: [WorldEvent] = []
        failedContext.onEventsPublished = { failureEvents += $0 }
        failedContext.installCollisionWorld(floor)
        try failedContext.startActivity(id: "home.walk")
        failedContext.installCollisionWorld(CollisionVolumeWorld(volumes: []))
        try failedContext.tick(deltaTime: 0.1)
        check(failedContext.state.activeActivity == nil && failedContext.currentActivityRequestID == nil, "blocked running activity ends in both state and executor")
        check(failureEvents.contains { if case let .activityFailed("home.walk", reason) = $0.kind { reason.contains("blocked") } else { false } }, "real executor failure preserves blocked reason as a failure fact")
        let rejectedContext = try WorldAgentContext(manifest: manifest)
        rejectedContext.installCollisionWorld(CollisionVolumeWorld(volumes: []))
        try rejectedContext.startActivity(id: "home.idle")
        let previousRequest = rejectedContext.currentActivityRequestID
        do { try rejectedContext.startActivity(id: "home.walk"); check(false, "missing floor rejects approach") }
        catch { check(true, "missing floor rejects approach") }
        check(rejectedContext.currentActivityRequestID == previousRequest, "rejected replacement preserves existing executor")
        check(rejectedContext.state.activeActivity?.activityID == "home.idle", "rejected replacement preserves world activity")
        var authored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        var definitions = authored["activityDefinitions"] as! [[String: Any]]
        for index in definitions.indices {
            var phases = definitions[index]["phases"] as! [[String: Any]]
            for phase in phases.indices { phases[phase]["durationSeconds"] = 0.01 }
            definitions[index]["phases"] = phases
        }
        authored["activityDefinitions"] = definitions
        let finiteManifest = try JSONDecoder().decode(WorldManifest.self, from: JSONSerialization.data(withJSONObject: authored))
        let finite = try WorldAgentContext(manifest: finiteManifest)
        var finiteEvents: [WorldEvent] = []
        finite.onEventsPublished = { finiteEvents += $0 }
        try finite.startActivity(id: "home.idle")
        for _ in 0..<3 { try finite.tick(deltaTime: 0.02) }
        check(finiteEvents.contains { if case .activityCompleted("home.idle") = $0.kind { true } else { false } }, "authored finite activity publishes actual completion")
        check(finite.state.activeActivity == nil, "completion event agrees with world state")
        check(finiteEvents.allSatisfy { if case .activityCancelled = $0.kind { false } else { true } }, "finite completion is never reported as cancellation")
        let unobserved = try WorldAgentContext(manifest: manifest)
        try unobserved.tick(deltaTime: 1)
        var lateEvents: [WorldEvent] = []
        unobserved.onEventsPublished = { lateEvents += $0 }
        try unobserved.tick(deltaTime: 1)
        check(lateEvents.contains { if case .worldLoaded = $0.kind { true } else { false } }, "late observer still receives initial load fact")
        let longReason = String(repeating: "中文原因🫶🏽", count: 1000)
        let longEvent = WorldEvent(sequence: 1002, revision: 1002, worldTime: Date(), kind: .activityCancelled(activityID: "home.walk", reason: longReason))
        let bounded = ResidentWorldObservation.event(longEvent, worldID: manifest.worldID, scopeID: "fixture")!
        check(bounded.summary.count <= 2000, "untrusted reason has a bounded summary")
        check(String(data: Data(bounded.summary.utf8), encoding: .utf8) == bounded.summary && bounded.summary.contains("中文原因🫶🏽"), "Chinese and composed emoji remain valid UTF8")
        let wired = AppFixture()
        let oldContext = try WorldAgentContext(manifest: manifest)
        wired.attach(oldContext)
        try oldContext.setWeather(.rain)
        check(wired.loop.snapshot.recentEvents.contains { $0.kind == "weather_changed" }, "production App callback delivers real world events")
        let oldIDs = Set(wired.loop.snapshot.recentEvents.map(\.id))
        let newContext = try WorldAgentContext(manifest: manifest)
        wired.attach(newContext)
        let beforeOld = wired.loop.snapshot.recentEvents.count
        try oldContext.setWeather(.clear)
        check(wired.loop.snapshot.recentEvents.count == beforeOld, "replaced context cannot pollute resident observations")
        try newContext.setWeather(.rain)
        check(wired.loop.snapshot.recentEvents.count > beforeOld && !oldIDs.contains(wired.loop.snapshot.recentEvents.last!.id), "same world reload creates distinct event identities")
        wired.spatialStage.selectedWorldID = "another-world"
        let beforeSelection = wired.loop.snapshot.recentEvents.count
        try newContext.setWeather(.clear)
        check(wired.loop.snapshot.recentEvents.count == beforeSelection, "unselected world cannot pollute observations")
        check(!wired.loop.snapshot.isRunning, "observations alone never initiate a model request")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) world observation checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-world-observations-\(UUID())")
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
