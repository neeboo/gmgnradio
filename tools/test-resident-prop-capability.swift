// Hostless behavioral checks for the coffee prop capability: usage receipts,
// persistence, stop/move/withdraw and restore behavior through the real
// WorldAgentContext, placement service and tool bridge. No app, no host.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let harness = #"""
import Foundation
import WorldRuntime

struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: Data
}
struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String
    let resultJSON: Data
    let isError: Bool
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}
func payload(_ result: RealtimeDJToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] ?? [:]
}

private final class ReloadablePersistence: WorldStatePersisting, @unchecked Sendable {
    var latestState: WorldState?
    func save(_ state: WorldState) throws { latestState = state }
    func load() throws -> WorldState? { latestState }
}

private struct SaveFailure: Error {}

/// Fails exactly the next save, then records normally: models a full disk.
private final class FlakyPersistence: WorldStatePersisting, @unchecked Sendable {
    var latestState: WorldState?
    var failNextSave = false
    func save(_ state: WorldState) throws {
        if failNextSave { failNextSave = false; throw SaveFailure() }
        latestState = state
    }
    func load() throws -> WorldState? { latestState }
}

private let coffeeObjectID = "wish-prop-ebfc07be"
private let coffeeActivityID = "coffee.brew@wish-prop-ebfc07be"

private let machine = WorldGeneratedProp(
    objectID: coffeeObjectID, sourceWishID: "wish-ebfc07be", assetID: "asset-espresso",
    displayName: "E2E-0907 咖啡机",
    size: WorldVector3(x: 0.2915, y: 0.35, z: 0.47193), sourceHeight: 2)

@MainActor
private func makeManifest(coffeeNearZ: Float = 2.8) -> WorldManifest {
    let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
    let unit = WorldVector3(x: 1, y: 1, z: 1)
    func transform(_ x: Float, _ y: Float, _ z: Float) -> WorldTransform {
        WorldTransform(position: WorldVector3(x: x, y: y, z: z), rotation: identity, scale: unit)
    }
    let phases = LifeActivityPhase.allCases.map { ActivityPhaseContract(phase: $0) }
    return WorldManifest(
        schemaVersion: 1, packageID: "capability-package", packageVersion: "1.0.0",
        worldID: "capability-room", displayName: "Capability Room",
        calibration: WorldCalibration(
            visualToGameplay: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], metersPerUnit: 1),
        spawn: transform(0, 0, 0),
        collisionVolumes: [
            WorldCollisionVolume(id: "ground", center: WorldVector3(x: 2, y: -0.5, z: 0),
                halfExtents: WorldVector3(x: 5, y: 0.5, z: 5), rotation: identity, isBlocking: true),
        ],
        waypoints: [
            WorldWaypoint(id: "spawn", position: transform(0, 0, 0).position, arrivalRadius: 0.1, enabled: true),
            WorldWaypoint(id: "chair", position: transform(2, 0, 0).position, arrivalRadius: 0.1, enabled: true),
            WorldWaypoint(id: "mid", position: transform(0, 0, 2.8).position, arrivalRadius: 0.1, enabled: true),
            WorldWaypoint(id: "coffee-near", position: transform(2, 0, coffeeNearZ).position, arrivalRadius: 0.1, enabled: true),
        ],
        routes: [
            WorldRoute(id: "chair-link", waypointIDs: ["spawn", "chair"], bidirectional: true, enabled: true),
            WorldRoute(id: "coffee-link", waypointIDs: ["spawn", "mid", "coffee-near"], bidirectional: true, enabled: true),
        ],
        activities: [
            WorldActivityAnchor(id: "sit-chair", action: "sit", entryWaypointID: "chair",
                transform: transform(2, 0, 0), motionID: nil, propIDs: [], interruptible: true),
        ],
        activityDefinitions: [
            LifeActivityDefinition(id: "sit-chair", activity: .sit(anchorID: "sit-chair"),
                phases: phases, interruptible: true, cooldownSeconds: 0),
        ],
        cameras: [],
        capabilities: [WorldCapability("navigation"), .activity("sit-chair")],
        resources: [])
}

