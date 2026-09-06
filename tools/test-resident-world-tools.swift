// Hostless behavioral checks against the shipping world context and dispatcher.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
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
        let context = try WorldAgentContext(manifest: manifest)
        let worldRoot = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: worldRoot.appendingPathComponent("marble.json")))
        let origin = SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: worldRoot.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin, uniformScale: config.framing.scale))
        let physics = MarbleLivingCabinCollisionWorld(environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes.filter { $0.id == "collision.jukebox" }))
        _ = try context.installCollisionWorldAndReconcilePlacement(physics)
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context)
        let clock = Clock()
        let current = Current()
        let scope = UUID()
        let session = ResidentWorldToolSession(scopeID: scope, worldID: manifest.worldID,
            dispatcher: dispatcher, deadline: Date(timeIntervalSince1970: 200),
            now: { clock.value }, isCurrent: { current.value })
        let schemas = try JSONSerialization.jsonObject(with: session.toolSchemasJSON) as! [[String: Any]]
        check(Set(schemas.compactMap { $0["name"] as? String }) ==
              ["inspect_world", "list_available_activities", "start_activity", "stop_activity"], "only four formal tools advertised")
        for schema in schemas {
            let input = schema["inputSchema"] as? [String: Any]
            check(input?["type"] as? String == "object", "tool arguments are objects")
            check(input?["additionalProperties"] as? Bool == false, "unknown arguments forbidden by schema")
        }
        let startSchema = schemas.first { $0["name"] as? String == "start_activity" }!
        let parameters = (startSchema["inputSchema"] as! [String: Any])["properties"] as! [String: Any]
        check((parameters["activity_id"] as? [String: Any])?["enum"] as? [String] == manifest.activities.map(\.id).sorted(), "advertised activity IDs come from actual manifest")
        check(!String(decoding: session.toolSchemasJSON, as: UTF8.self).contains("/Users/"), "tool schemas contain no local paths")
        let first = await session.call(requestID: "read", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        check(!first.isError && first.callID == "read", "read returns original transport call ID")
        check((payload(first)["snapshot"] as? [String: Any])?["worldID"] as? String == manifest.worldID, "read uses actual bound world")
        let before = context.snapshot
        for (name, argument, expected) in [
            ("move_to", "{\"place_id\":\"home\"}", "tool_not_allowed"),
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
        check((payload(started)["message"] as? String)?.contains("开始执行") == true, "start only reports accepted activity")
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
        check(context.snapshot.activeActivity?.phase == .loop, "real resident reaches jukebox through actual collision route")
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
        check(extendedSchemas.count == 5, "only registered extension is advertised alongside world tools")
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
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library",
    "-I", root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/Modules").path,
    sources.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolContract.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolDispatcher.swift").path,
    bridge.path, program.path, "-o", executable.path] + FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/WorldRuntime.build"),
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path))
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
