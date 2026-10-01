// P-B1：生成结果的**归属与身份**门禁。
//
// 只读生产源码、只在临时目录里编译/运行，不启动 app、不碰真机存档、不写 repo。
// 判据出处：docs/plans/2026-10-02-memory-and-generation-results-in-rust.md §8
//
//   B-1（**缺陷抓手**，三层）：状态声明的"已入库" ⇔ 派生源（`objectStates`）
//       里真的存在该条目。
//         1) 函数层：`ResidentPropInventoryBacklog.status` 只在 `isInInventory`
//            时给出含"已入库"的字样；
//         2) **派生源层（今天最容易退化的那一层）**：`isInInventory` 必须由
//            `state.objectStates[objectID]?.generatedProp != nil` 派生，
//            **不得**由 `residentOwnedPropAssets` / `localModelPath` /
//            `layoutReceipts` 派生 —— 原始缺陷（真机 `4210DB95`）正是"模型已备好、
//            库存里没有它"，因为旧代码读的是模型资产；
//         3) 终态层：`isTerminal` 只由 `isInInventory` 决定（入库没完成的物件
//            不许被终态过期藏掉）。
//   B-4（**回归护栏**）：资产身份必须等于**产物字节**的 sha256，且**不得**等于
//       输入图的 sha256（`job.imageSHA256`）。输入与产物是**两个不同的键，永不混用**
//       —— 这一条是防作者本人犯过的错（把 `imageSHA256` 当成 `assetID` 的来源）。
//
// 负对照（在临时目录里对**源码副本**做手术，证明门禁真的会红）：
//   * 把派生源换成 `residentOwnedPropAssets` ⇒ B-1 第 2 层必须 FAIL；
//   * 让 `status` 无条件返回"已领取并入库" ⇒ B-1 第 1 层必须 FAIL；
//   * 把资产身份换成输入图哈希 ⇒ B-4 必须 FAIL。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
func require(_ condition: Bool, _ message: String) { if !condition { fail(message) } }
func text(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    return value
}

/// 抽出某个声明（含方法体）的原文。与其它 harness 同一种做法：签名 + 花括号配平。
func body(of signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { return "" }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    return ""
}

