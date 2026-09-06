import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent")
let ownership = sources.appendingPathComponent("ResidentActivityOwnership.swift")
guard FileManager.default.fileExists(atPath: ownership.path) else {
    print("FAIL: non-music resident activities have no request-scoped stop ownership")
    exit(1)
}
guard try String(contentsOf: ownership, encoding: .utf8).contains("var hasActiveActivity: Bool") else {
    print("FAIL: resident loop cannot inspect whether its accepted activity remains active")
    exit(1)
}
let harness = #"""
import Foundation
import WorldRuntime
struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String; let name: String; let argumentsJSON: Data
}
struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String; let resultJSON: Data; let isError: Bool
}
@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
            URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
        let context = try WorldAgentContext(manifest: manifest, startedAt: Date(timeIntervalSince1970: 1000))
        let ownership = ResidentActivityOwnership()
        check(!ownership.hasActiveActivity, "new ownership has no active activity")
        var claims = 0
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
            onActivityStarted: { claimedContext, requestID in
                claims += 1
                check(claimedContext === context && requestID == context.currentActivityRequestID,
                      "start callback synchronously receives the actual executor request")
                ownership.claim(context: claimedContext, requestID: requestID)
            })
        func start(_ callID: String, _ activityID: String) async -> RealtimeDJToolResult {
            await dispatcher.handle(.init(id: callID, name: "start_activity",
                argumentsJSON: Data("{\"activity_id\":\"\(activityID)\"}".utf8)))
        }
        let started = await start("idle", "home.idle")
        check(!started.isError && context.state.activeActivity?.activityID == "home.idle",
              "real non-music activity starts through dispatcher")
        check(claims == 1, "successful non-music start establishes one claim")
        check(ownership.hasActiveActivity, "accepted activity remains available to the stop control")
        let duplicate = await start("idle", "home.idle")
        check(duplicate == started && claims == 1, "cached tool result does not claim activity again")
        try ownership.stopOwnedActivity()
        check(context.state.activeActivity == nil && context.currentActivityRequestID == nil,
              "explicit cancellation stops the actual non-music body activity")
        check(!ownership.hasActiveActivity, "explicit stop clears active ownership")
        try context.startActivity(id: "home.idle")
        let manualRequest = context.currentActivityRequestID
        try ownership.stopOwnedActivity()
        check(context.currentActivityRequestID == manualRequest && context.state.activeActivity != nil,
              "ownership is cleared before stop and repeated cleanup preserves later manual activity")

        let nextResult = await start("next-idle", "home.idle")
        check(!nextResult.isError && context.state.activeActivity?.activityID == "home.idle",
              "later non-music tool request acquires fresh ownership")
        try context.startActivity(id: "home.idle")
        let replacement = context.currentActivityRequestID
        check(!ownership.hasActiveActivity, "manual replacement is not advertised as resident-owned")
        try ownership.stopOwnedActivity()
        check(context.currentActivityRequestID == replacement && context.state.activeActivity?.activityID == "home.idle",
              "manual replacement is not stopped by an older request")

        let previousClaims = claims
        let invalid = await start("invalid", "missing.activity")
        check(invalid.isError && claims == previousClaims, "failed start never claims manual activity")
        try ownership.stopOwnedActivity()
        check(context.currentActivityRequestID == replacement, "failure cleanup preserves manual activity")

        _ = await start("normal-finish", "home.idle")
        dispatcher.resetSession()
        check(context.state.activeActivity?.activityID == "home.idle",
              "normal conversation/session release leaves accepted activity running")
        check(ownership.hasActiveActivity, "ordinary turn finish keeps stop available for owned activity")
        try ownership.stopOwnedActivity()
        check(context.state.activeActivity == nil, "explicit stop still works after ordinary turn end")

        let other = try WorldAgentContext(manifest: manifest, startedAt: Date(timeIntervalSince1970: 1000))
        try other.startActivity(id: "home.idle")
        let otherRequest = other.currentActivityRequestID
        try context.startActivity(id: "home.idle")
        ownership.claim(context: context, requestID: context.currentActivityRequestID!)
        try context.stopActivity()
        check(!ownership.hasActiveActivity, "externally finished activity clears read-only active status")
        try ownership.stopOwnedActivity()
        check(other.currentActivityRequestID == otherRequest && other.state.activeActivity != nil,
              "ownership only affects its exact world context")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident activity ownership checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-activity-ownership-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let program = temp.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
func run(_ binary: String, _ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let build = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let files = ["WorldAgentContext", "WorldAgentToolContract", "WorldAgentToolDispatcher", "ResidentActivityOwnership"]
let sourcePaths = files.map { sources.appendingPathComponent("\($0).swift").path }
let objects = try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "o" }.map(\.path)
let arguments = ["-j1", "-parse-as-library", "-I", build.appendingPathComponent("Modules").path] + sourcePaths +
    [program.path, "-o", temp.appendingPathComponent("test").path] + objects
let compiled = try run("/usr/bin/swiftc", arguments)
guard compiled == 0 else { exit(compiled) }
exit(try run(temp.appendingPathComponent("test").path, []))
