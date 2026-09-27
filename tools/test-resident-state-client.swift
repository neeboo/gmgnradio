// ResidentStateClient 与 docs/plans/2026-09-08-resident-storage-contract.md 的
// 直接核对：真实 gmgn-taskd 临时 daemon（明确临时 root/socket，绝不启动用户的
// TaskService）走 Unix socket，覆盖 nested scope、record:null、CAS/revision、
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
    ?? "services/gmgn-taskd/target/debug/gmgn-taskd"

// MARK: - 真实 daemon 进程与 socket 运输

final class TaskdProcess {
    let root: String
    let socketPath: String
    private var process: Process?
    init(root: String) {
        self.root = root
        self.socketPath = root + "/taskd.sock"
    }
    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--root", root, "--socket", socketPath, "--concurrency", "2"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        var ready = false
        for _ in 0..<500 {
            if process.isRunning == false { break }
            if FileManager.default.fileExists(atPath: socketPath) {
                let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                if probe >= 0 {
                    var address = sockaddr_un()
                    address.sun_family = sa_family_t(AF_UNIX)
                    _ = socketPath.withCString { bytes in
                        memcpy(&address.sun_path, bytes, min(strlen(bytes), MemoryLayout.size(ofValue: address.sun_path) - 1))
                    }
                    let ok = Darwin.connect(probe, withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, socklen_t(MemoryLayout<sockaddr_un>.size))
                    Darwin.close(probe)
                    if ok == 0 { ready = true; break }
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard ready else { throw FakeError.message("daemon did not expose socket at \(socketPath)") }
    }
    func stop() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil
    }
    deinit { stop() }
}

enum FakeError: Error { case message(String) }

/// 每次 call 一条独立 Unix socket 连接，I/O 放到后台队列，MainActor 让出等待：
/// 与真实 daemon 逐条往返，不改动合同形状。
@MainActor final class TaskdTransport: ResidentStateTransport, @unchecked Sendable {
    struct Request: Encodable { let id: String; let method: String; let params: [String: ResidentStateJSON] }
    private struct Envelope: Decodable {
        struct Err: Decodable { let code: String }
        let result: [String: ResidentStateJSON]?
        let error: Err?
    }
    let socketPath: String

    init(socketPath: String) { self.socketPath = socketPath }

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        let id = UUID().uuidString
        var request = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        request.append(10)  // 一帧一行 JSON，Unix socket 以换行分帧
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let line = try Self.roundTrip(socketPath: self.socketPath, frame: request)
                    let envelope = try JSONDecoder().decode(Envelope.self, from: line)
                    if let error = envelope.error { throw ResidentStateError.daemon(error.code) }
                    guard let result = envelope.result else { throw ResidentStateError.invalidResponse }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func roundTrip(socketPath: String, frame: Data) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FakeError.message("socket() failed") }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { bytes in
            memcpy(&address.sun_path, bytes, min(strlen(bytes), MemoryLayout.size(ofValue: address.sun_path) - 1))
        }
        let connected = Darwin.connect(descriptor, withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, socklen_t(MemoryLayout<sockaddr_un>.size))
        guard connected == 0 else { throw FakeError.message("connect to \(socketPath) failed") }
        var sent = 0
        while sent < frame.count {
            let written = frame.withUnsafeBytes { raw in
                Darwin.send(descriptor, raw.baseAddress!.advanced(by: sent), frame.count - sent, 0)
            }
            guard written > 0 else { throw FakeError.message("send failed") }
            sent += written
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let received = Darwin.recv(descriptor, &chunk, chunk.count, 0)
            if received <= 0 { throw FakeError.message("recv ended before newline") }
            buffer.append(contentsOf: chunk[..<received])
            if buffer.contains(10) { break }
            if buffer.count > 8 * 1024 * 1024 { throw FakeError.message("frame too large") }
        }
        guard let newline = buffer.firstIndex(of: 10) else { throw FakeError.message("no newline") }
        return buffer[..<newline]
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
    main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
