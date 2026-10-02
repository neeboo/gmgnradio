// 「我的物件」列表**只有一套投影** —— 这是那条并存线的**退役门禁**。
//
// 背景（2026-10-02 仲裁）：工作树里同时长出了**两套**列表状态推导 ——
//   · 本文件原先盯的那一套：`ResidentPropCatalog.rows` / `ResidentPropWishFact` /
//     `ResidentPropCatalogRow`（+ 第四套文案 `wishStatusText` / `rowStatus`）；
//   · 唯一投影那一套：`Presence/ResidentOwnershipProjection.swift`。
// 仲裁结论：**唯一投影 = `ResidentOwnershipProjection`**，另一套**逐字删除**。
// 两套并存正是「东西静默消失」的形状：同一个问题有两个答案，界面与任务行就会各说各话。
//
// 于是本文件不再测那套已经退场的 API（那会变成一条对不存在符号的红线），改成钉住
// **「第二套不许回来」**：
//
//   R1 全仓生产源码里**不存在**那套退役符号（注释里提到不算，见下面 `code(_:)`）；
//   R2 唯一投影在，而且对外状态**只有五种** + 折叠的「已结束」，且**不实现 Codable**
//      （「存下来的状态」是第二份真相的入口，类型上就不许写出来）；
//   R3 面板**真的**在读唯一投影（`state.ownershipList`），而不是又拼了一份；
//   R4 面板尺寸那条红线：列表 190 pt（由唯一投影给出）、宽度仍是 **340**；
//   R5、R6 两条**注入负对照**：把第二套投影的定义 / 第四套文案塞回一份源码副本 ⇒
//      本门禁必须 FAIL（注入只改临时副本，跑完再扫一次真源码确认没被污染）。
//
// 六条各自独立可断言，不是「顺手 grep 一下」。

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

/// 已经退役的那套符号。**只作为字符串**出现在这里 —— 本文件不许再引用它们当类型。
let retiredSymbols = ["ResidentPropWishFact", "ResidentPropCatalog", "wishStatusText",
                      "static func rowStatus(isHeld"]

var checks = 0
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

/// 把源码里**注释行**去掉：退役记录本身会写这些名字（见本文件头，以及
/// `test-no-long-term-memory-capability.swift` 的同一手法），那不是「第二套投影回来了」。
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
        .joined(separator: "\n")
}

/// 扫一整棵树：哪些文件里还有退役符号（只看代码，不看注释）。
/// 返回「文件: 符号」的排序列表 —— R1 与两条注入负对照读的是**同一个**函数。
func offenders(in directory: URL) -> [String] {
    var found: [String] = []
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return found
    }
    for case let url as URL in walker where url.pathExtension == "swift" {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let body = code(text)
        for symbol in retiredSymbols where body.contains(symbol) {
            found.append("\(url.lastPathComponent): \(symbol)")
        }
    }
    return found.sorted()
}

func source(_ relative: String) -> String? {
    try? String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
}

// ── R1：全仓不存在第二套投影 ────────────────────────────────────────────────
let live = offenders(in: sources)
guard live.isEmpty else {
    print("FAIL[R1]: 第二套列表状态推导又回来了（两套并存 = 两份真相）：")
    for item in live { print("        \(item)") }
    exit(1)
}
let swiftFileCount = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.count) ?? 0
print("PASS[R1]: \(swiftFileCount) 个生产源文件里 0 处退役符号（\(retiredSymbols.joined(separator: " / "))）")

// ── R2：唯一投影在，五态 + 折叠「已结束」，且不实现 Codable ────────────────
let projectionPath = "Presence/ResidentOwnershipProjection.swift"
guard let projection = source(projectionPath) else {
    print("FAIL[R2]: 找不到唯一投影 \(projectionPath)"); exit(1)
}
check(projection.contains("enum OwnershipDisplayState: String, Sendable, CaseIterable {"),
      "唯一投影必须自己定义对外状态 `OwnershipDisplayState`")
check(!projection.contains("enum OwnershipDisplayState: String, Codable"),
      "对外状态不许实现 Codable：那是「把状态从存档里读回来」的入口（第二份真相）")
for state in ["case generating", "case awaitingClaim", "case inInventory", "case placed", "case failed", "case ended"] {
    check(projection.contains(state), "对外状态缺了 \(state)（五种 + 折叠的「已结束」）")
}
check(projection.contains("static func row(_ facts: OwnershipRowFacts) -> OwnershipRow"),
      "唯一投影必须只有一处推导 row(_:)")
