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
/// 任务行那一句**委托**给唯一投影（`ResidentOwnershipProjection.sentence(...)` →
/// `OwnershipSentence`），所以那一份生产源码必须一起编 —— 编的是**同一份**，
/// 不是在这里抄一套文案（抄一份正是"两份真相"最容易被放过去的地方）。
let projectionPath = "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift"
let overlayPath = "apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift"
let liveCamPath = "apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift"
let stageControllerPath = "apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"
let settingsPath = "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsView.swift"
let appPath = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
let loopPath = "apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift"
let wishToolsPath = "apps/macos/Sources/GMGNRadio/Agent/ResidentWishMachineTools.swift"
let coordinatorPath = "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift"
/// 许愿任务不再是窗口/列表（用户 2026-10-02：「许愿任务变成消息提示，不要单独做窗口了」）：
/// 状态变化是一条条消息，读的是**唯一投影**的输出。这一份只被当**文本**校验（它依赖
/// Foundation + 投影，由 `tools/test-wish-task-messages.swift` 编译驱动）。
let messagePath = "apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskMessage.swift"

let presentationSource = try productionSource(presentationPath)
let projectionSource = try productionSource(projectionPath)
let overlaySource = try productionSource(overlayPath)
let liveCamSource = try productionSource(liveCamPath)
let stageControllerSource = try productionSource(stageControllerPath)
let settingsSource = try productionSource(settingsPath)
let appSource = try productionSource(appPath)
let loopSource = try productionSource(loopPath)
let wishToolsSource = try productionSource(wishToolsPath)
let coordinatorSource = try productionSource(coordinatorPath)
let messageSource = try productionSource(messagePath)

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

/// 一处声明在源码里出现几次。用来断言"这句话只有**一处**定义"——
/// 派生点复制出第二份就立刻 FAIL，而不是等它在真机上说出两句不一样的话。
func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

// ── 断言 1：许愿任务**没有自己的窗口/列表**（用户 2026-10-02：「许愿任务变成消息提示，
//    不要单独做窗口了」）─────────────────────────────────────────────────────────
//
// 这一节原来钉的是"单条任务行的正文里不许有按任务的授权控件、只表达三轴、只渲染一句现状"。
// 用户拍板（许愿任务改成消息提示）之后，任务行与那块列表**整个从产品路径上删掉了** ——
// 所以这里钉的是更强的那一件事：**没有任务行、没有列表**。
//
// 原来那些断言的**对象**（任务行）不存在了，但它们的内容一条都没有放宽，改在**消息通道**上
// 继续成立，并由 `tools/test-wish-task-messages.swift` 逐条钉着：
//   · 状态来源仍然是唯一投影（消息读 `OwnershipRow.statusText`，不自己拼状态词）；
//   · 文案是人话（那一套词表 0 个 key=value / UUID / 路径 / 内部字段名 / 省略号堆叠）；
//   · 状态变化各发一条、同一状态不重复；失败待办**不自动消失**、其它终态按既有窗口过期；
//   · 消息落进**既有**的对话通道（`ResidentChatTranscriptLine`），不新造面板、不新造窗口。
guard let row = declaration(in: overlaySource, "struct WishMachineTaskStatusView") else {
    print("FAIL: 找不到许愿任务那块视图的宿主 WishMachineTaskStatusView")
    exit(1)
}
check(!row.contains("ForEach"),
      "许愿任务不再有自己的窗口/列表：视图里不许再出现按任务渲染的行（ForEach）")
check(!row.contains("state.tasks"),
      "视图不得再读任务列表（state.tasks）：产品路径对许愿任务列表**零调用**")
check(!row.contains("Text(\"许愿任务\")"),
      "视图里不许再有那块列表的标题（「许愿任务」）")
check(!row.contains("resident.wish-tasks") && !row.contains("resident.wish-task."),
      "视图里不许再有任何许愿任务列表/任务行的无障碍标识")
// 视图里剩下的只有两条**全局**横幅：连通性与「能不能自主」。它们不是任务属性。
check(row.contains("resident.connectivity-banner") && row.contains("resident.autonomy-banner"),
      "视图里只剩两条全局横幅（连通性 resident.connectivity-banner / 自主 resident.autonomy-banner）")
// 那一句现状的唯一出口仍然是唯一投影：任务行没了，取它的是**消息通道**
// （`OwnershipRow.statusText` 就是投影自己的输出；这里不许出现任何自己拼的状态词）。
check(messageSource.contains("row.statusText"),
      "许愿任务那一句仍然只能来自唯一投影（消息通道读 OwnershipRow.statusText）")
