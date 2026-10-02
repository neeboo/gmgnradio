// ---------------------------------------------------------------------------
// 「我的物件」列表 = 全部许愿的目录：投影的判据 + **真机数据离线复核**。
//
// 这一份钉四件事，每一条都带**注入负对照**（把缺陷注入回生产源码必须 FAIL）：
//
// 1. **许愿过的东西一件都不许消失**：真机 `wishes.json` 的每条 job ⇒ 一行；
//    `stage == "ready"` 的必须在「待你处理」里看得见（不是折叠掉），"已领取但没入库存"的
//    必须看得见并说得出为什么。**这两个期望值从同一份输入推导，不写死快照** ——
//    现场已经漂过一次：2026-10-02 早上是 2 ready + 3 未入库，同一台机器 17:32 变成
//    0 + 5（7 条全 `claimed`，只有 2 件真的进了世界）。写死旧数字，红的就只是快照过期，
//    与产品无关；推导出来的期望值反而不会漏掉任何一条。
//    注入"把 job-only 的行塞进「已结束」" ⇒ FAIL。
// 2. **状态 = f(权威)**：改权威（`isEnabled` / `heldProp` / `propTombstones`）⇒ 行状态随之改变。
//    注入"缓存上一次的状态" ⇒ FAIL。
// 3. **删除后不再显示成已摆出**（G5）：列表必须读 `propTombstones`。
//    注入"不读墓碑" ⇒ FAIL。
// 4. **对外只有五种状态**（+ 折叠的「已结束」），且 `OwnershipRow` **不实现 `Codable`**
//    （禁止把派生结论写回）。注入 `Codable` / 注入 `init(rawValue:)` ⇒ FAIL。
// 5. **一个投影，五处消费**（2026-10-02 收口）：列表 / 房间里 / 托盘 / 任务行 /
//    agent 的 `read_owned_props` 都从 `ResidentOwnershipProjection` 取状态；任务行那一句
//    委托 `sentence(...)`、托盘字面读 `room == .placed`、回执写投影那两句。
//    任务行 / 托盘 / agent 各写一套 ⇒ 三种注入都必须 FAIL。
// 6. **第四套状态词的全局门禁**：任何界面 / 回执的**代码**里出现「已摆出」这类自造词
//    ⇒ FAIL（注入面板 ⇒ 必须红）；任务行里再出现「可领取 / 等待入库 / 未摆放 / 排队中」
//    ⇒ FAIL（那是被这次收口退役的第二套）。
//
// 真机那一段读的是**生产投影函数本身**（`ResidentOwnershipProjection.row`），
// 过程权威解码用的是**生产 `WishMachineJob` / `WishMachineStage` 声明**
// （从 `WishMachineCoordinator.swift` 里抽出来编译），所以它复核对的就是用户会看到的那一行。
//
// 真机那一段的**输入**刻意不用 `wishes.json` 里那条陈旧 `renderer` 失败：生产读的是
// **现场**（`spatialStage.residentPropRenderStatuses`），存档那条只作记录（见
// `archivedRenderFailures`）。拿存档当动作判据 ⇒ 必须 FAIL（那条负对照就在下面）。
//
// 用法：swift tools/test-ownership-list-projection.swift
// ---------------------------------------------------------------------------
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}
/// 抽出一段声明（从签名到配对的 `}`）—— 与仓里其它 harness 同一套做法。
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

let projectionPath = "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift"
let coordinatorPath = "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift"
let generationClientPath = "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift"
let worldLayoutPath = "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropLayout.swift"
let projectionSource = try read(projectionPath)

// ── 判据 4（源码级）：对外只有五种状态 + 折叠的 ended，且派生结论不可落盘 ─────────
/// 去掉行注释之后的源码：判据要看的是**声明**，不是注释里提到这些名字（本文件自己
/// 就在注释里说明"没有 `init(rawValue:)`"，那不该被当成违规）。
func stripped(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<range.lowerBound])
        }
        .joined(separator: "\n")
}
/// 返回所有违规项。**注入负对照要的就是"这里非空"**。
func staticViolations(_ source: String) -> [String] {
    var violations: [String] = []
    let declarations = stripped(source)
    /// 从标记到配对的 `}`（签名里的 `Codable` 也要一起看得到）。
    func body(_ marker: String) -> String? { declaration(declarations, marker) }
    func signature(_ marker: String) -> String? {
        guard let start = declarations.range(of: marker)?.lowerBound,
              let open = declarations[start...].firstIndex(of: "{") else { return nil }
        return String(declarations[start..<open])
    }
    guard let stateSignature = signature("enum OwnershipDisplayState: String") else {
        violations.append("找不到 OwnershipDisplayState（对外状态必须是它）")
        return violations
    }
    if stateSignature.contains("Codable") {
        violations.append("对外状态不许实现 Codable（派生的结论不许落盘）")
    }
    guard let rowSignature = signature("struct OwnershipRow: Identifiable") ?? signature("struct OwnershipRow: Equatable") else {
        violations.append("找不到 OwnershipRow")
        return violations
    }
    if rowSignature.contains("Codable") {
        violations.append("OwnershipRow 不许实现 Codable：派生行一旦可编码就会被写回去当第二份真相")
    }
    if body("struct OwnershipRow") == nil {
        violations.append("OwnershipRow 的声明抽不出来")
    }
    if declarations.contains("init(rawValue:") || declarations.contains("init?(rawValue:") {
        violations.append("投影类型不许有 init(rawValue:)：那是「从存档把状态读回来」的入口")
    }
    // 五种状态 + ended：词表**就是**这六个，多一个就是内部术语漏到界面上。
    // 这一档用户拍板写「未领取」（不是「待领取」）—— 词表也照它钉。
    for word in ["生成中", "未领取", "在库里（没摆）", "已摆放", "失败"] where !source.contains(word) {
        violations.append("对外状态词表里少了「\(word)」")
    }
    return violations
}
let cleanViolations = staticViolations(projectionSource)
guard cleanViolations.isEmpty else {
    for violation in cleanViolations { print("FAIL: " + violation) }
    exit(1)
}
print("PASS[4]: 对外只有五种状态 + 折叠的「已结束」；OwnershipRow / 状态类型不实现 Codable、没有 init(rawValue:)")

// 生产声明：过程权威（wishes.json）的 stage 与 job —— 逐字来自生产源码。
guard let stageSource = declaration(try read(coordinatorPath), "enum WishMachineStage: String, Codable, Sendable {") else {
    print("FAIL: 找不到 WishMachineStage —— 真机复核读的就是它"); exit(1)
}
guard let jobSource = declaration(try read(coordinatorPath), "struct WishMachineJob: Identifiable, Codable, Equatable, Sendable {") else {
    print("FAIL: 找不到 WishMachineJob"); exit(1)
}
for literal in ["submitting", "submissionUncertain", "generating", "generated",
                "ready", "failed", "cancelled", "interrupted", "claimed"]
where !stageSource.contains(literal) {
    print("FAIL: WishMachineStage 里没有 \(literal)"); exit(1)
}
let generationClientSource = try read(generationClientPath)
let worldLayoutSource = try read(worldLayoutPath)
let generatedPropKey = "gmgn.generated-prop.v1"
guard worldLayoutSource.contains(generatedPropKey) else {
    print("FAIL: 找不到 generatedProp 的元数据键 \(generatedPropKey) —— 世界那一轴读的就是它"); exit(1)
}

let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ownership-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

