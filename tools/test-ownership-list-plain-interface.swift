// ---------------------------------------------------------------------------
// 「我的物件」列表 = **给普通人看的**：一行只有三样，界面上零内部术语。
//
// 用户原话（2026-10-02，针对一行 `暖光落地灯 / 已摆放 / 按 sourceWishID 认到所属许愿 /
// [收回] [删除] [为什么]`）：
//
//   「不要搞为什么然后给展开折叠，普通人看得懂吗，里面一堆 key-value 的东西」
//
// 这一份钉五件事，**每一条都带注入负对照**（把缺陷注入回内存副本必须 FAIL）：
//
// 1. **界面上没有任何 `key=value` / UUID / 路径 / 内部字段名**：
//    真机 `wishes.json` + `state.json` 跑生产投影，把**面板真的会画的每一个字**
//    （名字 / 状态句 / 按钮词 / 组头 / 「还有 N 件」）拿正则过一遍必须干净。
//    注入「状态句里塞回 UUID」⇒ FAIL。
// 2. **没有「为什么」入口与展开证据面板**：面板源码里不许再有 `为什么` /
//    `expandedRowIDs` / `row.evidence` / `item.field` / `item.value`。
//    注入「把「为什么」按钮装回去」⇒ FAIL；注入「把 field = value 面板装回去」⇒ FAIL。
// 3. **每行最多三样：名字 / 一句人话状态 / 按钮**：`ownershipRow` 函数体里
//    `Text(` 恰好两处（name + statusText），零 `ForEach`，零副标题（`row.badges`）。
//    注入「多一层」（副标题 / 第三行）⇒ FAIL。
// 4. **七个动作都还在**，只是不解释：领取 / 让居民去取 / 重试入库 / 重试 / 摆放 / 收回 / 删除。
//    注入「删掉其中一个入口」⇒ FAIL。
// 5. **投影一个字没改**（与 HEAD 逐字节相同），面板宽 340 / 列表高 190 未动。
//    投影语义与五处消费的判据由 `tools/test-ownership-list-projection.swift` 负责。
//
// 注入只改**内存副本**（源码字符串）或**临时副本**（编译到 NSTemporaryDirectory），
// 落盘的源码一个字不改。
//
// 用法：swift tools/test-ownership-list-plain-interface.swift
// ---------------------------------------------------------------------------
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}
/// 去掉行注释：判据要看的是**代码与字面量**，不是注释里说明「这里没有为什么」的那句话。
func stripped(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<range.lowerBound])
        }
        .joined(separator: "\n")
}
/// 从签名到配对的 `}`。
func declaration(_ source: String, _ signature: String) -> String? {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    return nil
}
/// 一段源码里所有**给人看的字符串字面量**（插值里的代码整段跳过，不算字面量）。
func stringLiterals(_ source: String) -> [String] {
    var out: [String] = []
    var index = source.startIndex
    while index < source.endIndex {
        guard source[index] == "\"" else { index = source.index(after: index); continue }
        var literal = ""
        var cursor = source.index(after: index)
        var closed = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\\" {
                let next = source.index(after: cursor)
                guard next < source.endIndex else { break }
                if source[next] == "(" {
                    // 插值：跳过配对的括号，里面的标识符不是给人看的字。
                    cursor = source.index(after: next)
                    var depth = 1
                    while cursor < source.endIndex, depth > 0 {
                        if source[cursor] == "(" { depth += 1 }
                        if source[cursor] == ")" { depth -= 1 }
                        cursor = source.index(after: cursor)
                    }
                    continue
                }
                cursor = source.index(after: next)
                continue
            }
            if character == "\"" { closed = true; break }
            literal.append(character)
            cursor = source.index(after: cursor)
        }
        if closed { out.append(literal); index = source.index(after: cursor) } else { break }
    }
    return out
}

let viewPath = "apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift"
let projectionPath = "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift"
let viewSource = try read(viewPath)
let projectionSource = try read(projectionPath)
let viewCode = stripped(viewSource)