check(projection.contains("static func list(_ rows: [OwnershipRow], order: [String: Int] = [:]"),
      "唯一投影必须给出分组 / 折叠 / 预算的那一处 list(_:)")
check(projection.contains("isFoldedByDefault"),
      "「已结束」默认折叠必须由投影说（Q1：折叠可见，不是隐藏）")
print("PASS[R2]: 唯一投影到位 —— 五态 + 折叠「已结束」、纯函数、不实现 Codable")

// ── R3：面板真的在读唯一投影 ────────────────────────────────────────────────
guard let view = source("VisualEngine/ResidentPropEditorView.swift") else {
    print("FAIL[R3]: 找不到摆放面板视图"); exit(1)
}
check(view.contains("state.ownershipList"), "面板列表必须读 state.ownershipList（唯一投影）")
check(view.contains("row.statusText"), "面板那一行的状态词必须读投影给的 row.statusText")
check(!code(view).contains("wishStatusText") && !code(view).contains("rowStatus("),
      "面板里不许再出现第二套 / 第四套文案")
check(view.contains("row.actions"), "行内动作必须由投影派生（row.actions），视图不判能不能领")
print("PASS[R3]: 面板消费唯一投影（行状态 + 行动作都由投影派生）")

// ── R4：红线 —— 列表 190 pt、面板宽 340 不动 ───────────────────────────────
check(projection.contains("static let panelListHeightPoints = 190"),
      "列表高度必须是 190 pt（145 → 190 是这次拍板的）")
check(view.contains("ResidentOwnershipProjection.panelListHeightPoints"),
      "面板必须读投影给的列表高度，而不是自己写一个数")
let controller = source("VisualEngine/StageWindowController.swift") ?? ""
let widthHits = controller.components(separatedBy: "equalToConstant: 340").count - 1
check(widthHits == 2, "面板宽度必须仍是 340（两处约束），实测 \(widthHits) 处")
print("PASS[R4]: 列表 190 pt（唯一投影给出）、面板宽度 340 两处约束逐字未动")

// ── R5 / R6：注入负对照（同一棵扫描器必须能抓到） ──────────────────────────
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-ownership-retirement-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

/// 把一棵真实源码树拷进临时目录，再往指定文件尾部追加一段注入。
func injectedTree(appending injection: String, to relative: String) throws -> URL {
    let copy = temporary.appendingPathComponent("GMGNRadio-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: sources, to: copy)
    let target = copy.appendingPathComponent(relative)
    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    try (existing + "\n" + injection + "\n").write(to: target, atomically: true, encoding: .utf8)
    return copy
}

let stateRelative = "Presence/ResidentPropEditorState.swift"

// R5：把「第二套投影」的定义注入回去 ⇒ 扫描器必须抓到。
let secondProjectionInjection = """
enum ResidentPropCatalog {
    static func rows() -> [String] { [] }
}
"""
let treeR5 = try injectedTree(appending: secondProjectionInjection, to: stateRelative)
let r5 = offenders(in: treeR5)
check(!r5.isEmpty, "注入第二套投影之后扫描器竟然没抓到（门禁是假的）")
if let first = r5.first { print("PASS[R5]: 注入第二套投影 ⇒ FAIL 被抓住（\(first)）") }

// R6：把「第四套文案」注入回去 ⇒ 扫描器必须抓到。
let fourthWordingInjection = """
extension ResidentPropEditorState {
    static func rowStatus(isHeld: Bool, isPlaced: Bool) -> String { isHeld ? "手持中" : "已摆出" }
}
"""
let treeR6 = try injectedTree(appending: fourthWordingInjection, to: stateRelative)
let r6 = offenders(in: treeR6)
check(!r6.isEmpty, "注入第四套文案之后扫描器竟然没抓到（门禁是假的）")
if let first = r6.first { print("PASS[R6]: 注入第四套文案 ⇒ FAIL 被抓住（\(first)）") }

// 注入只改了临时副本：真源码必须仍然干净。
let after = offenders(in: sources)
check(after.isEmpty, "注入之后真源码里出现了退役符号（注入污染了工作树）：\(after)")

for failure in failures { print("FAIL: " + failure) }
guard failures.isEmpty else { exit(1) }
print("PASS: \(checks) 条断言 —— 「我的物件」只有一套投影（\(swiftFileCount) 个源文件），两条注入负对照都实测会红")
