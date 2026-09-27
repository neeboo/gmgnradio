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
}

@main struct Tests {
    @MainActor static func main() async {
        await run()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident system inbox checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-system-inbox-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("system-inbox")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInbox.swift").path,
    program.path, "-o", executable.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let test = Process()
test.executableURL = URL(fileURLWithPath: executable.path)
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