// ---------------------------------------------------------------------------
// 判据 1 的**词表**：这些东西是给我们和 agent 看的，不许出现在界面上。
// ---------------------------------------------------------------------------
let hiddenTerms = ["sourceWishID", "layoutReceipts", "objectStates", "propTombstones",
                   "wishes.json", "state.json", "claimed.", "jobID", "objectID",
                   "isEnabled", "heldProp", "effectiveSize", "sizeProvenance",
                   "residentPropAssetFailures", "residentPropInventoryBacklog"]
let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
let keyValuePattern = "[A-Za-z_][A-Za-z0-9_]*[ \\t]*=[ \\t]*[^ \\t]"
let pathPattern = "(/Users/|/Library/|/private/|/var/|\\.json|file://)"

/// 一段**给人看的文本**里的违规项。**注入负对照要的就是「这里非空」**。
func plainTextViolations(_ text: String) -> [String] {
    var out: [String] = []
    if text.range(of: uuidPattern, options: .regularExpression) != nil {
        out.append("界面上出现了 UUID：\(text)")
    }
    if text.range(of: keyValuePattern, options: .regularExpression) != nil {
        out.append("界面上出现了 key=value：\(text)")
    }
    if text.range(of: pathPattern, options: .regularExpression) != nil {
        out.append("界面上出现了路径：\(text)")
    }
    for term in hiddenTerms where text.contains(term) {
        out.append("界面上出现了内部字段名「\(term)」：\(text)")
    }
    return out
}

// ---------------------------------------------------------------------------
// 判据 2 / 3 / 4 —— 源码级。**注入负对照要的就是「这里非空」**。
// ---------------------------------------------------------------------------
/// 面板源码里的违规项。`view` 是**代码**（已去注释）。
func plainInterfaceViolations(_ view: String) -> [String] {
    var failures: [String] = []

    // 判据 2：入口与证据面板都不许回来。
    for gone in ["为什么", "expandedRowIDs", "row.evidence", ".evidence",
                 "item.field", "item.value", "row.badges", "row.reasonText"] where view.contains(gone) {
        failures.append("面板里又出现了「\(gone)」—— 「为什么」入口 / 展开的 key-value 面板必须不在")
    }

    // 判据 1（源码级）：面板画出来的**字面量**里不许有 UUID / 路径 / key=value / 内部字段名。
    for literal in stringLiterals(view) {
        for violation in plainTextViolations(literal) { failures.append(violation) }
    }

    // 判据 3：一行最多三样。`ownershipRow` 只许画 name + statusText 两处文字。
    guard let rowBody = declaration(view, "private func ownershipRow(_ row: OwnershipRow) -> some View {") else {
        failures.append("抽不出 ownershipRow —— 那正是一行的定义处")
        return failures
    }
    let textCount = rowBody.components(separatedBy: "Text(").count - 1
    if textCount != 2 {
        failures.append("一行画了 \(textCount) 处文字（必须恰好 2：名字 + 一句人话状态）—— 多一层就是第四样东西")
    }
    if rowBody.contains("ForEach(") {
        failures.append("一行里出现了 ForEach —— 那是展开的证据 / 徽标列表，必须不在")
    }
    if !rowBody.contains("Text(row.name)") { failures.append("一行里没有名字（Text(row.name)）") }
    if !rowBody.contains("Text(row.statusText)") { failures.append("一行里没有那一句人话状态（Text(row.statusText)）") }
    if !rowBody.contains("ownershipActions(row)") { failures.append("一行里没有能做的事（ownershipActions(row)）") }

    // 判据 4：七个动作的入口都得在（摆放走既有的点行进携带态，不是按钮）。
    let actionAnchors = ["row.actions.contains(.claim)", "row.actions.contains(.askResidentToFetch)",
                         "row.actions.contains(.retry)", "row.actions.contains(.retryInventoryRegistration)",
                         "row.actions.contains(.place)", "row.actions.contains(.withdraw)",
                         "row.actions.contains(.delete)"]
    for anchor in actionAnchors where !view.contains(anchor) {
        failures.append("动作入口「\(anchor)」不见了 —— 七个动作一个都不许丢")
    }
    // 摆放入口在行内的那条守卫上（点行 = 既有携带态）。
    if !view.contains("guard row.actions.contains(.place) || row.actions.contains(.withdraw) else { return }") {
        failures.append("「摆放」的既有入口（点行进携带态）不见了")
    }
    return failures
}

