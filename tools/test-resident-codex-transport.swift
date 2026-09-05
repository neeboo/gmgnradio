// Compiles the production transport and a tiny local JSONL peer. No model or credentials.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexTransport.swift")
guard FileManager.default.fileExists(atPath: source.path) else {
    print("FAIL: resident bidirectional transport is missing")
    exit(1)
}
let harness = #"""
import Foundation
import Darwin

func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func object(_ bytes: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
func emit(_ value: [String: Any], split: Bool = false) {
    let bytes = data(value) + Data([10])
    if split {
        FileHandle.standardOutput.write(bytes.prefix(3))
        usleep(10_000)
        FileHandle.standardOutput.write(bytes.dropFirst(3))
    } else { FileHandle.standardOutput.write(bytes) }
}
func fake() {
    var initialized = false
    while let line = readLine() {
        let value = object(Data(line.utf8))
        guard let method = value["method"] as? String else {
            if value["id"] as? String == "server-call" {
                emit(["id": 3, "result": ["callback": value["result"] ?? value["error"] ?? [:]]])
            }
            continue
        }
        let id = value["id"] ?? 0
        switch method {
        case "initialize":
            let params = value["params"] as? [String: Any]
            let capabilities = params?["capabilities"] as? [String: Any]
            if capabilities?["experimentalApi"] as? Bool == true {
                emit(["id": id, "result": [:]])
            } else { emit(["id": id, "error": ["code": -32602]]) }
        case "initialized": initialized = true
        case "echo":
            guard initialized else { exit(2) }
            FileHandle.standardError.write(Data("private-stderr-DO-NOT-RETURN\n".utf8))
            emit(["method": "turn/progress", "params": ["ok": true]], split: true)
            emit(["id": id, "result": value["params"] ?? [:]], split: true)
        case "callback", "approval":
            emit(["id": "server-call", "method": method == "callback" ? "item/tool/call" : "item/permissions/requestApproval", "params": ["tool": "inspect_world"]])
        case "failure": emit(["id": id, "error": ["code": -32000, "message": "private-server-DO-NOT-RETURN"]])
        case "exit": exit(0)
        case "malformed": FileHandle.standardOutput.write(Data("not-json\n".utf8))
        case "oversized": FileHandle.standardOutput.write(Data(repeating: 65, count: 1_100_000))
        case "hang": break
        case "ignoreTermination": signal(SIGTERM, SIG_IGN)
        case "stopReading":
            emit(["id": id, "result": [:]])
            sleep(3)
        default: break
        }
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--fake") { fake(); return }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: " + message) }
            checks += 1
        }
        func transport(_ timeout: TimeInterval = 2) -> ResidentCodexTransport {
            ResidentCodexTransport(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["--fake"], currentDirectoryURL: nil, environment: [:], requestTimeout: timeout)
        }
        func stopped(_ pid: Int32) async -> Bool {
            for _ in 0..<100 {
                if kill(pid, 0) != 0 { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
        let client = transport()
        var notificationCount = 0
        client.onNotification = { method, payload in
            if method == "turn/progress", object(payload)["ok"] as? Bool == true { notificationCount += 1 }
        }
        client.onServerRequest = { method, payload in
            check(method == "item/tool/call", "only formal tool callback")
            check(object(payload)["tool"] as? String == "inspect_world", "callback params")
            return data(["success": true, "contentItems": []])
        }
        try await client.start()
        let pid = client.processIdentifier!
        let echoed = try await client.request(method: "echo", params: data(["hello": "room"]))
        check(object(echoed)["hello"] as? String == "room", "fragmented response and stderr isolation")
        check(notificationCount == 1, "notification delivered")
        let callback = try await client.request(method: "callback", params: data([:]))
        check((object(callback)["callback"] as? [String: Any])?["success"] as? Bool == true, "formal callback result")
        client.close()
        check(await stopped(pid), "close terminates owned process")

        let denied = transport()
        var unexpectedCallback = false
        denied.onServerRequest = { _, _ in unexpectedCallback = true; return data(["approved": true]) }
        try await denied.start()
        _ = try await denied.request(method: "echo", params: data([:]))
        let rejection = try await denied.request(method: "approval", params: data([:]))
        check(!unexpectedCallback, "approval never reaches application callback")
        check((object(rejection)["callback"] as? [String: Any])?["code"] as? Int == -32601, "unknown server request rejected")
        denied.close()

        for method in ["failure", "exit", "malformed", "oversized", "hang"] {
            let failureClient = transport(0.15)
            try await failureClient.start()
            let failurePID = failureClient.processIdentifier!
            do {
                _ = try await failureClient.request(method: method, params: data([:]))
                fatalError("FAIL: \(method) must fail")
            } catch {
                check(!String(describing: error).contains("DO-NOT-RETURN"), "errors exclude peer private text")
            }
            failureClient.close()
            check(await stopped(failurePID), "\(method) ends process")
        }
        let canceled = transport()
        try await canceled.start()
        let cancelPID = canceled.processIdentifier!
        let waiting = Task { try await canceled.request(method: "hang", params: data([:])) }
        try await Task.sleep(nanoseconds: 30_000_000)
        waiting.cancel()
        do { _ = try await waiting.value; fatalError("FAIL: cancellation") }
        catch { check(error is CancellationError, "cancellation propagated") }
        check(await stopped(cancelPID), "cancel terminates owned process")
        let concurrent = transport()
        try await concurrent.start()
        let first = Task { try await concurrent.request(method: "hang", params: data([:])) }
        let second = Task { try await concurrent.request(method: "hang", params: data([:])) }
        try await Task.sleep(nanoseconds: 30_000_000)
        first.cancel()
        for waiting in [first, second] {
            do { _ = try await waiting.value; fatalError("FAIL: pending request survived cancellation") }
            catch { check(error is CancellationError, "all pending requests finish on cancellation") }
        }
        let resistant = transport(0.1)
        try await resistant.start()
        let resistantPID = resistant.processIdentifier!
        do { _ = try await resistant.request(method: "ignoreTermination", params: data([:])); fatalError("FAIL: timeout") }
        catch { check(error is ResidentCodexTransportError, "timeout throws typed error") }
        check(await stopped(resistantPID), "cleanup escalates only owned resistant process")
        let blockedWriter = transport(0.1)
        try await blockedWriter.start()
        _ = try await blockedWriter.request(method: "stopReading", params: data([:]))
        let writeStarted = Date()
        do {
            _ = try await blockedWriter.request(method: "echo", params: data(["large": String(repeating: "a", count: 200_000)]))
            fatalError("FAIL: stalled reader must timeout")
        } catch { check(Date().timeIntervalSince(writeStarted) < 1, "stalled stdin never blocks main actor or timeout") }
        blockedWriter.close()
        print("PASS: \(checks) resident transport checks")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-transport-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let fixture = temporary.appendingPathComponent("Checks.swift")
try harness.write(to: fixture, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", source.path, fixture.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit()
exit(test.terminationStatus)
