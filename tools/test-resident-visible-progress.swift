// Offline production-method behavior, task lifecycle, and source wiring checks.
// No application host, window or provider is started.
import Foundation

let root = "apps/macos/Sources/GMGNRadio/"
func read(_ path: String) throws -> String { try String(contentsOfFile: root + path, encoding: .utf8) }
let app = try read("App/GMGNRadioApp.swift")
let stage = try read("VisualEngine/StageOverlayView.swift")
let liveCam = try read("DesktopPresence/LiveCamPanel.swift")
let stageController = try read("VisualEngine/StageWindowController.swift")
let liveCamController = try read("DesktopPresence/LiveCamWindowController.swift")
let taskModelPath = root + "Presence/WishMachineTaskPresentation.swift"
guard FileManager.default.fileExists(atPath: taskModelPath) else {
    print("FAIL: independent wish task presentation model is missing")
    exit(1)
}
var failures = 0
func check(_ value: Bool, _ message: String) {
    if !value { failures += 1; print("FAIL: \(message)") }
}
check(app.contains("maximumCalls: AgentConversationService.shared.effectiveBackendID == .dsh ? nil : 32"),
      "DSH tool lease has no hidden call-count cutoff while other backends keep their limit")
check(app.contains("recordToolProgress(runID: messageID, toolName: name, phase: .started)") &&
      app.contains("phase: result.isError ? .failed : .returned"), "actual resident tool boundaries publish progress")