let cleanFailures = plainInterfaceViolations(viewCode)
guard cleanFailures.isEmpty else {
    for failure in cleanFailures { print("FAIL: " + failure) }
    exit(1)
}
print("PASS[plain-source]: 面板源码里 0 个「为什么」/ 展开证据 / 副标题；一行恰好两处文字 + 一排按钮；七个动作入口都在")

// ---------------------------------------------------------------------------
// 判据 4（词表）：七个动作**逐字**来自唯一投影，视图不自造。
// ---------------------------------------------------------------------------
for label in ["领取", "让居民去取", "重试", "重试入库", "摆放", "收回", "删除"] where !projectionSource.contains("return \"\(label)\"") {
    print("FAIL: 唯一投影的 OwnershipRowAction.label 里少了「\(label)」")
    exit(1)
}
print("PASS[seven-actions]: 投影给的动作词就是那七个（领取 / 让居民去取 / 重试 / 重试入库 / 摆放 / 收回 / 删除）")

// ---------------------------------------------------------------------------
// 判据 5：投影**一个字没改**（与 HEAD 逐字节相同）；两条红线未动。
// ---------------------------------------------------------------------------
let gitDiff = Process()
gitDiff.executableURL = URL(fileURLWithPath: "/usr/bin/git")
gitDiff.arguments = ["diff", "--quiet", "HEAD", "--", projectionPath]
gitDiff.currentDirectoryURL = root
try? gitDiff.run(); gitDiff.waitUntilExit()
if gitDiff.terminationStatus != 0 {
    print("FAIL: 唯一投影 \(projectionPath) 被改过了 —— 这次只许改它被画出来的样子")
    exit(1)
}
guard projectionSource.contains("static let panelListHeightPoints = 190") else {
    print("FAIL: 列表高度必须是 190 pt"); exit(1)
}
let controller = try read("apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift")
// 红线钉的是**摆放面板**那一处约束（另一处 340 属于电视面板 —— 2026-10-02 用户要求
// 把电视面板整块从产品界面拿掉，那条约束被另一条线合法删除；这里不替它背书）。
guard controller.contains("propEditorPanel.widthAnchor.constraint(equalToConstant: 340)") else {
    print("FAIL: 摆放面板宽度必须仍是 340（propEditorPanel 那处约束）"); exit(1)
}
print("PASS[red-lines]: 唯一投影与 HEAD 逐字节相同；列表 190 pt、摆放面板宽 340 那处约束未动")

/// 下面那段真机复核里，「重试入库」摆不摆出来按生产那句判据镜像。
/// 这里先钉住生产源码**就是**那一句 —— 镜像一旦与生产分叉，这条先红。
let worldSimulation = try read("apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldSimulation.swift")
guard worldSimulation.contains("objectStates[objectID] == nil && propTombstones?[objectID] == nil") else {
    print("FAIL: 生产 WorldState.canRedoInventoryRegistration 的判据变了 —— 真机复核里的镜像必须跟着改")
    exit(1)
}
print("PASS[mirror-guard]: 真机复核镜像的那句「能不能补做」= 生产 WorldState.canRedoInventoryRegistration 逐字")

// ---------------------------------------------------------------------------
// 判据 1（数据级）：拿真机档案跑生产投影，把**面板真的会画的每一个字**过一遍。
// ---------------------------------------------------------------------------
let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("plain-interface-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func declarationOf(_ relative: String, _ signature: String) throws -> String {
    guard let found = declaration(try read(relative), signature) else {
        print("FAIL: 抽不出 \(signature)"); exit(1)
    }
    return found
}
let coordinatorPath = "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift"
let extra = try read("apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift")
    + "\n"
    + (try declarationOf(coordinatorPath, "enum WishMachineStage: String, Codable, Sendable {"))
    + "\n"
    + (try declarationOf(coordinatorPath, "struct WishMachineJob: Identifiable, Codable, Equatable, Sendable {"))

