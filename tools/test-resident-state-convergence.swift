// 状态收敛：三条互不相干的轴（生成/归属/摆放）+ 一个全局开关。
//
// 断言打在**生产源码**与**生产投影**上：本脚本把
// `apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift`
// 整份读进来编译运行，所以"任务行说什么"与"连通性/授权去哪儿了"不可能是测试里的
// 复制品在说话。视图一侧（任务行/横幅）在生产源码文本上校验。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// 变异测试的**只读**覆盖：`GMGN_HARNESS_SOURCE_OVERRIDES="relpath=/abs/path;…"`。
/// 这样可以在**完全不碰仓库**（尤其是不碰正在被另一条线补打的那三个文件）的前提下，
/// 证明下面每条断言真的能抓住缺陷：把一份变异副本放进 /tmp，指向它，看它是否 FAIL。
let sourceOverrides: [String: String] = (ProcessInfo.processInfo
    .environment["GMGN_HARNESS_SOURCE_OVERRIDES"] ?? "")
    .split(separator: ";")
    .reduce(into: [String: String]()) { result, pair in
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        result[String(parts[0])] = String(parts[1])
    }

func productionSource(_ path: String) throws -> String {
    if let override = sourceOverrides[path] {
        return try String(contentsOfFile: override, encoding: .utf8)
    }
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

let presentationPath = "apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift"
let overlayPath = "apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift"
let liveCamPath = "apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift"
let stageControllerPath = "apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"
let settingsPath = "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsView.swift"
let appPath = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
let loopPath = "apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift"
let wishToolsPath = "apps/macos/Sources/GMGNRadio/Agent/ResidentWishMachineTools.swift"
let coordinatorPath = "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift"

let presentationSource = try productionSource(presentationPath)
let overlaySource = try productionSource(overlayPath)
let liveCamSource = try productionSource(liveCamPath)
let stageControllerSource = try productionSource(stageControllerPath)
let settingsSource = try productionSource(settingsPath)
let appSource = try productionSource(appPath)
let loopSource = try productionSource(loopPath)
let wishToolsSource = try productionSource(wishToolsPath)
let coordinatorSource = try productionSource(coordinatorPath)

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

/// 按签名取出一个声明的完整正文（含括号平衡）。用来把任务行的实现单独隔离出来 ——
/// "任务行里没有授权控件"必须在任务行**自己**的正文上成立，而不是在整份文件上。
func declaration(in text: String, _ signature: String) -> String? {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    return nil
}

// ── 断言 1：任务行不含任何**按任务**的授权控件，只表达三轴状态 ──────────────
guard let row = declaration(in: overlaySource, "struct WishMachineTaskStatusView") else {
    print("FAIL: 找不到任务行视图 WishMachineTaskStatusView（任务行的三轴呈现必须存在且可被隔离校验）")
    exit(1)
}
// 单条任务行的正文：授权/连通性必须在**这一层**缺席，而不是只在整份文件里缺席。
guard let rowItem = declaration(in: row, "ForEach(visible) { task in") else {
    print("FAIL: 找不到单条任务行的渲染体（ForEach(visible) { task in ... }）")
    exit(1)
}
check(!rowItem.contains("onResumeAutomaticContinuation"),
      "任务行不得调用按任务的自动续办恢复通道：授权不是任务状态")
check(!rowItem.contains("resident.wish-task.\\(task.id.uuidString).resume"),
      "任务行不得再有按任务展开的「恢复自动领取」控件（resident.wish-task.<id>.resume）")
check(!rowItem.contains("恢复自动领取"),
      "任务行不得再出现「恢复自动领取」文案：解除是一个全局动作，不按任务逐个恢复")
check(!rowItem.contains("autoContinuationPaused"),
      "任务行不得渲染任务级停止事实（autoContinuationPaused）：那是授权，不是三轴状态")
check(!rowItem.contains("resident.wish-task.\\(task.id.uuidString).stop"),
      "任务行不得有按任务的停止控件：停止由全局开关表达")
check(!rowItem.contains("connectivityNotice") && !rowItem.contains("resident.connectivity-banner"),
      "连通性事实不得出现在任务行里：它只能出现在全局横幅上")
check(!rowItem.contains("resident.autonomy.resume") && !rowItem.contains("resumeAutonomy()"),
      "全局开关的动作不得挂在任务行上：那是全局入口")
check(rowItem.contains("resident.wish-task.\\(task.id.uuidString).generation")
      && rowItem.contains("resident.wish-task.\\(task.id.uuidString).ownership")
      && rowItem.contains("resident.wish-task.\\(task.id.uuidString).placement"),
      "任务行必须能表达它自己的三轴状态（生成 / 归属 / 摆放）")
check(rowItem.contains("axes.generation.label") && rowItem.contains("axes.ownership.label")
      && rowItem.contains("axes.placement.label"),
      "三轴的值必须来自三轴投影，不能另写一份判断")

// 全局开关必须存在且是**一个**：任务行没有了，全局就一定要有。
check(row.contains("resident.autonomy.resume"),
      "删掉任务行控件之后必须有一个全局自主开关入口（resident.autonomy.resume）")
check(row.contains("state.resumeAutonomy()"),
      "全局开关的那个动作必须真的调用一个动作解除（store.resumeAutonomy）")
check(row.contains("if !state.isAutonomySwitchOn || state.isAutonomyStoppedByUser"),
      "全局开关关闭、或用户显式停止过任务时，横幅必须可见（停止不是隐形状态）")
check(row.contains("不自主不等于不听话") && row.contains("任何开关状态下都会执行"),
      "全局横幅必须说明：不自主不等于不听命，人类下令在任何开关状态下都能执行")

// ── 断言 2：连通性事实只出现在全局提示里，不再作为任务属性 ──────────────────
check(row.contains("resident.connectivity-banner"),
      "连通性必须有一条全局横幅（resident.connectivity-banner）")
check(row.contains("state.connectivityNotice"),
      "全局横幅必须由**投影算出来的**连通性提示驱动，不能另存一份")
check(stageControllerSource.contains("WishMachineTaskStatusView(state: wishMachineTasks)")
      && liveCamSource.contains("WishMachineTaskStatusView(state: wishMachineTasks"),
      "舞台与小窗必须共用同一份「横幅 + 任务行」呈现，不能各存一套")
check(stageControllerSource.contains("setWishMachineConnectivity(_ text: String?)")
      && liveCamSource.contains("setWishMachineConnectivity(_ text: String?)"),
      "宿主必须能把**全局**连通性事实推给两个表面（它不经过任何任务行）")

// 投影侧真的接上了：光有呈现侧的摘除还不够，投影必须**不再产生**这两类事实，
// 并且连通性要有一个不依赖"面板上最近 20 条"的权威来源。
guard let projection = declaration(in: appSource, "private func wishMachineTaskPresentation(") else {
    print("FAIL: 找不到生产投影 wishMachineTaskPresentation(for:)")
    exit(1)
}
check(projection.contains("ResidentConnectivityFact.strippingConnectivityLines(from: job.lastError)"),
      "投影必须把连通性事实从任务属性里摘掉（job.lastError 不再直接成为任务 detail）")
check(!projection.contains("var detail = job.lastError"),
      "投影不得再把 job.lastError 原样当作任务 detail")
check(!projection.contains("自主行动已停止"),
      "投影不得再把授权事实（『自主行动已停止』）写进任务 detail：授权属于全局开关")
check(projection.contains("axes: axes")
      && projection.contains("ResidentTaskAxisProjection.project("),
      "投影必须把三轴交给任务行（判断在 ResidentTaskAxisProjection 里，不在宿主里）")
check(appSource.contains("private func pushResidentConnectivityNotice(")
      && appSource.contains("setWishMachineConnectivity(notice)"),
      "宿主必须有一条把连通性推给全局横幅的通道")
check(appSource.contains(
        "wishMachineCoordinator.residentJobs(worldID: worldID, residentScope: scope)\n"
        + "            .compactMap { ResidentConnectivityFact.firstConnectivityLine(in: $0.lastError) }"),
      "全局连通性必须读**整个作用域**（residentJobs 之后直接收集连通性事实），不能只看面板上最近 20 条")
check(!appSource.contains("点许愿任务行的「恢复自动领取」"),
      "停止文案不得再指向已经删掉的按任务控件")
check(appSource.contains("liveCamWindowController?.setResidentAutonomyStop(")
      && appSource.contains("stageWindowController?.setResidentAutonomyStop("),
      "run 级用户停止必须推给全局开关横幅（它不再由任务行表达）")

// ── 断言 2（续）：连通性词汇只有一份 ────────────────────────────────────────
check(coordinatorSource.contains("ResidentConnectivityFact.isConnectivityLine(message)"),
      "coordinator 的 isNetworkClassSubmissionError 必须委托给 ResidentConnectivityFact，不另存一套词汇表")
check(!coordinatorSource.contains("[\"network_unavailable\", \"remote_unavailable\"]"),
      "不得再存在第二份连通性词汇表：『什么算网络类』只能有一个答案")

// ── 断言 3：真的只有**一个**开关，且人类下令在任何开关状态下都能执行 ────────
check(settingsSource.contains("resident.autonomous.enabled.v1")
      && appSource.contains("resident.autonomous.enabled.v1")
      && presentationSource.contains("resident.autonomous.enabled.v1"),
      "设置、宿主与呈现必须读同一个全局开关键 resident.autonomous.enabled.v1，不许另造第二个开关")
check(presentationSource.contains("gmgnResidentAutonomyChanged")
      && settingsSource.contains("gmgnResidentAutonomyChanged")
      && appSource.contains("gmgnResidentAutonomyChanged"),
      "收敛后的开关必须复用设置里已有的那条通知，不另造一套")
// 关 ⇒ 不自主；开 ⇒ 自主：开关真的接到后台自主上，而不是只存在设置里。
check(appSource.contains(
        "loop.setBackgroundEnabled(UserDefaults.standard.bool(forKey: \"resident.autonomous.enabled.v1\"))"),
      "全局开关必须真的接到后台自主上：宿主按开关设置 backgroundEnabled")
check(loopSource.contains("guard backgroundEnabled || !pendingContinuationIDs.isEmpty,")
      && loopSource.contains("!invalidated, !stopped, !intentPausedByUser"),
      "不自主必须真的不自主：后台轮既要 backgroundEnabled，也要没被用户停止")
// 人类明确下令在**任何**开关状态下都能执行：授权按每次工具调用实时求值，
// 而不是被任务级暂停或开关挡住。
check(wishToolsSource.contains("humanOrderedClaim() || existing.autoContinuationPaused != true"),
      "人类明确下令必须能越过任务级暂停直接领取：不自主不等于不听话（existing）")
check(wishToolsSource.contains("humanOrderedClaim() || current.autoContinuationPaused != true"),
      "人类明确下令在领取等待的每一拍都必须能越过任务级暂停（current）")
check(appSource.contains("humanOrderedClaim: {")
      && appSource.contains("!input.isBackground || self.residentAgentLoop?.runHasHumanInput(runID: messageID) == true"),
      "『本轮是否载有人类明确指令』必须有真实接线，不能是常量 false")

// ── 断言 3 + 4：一个开关 / 用户显式停止仍然有效 —— 跑生产投影 ───────────────
// 把生产文件原样读进来（去掉 import 行，由下面统一导入），
// 所以下面这些断言检验的是真正跑在 App 里的那份判断。
let productionBody = presentationSource
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.hasPrefix("import ") }
    .joined(separator: "\n")

