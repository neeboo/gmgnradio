// Resident system inbox storage adapter over the REAL gmgn-taskd helper
// process (temporary root + Unix socket, offline). Covers: restore of empty
// scopes, durable create/update with CAS revisions, unchanged-content
// commits skipped by fingerprint, read state + original timestamps preserved
// across a daemon restart, idempotent read-only import of a legacy
// ResidentSystemInbox.json fixture, visible revision_conflict on a stale
// writer, scope isolation, and the store-level durable-then-success flow
// including a daemon outage. Every wait is bounded; nothing outside its own
// temporary directories is touched.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-inbox-\(UUID())")
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
enum FakeError: Error { case message(String) }

let work: URL = {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-resident-inbox-harness-\(UUID())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

let binaryPath = ProcessInfo.processInfo.environment["TASKD_BIN"]
    ?? "services/gmgn-taskd/target/debug/gmgn-taskd"

// MARK: - 真实 daemon 与 socket 运输

final class TaskdProcess {
    let root: String
    let socketPath: String
    private var process: Process?
    init(root: String) { self.root = root; self.socketPath = root + "/taskd.sock" }
    func start() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
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
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                _ = socketPath.withCString { bytes in
                    memcpy(&address.sun_path, bytes, min(strlen(bytes), MemoryLayout.size(ofValue: address.sun_path) - 1))
                }
                let ok = Darwin.connect(fd, withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                }, socklen_t(MemoryLayout<sockaddr_un>.size))
                Darwin.close(fd)
                if ok == 0 { ready = true; break }
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
        var frame = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        frame.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let line = try Self.roundTrip(socketPath: self.socketPath, frame: frame)
                    let envelope = try JSONDecoder().decode(Envelope.self, from: line)
                    if let error = envelope.error { throw ResidentStateError.daemon(error.code) }
                    guard let result = envelope.result else { throw ResidentStateError.invalidResponse }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private nonisolated static func roundTrip(socketPath: String, frame: Data) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FakeError.message("socket() failed") }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { bytes in
            memcpy(&address.sun_path, bytes, min(strlen(bytes), MemoryLayout.size(ofValue: address.sun_path) - 1))
        }
        guard Darwin.connect(descriptor, withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else { throw FakeError.message("connect failed") }
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

/// 统计 state_commit 调用次数（验证未变内容跳过提交），不改合同。
@MainActor final class CountingTransport: ResidentStateTransport, @unchecked Sendable {
    let inner: TaskdTransport
    private(set) var commitCalls = 0
    init(inner: TaskdTransport) { self.inner = inner }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        if method == "state_commit" { commitCalls += 1 }
        return try await inner.call(method: method, params: params)
    }
}

// MARK: - 夹具

@MainActor func makeEntry(_ taskKey: String, eventID: String, read: Bool = false,
                          readAt: Date? = nil, deliveredAt: Date, updatedAt: Date) -> ResidentSystemInboxEntry {
    ResidentSystemInboxEntry(taskKey: taskKey, lastEventID: eventID, kind: "wish.task",
        title: "E2E 咖啡机", status: "已摆放", detail: "载入场景失败：网格缺失", terminal: true,
        isRead: read, readAt: readAt, deliveredAt: deliveredAt, updatedAt: updatedAt)
}

@MainActor func storage(_ transport: ResidentStateTransport) -> ResidentSystemInboxStateStorage {
    ResidentSystemInboxStateStorage(client: ResidentStateClient(transport: transport))
}