@MainActor
private func makeContext(_ persistence: (any WorldStatePersisting)? = nil) throws -> WorldAgentContext {
    try WorldAgentContext(manifest: makeManifest(), startedAt: Date(timeIntervalSince1970: 1_000),
        persistence: persistence, walkingSpeed: 4)
}

@MainActor
private func bindPlacedMachine(in context: WorldAgentContext,
                               service: ResidentPropPlacementService? = nil) throws {
    if let service {
        try service.commit(.register(machine), expectedLayoutRevision: 0, requestID: "claim")
        try service.commit(.place(objectID: coffeeObjectID,
            placement: WorldPropPlacement(surfaceID: "resident.display_table",
                position: WorldVector3(x: 2, y: 0.52, z: 2), yaw: 0)),
            expectedLayoutRevision: 1, requestID: "place")
    } else {
        try context.commitPropLayout(.register(machine), expectedLayoutRevision: 0, requestID: "claim") { _ in }
        try context.commitPropLayout(.place(objectID: coffeeObjectID,
            placement: WorldPropPlacement(surfaceID: "resident.display_table",
                position: WorldVector3(x: 2, y: 0.52, z: 2), yaw: 0)),
            expectedLayoutRevision: 1, requestID: "place") { _ in }
    }
}

@MainActor
private func usage(_ context: WorldAgentContext) -> WorldPropUsageState? {
    context.state.objectStates[coffeeObjectID]?.propUsage
}

@MainActor
private func advanceToEnter(_ context: WorldAgentContext) throws {
    for _ in 0..<24 {
        guard context.snapshot.activeActivity?.phase != .enter else { return }
        try context.tick(deltaTime: 0.5)
    }
}

@MainActor
func usageStatus(_ result: RealtimeDJToolResult) -> String? {
    guard let objects = payload(result)["objects"] as? [[String: Any]],
          let object = objects.first(where: { ($0["object_id"] as? String) == coffeeObjectID }),
          let usage = object["usage"] as? [String: Any] else { return nil }
    return usage["status"] as? String
}

