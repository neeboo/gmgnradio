// Hostless checks for the App's shared gmgn-taskd state transport
// (ResidentTaskDaemonStateTransport). Compiles and RUNS the shipping sources
// and asserts the exact one-line Codable roundtrips preserve real JSON
// semantics (0/1 stay numbers, true/false stay bools, null/string/array/
// nested objects survive both directions), that contract-shaped state_commit
// params convert as the daemon expects, and that client failures propagate
// untouched instead of being masked as conversion errors.
//
// Run:  swift tools/test-resident-task-daemon-transport.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-task-transport-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}
func propObject(_ value: PropTaskJSON?) -> [String: PropTaskJSON]? {
    if case let .object(object) = value ?? .null { return object }
    return nil
}
func propBool(_ value: PropTaskJSON?) -> Bool? {
    if case let .bool(bool) = value ?? .null { return bool }
    return nil
}
func propDouble(_ value: PropTaskJSON?) -> Double? {
    if case let .number(number) = value ?? .null { return number }
    return nil
}

@MainActor @main struct Tests {
    static func main() async {
        // 1. ResidentStateJSON → PropTaskJSON keeps exact JSON semantics.
        let source: ResidentStateJSON = .object([
            "string": .string("resident.pmx"),
            "zero": .number(0),
            "one": .number(1),
            "negative": .number(-2.5),
            "trueValue": .bool(true),
            "falseValue": .bool(false),
            "nullValue": .null,
            "array": .array([.string("a"), .number(3), .bool(false), .null]),
            "nested": .object(["worldID": .string("world.marble-living-cabin"),
                "residentScope": .string("resident.world.cabin"),
                "deep": .object(["revision": .number(7)])]),
        ])
        let converted = try? ResidentTaskDaemonStateTransport.propTaskJSON(source)
        check(converted == .object([
            "string": .string("resident.pmx"),
            "zero": .number(0),
            "one": .number(1),
            "negative": .number(-2.5),
            "trueValue": .bool(true),
            "falseValue": .bool(false),
            "nullValue": .null,
            "array": .array([.string("a"), .number(3), .bool(false), .null]),
            "nested": .object(["worldID": .string("world.marble-living-cabin"),
                "residentScope": .string("resident.world.cabin"),
                "deep": .object(["revision": .number(7)])]),
        ]), "the outbound conversion preserves the full typed tree")
        check(propBool(propObject(converted)?["one"]) == nil,
            "the number 1 is never coerced into a bool")
        check(propBool(propObject(converted)?["zero"]) == nil,
            "the number 0 is never coerced into a bool")
        check(propDouble(propObject(converted)?["trueValue"]) == nil,
            "true is never coerced into a number")

        // 2. Scalars themselves (top-level params can be scalar trees per key).
        for (value, label) in [(ResidentStateJSON.string("s"), "string"),
                               (ResidentStateJSON.number(0), "number 0"),
                               (ResidentStateJSON.bool(true), "bool"),
                               (ResidentStateJSON.null, "null")] {
            check((try? ResidentTaskDaemonStateTransport.propTaskJSON(value)) != nil,
                "a top-level \(label) value converts without dictionary shaping")
        }

        // 3. PropTaskJSON → ResidentStateJSON reverse roundtrip.
        let daemonValue: PropTaskJSON = .object([
            "record": .null,
            "revision": .number(12),
            "replayed": .bool(false),
            "nextCursor": .number(0),
            "events": .array([.object(["sequence": .number(4), "id": .string("evt"),
                "kind": .string("room.layout.changed"),
                "payload": .object(["surface": .string("desk")])])]),
        ])
        let restored = try? ResidentTaskDaemonStateTransport.residentStateJSON(daemonValue)
        check(restored == .object([
            "record": .null,
            "revision": .number(12),
            "replayed": .bool(false),
            "nextCursor": .number(0),
            "events": .array([.object(["sequence": .number(4), "id": .string("evt"),
                "kind": .string("room.layout.changed"),
                "payload": .object(["surface": .string("desk")])])]),
        ]), "the inbound conversion preserves the daemon tree")
        check(restored?.objectValue?["nextCursor"]?.boolValue == nil,
            "nextCursor 0 stays a numeric watermark, never false")
        check(restored?.objectValue?["replayed"]?.boolValue == false,
            "replayed stays a real bool")

        // 4. Contract-shaped state_commit params (scope as the unified nested
        //    object, exactly what ResidentStateClient submits) convert cleanly.
        let scope = ResidentStateScope(worldID: "world.marble-living-cabin",
            residentScope: "resident.world.cabin")
        let params: [String: ResidentStateJSON] = [
            "scope": scope.nestedParam,
            "domain": .string("resident"),
            "key": .string("intent"),
            "expectedRevision": .number(3),
            "requestID": .string("req-1"),
            "value": .object(["summary": .string("去点唱机"), "status": .string("active")]),
            "events": .array([.object(["id": .string("e1"), "kind": .string("wake"),
                "payload": .object(["reason": .string("outputReady")])])]),
        ]
        var outbound: [String: PropTaskJSON] = [:]
        var allConverted = true
        for (key, item) in params {
            guard let convertedItem = try? ResidentTaskDaemonStateTransport.propTaskJSON(item) else {
                allConverted = false
                break
            }
            outbound[key] = convertedItem
        }
        check(allConverted, "every state_commit param converts")
        check(outbound["scope"] == .object(["worldID": .string("world.marble-living-cabin"),
            "residentScope": .string("resident.world.cabin")]),
            "the scope travels as the unified nested object")
        check(outbound["expectedRevision"] == .number(3),
            "expectedRevision stays an integer number")

        // 5. Client failures propagate untouched: an unavailable HTTP endpoint
        //    surfaces as the daemon error itself, never as a conversion error.
        let scratch = URL(fileURLWithPath: "\#(work.path)")
        let missingEndpointFile = scratch.appendingPathComponent("missing").appendingPathComponent("taskd.endpoint.json")
        let client = PropTaskDaemonClient(root: scratch.appendingPathComponent("root"),
            endpointFileURL: missingEndpointFile, allowsLaunching: false, requestTimeout: 1)
        let transport = ResidentTaskDaemonStateTransport(client: client)
        var propagated: Error?
        do {
            _ = try await transport.call(method: "state_read", params: [
                "scope": scope.nestedParam, "domain": .string("resident"), "key": .string("intent"),
            ])
        } catch { propagated = error }
        check(propagated != nil, "an unconnectable daemon fails the call")
        if case PropTaskDaemonError.unavailable = propagated! {
            check(true, "the daemon error passes through unchanged")
        } else if case ResidentStateError.invalidResponse = propagated! {
            check(false, "a connection failure is never disguised as a conversion error")
        } else {
            check(false, "unexpected error type: \(propagated!)")
        }

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident task daemon transport checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compiled = ["Presence/PropGenerationClient.swift", "Presence/PropGenerationStore.swift",
    "Presence/PropImagePreparation.swift", "Presence/PropTaskDaemonClient.swift", "Presence/TaskdHTTPTransport.swift",
    "Agent/ResidentStateClient.swift",
    "Presence/ResidentTaskDaemonStateTransport.swift"].map { sources.appendingPathComponent($0).path }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-parse-as-library", "-j1"] + compiled + [main.path, "-o", binary.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let test = Process()
test.executableURL = URL(fileURLWithPath: binary.path)
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
