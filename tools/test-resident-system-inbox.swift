// Hostless red/green checks for the resident system inbox store: pure clock,
// in-memory persistence closures. No app, no AppKit, no daemon, no user data.
// Covers: 30s terminal prompt window, explicit read state, scope isolation,
// durable-then-success semantics, visible save failures with explicit retry,
// and restore (including the legacy-import create) without clobbering a
// scope that still has unsaved failures.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = #"""
import Foundation
import Combine

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

enum FakeError: Error { case disk }

struct TestClock {
    var time: Date
    var now: Date { time }
    mutating func advance(_ seconds: TimeInterval) {
        time = time.addingTimeInterval(seconds)
    }
}

/// 可编程假存储：模拟磁盘成功/失败与重启（新 store 从已保存内容恢复）。
@MainActor final class FakeStorage {
    var saved: [ResidentSystemInboxScope: [ResidentSystemInboxEntry]] = [:]
    var failPersist = false
    var failRestore = false
    private(set) var persistCalls = 0

    func entries(for scope: ResidentSystemInboxScope) -> [ResidentSystemInboxEntry]? {
        saved[scope]
    }
    func persist(_ scope: ResidentSystemInboxScope, _ entries: [ResidentSystemInboxEntry]) throws {
        persistCalls += 1
        if failPersist { throw FakeError.disk }
        saved[scope] = entries
    }
    func restore(_ scope: ResidentSystemInboxScope) throws -> [ResidentSystemInboxEntry]? {
        if failRestore { throw FakeError.disk }
        return saved[scope]
    }
}

@MainActor
func makeStore(_ clock: @escaping () -> Date, storage: FakeStorage) -> ResidentSystemInboxStore {
    ResidentSystemInboxStore(
        clock: clock,
        restore: { scope in try storage.restore(scope) },
        persist: { scope, entries in try storage.persist(scope, entries) })
}

@MainActor
private func delivery(_ eventID: String, _ taskID: String, status: String,
                      terminal: Bool, detail: String = "") -> ResidentSystemDelivery {
    ResidentSystemDelivery(eventID: eventID, taskID: taskID, kind: "wish.test",
        title: "E2E 咖啡机", status: status, detail: detail, terminal: terminal)
}