@main struct Tests {
    @MainActor static func main() async throws {
        // 1. Binding requires a human round; the bound readback is exact.
        do {
            let context = try makeContext()
            try bindPlacedMachine(in: context)
            let service = ResidentPropPlacementService(context: context, surfaces: [
                ResidentPropSupportSurface(id: "resident.display_table",
                    center: WorldVector3(x: 2, y: 0.52, z: 2),
                    halfExtents: WorldVector3(x: 0.5, y: 0.02, z: 0.5), yaw: 0,
                    excludedCollisionID: nil),
            ], validateEnvironment: { _, _ in })
            let arguments = try JSONSerialization.data(withJSONObject: [
                "object_id": coffeeObjectID, "capability": "coffee.brew", "layout_revision": 2])
            let background = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { true })
            let backgroundTool = background.tools.first { $0.name == "enable_prop_capability" }!
            let denied = await backgroundTool.handle("bind-denied", arguments)
            check(denied.isError && payload(denied)["code"] as? String == "human_guidance_required",
                "background round cannot enable a capability")
            let bound = ResidentPropToolBridge(service: service, allowsMutation: true, isCurrent: { true })
            let bind = await bound.tools.first { $0.name == "enable_prop_capability" }!.handle("bind-1", arguments)
            check(!bind.isError && payload(bind)["interaction_status"] as? String == "capability_bound_use_only",
                "human round binds coffee.brew and reports capability_bound_use_only")
            let read = await bound.tools.first { $0.name == "read_owned_props" }!.handle(
                "read-1", Data("{}".utf8))
            check(!read.isError, "read_owned_props succeeds")
            check(usageStatus(read) == nil, "no usage exists before the first real run")

            // 2. A run is running at start and completed only through the
            //    matching receipt; foreign receipts change nothing.
            try context.startActivity(id: coffeeActivityID)
            check(usage(context)?.status == .running, "starting the run records running usage")
            let drivingRequestID = context.currentActivityRequestID
            check(usage(context)?.activityRequestID == drivingRequestID,
                "running usage is anchored to the actual executor request")
            try advanceToEnter(context)
            for _ in 0..<8 { try context.tick(deltaTime: 1) }
            check(context.snapshot.activeActivity?.phase == .enter,
                "enter never completes by elapsed time")
            let beforeForeign = usage(context)
            try context.completeActivityPlayback(requestID: "foreign", phase: .enter)
            check(context.snapshot.activeActivity?.phase == .enter && usage(context) == beforeForeign,
                "a foreign receipt neither advances nor completes the usage")
            try context.completeActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
            try context.tick(deltaTime: 0.05)
            try context.tick(deltaTime: 0.05)
            check(context.snapshot.activeActivity == nil, "matched receipt finishes the run")
            check(usage(context)?.status == .completed, "completion is persisted as usage")
            check(usage(context)?.activityRequestID == drivingRequestID,
                "completion carries the driving request id")
            let readback = await bound.tools.first { $0.name == "read_owned_props" }!.handle(
                "read-2", Data("{}".utf8))
            check(usageStatus(readback) == "completed", "read_owned_props reads the completed usage back")

            // 3. Stopping records stopped with the stop reason; a missing
            //    motion records failed, never completed.
            try context.tick(deltaTime: 46)
            try context.startActivity(id: coffeeActivityID)
            try context.stopActivity(reason: "用户取消")
            check(usage(context)?.status == .stopped && usage(context)?.reason == "用户取消",
                "stopping records stopped with the reason")
            // A model-supplied stop reason can be arbitrarily long: the
            // stopped state must still land (bounded reason), never stay running.
            try context.tick(deltaTime: 46)
            try context.startActivity(id: coffeeActivityID)
            try context.stopActivity(reason: String(repeating: "停", count: 400))
            check(usage(context)?.status == .stopped,
                "an over-long stop reason must still transition the usage off running")
            check((usage(context)?.reason?.count ?? 0) <= 256,
                "the persisted stop reason is bounded to 256 characters")

            try context.tick(deltaTime: 46)
            try context.startActivity(id: coffeeActivityID)
            try advanceToEnter(context)
            try context.failActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
            check(context.snapshot.activeActivity == nil, "missing motion ends the run")
            check(usage(context)?.status == .failed && usage(context)?.reason == "missingMotion",
                "playback failure records failed usage")
        }

        // 4. Withdrawing mid-run stops the usage, and the orphaned playback can
        //    never resurrect it into a fake completion.
        do {
            let persistence = ReloadablePersistence()
            let context = try makeContext(persistence)
            try bindPlacedMachine(in: context)
            try context.commitPropLayout(
                .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "bind") { _ in }
            try context.startActivity(id: coffeeActivityID)
            try advanceToEnter(context)
            try context.commitPropLayout(.withdraw(objectID: coffeeObjectID),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "withdraw") { _ in }
            check(usage(context)?.status == .stopped, "withdraw stops the running usage")
            check(!context.snapshot.activities.contains { $0.id == coffeeActivityID },
                "withdraw removes the discoverable activity")
            check(context.snapshot.activeActivity == nil,
                "withdraw cancels the in-flight orphan run immediately")
            check(persistence.latestState?.activeActivity == nil,
                "the persisted commit point no longer carries the cancelled run")
            let stopped = usage(context)
            try context.completeActivityPlayback(requestID: "late", phase: .enter)
            try context.tick(deltaTime: 0.05)
            check(context.snapshot.activeActivity == nil, "late receipts cannot restart a cancelled run")
            check(usage(context) == stopped, "late receipts cannot resurrect the stopped usage")

            // Re-placing does not fake a fresh completion either.
            try context.commitPropLayout(
                .place(objectID: coffeeObjectID,
                    placement: WorldPropPlacement(surfaceID: "resident.display_table",
                        position: WorldVector3(x: 2, y: 0.52, z: 2), yaw: 0)),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "replace") { _ in }
            check(usage(context) == stopped, "re-placing keeps the stopped usage")
        }