func compact(_ source: String) -> String {
    source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

let appPath = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
let app = text(appPath)

var checks = 0
func check(_ condition: Bool, _ message: String, _ source: String = app) {
    checks += 1
    if !condition { fail("\(message) [check #\(checks)]") }
}

// ---------------------------------------------------------------------------
// B-1 第 1 层（函数层）：只有库存里真的有它，才允许说"已入库"
// ---------------------------------------------------------------------------

let statusBody = compact(body(of: "static func status(isInInventory: Bool", in: app))
require(!statusBody.isEmpty, "找不到 ResidentPropInventoryBacklog.status —— 判据的宿主没了")

// 「已入库」字样必须出现在 `isInInventory` 为真的分支里。
require(statusBody.contains("if isInInventory { return"),
        "status 必须**先**判 isInInventory 再决定文案（否则资产状态会冒充库存）")
let claimedPhrase = "已领取并入库"
require(statusBody.contains(claimedPhrase), "status 里应当有「\(claimedPhrase)」这一档")
require(statusBody.contains("等待入库") || statusBody.contains("入库中"),
        "非库存态必须给出**另一档**可读文案（不许复用「已入库」）")
check(!statusBody.contains("residentOwnedPropAssets"),
      "status 不得读模型资产（residentOwnedPropAssets）来决定「已入库」")

// ---------------------------------------------------------------------------
// B-1 第 3 层（终态层）：终态只由库存记录决定
// ---------------------------------------------------------------------------

let terminalBody = compact(body(of: "static func isTerminal(isInInventory: Bool", in: app))
require(!terminalBody.isEmpty, "找不到 ResidentPropInventoryBacklog.isTerminal")
require(terminalBody.contains("isInInventory"),
        "isTerminal 必须由 isInInventory 决定（否则未入库的物件会被终态过期藏掉）")
check(!terminalBody.contains("hasAssetFailure") && !terminalBody.contains("modelPath"),
      "isTerminal 不得读资产是否备好 —— 「模型好了」不是「入库了」")

// ---------------------------------------------------------------------------
// B-1 第 2 层（**派生源层**）：这是原始缺陷所在的那一层，也是最容易退化的
// ---------------------------------------------------------------------------

// 派生点：`case .claimed:` 分支里的 `let inInventory = …`。
let claimedMarker = "case .claimed:"
guard let claimedStart = app.range(of: claimedMarker)?.lowerBound else {
    fail("找不到 \(claimedMarker) —— 任务行投影没了")
}
// 该分支到下一处 `case .failed:` 之间就是它的作用域。
let claimedEnd = app.range(of: "case .failed:", range: claimedStart..<app.endIndex)?.lowerBound
    ?? app.endIndex
let claimedBranch = compact(String(app[claimedStart..<claimedEnd]))

require(claimedBranch.contains("let inInventory"),
        "claimed 分支必须把「是否在库存」算成一个具名事实")
require(claimedBranch.contains("objectStates[job.objectID]?.generatedProp != nil"),
        "**B-1 第 2 层**：inInventory 必须由 `state.objectStates[objectID]?.generatedProp != nil` 派生")
for forbidden in ["residentOwnedPropAssets[", "localModelPath", "layoutReceipts["] {
    check(!claimedBranch.contains(forbidden),
          "**B-1 第 2 层**：inInventory 不得由 \(forbidden) 派生 —— 那正是真机 `4210DB95` 的形状"
          + "（模型备好了、库存里没有它，界面却说「已领取并入库」）")
}
check(claimedBranch.contains("ownershipFact = inInventory ? .inInventory : .claimedNotInInventory"),
      "归属轴必须由同一个 inInventory 派生（两条轴不许各读各的事实）")

// ---------------------------------------------------------------------------
// B-4（回归护栏）：资产身份 == 产物字节的 sha256，且 != 输入图的 sha256
// ---------------------------------------------------------------------------

// 世界侧的身份：`assetID: "sha256:" + hash.lowercased()`，其中 hash 必须来自
// **回执的产物 inspection**，不是 `imageSHA256`。
let assetIdentity = compact(body(of: "private func residentPropAssetIdentityIsConsistent(", in: app))
if assetIdentity.isEmpty {
    // 该函数可以尚未抽出；退而求其次，直接在报账处断言身份来源。
    let descriptorMarker = "assetID: \"sha256:\" +"
    require(app.contains(descriptorMarker),
            "找不到产物身份 `assetID: \"sha256:\" + …` —— B-4 的宿主没了")
    guard let markerRange = app.range(of: descriptorMarker)?.lowerBound else {
        fail("找不到产物身份构造点")
    }
    // 往回看 40 行找 `let hash =`，它必须是 inspection 的 sha256。
    let prefixStart = app.index(markerRange, offsetBy: -2000, limitedBy: app.startIndex) ?? app.startIndex
    let prefix = compact(String(app[prefixStart..<markerRange]))
    check(prefix.contains("inspection.sha256") || prefix.contains("let hash = inspection.sha256"),
          "**B-4**：资产身份必须取自回执的产物 inspection.sha256")
    check(!prefix.contains("hash = job.imageSHA256"),
          "**B-4**：资产身份**不得**取自 job.imageSHA256（输入图的哈希）—— 输入与产物是两个不同的键")
}

// 产物 blob 与输入 blob 必须是**两个不同的键**：两个名字都得能指认出来
// （输入图哈希 `imageSHA256` 声明在 PropGenerationStore，产物哈希
// `inspection.sha256` 用在 App 的身份构造处），且 App 里**从不**把两者当同一个。
let storeSource = text("apps/macos/Sources/GMGNRadio/Presence/PropGenerationStore.swift")
require(storeSource.contains("let imageSHA256: String"),
        "**B-4**：输入图哈希 `imageSHA256` 应当作为独立字段存在（它是输入那个键）")
require(app.contains("inspection"),
        "**B-4**：产物哈希来自回执 `inspection`（那是产物那个键）")
check(!compact(app).contains("sha256:\" + job.imageSHA256")
      && !compact(app).contains("sha256:\" + imageSHA256"),
      "**B-4**：App 不得用输入图哈希构造产物身份 —— 输入与产物是两个不同的键")

// ---------------------------------------------------------------------------
// 负对照：在临时目录里对源码副本做手术，证明上面的门禁真的会红
// ---------------------------------------------------------------------------

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-gen-results-gate-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

/// 复现上面第 2 层与第 4 层的判据，作用于**任意一份源码**；返回失败的判据名。
func violations(in source: String) -> [String] {
    var found: [String] = []
    guard let start = source.range(of: claimedMarker)?.lowerBound else { return ["no-claimed-branch"] }
    let end = source.range(of: "case .failed:", range: start..<source.endIndex)?.lowerBound
        ?? source.endIndex
    let branch = compact(String(source[start..<end]))
    if !branch.contains("objectStates[job.objectID]?.generatedProp != nil") {
        found.append("derivation-not-from-objectStates")
    }
    for forbidden in ["residentOwnedPropAssets[", "localModelPath"] {
        if branch.contains(forbidden) { found.append("derivation-from-\(forbidden)") }
    }
    let status = compact(body(of: "static func status(isInInventory: Bool", in: source))
    if !status.contains("if isInInventory { return") { found.append("status-not-gated") }
    return found
}

// 正对照：未改动源码必须**没有**违规。
require(violations(in: app).isEmpty,
        "未改动的生产源码不该有违规，实测：\(violations(in: app))")

// 负对照 1：把派生源换成模型资产 ⇒ 必须被抓到。
let mutatedDerivation = app.replacingOccurrences(
    of: "world.state.objectStates[job.objectID]?.generatedProp != nil",
    with: "residentOwnedPropAssets[job.objectID] != nil")
require(mutatedDerivation != app, "负对照 1：替换没生效，说明被判据锚定的那行已变动")
check(!violations(in: mutatedDerivation).isEmpty,
      "负对照 1 失败：把 inInventory 改回读模型资产（residentOwnedPropAssets）竟未被抓到 —— "
      + "那正是真机 `4210DB95` 的原始缺陷，门禁必须红")

// 负对照 2：让 status 无条件说"已领取并入库" ⇒ 必须被抓到。
let mutatedStatus = app.replacingOccurrences(
    of: "if isInInventory { return hasAssetFailure ? \"已入库，资产未就绪\" : \"已领取并入库\" }",
    with: "return \"已领取并入库\"")
require(mutatedStatus != app, "负对照 2：替换没生效，status 的形状已变动")
check(!violations(in: mutatedStatus).isEmpty,
      "负对照 2 失败：无条件说「已领取并入库」竟未被抓到")

// 负对照 3：资产身份改用输入图哈希 ⇒ 必须被判据抓到。
let descriptorAnchor = "assetID: \"sha256:\" + hash.lowercased()"
require(app.contains(descriptorAnchor), "负对照 3：找不到身份构造锚点 \(descriptorAnchor)")
let mutatedIdentity = app.replacingOccurrences(
    of: descriptorAnchor,
    with: "assetID: \"sha256:\" + job.imageSHA256.lowercased()")
require(mutatedIdentity != app, "负对照 3：替换没生效")
// 手术后的那一行本身就证明了"身份现在取自输入图哈希"。
require(mutatedIdentity.contains("assetID: \"sha256:\" + job.imageSHA256.lowercased()"),
        "负对照 3 的构造没生效")
// 而 B-4 的判据（App 里不得用输入图哈希构造产物身份）必须因此变红。
let identityViolation = compact(mutatedIdentity).contains("sha256:\" + job.imageSHA256")
check(identityViolation,
      "负对照 3 失败：身份改用输入图哈希后，B-4 的判据没有抓住它")
// 正对照：未改动的源码里不应当有这个违规。
check(!compact(app).contains("sha256:\" + job.imageSHA256"),
      "正对照失败：未改动的 App 里竟然出现了用输入图哈希构造身份")

print("PASS: \(checks) 生成结果归属/身份判据 —— "
      + "B-1 三层（函数 / 派生源 / 终态）各自独立可断言，"
      + "B-4 护栏证明输入与产物是两个不同的键；"
      + "3 个负对照（改派生源 / 无条件报已入库 / 身份用输入哈希）都被抓到")
