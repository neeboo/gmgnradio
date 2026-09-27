// Hostless regressions against the production world context. No app, model, or UI.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = #"""
import Foundation
import WorldRuntime

struct Floor: WorldCollisionQuerying {
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
}
final class ClosingFloor: WorldCollisionQuerying, @unchecked Sendable {
    var closed = false
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { !closed }
}
final class DoorFloor: WorldCollisionQuerying, @unchecked Sendable {
    var closed = false
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        !closed || !(position.x > 0.8 && position.x < 1.2 && abs(position.z) < 0.3)
    }
}
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    if !value { failures += 1; print("FAIL: \(label)") }
}
@main struct Tests {
    @MainActor static func main() throws {
        let worldURL = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: worldURL)) as! [String: Any]
        let ids = ["wp.spawn", "wp.center", "wp.jukebox", "wish_machine.pickup"]
        json["waypoints"] = ids.enumerated().map { i, id in
            ["id": id, "position": ["x": Double(i % 2) * 2, "y": 0, "z": Double(i / 2) * 2], "arrivalRadius": 0.1, "enabled": true] as [String: Any]
        }
        var spawn = json["spawn"] as! [String: Any]
        spawn["position"] = ["x": 0, "y": 0, "z": 0]
        json["spawn"] = spawn
        json["routes"] = [["id": "tour", "waypointIDs": ids + [ids[0]], "bidirectional": true, "enabled": true]]
        json["collisionVolumes"] = []
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let context = try WorldAgentContext(manifest: manifest, walkingSpeed: 1)
        context.installCollisionWorld(Floor())
        _ = try context.move(to: "wp.center")
        try context.tick(deltaTime: 0.25)
        try context.stopActivity()
        let stopped = context.state.agentTransform.position
        try context.tick(deltaTime: 1)
        check(context.snapshot.movement == nil && context.state.agentTransform.position == stopped, "stop cancels ordinary movement")
        let walking = try WorldAgentContext(manifest: manifest, walkingSpeed: 1)
        walking.installCollisionWorld(Floor())
        try walking.startActivity(id: "home.walk")
        var visited = Set<String>()
        var targets = Set<String>()
        let walkingRequestID = walking.currentActivityRequestID
        for _ in 0..<120 {
            try walking.tick(deltaTime: 0.25)
            if case let .walk(destinationID)? = walking.snapshot.activeActivity?.activity { targets.insert(destinationID) }
            for point in manifest.waypoints where hypot(point.position.x-walking.state.agentTransform.position.x, point.position.z-walking.state.agentTransform.position.z) < 0.11 { visited.insert(point.id) }
        }
        check(visited.count >= 3, "home.walk continues through at least three targets")
        check(targets.count >= 3 && walking.currentActivityRequestID == walkingRequestID, "patrol changes targets without replacing playback request identity")
        try walking.stopActivity()
        let stoppedWalk = walking.state.agentTransform.position
        try walking.tick(deltaTime: 10)
        check(walking.state.agentTransform.position == stoppedWalk && walking.state.activeActivity == nil, "stop clears continuous walking")
        let single = try WorldAgentContext(manifest: manifest, walkingSpeed: 1)
        single.installCollisionWorld(Floor())
        _ = try single.move(to: "wp.center")
        let firstMovementID = single.currentMovementRequestID!
        try single.tick(deltaTime: 0.25)
        check(single.state.agentTransform.rotation != manifest.spawn.rotation, "ordinary movement faces the route")
        check(single.currentMovementRequestID == firstMovementID, "movement playback identity is stable across frames")
        try single.failMovementPlayback(requestID: "stale")
        check(single.currentMovementRequestID == firstMovementID, "stale movement playback failure is ignored")
        let beforeSpeedChange = single.state.agentTransform.position.x
        single.updateWalkingSpeed(2)
        try single.tick(deltaTime: 0.25)
        check(abs(single.state.agentTransform.position.x-beforeSpeedChange-0.5) < 0.001, "speed updates ordinary movement without resetting it")
        for _ in 0..<20 { try single.tick(deltaTime: 0.25) }
        let arrived = single.state.agentTransform.position
        try single.tick(deltaTime: 10)
        check(single.state.agentTransform.position == arrived && single.snapshot.movement == nil, "ordinary move remains one destination")
        check(single.events.filter { if case .movementCompleted(requestID: firstMovementID, destinationID: "wp.center") = $0.kind { true } else { false } }.count == 1, "movement emits exactly one completion")
        _ = try single.move(to: "wp.jukebox")
        let failedID = single.currentMovementRequestID!
        try single.failMovementPlayback(requestID: firstMovementID)
        check(single.currentMovementRequestID == failedID, "old movement cannot stop replacement")
        try single.failMovementPlayback(requestID: failedID)
        check(single.snapshot.movement == nil, "current movement playback failure stops movement")
        check(single.events.contains { if case .movementFailed(requestID: failedID, destinationID: "wp.jukebox", reason: "missingMotion") = $0.kind { true } else { false } }, "movement missing motion is a failure fact")
        let closing = ClosingFloor()
        let blocked = try WorldAgentContext(manifest: manifest)
        blocked.installCollisionWorld(closing)
        _ = try blocked.move(to: "wp.center")
        closing.closed = true
        _ = try? blocked.tick(deltaTime: 0.1)
        check(blocked.snapshot.movement == nil, "no route after dynamic obstacle exits boundedly")
        let blockedCount = blocked.events.filter { if case .movementFailed = $0.kind { true } else { false } }.count
        for _ in 0..<10 { try blocked.tick(deltaTime: 0.1) }
        check(blockedCount == 1 && blocked.events.filter { if case .movementFailed = $0.kind { true } else { false } }.count == 1, "blocked movement never retries each idle frame")
        let door = DoorFloor()
        let detour = try WorldAgentContext(manifest: manifest, walkingSpeed: 1)
        detour.installCollisionWorld(door)
        _ = try detour.move(to: "wp.center")
        let detourID = detour.currentMovementRequestID!
        try detour.tick(deltaTime: 0.5)
        door.closed = true
        var tookDetour = false
        for _ in 0..<100 {
            try detour.tick(deltaTime: 0.1)
            let p = detour.state.agentTransform.position
            tookDetour = tookDetour || p.z > 1
            check(door.canOccupy(WorldCapsule(radius: 0.2,height: 1.8),at: SIMD3(p.x,p.y,p.z)), "replanned movement never enters newly blocked doorway")
        }
        check(tookDetour && detour.snapshot.movement == nil && abs(detour.state.agentTransform.position.x-2) < 0.001 && abs(detour.state.agentTransform.position.z) < 0.001, "dynamic doorway causes bounded safe detour to original target")
        check(detour.events.contains { if case .movementCompleted(requestID: detourID, destinationID: "wp.center") = $0.kind { true } else { false } }, "replanned movement keeps request identity")
        let activity = try WorldAgentContext(manifest: manifest)
        activity.installCollisionWorld(Floor())
        try activity.startActivity(id: "home.walk")
        let walkID = activity.currentActivityRequestID!
        try activity.failActivityPlayback(requestID: walkID, phase: .loop)
        check(activity.state.activeActivity != nil, "wrong phase cannot fail walking approach")
        try activity.failActivityPlayback(requestID: "stale", phase: .approach)
        check(activity.state.activeActivity != nil, "stale activity playback failure is ignored")
        try activity.failActivityPlayback(requestID: walkID, phase: .approach)
        let failurePosition = activity.state.agentTransform.position
        try activity.tick(deltaTime: 20)
        check(activity.state.activeActivity == nil && activity.state.agentTransform.position == failurePosition, "failed activity cannot keep patrolling")
        check(activity.events.contains { if case .activityFailed(activityID: "home.walk", reason: "missingMotion") = $0.kind { true } else { false } }, "missing animation emits activity failure")
        check(!activity.events.contains { if case .activityCompleted(activityID: "home.walk") = $0.kind { true } else { false } }, "failed activity never turns into timer success")
        try activity.startActivity(id: "performance.backflip")
        let performanceID = activity.currentActivityRequestID!
        try activity.completeActivityPlayback(requestID: "old", phase: .enter)
        check(activity.snapshot.activeActivity?.phase == .enter, "stale completion is ignored")
        try activity.completeActivityPlayback(requestID: performanceID, phase: .enter)
        check(activity.snapshot.activeActivity?.phase == .loop, "matching enter completion advances")
        try activity.completeActivityPlayback(requestID: performanceID, phase: .loop)
        try activity.completeActivityPlayback(requestID: performanceID, phase: .exit)
        check(activity.state.activeActivity == nil, "matching finite playback completion ends activity")
        try activity.startActivity(id: "home.walk")
        activity.updateWalkingSpeed(0)
        let stationary = activity.state.agentTransform.position
        try activity.tick(deltaTime: 0.5)
        check(activity.state.agentTransform.position == stationary, "speed update reaches ActivityExecutor")
        activity.updateWalkingSpeed(1)
        _ = try activity.move(to: "wp.center")
        check(activity.state.activeActivity == nil, "move replaces patrol activity")
        for _ in 0..<40 { try activity.tick(deltaTime: 0.25) }
        let replacementDestination = activity.state.agentTransform.position
        try activity.tick(deltaTime: 20)
        check(activity.state.agentTransform.position == replacementDestination && activity.snapshot.movement == nil, "replacement never revives patrol")
        try activity.startActivity(id: "home.walk")
        let beforeReplacementTick = activity.state.agentTransform.position
        try activity.tick(deltaTime: 0.1)
        check(hypot(activity.state.agentTransform.position.x-beforeReplacementTick.x, activity.state.agentTransform.position.z-beforeReplacementTick.z) <= 0.101, "starting activity after movement uses actual current placement")
        let priorWorld = try WorldAgentContext(manifest: manifest)
        let nextWorld = try WorldAgentContext(manifest: manifest)
        priorWorld.installCollisionWorld(Floor()); nextWorld.installCollisionWorld(Floor())
        try priorWorld.startActivity(id: "performance.backflip")
        try nextWorld.startActivity(id: "performance.backflip")
        let priorWorldRequest = priorWorld.currentActivityRequestID!
        check(nextWorld.currentActivityRequestID != priorWorldRequest, "execution identity is unique across contexts at equal world revision")
        try nextWorld.completeActivityPlayback(requestID: priorWorldRequest, phase: .enter)
        try nextWorld.failActivityPlayback(requestID: priorWorldRequest, phase: .enter)
        check(nextWorld.snapshot.activeActivity?.phase == .enter && !nextWorld.events.contains { if case .activityFailed = $0.kind { true } else { false } }, "old world completion and failure cannot mutate replacement world")
        print("\(failures == 0 ? "PASS" : "FAIL"): navigation behavior, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-navigation-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("navigation-tests")
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let packageBuild = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-I", packageBuild.appendingPathComponent("Modules").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift").path,
    program.path, "-o", executable.path] + FileManager.default.contentsOfDirectory(at: packageBuild.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path))
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