        // 5. Placement changes end the in-flight run precisely: moving to
        //    another still-reachable spot and rotating in place both cancel the
        //    old run (whose path and facing belong to the old placement), and
        //    the old run's late receipt can never flip the stopped usage into a
        //    completion. Replaying an identical recorded request and layout
        //    changes to unrelated objects leave a live run untouched.
        do {
            let persistence = FlakyPersistence()
            let context = try makeContext(persistence)
            try bindPlacedMachine(in: context)
            try context.commitPropLayout(
                .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "bind") { _ in }
            func place(_ x: Float, _ z: Float, _ yaw: Float, _ requestID: String) throws {
                try context.commitPropLayout(
                    .place(objectID: coffeeObjectID,
                        placement: WorldPropPlacement(surfaceID: "resident.display_table",
                            position: WorldVector3(x: x, y: 0.52, z: z), yaw: yaw)),
                    expectedLayoutRevision: context.state.layoutRevision, requestID: requestID) { _ in }
            }
            func startRun() throws -> String {
                try context.startActivity(id: coffeeActivityID)
                try advanceToEnter(context)
                guard let requestID = context.currentActivityRequestID else {
                    fatalError("startRun precondition failed: no executor request")
                }
                return requestID
            }

            // (a) move to another still-reachable position
            let requestA = try startRun()
            try place(2.4, 2, 0, "move")
            check(usage(context)?.status == .stopped && usage(context)?.reason == "物件被移动或收回，使用中止",
                "moving a reachable prop stops the usage with the layout reason")
            check(context.snapshot.activeActivity == nil && context.currentActivityRequestID == nil,
                "the in-flight run is cancelled even though the machine is still discoverable")
            try context.completeActivityPlayback(requestID: requestA, phase: .enter)
            try context.tick(deltaTime: 0.05)
            check(context.snapshot.activeActivity == nil && usage(context)?.status == .stopped,
                "the old run's late receipt cannot complete a moved machine")
            // Persistence transaction: the saved commit point excludes the run,
            // and a restart from that snapshot does not resurrect it.
            check(persistence.latestState?.activeActivity == nil,
                "the persisted commit point no longer carries the cancelled run")
            let rebuilt = try makeContext(persistence)
            check(rebuilt.snapshot.activeActivity == nil,
                "a restart from the persisted snapshot does not resurrect the stopped run")
            check(rebuilt.state.objectStates[coffeeObjectID]?.propUsage?.status == .stopped
                && rebuilt.state.objectStates[coffeeObjectID]?.propCapability != nil,
                "the rebuilt world keeps the stopped usage and the intact binding")

            // (b) rotate in place only
            try context.tick(deltaTime: 46)
            let requestB = try startRun()
            try place(2.4, 2, 0.7, "rotate")
            check(usage(context)?.status == .stopped, "rotating in place stops the usage")
            check(context.snapshot.activeActivity == nil && context.currentActivityRequestID == nil,
                "rotating in place also cancels the in-flight run")
            try context.completeActivityPlayback(requestID: requestB, phase: .enter)
            try context.tick(deltaTime: 0.05)
            check(context.snapshot.activeActivity == nil && usage(context)?.status == .stopped,
                "the rotated run's late receipt cannot complete either")

            // (c) replaying an identical recorded request is a pure no-op
            try context.tick(deltaTime: 46)
            let requestC = try startRun()
            try place(2.4, 2, 0.7, "rotate")
            check(context.snapshot.activeActivity?.id == coffeeActivityID
                && context.currentActivityRequestID == requestC
                && usage(context)?.status == .running,
                "replaying the recorded rotate request neither cancels nor stops the live run")

            // (d) another object's layout change does not touch this run
            let second = WorldGeneratedProp(objectID: "wish-prop-second", sourceWishID: "wish-second",
                assetID: "asset-second", displayName: "第二台",
                size: WorldVector3(x: 0.29, y: 0.35, z: 0.47), sourceHeight: 2)
            try context.commitPropLayout(.register(second),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "claim-second") { _ in }
            try context.commitPropLayout(
                .place(objectID: "wish-prop-second",
                    placement: WorldPropPlacement(surfaceID: "resident.display_table",
                        position: WorldVector3(x: 2.3, y: 0.52, z: 2.3), yaw: 0)),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "place-second") { _ in }
            check(context.snapshot.activeActivity?.id == coffeeActivityID
                && context.currentActivityRequestID == requestC
                && usage(context)?.status == .running,
                "an unrelated object's layout change leaves the coffee run running")

            // (e) a failed save must not commit memory: the transaction covers
            //     placement, usage, the active run and the executor, and the
            //     old run keeps receiving its completion receipts afterwards.
            try context.tick(deltaTime: 46)
            let requestE = try startRun()
            let beforeMove = context.state
            let inventoryBefore = context.snapshot.activities.map(\.id)
            persistence.failNextSave = true
            var moveFailed = false
            do { try place(2, 2, 0, "failed-move") } catch { moveFailed = true }
            check(moveFailed, "a failing persistence surfaces the commit failure")
            check(context.state == beforeMove && context.state.layoutRevision == beforeMove.layoutRevision,
                "a failed move save leaves world state and layout revision untouched")
            check(context.snapshot.activeActivity?.id == coffeeActivityID
                && context.snapshot.activeActivity?.phase == .enter
                && context.currentActivityRequestID == requestE,
                "a failed move save keeps the run alive at its phase")
            check(usage(context)?.status == .running,
                "a failed move save leaves the usage running")
            check(context.snapshot.activities.map(\.id) == inventoryBefore,
                "a failed move save leaves the activity inventory untouched")
            try context.completeActivityPlayback(requestID: requestE, phase: .enter)
            try context.tick(deltaTime: 0.05)
            try context.tick(deltaTime: 0.05)
            check(context.snapshot.activeActivity == nil && usage(context)?.status == .completed,
                "the old run still completes normally after the failed save")

            // (f) same transaction guarantees for a failing withdraw
            try context.tick(deltaTime: 46)
            let requestF = try startRun()
            let beforeWithdraw = context.state
            persistence.failNextSave = true
            var withdrawFailed = false
            do {
                try context.commitPropLayout(.withdraw(objectID: coffeeObjectID),
                    expectedLayoutRevision: context.state.layoutRevision, requestID: "failed-withdraw") { _ in }
            } catch { withdrawFailed = true }
            check(withdrawFailed, "a failing persistence surfaces the withdraw failure")
            check(context.state == beforeWithdraw && context.state.layoutRevision == beforeWithdraw.layoutRevision,
                "a failed withdraw save leaves world state and layout revision untouched")
            check(context.snapshot.activeActivity?.id == coffeeActivityID
                && context.snapshot.activeActivity?.phase == .enter
                && context.currentActivityRequestID == requestF,
                "a failed withdraw save keeps the run alive at its phase")
            check(usage(context)?.status == .running,
                "a failed withdraw save leaves the usage running")
            try context.completeActivityPlayback(requestID: requestF, phase: .enter)
            try context.tick(deltaTime: 0.05)
            try context.tick(deltaTime: 0.05)
            check(context.snapshot.activeActivity == nil && usage(context)?.status == .completed,
                "the withdrawn attempt's run still completes normally after the failed save")
        }

