// ResidentStateClient 与 docs/plans/2026-09-08-resident-storage-contract.md 的
// 直接核对：真实 gmgn-taskd 临时 daemon（明确临时 root/socket，绝不启动用户的
// TaskService）走鉴权 HTTP，覆盖 nested scope、record:null、CAS/revision、
// requestID 幂等（含跨重启回放）、event_read 无 domain、nextCursor 整数水位、
// message_read/ack、跨 scope 隔离；另有只做客户端解析校验的畸形响应用例
// （record 缺字段、item 缺字段、nextCursor 非整数、acknowledged 缺失等一律拒绝，
// 绝不吞错填 null/伪成功），以及 UInt64(exactly:) 转换不再 trap 的用例。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-state-client-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation
import Darwin

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

let binaryPath = ProcessInfo.processInfo.environment["TASKD_BIN"]
    ?? "target/debug/gmgn-taskd"

// MARK: - 真实 daemon 进程与 socket 运输

enum FakeError: Error { case message(String) }

final class HTTPFixtureResult: @unchecked Sendable {
    let lock = NSLock()
    var response: Data?
    var failure: Error?
    func set(_ data: Data) { lock.lock(); response = data; lock.unlock() }
    func set(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
}
private func fixtureRequest(socketPath: String, path: String, body: Data?) throws -> URLRequest {
    struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    let descriptor = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: URL(fileURLWithPath: socketPath)))
    let parts = descriptor.address.split(separator: ":")
    guard descriptor.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
          let port = UInt16(parts[1]), port > 0, let token = UUID(uuidString: descriptor.token),
          token.uuidString.dropFirst(14).first == "4",
          let origin = URL(string: "http://\(descriptor.address)") else { throw FakeError.message("invalid HTTP endpoint") }
    var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 8)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
    if let body {
        guard body.count <= TaskdHTTPTransport.maxBytes else { throw FakeError.message("request exceeds limit") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
    }
    return request
}
final class TaskdProcess {
    let root: String
    let socketPath: String
    private var process: Process?
    init(root: String) { self.root = root; self.socketPath = root + "/taskd.endpoint.json" }
    func start() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--root", root, "--endpoint-file", socketPath, "--concurrency", "2"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            if let request = try? fixtureRequest(socketPath: socketPath, path: "health", body: nil) {
                let semaphore = DispatchSemaphore(value: 0), result = HTTPFixtureResult()
                let transport = TaskdHTTPTransport(streaming: false, receive: { result.set($0) },
                    completion: { error in if let error { result.set(error) }; semaphore.signal() })
                transport.start(request)
                if semaphore.wait(timeout: .now() + 8) != .success { transport.cancel(); throw FakeError.message("health timed out") }
                if let data = result.response,
                   let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   health["version"] as? Int == 2, health["transport"] as? String == "http" { return }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw FakeError.message("daemon did not expose HTTP at \(socketPath)")
    }
    func stop() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil
    }
    deinit { stop() }
}
@MainActor class TaskdTransport: ResidentStateTransport, @unchecked Sendable {
    struct Request: Encodable { let id: String; let method: String; let params: [String: ResidentStateJSON] }
    private struct Envelope: Decodable {
        struct Err: Decodable { let code: String }
        let id: String?
        let result: [String: ResidentStateJSON]?
        let error: Err?
    }
    let socketPath: String
    init(socketPath: String) { self.socketPath = socketPath }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        let id = UUID().uuidString
        let body = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let request = try fixtureRequest(socketPath: socketPath, path: "rpc", body: body)
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let transport = TaskdHTTPTransport(streaming: false, receive: { continuation.resume(returning: $0) },
                completion: { error in if let error { continuation.resume(throwing: error) } })
            transport.start(request)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: response)
        if let error = envelope.error { throw ResidentStateError.daemon(error.code) }
        guard envelope.id == id, let result = envelope.result else { throw ResidentStateError.invalidResponse }
        return result
    }
}

