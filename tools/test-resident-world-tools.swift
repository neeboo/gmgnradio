// Hostless behavioral checks against the shipping world context and dispatcher.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let worldJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("apps/macos/Resources/Worlds/marble-living-cabin/world.json"))) as! [String: Any]
let worldActivityIDs = (worldJSON["activities"] as! [[String: Any]]).compactMap { $0["id"] as? String }
guard worldActivityIDs.contains("performance.backflip"), worldActivityIDs.contains("performance.jumping_jacks") else {
    print("FAIL: installed performance motions have no formal world activities"); exit(1)
}
guard try String(contentsOf: sources.appendingPathComponent("Agent/WorldAgentToolDispatcher.swift"), encoding: .utf8).contains("availableActivity:") else {
    print("FAIL: dispatcher cannot consistently filter and reject unavailable motions"); exit(1)
}
let bridge = sources.appendingPathComponent("Agent/ResidentWorldToolSession.swift")
guard FileManager.default.fileExists(atPath: bridge.path) else {
    print("FAIL: resident world tool session is not implemented")
    exit(1)
}
guard try String(contentsOf: bridge, encoding: .utf8).contains("struct AdditionalTool") else {
    print("FAIL: resident session cannot register loop capabilities or enforce a call budget")
    exit(1)
}
let bootstrap = try String(contentsOf: sources.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let collisionStart = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let collisionEnd = bootstrap.range(of: "/// An effect is keyed", range: collisionStart..<bootstrap.endIndex)!.lowerBound
let collision = String(bootstrap[collisionStart..<collisionEnd])
let harness = #"""
import Foundation
import WorldRuntime

\#(collision)
struct Config: Decodable {
    struct Framing: Decodable { let origin: [Float]; let scale: Float }
    let framing: Framing
}

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
func code(_ result: RealtimeDJToolResult) -> String? { payload(result)["code"] as? String }
@MainActor final class Clock { var value = Date(timeIntervalSince1970: 100) }
@MainActor final class Current { var value = true }
@main struct Tests {
    @MainActor static func main() async throws {
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
            URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
        let worldRoot = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let functionSources: [WorldPropFunctionSource] = try manifest.resources
            .filter { $0.kind == "prop.procedural" }
            .sorted { $0.id < $1.id }
            .compactMap { resource in
                try JSONDecoder().decode(WorldProceduralPropDeclaration.self,
                    from: Data(contentsOf: worldRoot.appendingPathComponent(resource.path))).functionSource
            }
        let context = try WorldAgentContext(manifest: manifest, propFunctionSources: functionSources)
        let motionDispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context)
        var motionID = "builtin.motion.iluvslapbass"
        var selectedMotion: String?
        motionDispatcher.availableMotions = {
            [.init(id: motionID, displayName: "I Love Slap Bass", format: motionID.hasSuffix("-vrm") ? "vrma" : "vmd", loop: true)]
        }
        motionDispatcher.selectMotion = { selectedMotion = $0; return true }
        let motionList = payload(await motionDispatcher.handle(.init(id: "motion-list", name: "list_available_motions", argumentsJSON: Data("{}".utf8))))
        check((motionList["motions"] as? [[String: Any]])?.first?["id"] as? String == motionID, "all compatible motions expose exact Slap Bass ID")
        check((motionList["motions"] as? [[String: Any]])?.first?["displayName"] as? String == "I Love Slap Bass", "motion display name is discoverable")
        let motionSession = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: motionDispatcher, deadline: Date.distantFuture, isCurrent: { true })
        let motionSchemas = try JSONSerialization.jsonObject(with: motionSession.toolSchemasJSON) as! [[String: Any]]
        check(motionSchemas.contains { $0["name"] as? String == "list_available_motions" } &&
              motionSchemas.contains { $0["name"] as? String == "play_motion" }, "resident provider transport advertises both motion tools")
        let leasedMotionList = await motionSession.call(requestID: "leased-motion-list", name: "list_available_motions", argumentsJSON: Data("{}".utf8))
        check(!leasedMotionList.isError && (payload(leasedMotionList)["motions"] as? [[String: Any]])?.first?["id"] as? String == motionID, "resident lease exposes actual motion catalog")
        let leasedMotionPlay = await motionSession.call(requestID: "leased-motion-play", name: "play_motion", argumentsJSON: Data(#"{"motion_id":"builtin.motion.iluvslapbass"}"#.utf8))
        check(!leasedMotionPlay.isError && selectedMotion == motionID, "resident lease executes discovered Slap Bass motion")
        motionSession.cancel()
        check(code(await motionSession.call(requestID: "leased-motion-cancelled", name: "play_motion", argumentsJSON: Data(#"{"motion_id":"builtin.motion.iluvslapbass"}"#.utf8))) == "tool_session_cancelled", "cancelled resident lease cannot select motion")
        let beforeMotion = context.snapshot.agentTransform
        let motionResult = await motionDispatcher.handle(.init(id: "motion-play", name: "play_motion", argumentsJSON: Data(#"{"motion_id":"builtin.motion.iluvslapbass"}"#.utf8)))
        check(!motionResult.isError && selectedMotion == motionID, "agent selects exact discovered motion")
        check(context.snapshot.agentTransform == beforeMotion, "manual motion selection never teleports to authored activity spawn")
        let missingMotion = await motionDispatcher.handle(.init(id: "motion-missing", name: "play_motion", argumentsJSON: Data(#"{"motion_id":"missing"}"#.utf8)))
        check(code(missingMotion) == "motion_unavailable" && selectedMotion == motionID, "missing motion rejected before selection")
        motionID = "builtin.motion.iluvslapbass-vrm"
        let changedList = payload(await motionDispatcher.handle(.init(id: "motion-changed", name: "list_available_motions", argumentsJSON: Data("{}".utf8))))
        check((changedList["motions"] as? [[String: Any]])?.first?["id"] as? String == motionID, "character switch refreshes catalog without stale enum")
        let staleMotion = await motionDispatcher.handle(.init(id: "motion-stale", name: "play_motion", argumentsJSON: Data(#"{"motion_id":"builtin.motion.iluvslapbass"}"#.utf8)))
        check(code(staleMotion) == "motion_unavailable", "old character motion rejected after switch")
        motionDispatcher.availableMotions = { [] }
        check((payload(await motionDispatcher.handle(.init(id: "motion-empty", name: "list_available_motions", argumentsJSON: Data("{}".utf8))))["motions"] as? [[String: Any]])?.isEmpty == true, "no installed compatible actions means empty catalog")
        let restricted = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
            availableActivity: { $0 != "music.listen" })
        let unavailableList = await restricted.handle(RealtimeDJToolCall(id: "restricted-list", name: "list_available_activities", argumentsJSON: Data("{}".utf8)))
        let restrictedSnapshot = payload(unavailableList)["snapshot"] as! [String: Any]
        let restrictedActivities = restrictedSnapshot["activities"] as! [[String: Any]]
        check(!restrictedActivities.contains { $0["id"] as? String == "music.listen" }, "unavailable activities absent from snapshot/list")
        let restrictedTools = restricted.providerTools
        let restrictedStart = restrictedTools.first { ($0["function"] as? [String: Any])?["name"] as? String == "start_activity" }!["function"] as! [String: Any]
        let restrictedProperties = (restrictedStart["parameters"] as! [String: Any])["properties"] as! [String: Any]
        let restrictedActivitySchema = restrictedProperties["activity_id"] as! [String: Any]
        check(restrictedActivitySchema["type"] as? String == "string" && restrictedActivitySchema["enum"] == nil, "activity schema stays stable across avatar changes")
        let unrestricted = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context)
        let restrictedSchemaBytes = try JSONSerialization.data(withJSONObject: restricted.providerTools, options: [.sortedKeys])
        let unrestrictedSchemaBytes = try JSONSerialization.data(withJSONObject: unrestricted.providerTools, options: [.sortedKeys])
        check(restrictedSchemaBytes == unrestrictedSchemaBytes, "changing available assets never changes resumed tool schema")
        let restrictedBefore = context.snapshot
        let rejectedMotion = await restricted.handle(RealtimeDJToolCall(id: "restricted-start", name: "start_activity", argumentsJSON: Data(#"{"activity_id":"music.listen"}"#.utf8)))
        check(code(rejectedMotion) == "activity_unavailable" && context.snapshot == restrictedBefore, "unavailable start fails before world mutation")
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: worldRoot.appendingPathComponent("marble.json")))
        let origin = SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: worldRoot.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin, uniformScale: config.framing.scale))
        let physics = MarbleLivingCabinCollisionWorld(environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes))
        let performancePosition = manifest.spawn.position
        check(physics.canOccupy(WorldCapsule(radius: 0.7, height: 2.5), at: SIMD3(performancePosition.x, performancePosition.y, performancePosition.z)), "performance anchor has enlarged body/air clearance in actual collision mesh")
        for activityID in ["performance.backflip", "performance.jumping_jacks"] {
            let performanceContext = try WorldAgentContext(manifest: manifest)
            _ = try performanceContext.installCollisionWorldAndReconcilePlacement(physics)
            try performanceContext.startActivity(id: activityID)
            for _ in 0..<450 { try performanceContext.tick(deltaTime: 1.0/30) }
            check(performanceContext.state.activeActivity == nil, "finite performance terminates: \(activityID)")
            check(abs(performanceContext.state.agentTransform.position.x-performancePosition.x) < 0.1 && abs(performanceContext.state.agentTransform.position.z-performancePosition.z) < 0.1, "performance never translates world position: \(activityID)")
        }
        _ = try context.installCollisionWorldAndReconcilePlacement(physics)
        let heldContext = try WorldAgentContext(manifest: manifest, propFunctionSources: functionSources)
        let sensitiveHeldObjectID = "/private/user/secret-held-prop.glb"
        var heldState = heldContext.state
        let heldReturnState = WorldObjectState(isEnabled: true, transform: manifest.spawn)
        heldState.objectStates[sensitiveHeldObjectID] = WorldObjectState(
            isEnabled: false,
            transform: manifest.spawn
        )
        heldState.heldProp = WorldHeldProp(
            objectID: sensitiveHeldObjectID,
            avatarAssetID: "avatar.fixture",
            hand: .rightHand,
            returnState: heldReturnState
        )
        try heldContext.adoptAuthorityState(heldState, propFunctionSources: functionSources)
        let heldDispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: heldContext)
        let heldStart = await heldDispatcher.handle(RealtimeDJToolCall(
            id: "held-start",
            name: "start_activity",
            argumentsJSON: Data(#"{"activity_id":"home.idle"}"#.utf8)
        ))
        let heldMessage = payload(heldStart)["message"] as? String ?? ""
        check(
            heldStart.isError && code(heldStart) == "held_prop_conflict",
            "held prop conflict has a stable actionable code"
        )
        check(
            heldMessage == "居民正持有物件。需要人类在本轮明确授权放回后，才能开始活动。",
            "held prop conflict asks for explicit current-turn human authorization"
        )
        check(
            !heldMessage.contains(sensitiveHeldObjectID) && !heldMessage.contains("重启"),
            "held prop conflict does not expose object identity or suggest a retry loop"
        )
        check(
            heldContext.state.activeActivity == nil,
            "rejected held-prop start never reports an activity as started"
        )
        let patrolContext = try WorldAgentContext(manifest: manifest, walkingSpeed: 1.2)
        _ = try patrolContext.installCollisionWorldAndReconcilePlacement(physics)
        check(Set(patrolContext.snapshot.places.map(\.id)) == ["wp.spawn", "wp.center", "wp.jukebox", "wish_machine.pickup"], "only four semantic places are exposed; generated navigation stays internal")
        let patrolStarted = Date()
        try patrolContext.startActivity(id: "home.walk")
        let coldPatrolPlanning = Date().timeIntervalSince(patrolStarted)
        var patrolTargets = Set<String>()
        let patrolRequestID = patrolContext.currentActivityRequestID
        var slowestPatrolTick: TimeInterval = 0
        for _ in 0..<900 {
            let tickStarted = Date()
            try patrolContext.tick(deltaTime: 1.0/30)
            slowestPatrolTick = max(slowestPatrolTick, Date().timeIntervalSince(tickStarted))
            if case let .walk(destinationID)? = patrolContext.snapshot.activeActivity?.activity { patrolTargets.insert(destinationID) }
            let p = patrolContext.state.agentTransform.position
            check(physics.canOccupy(WorldCapsule(radius: 0.2, height: 1.8), at: SIMD3(p.x,p.y,p.z)), "actual mesh permits every patrol body position")
        }
        check(patrolTargets.count >= 3 && patrolContext.currentActivityRequestID == patrolRequestID, "actual cabin patrol continues across three targets in one execution")
        print("Patrol: \(patrolTargets.count) targets, 30 simulated seconds, \(Date().timeIntervalSince(patrolStarted)) wall seconds, cold plan \(coldPatrolPlanning)s, slowest tick \(slowestPatrolTick)s")
        try patrolContext.stopActivity()
        let stoppedPatrolPosition = patrolContext.state.agentTransform.position
        try patrolContext.tick(deltaTime: 20)
        check(patrolContext.state.agentTransform.position == stoppedPatrolPosition && patrolContext.state.activeActivity == nil, "actual cabin patrol stop does not resume")
        let internalTarget = manifest.waypoints.first { $0.id.hasPrefix("wp.auto.") && hypot($0.position.x-stoppedPatrolPosition.x, $0.position.z-stoppedPatrolPosition.z) > 0.5 }!
        let internalPath = try patrolContext.planRoute(to: internalTarget.id)
        check(internalPath.destinationID == internalTarget.id && !internalPath.points.isEmpty, "known generated waypoint remains navigable internally")
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context)
        let acceptanceContext = try WorldAgentContext(manifest: manifest)
        let acceptanceDispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: acceptanceContext)
        let missingDeviceSnapshot = acceptanceContext.snapshot
        let missingDevice = await acceptanceDispatcher.handle(RealtimeDJToolCall(id: "missing-device", name: "start_activity", argumentsJSON: Data(#"{"activity_id":"music.listen"}"#.utf8)))
        check(code(missingDevice) == "unknown_activity" && acceptanceContext.snapshot == missingDeviceSnapshot,
            "manifest-only baseline has no registered jukebox and rejects without mutation")
        let acceptedIdle = await acceptanceDispatcher.handle(RealtimeDJToolCall(id: "accepted-idle", name: "start_activity", argumentsJSON: Data(#"{"activity_id":"home.idle"}"#.utf8)))
        let idleRequest = payload(acceptedIdle)["activityRequest"] as? [String: Any]
        check(!acceptedIdle.isError && idleRequest?["status"] as? String == "accepted", "formal idle request is accepted without renderer success claim")
        check(idleRequest?["requestID"] as? String == acceptanceContext.currentActivityRequestID, "formal idle acceptance uses actual request identity")
        let clock = Clock()
        let current = Current()
        let scope = UUID()
        let session = ResidentWorldToolSession(scopeID: scope, worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 200),
            now: { clock.value }, isCurrent: { current.value })
        let schemas = try JSONSerialization.jsonObject(with: session.toolSchemasJSON) as! [[String: Any]]
        check(Set(schemas.compactMap { $0["name"] as? String }) ==
              ["inspect_world", "list_places", "list_available_activities", "plan_route", "move_to",
               "start_activity", "stop_activity", "look_at", "list_available_motions", "play_motion"], "resident life tools are advertised")
        for schema in schemas {
            let input = schema["inputSchema"] as? [String: Any]
            check(input?["type"] as? String == "object", "tool arguments are objects")
            check(input?["additionalProperties"] as? Bool == false, "unknown arguments forbidden by schema")
        }
        let startSchema = schemas.first { $0["name"] as? String == "start_activity" }!
        let parameters = (startSchema["inputSchema"] as! [String: Any])["properties"] as! [String: Any]
        check((parameters["activity_id"] as? [String: Any])?["type"] as? String == "string" && (parameters["activity_id"] as? [String: Any])?["enum"] == nil, "discover actual activity IDs through list tool instead of frozen schema enum")
        check(!String(decoding: session.toolSchemasJSON, as: UTF8.self).contains("/Users/"), "tool schemas contain no local paths")
        let first = await session.call(requestID: "read", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        check(!first.isError && first.callID == "read", "read returns original transport call ID")
        check((payload(first)["snapshot"] as? [String: Any])?["worldID"] as? String == manifest.worldID, "read uses actual bound world")
        let before = context.snapshot
        for (name, argument, expected) in [
            ("move_live_camera", "{\"camera_id\":\"home\"}", "tool_not_allowed"),
            ("shell", "{}", "tool_not_allowed"),
            ("start_activity", "{}", "invalid_arguments"),
            ("start_activity", "{\"activity_id\":7}", "invalid_arguments"),
            ("start_activity", "{\"activity_id\":true}", "invalid_arguments"),
            ("start_activity", "{\"activity_id\":null}", "invalid_arguments"),
            ("start_activity", "{\"activity_id\":\"music.listen\",\"worldID\":\"other\"}", "invalid_arguments"),
            ("inspect_world", "{\"extra\":true}", "invalid_arguments"),
            ("stop_activity", "{\"reason\":null}", "invalid_arguments"),
            ("inspect_world", "[]", "invalid_arguments"),
            ("inspect_world", "oops", "invalid_arguments")
        ] {
            let result = await session.call(requestID: UUID().uuidString, name: name, argumentsJSON: Data(argument.utf8))
            check(result.isError && code(result) == expected, "reject \(name) \(argument)")
        }
        check(context.snapshot == before, "rejected tools and arguments never mutate world")
        let empty = await session.call(requestID: "", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        check(code(empty) == "invalid_call_id", "empty call ID rejected")
        let unknown = await session.call(requestID: "unknown", name: "start_activity", argumentsJSON: Data(#"{"activity_id":"missing"}"#.utf8))
        check(unknown.isError && code(unknown) == "unknown_activity", "unknown activity is existing executor failure")
        let args = Data(#"{"activity_id":"music.listen"}"#.utf8)
        let started = await session.call(requestID: "start", name: "start_activity", argumentsJSON: args)
        check(!started.isError, "actual runtime accepts music activity")
        check(context.state.activeActivity?.activityID == "music.listen", "real context starts activity")
        check((payload(started)["message"] as? String)?.contains("已接受活动请求") == true, "start only reports accepted activity")
        let acceptedRequest = payload(started)["activityRequest"] as? [String: Any]
        check(acceptedRequest?["status"] as? String == "accepted", "acceptance never claims renderer performing")
        check(acceptedRequest?["requestID"] as? String == context.currentActivityRequestID, "accepted request exposes formal executor identity")
        check(acceptedRequest?["activityID"] as? String == "music.listen", "accepted request identifies the requested activity")
        check((payload(started)["message"] as? String)?.contains("播放成功") != true, "start does not fabricate playback success")
        let startSnapshot = context.snapshot
        let duplicate = await session.call(requestID: "start", name: "start_activity", argumentsJSON: Data("{ \"activity_id\" : \"music.listen\" }".utf8))
        check(duplicate == started && context.snapshot == startSnapshot, "semantic duplicate returns original result without replay")
        let collision = await session.call(requestID: "start", name: "stop_activity", argumentsJSON: Data("{}".utf8))
        check(code(collision) == "call_id_conflict" && context.snapshot == startSnapshot, "reused ID for different call rejected")
        let different = await session.call(requestID: "start", name: "start_activity", argumentsJSON: Data(#"{"activity_id":"home.idle"}"#.utf8))
        check(code(different) == "call_id_conflict", "reused ID with different parameters rejected")
        for _ in 0..<600 {
            try context.tick(deltaTime: 1.0 / 30)
            if context.snapshot.activeActivity?.phase == .loop { break }
        }
        check(context.snapshot.activeActivity?.phase == .enter, "real resident reaches jukebox and waits for operation completion")
        try context.completeActivityPlayback(requestID: "wrong-request", phase: .enter)
        check(context.snapshot.activeActivity?.phase == .enter, "unrelated completion cannot acknowledge the device operation")
        try context.completeActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
        check(context.snapshot.activeActivity?.phase == .loop, "matching formal completion advances device operation; this is a hostless receipt fixture")
        let acceptedReplay = await session.call(requestID: "start", name: "start_activity", argumentsJSON: args)
        check(acceptedReplay == started, "request replay preserves accepted result and never upgrades it to renderer success")
        let stopped = await session.call(requestID: "stop", name: "stop_activity", argumentsJSON: Data(#"{"reason":"private user words"}"#.utf8))
        check(!stopped.isError && context.state.activeActivity == nil, "actual runtime stops activity")
        let fresh = await session.call(requestID: "fresh", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        check((payload(fresh)["snapshot"] as? [String: Any])?["revision"] as? UInt64 == context.snapshot.revision, "new read reflects current state")
        let encodedRecords = try JSONEncoder().encode(session.records)
        let records = String(decoding: encodedRecords, as: UTF8.self)
        check(records.contains(scope.uuidString) && records.contains("music.listen"), "audit identifies scope and activity")
        check(!records.contains("private user words") && !records.contains("argumentsJSON"), "audit excludes user text and raw arguments")
        current.value = false
        let stale = await session.call(requestID: "start", name: "start_activity", argumentsJSON: args)
        check(code(stale) == "stale_world_session", "stale world rejected before duplicate cache read")
        check(context.state.activeActivity == nil, "stale call cannot start activity")
        current.value = true
        clock.value = Date(timeIntervalSince1970: 200)
        let expired = await session.call(requestID: "expire", name: "start_activity", argumentsJSON: args)
        check(code(expired) == "tool_session_expired", "deadline is exclusive")
        let other = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 300),
            now: { clock.value }, isCurrent: { true })
        let cooldown = await other.call(requestID: "cooldown", name: "start_activity", argumentsJSON: args)
        check(code(cooldown) == "activity_rejected", "actual activity cooldown rejection returned without bypass")
        try context.tick(deltaTime: 46)
        let otherStart = await other.call(requestID: "start", name: "start_activity", argumentsJSON: args)
        check(!otherStart.isError && context.state.activeActivity?.activityID == "music.listen", "scope prevents shared dispatcher cache collision")
        _ = await other.call(requestID: "stop", name: "stop_activity", argumentsJSON: Data("{}".utf8))
        other.cancel()
        let cancelled = await other.call(requestID: "after-cancel", name: "start_activity", argumentsJSON: args)
        check(code(cancelled) == "tool_session_cancelled" && context.state.activeActivity == nil, "cancelled lease prevents future mutation")
        let mismatch = ResidentWorldToolSession(scopeID: UUID(), worldID: "other-world",
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 300),
            now: { clock.value }, isCurrent: { true })
        let wrongWorld = await mismatch.call(requestID: "wrong", name: "start_activity", argumentsJSON: args)
        check(code(wrongWorld) == "stale_world_session", "bound world must equal actual dispatcher context")
        let disabled = WorldAgentToolDispatcher(takeoverEnabled: { false }, context: context)
        let blocked = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: disabled, deadline: Date(timeIntervalSince1970: 300),
            now: { clock.value }, isCurrent: { true })
        let denied = await blocked.call(requestID: "permission", name: "start_activity", argumentsJSON: args)
        check(code(denied) == "world_takeover_disabled", "existing dispatcher takeover permission preserved")
        let taskCancelledSession = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 300),
            now: { clock.value }, isCurrent: { true })
        let cancelledTask = Task { @MainActor in
            await taskCancelledSession.call(requestID: "task-cancelled", name: "start_activity", argumentsJSON: args)
        }
        cancelledTask.cancel()
        let cancelledTaskResult = await cancelledTask.value
        check(code(cancelledTaskResult) == "tool_session_cancelled", "caller task cancellation prevents dispatch")
        let listed = await blocked.call(requestID: "readonly", name: "list_available_activities", argumentsJSON: Data("{}".utf8))
        check(!listed.isError && (payload(listed)["snapshot"] as? [String: Any])?["activities"] != nil,
              "read-only activity list works with takeover disabled")
        check(context.state.activeActivity == nil, "rejected final calls leave resident idle")
        var extensionCalls = 0
        let extensionTool = ResidentWorldToolSession.AdditionalTool(
            name: "read_resident_state", description: "Read process-local resident state",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            validate: { $0.isEmpty },
            handle: { id, _ in
                extensionCalls += 1
                return RealtimeDJToolResult(callID: id, resultJSON: Data("{\"ok\":true}".utf8), isError: false)
            })
        let extended = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 300),
            now: { clock.value }, isCurrent: { current.value },
            additionalTools: [extensionTool], maximumCalls: 2)
        let extendedSchemas = try JSONSerialization.jsonObject(with: extended.toolSchemasJSON) as! [[String: Any]]
        check(extendedSchemas.count == ResidentWorldToolSession.allowedToolNames.count + 1, "only registered extension is advertised alongside world tools")
        let extensionFirst = await extended.call(requestID: "extension", name: "read_resident_state", argumentsJSON: Data("{}".utf8))
        let extensionDuplicate = await extended.call(requestID: "extension", name: "read_resident_state", argumentsJSON: Data("{}".utf8))
        check(!extensionFirst.isError && extensionFirst == extensionDuplicate && extensionCalls == 1, "registered capability shares call deduplication")
        let invalidExtension = await extended.call(requestID: "bad-extension", name: "read_resident_state", argumentsJSON: Data("{\"extra\":true}".utf8))
        check(code(invalidExtension) == "invalid_arguments" && extensionCalls == 1, "registered capability validates arguments before execution")
        _ = await extended.call(requestID: "second", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        let exhausted = await extended.call(requestID: "third", name: "read_resident_state", argumentsJSON: Data("{}".utf8))
        check(code(exhausted) == "tool_budget_exhausted" && extensionCalls == 1, "per-turn call limit prevents further operations")
        extended.cancel()
        let afterClose = await extended.call(requestID: "closed", name: "read_resident_state", argumentsJSON: Data("{}".utf8))
        check(code(afterClose) == "tool_session_cancelled" && extensionCalls == 1, "registered capability cannot survive closed lease")
        let timeBounded = ResidentWorldToolSession(scopeID: UUID(), worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 300),
            now: { clock.value }, isCurrent: { current.value }, maximumCalls: nil)
        for index in 0..<70 {
            let result = await timeBounded.call(requestID: "uncapped-\(index)", name: "inspect_world", argumentsJSON: Data("{}".utf8))
            check(!result.isError, "DSH time-bounded lease has no hidden call-count cutoff")
        }
        timeBounded.cancel()
        let timeBoundedStopped = await timeBounded.call(requestID: "uncapped-stop", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        check(code(timeBoundedStopped) == "tool_session_cancelled", "count-free lease still enforces explicit stop")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident world tool checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-world-tools-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("world-tools")
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
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
let worldRuntimeObjects = URL(fileURLWithPath: worldRuntimeFlags[1])
    .deletingLastPathComponent().appendingPathComponent("WorldRuntime.build")
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library",
    "-I", worldRuntimeFlags[1],
    sources.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolContract.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolDispatcher.swift").path,
    sources.appendingPathComponent("Presence/RetryBackoff.swift").path,
    bridge.path, program.path, "-o", executable.path] + FileManager.default.contentsOfDirectory(
        at: worldRuntimeObjects,
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path))
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
