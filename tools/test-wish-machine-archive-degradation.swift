// ---------------------------------------------------------------------------
// 许愿档案的**局部降级**（G6）与**重试/领取判据的唯一性**（G2 / G1）。
//
// 这一份编译的是**生产** `WishMachineCoordinator`（与 `test-wish-machine-coordinator.swift`
// 同一份源码清单，不另写同名类型），钉四件事：
//
// 1. **一条坏 job 不许让整个列表消失**：`wishes.json` 里坏的那一条被跳过（局部降级）、
//    被点名（可见说明），其余照常读出来，`isReadable` 仍然为真。
// 2. **不许静默删数据**：坏记录的原始 JSON 留在档案里（`Archive.unreadableJobs`），
//    下一次 `persist()` 不会把它抹掉。
// 3. **别的段落坏了仍然 fail-closed**：不是 `jobs` 的段落坏掉 ⇒ 整份读不出来（既有行为保留）。
// 4. **`.failed` 能重试，其它 guard 一个字都不放宽**；而且「领取」的判据只有**一份**：
//    `claimAvailability`（界面按钮读的）与 `claim()`（真正的提交）对同一份事实必须
//    给出同一句话，那句话本身没有被放宽。
//
// 为什么单独立一份而不是塞进 `test-wish-machine-coordinator.swift`：那一份里有一条
// 与本判据无关的既有断言（renderer 记录的持久化语义）正在被另一条线改动而变红，
// 会让这里的判据**根本跑不到**。判据之间不该互相挡路。
//
// 用法：swift tools/test-wish-machine-archive-degradation.swift
// ---------------------------------------------------------------------------
import Foundation

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

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = ["Presence/PropGenerationClient", "Presence/PropGenerationStore", "Presence/PropImagePreparation",
               "Presence/WishMachineOutputDescriptor", "Presence/WishMachineCoordinator",
               "Agent/WishMachineContract", "Agent/ResidentWishMachineTools"]
    .map { root.appendingPathComponent("apps/macos/Sources/GMGNRadio/\($0).swift") }
    + [root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropTaskDaemonClient.swift"),
       root.appendingPathComponent("tools/fixtures/WishMachineDaemonFixture.swift"),
       root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift"),
       // 任务行那一句委托给唯一投影（`OwnershipSentence` 是唯一出口），一起编。
       root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift"),
       // 生成确认的退避/预算读这一份唯一策略（编同一份，不抄常量）。
       root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift")]
guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
    print("FAIL: 许愿机协调器那一份源码清单不齐（少了文件）"); exit(1)
}

// ── 源码级：整份 decode 之后必须有**逐条降级**的兜底，而且坏记录要写回去 ──────────
let coordinatorSource = try String(contentsOf: sources[4], encoding: .utf8)
guard coordinatorSource.contains("private static func loadArchive(from data: Data) throws -> Archive") else {
    print("FAIL: 找不到逐条降级的解码入口 loadArchive（G6 的宿主没了）"); exit(1)
}
guard coordinatorSource.contains("struct WishMachineUnreadableJob: Codable, Equatable, Sendable {") else {
    print("FAIL: 找不到 WishMachineUnreadableJob（坏记录没有落脚点）"); exit(1)
}
guard coordinatorSource.contains("unreadableJobs: unreadableJobs.isEmpty ? nil : unreadableJobs") else {
    print("FAIL: persist() 没有把坏记录的原始 JSON 写回去 —— 那不是降级，是静默删数据"); exit(1)
}
guard coordinatorSource.contains("func claimAvailability(id: UUID, worldID: String, residentScope: String) -> Result<WishMachineJob, WishMachineError>") else {
    print("FAIL: 「这一件现在能不能领」不是一份共享判据（按钮与 claim 会各判一次）"); exit(1)
}
guard coordinatorSource.contains("switch claimAvailability(id: id, worldID: worldID, residentScope: residentScope)") else {
    print("FAIL: claim() 没有走共享判据（那就还是两份真相）"); exit(1)
}
print("PASS[source]: 逐条降级入口、坏记录落脚点、写回、共享领取判据都在")

