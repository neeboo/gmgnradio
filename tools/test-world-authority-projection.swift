// 世界状态投影守卫的聚焦门禁（F2）——只读源码 + 临时目录编译，不启 app。
//
// 它锁住三件在评审里真实出现过的事故：
//   1. 同一个提交里 `world.stateCommitted`(rev=4) 与 `object.placed`(rev=3) 必须
//      **都**被应用：物件有自己的 revision 数轴，不能拿世界记录的轴去比；
//   2. 被拒的事实**也**要推进游标：否则游标永远停在被拒那条前面，每次重连
//      重放再拒一次，投影永远追不上权威；
//   3. 重复/乱序（`seq <= cursor`）与 subject revision 回退必须分开计数。
//
// 运行：swift tools/test-world-authority-projection.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
func check(_ condition: Bool, _ message: String) { if !condition { fail(message) } }

let clientPath = "apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift"
// 退避/重试预算的**唯一**定义（权威重连读它）—— 编它，不另抄一套常量。
let backoffPath = "apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift"
let persistencePath = "apps/macos/Sources/GMGNRadio/Presence/AuthorityWorldStatePersistence.swift"
let clientSource = (try? String(contentsOf: URL(fileURLWithPath: clientPath), encoding: .utf8)) ?? ""
let persistenceSource = (try? String(contentsOf: URL(fileURLWithPath: persistencePath), encoding: .utf8)) ?? ""
check(!clientSource.isEmpty && !persistenceSource.isEmpty, "读不到生产源码")

// MARK: - 源码级：幂等键必须覆盖 expectedRevision（F3）

check(clientSource.contains("\"world-save:\\(expectedRevision):\""),
      "requestID 没带 expectedRevision：同内容 + 新 revision 会撞 request_id_conflict")
check(clientSource.contains("startEventSubscription"), "没有事件订阅接线")
check(persistenceSource.contains("private let archive"), "只读预像的 archive 未封口")

// MARK: - 行为级：编译投影 + 预像并运行

// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
// `build` 由那唯一一份定义**推出来**（= Modules 的上一级），本文件不持有路径字面量。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let build = URL(fileURLWithPath: worldRuntimeFlags[1]).deletingLastPathComponent()
let objects = (try? FileManager.default.contentsOfDirectory(
    at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "o" } ?? []
check(!objects.isEmpty, "WorldRuntime 还没构建")

let driver = #"""
import Foundation
import WorldRuntime

struct StubArchive: WorldStatePersisting {
    func save(_ state: WorldState) throws {}
    func load() throws -> WorldState? { nil }
}

func fact(_ seq: UInt64, _ kind: String, _ domain: String, _ key: String,
          _ revision: UInt64) -> WorldAuthorityFact {
    WorldAuthorityFact(sequence: seq, id: "\(kind):\(seq)", kind: kind, subjectDomain: domain,
                       subjectKey: key, revision: revision, payload: [:], producer: "probe",
                       atMilliseconds: 0)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

@main struct Probe {
    static func main() throws {

    // 1. 只读预像的写入口必须抛
    let preImage = LegacyWorldStatePreImage(archive: StubArchive(), candidateURLs: [])
    let state = WorldState(revision: 1, worldID: "w", worldTime: Date(timeIntervalSince1970: 0),
                           lastObservedWallTime: Date(timeIntervalSince1970: 0), weather: .clear,
                           agentTransform: WorldTransform(
                               position: WorldVector3(x: 0, y: 0, z: 0),
                               rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
                               scale: WorldVector3(x: 1, y: 1, z: 1)))
    do {
        try preImage.save(state)
        check(false, "只读预像还能写 state.json")
    } catch WorldStatePersistenceRetired.writeRetired {
    } catch {
        check(false, "只读预像抛了别的错：\(error)")
    }

    // 2. 同一提交：世界事实 rev=4 在前，物件事实 rev=3 在后 —— 两条都必须应用
    var projection = WorldAuthorityProjection()
    projection.adopt(recordRevision: 3, boundarySeq: 4, stateSha256: "seed")
    let worldCommit = fact(5, "world.stateCommitted", "worlds", "state", 4)
    let objectPlaced = fact(6, "object.placed", "objects", "o1", 3)
    check(projection.apply(worldCommit), "world 事实没被应用")
    check(projection.apply(objectPlaced),
          "同一提交里物件自己的 revision(3) 低于世界记录(4) 时仍必须被应用")
    check(projection.basedOnRevision == 4, "basedOnRevision 只跟随世界记录")
    check(projection.appliedFacts == 2 && projection.droppedStaleFacts == 0
          && projection.revisionRegressions == 0, "两条都应计入 applied")

    // 3. 重放同一条：按 seq 丢弃，不重复应用
    check(!projection.apply(objectPlaced), "重放必须被拒")
    check(projection.lastAppliedSequence == 6, "游标停在最高已见 seq")
    check(projection.appliedFacts == 2, "重放不增加 applied")

    // 4. subject revision 回退：单独计为协议错，**且游标必须越过它**
    check(!projection.apply(fact(7, "object.placed", "objects", "o1", 2)), "revision 回退必须被拒")
    check(projection.revisionRegressions == 1, "revision 回退单独计数")
    check(projection.droppedStaleFacts == 1, "回退不混进 droppedSeq（1 来自第 3 步重放）")
    check(projection.lastAppliedSequence == 7,
          "被拒的事实也必须推进游标，否则每次重连都重放再拒一次")
    // 重连：从 7 之后开始，不会重放 7
    check(!projection.apply(fact(7, "object.placed", "objects", "o1", 2)), "重连不重放已见事实")
    check(projection.lastAppliedSequence == 7, "游标不因重放回退")

    // 4b. 物件自己的 revision **高于**世界记录时，也不得把 basedOnRevision 拉走：
    //     两套数轴混用的另一种症状（会把写准入判成陈旧而误拒）。
    check(projection.apply(fact(8, "object.resized", "objects", "o1", 5)),
          "更高的物件 revision 事件应被应用")
    check(projection.basedOnRevision == 4,
          "basedOnRevision 只跟随世界记录：物件 revision=5 不得把它拉走（否则写准入会误判陈旧）")

    // 5. 权威前进 ⇒ 陈旧投影不得通过写准入
    projection.adopt(recordRevision: 6, boundarySeq: 12, stateSha256: "next")
    check(!projection.admitsWrite(at: 5), "基于 rev=5 的投影在权威到 6 后必须被拒")
    check(projection.admitsWrite(at: 6), "跟上权威的投影必须允许写入")
    print("PASS: 投影带 basedOnRevision、按 subject 记 revision、被拒事实也推进游标")
        }
    }
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-world-projection-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let driverURL = temporary.appendingPathComponent("main.swift")
let executable = temporary.appendingPathComponent("check")
try driver.write(to: driverURL, atomically: true, encoding: .utf8)

func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compile = try run("/usr/bin/nice", ["-n", "15", "/usr/bin/swiftc", "-j1", "-parse-as-library",
    "-I", build.appendingPathComponent("Modules").path,
    clientPath, persistencePath, backoffPath, driverURL.path] + objects.map(\.path) + ["-o", executable.path])
guard compile == 0 else { fail("投影/预像那段编译不过") }
exit(try run(executable.path, []))
