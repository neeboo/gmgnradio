import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-wish-delivery-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// Reuse the established pure-Swift production source compilation/runner, not its scenarios.
let harness = #"""
import Foundation
@MainActor var failures = 0
@MainActor var checks = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}
struct Locator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? {
        let key = executableNames.contains("node") ? "NODE_BIN" : "DSH_BIN"
        return ProcessInfo.processInfo.environment[key].map { URL(fileURLWithPath: $0) }
    }
}
@main struct WishDelivery {
    @MainActor static func main() async throws {
        let suite = "gmgn-wish-delivery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = AgentConversationService(locator: Locator(), defaults: defaults)
        defer {
            service.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            service.cancel(); service.resetSession()
            defaults.removePersistentDomain(forName: suite)
            print("FAIL: wish delivery watchdog")
            exit(124)
        }
        defer { watchdog.cancel() }
        service.selectBackend(.dsh)
        let names = ["search_wish_reference_images", "register_wish_reference_image", "submit_wish_generation"]
        let properties: [[String: Any]] = [
            ["query": ["type": "string"]],
            ["image_url": ["type": "string"], "display_name": ["type": "string"]],
            ["attachment_id": ["type": "string"], "name": ["type": "string"], "height_meters": ["type": "number"]]
        ]
        let schemas: [[String: Any]] = names.enumerated().map { index, name in
            ["name": name, "description": "Offline wish delivery fixture",
             "inputSchema": ["type": "object", "properties": properties[index],
                             "required": Array(properties[index].keys).sorted(), "additionalProperties": false]]
        }
        // Negative control: prove that missing actual tool registration fails delivery.
        let omitRegistration = ProcessInfo.processInfo.environment["TEST_OMIT_REGISTER_SCHEMA"] == "1"
        let schemasJSON = try JSONSerialization.data(withJSONObject: omitRegistration ? schemas.filter { $0["name"] as? String != names[1] } : schemas)
        var calls: [String] = []
        let imageURL = "https://reference.invalid/\(UUID().uuidString.lowercased()).png"
        let attachmentID = UUID().uuidString.lowercased()
        let tools = ResidentConversationTools(
            visionCapable: true, worldID: "offline-wish", schemasJSON: schemasJSON,
            call: { _, name, argumentsJSON in
                calls.append(name)
                let args = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] ?? [:]
                var payload: [String: Any] = ["ok": false]
                switch name {
                case names[0]:
                    check(args["query"] as? String == "red wooden chair", "typed search arguments reach host")
                    payload = ["ok": true, "images": [["image_url": imageURL]]]
                case names[1]:
                    check(args["image_url"] as? String == imageURL, "register uses unpredictable URL returned by search")
                    check(args["display_name"] as? String == "red wooden chair", "typed display_name reaches registration host")
                    payload = ["ok": true, "attachment_id": attachmentID]
                case names[2]:
                    check(args["attachment_id"] as? String == attachmentID, "submit uses unpredictable registered attachment ID")
                    payload = ["ok": true, "wish_id": "wish-offline-accepted", "status": "accepted"]
                default:
                    check(false, "public gmgn_ name must map to canonical host name: \(name)")
                }
                return ResidentCodexToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: payload), isError: false)
            }, cancel: {})
        let world = ResidentWorldContext(
            selectedWorldID: "offline-wish", worldID: "offline-wish", displayName: "Offline fixture", revision: 1,
            residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        do {
            let result = try await service.send("WISH_CHAIN_MARKER Find a reference and make a red chair.", worldContext: world, worldTools: tools)
            check(result.contains("WISH_REFERENCE_CHAIN_FINAL_OK"), "same send reaches final after three host results: \(result)")
        } catch { check(false, "send error: \(error)") }
        check(calls == names, "exact canonical execution order search → register → submit; got \(calls)")
        let requestFile = ProcessInfo.processInfo.environment["REQUESTS_FILE"]!
        let lines = try String(contentsOfFile: requestFile, encoding: .utf8).split(separator: "\n")
        let bodies = lines.compactMap { line -> [String: Any]? in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["body"] as? [String: Any]
        }
        let toolRequests = bodies.filter { ($0["tools"] as? [[String: Any]] ?? []).contains { (($0["function"] as? [String: Any])?["name"] as? String)?.hasPrefix("gmgn_") == true } }
        check(toolRequests.count == 4, "provider sees initial + three result continuations")
        for (index, body) in toolRequests.enumerated() {
            let functions = (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["function"] as? [String: Any] }
            for (offset, name) in names.enumerated() {
                let schema = functions.first { $0["name"] as? String == "gmgn_" + name }
                check(schema != nil, "request \(index) exposes public schema gmgn_\(name)")
                let required = (schema?["parameters"] as? [String: Any])?["required"] as? [String] ?? []
                check(Set(required) == Set(properties[offset].keys), "public schema preserves canonical required arguments for \(name)")
            }
        }
        let messages = toolRequests.last?["messages"] as? [[String: Any]] ?? []
        check(messages.filter { $0["role"] as? String == "tool" }.count == 3, "all three role=tool results remain in same provider history")
        service.resetSession()
        defaults.removePersistentDomain(forName: suite)
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) wish reference service delivery checks; \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
"""#
let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-j1", "-parse-as-library"] + [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport",
    "ResidentCodexPolicy", "ResidentCodexAgent", "ResidentSteeringDelivery",
    "ResidentDSHTransport", "ResidentDSHConfiguration", "ResidentStateClient",
    "ResidentMemoryClient", "ResidentConversationMemory",
    "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner",
].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path
} + [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    main.path, "-o", binary.path,
]
compile.currentDirectoryURL = work
try compile.run()
let compileDeadline = Date().addingTimeInterval(240)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: service native-assembly compile exceeded 240s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    try? FileManager.default.removeItem(at: work)
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    exit(compile.terminationStatus)
}
let test = Process()
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(300)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if test.isRunning {
    test.terminate()
    try? FileManager.default.removeItem(at: work)
    print("FAIL: service native-assembly execution exceeded 300s")
    exit(124)
}
test.waitUntilExit()
try? FileManager.default.removeItem(at: work)
print("service-native assembly exit=\(test.terminationStatus)")
exit(test.terminationStatus)