/// 只记录请求并回放预设响应的解析层（畸形响应用例专用——校验客户端解析，
/// 不声称自己是 daemon）。
@MainActor final class StubTransport: ResidentStateTransport, @unchecked Sendable {
    var responses: [[String: ResidentStateJSON]]
    var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var thrown: Error?
    init(_ responses: [[String: ResidentStateJSON]]) { self.responses = responses }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        if let thrown { throw thrown }
        if responses.isEmpty { return ["record": .null] }
        return responses.removeFirst()
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
        if Date() >= deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func scope(_ world: String = "world-a", _ resident: String = "resident-a") -> ResidentStateScope {
    ResidentStateScope(worldID: world, residentScope: resident)
}

func committedFact(_ object: [String: ResidentStateJSON]) -> ResidentStateJSON {
    .object(object)
}

@MainActor func run() async throws {
    guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
        print("SKIP: gmgn-taskd binary not found at \(binaryPath)")
        return
    }
    // daemon root/socket 必须落在工作区内：沙箱只允许派生进程在工作区路径绑定 socket。
    let temporary = FileManager.default.currentDirectoryPath + "/tmp/gmgn-state-client-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: temporary) }
    let daemon = TaskdProcess(root: temporary)
    try daemon.start()
    defer { daemon.stop() }
    let socket = TaskdTransport(socketPath: daemon.socketPath)
    let client = ResidentStateClient(transport: socket)

