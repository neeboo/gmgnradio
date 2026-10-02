// 现场取证：拿**真机那份 2B 白色长剑**（`assetID sha256:e9dda009…`，1,722,692 字节）跑一遍
// 生产代码里那条「资产未验证」的判据，逐条打印**哪一项没过、期望值 vs 实际值**。
//
// 为什么必须是"跑生产代码"而不是"读源码猜"：真机 2026-10-02 12:28:21 的统一日志只有
//
//     挂点拒绝 step=asset-unverified 挂点=右手 物件=wish-prop-4210db95-…
//     挂件拒绝 step=grip-calibration … 原因=物件尚未完成本地显示检查，所有权已保留，请稍后重试。
//
// 这两句说的是**后果**。文件不在？字节数不对？哈希对不上？本地资产记录里没有它？
// 渲染器还没备好？—— 五条腿各自的期望/实际必须从**真数据**里量出来，不能靠读代码推断。
//
// 数据来源（都是真机现状，只读，不改任何东西）：
//   * 权威存档：`~/Library/Application Support/gmgn radio/TaskService/tasks.sqlite3`
//     的 `world_records`（`objects/wish-prop-4210db95-…` 与 `worlds/state`）；
//   * 领取回执：同一 DB 的 `jobs` 表（`receipt.result.inspection` = 生成器量到的字节与哈希）；
//   * 资产文件：`…/TaskService/4210DB95-9253-4CAF-83A3-3C45F090B099.glb`（现场再算一次 sha256）。
//
// 判据（`ResidentPropAssetVerification`）本身**原样切自生产源码**，这里不另写一份。
import Foundation
import CryptoKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func declaration(_ source: String, _ signature: String) -> String? {
    guard let start = source.range(of: signature) else { return nil }
    guard let open = source[start.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[start.lowerBound...index]) }
        }
    }
    return nil
}

// ---------------------------------------------------------------------------
// 真机数据（只读）
// ---------------------------------------------------------------------------
let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/gmgn radio", isDirectory: true)
let database = applicationSupport.appendingPathComponent("TaskService/tasks.sqlite3")
let objectID = "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099"
let wishID = "4210DB95-9253-4CAF-83A3-3C45F090B099"

func sqlite(_ statement: String) -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, statement]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return "" }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

guard FileManager.default.fileExists(atPath: database.path) else {
    print("FAIL: 找不到真机权威存档 \(database.path)")
    exit(1)
}

/// 存档里那条物件记录 → `gmgn.generated-prop.v1` 那串 JSON（**权威里那一份身份**）。
let recordRow = sqlite("select value from world_records where domain='objects' and key='\(objectID)';")
guard let recordData = recordRow.data(using: .utf8),
      let recordObject = (try? JSONSerialization.jsonObject(with: recordData)) as? [String: Any],
      let metadata = recordObject["metadata"] as? [String: Any],
      let storedJSON = metadata["gmgn.generated-prop.v1"] as? String
else {
    print("FAIL: 权威里没有 \(objectID) 的生成物件记录（真机存档里它被删了？）")
    exit(1)
}
let storedPropJSON = storedJSON

/// 领取回执里那两行 —— 生成器/准备路径**实际量到**的字节数与 sha256。
let jobRow = sqlite("select data from jobs where id='\(wishID)';")
guard let jobData = jobRow.data(using: .utf8),
      let jobEnvelope = (try? JSONSerialization.jsonObject(with: jobData)) as? [String: Any],
      let job = jobEnvelope["job"] as? [String: Any],
      let receipt = job["receipt"] as? [String: Any],
      let result = receipt["result"] as? [String: Any],
      let inspection = result["inspection"] as? [String: Any],
      let inspectedBytes = inspection["bytes"] as? Int,
      let inspectedSHA = inspection["sha256"] as? String,
      let modelPath = job["localModelPath"] as? String
else {
    print("FAIL: 领取回执里读不出 inspection.bytes / inspection.sha256 / localModelPath")
    exit(1)
}

/// 资产文件此刻的样子 + 现场重算的 sha256（**这条是实测，不是抄回执**）。
let modelURL = URL(fileURLWithPath: modelPath)
let values = try? modelURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
let liveBytes = values?.fileSize
let liveSHA: String? = (try? Data(contentsOf: modelURL, options: .mappedIfSafe)).map {
    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
}