check(!messageSource.contains("ResidentTaskAxisProjection.currentStatus"),
      "消息通道不得绕过投影自己去拼那一句（拼一份就是第二份真相）")
for axisLabel in [".generation.label", ".ownership.label", ".placement.label", "axisChip"] {
    check(!overlaySource.contains(axisLabel) && !messageSource.contains(axisLabel),
          "任何界面/消息里都不得再出现轴标签文案（\(axisLabel)）：三轴只在投影里合成一句")
}
// 派生点**只有一处**：三轴 → 一句现状 的判断在 `ResidentTaskAxisProjection.currentStatus`
// 里，任务行那一句的组装在 `WishMachineTaskPresentation.currentStatusLine` 里，各一份。
check(occurrences(of: "static func currentStatus(", in: presentationSource) == 1,
      "三轴 → 一句现状 的派生必须只有一处定义（ResidentTaskAxisProjection.currentStatus）")
check(occurrences(of: "var currentStatusLine: String", in: presentationSource) == 1,
      "那一句现状的组装必须只有一处（WishMachineTaskPresentation.currentStatusLine）")
check(presentationSource.contains("ResidentTaskAxisProjection.currentStatus(axes)"),
      "那一句必须真的来自三轴派生，而不是另写一份判断")
// 三轴 → 那一句**只有唯一投影一个出口**（2026-10-02 收口）：正文里既要有委托，
// 又不许再有第二套字面量（可领取 / 等待入库 / 未摆放 / 排队中）。
guard let statusBody = declaration(in: presentationSource, "static func currentStatus(") else {
    print("FAIL: 抽不出 ResidentTaskAxisProjection.currentStatus 的正文"); exit(1)
}
check(statusBody.contains("ResidentOwnershipProjection.sentence("),
      "三轴那一句必须委托给唯一投影 ResidentOwnershipProjection.sentence(generation:ownership:placement:)")