        // 6. Usage state survives a restart, and a restored run stays
        //    receipt-gated instead of claiming completion.
        do {
            let persistence = ReloadablePersistence()
            let context = try makeContext(persistence)
            try bindPlacedMachine(in: context)
            try context.commitPropLayout(
                .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "bind") { _ in }
            try context.startActivity(id: coffeeActivityID)
            try advanceToEnter(context)
            check(persistence.latestState != nil, "running usage is checkpointed")

            let reloaded = try makeContext(persistence)
            check(reloaded.state.objectStates[coffeeObjectID]?.propUsage?.status == .running,
                "restart reads the running usage back")
            check(reloaded.snapshot.activeActivity?.id == coffeeActivityID,
                "the interrupted run is restored")
            check(reloaded.currentActivityRequestID != nil, "restored run keeps an executor request")
            try reloaded.tick(deltaTime: 0.05)
            check(reloaded.snapshot.activeActivity != nil && reloaded.usageStatusStillRunning(),
                "restored run remains receipt-gated and running")

            // A restore whose operation spot no longer resolves must end the
            // phantom run as stopped, never leave it running or claim completion.
            // All four conditions the cleanup must survive are pinned here:
            // capability still bound, machine moved where no waypoint within
            // the 2.5m discovery radius stands (spawn is 2.83m away), usage
            // persisted as running, activity persisted as interrupted. The
            // stale activity is deliberately absent from propActivities, so
            // this exercises the persisted-capability mapping, not discovery.
            var corrupted = persistence.latestState!
            check(corrupted.objectStates[coffeeObjectID]?.propCapability != nil,
                "fixture precondition: the capability binding survives the corruption")
            check(corrupted.objectStates[coffeeObjectID]?.propUsage?.status == .running,
                "fixture precondition: the persisted usage was running")
            corrupted.objectStates[coffeeObjectID]!.transform = WorldTransform(
                position: WorldVector3(x: -2, y: 0.52, z: -2),
                rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
                scale: corrupted.objectStates[coffeeObjectID]!.transform.scale)
            corrupted.activeActivity = WorldActivityState(activityID: coffeeActivityID,
                status: .interrupted, startedAt: corrupted.worldTime)
            persistence.latestState = corrupted
            let orphaned = try makeContext(persistence)
            check(orphaned.snapshot.activeActivity == nil, "phantom run is cancelled at restore")
            check(orphaned.state.objectStates[coffeeObjectID]?.propCapability != nil,
                "the restore never strips the capability binding")
            check(orphaned.state.objectStates[coffeeObjectID]?.propUsage?.status == .stopped,
                "unreachable restore marks the usage stopped")
            check(orphaned.state.objectStates[coffeeObjectID]?.propUsage?.reason == "重启后无法到达物件操作位点",
                "the stop reason names the restore failure")
        }