print("=== 真机现场读数（2026-10-02 那把 2B 白色长剑）===")
print("物件=\(objectID)")
print("权威存档里的身份 assetID=\(storedPropJSON.contains("e9dda009") ? "sha256:e9dda009…（已确认）" : "（下面原样打印）")")
print("领取回执 inspection.bytes=\(inspectedBytes)  inspection.sha256=\(inspectedSHA)")
print("资产文件 path=\(modelPath)")
print("资产文件 此刻字节数=\(liveBytes.map(String.init) ?? "nil")  此刻重算 sha256=\(liveSHA ?? "nil")")
print("文件 isRegularFile=\(values?.isRegularFile.map(String.init) ?? "nil") isSymbolicLink=\(values?.isSymbolicLink.map(String.init) ?? "nil")")
print("")

// ---------------------------------------------------------------------------
// 切出生产的判据（原样，不另写一份），编成内层程序跑
// ---------------------------------------------------------------------------
let attachmentPath = "apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift"
guard let attachmentSource = try? String(contentsOf: root.appendingPathComponent(attachmentPath), encoding: .utf8),
      let receiptDeclaration = declaration(attachmentSource, "struct ResidentPropAssetByteReceipt"),
      let verificationDeclaration = declaration(attachmentSource, "struct ResidentPropAssetVerification")
else {
    print("FAIL: 从 \(attachmentPath) 切不出 ResidentPropAssetByteReceipt / ResidentPropAssetVerification")
    exit(1)
}
for leg in ["asset-record", "asset-identity", "asset-file", "asset-hash", "asset-prepare"] {
    guard verificationDeclaration.contains(leg) else {
        print("FAIL: 生产判据里缺少腿 \(leg)（五条腿必须各自具名）")
        exit(1)
    }
}

let fixture: [String: Any] = [
    "objectID": objectID,
    "storedPropJSON": storedPropJSON,
    "modelURL": modelPath,
    "inspectedBytes": inspectedBytes,
    "inspectedSHA": inspectedSHA,
    "liveBytes": liveBytes ?? -1,
    "liveSHA": liveSHA ?? "",
]
let fixtureData = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-prop-asset-probe-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

let fixtureURL = temporary.appendingPathComponent("fixture.json")
try fixtureData.write(to: fixtureURL)

let inner = #"""
import Foundation
import WorldRuntime

\#(receiptDeclaration)

\#(verificationDeclaration)