/// 编译并运行一段程序（程序 = 生产源码 + 这份 program）。返回 (退出码, 输出)。
func compileAndRun(_ program: String, projection: String, extra: String = "") -> (Int32, String) {
    let binary = temporary.appendingPathComponent("h-\(UUID().uuidString)")
    let file = binary.appendingPathExtension("swift")
    let text = """
    import Foundation
    \(extra)
    \(projection)
    \(program)
    """
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

// ── 判据 2 / 3：状态 = f(权威)；墓碑必须被读到 ─────────────────────────────────
let authorityProgram = #"""
@main struct Harness {
    static func facts(_ objectID: String) -> OwnershipRowFacts {
        var f = OwnershipRowFacts(objectID: objectID)
        f.jobID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        f.jobName = "斧头"
        f.jobStage = .claimed
        f.processOrder = 0
        f.objectPresent = true
        f.objectHasGeneratedProp = true
        f.objectName = "斧头"
        return f
    }
    static func main() {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }

        // (a) isEnabled = false ⇒ 在库里（没摆）
        var inventory = facts("obj")
        inventory.objectIsEnabled = false
        let inInventory = ResidentOwnershipProjection.row(inventory)
        check(inInventory.state == .inInventory && inInventory.statusText == "在库里（没摆）",
              "isEnabled=false 必须是在库里（没摆），实测 \(inInventory.state)/\(inInventory.statusText)")
        check(inInventory.room == .inventory, "isEnabled=false ⇒ room 必须是 inventory")

        // (b) 只把**权威**改成 isEnabled = true ⇒ 同一份事实的状态必须跟着变（防缓存）
        var placed = inventory
        placed.objectIsEnabled = true
        let isPlaced = ResidentOwnershipProjection.row(placed)
        check(isPlaced.state == .placed && isPlaced.statusText == "已摆放",
              "isEnabled=true ⇒ 已摆放，实测 \(isPlaced.state)/\(isPlaced.statusText)")
        check(inInventory.state != isPlaced.state, "改权威必须改变行状态（不许沿用上一次）")

        // (c) 只把**权威**改成挂在背后 ⇒ 行状态跟着变，且**不许**说成"已摆放"（F5：
        //     「已摆放」这两个字只能等于 isEnabled == true）
        var held = inventory
        held.heldSlot = "back"
        let isHeld = ResidentOwnershipProjection.row(held)
        check(isHeld.room == .held, "heldProp ⇒ room 必须是 held")
        check(isHeld.statusText != "已摆放", "手持不许被说成「已摆放」（实测 \(isHeld.statusText)）")
        check(isHeld.statusText == "在居民手里", "手持那一行必须说得出来，实测 \(isHeld.statusText)")

        // (d) G5：删掉的东西**不再显示成已摆出**，而且必须留下「已结束」一行
        var deleted = placed
        deleted.objectPresent = false
        deleted.objectHasGeneratedProp = false
        deleted.tombstoneName = "斧头"
        deleted.tombstoneSettlement = "原本摆放在房间里，摆放随删除一并结束"
        let tombstoned = ResidentOwnershipProjection.row(deleted)
        check(tombstoned.state == .ended && tombstoned.group == .ended,
              "有墓碑 ⇒ 必须进「已结束」，实测 \(tombstoned.state)/\(tombstoned.group)")
        check(tombstoned.statusText == "已删除", "墓碑行必须是「已删除」，实测 \(tombstoned.statusText)")
        check(tombstoned.isFoldedByDefault, "「已结束」必须默认折叠")
        check(tombstoned.evidence.contains { $0.field == "state.json propTombstones" && $0.value.contains("斧头") },
              "展开里必须给出墓碑的 evidence（字段名 + 值）")
        // 删除**不回写** wishes.json：job 还是 claimed，墓碑必须在它之前生效。
        check(deleted.jobStage == .claimed, "（前提）被删的 job stage 仍然是 claimed")
        check(tombstoned.state != .failed && tombstoned.statusText != "已领取，入库尚未保存",
              "有墓碑时绝不许显示成「已领取，入库尚未保存」（那会读成「还会回来」）")
        // Q1 的**列表层**判据：删掉的东西要**折叠可见**，不是隐藏 ——
        // 折叠时它必须仍被**计数**（「已结束 (1)」），点开之后必须真的是行。
        let endedRows = [tombstoned]
        let collapsed = ResidentOwnershipProjection.list(endedRows, showsEnded: false)
        let collapsedSection = collapsed.sections.first { $0.group == .ended }
        check(collapsedSection?.isFolded == true && collapsedSection?.totalCount == 1,
              "默认折叠时必须仍报出「已结束 (1)」—— 隐藏 = 用户以为东西没了，实测 \(collapsedSection?.totalCount ?? -1)")
        check(collapsedSection?.rows.isEmpty == true, "默认折叠时那一组不该展开出行")
        let expandedEnded = ResidentOwnershipProjection.list(endedRows, showsEnded: true, rowBudget: 8)
        check(expandedEnded.sections.first { $0.group == .ended }?.rows.count == 1,
              "点开之后那条「已删除」必须真的看得见（Q1：折叠可见，不是隐藏）")
        check(expandedEnded.allRows.contains { $0.statusText == "已删除" },
              "展开里必须有「已删除」那一行")

        // (e) 墓碑与物件并存（存档分叉）：以**物件**为准（东西不许消失），分叉必须可见
        var divergent = placed
        divergent.tombstoneName = "斧头"
        let both = ResidentOwnershipProjection.row(divergent)
        check(both.room == .placed, "墓碑与库存并存时以物件为准（东西不许消失）")
        check(both.badges.contains { $0.contains("分叉") }, "并存的分叉必须可见，实测 \(both.badges)")

        // (f) 未领取：主文案**就是「未领取」**（用户 2026-10-02 原话），而「还没上托盘」
        //     降级成**原因**；它**仍然**在「待你处理」里。
        var ready = OwnershipRowFacts(objectID: "wish-prop-x")
        ready.jobID = UUID()
        ready.jobStage = .ready
        ready.trayShowsThis = false
        ready.canClaimNow = false
        let unclaimed = ResidentOwnershipProjection.row(ready)
        check(unclaimed.state == .awaitingClaim && unclaimed.group == .needsYou,
              "未领取必须在「待你处理」里，实测 \(unclaimed.state)/\(unclaimed.group)")
        check(unclaimed.statusText == "未领取",
              "stage=ready 那一档的主文案必须是「未领取」（用户原话），实测 \(unclaimed.statusText)")
        check(unclaimed.reasonText?.contains("还没上托盘") == true,
              "「还没上托盘」必须降级到**原因**里说出来（不是主文案，也不许丢），实测 \(unclaimed.reasonText ?? "nil")")
        check(unclaimed.actions == [.askResidentToFetch],
              "够不到许愿机时给的是「让居民去取」（既有 agent 路径），实测 \(unclaimed.actions)")
        ready.trayShowsThis = true
        ready.canClaimNow = true
        let claimable = ResidentOwnershipProjection.row(ready)
        check(claimable.statusText == unclaimed.statusText,
              "托盘上有没有它**不许**改变那一档的主文案：领没领只有一个答案，实测 \(claimable.statusText) / \(unclaimed.statusText)")
        check(claimable.reasonText == nil,
              "上了托盘就不该再留「还没上托盘」的原因，实测 \(claimable.reasonText ?? "nil")")
        check(claimable.actions == [.claim], "够得到时给「领取」，实测 \(claimable.actions)")

        // (f2) 持久化的渲染失败**不许**把一件已经就绪、也确实能领的东西从列表里说成"失败"
        //      —— 真机那台电视 `stage=ready`、资产完好，却因为一条旧结论永久上不了托盘。
        //      它必须仍然是「未领取」，失败降级成徽标 + 具名原因。
        var renderFailed = ready
        renderFailed.trayShowsThis = false
        renderFailed.canClaimNow = false
        renderFailed.renderFailureMessage = "成品场景加载失败：许愿机产物的尺寸无效，暂时无法显示。"
        let renderRow = ResidentOwnershipProjection.row(renderFailed)
        check(renderRow.state == .awaitingClaim && renderRow.group == .needsYou,
              "场景加载失败不该把「未领取」改成失败，实测 \(renderRow.state)/\(renderRow.group)")
        check(renderRow.badges.contains("场景加载失败"), "失败必须可见（徽标），实测 \(renderRow.badges)")
        check(renderRow.reasonText == renderFailed.renderFailureMessage,
              "失败原因必须是权威那一句原话")
        check(renderRow.actions.isEmpty,
              "托盘永远显示不出它时不给「让居民去取」（那是一句做不到的承诺），实测 \(renderRow.actions)")

        // (g) G2：生成失败那行必须留在「待你处理」并给出「重试」
        var failed = OwnershipRowFacts(objectID: "wish-prop-y")
        failed.jobID = UUID()
        failed.jobStage = .failed
        failed.lastError = "size_intent.longest.meters = 1443，期望 1.443"
        failed.canRetryNow = true
        let failure = ResidentOwnershipProjection.row(failed)
        check(failure.state == .failed && failure.group == .needsYou,
              "生成失败必须留在「待你处理」，实测 \(failure.state)/\(failure.group)")
        check(failure.actions.contains(.retry), "失败行必须给得出「重试」")
        check(failure.reasonText == failed.lastError, "失败原因必须是权威那一句原话（带字段与数值）")

        // (g2) 已领取但没入库存：下一步是**既有**的入库补做，不是重新生成
        //      （`retry` 的阶段判据刻意不含 `.claimed`）。
        var notSaved = OwnershipRowFacts(objectID: "wish-prop-w")
        notSaved.jobID = UUID()
        notSaved.jobStage = .claimed
        notSaved.claimReceiptPresent = false
        // 「这条补做路今天真的走得通」由宿主读出来（`WorldState.canRedoInventoryRegistration`，
        // 与 `applyPropLayout(.register)` 的回执去重同源）—— 做不到就不给按钮。
        // 这一支要钉的是"给得出下一步"，所以这里按**走得通**输入。
        notSaved.canRedoInventoryRegistration = true
        let backlog = ResidentOwnershipProjection.row(notSaved)
        check(backlog.statusText == "已领取，入库尚未保存", "实测 \(backlog.statusText)")
        check(backlog.state == .failed && backlog.group == .needsYou,
              "已领取未入库必须在「待你处理」里（绝不许折叠进「已结束」），实测 \(backlog.state)/\(backlog.group)")
        check(backlog.actions == [.retryInventoryRegistration],
              "没入库存那一行必须给「重试入库」（既有 register 路径），实测 \(backlog.actions)")
        // 「说得出为什么」仍是判据，但说法是**人话**（2026-10-02：那三条大字面改成一句
        // 人话，本文件不再要求原因里出现 `layoutReceipts` 这种字段名）：不出现字段名 /
        // 回执键 / UUID，而且「回执在」与「回执不在」两档说的**不是同一句** —— 说得具体，
        // 不是套一句模板。文案逐字归 `tools/test-user-facing-copy.swift` 管，这里不钉死。
        let noReceiptReason = backlog.reasonText ?? ""
        check(!noReceiptReason.isEmpty, "说「没保存」就必须说得出来为什么，实测 \(noReceiptReason)")
        check(noReceiptReason.range(of: "[A-Za-z_]", options: .regularExpression) == nil,
              "「没保存」的原因必须是人话（不出现字段名 / 回执键 / UUID），实测 \(noReceiptReason)")
        var withReceipt = notSaved
        withReceipt.claimReceiptPresent = true
        let withReceiptReason = ResidentOwnershipProjection.row(withReceipt).reasonText ?? ""
        check(!withReceiptReason.isEmpty && withReceiptReason != noReceiptReason,
              "有回执 / 没回执两档的原因必须分得开（「是哪一个」说得出），实测 \(withReceiptReason) / \(noReceiptReason)")
        check(backlog.evidence.contains { $0.field.hasPrefix("layoutReceipts[claimed.") },
              "展开里必须有 layoutReceipts 的 evidence")
        // 同一行、同一条事实：补做**走不通**时按钮**不摆出来**（一句做不到的承诺比没有按钮更坏），
        // 但那一行、那句话、那个原因一个字都不许少 —— 可见性不由"能不能动"决定。
        var cannotRedoSave = notSaved
        cannotRedoSave.canRedoInventoryRegistration = false
        let noRedo = ResidentOwnershipProjection.row(cannotRedoSave)
        check(noRedo.actions.isEmpty,
              "补做走不通时不许摆出做不到的按钮，实测 \(noRedo.actions)")
        check(noRedo.statusText == backlog.statusText && noRedo.state == backlog.state
              && noRedo.reasonText == backlog.reasonText,
              "能不能补做只影响动作，不影响那一行在不在、那句话说不说")

        // (h) 已结束的三兄弟：默认折叠，且**计数可见**
        var cancelled = OwnershipRowFacts(objectID: "wish-prop-z")
        cancelled.jobID = UUID()
        cancelled.jobStage = .cancelled
        let ended = ResidentOwnershipProjection.row(cancelled)
        check(ended.state == .ended && ended.isFoldedByDefault && ended.statusText == "已取消",
              "已取消 ⇒ 折叠的「已结束」，实测 \(ended.state)/\(ended.statusText)")

        for failure in failures { print("FAIL: " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
"""#
let authority = compileAndRun(authorityProgram, projection: projectionSource)
if authority.0 != 0 {
    print(authority.1.trimmingCharacters(in: .whitespacesAndNewlines))
    print("FAIL: 投影的状态判据没通过"); exit(1)
}
print("PASS[1-3]: 状态 = f(权威)（isEnabled / heldProp / propTombstones 各自改变行状态）；墓碑必被读到；未领取/失败/已结束各归其位")

// ── 判据 1：真机数据离线复核 —— 7 条 job ⇒ 7 行 ────────────────────────────────
let wishesPath = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/gmgn radio/WishMachine/wishes.json")
let statePath = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json")
guard FileManager.default.fileExists(atPath: wishesPath.path),
      FileManager.default.fileExists(atPath: statePath.path) else {
    print("SKIP: 这台机器上没有真机档案（wishes.json / state.json），真机复核没跑")
    print("PASS(projection-only): 真机复核被跳过；投影判据全绿")
    exit(0)
}

let replayProgram = #"""
// 世界那一轴：`state.json` 的形状逐字取自生产（`WorldObjectState.isEnabled` /
// `WorldGeneratedProp` 的元数据键 `gmgn.generated-prop.v1`，上面 assert 过那个键）。
struct RealEvent: Decodable { let wishID: String; let kind: String; let failureSource: String?; let message: String? }
struct RealArchive: Decodable { let jobs: [WishMachineJob]; let events: [RealEvent]? }
struct RealGeneratedProp: Decodable {
    let objectID: String
    let sourceWishID: String?
    let displayName: String?
    let size: RealSize?
}
struct RealSize: Decodable { let x: Double; let y: Double; let z: Double }
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
/// 回执的值是生产里的 `WorldPropLayoutCommand`（一个对象）。复核只关心**这个键在不在**
/// —— 所以形状不敏感地解一下，不在这里复刻那条命令的字段。
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

@main struct Replay {
    static func longestEdgeText(_ size: RealSize?) -> String? {
        guard let size else { return nil }
        return String(format: "最长边 %.2f m", max(size.x, max(size.y, size.z)))
    }
    static func main() throws {
        let wishesURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/gmgn radio/WishMachine/wishes.json")
        let stateURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json")
        let archive = try JSONDecoder().decode(RealArchive.self, from: Data(contentsOf: wishesURL))
        let world = try JSONDecoder().decode(RealWorld.self, from: Data(contentsOf: stateURL))
        // **存档回放 ≠ 现场**：`wishes.json` 的 `events[]` 里那条 `failureSource == "renderer"`
        // 是**上一次推导说过什么**的存档，不是"这一刻舞台渲染成什么样"。
        //
        // 生产读的是**现场**（`GMGNRadioApp.residentPropWishFacts`：
        // `spatialStage.residentPropRenderStatuses[objectID]`），离线复核没有舞台 ——
        // 所以这里把它**只当记录**数出来（下面打印），**绝不**灌进
        // `OwnershipRowFacts.renderFailureMessage`：拿一条存档里的旧结论当动作判据，
        // 会让一件其实能领的东西变成"动作空"，而那是生产永远不会有的形状
        // （真机 2026-10-02 那台电视就是因为信了这条旧结论，永久上不了托盘）。
        let archivedRenderFailures = (archive.events ?? [])
            .filter { $0.kind == "failed" && $0.failureSource == "renderer" }

        // ── 连接（**只正向**）：job.objectID == object.objectID，
        //    兜底 job.id.uuidString == object.sourceWishID。**绝不反解 objectID**。 ──
        var facts: [OwnershipRowFacts] = []
        var order: [String: Int] = [:]
        var matchedObjectIDs: Set<String> = []
        var claimedWithoutReceipt: [String] = []
        var receiptWithoutObject: [String] = []
        /// `stage == "claimed"` 而世界里**没有**它的那些 job：这正是投影里
        /// `case .claimed:` 那一支（「已领取，入库尚未保存」）的**唯一**判据。
        /// 期望值由它数出来，不写死某一天的 3。
        var claimedWithoutObject: [String] = []
        /// 「把存档回放当成现场渲染状态」的**可判定**记录（见下面 `f.renderFailureMessage = nil`
        /// 那一行后面的检查）。单独收在一处，是因为 `failures` 在循环之后才声明。
        var archiveRenderFailureLeaks: [String] = []
        for (index, job) in archive.jobs.enumerated() {
            var objectID = job.objectID
            var object = world.objectStates[job.objectID]
            var bySourceWish = false
            if object?.generatedProp?.objectID != job.objectID {
                if let found = world.objectStates.first(where: { $0.value.generatedProp?.sourceWishID == job.id.uuidString }) {
                    objectID = found.key; object = found.value; bySourceWish = true
                } else { object = nil }
            }
            let tombstone = world.propTombstones?[objectID]
            let receipt = world.layoutReceipts?["claimed." + job.id.uuidString] != nil
            var f = OwnershipRowFacts(objectID: objectID)
            f.jobID = job.id
            f.jobName = job.name
            f.jobStage = OwnershipJobStage(rawValue: job.stage.rawValue)
            f.remoteState = job.remoteState?.rawValue
            f.lastError = job.lastError
            f.cancelRequested = job.cancelRequested == true
            // **现场语义**：离线复核读不到舞台，所以如实置 nil（= 读不到），
            // 而不是把存档里那条旧结论当成现场事实 —— 见上面 `archivedRenderFailures`。
            f.renderFailureMessage = nil
            // 上面那句话必须**可判定**，不能只是一句注释：谁把这个字段填上（= 拿存档
            // 回放当现场），这里当场记下来。为什么非要在这里判：文件尾那条
            // `stale-archive-as-action-judge` 负对照注入的正是这一行，而它原来靠的是
            // "未领取行必须给得出下一步" —— 现场 `wishes.json` 今天一条 `ready` 都没有
            // （2026-10-02 17:32：7 条全 `claimed`），那条判据会**空转**，负对照于是
            // 抓不到任何缺陷（"门禁从不 FAIL"）。这条不依赖现场有没有 ready：
            // 只要谁把存档塞进这个字段，它就红。
            if f.renderFailureMessage != nil {
                archiveRenderFailureLeaks.append("\(job.name)｜\(job.objectID)")
            }
            f.processOrder = index
            f.objectPresent = object?.generatedProp != nil
            f.objectHasGeneratedProp = object?.generatedProp != nil
            f.objectName = object?.generatedProp?.displayName
            f.objectIsEnabled = object?.isEnabled == true
            f.heldSlot = (world.heldProp?.objectID == objectID) ? world.heldProp?.hand : nil
            f.tombstoneName = tombstone?.displayName
            f.tombstoneReason = tombstone?.reason
            f.claimReceiptPresent = receipt
            f.matchedBySourceWishID = bySourceWish
            f.sizeText = longestEdgeText(object?.generatedProp?.size)
            // 会话内事实（重启即消失）离线复核里没有，如实置空：它们只影响"现在能不能点"
            // 与"入库尚未保存的原话"，不影响"这一行在不在"。
            f.trayShowsThis = false
            f.canClaimNow = false
            f.canRetryNow = true
            if job.stage.rawValue == "claimed", !receipt { claimedWithoutReceipt.append("\(job.name)｜\(job.objectID)") }
            if receipt, object?.generatedProp == nil { receiptWithoutObject.append("\(job.name)｜\(job.objectID)") }
            if job.stage.rawValue == "claimed", object?.generatedProp == nil { claimedWithoutObject.append("\(job.name)｜\(job.objectID)") }
            if f.objectPresent { matchedObjectIDs.insert(objectID) }
            facts.append(f)
            order[OwnershipRowKey(jobID: job.id, objectID: objectID).identifier] = index
        }
        // 孤儿行：有物件、没有 job（照常显示并标注）。
        for (objectID, object) in world.objectStates.sorted(by: { $0.key < $1.key }) {
            guard !matchedObjectIDs.contains(objectID), let prop = object.generatedProp else { continue }
            var f = OwnershipRowFacts(objectID: objectID)
            f.objectPresent = true
            f.objectHasGeneratedProp = true
            f.objectName = prop.displayName
            f.objectIsEnabled = object.isEnabled
            f.heldSlot = (world.heldProp?.objectID == objectID) ? world.heldProp?.hand : nil
            f.tombstoneName = world.propTombstones?[objectID]?.displayName
            f.sizeText = longestEdgeText(prop.size)
            matchedObjectIDs.insert(objectID)
            facts.append(f)
        }
        // 只剩墓碑的：也必须有行（折叠在「已结束」里）。
        for (objectID, tombstone) in (world.propTombstones ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !matchedObjectIDs.contains(objectID) else { continue }
            var f = OwnershipRowFacts(objectID: objectID)
            f.tombstoneName = tombstone.displayName
            f.tombstoneReason = tombstone.reason
            facts.append(f)
        }

        let rows = facts.map(ResidentOwnershipProjection.row)
        print("── 真机逐行（生产投影 ResidentOwnershipProjection.row）──")
        print("wishes.json job = \(archive.jobs.count)｜state.json objectStates = \(world.objectStates.count)｜propTombstones = \(world.propTombstones?.count ?? 0)｜layoutReceipts 里的 claimed.* = \(world.layoutReceipts?.keys.filter { $0.hasPrefix("claimed.") }.count ?? 0)")
        print("存档回放（**不作判据**）：wishes.json events[] 里 failureSource=renderer 的失败 \(archivedRenderFailures.count) 条 —— 生产读的是**现场**舞台渲染状态，不是这条存档")

        func render(_ budget: Int, _ label: String) {
            print("")
            print("【\(label)】")
            let listed = ResidentOwnershipProjection.list(rows, order: order, showsEnded: true, rowBudget: budget)
            for section in listed.sections {
                print("[\(ResidentOwnershipProjection.sectionTitle(section))] 共 \(section.totalCount) 件\(section.isFolded ? "（默认折叠，点开可见）" : "")")
                for row in section.rows {
                    var line = "  · \(row.name) — \(row.state.label)｜\(row.statusText)"
                    if let reason = row.reasonText { line += "\n      原因：\(reason)" }
                    if !row.actions.isEmpty { line += "\n      动作：\(row.actions.map(\.label).joined(separator: " / "))" }
                    if !row.badges.isEmpty { line += "｜徽标：\(row.badges.joined(separator: " / "))" }
                    print(line)
                }
            }
            if listed.remainingCount > 0 { print("还有 \(listed.remainingCount) 件") }
        }
        // 面板的真实预算（190 pt / 6 行）与"全部展开"各看一次：前者是用户看到的，
        // 后者证明**一件都没丢**。
        render(ResidentOwnershipProjection.visibleRowBudget, "面板预算 \(ResidentOwnershipProjection.visibleRowBudget) 行（高度 \(ResidentOwnershipProjection.panelListHeightPoints) pt，宽度 340 不动）")
        render(rows.count + 8, "不设预算（证明一件都没丢）")

        // ── 判据：7 件东西一件都不许消失 ──
        var failures: [String] = []
        // 「现场语义」那一条的判定（记录在循环里，见 `archiveRenderFailureLeaks`）：
        // 一条都不许有 —— 有就是拿存档回放当了现场。
        for leak in archiveRenderFailureLeaks {
            failures.append("「\(leak)」的渲染失败来自**存档回放**，不是现场 —— 生产读的是 `spatialStage.residentPropRenderStatuses[objectID]`")
        }
        let unbounded = ResidentOwnershipProjection.list(rows, order: order, showsEnded: true, rowBudget: rows.count + 8)
        let visible = Set(unbounded.sections.flatMap { $0.rows }.map(\.key.objectID))
        let foldedGroups = Set(unbounded.sections.filter(\.isFolded).map(\.group))
        if rows.count != archive.jobs.count {
            failures.append("行数 \(rows.count) ≠ job 条数 \(archive.jobs.count)（一件都不许消失）")
        }
        // C3：同一件东西**不许出现两行**（行键必须唯一：jobID 为主、objectID 为从）。
        let objectIDs = rows.map(\.key.objectID)
        if Set(objectIDs).count != objectIDs.count {
            failures.append("同一件东西出现了不止一行（行键不唯一）")
        }
        // C3：权威里**没有**它，就绝不许说成「已摆放」。
        for row in rows where !facts.first(where: { $0.objectID == row.key.objectID })!.objectPresent {
            if row.state == .placed { failures.append("「\(row.name)」权威里没有记录，却被标成已摆放") }
        }
        for job in archive.jobs {
            guard let row = rows.first(where: { $0.key.jobID == job.id }) else {
                failures.append("许愿「\(job.name)」在列表里彻底消失了"); continue
            }
            let mayBeFolded = foldedGroups.contains(row.group)
            if !visible.contains(row.key.objectID), !mayBeFolded {
                failures.append("许愿「\(job.name)」既不可见、也没折叠进「已结束」")
            }
            if row.state == .ended, job.stage.rawValue == "ready" {
                failures.append("未领取的「\(job.name)」被折叠进了「已结束」—— 用户正是为这个抱怨的")
            }
            if row.state == .ended, job.stage.rawValue == "claimed" {
                failures.append("已领取但没入库的「\(job.name)」被折叠进了「已结束」—— 那一档一件都不许折叠")
            }
        }
        // 期望值**从输入推导**（见文件头第 1 条与上面 `claimedWithoutObject` 的注释）：
        // 判据强度一个字没变 —— 仍然是"**每一条**该在这一档的东西都必须真的在这一档、
        // 一条都不许漏"，只是不再假设那一天的数字。旧写法把"输入快照"当成了判据：
        // 现场从 2 + 3 漂到 0 + 5 之后，它红的理由与列表对不对毫无关系。
        let expectedAwaiting = archive.jobs.filter { $0.stage.rawValue == "ready" }.count
        let expectedNotSaved = claimedWithoutObject.count
        let awaiting = rows.filter { $0.state == .awaitingClaim }
        let notSaved = rows.filter { $0.statusText == "已领取，入库尚未保存" }
        if awaiting.count != expectedAwaiting {
            failures.append("输入里有 \(expectedAwaiting) 件未领取（stage=ready），列表里只数得出 \(awaiting.count) 件 —— 一件都不许漏，也不许凭空多")
        }
        if notSaved.count != expectedNotSaved {
            failures.append("输入里有 \(expectedNotSaved) 件「已领取但没写进库存」（stage=claimed 且世界里没有它），列表里只数得出 \(notSaved.count) 件")
        }
        for row in notSaved where row.reasonText?.isEmpty != false {
            failures.append("「\(row.name)」说了入库尚未保存，却没说为什么")
        }
        // **陈旧失败只作徽标，动作由现场状态派生**：真机存档里那条 renderer 失败不许
        // 参与离线复核的动作判据（生产读现场）。所以那两条 ready 行必须**给得出下一步**；
        // 「动作空」是拿存档当现场才会有的形状，生产永远不会那样。
        for row in awaiting where row.actions.isEmpty {
            failures.append("「\(row.name)」的「未领取」行没有任何下一步 —— 那是拿存档里的陈旧失败当动作判据了（生产读现场，不会有这一条）")
        }
        // 同源不同源必须说得清：同一个「渲染失败」概念，生产读**现场**、这里读**存档**；
        // 生产那一句必须真的读现场（否则这条离线复核就在替一条不存在的规则背书）。
        let appSourceForFacts = (try? String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift",
                                              encoding: .utf8)) ?? ""
        if !appSourceForFacts.contains("spatialStage.residentPropRenderStatuses[objectID]") {
            failures.append("生产投影必须读**现场**的渲染状态（residentPropRenderStatuses），不是 wishes.json 里那条旧结论")
        }
        // 对账（与 tools/reconcile-generation-results.py 同一个答案）：
        // 有回执 ⇒ 权威里一定有它。反过来的缺口就是这次要修的那 3 件。
        for missing in receiptWithoutObject {
            failures.append("有 claimed 回执、库存里却没有：\(missing)")
        }
        print("")
        print("统计：未领取 \(awaiting.count)｜已领取入库尚未保存 \(notSaved.count)｜已摆放 \(rows.filter { $0.state == .placed }.count)｜在库里 \(rows.filter { $0.state == .inInventory }.count)｜失败 \(rows.filter { $0.state == .failed }.count)｜已结束 \(rows.filter { $0.state == .ended }.count)")
        print("对账：job stage=claimed 而 layoutReceipts 里没有 claimed.<jobID> 的有 \(claimedWithoutReceipt.count) 件")
        for item in claimedWithoutReceipt { print("  · \(item)") }
        for failure in failures { print("FAIL: " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
"""#
let replay = compileAndRun(replayProgram, projection: projectionSource,
                          extra: generationClientSource + "\n" + stageSource + "\n" + jobSource)
print(replay.1.trimmingCharacters(in: .whitespacesAndNewlines))
guard replay.0 == 0 else { print("FAIL: 真机逐行复核没通过"); exit(1) }
print("")
print("PASS[2-real]: 真机每条 job ⇒ 一行、一件都不许消失（未领取 / 已领取未入库的期望值都由同一份输入推导，逐行见上）")

// ── 契约（C1-C5）：那一行真的能动手，而且走的是**既有**那条路；面板不长第二套文案 ──
//
// 这几条是**只读**断言（读生产源码，不改）：面板那一行如果自己造一条通道、
// 或者自己再编一套状态词，用户就会看到与投影不一样的话 —— 那正是 C3 说的"第四套文案"。
let editorStateSource = try read("apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift")
let editorViewSource = try read("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift")
let appSource = try read("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")

/// C1-C5 的契约违规项。**注入负对照要的就是"这里非空"**。
func contractViolations(state: String, view: String, app: String) -> [String] {
    var failures: [String] = []
    func contract(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }
    // C2：「未领取」那一行能领，走**既有**的 `WishMachineCoordinator.claim`（不是新通道）。
    contract(state.contains("var claimWishOutput: (@MainActor (String) async throws -> Void)?"),
             "面板没有接到宿主的领取入口")
    contract(view.contains("if row.actions.contains(.claim)"),
             "行内「领取」不是由**投影派生的动作**摆出来的（那就成了一份新的可见性判据）")
    contract(view.contains("await state.claimWish(jobID: jobID)"), "行内「领取」没有接到面板动作上")
    contract(app.contains("wishMachineCoordinator.claim(id: wishID"),
             "「领取」没有走既有的 WishMachineCoordinator.claim（那是一条新的人类通道）")
    // 动作出口**只有一处**，并且有"进行中"守卫 ⇒ 重复点击只提交一次。
    contract(state.contains("private func performWishAction(jobID: String, step: String,")
             && state.contains("guard isOpen, !isSaving else { return }"),
             "许愿动作的出口不是唯一一处 / 没有进行中守卫（重复点击会提交多次）")
    // 「同一 (任务, 动作) 在一次用户意图内只提交一次」：上面那条 `isSaving` 只挡**在飞**
    // 的那一次，真机上相隔一秒多的第二次激活落在它放开之后，于是同一个任务第二次交给
    // 居民（2026-10-02 16:56:03.446 / 04.928 同一任务两条 `ask-resident`）。幂等台账缺席 ⇒ FAIL。
    contract(state.contains("private var submittedWishActions = WishActionLedger()"),
             "许愿动作没有幂等台账（连点 / 界面重放会第二次交给居民）")
    contract(state.contains("guard submittedWishActions.admits(jobID: jobID, step: step) else {"),
             "重复提交没有被挡在唯一那个动作出口上")
    contract(state.contains("submittedWishActions.record(jobID: jobID, step: step)"),
             "提交成功没有记账，第二次点击仍然会再交给居民一次")
    contract(state.contains("\n        pruneSubmittedWishActions()\n"),
             "台账不随投影剪枝（行换了动作或已入库之后这一行就再也点不动了）")
    contract(state.contains("notice = Self.submittedText(for: step)"),
             "重复调用没有走幂等出口（同一次的结果应当原样返回，而不是改口或再发一次）")
    contract(state.contains("step: \"claim\", action: claimWishOutput"),
             "「领取」没有从唯一那个动作出口走")
    // Q4：够不到许愿机 ⇒ 按钮**可见但置灰** + 一行可读原因 + 「让居民去取」（既有 agent 路径）。
    contract(view.contains("Button(\"领取\") {}.disabled(true)"), "Q4：够不到许愿机时「领取」必须可见但置灰")
    contract(view.contains("await state.askResidentToFetch(jobID:")
             && app.contains("askResidentToFetchProp(jobID: jobID)"),
             "「让居民去取」没有走既有 agent 路径（claim_when_arrived）")
    // C5：失败行给「重试」，走既有 `retry`；「已领取未入库」给「重试入库」（不是重新生成）。
    contract(view.contains("if row.actions.contains(.retry)"), "失败行没有「重试」入口")
    contract(app.contains("wishMachineCoordinator.retry(id: wishID"), "「重试」没有走既有的 coordinator.retry")
    contract(view.contains("if row.actions.contains(.retryInventoryRegistration)"),
             "「已领取未入库」那一行没有可操作的下一步")
    // C3：面板**不许**再自己编状态词 —— 视图那段代码里一个状态字面量都不该有。
    for word in ["尚未摆放", "已摆出", "手持中", "可领取", "等待入库", "未摆放", "已摆放"] {
        contract(!stripped(view).contains(word),
                 "面板视图里出现了自己的状态词「\(word)」—— 状态文案只能来自唯一投影")
    }
    contract(view.contains("Text(row.statusText)"), "面板那一行必须渲染投影给的那一句")
    contract(state.contains("snapshot.ownershipFacts.map(ResidentOwnershipProjection.row)"),
             "面板的行不是从唯一投影现算的")
    return failures
}
let contractState = editorStateSource, contractView = editorViewSource, contractApp = appSource
let contractFailures = contractViolations(state: contractState, view: contractView, app: contractApp)
if !contractFailures.isEmpty {
    for failure in contractFailures { print("FAIL: " + failure) }
    exit(1)
}
print("PASS[contract]: 领取/重试/重试入库/让居民去取都走**既有**那条路；面板视图零状态字面量（唯一出口是投影）")
for (name, source, anchor, replacement) in [
    ("no-claim-entry", contractView, "if row.actions.contains(.claim)", "if false"),
    ("claim-not-existing-path", contractApp, "wishMachineCoordinator.claim(id: wishID",
     "wishMachineCoordinator.claimUnused(id: wishID"),
    ("fourth-vocabulary-in-panel", contractView, "Text(row.statusText)", "Text(\"已摆出\")"),
    // 幂等台账三条注入：去掉放行判据 / 去掉记账 / 去掉剪枝。
    ("ask-duplicate-never-blocked", contractState,
     "guard submittedWishActions.admits(jobID: jobID, step: step) else {", "guard true else {"),
    ("ask-duplicate-not-recorded", contractState,
     "submittedWishActions.record(jobID: jobID, step: step)", "_ = step"),
    ("ask-ledger-never-pruned", contractState, "\n        pruneSubmittedWishActions()\n", "\n"),
] {
    guard source.contains(anchor) else {
        print("FAIL: 契约负对照「\(name)」的注入点找不到（等于没有负对照）"); exit(1)
    }
    let mutated = source.replacingOccurrences(of: anchor, with: replacement)
    // 注入必须落在**它自己那一个槽位**上：早先这里按"不是视图就当 app"处理，
    // 于是注入 `ResidentPropEditorState` 时被 app 槽位的检查先接住，报的是别人的
    // 违规 —— 那等于这条负对照没有真的证明它要证的那一条。
    let final = contractViolations(state: source == contractState ? mutated : contractState,
                                   view: source == contractView ? mutated : contractView,
                                   app: source == contractApp ? mutated : contractApp)
    guard !final.isEmpty else {
        print("FAIL: 契约负对照「\(name)」注入后没有报违规"); exit(1)
    }
    print("PASS[negative-\(name)]: 注入 ⇒ FAIL：\(final[0])")
}

// ── 同一 (任务, 动作) 只提交一次：台账的**行为**（不是源码里的字样） ────────────────
//
// 真机 2026-10-02 16:56:03.446 与 04.928 是**同一个任务**的两条 `ask-resident`：
// 唯一那个出口上原来只有 `isSaving`，而它只挡"在飞"的那一次，所以第二次激活又提交
// 了一遍。这里把生产里那份纯台账原文编译进来，按"连点 / 同步重放 / 行换了动作 /
// 关面板重开"四种情形复现它。
guard let ledgerSource = declaration(editorStateSource, "struct WishActionLedger: Equatable {") else {
    print("FAIL: 找不到 WishActionLedger —— 幂等台账不在生产源码里"); exit(1)
}
let ledgerRun = compileAndRun(#"""
@main struct Harness {
    static func main() {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL: \(message)") }
        }
        let job = "0C285296-9164-4A2B-8FB7-6648E549A4AE"
        var ledger = WishActionLedger()
        check(ledger.admits(jobID: job, step: "ask-resident"), "第一次提交必须放行")
        ledger.record(jobID: job, step: "ask-resident")
        check(!ledger.admits(jobID: job, step: "ask-resident"),
              "连点第二次必须被挡下，否则同一个任务会再交给居民一次（真机 16:56:03.446 / 04.928）")
        check(!ledger.admits(jobID: job, step: "ask-resident"),
              "同步重放的第三次同样被挡下")
        check(ledger.admits(jobID: job, step: "claim"),
              "同一任务换成另一个动作是新的意图，必须放行")
        check(ledger.admits(jobID: "AEFC68E1-91D4-42F6-AA6A-ED35EDDF9613", step: "ask-resident"),
              "另一个任务必须独立放行")
        ledger.record(jobID: job, step: "claim")
        ledger.keepOnly([WishActionLedger.key(jobID: job, step: "claim")])
        check(ledger.admits(jobID: job, step: "ask-resident"),
              "行不再提供那个动作后必须放掉台账，否则这一行以后点不动")
        check(!ledger.admits(jobID: job, step: "claim"), "此刻仍提供的动作依旧只提交一次")
        ledger.removeAll()
        check(ledger.admits(jobID: job, step: "claim"), "关面板 / 换世界后是新意图，必须重新放行")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) wish action ledger checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#, projection: ledgerSource)
guard ledgerRun.0 == 0 else {
    print("FAIL: 幂等台账行为复核失败\n\(ledgerRun.1)"); exit(1)
}
print("PASS[ask-dedup]: " + ledgerRun.1.trimmingCharacters(in: .whitespacesAndNewlines))

// ── 「一个投影，五处消费」（设计 §8.3）+ **第四套状态词的全局门禁** ───────────────
//
// 五处 = 列表（`state.ownershipList`）/ 房间里（同一批行按 group 过滤）/ 托盘
// （`rows.filter { $0.room == .placed }`）/ 任务行（`currentStatus` 委托
// `sentence(...)`）/ agent 的 `read_owned_props`（回执里的 `ownership_state` /
// `ownership_status`）。三条这次要接的消费面（任务行 / 托盘 / agent 回执）**逐字**
// 钉在这里：各自再写一套状态词 ⇒ FAIL。
let presentationSource = try read("apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift")
let bridgeSource = try read("apps/macos/Sources/GMGNRadio/Agent/ResidentPropToolBridge.swift")

/// **第四套状态词**：与投影那五种状态重复的**自造同义词**（外加这次退役掉的
/// 「待领取」）。它们出现在**任何界面 / 回执的代码里** ⇒ FAIL。
/// 注释里提到这些名字不算 —— 那是退役记录本身（与
/// `test-no-long-term-memory-capability.swift` 同一手法）。
let fourthVocabulary = ["已摆出", "手持中", "尚未摆放", "待领取"]
/// 被这次收口从**任务行**退役的第二套状态词：只允许出现在唯一投影里。
let retiredTaskLineVocabulary = ["可领取", "等待入库", "未摆放", "排队中"]

/// 五处消费同一个投影的违规项。**注入负对照要的就是"这里非空"**。
func singleProjectionViolations(state: String, view: String, app: String,
                                presentation: String, bridge: String) -> [String] {
    var failures: [String] = []
    func guardrail(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }

    // **全局第一条**：任何界面 / 回执的**代码**里出现第四套自造状态词 ⇒ FAIL。
    // 放在最前面，是为了让"注入自造词"的 FAIL 原话就是这一条（而不是被别的判据先接住）。
    for (name, source) in [("列表", state), ("面板", view), ("托盘/宿主", app),
                           ("任务行", presentation), ("agent 回执", bridge)] {
        let code = stripped(source)
        for word in fourthVocabulary where code.contains(word) {
            failures.append("\(name)的代码里出现了第四套状态词「\(word)」—— 状态词只有唯一投影那一份")
        }
    }

    // ① 列表 / ② 房间里：同一批行（`ResidentOwnershipProjection.row`），视图只读 `row.statusText`。
    guardrail(state.contains("snapshot.ownershipFacts.map(ResidentOwnershipProjection.row)"),
              "列表的行不是从唯一投影现算的")
    guardrail(view.contains("Text(row.statusText)"), "列表那一行必须渲染投影给的那一句")

    // ③ 托盘输出列表：必须**字面**消费投影，不再是它自己的 `filter(\.isEnabled)`。
    guardrail(app.contains("rows.filter { $0.room == .placed }"),
              "托盘输出列表没有字面消费投影（`.filter { $0.room == .placed }` 不见了）")
    guardrail(!stripped(app).contains("objectStates.values.filter(\\.isEnabled)"),
              "托盘又按自己的 `objectStates...filter(\\.isEnabled)` 判「在房间里」了 —— 那是第二套可见性判据")

    // ④ 任务行：那一句必须委托给投影的 `sentence(...)`，且不许再有第二套字面量。
    guardrail(presentation.contains("ResidentOwnershipProjection.sentence("),
              "任务行那一句没有委托给唯一投影 ResidentOwnershipProjection.sentence(...)")
    for word in retiredTaskLineVocabulary where stripped(presentation).contains(word) {
        failures.append("任务行文件里又出现了第二套状态词「\(word)」—— 那一句只有唯一投影一个出口")
    }

    // ⑤ agent 回执：那两句必须来自注入的投影回答（`ownershipRow`），与列表**同一句话**。
    guardrail(bridge.contains("ownershipRow(objectID)"),
              "read_owned_props 没有向唯一投影问状态（没有注入 `ownershipRow`）")
    guardrail(bridge.contains("result[\"ownership_status\"] = ownership.statusText")
              && bridge.contains("result[\"ownership_state\"] = ownership.state.rawValue"),
              "read_owned_props 回执里的状态不是投影那两句（ownership_state / ownership_status）")
    return failures
}

let fiveConsumerFailures = singleProjectionViolations(
    state: editorStateSource, view: editorViewSource, app: appSource,
    presentation: presentationSource, bridge: bridgeSource)
if !fiveConsumerFailures.isEmpty {
    for failure in fiveConsumerFailures { print("FAIL: " + failure) }
    exit(1)
}
print("PASS[five-consumers]: 列表 / 房间里 / 托盘 / 任务行 / agent 回执消费的是**同一个**投影；五处的代码里 0 个第四套状态词")

/// 注入到某个消费面上，要求上面这条全局断言**变成 FAIL**。
func expectConsumerFailure(_ name: String, _ surface: String, _ anchor: String, _ replacement: String) {
    let originals: [String: String] = ["state": editorStateSource, "view": editorViewSource,
                                       "app": appSource, "presentation": presentationSource,
                                       "bridge": bridgeSource]
    guard let original = originals[surface] else {
        print("FAIL: 负对照「\(name)」指名了一个不存在的消费面 \(surface)"); exit(1)
    }
    guard original.contains(anchor) else {
        print("FAIL: 负对照「\(name)」的注入点找不到（等于没有负对照）"); exit(1)
    }
    let mutated = original.replacingOccurrences(of: anchor, with: replacement)
    guard mutated != original else {
        print("FAIL: 负对照「\(name)」注入没有改变源码"); exit(1)
    }
    let final = singleProjectionViolations(
        state: surface == "state" ? mutated : editorStateSource,
        view: surface == "view" ? mutated : editorViewSource,
        app: surface == "app" ? mutated : appSource,
        presentation: surface == "presentation" ? mutated : presentationSource,
        bridge: surface == "bridge" ? mutated : bridgeSource)
    guard !final.isEmpty else {
        print("FAIL: 负对照「\(name)」注入后没有报违规 —— 这个判据抓不到该缺陷"); exit(1)
    }
    print("PASS[negative-\(name)]: 注入 ⇒ FAIL：\(final[0])")
}

// 「五处消费同一个投影」：任务行 / 托盘 / agent 各写一套 ⇒ 三种注入都必须 FAIL。
expectConsumerFailure("task-line-writes-its-own", "presentation",
                      "ResidentOwnershipProjection.sentence(", "\"可领取\" + proxy(")
expectConsumerFailure("tray-writes-its-own", "app",
                      "rows.filter { $0.room == .placed }",
                      "context.state.objectStates.values.filter(\\.isEnabled)")
expectConsumerFailure("agent-writes-its-own", "bridge",
                      "result[\"ownership_status\"] = ownership.statusText",
                      "result[\"ownership_status\"] = \"已摆出\"")
// 「第四套状态词出现 ⇒ FAIL」：往**面板**里写回「已摆出」这种自造词 ⇒ 必须红
// （回执那一面由上面 `agent-writes-its-own` 一起盖住："任何界面 / 回执"）。
expectConsumerFailure("global-fourth-vocabulary-in-panel", "view",
                      "Text(row.statusText)", "Text(\"已摆出\")")

// ── 注入负对照：每一条都必须让对应判据红 ──────────────────────────────────────
/// 注入到生产投影源码上，要求那个判据**变成 FAIL**。
func expectFailure(_ name: String, _ original: String, _ anchor: String, _ replacement: String,
                   program: String, extra: String = "") {
    guard original.contains(anchor) else {
        print("FAIL: 负对照「\(name)」的注入点找不到（注入本身失效，等于没有负对照）"); exit(1)
    }
    let mutated = original.replacingOccurrences(of: anchor, with: replacement)
    guard mutated != original else {
        print("FAIL: 负对照「\(name)」注入没有改变源码"); exit(1)
    }
    let result = compileAndRun(program, projection: mutated, extra: extra)
    guard result.0 != 0 else {
        print("FAIL: 负对照「\(name)」注入回去之后判据竟然还是绿的 —— 这个判据抓不到该缺陷")
        exit(1)
    }
    let line = result.1.split(separator: "\n").first(where: { $0.hasPrefix("FAIL") })
        .map(String.init) ?? result.1.split(separator: "\n").first.map(String.init) ?? "(无输出)"
    print("PASS[negative-\(name)]: 注入 ⇒ FAIL：\(line)")
}

let replayExtra = generationClientSource + "\n" + stageSource + "\n" + jobSource
// 1a) 把"已领取但没入库"塞进「已结束」⇒ 3 件从「待你处理」消失（用户抱怨的原形）。
expectFailure("hide-claimed-not-saved",
              projectionSource,
              "                state = .failed\n                statusText = OwnershipSentence.inventoryNotSaved.rawValue",
              "                state = .ended\n                statusText = OwnershipSentence.inventoryNotSaved.rawValue",
              program: authorityProgram)
// 1b) 把"未领取"塞进「已结束」⇒ 2 件从未进过列表的那两件继续不可见。
expectFailure("hide-unclaimed",
              projectionSource,
              "                state = .awaitingClaim\n                statusText = OwnershipSentence.awaitingClaim.rawValue",
              "                state = .ended\n                statusText = OwnershipSentence.awaitingClaim.rawValue",
              program: authorityProgram)
// 1d) 把那一档的主文案写回「待领取 · 还没上托盘」⇒ 必须 FAIL（用户拍板：那一档就是「未领取」，
//     "还没上托盘"只能在**原因**里）。
expectFailure("wording-not-unclaimed",
              projectionSource,
              "                statusText = OwnershipSentence.awaitingClaim.rawValue",
              "                statusText = \"待领取 · 还没上托盘\"",
              program: authorityProgram)
// 1c) 把「已结束」整组**隐藏**掉（不是折叠）⇒ 已删除的那件东西连计数都没了。
//     Q1 要的是"折叠可见"：沉默消失正是用户被咬过好几次的那件事。
expectFailure("hide-ended-entirely",
              projectionSource,
              "        let ended = sorted.filter { $0.group == .ended }",
              "        let ended: [OwnershipRow] = []",
              program: authorityProgram)
// 2) 缓存：把"手上的物件一律当已摆放"当成答案 ⇒ 改权威不再改变行状态。
expectFailure("cache-last-state",
              projectionSource,
              "        if facts.heldSlot != nil { return .held }\n        return facts.objectIsEnabled ? .placed : .inventory",
              "        if facts.heldSlot != nil { return .held }\n        return .placed",
              program: authorityProgram)
// 3) 不读墓碑 ⇒ 删掉的东西不再留下「已结束」那一行（也就分不出"有意删除"与"意外丢了"）。
expectFailure("ignore-tombstones",
              projectionSource,
              "if facts.tombstoneName != nil, !facts.objectPresent {",
              "if false, !facts.objectPresent {",
              program: authorityProgram)
// 4) 把派生行做成可落盘 / 把状态做成可解码 / 开一个"从存档读回状态"的入口
//    ⇒ **源码级**判据必须红（这三条不靠编译，靠 `staticViolations`）。
for (name, anchor, replacement) in [
    ("codable-row", "struct OwnershipRow: Equatable, Sendable, Identifiable {",
     "struct OwnershipRow: Equatable, Sendable, Identifiable, Codable {"),
    ("codable-state", "enum OwnershipDisplayState: String, Sendable, CaseIterable {",
     "enum OwnershipDisplayState: String, Codable, CaseIterable {"),
    ("raw-value-entry", "enum OwnershipDisplayState: String, Sendable, CaseIterable {",
     "enum OwnershipDisplayState: String, Sendable, CaseIterable {\n    init?(rawValue: String) { return nil }"),
] {
    let mutated = projectionSource.replacingOccurrences(of: anchor, with: replacement)
    guard mutated != projectionSource, !staticViolations(mutated).isEmpty else {
        print("FAIL: 源码级负对照「\(name)」注入后没有报违规"); exit(1)
    }
    print("PASS[negative-\(name)]: 注入 ⇒ FAIL：\(staticViolations(mutated)[0])")
}

// 真机那一条的负对照：同样的注入要让**真机逐行**也红（证明它抓的是真机数据上的缺陷）。
expectFailure("hide-claimed-not-saved-on-real-data",
              projectionSource,
              "                state = .failed\n                statusText = OwnershipSentence.inventoryNotSaved.rawValue",
              "                state = .ended\n                statusText = OwnershipSentence.inventoryNotSaved.rawValue",
              program: replayProgram, extra: replayExtra)

// 「陈旧失败只作徽标：动作由现场状态派生」的负对照：把**存档回放**（`wishes.json` 里那条
// `failureSource == "renderer"`）当成动作判据 ⇒ 真机逐行必须红。
// 生产读的是**现场**舞台渲染状态；拿存档里的旧结论当判据，那两件其实能领的东西会变成
// "动作空" —— 那是生产永远不会有的形状（真机那台电视正是被这条旧结论永久挡住的）。
do {
    let anchor = "            f.renderFailureMessage = nil"
    guard replayProgram.contains(anchor) else {
        print("FAIL: 负对照「stale-archive-as-action-judge」的注入点找不到（等于没有负对照）"); exit(1)
    }
    let mutated = replayProgram.replacingOccurrences(of: anchor, with:
        "            f.renderFailureMessage = archivedRenderFailures.first { $0.wishID == job.id.uuidString }?.message ?? \"场景加载失败\"")
    guard mutated != replayProgram else {
        print("FAIL: 负对照「stale-archive-as-action-judge」注入没有改变程序"); exit(1)
    }
    let result = compileAndRun(mutated, projection: projectionSource, extra: replayExtra)
    guard result.0 != 0 else {
        print("FAIL: 负对照「stale-archive-as-action-judge」注入回去之后竟然还是绿的 —— 这个判据抓不到该缺陷")
        exit(1)
    }
    let line = result.1.split(separator: "\n").first(where: { $0.hasPrefix("FAIL") })
        .map(String.init) ?? "(无 FAIL 行)"
    print("PASS[negative-stale-archive-as-action-judge]: 注入 ⇒ FAIL：\(line)")
}

print("")
print("PASS: 「我的物件」投影 —— 真机逐行不丢件、状态 = f(权威)、墓碑被读到、对外只有五种状态（全部含注入负对照）")