@MainActor func run() async {
    var clock = TestClock(time: Date(timeIntervalSince1970: 5_000))
    let storage = FakeStorage()
    let store = makeStore({ clock.now }, storage: storage)
    let world = "wish-world"
    let scope = "resident.scope"

    // 1. Terminal prompt lives 30s from the actual state change, then hides.
    check(await store.apply(delivery("e1", "task-1", status: "已摆放", terminal: true),
        worldID: world, residentScope: scope), "a fresh delivery is durably saved")
    check(store.visibleEntries(worldID: world, residentScope: scope).count == 1,
        "a fresh terminal prompt is visible")
    clock.advance(29)
    check(store.visibleEntries(worldID: world, residentScope: scope).count == 1,
        "still visible at 29s")
    clock.advance(2)
    check(store.visibleEntries(worldID: world, residentScope: scope).isEmpty,
        "hidden after 30s")

    // 2. Repeated refresh / duplicate delivery never re-anchors the clock and
    //    never spends a persistence round trip on unchanged content.
    let commitsBefore = storage.persistCalls
    check(await store.apply(delivery("e1", "task-1", status: "已摆放", terminal: true),
        worldID: world, residentScope: scope) == false,
        "an identical delivery reports no new state")
    check(await store.apply(delivery("e2-copy", "task-1", status: "已摆放", terminal: true),
        worldID: world, residentScope: scope) == false,
        "an identical re-projection reports no new state")
    check(storage.persistCalls == commitsBefore,
        "unchanged deliveries do not touch persistence")
    for _ in 0..<3 { _ = store.visibleEntries(worldID: world, residentScope: scope) }
    check(store.visibleEntries(worldID: world, residentScope: scope).isEmpty,
        "duplicate or identical deliveries do not extend the 30s window")

    // 3. Non-terminal prompts persist regardless of age.
    check(await store.apply(delivery("e3", "task-2", status: "生成中", terminal: false),
        worldID: world, residentScope: scope), "the in-progress delivery is saved")
    clock.advance(3_600)
    check(store.visibleEntries(worldID: world, residentScope: scope).count == 1,
        "an in-progress prompt stays visible")
    check(store.entries(worldID: world, residentScope: scope).count == 2,
        "the expired terminal record is retained in history")

    // 4. Expired but unread still drives the badge and the list.
    check(store.unreadCount(worldID: world, residentScope: scope) == 2,
        "both records stay unread until explicitly opened")

    // 5. Explicit open marks read; identical re-projection never unreadies it.
    check(await store.markRead(taskKey: "task-1", worldID: world, residentScope: scope),
        "opening a message durably marks it read")
    check(await store.apply(delivery("e4-copy", "task-1", status: "已摆放", terminal: true),
        worldID: world, residentScope: scope) == false,
        "identical re-projection after read is a no-op")
    check(store.unreadCount(worldID: world, residentScope: scope) == 1,
        "explicit read survives identical re-projection")

    // 6. A new actual state merges in place and flips read back to unread,
    //    re-anchoring the prompt clock.
    check(await store.apply(delivery("e5", "task-1", status: "已摆放", terminal: true, detail: "载入场景失败：网格缺失"),
        worldID: world, residentScope: scope),
        "the genuinely new state is saved")
    check(store.unreadCount(worldID: world, residentScope: scope) == 2,
        "a genuinely new state becomes unread again")
    let entry = store.entries(worldID: world, residentScope: scope).first { $0.taskKey == "task-1" }
    check(entry?.status == "已摆放" && entry?.detail == "载入场景失败：网格缺失",
        "the merged entry carries the latest content")
    check(store.visibleEntries(worldID: world, residentScope: scope).contains { $0.taskKey == "task-1" },
        "the new terminal state prompts again")

    // 6b. One explicitly read record exists before the restart so read-state
    //     persistence has a real sample: task-2 is opened and stays read.
    check(await store.markRead(taskKey: "task-2", worldID: world, residentScope: scope),
        "opening the second message marks it read")
    check(store.unreadCount(worldID: world, residentScope: scope) == 1,
        "only the re-flagged task remains unread before the restart")

    // 7. Persistence restores history, read state and the prompt clock.
    let restoredStore = makeStore({ clock.now }, storage: storage)
    await restoredStore.restore(worldID: world, residentScope: scope)
    check(restoredStore.entries(worldID: world, residentScope: scope).count == 2,
        "history survives a restart")
    check(restoredStore.unreadCount(worldID: world, residentScope: scope) == 1,
        "read state survives a restart")
    check(restoredStore.entries(worldID: world, residentScope: scope)
        .first { $0.taskKey == "task-2" }?.isRead == true,
        "the opened task is still read after the restart")
    check(restoredStore.visibleEntries(worldID: world, residentScope: scope).contains { $0.taskKey == "task-1" },
        "the restored prompt clock is not reset")
    let anchor = entry?.updatedAt
    let restoredAnchor = restoredStore.entries(worldID: world, residentScope: scope)
        .first { $0.taskKey == "task-1" }?.updatedAt
    check(anchor == restoredAnchor, "the prompt anchor is preserved byte-for-byte")

    // 8. world + residentScope isolation: identical task keys stay independent.
    check(await store.apply(delivery("e9", "task-1", status: "生成中", terminal: false),
        worldID: "other-world", residentScope: scope), "the other world's delivery is saved")
    check(await store.apply(delivery("e10", "task-1", status: "生成中", terminal: false),
        worldID: world, residentScope: "other-scope"), "the other scope's delivery is saved")
    check(store.unreadCount(worldID: world, residentScope: scope) == 1,
        "another world's delivery does not touch this scope (task-1 unread, task-2 read)")
    check(store.unreadCount(worldID: "other-world", residentScope: scope) == 1,
        "the other world has its own unread state")
    check(store.unreadCount(worldID: world, residentScope: "other-scope") == 1,
        "another resident scope has its own unread state")

    // 9. Failed saves are visible, never reported as success, and retried by
    //    the next explicit delivery — the retry must not renew the expiry.
    var failDisk = true
    let diskStore = ResidentSystemInboxStore(clock: { clock.now }, persist: { _, _ in
        if failDisk { throw FakeError.disk }
    })
    let diskDelivery = delivery("disk-event", "disk-task", status: "已摆放", terminal: true)
    check(await diskStore.apply(diskDelivery, worldID: world, residentScope: scope) == false,
        "a failed save is not reported as success")
    check(diskStore.persistenceError != nil, "a failed disk write is visible")
    let diskAnchor = diskStore.promptExpiry(taskKey: "disk-task", worldID: world, residentScope: scope)
    check(diskAnchor != nil, "the unsaved terminal prompt still anchors on-screen")
    check(await diskStore.apply(diskDelivery, worldID: world, residentScope: scope) == false,
        "an identical delivery retries the failed save while the sink is broken")
    failDisk = false
    check(await diskStore.apply(diskDelivery, worldID: world, residentScope: scope),
        "the identical delivery's retry succeeds once the sink recovers")
    check(diskStore.persistenceError == nil, "a successful retry clears the visible error")
    check(diskStore.promptExpiry(taskKey: "disk-task", worldID: world, residentScope: scope) == diskAnchor,
        "retrying persistence does not renew expiry")

    // 10. markRead on a missing or already-read entry is a no-op.
    check(await diskStore.markRead(taskKey: "missing", worldID: world, residentScope: scope) == false,
        "reading a missing entry is a no-op")
    check(await diskStore.markRead(taskKey: "disk-task", worldID: world, residentScope: scope),
        "reading the delivered entry durably marks it read")
    check(await diskStore.markRead(taskKey: "disk-task", worldID: world, residentScope: scope) == false,
        "re-reading an entry is a no-op")

    // 11. Restore failures are visible; restore never clobbers a scope whose
    //     saves are still failing (local truth + error win).
    let brokenRestore = ResidentSystemInboxStore(restore: { _ in throw FakeError.disk })
    await brokenRestore.restore(worldID: world, residentScope: scope)
    check(brokenRestore.persistenceError != nil, "a failed restore is visible")
    check(brokenRestore.entries(worldID: world, residentScope: scope).isEmpty,
        "a failed restore injects nothing")

    // 12. Restore adopts saved entries and immediately persists an import
    //     (legacy-import create path), keeping original timestamps.
    let importSource = FakeStorage()
    importSource.saved[ResidentSystemInboxScope(worldID: world, residentScope: scope)] = [
        ResidentSystemInboxEntry(taskKey: "task-old", lastEventID: "e0", kind: "wish.task",
            title: "旧任务", status: "已摆放", detail: "", terminal: true,
            isRead: true, readAt: Date(timeIntervalSince1970: 4_000),
            deliveredAt: Date(timeIntervalSince1970: 3_000),
            updatedAt: Date(timeIntervalSince1970: 3_500))
    ]
    let importTarget = FakeStorage()
    let importStore = ResidentSystemInboxStore(clock: { clock.now },
        restore: { scope in try importSource.restore(scope) },
        persist: { scope, entries in try importTarget.persist(scope, entries) })
    await importStore.restore(worldID: world, residentScope: scope)
    check(importStore.entries(worldID: world, residentScope: scope).count == 1,
        "the imported entry is present")
    check(importTarget.persistCalls == 1, "an import is persisted once")
    check(importStore.entries(worldID: world, residentScope: scope).first?.updatedAt
        == Date(timeIntervalSince1970: 3_500),
        "the imported timestamp is preserved")
    await importStore.restore(worldID: world, residentScope: scope)
    check(importTarget.persistCalls == 1, "re-restoring the same scope never re-imports")

    // 13. Duplicate delivery does not duplicate entries.
    check(await store.apply(delivery("e9", "task-1", status: "生成中", terminal: false),
        worldID: "other-world", residentScope: scope) == false,
        "a duplicate delivery never duplicates an entry")
    check(store.entries(worldID: "other-world", residentScope: scope).count == 1,
        "the other world still holds a single entry")

    // 14. 「重启后已读保持」：读一条 ⇒ 落盘 ⇒ 重新载入（第二次启动）⇒ 仍是已读、
    //     角标少一。注入「不持久化已读」⇒ 这一条必须 FAIL。
    let restartStorage = FakeStorage()
    let launchOne = makeStore({ clock.now }, storage: restartStorage)
    check(await launchOne.apply(delivery("relaunch-1", "relaunch-a", status: "已摆放", terminal: true),
        worldID: world, residentScope: scope), "第一次启动：新消息可靠落库")
    check(await launchOne.apply(delivery("relaunch-2", "relaunch-b", status: "已摆放", terminal: true),
        worldID: world, residentScope: scope), "第一次启动：第二条新消息可靠落库")
    check(launchOne.unreadCount(worldID: world, residentScope: scope) == 2,
        "第一次启动：两条都未读，角标 = 2")
    check(await launchOne.markRead(taskKey: "relaunch-a", worldID: world, residentScope: scope),
        "第一次启动：读一条（可靠落盘才算成功）")
    check(launchOne.unreadCount(worldID: world, residentScope: scope) == 1,
        "第一次启动：读一条之后角标少一（2 → 1）")
    let launchTwo = makeStore({ clock.now }, storage: restartStorage)
    await launchTwo.restore(worldID: world, residentScope: scope)
    check(launchTwo.unreadCount(worldID: world, residentScope: scope) == 1,
        "第二次启动：已读仍然是已读，角标仍然是 1")
    check(launchTwo.entry(taskKey: "relaunch-a", worldID: world, residentScope: scope)?.isRead == true,
        "第二次启动：读过的那一条 isRead 仍然是 true")
    check(launchTwo.entry(taskKey: "relaunch-b", worldID: world, residentScope: scope)?.isRead == false,
        "第二次启动：没读过的那一条仍然是未读")

    // 15. 「重启后条目不重复、不重新未读」：同一条消息（同一个 eventID）再投一次 ——
    //     终态那一栏来自宿主呈现（会话事实/面板最近 20 条窗口），它可以与上次不同，
    //     但同一个 id 就是同一个状态：不许翻回未读、不许重锚、不许多出条目。
    let anchorBefore = launchTwo.entry(taskKey: "relaunch-a", worldID: world, residentScope: scope)?.updatedAt
    _ = await launchTwo.apply(delivery("relaunch-1", "relaunch-a", status: "已摆放", terminal: false),
        worldID: world, residentScope: scope)
    check(launchTwo.unreadCount(worldID: world, residentScope: scope) == 1,
        "同一条消息（同 eventID）终态漂移后再投一次：读过的那条仍然是已读，角标不涨")
    check(launchTwo.entries(worldID: world, residentScope: scope)
        .filter { $0.taskKey == "relaunch-a" }.count == 1,
        "同一条消息再投一次不会多出第二条（按 taskKey 归并）")
    check(launchTwo.entry(taskKey: "relaunch-a", worldID: world, residentScope: scope)?.updatedAt == anchorBefore,
        "同一条消息再投一次不重锚 30 秒提示窗（updatedAt 一个字不动）")
    check(launchTwo.entry(taskKey: "relaunch-a", worldID: world, residentScope: scope)?.terminal == false,
        "同一状态刷新时展示字段跟着最新投影走（终态刷新，身份没变）")

    // 16. 「新消息仍然未读、角标 +1」：**新的 eventID** = 真的新状态，必须未读。
    //     注入「永不未读」⇒ 这一条必须 FAIL。
    let unreadBefore = launchTwo.unreadCount(worldID: world, residentScope: scope)
    check(await launchTwo.apply(
        delivery("relaunch-3", "relaunch-a", status: "生成失败", terminal: true, detail: "网格缺失"),
        worldID: world, residentScope: scope), "新状态可靠落库")
    check(launchTwo.unreadCount(worldID: world, residentScope: scope) == unreadBefore + 1,
        "新状态仍然未读，角标 +1")
}

