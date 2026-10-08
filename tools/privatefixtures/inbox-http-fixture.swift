import Foundation
import Darwin
enum InboxFixtureError: Error { case unavailable, missingBinary, timeout, verification(String), lostReceipt }
// Transport shim only; the real daemon supplies every state and error.
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    let endpointFile: String
    let timeout: TimeInterval
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: TimeInterval) {
        precondition(!allowsLaunching); self.endpointFile = endpointFile; self.timeout = timeout
    }
    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        struct Endpoint: Decodable { let version: Int; let address, token: String }
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: URL(fileURLWithPath: endpointFile)))
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1", UInt16(parts[1]) != nil,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4" else { throw InboxFixtureError.unavailable }
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: "http://" + endpoint.address + "/rpc")!, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = InboxHTTPResponse()
        let transport = TaskdHTTPTransport(streaming: false, receive: { response.receive($0) }, completion: { response.finish($0) })
        transport.start(request); defer { transport.cancel() }
        let data = try response.wait(timeout: timeout)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any], envelope["id"] as? String == id else { throw ResidentStateError.invalidResponse }
        if let error = envelope["error"] as? [String: Any], let code = error["code"] as? String { throw ResidentStateError.daemon(code) }
        guard let result = envelope["result"] as? [String: Any] else { throw ResidentStateError.invalidResponse }; return result
    }
}
private final class InboxHTTPResponse: @unchecked Sendable {
    private let condition = NSCondition()
    private var data: Data?, error: Error?
    private var done = false
    func receive(_ data: Data) { condition.lock(); self.data = data; condition.unlock() }
    func finish(_ error: Error?) { condition.lock(); self.error = error; done = true; condition.broadcast(); condition.unlock() }
    func wait(timeout: TimeInterval) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !done { if !condition.wait(until: deadline) { throw InboxFixtureError.timeout } }
        if let error { throw error }; guard let data else { throw InboxFixtureError.unavailable }; return data
    }
}
@MainActor final class InboxHTTPFixture {
    let root = URL(fileURLWithPath: "/private/tmp/gmgn-inbox-private-" + UUID().uuidString)
    private var process: Process?
    let binary: String
    var loseNextMutationReceipt = false
    private(set) var mutationCalls = 0
    init() throws {
        guard let binary = ProcessInfo.processInfo.environment["TASKD_BIN"], binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary) else { throw InboxFixtureError.missingBinary }
        self.binary = binary
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func start() async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--root", root.path, "--endpoint-file", root.appendingPathComponent("taskd.endpoint.json").path, "--concurrency", "1"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        try process.run(); self.process = process
        FileHandle.standardOutput.write(Data("ownedPID: \(process.processIdentifier), inheritedPG: \(getpgid(process.processIdentifier)), receiptRoot: \(root.path)\n".utf8))
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            if (try? await raw("inbox_control_read", params: ["scope": ["worldID": "readiness", "residentScope": "private"]])) != nil { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        stop(); throw InboxFixtureError.unavailable
    }
    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate(); let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit()
        }
        FileHandle.standardOutput.write(Data("ownedPID cleanup: \(process.processIdentifier), exit=\(process.terminationStatus)\n".utf8)); self.process = nil
    }
    func cleanup() {
        stop(); try? FileManager.default.removeItem(at: root)
        FileHandle.standardOutput.write(Data("ownedRoot cleanup: \(root.path), absent=\(!FileManager.default.fileExists(atPath: root.path))\n".utf8))
    }
    func raw(_ method: String, params: [String: Any]) async throws -> Data {
        let transport = TaskdHTTPAuthorityClient(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path, helperPath: binary, allowsLaunching: false, timeout: 3)
        let encoded = try JSONSerialization.data(withJSONObject: params)
        return try await Task.detached {
            let params = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }.value
    }
    func client() -> RustInboxClient {
        RustInboxClient(call: { [self] method, data in
            let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let result = try await raw(method, params: params)
            if method != "inbox_control_read" {
                mutationCalls += 1
                if loseNextMutationReceipt { loseNextMutationReceipt = false; throw InboxFixtureError.lostReceipt }
            }
            return result
        })
    }
    func sqlite(_ query: String) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", root.appendingPathComponent("tasks.sqlite3").path, query]; process.standardOutput = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InboxFixtureError.verification("SQLite read failed") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
@MainActor func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw InboxFixtureError.verification(message) }
}
func fixtureDelivery(_ event: String = "event", task: String = "task", title: String = "Ready", terminal: Bool = true) -> ResidentSystemDelivery {
    .init(eventID: event, taskID: task, kind: "completed", title: title, status: "ready", detail: "Detail", terminal: terminal)
}