/// 编译并运行一段程序（程序 = 生产投影 + 这份 program）。返回 (退出码, 输出)。
func compileAndRun(_ program: String, projection: String, extra: String) -> (Int32, String) {
    let binary = temporary.appendingPathComponent("h-\(UUID().uuidString)")
    let file = binary.appendingPathExtension("swift")
    let text = "import Foundation\n\(extra)\n\(projection)\n\(program)"
    try? text.write(to: file, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compile.arguments = ["-j1", "-parse-as-library", "-swift-version", "6", file.path, "-o", binary.path]
    let compileLog = Pipe()
    compile.standardError = compileLog
    try? compile.run(); compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        return (compile.terminationStatus,
                "compile failed:\n" + String(decoding: compileLog.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    let run = Process()
    run.executableURL = binary
    let output = Pipe()
    run.standardOutput = output
    run.standardError = output
    try? run.run(); run.waitUntilExit()
    return (run.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

let panelProgram = #"""
/// 世界那一轴：`state.json` 的形状逐字取自生产（`gmgn.generated-prop.v1`）。
struct RealGeneratedProp: Decodable { let objectID: String; let sourceWishID: String?; let displayName: String? }
struct RealObjectState: Decodable {
    let isEnabled: Bool
    let metadata: [String: String]?
    var generatedProp: RealGeneratedProp? {
        guard let text = metadata?["gmgn.generated-prop.v1"], let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RealGeneratedProp.self, from: data)
    }
}
struct RealTombstone: Decodable { let objectID: String; let displayName: String; let reason: String? }
struct RealHeld: Decodable { let objectID: String; let hand: String }
struct RealReceipt: Decodable {
    enum Key: String, CodingKey { case requestID }
    init(from decoder: Decoder) throws {
        if (try? decoder.container(keyedBy: Key.self)) != nil { return }
        if (try? decoder.singleValueContainer()) != nil { return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "receipt"))
    }
}
struct RealWorld: Decodable {
    let objectStates: [String: RealObjectState]
    let propTombstones: [String: RealTombstone]?
    let heldProp: RealHeld?
    let layoutReceipts: [String: RealReceipt]?
}
struct RealArchive: Decodable { let jobs: [WishMachineJob] }

@main struct PlainInterface {
    /// 界面上**不许出现**的东西。
    static func dirty(_ text: String) -> String? {
        if text.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                       options: .regularExpression) != nil { return "UUID" }
        if text.range(of: "[A-Za-z_][A-Za-z0-9_]*[ \\t]*=[ \\t]*[^ \\t]", options: .regularExpression) != nil { return "key=value" }
        if text.range(of: "(/Users/|/Library/|/private/|/var/|\\.json|file://)", options: .regularExpression) != nil { return "路径" }
        for term in ["sourceWishID", "layoutReceipts", "objectStates", "propTombstones",
                     "wishes.json", "state.json", "claimed.", "jobID", "objectID",
                     "isEnabled", "heldProp", "effectiveSize", "sizeProvenance"] where text.contains(term) {
            return "内部字段名「\(term)」"
        }
        return nil
    }

    static func main() throws {
        var failures: [String] = []
        var drawn: [String] = []

        /// 面板**真的会画**的东西：名字、那一句人话状态、按钮词。
        /// （`reasonText` / `evidence` / `badges` 是投影给日志与 agent 回执的工程细节，
        /// 视图已经不画它们 —— 所以它们**不进**这份清单。）
        func draw(_ label: String, _ rows: [OwnershipRow], budget: Int, showsEnded: Bool) {
            let list = ResidentOwnershipProjection.list(rows, showsEnded: showsEnded, rowBudget: budget)
            for section in list.sections {
                let title = ResidentOwnershipProjection.sectionTitle(section)
                if let why = dirty(title) { failures.append("组头里有 \(why)：\(title)") }
                drawn.append("\(label)|【组头】\(title)")
                for row in section.rows {
                    if let why = dirty(row.name) { failures.append("面板第一样（名字）里有 \(why)：\(row.name)") }
                    if let why = dirty(row.statusText) { failures.append("面板第二样（状态）里有 \(why)：\(row.statusText)") }
                    for action in row.actions {
                        if let why = dirty(action.label) { failures.append("面板第三样（按钮）里有 \(why)：\(action.label)") }
                    }
                    let buttons = row.actions.map(\.label).joined(separator: " ")
                    drawn.append("\(label)|\(row.name)|\(row.statusText)|\(buttons.isEmpty ? "（没有按钮）" : buttons)")
                }
            }
            if list.remainingCount > 0 {
                let tail = "还有 \(list.remainingCount) 件"
                if let why = dirty(tail) { failures.append("面板尾部里有 \(why)：\(tail)") }
                drawn.append("\(label)|【尾部】\(tail)")
            }
        }

        // ── (a) 人造事实：把投影**画得出来的每一句**都过一遍（真机数据不一定覆盖每一档） ──
        func fact(_ id: String, _ name: String, _ stage: OwnershipJobStage?) -> OwnershipRowFacts {
            var f = OwnershipRowFacts(objectID: id)
            f.jobID = UUID()
            f.jobName = name
            f.jobStage = stage
            return f
        }
        var synthetic: [OwnershipRowFacts] = []
        synthetic.append(fact("s1", "一盏灯", .generating))
        synthetic.append(fact("s2", "一盏灯", .submitting))
        synthetic.append(fact("s3", "一盏灯", .submissionUncertain))
        var cancelPending = fact("s4", "一盏灯", .generating); cancelPending.cancelRequested = true
        synthetic.append(cancelPending)
        var ready = fact("s5", "一盏灯", .ready); ready.trayShowsThis = true; ready.canClaimNow = true
        synthetic.append(ready)
        var readyOffTray = fact("s6", "一盏灯", .ready); readyOffTray.trayShowsThis = false
        synthetic.append(readyOffTray)
        var renderFailed = fact("s7", "一盏灯", .ready)
        renderFailed.renderFailureMessage = "场景加载失败：/Users/someone/thing.usdz 打不开"
        synthetic.append(renderFailed)
        var inventory = fact("s8", "一盏灯", .claimed)
        inventory.objectPresent = true; inventory.objectHasGeneratedProp = true
        inventory.objectName = "一盏灯"; inventory.objectIsEnabled = false
        synthetic.append(inventory)
        var placed = inventory; placed.objectIsEnabled = true
        synthetic.append(placed)
        var held = inventory; held.heldSlot = "rightHand"
        synthetic.append(held)
        var notSaved = fact("s11", "一盏灯", .claimed)
        notSaved.claimReceiptPresent = true
        notSaved.canRedoInventoryRegistration = true
        synthetic.append(notSaved)
        synthetic.append(fact("s12", "一盏灯", .claimed))
        var failed = fact("s13", "一盏灯", .failed)
        failed.lastError = "renderer failed at /Users/someone/out.glb (0C285296-9164-4A2B-8FB7-6648E549A4AE)"
        failed.canRetryNow = true
        synthetic.append(failed)
        synthetic.append(fact("s14", "一盏灯", .cancelled))
        synthetic.append(fact("s15", "一盏灯", .interrupted))
        var deleted = OwnershipRowFacts(objectID: "s16")
        deleted.tombstoneName = "一盏灯"; deleted.tombstoneReason = "不想要了"
        synthetic.append(deleted)
        var orphan = OwnershipRowFacts(objectID: "s17")
        orphan.objectPresent = true; orphan.objectHasGeneratedProp = true
        orphan.objectName = "旧的咖啡机"; orphan.objectIsEnabled = true
        synthetic.append(orphan)
        draw("人造", synthetic.map(ResidentOwnershipProjection.row), budget: 40, showsEnded: true)

        // ── (b) 真机档案：面板**真的**会画的那几行 ──
        let wishesURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/gmgn radio/WishMachine/wishes.json")
        let stateURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json")
        var realRows: [OwnershipRow] = []
        if let archiveData = try? Data(contentsOf: wishesURL), let worldData = try? Data(contentsOf: stateURL),
           let archive = try? JSONDecoder().decode(RealArchive.self, from: archiveData),
           let world = try? JSONDecoder().decode(RealWorld.self, from: worldData) {
            var facts: [OwnershipRowFacts] = []
            var matched: Set<String> = []
            for (index, job) in archive.jobs.enumerated() {
                var objectID = job.objectID
                var object = world.objectStates[job.objectID]
                if object?.generatedProp?.objectID != job.objectID {
                    if let found = world.objectStates.first(where: { $0.value.generatedProp?.sourceWishID == job.id.uuidString }) {
                        objectID = found.key; object = found.value
                    } else { object = nil }
                }
                var f = OwnershipRowFacts(objectID: objectID)
                f.jobID = job.id
                f.jobName = job.name
                f.jobStage = OwnershipJobStage(rawValue: job.stage.rawValue)
                f.lastError = job.lastError
                f.cancelRequested = job.cancelRequested == true
                f.processOrder = index
                f.objectPresent = object?.generatedProp != nil
                f.objectHasGeneratedProp = object?.generatedProp != nil
                f.objectName = object?.generatedProp?.displayName
                f.objectIsEnabled = object?.isEnabled == true
                f.heldSlot = (world.heldProp?.objectID == objectID) ? world.heldProp?.hand : nil
                f.tombstoneName = world.propTombstones?[objectID]?.displayName
                f.claimReceiptPresent = world.layoutReceipts?["claimed." + job.id.uuidString] != nil
                // 与生产 `WorldState.canRedoInventoryRegistration(objectID:)` **同源**
                // （外层脚本已断言生产源码就是这一句）。它只决定「重试入库」那个按钮
                // 摆不摆出来，不决定这一行画什么字。
                f.canRedoInventoryRegistration = (object == nil) && (world.propTombstones?[objectID] == nil)
                if f.objectPresent { matched.insert(objectID) }
                facts.append(f)
            }
            for (objectID, object) in world.objectStates.sorted(by: { $0.key < $1.key }) {
                guard !matched.contains(objectID), let prop = object.generatedProp else { continue }
                var f = OwnershipRowFacts(objectID: objectID)
                f.objectPresent = true; f.objectHasGeneratedProp = true
                f.objectName = prop.displayName; f.objectIsEnabled = object.isEnabled
                f.heldSlot = (world.heldProp?.objectID == objectID) ? world.heldProp?.hand : nil
                matched.insert(objectID)
                facts.append(f)
            }
            for (objectID, tombstone) in (world.propTombstones ?? [:]).sorted(by: { $0.key < $1.key }) where !matched.contains(objectID) {
                var f = OwnershipRowFacts(objectID: objectID)
                f.tombstoneName = tombstone.displayName
                facts.append(f)
            }
            realRows = facts.map(ResidentOwnershipProjection.row)
            // 面板默认：预算 6 行（190 pt）、「已结束」折叠。
            draw("真机", realRows, budget: ResidentOwnershipProjection.visibleRowBudget, showsEnded: false)
            draw("真机全量", realRows, budget: realRows.count + 8, showsEnded: true)
        } else {
            drawn.append("真机|（这台机器上没有 wishes.json / state.json，真机那一遍跳过）")
        }

        print("── 面板**真的会画**的每一个字（名字 | 状态 | 按钮）──")
        for line in drawn { print("DRAW|" + line) }
        // 工程细节**不在**界面上，只在日志与 agent 回执里 —— 这里如实数出来做对照。
        let reasons = realRows.compactMap(\.reasonText)
        let evidence = realRows.flatMap(\.evidence)
        let dirtyReasons = reasons.filter { dirty($0) != nil }.count
        print("INFO|真机行数 \(realRows.count)｜投影里带工程细节的原因 \(reasons.count) 条（其中 \(dirtyReasons) 条含 UUID/路径/字段名）｜evidence \(evidence.count) 条 —— 都不在界面上")

        for failure in failures { print("FAIL: " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
"""#

let panel = compileAndRun(panelProgram, projection: projectionSource, extra: extra)
print(panel.1.trimmingCharacters(in: .whitespacesAndNewlines))
guard panel.0 == 0 else {
    print("FAIL: 面板画出来的字里有内部术语 —— 见上面每一条 FAIL")
    exit(1)
}
print("PASS[plain-drawn]: 真机 + 人造每一档，面板画的字里 0 个 UUID / 路径 / key=value / 内部字段名")

// ---------------------------------------------------------------------------
// 注入负对照：每一条都必须让对应判据红（只改内存副本）。
// ---------------------------------------------------------------------------
func expectSourceFailure(_ name: String, _ anchor: String, _ replacement: String) {
    guard viewCode.contains(anchor) else {
        print("FAIL: 负对照「\(name)」的注入点找不到（等于没有负对照）"); exit(1)
    }
    let mutated = viewCode.replacingOccurrences(of: anchor, with: replacement)
    guard mutated != viewCode else {
        print("FAIL: 负对照「\(name)」注入没有改变源码"); exit(1)
    }
    let final = plainInterfaceViolations(mutated)
    guard !final.isEmpty else {
        print("FAIL: 负对照「\(name)」注入后没有报违规 —— 这个判据抓不到该缺陷"); exit(1)
    }
    print("PASS[negative-\(name)]: 注入 ⇒ FAIL：\(final[0])")
}

// 1) 把「为什么」按钮装回去 ⇒ FAIL
expectSourceFailure("why-entry-back", "                ownershipActions(row)\n",
                    "                ownershipActions(row)\n                Button(\"为什么\") {}\n")
// 2) 把**展开的 key-value 证据面板**装回去 ⇒ FAIL
expectSourceFailure("evidence-panel-back", "Text(row.statusText)",
                    "Text(row.statusText)\n                Text(\"\\(item.field) = \\(item.value)\")")
// 3) 把内部术语写回界面（副标题里那句 sourceWishID）⇒ FAIL
expectSourceFailure("subtitle-source-wish-id", "Text(row.name)",
                    "Text(\"按 sourceWishID 认到所属许愿\")")
// 4) 多一层（名字下面再加一行副标题）⇒ FAIL
expectSourceFailure("extra-layer", "Text(row.name).lineLimit(1)\n",
                    "Text(row.name).lineLimit(1)\n                if !row.badges.isEmpty { Text(row.badges.joined(separator: \" · \")) }\n")
// 5) 丢掉一个动作入口 ⇒ FAIL
expectSourceFailure("drop-retry-action",
                    "            if row.actions.contains(.retry), let jobID = row.key.jobID?.uuidString {",
                    "            if false, let jobID = row.key.jobID?.uuidString {")
// 6) 往界面塞回一条 `field: value`（普通人看不懂的那种）⇒ FAIL
expectSourceFailure("key-value-back", "Text(row.name)", "Text(\"stage = ready\")")

// 7) 投影把 UUID 画进状态句 ⇒ 数据级判据必须 FAIL（只编译临时副本）。
do {
    let anchor = "                statusText = OwnershipSentence.inventoryNotSaved.rawValue"
    guard projectionSource.contains(anchor) else {
        print("FAIL: 负对照「uuid-into-status」的注入点找不到"); exit(1)
    }
    let mutated = projectionSource.replacingOccurrences(
        of: anchor,
        with: "                statusText = \"入库未保存 \" + (facts.jobID?.uuidString ?? \"\")")
    let result = compileAndRun(panelProgram, projection: mutated, extra: extra)
    guard result.0 != 0 else {
        print("FAIL: 负对照「uuid-into-status」注入后判据竟然还是绿的 —— 这个判据抓不到该缺陷"); exit(1)
    }
    let line = result.1.split(separator: "\n").first(where: { $0.hasPrefix("FAIL") }).map(String.init) ?? "(无 FAIL 行)"
    print("PASS[negative-uuid-into-status]: 注入 ⇒ FAIL：\(line)")
}

print("")
print("PASS: 「我的物件」面板 —— 一行只有三样（名字 / 一句人话状态 / 按钮），界面上 0 个 key=value、UUID、路径、内部字段名（全部含注入负对照）")