@main struct Tests {
    @MainActor static func main() async {
        await run()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident system inbox checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

// ---------------------------------------------------------------------------
// 存放位置：已读是**UI 本地状态**，但它必须活在一份**可写、可读回**的耐久通道里
// ——统一状态合同的 `inbox` 域（`state_read`/`state_commit`，Application Support
// 里的 sqlite）。不是只读前像 `state.json`（迁到 Rust 权威之后它写不进去），也不是
// 世界权威 `world_records`（已读不是世界状态的一部分）。下面这几条是**机械判据**：
// 注入「把收件箱塞进世界权威 / 塞回 state.json」⇒ 必须变红。
// ---------------------------------------------------------------------------
let storagePath = "apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInboxStateStorage.swift"
let appPath = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
let storageSource = try String(contentsOf: root.appendingPathComponent(storagePath), encoding: .utf8)
let appSource = try String(contentsOf: root.appendingPathComponent(appPath), encoding: .utf8)

func sourceViolations(storage: String, app: String) -> [String] {
    var out: [String] = []
    guard let storeStart = app.range(of: "private lazy var residentSystemInboxStore: ResidentSystemInboxStore = {")?.lowerBound,
          let storeEnd = app.range(of: "private func openSystemInbox()", range: storeStart..<app.endIndex)?.lowerBound else {
        out.append("抽不出宿主的收件箱接线（`residentSystemInboxStore` 的构造）")
        return out
    }
    let wiring = String(app[storeStart..<storeEnd])
    if !wiring.contains("ResidentSystemInboxStateStorage(client:") {
        out.append("宿主没有把收件箱接在 `ResidentSystemInboxStateStorage` 上（那才是可写可读回的那份记录）")
    }
    for token in ["domain: .inbox", "client.stateCommit(", "client.stateRead("]
    where !storage.contains(token) {
        out.append("收件箱的读写没有走统一状态合同的 inbox 域：storage 里找不到「\(token)」")
    }
    for token in ["world_commit", "world_records", "world_snapshot", "state.json",
                  "domain: .world", "AtomicJSONWorldStatePersistence", "write(to:"]
    where storage.contains(token) || wiring.contains(token) {
        out.append("收件箱被塞进了世界权威／只读前像：出现「\(token)」—— 已读是 UI 本地状态，"
            + "它该活在那份可写可读回的 inbox 域记录里")
    }
    return out
}
var failures = 0
func report(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") } else { print("FAIL \(label)"); failures += 1 }
}

let cleanPlacement = sourceViolations(storage: storageSource, app: appSource)
if !cleanPlacement.isEmpty { for line in cleanPlacement { print("FAIL: " + line) } }
report(cleanPlacement.isEmpty,
    "[storage] 已读存在该在的地方：统一状态合同 inbox 域（可写可读回），不是只读前像、不是世界权威")

/// 跑一份 store 源码 + 固定 harness，返回 (退出码, 输出)。
func runHarness(_ storeSource: String) throws -> (status: Int32, output: String) {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-system-inbox-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = temporary.appendingPathComponent("ResidentSystemInbox.swift")
    try storeSource.write(to: store, atomically: true, encoding: .utf8)
    let program = temporary.appendingPathComponent("Tests.swift")
    try harness.write(to: program, atomically: true, encoding: .utf8)
    let executable = temporary.appendingPathComponent("system-inbox")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    process.arguments = ["-j1", "-parse-as-library", store.path, program.path, "-o", executable.path]
    let compilePipe = Pipe()
    process.standardOutput = compilePipe
    process.standardError = compilePipe
    try process.run()
    let compileData = compilePipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return (process.terminationStatus, String(decoding: compileData, as: UTF8.self))
    }
    let test = Process()
    test.executableURL = executable
    let pipe = Pipe()
    test.standardOutput = pipe
    test.standardError = pipe
    try test.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    test.waitUntilExit()
    return (test.terminationStatus, String(decoding: data, as: UTF8.self))
}

let storePath = "apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInbox.swift"
let storeSource = try String(contentsOf: root.appendingPathComponent(storePath), encoding: .utf8)

let clean = try runHarness(storeSource)
print(clean.output, terminator: clean.output.hasSuffix("\n") ? "" : "\n")
report(clean.status == 0,
    "[restart] 重启后已读保持 / 条目不重复不重新未读 / 新消息仍然未读（真源码驱动）")
guard failures == 0 else { print("FAIL 收件箱判据有 \(failures) 条不通过"); exit(1) }

// ---------------------------------------------------------------------------
// 注入负对照（只在**临时副本**上做手术，落盘的产品源码一个字不改）
// ---------------------------------------------------------------------------
enum InboxInjection: String, CaseIterable {
    /// 读一条只改内存、不落盘（"已读没有被持久化"）。
    case readNotPersisted
    /// 新状态也不翻未读（"永不显示未读"）—— 用假绿灯糊弄。
    case neverUnread
    /// 幂等判据里把**呈现字段**（终态）算进身份 —— 修之前的行为：
    /// 宿主呈现一变，同一条消息就被当成新状态，重启即重新未读。
    case identityIncludesPresentation