        // 7. The dispatcher availability gate blocks the run before any usage exists.
        do {
            let context = try makeContext()
            try bindPlacedMachine(in: context)
            try context.commitPropLayout(
                .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "bind") { _ in }
            let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
                availableActivity: { $0 != coffeeActivityID })
            let result = await dispatcher.handle(RealtimeDJToolCall(id: "gate", name: "start_activity",
                argumentsJSON: Data(#"{"activity_id":"coffee.brew@wish-prop-ebfc07be"}"#.utf8)))
            check(result.isError && payload(result)["code"] as? String == "activity_unavailable",
                "incompatible avatar keeps the activity gated")
            check(context.snapshot.activeActivity == nil && usage(context) == nil,
                "a gated run never creates usage state")
        }


        // 8. When the anchor waypoint lies outside arm's reach, discovery
        //    appends a collision-verified final approach and the resident
        //    physically walks onto that stand point before pressing.
        do {
            let context = try WorldAgentContext(
                manifest: makeManifest(coffeeNearZ: 3.2),
                startedAt: Date(timeIntervalSince1970: 1_000), walkingSpeed: 4)
            try bindPlacedMachine(in: context)
            try context.commitPropLayout(
                .enableCapability(objectID: coffeeObjectID, templateID: "coffee.brew"),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "bind") { _ in }
            check(context.snapshot.activities.contains {
                $0.id == coffeeActivityID && $0.entryPlaceID == "coffee-near"
            }, "the route still anchors at the nearest waypoint (edge 0.965m > 0.6m reach)")

            try context.startActivity(id: coffeeActivityID)
            try advanceToEnter(context)
            check(context.snapshot.agentTransform.position == WorldVector3(x: 2, y: 0, z: 2.8),
                "the resident stands on the collision-verified final approach (first in-window step, edge 0.564m), not the waypoint at 3.2")
            check(abs(context.snapshot.agentTransform.rotation.y - sin(.pi / 2)) < 0.001,
                "the resident faces the machine from the stand point")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident prop capability checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor
private extension WorldAgentContext {
    func usageStatusStillRunning() -> Bool {
        state.objectStates[coffeeObjectID]?.propUsage?.status == .running
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-capability-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("prop-capability")
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let modules = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/Modules")
let objects = try FileManager.default.contentsOfDirectory(
    at: root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/WorldRuntime.build"),
    includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-I", modules.path,
    sources.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolContract.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolDispatcher.swift").path,
    sources.appendingPathComponent("Agent/ResidentWorldToolSession.swift").path,
    sources.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sources.appendingPathComponent("Agent/ResidentPropToolBridge.swift").path,
    program.path, "-o", executable.path] + objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