for retired in ["可领取", "等待入库", "未摆放", "排队中"] {
    check(!statusBody.contains(retired),
          "那一句里还有第二套状态词「\(retired)」：那一句只有唯一投影一个出口")
}
check(occurrences(of: "static func hasReachedTerminalStep(", in: presentationSource) == 1,
      "『三轴走到头了没有』的判据必须只有一处（失败通道据此让位，不另写一套）")

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
let productionBody = (projectionSource + "\n" + presentationSource)
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
    // 2026-10-02 文案规则：横幅只给**一句人话**（发生了什么 + 要不要用户做什么），
    // 原始原因码（network_unavailable 这类工程词）一律不上屏，只进日志。
    storeCheck(store.connectivityNotice?.contains("暂时连不上") == true,
               "连通性事实必须出现在全局横幅里（一句人话）")
    storeCheck(store.connectivityNotice?.contains("network_unavailable") != true,
               "全局横幅不得回显原始原因码（key=value 这类工程词不上屏）")
    storeCheck(store.connectivityNotice?.contains("恢复后会自己继续") == true,
               "全局横幅必须说明会自己恢复，用户不用做什么")
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
    fed.setConnectivityWarning("暂时连不上，东西都还在，恢复后会自己继续。")
    storeCheck(fed.connectivityNotice?.contains("暂时连不上") == true,
               "宿主推来的全局连通性事实必须驱动横幅")
    fed.setConnectivityWarning(nil)
    fed.update([WishMachineTaskPresentation(id: UUID(), title: "T", status: "提交待确认",
                                            detail: "remote_unavailable", isTerminal: false)])
    storeCheck(fed.connectivityNotice?.contains("暂时连不上") == true,
               "宿主没报连通性问题时，投影里的连通性事实仍然必须可见（不静默）")
    storeCheck(fed.connectivityNotice?.contains("remote_unavailable") != true,
               "投影推导出的横幅同样不得回显原始原因码")

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

    // ── 三轴 → 一句现状：完整对照表，逐条跑生产投影 ──────────────────────────
    // 取法是"最靠后的、对用户最有意义的那一步"：沿 生成 → 归属 → 摆放 从后往前看。
    //
    // 期望值**逐字**是唯一投影 `OwnershipSentence` 的那几句 —— 任务行与「我的物件」
    // 列表因此说的是同一句话。这里不再有第二套（可领取 / 等待入库 / 未摆放）。
    func produced(_ generation: ResidentTaskAxisProjection.GenerationFact,
                  _ ownership: ResidentTaskAxisProjection.OwnershipFact,
                  _ placement: ResidentTaskAxisProjection.PlacementFact,
                  previousOwnership: ResidentOwnershipAxis = .unclaimed) -> String {
        ResidentTaskAxisProjection.currentStatus(ResidentTaskAxisProjection.project(
            generation, ownership: ownership, placement: placement,
            previousOwnership: previousOwnership))
    }
    // 生成轴的两档在投影里**只有一句话**（「生成中」）：队列细分（排队中）是远端进度，
    // 不是对外状态 —— 那一档的细分仍在 `detail` 里说，不另造一个状态词。
    storeCheck(produced(.remoteQueued, .notClaimed, .unknown) == "生成中",
               "生成轴：排队 ⇒「生成中」（队列细分不是对外状态）")
    storeCheck(produced(.remoteRunning, .notClaimed, .unknown) == "生成中",
               "生成轴：生成中 ⇒「生成中」")
    storeCheck(produced(.completed, .notClaimed, .notPlaced) == "未领取",
               "生成完成但未领取 ⇒「未领取」（用户拍板的那一档）")
    storeCheck(produced(.downloaded, .claimedNotInInventory, .notPlaced) == "已领取，入库尚未保存",
               "已领取、未入库 ⇒ 与列表同一句「已领取，入库尚未保存」")
    storeCheck(produced(.completed, .inInventory, .unknown) == "在库里（没摆）",
               "已入库、未摆放 ⇒ 与列表同一句「在库里（没摆）」")
    storeCheck(produced(.completed, .inInventory, .placed, previousOwnership: .inInventory) == "已摆放",
               "已摆放 ⇒「已摆放」")
    storeCheck(produced(.failed, .notClaimed, .unknown) == "生成失败",
               "只有生成轴失败时才说「生成失败」")
    // "不取最坏的那个"：摆出来了就是摆出来了，不因为生成轴上失败过而退回去说"生成失败"。
    storeCheck(produced(.failed, .inInventory, .placed, previousOwnership: .inInventory) == "已摆放",
               "取最靠后的一步，不取最坏的那个：已摆放优先于生成轴的失败")

    // 失败仍走**既有失败通道**：三轴说不出"取消/中断/加载失败"这些词，任务行那一句
    // 就回到宿主那句话，绝不自己编一个词（编了就是第二份真相，而且会说错）。
    let cancelled = WishMachineTaskPresentation(
        id: taskID, title: "T", status: "已取消", detail: "用户取消了这次生成。", isTerminal: true,
        axes: ResidentTaskAxisProjection.project(.cancelled, ownership: .notClaimed, placement: .unknown))
    storeCheck(cancelled.currentStatusLine == "已取消",
               "取消不是失败：生成轴只会说『生成失败』，那一句必须回到既有失败通道（已取消）")
    let renderFailed = WishMachineTaskPresentation(
        id: taskID, title: "T", status: "场景加载失败", detail: "加载失败：…", isTerminal: true,
        axes: ResidentTaskAxisProjection.project(.completed, ownership: .notClaimed, placement: .unknown))
    storeCheck(renderFailed.currentStatusLine == "场景加载失败",
               "三轴还没走到头、宿主已经终态 ⇒ 那是没做成：绝不能说成「未领取」（那是新的自相矛盾）")
    let queuedRow = WishMachineTaskPresentation(
        id: taskID, title: "T", status: "后台排队中", detail: nil, isTerminal: false,
        axes: ResidentTaskAxisProjection.project(.remoteQueued, ownership: .notClaimed, placement: .unknown))
    storeCheck(queuedRow.currentStatusLine == "生成中",
               "正常推进时那唯一一句必须由唯一投影派生（排队 ⇒「生成中」），而不是把宿主那句话照抄一遍")
    let legacyRow = WishMachineTaskPresentation(
        id: taskID, title: "T", status: "提交待确认", detail: nil, isTerminal: false)
    storeCheck(legacyRow.currentStatusLine == "提交待确认",
               "没有三轴的老路径仍然说得出状态：这次简化只减去标签，不减去状态")
    // 原因那一行与状态那一句是**两件事**：简化标签不许把原因一起吃进状态句里。
    storeCheck(renderFailed.detail == "加载失败：…",
               "失败原因必须仍然在 detail 那一行上可读，不许被折进唯一那一句状态里")

    return storeFailures
}

let storeFailures = MainActor.assumeIsolated { storeChecks() }
if storeFailures > 0 { exit(1) }
print("PASS: 生产投影：连通性/授权收敛到全局横幅、一个动作解除自主停止、归属轴只前进、三轴互不串台、三轴合起来只说一句现状（失败走既有通道）")
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
print("PASS: 许愿任务没有自己的窗口/列表（零 ForEach / 零 state.tasks / 零列表标识），只剩连通性与自主两条全局横幅；三轴仍然只在唯一投影里合成一句；一个开关；人类下令任何开关状态下都能执行；用户显式停止仍有效")
