// 「左上角那块许愿任务列表**什么时候占屏幕**」的判据（用户 2026-10-02 原话：
// 「左上角这个也不应该常驻啊」）。
//
// 它要回答的是两件事，缺一不可：
//   ① **有事才出现**：有正在生成 / 待领取 / 已领取未入库 / 失败待处理的任务 ⇒ 出现；
//   ② **了结后收起**：任务走到终态、提示窗过了 ⇒ 不再占屏幕；一件都没有时整块**不渲染**
//      （不是渲染一个空壳）。
//
// 判据不许自己再写一遍规则 —— 那会变成第二份真相。所以这里的做法是：
//   从**真源码** `VisualEngine/StageOverlayView.swift` 里把 `enum WishMachineTaskPrompt`
//   的文本**逐字抽出来**，只把签名里的 `WishMachineTaskPresentation` 换成探针类型
//   （规则体一个字不动），然后**真的编译并驱动它**。
//
// 每一条都配注入负对照（只在内存里的源码副本上做手术）：
//   把规则改成「永远 true」（= 常驻）⇒ 「了结后收起」必须 FAIL；
//   把 `if !visible.isEmpty` 拿掉（= 空壳也渲染）⇒ 「一件都没有就不渲染」必须 FAIL。
//
// 现场演示：`WISH_TASK_PANEL_INJECT=always swift tools/test-wish-task-panel-when-shown.swift`
// 会把**真源码**当成"被改成常驻"的那一份来判，于是主判据自己打出一条 FAIL。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let overlayPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift")

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

// ---------------------------------------------------------------------------
// MARK: 从真源码里抽出「什么时候显示」那条规则
// ---------------------------------------------------------------------------

let declarationStart = "enum WishMachineTaskPrompt {"

/// 抽 `enum WishMachineTaskPrompt { … }` 的整段文本（到第一个顶格 `}` 为止）。
func extractPromptRule(from source: String) -> String? {
    guard let start = source.range(of: declarationStart) else { return nil }
    let rest = source[start.lowerBound...]
    guard let end = rest.range(of: "\n}\n") else { return nil }
    return String(rest[rest.startIndex..<end.upperBound])
}

let overlaySource = try String(contentsOf: overlayPath, encoding: .utf8)

/// 判据只许有一个出口：视图必须**经这个函数**回答"要不要显示"。
let routesThroughRule = overlaySource.contains("state.tasks.filter { WishMachineTaskPrompt.isShown($0, at: timeline.date) }")
/// 一件都没有时整块不渲染（而不是渲染空壳）。
let emptyBlockIsGuarded = overlaySource.contains("if !visible.isEmpty {")

let pristineRule = extractPromptRule(from: overlaySource)
require(pristineRule != nil, "真源码里找不到 `\(declarationStart)` —— 判据的宿主没了")

check(routesThroughRule, "① 任务列表经**唯一**判据 `WishMachineTaskPrompt.isShown` 过滤（不在视图里另写一遍规则）")
check(emptyBlockIsGuarded, "② 「一件都没有」时整块不渲染（`if !visible.isEmpty` 守着那个 VStack）")

// ---------------------------------------------------------------------------
// MARK: 把规则真的编译起来，用探针驱动
// ---------------------------------------------------------------------------

/// 探针：规则体只读 `task.promptExpiresAt`，所以只给这一个字段。
/// **规则体本身逐字来自真源码**，这里换掉的只有签名里的类型名。
struct ProbeTask {
    let promptExpiresAt: Date?
}

/// 把抽出来的规则落成一份可执行源码：签名换探针类型，**函数体一个字不动**。
func probeSource(rule: String) -> String {
    let body = rule.replacingOccurrences(
        of: "_ task: WishMachineTaskPresentation",
        with: "_ task: ProbeTask")
    return """
    import Foundation
    /// 探针：规则体只读 `task.promptExpiresAt`。
    struct ProbeTask { let promptExpiresAt: Date? }
    \(body)
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message); if !condition { failures += 1 }
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    // 非终态（收件箱给不出到期时间）= 有事在发生 ⇒ 出现。
    expect(WishMachineTaskPrompt.isShown(ProbeTask(promptExpiresAt: nil), at: now),
        "有事发生时出现（非终态，promptExpiresAt == nil）")
    // 终态、提示窗还没过 ⇒ 出现（可见、可预期的收起，不是闪一下）。
    expect(WishMachineTaskPrompt.isShown(ProbeTask(promptExpiresAt: now.addingTimeInterval(29)), at: now),
        "终态但提示窗未过 ⇒ 仍在屏幕上（收起可见、可预期）")
    // 终态、提示窗已过 ⇒ **收起**。这一条就是"不常驻"的正身。
    expect(!WishMachineTaskPrompt.isShown(ProbeTask(promptExpiresAt: now.addingTimeInterval(-1)), at: now),
        "了结（终态 + 提示窗已过）⇒ 收起，不再占屏幕")
    expect(!WishMachineTaskPrompt.isShown(ProbeTask(promptExpiresAt: now), at: now),
        "提示窗到点那一刻就收起（边界不是「再多留一拍」）")
    exit(failures == 0 ? 0 : 1)
    """
}

/// 跑一份规则文本，返回 (退出码, 输出)。
func runProbe(rule: String) throws -> (status: Int32, output: String) {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wish-task-panel-\(UUID().uuidString)", isDirectory: true)
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

let observedRule = injectAlways
    ? (pristineRule ?? "").replacingOccurrences(
        of: "guard let expiry = task.promptExpiresAt else { return true }\n        return now < expiry",
        with: "return true")
    : (pristineRule ?? "")
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
    /// 把「一件都没有就不渲染」的守卫拿掉 —— 空壳也占屏幕。
    case renderEmptyShell

    func apply(toRule rule: inout String, toViewSource view: inout String) {
        switch self {
        case .alwaysShown:
            rule = rule.replacingOccurrences(
                of: "guard let expiry = task.promptExpiresAt else { return true }\n        return now < expiry",
                with: "return true")
        case .renderEmptyShell:
            view = view.replacingOccurrences(of: "if !visible.isEmpty {", with: "if true {")
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
    case .renderEmptyShell:
        let stillGuarded = injectedView.contains("if !visible.isEmpty {")
        check(!stillGuarded, "注入负对照「空壳也渲染」⇒ 「一件都没有就不渲染」必须变红")
    }
}

print(failureCount == 0
    ? "PASS 许愿任务面板「有事才出现、了结后收起」判据全部通过"
    : "FAIL 许愿任务面板显示判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