    func apply(to source: String) -> String {
        switch self {
        case .readNotPersisted:
            return source.replacingOccurrences(
                of: """
                        bucket[index].isRead = true
                        bucket[index].readAt = clock()
                        buckets[scope] = bucket
                        return await persistIfNeeded(scope)
                """,
                with: """
                        bucket[index].isRead = true
                        bucket[index].readAt = clock()
                        buckets[scope] = bucket
                        return true
                """)
        case .neverUnread:
            return source
                .replacingOccurrences(of: "terminal: delivery.terminal, isRead: false, readAt: nil,",
                                      with: "terminal: delivery.terminal, isRead: true, readAt: nil,")
                .replacingOccurrences(of: "updated.isRead = false", with: "updated.isRead = true")
        case .identityIncludesPresentation:
            return source.replacingOccurrences(
                of: "if entry.lastEventID == delivery.eventID {",
                with: "if entry.lastEventID == delivery.eventID, entry.terminal == delivery.terminal {")
        }
    }
}

for injection in InboxInjection.allCases {
    let injected = injection.apply(to: storeSource)
    report(injected != storeSource, "注入负对照「\(injection.rawValue)」确实改到了源码副本")
    let result = try runHarness(injected)
    let firstFailure = result.output
        .split(separator: "\n")
        .first { $0.hasPrefix("FAIL") }
        .map(String.init) ?? "（没有）"
    report(result.status != 0,
        "注入负对照「\(injection.rawValue)」⇒ 判据必须变红（第一条：\(firstFailure)）")
}

// ---------------------------------------------------------------------------
// 存放位置判据的注入负对照：把收件箱挪进世界权威／只读前像 ⇒ 必须变红。
// ---------------------------------------------------------------------------
let authorityInjected = storageSource
    .replacingOccurrences(of: "client.stateCommit(", with: "client.world_commit(")
let legacyInjected = storageSource
    .replacingOccurrences(of: "let value = try Self.stateValue(entries)",
                          with: "let value = try Self.stateValue(entries); try Data().write(to: URL(fileURLWithPath: \"state.json\"))")
for (name, injected) in [("挪进世界权威", authorityInjected), ("挪回 state.json（只读前像）", legacyInjected)] {
    report(injected != storageSource, "注入负对照「\(name)」确实改到了源码副本")
    let injectedFailures = sourceViolations(storage: injected, app: appSource)
    report(!injectedFailures.isEmpty,
        "注入负对照「\(name)」⇒ 判据必须变红（第一条：\(injectedFailures.first ?? "（没有）")）")
}

print(failures == 0
    ? "PASS 收件箱判据全部通过（重启已读保持 / 不重复不重新未读 / 新消息未读 / 存放位置 + 注入负对照）"
    : "FAIL 收件箱判据有 \(failures) 条不通过")
exit(failures == 0 ? 0 : 1)