func load(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return (try JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

/// 真机 12:28:21.388 那一刻：世界状态里**有**这件物件（它就在房间里），
/// 但这一进程的本地资产记录里**还没有**它 —— 判据必须说出是"哪条腿"。
func verification(record: WorldGeneratedProp?,
                  receipt: ResidentPropAssetByteReceipt?,
                  observedSHA256: String?,
                  prepared: Bool,
                  expected: WorldGeneratedProp?,
                  fileExists: Bool = true,
                  regular: Bool = true,
                  symlink: Bool = false,
                  liveBytes: Int?) -> ResidentPropAssetVerification {
    // 身份那条判据**只有一处**：`WorldGeneratedProp.matchesIdentity(of:)`（WorldRuntime）。
    let identityMatches: Bool? = (record != nil && expected != nil)
        ? record!.matchesIdentity(of: expected!) : nil
    return ResidentPropAssetVerification(
        objectID: expected?.objectID ?? "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099",
        record: record,
        recordModelURL: record == nil ? nil : receipt?.modelURL,
        recordCount: record == nil ? 2 : 1,
        recordNames: record == nil ? ["斧头", "2B 白色长剑（外形摆件）"] : ["2B 白色长剑（外形摆件）"],
        expected: expected,
        identityMatches: identityMatches,
        byteReceipt: receipt,
        fileExists: fileExists,
        fileIsRegularFile: regular,
        fileIsSymbolicLink: symlink,
        fileBytes: liveBytes,
        observedSHA256: observedSHA256,
        prepared: prepared)
}

let fixture = try load(CommandLine.arguments[1])
let storedJSON = fixture["storedPropJSON"] as! String
let modelURL = fixture["modelURL"] as! String
let inspectedBytes = fixture["inspectedBytes"] as! Int
let inspectedSHA = fixture["inspectedSHA"] as! String
let liveBytes = fixture["liveBytes"] as! Int
let liveSHA = fixture["liveSHA"] as! String

let decoder = JSONDecoder()
let stored = try decoder.decode(WorldGeneratedProp.self, from: Data(storedJSON.utf8))
print("权威存档里那份身份：")
print("  objectID=\(stored.objectID)")
print("  sourceWishID=\(stored.sourceWishID)")
print("  assetID=\(stored.assetID)")
print("  displayName=\(stored.displayName)")
print("  size=\(ResidentPropAssetVerification.sizeText(stored.size))")
print("")

let receipt = ResidentPropAssetByteReceipt(modelURL: modelURL, bytes: inspectedBytes, sha256: inspectedSHA)

func report(_ title: String, _ verification: ResidentPropAssetVerification) {
    print("--- \(title) ---")
    print("  体检：\(verification.examination)")
    if let failure = verification.failure {
        print("  不成立：腿=\(failure.leg.rawValue)")
        print("          字段=\(failure.field)")
        print("          期望=\(failure.expected)")
        print("          实际=\(failure.actual)")
    } else {
        print("  结论：五条腿全过 —— 资产已验证，挂点标定可以继续往下走")
    }
    print("")
}

// ① 真机那一刻（12:28:21.388）：本地资产记录里没有它。
report("A1 真机 12:28:21.388 那一刻：本地资产记录缺这条（资产准备还没轮到它）",
       verification(record: nil, receipt: nil, observedSHA256: nil, prepared: false,
                    expected: stored, liveBytes: nil))

// ② 准备跑完之后（记录 = 存档那一份、字节收据 = 真机实测、文件真的在）。
let delivered = stored
report("A2 资产准备跑完之后（记录在、文件在、字节与哈希都对、渲染器备好）",
       verification(record: delivered, receipt: receipt, observedSHA256: liveSHA, prepared: true,
                    expected: stored, liveBytes: liveBytes))

// ②b 同一次准备里，渲染器还没把资产备好（prepare 那条腿）。
report("A2b 记录与文件都对，但渲染器这一刻还没备好（asset-prepare）",
       verification(record: delivered, receipt: receipt, observedSHA256: nil, prepared: false,
                    expected: stored, liveBytes: liveBytes))

// ③ 文件被换过（字节数/哈希不再等于记录声明的那一份）。
report("A3 文件被动过（此刻重算的 sha256 与记录声明不同）",
       verification(record: delivered, receipt: receipt, observedSHA256: String(repeating: "0", count: 64),
                    prepared: true, expected: stored, liveBytes: liveBytes))

// ④ 身份不一致（存档里那份 displayName/尺寸被改成别的）。
let tampered = WorldGeneratedProp(objectID: stored.objectID, sourceWishID: stored.sourceWishID,
    assetID: stored.assetID, displayName: "白色长剑", size: WorldVector3(x: 1.1, y: 0.146, z: 0.062),
    sourceHeight: stored.sourceHeight)
report("A4 身份不一致（displayName 与 size 都被改过）",
       verification(record: delivered, receipt: receipt, observedSHA256: liveSHA, prepared: true,
                    expected: tampered, liveBytes: liveBytes))
"""#

let innerURL = temporary.appendingPathComponent("Probe.swift")
try inner.write(to: innerURL, atomically: true, encoding: .utf8)

// WorldRuntime 的模块搜索路径 + 目标文件只有一处定义：tools/world-runtime-harness-flags.sh。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [root.appendingPathComponent("tools/world-runtime-harness-flags.sh").path]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let flags = worldRuntimeHarnessFlags()
let executable = temporary.appendingPathComponent("probe")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-I", flags[1], innerURL.path, "-o", executable.path]
    + Array(flags.dropFirst(2))
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }

let run = Process()
run.executableURL = executable
run.arguments = [fixtureURL.path]
try run.run(); run.waitUntilExit()
exit(run.terminationStatus)