@MainActor func run() async throws {
    guard FileManager.default.fileExists(atPath: binaryPath) else {
        print("SKIP: gmgn-taskd binary not found at \(binaryPath); set TASKD_BIN (cargo build first)")
        return
    }
    let daemonRoot = "/tmp/gmgn-inbox-\(UUID().uuidString.prefix(8))"
    let daemon = TaskdProcess(root: daemonRoot)
    try daemon.start()
    let socket = TaskdTransport(socketPath: daemon.socketPath)
    defer { try? FileManager.default.removeItem(atPath: daemonRoot) }

    let world = "wish-world"
    let scopeA = ResidentStateScope(worldID: world, residentScope: "resident-a")
    let scopeB = ResidentStateScope(worldID: world, residentScope: "resident-b")
    let scopeC = ResidentStateScope(worldID: world, residentScope: "resident-store")
    let deliveredAt = Date(timeIntervalSince1970: 5_000.5)
    let updatedAt = Date(timeIntervalSince1970: 5_001.25)
    let readAt = Date(timeIntervalSince1970: 5_002.75)

    // 1. 空作用域恢复为 nil（不是错误），随后创建并可靠落库。
    let writer = storage(socket)
    check(try await writer.restore(scope: scopeA) == nil, "an empty scope restores to nil")
    let first = [makeEntry("task-1", eventID: "e1", deliveredAt: deliveredAt, updatedAt: updatedAt)]
    try await writer.persist(scope: scopeA, entries: first)

    // 2. 新实例恢复：条目、已读状态与原时间戳逐字节一致；revision=1。
    let reader = storage(socket)
    let restored = try await reader.restore(scope: scopeA)
    check(restored == first, "restored entries match byte-for-byte, timestamps included")
    let raw = try await ResidentStateClient(transport: socket).stateRead(scope: scopeA, domain: .inbox, key: "entries")
    check(raw?.revision == 1, "the created record sits at revision 1")

    // 3. 同一内容重试复用同一 requestID：后台幂等回放，revision 不重复推进。
    let counting = CountingTransport(inner: socket)
    let counter = storage(counting)
    _ = try await counter.restore(scope: scopeA)
    try await counter.persist(scope: scopeA, entries: first)
    try await counter.persist(scope: scopeA, entries: first)
    check(counting.commitCalls == 2, "both saves really went through the daemon")
    let replayed = try await ResidentStateClient(transport: socket).stateRead(scope: scopeA, domain: .inbox, key: "entries")
    check(replayed?.revision == 2, "the fresh save advanced to 2, the identical retry replayed in place")

    // 4. 已读翻转走真实提交；重启后已读与原时间戳仍在。
    var flipped = first
    flipped[0] = makeEntry("task-1", eventID: "e1", read: true, readAt: readAt,
        deliveredAt: deliveredAt, updatedAt: updatedAt)
    let commitsBeforeFlip = counting.commitCalls
    try await counter.persist(scope: scopeA, entries: flipped)
    check(counting.commitCalls == commitsBeforeFlip + 1, "changed content performs exactly one new commit")
    daemon.stop()
    try daemon.start()
    let afterRestart = try await reader.restore(scope: scopeA)
    check(afterRestart == flipped, "read state and timestamps survive a daemon restart")

    // 5. 陈旧写入者：相同内容按合同回放（绝回滚不了新值）；不同内容 CAS
    //    冲突如实抛出，绝不静默覆盖他人写入。
    try await writer.persist(scope: scopeA, entries: first)
    check(try await reader.restore(scope: scopeA) == flipped,
        "the identical-content replay never overwrote the newer value")
    do {
        var undone = flipped
        undone[0] = makeEntry("task-1", eventID: "e1", read: false,
            deliveredAt: deliveredAt, updatedAt: Date(timeIntervalSince1970: 4_999))
        try await writer.persist(scope: scopeA, entries: undone)
        check(false, "a stale writer's changed-content commit must be rejected")
    } catch ResidentStateError.daemon("revision_conflict") {
        check(true, "a stale writer sees revision_conflict, nothing overwritten")
    }
    check(try await reader.restore(scope: scopeA) == flipped, "the concurrent winner's content is intact")

    // 6. 旧 JSON 归档只读导入：只在无落库记录时导入一次，幂等且不改旧文件。
    let legacyURL = work.appendingPathComponent("ResidentSystemInbox.json")
    let legacyEntriesB = [makeEntry("task-old", eventID: "e0", read: true, readAt: readAt,
        deliveredAt: deliveredAt, updatedAt: updatedAt)]
    let legacyOther = [makeEntry("task-other", eventID: "e9", deliveredAt: deliveredAt, updatedAt: updatedAt)]
    let legacyArchive = ResidentSystemInboxArchive(buckets: [
        .init(scope: ResidentSystemInboxScope(worldID: world, residentScope: scopeB.residentScope),
            entries: legacyEntriesB),
        .init(scope: ResidentSystemInboxScope(worldID: "another-world", residentScope: scopeB.residentScope),
            entries: legacyOther),
    ])
    try JSONEncoder().encode(legacyArchive).write(to: legacyURL)
    let legacyData = try Data(contentsOf: legacyURL)

    let importer = storage(socket)
    check(try await importer.restore(scope: scopeB) == nil, "the import scope has no durable record yet")
    let imported = ResidentSystemInboxStateStorage.legacyEntries(
        from: ResidentSystemInboxStateStorage.legacyArchive(at: legacyURL)!,
        worldID: world, residentScope: scopeB.residentScope)
    check(imported == legacyEntriesB, "the legacy bucket imports with read state and timestamps")
    try await importer.persist(scope: scopeB, entries: imported)
    check(try await reader.restore(scope: scopeB) == legacyEntriesB, "the import landed durably")
    check(try Data(contentsOf: legacyURL) == legacyData, "the legacy file was never rewritten")

    // 6b. 再跑一次导入流程：落库记录优先，旧文件被忽略，无重复、无 revision 虚涨。
    let reimporter = storage(socket)
    let durableAgain = try await reimporter.restore(scope: scopeB)
    check(durableAgain == legacyEntriesB, "the durable record wins over the legacy file")
    if durableAgain == nil {
        try await reimporter.persist(scope: scopeB, entries: imported)
    }
    check(try await reader.restore(scope: scopeB) == legacyEntriesB, "re-import stays idempotent")

    // 6c. 损坏的旧文件导入为空（不抛、不注入）。
    let brokenURL = work.appendingPathComponent("broken.json")
    try Data("not json".utf8).write(to: brokenURL)
    check(ResidentSystemInboxStateStorage.legacyArchive(at: brokenURL) == nil,
        "a corrupted legacy archive imports nothing")

    // 7. 作用域隔离：同 taskKey 在别的 world 互不影响。
    check(try await reader.restore(scope: ResidentStateScope(worldID: "another-world", residentScope: scopeB.residentScope)) == nil,
        "another world's scope stays empty (scope isolation)")

    // 8. store 级集成：apply→durable；断电→已读失败可见；恢复→重试成功。
    let storeStorage = storage(socket)
    let makeStore = {
        ResidentSystemInboxStore(
            restore: { scope in try await storeStorage.restore(scope: ResidentStateScope(
                worldID: scope.worldID, residentScope: scope.residentScope)) },
            persist: { scope, entries in try await storeStorage.persist(scope: ResidentStateScope(
                worldID: scope.worldID, residentScope: scope.residentScope), entries: entries) })
    }
    let store = makeStore()
    let storeDelivery = ResidentSystemDelivery(eventID: "e1", taskID: "task-1", kind: "wish.task",
        title: "E2E 咖啡机", status: "已摆放", detail: "", terminal: true)
    check(await store.apply(storeDelivery, worldID: world, residentScope: scopeC.residentScope),
        "the store's delivery is durably saved")
    let reopened = makeStore()
    await reopened.restore(worldID: world, residentScope: scopeC.residentScope)
    check(reopened.unreadCount(worldID: world, residentScope: scopeC.residentScope) == 1,
        "a fresh store restores the unread delivery")

    daemon.stop()
    check(await reopened.markRead(taskKey: "task-1", worldID: world, residentScope: scopeC.residentScope) == false,
        "a read during an outage is not reported as success")
    check(reopened.persistenceError != nil, "the outage's save failure is visible")
    try daemon.start()
    check(await reopened.apply(storeDelivery, worldID: world, residentScope: scopeC.residentScope),
        "the identical delivery retries the pending save after recovery")
    check(reopened.persistenceError == nil, "the visible error clears on durable success")
    check(await reopened.markRead(taskKey: "task-1", worldID: world, residentScope: scopeC.residentScope) == false,
        "re-reading the already-read entry is a no-op (the flip landed with the retry)")
    let verifier = makeStore()
    await verifier.restore(worldID: world, residentScope: scopeC.residentScope)
    check(verifier.entry(taskKey: "task-1", worldID: world, residentScope: scopeC.residentScope)?.isRead == true,
        "the read state is durable on the daemon, not a background ACK")
}

@main struct Tests {
    @MainActor static func main() async {
        let timeout = DispatchWorkItem {
            print("FAIL: test timed out after 150s")
            exit(42)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: timeout)
        do {
            try await run()
        } catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
        }
        timeout.cancel()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident inbox storage checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInbox.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInboxStateStorage.swift").path,
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