let program = #"""
import Foundation
struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable { let id: UUID; let url: URL; let displayName: String }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name: String; let description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ title: String) { guard value else { fatalError("FAIL: " + title) }; count += 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wish-degrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = URLSession(configuration: .ephemeral)
        func store(_ name: String) throws -> PropGenerationStore {
            let value = fixtureWishStore(directory: dir.appendingPathComponent(name), session: session)
            try value.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
            return value
        }

        // ── G6：一条坏 job ⇒ 局部降级 + 可见 + 不丢数据 ────────────────────────────
        let goodJobID = UUID(), brokenJobID = UUID()
        func jobJSON(_ id: UUID, _ name: String, _ stage: String) -> [String: Any] {
            // 非可选字段一个都不能少（合成的 `Codable` 不使用属性默认值），否则
            // "坏的那一条"会因为缺字段而坏，而不是因为 stage 非法 —— 那样测的就不是同一件事。
            ["id": id.uuidString, "worldID": "world", "residentScope": "resident",
             "authorizationID": UUID().uuidString, "attachmentID": UUID().uuidString,
             "requestID": "req-" + name, "name": name, "heightMeters": 1.0,
             "objectID": "wish-prop-" + id.uuidString.lowercased(), "stage": stage,
             "computeMayContinue": false]
        }
        let corruptDirectory = dir.appendingPathComponent("corrupt-wishes")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["authorizations": [], "events": [],
            "jobs": [jobJSON(goodJobID, "good-prop", "ready"),
                     jobJSON(brokenJobID, "broken-prop", "exploded")]] as [String: Any])
            .write(to: corruptDirectory.appendingPathComponent("wishes.json"))
        let corrupted = WishMachineCoordinator(store: try store("corrupt-props"),
                                               directory: corruptDirectory, canClaim: { _ in nil })
        check(corrupted.isReadable, "一条坏 job 不许让整份 wishes.json 读不出来（那正是「列表整个消失」）")
        check(corrupted.jobs.count == 1 && corrupted.jobs.first?.id == goodJobID,
              "坏的那一条被跳过、其余照常（局部降级）实测 jobs=\(corrupted.jobs.count) unreadable=\(corrupted.unreadableJobs.count) reason=\(corrupted.unreadableJobs.first?.reason ?? "-")")
        check(corrupted.unreadableJobs.count == 1
              && corrupted.unreadableJobs.first?.jobID?.lowercased() == brokenJobID.uuidString.lowercased(),
              "坏的那一条必须被**点名**（jobID 读得出来）")
        check(corrupted.unreadableJobs.first?.reason.isEmpty == false,
              "「为什么读不出来」必须是具名原因，不是一句空话")
        check(corrupted.unreadableJobNotice?.contains("1") == true,
              "「有几条坏了、已跳过」必须有可见说明")
        let persisted = try String(contentsOf: corruptDirectory.appendingPathComponent("wishes.json"), encoding: .utf8)
        check(persisted.contains("unreadableJobs") && persisted.contains("broken-prop"),
              "坏记录的原始 JSON 必须留在档案里（下一次 persist 不许把它抹掉）")
        check(persisted.contains("good-prop"), "好记录当然还在")

        // ── 只有**别的段落**坏了，才允许整份读不出来（既有 fail-closed 行为保留） ──
        let brokenSectionDirectory = dir.appendingPathComponent("broken-section")
        try FileManager.default.createDirectory(at: brokenSectionDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["authorizations": "not-an-array", "events": [], "jobs": []] as [String: Any])
            .write(to: brokenSectionDirectory.appendingPathComponent("wishes.json"))
        let brokenSection = WishMachineCoordinator(store: try store("broken-section-props"),
                                                   directory: brokenSectionDirectory, canClaim: { _ in nil })
        check(!brokenSection.isReadable && brokenSection.errorMessage != nil,
              "别的段落坏了 ⇒ 仍然是「整份读不出来」（fail-closed，不猜）")

        // ── G2：`.failed` 能重试，**其它 guard 一个字都不放宽** ────────────────────
        check(WishMachineCoordinator.retryableStages.contains(.failed),
              "生成失败的行必须能重试（否则用户唯一的证据只能丢掉）")
        check(WishMachineCoordinator.retryableStages == [.submissionUncertain, .submitting, .generated, .failed],
              "除 .failed 之外的重试 guard 一个字都不许放宽（ready/claimed 已经有产物，重发会多出一件）")

        // ── G1：领取的判据只有一份（按钮与 claim 同一句话），而且没有被放宽 ────────
        let readyJob = corrupted.jobs.first!
        check(readyJob.stage == .ready, "（前提）坏档案旁边那条好记录是 ready")
        var availabilityMessage: String?
        if case let .failure(error) = corrupted.claimAvailability(id: readyJob.id, worldID: "world", residentScope: "resident") {
            availabilityMessage = error.localizedDescription
        }
        var thrownMessage: String?
        do { _ = try corrupted.claim(id: readyJob.id, worldID: "world", residentScope: "resident") }
        catch { thrownMessage = error.localizedDescription }
        check(availabilityMessage != nil && availabilityMessage == thrownMessage,
              "「领取」按钮与 claim() 必须读同一份判据（同一份事实 ⇒ 同一句话）")
        check(availabilityMessage == WishMachineError.notReady.localizedDescription,
              "判据本身没有被放宽：没有模型文件就是 notReady")
        // 作用域不对时两边同样一致（不是靠"哪一条先抛"碰巧相同）。
        var scopeMessage: String?
        if case let .failure(error) = corrupted.claimAvailability(id: readyJob.id, worldID: "other", residentScope: "resident") {
            scopeMessage = error.localizedDescription
        }
        check(scopeMessage == WishMachineError.wrongScope.localizedDescription,
              "别的空间里的任务不能领（fail-closed），实测 \(scopeMessage ?? "nil")")

        print("PASS: \(count) archive degradation / retry / claim-judgement checks")
    }
}
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wish-degrade-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let checks = tmp.appendingPathComponent("checks.swift"), binary = tmp.appendingPathComponent("checks")
try program.write(to: checks, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
compiler.arguments = ["-n", "15", "swiftc", "-j1", "-parse-as-library"] + worldRuntimeHarnessFlags()
    + sources.map(\.path) + [checks.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { print("FAIL: 编译不过"); exit(compiler.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit()
exit(run.terminationStatus)