check(app.contains("loop?.pendingUserMessages.count") && app.contains("条消息排队中"), "queued guidance has visible count")
check(app.contains("setResidentProgress(loop?.progress)"), "loop progress reaches presentation")
for (name, source) in [("stage", stageController), ("livecam", liveCamController), ("livecam panel", liveCam)] {
    check(source.contains("func setResidentProgress("), "\(name) forwards independent progress")
}
check(stage.contains("state.progress ?? \"等待居民回应…\"") && stage.contains("stage.resident-progress"), "space renders real progress instead of permanent thinking")
check(liveCam.contains("[residentProgress, residentDeliveryMessage]") && liveCam.contains("updateResidentStatusNotice()"), "compact view keeps progress and queue separate from final reply")
check(!app.contains("announce(loop?.progress"), "progress must not be spoken")
func declaration(_ signature: String, in source: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let opening = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced declaration")
}
let loopSource = try read("Agent/ResidentAgentLoop.swift")
let noticeTypes = [
    declaration("enum ResidentStatusNoticeKind:", in: loopSource),
    declaration("struct ResidentStatusNoticeDecision:", in: loopSource),
    declaration("enum ResidentStatusNoticeMerge", in: loopSource),
].joined(separator: "\n")
let methods = ["func setResidentThinking(", "func setResidentProgress(", "func setResidentDeliveryNotice(",
               "private func updateResidentStatusNotice()", "func showChatStatus(", "func dismissChatStatus()", "func showReply(",
               "private func applyStatusNotice("].map {
    declaration($0, in: liveCam)
}.joined(separator: "\n")
// 「状态 → 符号」的唯一来源：`updateResidentStatusNotice` 会给进度行加上它。
// 把它整份拼进来，harness 里跑的就是**生产那一份**投影，不是抄来的副本。
let badgeTypes = try read("VisualEngine/ResidentStatusBadge.swift")
let harness = #"""
import Foundation
import simd
\#(noticeTypes)
\#(badgeTypes)
/// 生产里是 `@MainActor @Observable final class AgentSpeechStatusStore`；这里只要
/// "语音是否正在输出"这一个可读事实，所以给一个同名的非隔离替身 —— 被抽取的状态方法
/// 在 harness 里不在 MainActor 上，隔离版本反而编不过。
final class AgentSpeechStatusStore {
    static let shared = AgentSpeechStatusStore()
    var isSpeaking = false
}
final class Label { var stringValue = ""; var toolTip: String? }
final class Notice { var isHidden = true }
final class Height { var constant: CGFloat = 0 }
final class Status {
    var residentThinking = false
    var residentProgress: String?
    var residentDeliveryMessage: String?
    var residentStatusNotice: String?
    var residentStatusKind: ResidentStatusNoticeKind = .info
    var replyTurn = 0
    var latestReplyTurn = -1
    let deliveryLabel = Label()
    let deliveryNotice = Notice()
    var deliveryHeight: Height? = Height()
    var reply = "已有的居民回复"
    enum Presentation { case agentReply }
    func show(_ text: String, as presentation: Presentation) { reply = text }
    func updateComposerActions() {}
    func updateDeliveryNoticeHeight() {}
    \#(methods)
}
let state = Status()
state.setResidentThinking(true)
// 期望值由**生产符号**推出（`ResidentStatusBadge.thinkingSymbol`），不在 harness 里再抄
// 一遍 emoji 字面量 —— 否则符号一改，这条断言就变成了"两处字面量恰好相同"。
precondition(state.deliveryLabel.stringValue == ResidentStatusBadge.thinkingSymbol + " 等待居民回应…")
state.setResidentProgress("正在查询歌单…")
state.setResidentDeliveryNotice("2 条消息排队中")
precondition(state.deliveryLabel.stringValue.contains("查询歌单") && state.deliveryLabel.stringValue.contains("2 条消息"))
precondition(state.reply == "已有的居民回复")
state.showChatStatus("物件显示失败；所有权仍保留。")
state.setResidentThinking(true)
state.setResidentProgress("工具请求已返回，等待居民回应…")
if !state.deliveryLabel.stringValue.contains("物件显示失败") || !state.residentThinking {
    print("FAIL: same-run progress refresh must preserve application errors and thinking")
    exit(1)
}
state.setResidentThinking(false)
state.setResidentDeliveryNotice(nil)
state.showChatStatus("本轮请求超时；已保留输入。")
precondition(state.deliveryLabel.stringValue == "应用提示：本轮请求超时；已保留输入。")
precondition(state.reply == "已有的居民回复" && !state.deliveryNotice.isHidden)
state.dismissChatStatus()
precondition(state.reply == "已有的居民回复" && state.deliveryNotice.isHidden)
state.showChatStatus("旧错误")
state.showReply("DSH 原始回答")
precondition(state.reply == "DSH 原始回答" && state.deliveryNotice.isHidden)
state.showChatStatus("旧状态")
state.setResidentThinking(true)
precondition(!state.deliveryLabel.stringValue.contains("旧状态"))
print("PASS: Live Cam extracted production progress/status methods")
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-visible-progress-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
let script = temporary.appendingPathComponent("main.swift")
try harness.write(to: script, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [script.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 { failures += 1 }
let taskHarness = #"""
import Foundation
@main struct TaskTests {
    @MainActor static func main() {
        let store = WishMachineTaskPresentationStore()
        let id = UUID()
        let accepted = WishMachineTaskPresentation(id: id, title: "咖啡杯", status: "已受理", detail: nil, isTerminal: false)
        store.update([accepted])
        precondition(store.tasks == [accepted])
        let generating = WishMachineTaskPresentation(id: id, title: "咖啡杯", status: "正在生成", detail: "生成约需数分钟", isTerminal: false)
        store.update([generating])
        precondition(store.tasks.count == 1 && store.tasks[0].id == id && store.tasks[0].status == "正在生成")
        let ready = WishMachineTaskPresentation(id: id, title: "咖啡杯", status: "已放上展示台", detail: "领取和摆放已确认", isTerminal: true)
        store.update([ready])
        precondition(store.tasks == [ready], "completed task remains visible until host removes it")
        let failedID = UUID()
        let failed = WishMachineTaskPresentation(id: failedID, title: "花瓶", status: "生成失败", detail: "服务返回失败，尚未领取", isTerminal: true)
        store.update([ready, failed])
        precondition(store.tasks.map(\.id) == [id, failedID] && store.tasks.last?.detail == failed.detail)
        store.update([])
        precondition(store.tasks.isEmpty, "leaving task scope clears its presentation")
        print("PASS: same-ID wish task lifecycle and explicit scope clearing")
    }
}
"""#
let taskScript = temporary.appendingPathComponent("TaskTests.swift")
try taskHarness.write(to: taskScript, atomically: true, encoding: .utf8)
let taskExecutable = temporary.appendingPathComponent("tasks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-parse-as-library", taskModelPath,
                      // 任务行那一句委托给唯一投影（`OwnershipSentence` 是唯一出口），一起编。
                      root + "Presence/ResidentOwnershipProjection.swift",
                      taskScript.path, "-o", taskExecutable.path]
try compiler.run(); compiler.waitUntilExit()
if compiler.terminationStatus != 0 { failures += 1 }
else {
    let tasks = Process(); tasks.executableURL = taskExecutable
    try tasks.run(); tasks.waitUntilExit()
    if tasks.terminationStatus != 0 { failures += 1 }
}
print("\(failures == 0 ? "PASS" : "FAIL"): resident progress/task behavior and wiring, \(failures) failures")
exit(failures == 0 ? 0 : 1)