let program = #"""
import Foundation
import Combine

"""# + productionBody + #"""

// 顶层脚本代码不是 MainActor 隔离的，而生产投影是；用 assumeIsolated 走主线程
// （脚本本来就跑在主线程上），不要用 Task+semaphore（那会死锁）。
@MainActor
func storeChecks() -> Int {
    var storeFailures = 0
    func storeCheck(_ condition: Bool, _ message: String) {
        if !condition { storeFailures += 1; print("FAIL: " + message) }
    }

    let taskID = UUID()

    // 断言 2（跑生产投影）：连通性事实被摘到全局横幅，任务行拿不到它。
    let store = WishMachineTaskPresentationStore()
    store.update([WishMachineTaskPresentation(
        id: taskID, title: "测试愿望", status: "提交待确认",
        detail: "network_unavailable\n远端计算可能仍在继续。", isTerminal: false)])
    storeCheck(store.connectivityNotice?.contains("连不上后台") == true,
               "连通性事实必须出现在全局横幅里（连不上后台 + 可读原因）")
    storeCheck(store.connectivityNotice?.contains("network_unavailable") == true,
               "全局横幅必须带上可读原因本身，不能只说『出错了』")
    storeCheck(store.connectivityNotice?.contains("自动消失") == true,
               "全局横幅必须说明恢复后会自动消失")
    storeCheck(store.tasks.first?.detail?.contains("network_unavailable") != true,
               "连通性事实不得再作为任务属性出现在任务行 detail 里")
    storeCheck(store.tasks.first?.detail == "远端计算可能仍在继续。",
               "摘掉连通性事实时不得连带丢掉任务自己的说明")

    // 连通正常时横幅必须安静（不是常驻）。
    let quiet = WishMachineTaskPresentationStore()
    quiet.update([WishMachineTaskPresentation(id: UUID(), title: "T", status: "生成中",
                                              detail: "远端计算可能仍在继续。", isTerminal: false)])
    storeCheck(quiet.connectivityNotice == nil, "没有连通性事实时全局横幅必须不出现")

    // 宿主推来的权威连通性事实优先；推 nil 时退回投影推导（不会留下永远不亮的提示）。
    let fed = WishMachineTaskPresentationStore()
    fed.setConnectivityWarning("连不上后台（daemon offline）。任务和产物都还在，恢复后会自己继续；这条提示会自动消失。")
    storeCheck(fed.connectivityNotice?.contains("daemon offline") == true,
               "宿主推来的全局连通性事实必须驱动横幅")
    fed.setConnectivityWarning(nil)
    fed.update([WishMachineTaskPresentation(id: UUID(), title: "T", status: "提交待确认",
                                            detail: "remote_unavailable", isTerminal: false)])
    storeCheck(fed.connectivityNotice?.contains("remote_unavailable") == true,
               "宿主没报连通性问题时，投影里的连通性事实仍然必须可见（不静默）")

    // 断言 1（跑生产投影）：授权文本同样被摘到全局横幅，任务行拿不到它。
    let authorized = WishMachineTaskPresentationStore()
    authorized.update([WishMachineTaskPresentation(
        id: taskID, title: "A", status: "可领取",
        detail: "自主行动已停止：不会自行前往领取或摆放；任务与产物保留，直接下达指令仍可当轮执行。",
        isTerminal: false)])
    storeCheck(authorized.tasks.first?.detail?.contains("自主行动已停止") != true,
               "任务行不得渲染授权事实（『自主行动已停止』）：授权属于全局开关横幅")
    storeCheck(authorized.isAutonomyStoppedByUser,
               "任务行不再表达授权，但授权事实必须仍然可见：全局开关横幅要亮")

    // 断言 4：用户显式停止仍然有效（安全语义保留），且只由**一个**动作解除。
    let stopped = WishMachineTaskPresentationStore()
    stopped.setHostAutonomyStop(true)
    storeCheck(stopped.isAutonomyStoppedByUser, "run 级用户停止必须仍然被认成『停过』")
    stopped.setHostAutonomyStop(false)
    stopped.update([
        WishMachineTaskPresentation(id: taskID, title: "A", status: "可领取", detail: nil,
                                    isTerminal: false, autoContinuationPaused: true),
        WishMachineTaskPresentation(id: UUID(), title: "B", status: "可领取", detail: nil,
                                    isTerminal: false, autoContinuationPaused: true),
        WishMachineTaskPresentation(id: UUID(), title: "C", status: "生成中", detail: nil,
                                    isTerminal: false, autoContinuationPaused: false)])
    storeCheck(stopped.isAutonomyStoppedByUser, "任务级用户停止必须仍然被认成『停过』")

    // 没有恢复通道时**不许静默**：拒绝必须可见（fail-closed 仍然可读）。
    stopped.resumeAutonomy()
    storeCheck(stopped.autonomyResumeFailure?.isEmpty == false,
               "恢复通道缺失时必须给出可读原因，不能变成『点了没反应』")

    // 断言 3：一个动作解除全部 —— 不按任务逐个恢复。
    let resumed = WishMachineTaskPresentationStore()
    var resumedIDs: [UUID] = []
    resumed.onResumeAutomaticContinuation = { resumedIDs.append($0) }
    UserDefaults.standard.set(false, forKey: ResidentAutonomySwitch.defaultsKey)
    resumed.update([
        WishMachineTaskPresentation(id: taskID, title: "A", status: "可领取", detail: nil,
                                    isTerminal: false, autoContinuationPaused: true),
        WishMachineTaskPresentation(id: UUID(), title: "B", status: "可领取", detail: nil,
                                    isTerminal: false, autoContinuationPaused: true)])
    resumed.resumeAutonomy()
    storeCheck(UserDefaults.standard.bool(forKey: ResidentAutonomySwitch.defaultsKey),
               "一个动作必须打开全局开关（resident.autonomous.enabled.v1）")
    storeCheck(resumedIDs.count == 2 && Set(resumedIDs) == Set(resumed.tasks.map(\.id)),
               "一个动作必须把**所有**被用户停过的任务一次解开，而不是只解一个")
    storeCheck(resumed.autonomyResumeFailure == nil,
               "真的解开了就不该留下失败说明")

    // 归属轴**只前进**：网络 / 重启 / 重复刷新都不能把它推回去。
    storeCheck(ResidentOwnershipAxis.advance(.inInventory, to: .unclaimed) == .inInventory,
               "归属轴不得从『已入库』退回『未领取』：东西不能看起来没了")
    storeCheck(ResidentOwnershipAxis.advance(.claimed, to: .inInventory) == .inInventory,
               "归属轴必须能前进到『已入库』")
    storeCheck(ResidentOwnershipAxis.advance(.unclaimed, to: .claimed) == .claimed,
               "归属轴必须能从『未领取』前进到『已领取』")

    // 三轴的判断只有一份，且三轴的取值互不串台。
    let axes = ResidentTaskAxisProjection.project(
        .remoteQueued, ownership: .notClaimed, placement: .unknown)
    storeCheck(axes.generation == .queued && axes.ownership == .unclaimed
               && axes.placement == .notYetPlaced,
               "排队中的任务必须是『生成=排队 / 归属=未领取 / 摆放=未摆放』")
    storeCheck(ResidentTaskAxisProjection.generation(.failed) == .failed,
               "生成失败只动生成轴")
    storeCheck(ResidentTaskAxisProjection.ownership(.inInventory) == .inInventory,
               "『已入库』只能由库存读回的事实给出")
    // 摆放这一档看**归属**：还没进库存就还没有"在库存待摆"这回事（不许说假话）。
    let claimedNotStored = ResidentTaskAxisProjection.project(
        .downloaded, ownership: .claimedNotInInventory, placement: .notPlaced)
    storeCheck(claimedNotStored.ownership == .claimed
               && claimedNotStored.placement == .notYetPlaced,
               "已领取但还没入库：归属=已领取，摆放=未摆放，绝不许说『在库存』")
    storeCheck(ResidentTaskAxisProjection.placement(.placed, ownership: .unclaimed) == .placed,
               "真的摆出来了就是已摆放，不因为归属轴的起点低就被压回低档")
    let placed = ResidentTaskAxisProjection.project(
        .downloaded, ownership: .inInventory, placement: .placed, previousOwnership: .inInventory)
    storeCheck(placed.generation == .generating && placed.ownership == .inInventory
               && placed.placement == .placed,
               "下载校验中仍是生成轴的事，已入库/已摆放是另外两条轴的事，三者互不覆盖")
    storeCheck(ResidentTaskAxisProjection.project(
        .downloaded, ownership: .notClaimed, placement: .notPlaced,
        previousOwnership: .inInventory).ownership == .inInventory,
        "归属轴只前进：已经入库过的任务不会因为投影说未领取就退回去")

    return storeFailures
}

let storeFailures = MainActor.assumeIsolated { storeChecks() }
if storeFailures > 0 { exit(1) }
print("PASS: 生产投影：连通性/授权收敛到全局横幅、一个动作解除自主停止、归属轴只前进、三轴互不串台")
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-state-convergence-\(UUID()).swift")
try program.write(to: temporary, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: temporary) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [temporary.path]
try process.run()
process.waitUntilExit()

if failures > 0 { exit(1) }
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("PASS: 任务行只表达三轴状态、无按任务授权控件；连通性只在全局横幅；一个开关；人类下令任何开关状态下都能执行；用户显式停止仍有效")
