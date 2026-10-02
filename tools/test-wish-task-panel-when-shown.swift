// 「许愿任务那一块**什么时候还占屏幕**」的判据 —— 现在它跟着**消息**走，不再跟着窗口/列表走。
//
// 用户 2026-10-02 原话：
//   「左上角这个也不应该常驻啊」
//   「许愿任务变成消息提示，不要单独做窗口了」
//
// 所以这一份 harness 现在回答三件事：
//   ① **没有单独的许愿任务窗口/列表**：产品路径的视图里零个列表痕迹
//      （`state.tasks` / `ForEach` / 「许愿任务」标题 / `resident.wish-tasks` 标识）；
//   ② **判据仍然只有一处**：`enum WishMachineTaskPrompt`（在
//      `Presence/WishMachineTaskMessage.swift` 里，跟着消息通道走），
//      消息通道**经它**回答"这一档状态此刻还该不该留在屏幕上"；
//   ③ **规则体一个字没改**并**真的编译起来驱动**：有事才出现、事情了结就收起、
//      到期那一刻就收起（不是"再多留一拍"）。
//
// 每一条都配注入负对照（只在内存里的源码副本上做手术）：
//   把规则改成「永远 true」（= 常驻）⇒ ③ 必须 FAIL；
//   把「许愿任务」列表装回视图 ⇒ ① 必须 FAIL。
//
// 现场演示：`WISH_TASK_PANEL_INJECT=always swift tools/test-wish-task-panel-when-shown.swift`
// 会把**真源码**当成"被改成常驻"的那一份来判，于是主判据自己打出一条 FAIL。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let messageRelative = "apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskMessage.swift"
let overlayRelative = "apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift"

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS \(message)")
    } else {
        print("FAIL \(message)")
        failureCount += 1
    }
}
func require(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL \(message)"); exit(1) }
}
func read(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
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

// ---------------------------------------------------------------------------
// MARK: ① 没有单独的许愿任务窗口/列表
// ---------------------------------------------------------------------------

let overlaySource = try read(overlayRelative)
let messageSource = try read(messageRelative)

/// 视图里"许愿任务列表又回来了"的痕迹。**注入负对照要的就是「这里非空」。**
func wishTaskPanelTraces(in overlay: String) -> [String] {
    guard let view = declaration(overlay, "struct WishMachineTaskStatusView: View {") else {
        return ["抽不出 WishMachineTaskStatusView —— 那是「没有许愿任务列表」的宿主"]
    }
    return ["state.tasks", "ForEach", "Text(\"许愿任务\")", "resident.wish-tasks", "resident.wish-task."]
        .filter { view.contains($0) }
}

let panelTraces = wishTaskPanelTraces(in: overlaySource)
check(panelTraces.isEmpty,
    "① 产品路径上没有单独的许愿任务窗口/列表（视图里的痕迹：\(panelTraces.isEmpty ? "零个" : panelTraces.joined(separator: "、"))）")

// ---------------------------------------------------------------------------
// MARK: ② 判据仍然只有一处，而且消息通道真的经它
// ---------------------------------------------------------------------------

let declarationStart = "enum WishMachineTaskPrompt {"
let pristineRule = declaration(messageSource, declarationStart)
require(pristineRule != nil, "消息通道里找不到 `\(declarationStart)` —— 判据的宿主没了")

/// 判据只许有一个出口：消息通道必须**经这个函数**回答"还占不占屏幕"。
let routesThroughRule = messageSource.contains(
    "WishMachineTaskPrompt.isShown(promptExpiresAt: anchors[id] ?? nil, at: now)")
check(routesThroughRule,
    "② 消息通道经**唯一**判据 `WishMachineTaskPrompt.isShown` 决定「这一档还占不占屏幕」（不另写一遍规则）")

// ---------------------------------------------------------------------------
// MARK: ③ 把规则真的编译起来，用探针驱动
// ---------------------------------------------------------------------------

/// 判据体只读 `promptExpiresAt` / `now`，不依赖任何别的东西 —— 所以**逐字抽出来**就能编译，
/// 连签名都不用换（这正是它被搬到一个只依赖 Foundation 的文件里的原因）。
func probeSource(rule: String) -> String {
    """
    import Foundation
    \(rule)
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message); if !condition { failures += 1 }
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    // 未了结（没有到期锚点）= 有事在发生 / 有件事在等人 ⇒ 还在屏幕上。
    expect(WishMachineTaskPrompt.isShown(promptExpiresAt: nil, at: now),
        "有事发生时还在屏幕上（未了结，promptExpiresAt == nil）")
    // 事了结、提示窗还没过 ⇒ 还在（可见、可预期的收起，不是闪一下）。
    expect(WishMachineTaskPrompt.isShown(promptExpiresAt: now.addingTimeInterval(29), at: now),
        "了结但提示窗未过 ⇒ 仍在屏幕上（收起可见、可预期）")
    // 提示窗已过 ⇒ **收起**。这一条就是"不常驻"的正身。
    expect(!WishMachineTaskPrompt.isShown(promptExpiresAt: now.addingTimeInterval(-1), at: now),
        "了结（终态 + 提示窗已过）⇒ 收起，不再占屏幕")
    expect(!WishMachineTaskPrompt.isShown(promptExpiresAt: now, at: now),
        "提示窗到点那一刻就收起（边界不是「再多留一拍」）")
    exit(failures == 0 ? 0 : 1)
    """
}

/// 跑一份规则文本，返回 (退出码, 输出)。
func runProbe(rule: String) throws -> (status: Int32, output: String) {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wish-task-prompt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let file = scratch.appendingPathComponent("probe.swift")
    try probeSource(rule: rule).write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// 现场演示：把真源码当成"被改成常驻"的那一份来判。
let injectAlways = ProcessInfo.processInfo.environment["WISH_TASK_PANEL_INJECT"] == "always"
if injectAlways {
    print("·· WISH_TASK_PANEL_INJECT=always：把真源码当成「被改成常驻」的那一份来判")
}

/// 「常驻」缺陷：把两条判断换成永远为真。
func makeAlwaysShownRule(_ rule: String) -> String {
    rule.replacingOccurrences(
        of: "        guard let expiry = promptExpiresAt else { return true }\n        return now < expiry",
        with: "        return true")
}

let observedRule = injectAlways ? makeAlwaysShownRule(pristineRule ?? "") : (pristineRule ?? "")
if injectAlways {
    check(observedRule != pristineRule, "注入负对照「常驻」确实改到了源码副本")
}

let observed = try runProbe(rule: observedRule)
for line in observed.output.split(separator: "\n") { print("   · \(line)") }
check(observed.status == 0, "③ 驱动**真源码抽出来的规则**：有事才出现、了结后收起")

// ---------------------------------------------------------------------------
// MARK: 注入负对照（只在内存里的副本上做手术）
// ---------------------------------------------------------------------------

enum WishTaskPanelInjection: String, CaseIterable {
    /// 把规则改成永远为真 —— 就是用户抱怨的「常驻」。
    case alwaysShown
    /// 把「许愿任务」列表装回视图 —— 就是用户要求删掉的那一块。
    case restorePanel

    func apply(toRule rule: inout String, toViewSource view: inout String) {
        switch self {
        case .alwaysShown:
            rule = makeAlwaysShownRule(rule)
        case .restorePanel:
            view = view.replacingOccurrences(
                of: "struct WishMachineTaskStatusView: View {",
                with: """
                struct WishMachineTaskStatusView: View {
                    // 注入负对照（只在内存副本里）：把许愿任务列表装回去
                    @ViewBuilder private var injectedWishTaskList: some View {
                        Text("许愿任务")
                        ForEach(state.tasks) { task in Text(task.currentStatusLine) }
                    }
                """)
        }
    }
}

let pristineViewSource = overlaySource
for injection in WishTaskPanelInjection.allCases {
    var injectedRule = pristineRule ?? ""
    var injectedView = pristineViewSource
    injection.apply(toRule: &injectedRule, toViewSource: &injectedView)
    let changed = injectedRule != (pristineRule ?? "") || injectedView != pristineViewSource
    check(changed, "注入负对照「\(injection.rawValue)」确实改到了源码副本")

    switch injection {
    case .alwaysShown:
        let result = try runProbe(rule: injectedRule)
        let firstFailure = result.output
            .split(separator: "\n")
            .first { $0.hasPrefix("FAIL ") }
            .map { String($0.dropFirst("FAIL ".count)) } ?? "（没有）"
        check(result.status != 0, "注入负对照「常驻」⇒ 判据必须变红（第一条：\(firstFailure)）")
    case .restorePanel:
        let traces = wishTaskPanelTraces(in: injectedView)
        check(!traces.isEmpty, "注入负对照「装回许愿任务列表」⇒ 判据必须变红（痕迹：\(traces.joined(separator: "、"))）")
    }
}

print(failureCount == 0
    ? "PASS 许愿任务「有事才出现、了结后收起」判据全部通过（且产品路径上没有那块列表）"
    : "FAIL 许愿任务显示判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