    // 1. record:null、创建/CAS、requestID 幂等与冲突、revision 是成功提交计数。
    let read0 = try await client.stateRead(scope: scope(), domain: .resident, key: "mood")
    check(read0 == nil, "state_read with no record returns nil (record:null)")
    let created = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 0, requestID: "create-1", value: ["state": .string("content")])
    check(created.revision == 1 && created.replayed == false, "create returns revision 1, replayed false")
    let replay = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 0, requestID: "create-1", value: ["state": .string("content")])
    check(replay.revision == 1 && replay.replayed == true, "same requestID + same content replays the recorded revision")
    var requestConflict = false
    do {
        _ = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
            expectedRevision: 0, requestID: "create-1", value: ["state": .string("different")])
    } catch ResidentStateError.daemon(let code) { requestConflict = code == "request_id_conflict" }
    check(requestConflict, "same requestID with different content -> request_id_conflict")
    var staleConflict = false
    do {
        _ = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
            expectedRevision: 99, requestID: "stale-1", value: ["state": .string("x")])
    } catch ResidentStateError.daemon(let code) { staleConflict = code == "revision_conflict" }
    check(staleConflict, "stale expectedRevision -> revision_conflict")
    var createOverExisting = false
    do {
        _ = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
            expectedRevision: 0, requestID: "recreate-1", value: ["state": .string("x")])
    } catch ResidentStateError.daemon(let code) { createOverExisting = code == "revision_conflict" }
    check(createOverExisting, "expectedRevision 0 over an existing record -> revision_conflict")
    let fresh = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 1, requestID: "fresh-1", value: ["state": .string("content")])
    check(fresh.revision == 2 && fresh.replayed == false,
        "a fresh requestID advances revision even when the value is unchanged")
    let read1 = try await client.stateRead(scope: scope(), domain: .resident, key: "mood")
    check(read1?.revision == 2 && read1?.value["state"]?.stringValue == "content",
        "state_read returns the committed record")

    // 2. event_read：无 domain 参数；整数水位 nextCursor；跨 scope 隔离。
    var eventID = UUID().uuidString.lowercased()
    let withEvents = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 2, requestID: "events-1",
        value: ["state": .string("content")],
        events: [
            ResidentStateFact(id: eventID, kind: "wish.placed", payload: ["at": .number(1)]),
        ])
    check(withEvents.revision == 3, "commit with events advances revision")
    let page1 = try await client.eventRead(scope: scope(), after: 0, limit: 1)
    check(page1.events.count == 1 && page1.events[0].id == eventID, "event_read pages events in order")
    check(page1.nextCursor == page1.events[0].sequence, "nextCursor equals the last event sequence on a full page")
    check(page1.nextCursor >= 0, "nextCursor is a non-negative integer watermark")
    let page2 = try await client.eventRead(scope: scope(), after: page1.nextCursor, limit: 10)
    check(page2.events.isEmpty, "after=nextCursor resumes past the first page")
    check(page2.nextCursor == page1.nextCursor, "empty page nextCursor mirrors the requested after")
    let tail = try await client.eventRead(scope: scope(), after: page2.nextCursor, limit: 10)
    check(tail.events.isEmpty && tail.nextCursor == page2.nextCursor, "empty page keeps the watermark")

    // 3. message_read / message_ack 按 consumer 独立；acknowledged:true 校验。
    var messageID = UUID().uuidString.lowercased()
    let withMessage = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 3, requestID: "msg-1", value: ["state": .string("content")],
        messages: [ResidentStateFact(id: messageID, kind: "wish.outputReady", payload: ["path": .string("model.glb")])])
    check(withMessage.revision == 4, "commit with messages advances revision")
    for consumer in ["world", "ui", "agent"] {
        let read = try await client.messageRead(scope: scope(), consumer: consumer, after: 0, limit: 10)
        check(read.messages.map(\.id) == [messageID], "every consumer sees the unacked message once")
        check(read.nextCursor == read.messages.last?.sequence, "message page nextCursor is the last sequence")
    }
    try await client.messageAck(scope: scope(), consumer: "ui", id: messageID)
    let afterAck = try await client.messageRead(scope: scope(), consumer: "ui", after: 0, limit: 10)
    check(afterAck.messages.isEmpty, "acking clears that one consumer only")
    check(afterAck.nextCursor == 0, "no-data message page nextCursor mirrors after (0)")
    let agentStill = try await client.messageRead(scope: scope(), consumer: "agent", after: 0, limit: 10)
    check(agentStill.messages.map(\.id) == [messageID], "agent still receives the unacked message")
    var missingMessage = false
    do {
        try await client.messageAck(scope: scope("other-world"), consumer: "agent", id: messageID)
    } catch ResidentStateError.daemon(let code) { missingMessage = code == "message_not_found" }
    check(missingMessage, "acking a message outside its scope -> message_not_found")

    // 4. 跨 scope 隔离：同 id 事件不同内容可以分别落库；revision 互不影响。
    eventID = UUID().uuidString.lowercased()
    _ = try await client.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 4, requestID: "scope-a-1",
        value: ["state": .string("content")],
        events: [ResidentStateFact(id: eventID, kind: "wish.placed", payload: ["at": .number(1)])])
    _ = try await client.stateCommit(scope: scope("world-a", "resident-b"), domain: .resident,
        key: "mood", expectedRevision: 0, requestID: "scope-b-1",
        value: ["state": .string("content")],
        events: [ResidentStateFact(id: eventID, kind: "wish.placed", payload: ["at": .number(2)])])
    let eventsA = try await client.eventRead(scope: scope(), after: 0, limit: 500)
    check(eventsA.events.filter { $0.id == eventID }.count == 1, "scope A holds its own event copy")
    let scopeBRecord = try await client.stateRead(scope: scope("world-a", "resident-b"),
        domain: .resident, key: "mood")
    check(scopeBRecord?.revision == 1, "scope B revision advances independently of scope A")

    // 5. 跨重启：进程重开、同一 root，状态/事件/ACK 均保留，幂等回放有效。
    daemon.stop()
    try daemon.start()
    let restarted = ResidentStateClient(transport: TaskdTransport(socketPath: daemon.socketPath))
    let afterRestart = try await restarted.stateRead(scope: scope(), domain: .resident, key: "mood")
    check(afterRestart?.revision == 5, "state survives a daemon restart (4 commits + message commit = revision 5)")
    let replayAcross = try await restarted.stateCommit(scope: scope(), domain: .resident, key: "mood",
        expectedRevision: 0, requestID: "create-1", value: ["state": .string("content")])
    check(replayAcross.replayed == true && replayAcross.revision == 1, "requestID replay works across a restart")
    let eventsAfterRestart = try await restarted.eventRead(scope: scope(), after: 0, limit: 500)
    check(eventsAfterRestart.events.count == 2, "events survive a daemon restart without duplicates")
    let uiAfterRestart = try await restarted.messageRead(scope: scope(), consumer: "ui", after: 0, limit: 10)
    check(uiAfterRestart.messages.isEmpty, "ui ack survives a daemon restart")
    let agentAfterRestart = try await restarted.messageRead(scope: scope(), consumer: "agent", after: 0, limit: 10)
    check(agentAfterRestart.messages.map(\.id) == [messageID], "agent's unacked message survives a restart")

    // 6. 客户端解析校验（畸形响应一律拒绝，不填 null/空值伪成功）。
    let stub = StubTransport([["record": .null]])
    let nilRead = try await ResidentStateClient(transport: stub).stateRead(scope: scope(), domain: .resident, key: "k")
    check(nilRead == nil, "record:null decodes to nil record")
    func expectInvalid<Value>(_ operation: @MainActor () async throws -> Value, _ message: String) async {
        do {
            _ = try await operation()
            check(false, message)
        } catch ResidentStateError.invalidResponse {
            check(true, message)
        } catch {
            check(false, "\(message) (threw \(error))")
        }
    }
    await expectInvalid({
        let t = StubTransport([["record": .object(["revision": .number(1)])]])
        _ = try await ResidentStateClient(transport: t).stateRead(scope: scope(), domain: .resident, key: "k")
    }, "record missing value is rejected")
    await expectInvalid({
        let t = StubTransport([["record": .object(["value": .object([:])])]])
        _ = try await ResidentStateClient(transport: t).stateRead(scope: scope(), domain: .resident, key: "k")
    }, "record missing revision is rejected")
    await expectInvalid({
        let t = StubTransport([["record": .string("not-an-object")]])
        _ = try await ResidentStateClient(transport: t).stateRead(scope: scope(), domain: .resident, key: "k")
    }, "record that is not null/object is rejected")
    await expectInvalid({
        let t = StubTransport([["record": .object(["revision": .bool(true), "value": .object([:])])]])
        _ = try await ResidentStateClient(transport: t).stateRead(scope: scope(), domain: .resident, key: "k")
    }, "revision encoded as a JSON boolean is rejected, not coerced")
    await expectInvalid({
        let t = StubTransport([["record": .object(["revision": .number(Double(UInt64.max)), "value": .object([:])])]])
        _ = try await ResidentStateClient(transport: t).stateRead(scope: scope(), domain: .resident, key: "k")
    }, "revision equal to 2^64 is rejected via UInt64(exactly:) without trapping")
    await expectInvalid({
        let t = StubTransport([["events": .array([.object(["sequence": .number(1), "id": .string("i")])]), "nextCursor": .number(1)]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "event item missing kind is rejected")
    await expectInvalid({
        let t = StubTransport([["events": .array([.object(["sequence": .number(1), "kind": .string("k"), "payload": .object([:])])]), "nextCursor": .number(1)]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "event item missing id is rejected")
    await expectInvalid({
        let t = StubTransport([["events": .array([.object(["sequence": .number(1), "id": .string("i"), "kind": .string("k")])]), "nextCursor": .number(1)]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "event item missing payload is rejected")
    await expectInvalid({
        let t = StubTransport([["events": .array([])]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "event_read missing nextCursor is rejected")
    await expectInvalid({
        let t = StubTransport([["nextCursor": .number(0)]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "event_read missing events is rejected")
    await expectInvalid({
        let t = StubTransport([["events": .array([]), "nextCursor": .string("1")]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "nextCursor that is not a number is rejected")
    await expectInvalid({
        let t = StubTransport([["events": .array([]), "nextCursor": .number(-1)]])
        _ = try await ResidentStateClient(transport: t).eventRead(scope: scope(), after: 0, limit: 10)
    }, "negative nextCursor is rejected")
    await expectInvalid({
        let t = StubTransport([[:]])
        _ = try await ResidentStateClient(transport: t).messageAck(scope: scope(), consumer: "agent", id: "x")
    }, "message_ack without acknowledged:true is rejected, never a silent success")
    await expectInvalid({
        let t = StubTransport([["acknowledged": .bool(false)]])
        _ = try await ResidentStateClient(transport: t).messageAck(scope: scope(), consumer: "agent", id: "x")
    }, "message_ack with acknowledged:false is rejected")
    do {
        let t = StubTransport([["revision": .number(1), "replayed": .bool(false)]])
        let result = try await ResidentStateClient(transport: t).stateCommit(scope: scope(), domain: .resident,
            key: "k", expectedRevision: 0, requestID: "r", value: [:])
        check(result.revision == 1 && result.replayed == false, "well-formed commit result parses")
    } catch { check(false, "well-formed commit result should parse: \(error)") }
    await expectInvalid({
        let t = StubTransport([["revision": .number(1)]])
        _ = try await ResidentStateClient(transport: t).stateCommit(scope: scope(), domain: .resident,
            key: "k", expectedRevision: 0, requestID: "r", value: [:])
    }, "state_commit result missing replayed is rejected")
    await expectInvalid({
        let t = StubTransport([["replayed": .bool(false)]])
        _ = try await ResidentStateClient(transport: t).stateCommit(scope: scope(), domain: .resident,
            key: "k", expectedRevision: 0, requestID: "r", value: [:])
    }, "state_commit result missing revision is rejected")
    await expectInvalid({
        let t = StubTransport([["revision": .bool(true), "replayed": .bool(false)]])
        _ = try await ResidentStateClient(transport: t).stateCommit(scope: scope(), domain: .resident,
            key: "k", expectedRevision: 0, requestID: "r", value: [:])
    }, "state_commit result revision as boolean is rejected")

    // 7. 请求形状：scope 内嵌、event_read 不带 domain。
    do {
        let t = StubTransport([
            ["revision": .number(1), "replayed": .bool(false)],
            ["events": .array([]), "nextCursor": .number(3)],
            ["acknowledged": .bool(true)],
        ])
        let c = ResidentStateClient(transport: t)
        _ = try await c.stateCommit(scope: scope("w", "r"), domain: .resident, key: "mood",
            expectedRevision: 0, requestID: "id-1", value: ["v": .number(1)])
        let params = t.recorded[0].params
        guard case .object(let scopeObject) = params["scope"] else { check(false, "scope is nested object"); return }
        check(scopeObject["worldID"]?.stringValue == "w" && scopeObject["residentScope"]?.stringValue == "r",
            "scope is nested with worldID/residentScope")
        check(params["worldID"] == nil && params["residentScope"] == nil, "no top-level scope fields leak")
        check(params["domain"]?.stringValue == "resident" && params["key"]?.stringValue == "mood",
            "domain/key ride alongside the nested scope")
        _ = try await c.eventRead(scope: scope("w", "r"), after: 3, limit: 5)
        let eventParams = t.recorded[1].params
        check(eventParams["domain"] == nil, "event_read never carries a domain")
        check(eventParams["after"]?.doubleValue == 3 && eventParams["limit"]?.doubleValue == 5,
            "event_read carries integer after/limit")
        _ = try await c.messageAck(scope: scope("w", "r"), consumer: "agent", id: "abc")
        let ackParams = t.recorded[2].params
        check(ackParams["consumer"]?.stringValue == "agent" && ackParams["id"]?.stringValue == "abc",
            "message_ack carries consumer and id")
    }

    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident state client checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

@main struct Tests {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
            print("FAIL: \(checks) resident state client checks, \(failures) failures")
            exit(1)
        }
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift").path,
    main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
