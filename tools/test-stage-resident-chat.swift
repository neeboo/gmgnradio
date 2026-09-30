// Native chat state and production keyboard handlers, with no app/window/GPU.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let controller = try String(contentsOf: sources.appendingPathComponent("VisualEngine/StageWindowController.swift"), encoding: .utf8)
let overlay = try String(contentsOf: sources.appendingPathComponent("VisualEngine/StageOverlayView.swift"), encoding: .utf8)
let liveCamController = try String(contentsOf: sources.appendingPathComponent("DesktopPresence/LiveCamWindowController.swift"), encoding: .utf8)
let liveCamPanel = try String(contentsOf: sources.appendingPathComponent("DesktopPresence/LiveCamPanel.swift"), encoding: .utf8)
guard overlay.contains("var statusNotice:"), liveCamPanel.contains("private var residentStatusNotice:") else {
    print("FAIL: application errors still overwrite resident replies")
    exit(1)
}
guard controller.contains("func setResidentThinking("), controller.contains("func setResidentDeliveryNotice(") else {
    print("FAIL: loop state and uncertain delivery cannot update independently of the reply")
    exit(1)
}
guard controller.contains("func setResidentCanStop(") else {
    print("FAIL: a silent active resident has no independent stop state")
    exit(1)
}
guard overlay.contains("final class StageResidentChatState:"), controller.contains("func beginResidentReply()") else {
    print("FAIL: space has no resident composer or shared reply entry points")
    exit(1)
}
func declaration(_ signature: String, in text: String) -> String {
    let start = text.range(of: signature)!.lowerBound
    let opening = text[start...].firstIndex(of: "{")!
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("Unbalanced declaration")
}
let state = declaration("final class StageResidentChatState:", in: overlay)
// ── 窗口失焦：不许关掉装修会话 ────────────────────────────────────────────────
// 装修的"在手"状态只是一份**本地草稿**（`placement`/`candidate`，`preview` 从不改世界），
// 切到别的窗口去说话不构成"我放弃这次编辑"；The Sims 也不会因为切窗口就退出建造模式。
// 真机 2026-09-28（阻塞缺陷）：用户只是「打开装修 → 点了一下物件那一行 → 切窗口说话」，
// 装修在打开 4.4 s 后自己退出了，而 Debug 构建下一次派生要 4.8 s ⇒ 派生每次都被掐死、
// 结果被丢弃，面板于是永远说"还在生成"、那一行永远点不动。
// 明确的关闭意图各有入口（面板 X / Esc 链 / 切换面板 / 切换空间或世界 / 关窗），
// 所以失焦这条路上不许出现任何关闭或停用编辑器的动作（只读 `isOpen` 无妨）。
let resignKeyHandler = declaration("func windowDidResignKey(", in: controller)
for forbidden in ["close()", "deactivate", "escape(", "cancelPreview"] where resignKeyHandler.contains(forbidden) {
    print("FAIL: windowDidResignKey must not close or deactivate the decoration editor on focus loss (found \"\(forbidden)\")")
    exit(1)
}
if controller.contains("func windowDidBecomeKey") {
    let becomeKeyHandler = declaration("func windowDidBecomeKey(", in: controller)
    guard !becomeKeyHandler.contains("close()"), !becomeKeyHandler.contains("deactivate") else {
        print("FAIL: regaining window focus must not compensate for focus loss by closing the decoration editor")
        exit(1)
    }
}
guard overlay.contains("private func performPrimaryAction()") else {
    print("FAIL: speech playback has no stop action that preserves the completed reply")
    exit(1)
}
let primaryAction = declaration("private func performPrimaryAction()", in: overlay)
let canStop = declaration("private var canStopReply:", in: overlay)
let steeringControls = ["private var hasDraft:", "private var primaryStops:", "private func stopReply()"].map {
    declaration($0, in: overlay)
}.joined(separator: "\n")
let keyboard = ["override func keyDown(", "override func keyUp(", "override func flagsChanged(", "override func resignFirstResponder()", "override func scrollWheel(", "private static func movement(", "private static func gridRotationSteps("].map {
    declaration($0, in: controller)
}.joined(separator: "\n")
// ── 门禁的判据来源：**真正的输入框**，不是任意 `NSTextView` ──────────────────────
// 真机 2026-09-29：用户在「摆放」面板点了一行 → 进了携带态 → 鼠标不跟手、圆环点不动、
// `R`/`,`/`.` 全没反应。键盘这一半的机制是"keyDown 根本到不了场景交互视图"；而门禁里那条
// `window?.firstResponder is NSTextView` 又太宽：装修面板自己也是 SwiftUI 托管视图，点一下
// 它里面的东西就可能把 first responder 交给一个 `NSTextView` —— 那是"刚点完列表"，不是
// "正在打字"。判据本体 `stageTextInputOwnsFocus(host:firstResponder:)` 必须由**真正的输入框
// 宿主**（`residentComposer`）决定，`keyDown` 与 `consumesPropPointer` 都只读 `inputOwnsFocus`。
let inputFocusPredicate = declaration("@MainActor\nfunc stageTextInputOwnsFocus(", in: controller)
let inputOwnsFocus = declaration("private var inputOwnsFocus", in: controller)
guard controller.contains("var isTextInputFocused: (() -> Bool)?"),
      inputOwnsFocus.contains("isTextInputFocused?() ?? (window?.firstResponder is NSTextView)") else {
    print("FAIL: the scene gate must take \"is the input field typing\" from its host, and keep the old answer as the fail-closed fallback")
    exit(1)
}
// ── 装修模式下的相机键：编辑器先处理，其余键落到相机 ──────────────────────────
// 回归缺陷：`keyDown` 里曾有一条 `if propEditor.isOpen { return }` 的无条件拦截，于是装修
// 模式下 W/A/S/D 全被吃掉，用户连换个角度看落点都做不到（The Sims / Unity / Unreal 里
// 拿着物件时相机照常可用）。反过来也不许矫枉过正：相机那一段必须留在**所有**编辑器分支
// 之后，否则装修时 Esc / R / ⇧R / , / . / Delete / ⌘Z 会被相机抢走。
// 这里把分支顺序钉死（行为面在 harness 里逐键验），路径本身也不能再出现那条无条件拦截。
let keyDownBody = declaration("override func keyDown(", in: controller)
// 注释里会引用历史缺陷的写法（说明"原来那条拦截长什么样"），所以按行去掉 `//` 注释，
// 只对**代码**做结构判断。
let keyDownCode = keyDownBody.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
    guard let comment = line.range(of: "//") else { return String(line) }
    return String(line[line.startIndex..<comment.lowerBound])
}.joined(separator: "\n")
guard !keyDownCode.contains("if propEditor.isOpen { return }") else {
    print("FAIL: keyDown still blocks every key unconditionally while the decoration editor is open")
    exit(1)
}
guard keyDownCode.contains("inputOwnsFocus"), !keyDownCode.contains("is NSTextView") else {
    print("FAIL: keyDown must not decide \"the user is typing\" from any NSTextView")
    exit(1)
}
let keyDownBranchOrder = [
    "event.keyCode == 53",  // Esc：放回预览物件
    "Self.gridRotationSteps(for: event)",  // R / ⇧R / `,` / `.`
    "event.keyCode == 51",  // Delete / Forward Delete：收回
    "lowercased() == \"z\"",  // ⌘Z：撤销
    "Self.movement(for: event.keyCode)",  // 相机 W/A/S/D：必须最后
]
var branchCursor = keyDownCode.startIndex
for branch in keyDownBranchOrder {
    guard let found = keyDownCode.range(of: branch, range: branchCursor..<keyDownCode.endIndex) else {
        print("FAIL: the decoration editor's keys must all be handled before the camera branch in keyDown (broken order at \"\(branch)\")")
        exit(1)
    }
    branchCursor = found.upperBound
}
let replyMethods = ["func beginResidentReply()", "func finishResidentReply(", "func showResidentChatStatus(", "func setResidentThinking(", "func setResidentDeliveryNotice(", "func setResidentCanStop(", "func restoreResidentSubmission(", "func setVoiceState(", "func setWishMachineTasks("].map {
    declaration($0, in: controller)
}.joined(separator: "\n")
let chatToggle = declaration("private func toggleResidentChat()", in: controller)
let chatVisibility = declaration("private func updateResidentComposerVisibility()", in: controller)
let showChat = declaration("func showResidentChat()", in: controller)
let liveCamSend = declaration("private func sendMessage(", in: liveCamController)
guard !liveCamSend.contains("showChatStatus(\"…\")") else {
    print("FAIL: message admission leaves a permanent ellipsis application notice")
    exit(1)
}
let liveCamRestore = declaration("func restoreSubmission(", in: liveCamPanel)
let liveCamStop = declaration("private func stopResident()", in: liveCamPanel)
let liveCamTaskSetter = declaration("func setWishMachineTasks(", in: liveCamController)
let liveCamPanelTaskSetter = declaration("func setWishMachineTasks(", in: liveCamPanel)
let speechSource = try String(contentsOf: sources.appendingPathComponent("Agent/AgentSpeech.swift"), encoding: .utf8)
let speechStore = declaration("final class AgentSpeechStatusStore", in: speechSource)
let loopSource = try String(contentsOf: sources.appendingPathComponent("Agent/ResidentAgentLoop.swift"), encoding: .utf8)
let noticeTypes = [
    declaration("enum ResidentStatusNoticeKind:", in: loopSource),
    declaration("struct ResidentStatusNoticeDecision:", in: loopSource),
    declaration("enum ResidentStatusNoticeMerge", in: loopSource),
    declaration("struct ResidentChatTranscriptLine:", in: loopSource),
].joined(separator: "\n")
let imageInput = try String(contentsOf: sources.appendingPathComponent("Presence/ResidentImageAttachment.swift"), encoding: .utf8)
precondition(imageInput.contains("insertNewlineIgnoringFieldEditor(nil)") && imageInput.contains("field.maximumNumberOfLines = 3"), "attachment input retains multiline and Shift-Return input")
precondition(imageInput.contains("controlTextDidEndEditing") && overlay.contains("onBlur: { inputFocused = false }"), "focus decoration resets when editing ends")
precondition(!chatToggle.contains("cancel") && !chatToggle.contains("residentChat"), "collapsing chat must not cancel or reset its state")
precondition(controller.contains("residentComposer.trailingAnchor.constraint(equalTo: transportControls.trailingAnchor)"), "composer belongs above the bottom-right controls")
precondition(overlay.contains("ScrollView") && overlay.contains(".textSelection(.enabled)"), "reply must remain readable and selectable")
// ── 场景内旋转手柄的屏幕锚点 ─────────────────────────────────────────────────
// 手柄原先锚在"footprint 中心沿局部 +Z 外扩 max(0.35, 0.6 × 最大半宽) 米"的**世界点**上：
// 投影到屏幕后那个偏移是 `米数 / 相机距离` 量级，相机一近就缩到几个点，手柄被顶到光标
// 所在格的前方、永远点不到。改成"投影后的 footprint 中心 + **固定屏幕偏移**"之后，
// 锚点计算里不能再出现任何随距离缩放的量 —— 这条结构性性质下面与真实投影一起断言。
let rotationHandleAnchor = declaration("enum ResidentPropRotationHandleAnchor", in: controller)
guard rotationHandleAnchor.contains("screenOffsetX"),
      rotationHandleAnchor.contains("screenOffsetY") else {
    print("FAIL: the rotation handle anchor has no named screen-space offset constants")
    exit(1)
}
let handleWorldAnchor = declaration("private var rotationHandleWorldAnchor: SIMD3<Float>?", in: controller)
guard handleWorldAnchor.contains("placement.position"),
      !handleWorldAnchor.contains("outward"),
      !handleWorldAnchor.contains("spacing"),
      !handleWorldAnchor.contains("yaw") else {
    print("FAIL: the handle anchor must be the footprint centre, not a world-space forward expansion")
    exit(1)
}
let handleCenter = declaration("private var rotationHandleCenter: NSPoint?", in: controller)
guard handleCenter.contains("residentPropScreenPoint(world:") else {
    print("FAIL: the handle must project through the shared resident prop screen point")
    exit(1)
}
// 结构性的"没有随距离缩放的量"：纯函数只读投影点与视图尺寸，不再读格距/外扩米数。
guard !rotationHandleAnchor.contains("outward"),
      !rotationHandleAnchor.contains("spacing"),
      !rotationHandleAnchor.contains("spatialStage") else {
    print("FAIL: the handle anchor still scales with camera distance")
    exit(1)
}
// 可见圆环半径：下面"偏移量的下界"要拿它当基准，所以读生产的**唯一一份**
// （`StageWorldInteractionView.rotationHandleRadius`），不另抄一个魔数。数值本身也钉住：
// 26 pt 是圆环的既有尺寸，属于"不要动"的那批常量之一。
let rotationRingRadius: Double = {
    guard let line = controller.split(separator: "\n").first(where: {
              $0.contains("static let rotationHandleRadius")
          }),
          let value = Double(line.split(separator: "=").last?
              .trimmingCharacters(in: .whitespaces) ?? "") else {
        print("FAIL: the visible rotation ring radius is not declared in StageWindowController")
        exit(1)
    }
    return value
}()
guard rotationRingRadius == 26 else {
    print("FAIL: the visible rotation ring radius moved (expected 26 pt, got \(rotationRingRadius) pt)")
    exit(1)
}
let harness = #"""
import Foundation
import Combine
import AppKit
import Observation
import simd
import os
\#(rotationHandleAnchor)
@MainActor @Observable
\#(speechStore)
\#(noticeTypes)
@MainActor
\#(state)
enum SpatialMovement: Hashable { case forward, backward, left, right }
final class Window { var firstResponder: AnyObject? }
struct NSEvent {
    let keyCode: UInt16
    var scrollingDeltaY: Double = 0
    var hasPreciseScrollingDeltas = false
    /// 建造模式快捷键（R / Shift+R、Delete、Cmd+Z）要读的字段。
    struct ModifierFlags: OptionSet {
        let rawValue: UInt
        static let shift = ModifierFlags(rawValue: 1)
        static let command = ModifierFlags(rawValue: 2)
    }
    var modifierFlags: ModifierFlags = []
    var charactersIgnoringModifiers: String?
}
/// 场景门禁的**判据本体**（生产实现，逐字抽取）：first responder 必须是这个输入框宿主自己
/// 或它的后代。harness 用真 AppKit 视图树搭出"合成器里的 field editor"与"别处的 NSTextView"。
\#(inputFocusPredicate)
@MainActor class Responder {
    var window: Window? = Window()
    var forwarded: [UInt16] = []
    func keyDown(with event: NSEvent) { forwarded.append(event.keyCode) }
    func keyUp(with event: NSEvent) {}
    func flagsChanged(with event: NSEvent) {}
    func resignFirstResponder() -> Bool { true }
    func scrollWheel(with event: NSEvent) {}
}
@MainActor final class Store {
    var isWorldVisible = true
    /// 建造模式的状态由 `SpatialStageStore` 转发，`keyDown` 会读它来决定 R 键是否旋转。
    var isResidentPropBuildModeActive = false
    var residentPropBuildModeProjection: (inverseViewProjection: simd_float4x4, spacing: Float)?
    var movements: Set<SpatialMovement> = []
    var boosted = false
    var dollyCalls = 0
    func setMovement(_ movement: SpatialMovement, active: Bool) {
        if active { movements.insert(movement) } else { movements.remove(movement) }
    }
    func clearMovement() { movements.removeAll() }
    func setSpeedBoosted(_ value: Bool) { boosted = value }
    func dollyCamera(scrollDelta: Float, precise: Bool) { dollyCalls += 1 }
}
@MainActor final class Interaction: Responder {
    let spatialStage = Store()
    /// 被抽取的生产 `keyDown` 会写一条**只观测**的诊断（`场景输入链[11]`），并把分支记在
    /// `loggedSceneKeyBranches` 里。生产里那个 `private static let log` 是
    /// `StageWindowController.log` 的别名；harness 给它同名同形的替身（`Self.log`），
    /// 与 `test-resident-prop-editor` 里 `ControllerHarness.log` 是同一手法。
    /// 行为断言完全不受影响 —— 这两个成员都只被日志用到。
    static let log = Logger(subsystem: "test.gmgn.stage-chat", category: "chat")
    var loggedSceneKeyBranches: Set<String> = []
    final class PropEditor {
        var isOpen = false
        var escapeCalls = 0
        var withdrawCalls = 0
        var undoCalls = 0
        func escape() { escapeCalls += 1 }
        func withdraw() async { withdrawCalls += 1 }
        func undo() async { undoCalls += 1 }
    }
    let propEditor = PropEditor()
    /// 建造模式的 R / Shift+R 旋转回调。
    var onGridRotate: ((Int) -> Void)?
    var onGridCursor: ((SIMD2<Float>) -> Void)?
    /// 「真正的输入框正在打字」——生产里由宿主注入（`residentComposerOwnsFirstResponder()`）。
    /// 探针这里直接接生产判据本体 + 真 AppKit 视图树，于是"面板的 NSTextView"与"输入框的
    /// field editor"是**两个可分辨的事实**，而不是同一个 `is NSTextView`。
    var isTextInputFocused: (() -> Bool)?
    \#(inputOwnsFocus)
    \#(keyboard)
}
@MainActor final class Controller {
    final class Avatar { func setActivity(_ activity: StageAvatarActivity) {} }
    let residentChat = StageResidentChatState()
    let wishMachineTasks = WishMachineTaskPresentationStore()
    let stageContentView: ChatContent? = ChatContent()
    var voiceState = RealtimeVoiceConnectionState.disconnected
    let avatarRuntime = Avatar()
    \#(replyMethods)
}
enum RealtimeVoiceConnectionState: Equatable { case disconnected, connecting, connected, listening, speaking, failed(String) }
enum StageAvatarActivity { case listening, speaking, idle }
@MainActor final class ChatContent {
    final class Surface { var isHidden = true }
    final class World { var isWorldPresentationRequested = true }
    final class Editor { var isOpen = false; func close() { isOpen = false } }
    final class Controls {
        func setProgramRailExpanded(_ value: Bool) {}
        func setVisualPickerExpanded(_ value: Bool) {}
        func setResidentChatExpanded(_ value: Bool) {}
        func setResidentChatAvailable(_ value: Bool) {}
    }
    final class Overlay { func setProgramRailVisible(_ value: Bool) {} }
    final class Focus { func makeFirstResponder(_ value: AnyObject) {} }
    let residentComposer = Surface()
    let programRail = Surface(), visualPicker = Surface()
    let spatialStage = World(), residentPropEditor = Editor()
    let transportControls = Controls(), overlayState = Overlay()
    let window: Focus? = Focus(), worldInteractionView = Surface()
    var isResidentChatExpanded = false, isProgramRailVisible = false, isVisualPickerVisible = false
    func residentComposerOwnsFirstResponder() -> Bool { false }
    func collapse() { isResidentChatExpanded = false; updateResidentComposerVisibility() }
    func setVoiceState(_ state: RealtimeVoiceConnectionState) {}
    \#(showChat)
    \#(chatToggle)
    \#(chatVisibility)
}
@MainActor final class ComposerControls {
    let state = StageResidentChatState()
    let speechStatus = AgentSpeechStatusStore()
    var speechStops = 0
    init() {
        speechStatus.onStopSpeaking = { [weak self] in
            self?.speechStops += 1
            self?.speechStatus.isSpeaking = false
        }
    }
    var cancelled = 0
    var submitted = 0
    func onCancelMessage() { cancelled += 1 }
    func submit() { submitted += 1 }
    func press() { performPrimaryAction() }
    func pressStop() { stopReply() }
    \#(canStop)
    \#(steeringControls)
    \#(primaryAction)
}
@MainActor final class LiveCamControls {
    var thinking = true
    var cancelled = 0
    func setResidentThinking(_ value: Bool) { thinking = value }
    func onCancelMessage() { cancelled += 1 }
    func press() { stopResident() }
    \#(liveCamStop)
}
@MainActor final class LiveCamSubmission {
    var window: AnyObject?
    var messageRevision: UInt64 = 0
    var isThinking = false
    var status = ""
    var pending: [String: CheckedContinuation<Void, Error>] = [:]
    func setResidentThinking(_ value: Bool) { isThinking = value }
    func showChatStatus(_ value: String) { status = value }
    /// 被抽取的 `sendMessage` 在失败路径上会调它（生产里在 `LiveCamWindowController` 上）。
    var failureStatus: String?
    func showFailureStatus(_ text: String) { failureStatus = text }
    func onSendMessage(_ message: ResidentChatSubmission) async throws {
        try await withCheckedThrowingContinuation { pending[message.text] = $0 }
    }
    func send(_ message: String) { sendMessage(ResidentChatSubmission(text: message)) }
    \#(liveCamSend)
    \#(liveCamTaskSetter)
}
@MainActor final class LiveCamPanel {
    var interactionView: LiveCamPanel { self }
    let wishMachineTasks = WishMachineTaskPresentationStore()
    func restoreSubmission(_ submission: ResidentChatSubmission) {}
    \#(liveCamPanelTaskSetter)
}
@MainActor final class RecoveryField { var stringValue = "" }
@MainActor final class RecoveryComposer { var isHidden = false }
@MainActor final class LiveCamRecovery {
    let messageField = RecoveryField()
    let composer = RecoveryComposer()
    let images = ResidentAttachmentStore()
    var recovery = ResidentDraftRecovery()
    func onComposerVisibilityChanged(_ visible: Bool) {}
    func updateComposerActions() {}
    func updateReplyDisclosure() {}
    \#(liveCamRestore)
}
@main struct Tests {
    @MainActor static func main() async {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ text: String) { count += 1; if !condition { failures += 1; print("FAIL: \(text)") } }
        let state = StageResidentChatState()
        check(state.takeMessage() == nil && !state.isThinking, "blank message is not submitted")
        state.draft = "  去点唱机放首歌  \n"
        check(state.takeMessage()?.text == "去点唱机放首歌" && state.draft.isEmpty && state.isThinking, "submit trims message and starts waiting")
        state.draft = "下一条"
        check(state.takeMessage()?.text == "下一条" && state.draft.isEmpty && state.isThinking, "human guidance can be submitted while the loop is thinking")
        state.finish("正在播放")
        check(state.reply == "正在播放" && !state.isThinking, "reply exits waiting")
        state.draft = "接着说"
        check(state.takeMessage()?.text == "接着说", "new message works after reply")
        let attachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/test.png"), displayName: "测试")
        state.images.restore([attachment])
        let imageMessage = state.takeMessage()!
        check(imageMessage.text.isEmpty && imageMessage.attachments == [attachment], "image-only messages can be sent")
        state.restore(imageMessage, error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "此后端暂不支持图片"]))
        check(state.images.attachments == [attachment] && state.statusNotice?.contains("此后端暂不支持图片") == true && state.reply.isEmpty, "send failure restores images and explains provider capability separately from reply")
        state.cancel()
        check(!state.isThinking && state.statusNotice != nil && state.reply.isEmpty, "stop exits waiting with app notice, not a resident reply")
        let controller = Controller()
        let wishID = UUID()
        let generatingWish = WishMachineTaskPresentation(id: wishID, title: "咖啡杯", status: "正在生成", detail: "已受理，等待产物", isTerminal: false)
        controller.setWishMachineTasks([generatingWish])
        check(controller.stageContentView?.residentComposer.isHidden == true && controller.wishMachineTasks.tasks == [generatingWish], "wish updates preserve collapsed chat while updating the independent task store")
        controller.setVoiceState(.connecting)
        // **语义变化**：语音"正在连接"的反馈现在走独立的状态提示，**不再**把输入框顶出来
        // （生产里只有 `showResidentChat()` 会展开它）。旧断言钉的是更早的行为。
        check(
            controller.residentChat.statusNotice?.contains("正在连接语音转写") == true,
            "toolbar voice connection reports its feedback before transcripts arrive"
        )
        check(
            controller.stageContentView?.residentComposer.isHidden == true,
            "voice feedback does not hijack the composer"
        )
        check(controller.residentChat.statusNotice == "正在连接语音转写…" && !controller.residentChat.isThinking, "voice connecting has a visible status without pretending the resident is thinking")
        controller.stageContentView?.collapse()
        controller.setVoiceState(.connecting)
        check(controller.stageContentView?.residentComposer.isHidden == true, "repeated connection state does not reopen manually collapsed chat")
        controller.setVoiceState(.disconnected)
        controller.beginResidentReply()
        check(controller.residentChat.isThinking, "controller forwards shared reply start")
        check(controller.stageContentView?.residentComposer.isHidden == false, "resident reply start reveals the actual chat surface")
        controller.stageContentView?.collapse()
        controller.finishResidentReply("你好")
        check(controller.residentChat.reply == "你好" && !controller.residentChat.isThinking, "controller forwards shared reply finish")
        check(controller.stageContentView?.residentComposer.isHidden == false, "completed reply reaches a visible chat surface even after collapse")
        check(controller.wishMachineTasks.tasks == [generatingWish], "finished dialog does not end an asynchronous wish")
        controller.setResidentThinking(true)
        controller.stageContentView?.collapse()
        controller.setResidentThinking(true)
        check(controller.stageContentView?.residentComposer.isHidden == true, "same-run progress refresh respects manually collapsed chat")
        controller.setResidentDeliveryNotice("有补充消息尚未确认送达，未重复发送。")
        check(controller.residentChat.reply == "你好" && controller.residentChat.isThinking, "loop status update preserves completed reply")
        check(controller.residentChat.deliveryNotice != nil, "uncertain delivery is visible separately from the reply")
        controller.setResidentThinking(false)
        controller.setResidentDeliveryNotice(nil)
        check(controller.residentChat.reply == "你好" && !controller.residentChat.isThinking && controller.residentChat.deliveryNotice == nil, "clearing delivery and busy status preserves completed reply")
        controller.setResidentCanStop(true)
        check(controller.residentChat.canStop && !controller.residentChat.isThinking && controller.residentChat.reply == "你好", "silent owned activity exposes stop without implying thinking")
        controller.setResidentThinking(true)
        controller.showResidentChatStatus("连接失败")
        check(controller.residentChat.statusNotice == "连接失败" && controller.residentChat.reply == "你好" && controller.residentChat.isThinking, "application notice preserves actual resident reply and active task state")
        controller.setResidentThinking(true)
        check(controller.residentChat.statusNotice == "连接失败", "same-run thinking refresh preserves application notice")
        controller.stageContentView?.collapse()
        controller.showResidentChatStatus("资源显示失败")
        check(controller.wishMachineTasks.tasks == [generatingWish], "application error does not overwrite the independent wish task")
        check(controller.stageContentView?.residentComposer.isHidden == false, "application error reveals a collapsed chat surface")
        let content = controller.stageContentView!
        content.collapse()
        content.residentPropEditor.isOpen = true
        controller.showResidentChatStatus("编辑期间收到应用提示")
        check(content.residentPropEditor.isOpen && content.residentComposer.isHidden, "automatic chat disclosure preserves an in-progress prop edit")
        content.residentPropEditor.isOpen = false
        content.spatialStage.isWorldPresentationRequested = false
        controller.finishResidentReply("全屏尚未显示时的回复")
        check(content.residentComposer.isHidden, "resident feedback does not force a world presentation")
        content.spatialStage.isWorldPresentationRequested = true
        content.isVisualPickerVisible = true
        content.visualPicker.isHidden = false
        controller.finishResidentReply("你好")
        check(!content.residentComposer.isHidden && content.visualPicker.isHidden, "visible reply clears the overlapping visual picker")
        controller.residentChat.draft = "后续草稿"
        controller.restoreResidentSubmission(ResidentChatSubmission(text: "失败消息", attachments: [attachment]), notice: "后端连接中断")
        check(controller.residentChat.draft == "失败消息\n后续草稿" && controller.residentChat.images.attachments == [attachment], "late delivery failure restores original image and text without losing a newer draft")
        check(controller.residentChat.statusNotice?.contains("后端连接中断") == true && controller.residentChat.reply == "你好" && !controller.residentChat.isThinking, "restored delivery failure has separate notice and never resubmits")
        controller.finishResidentReply("居民新回复")
        check(controller.residentChat.statusNotice == nil && controller.residentChat.reply == "居民新回复", "new authentic reply clears stale application failure")
        controller.showResidentChatStatus("上一轮错误")
        controller.setResidentThinking(true)
        check(controller.residentChat.statusNotice == nil && controller.residentChat.reply == "居民新回复", "new run clears stale application error without overwriting authentic reply")
        // 后台/自驱回合（autoRevealsChat: false）只更新状态，绝不抢开聊天或收起用户面板。
        controller.setResidentThinking(false)
        content.collapse()
        content.isVisualPickerVisible = true
        content.visualPicker.isHidden = false
        controller.setResidentThinking(true, autoRevealsChat: false)
        check(content.residentComposer.isHidden, "background turn start never reveals a collapsed chat")
        check(!content.visualPicker.isHidden, "background turn start never closes the user's visual picker")
        controller.finishResidentReply("后台生活记录", autoRevealsChat: false)
        check(controller.residentChat.reply == "后台生活记录" && content.residentComposer.isHidden,
              "background reply is stored without stealing open the chat")
        controller.showResidentChatStatus("后台失败：稍后重试", autoRevealsChat: false)
        check(controller.residentChat.statusNotice == "后台失败：稍后重试" && content.residentComposer.isHidden,
              "background failure notice is visible without stealing open the chat")
        controller.setResidentThinking(false)
        content.collapse()
        controller.setResidentThinking(true, autoRevealsChat: true)
        check(!content.residentComposer.isHidden, "user-initiated turn still reveals the chat")
        controller.setResidentThinking(false)
        content.visualPicker.isHidden = true
        let imageA = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/A.png"), displayName: "A")
        let imageB = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/B.png"), displayName: "B")
        let failureA = ResidentChatSubmission(text: "A", attachments: [imageA], createdAt: Date(timeIntervalSince1970: 1))
        let failureB = ResidentChatSubmission(text: "B", attachments: [imageB], createdAt: Date(timeIntervalSince1970: 2))
        for failures in [[failureA, failureB], [failureB, failureA]] {
            let stage = StageResidentChatState()
            let cam = LiveCamRecovery()
            stage.draft = "新草稿"
            cam.messageField.stringValue = "新草稿"
            for failure in failures {
                stage.restore(failure, notice: "失败")
                cam.restoreSubmission(failure)
            }
            check(stage.draft == "A\nB\n新草稿" && stage.images.attachments == [imageA, imageB], "consecutive stage failure recovery keeps original text and image order")
            check(cam.messageField.stringValue == "A\nB\n新草稿" && cam.images.attachments == [imageA, imageB], "consecutive Live Cam failure recovery keeps original text and image order")
            stage.restore(failureA, notice: "重复通知")
            cam.restoreSubmission(failureA)
            check(stage.draft == "A\nB\n新草稿" && cam.messageField.stringValue == stage.draft, "repeated failure receipt does not duplicate recovered text")
        }
        let edited = StageResidentChatState()
        edited.restore(failureA, notice: "失败")
        edited.draft = "A 已修改\n我的新想法"
        edited.restore(failureB, notice: "失败")
        check(edited.draft.contains("A 已修改\n我的新想法") && edited.draft.hasSuffix("B"), "later failure never overwrites edited recovered text")
        let controls = ComposerControls()
        controls.state.finish("完整的文字回复")
        controls.speechStatus.isSpeaking = true
        controls.press()
        check(controls.cancelled == 0 && controls.submitted == 0 && controls.speechStops == 1, "speaking button stops only audio, not resident task or session")
        check(controls.state.reply == "完整的文字回复", "stopping audio preserves completed reply")
        controls.speechStatus.isSpeaking = false
        controls.state.begin()
        controls.press()
        check(!controls.state.isThinking && controls.cancelled == 1, "thinking stop retains existing cancellation behavior")
        controls.press()
        check(controls.submitted == 1, "idle primary button still sends")
        controls.state.begin()
        controls.state.draft = "换点舒缓的"
        controls.press()
        check(controls.submitted == 2 && controls.cancelled == 1 && controls.state.isThinking, "nonempty guidance sends without cancelling current work")
        controls.pressStop()
        check(controls.cancelled == 2 && controls.state.draft == "换点舒缓的" && !controls.state.isThinking, "independent stop cancels immediately and preserves pending guidance")
        controls.state.draft = ""
        controls.state.canStop = true
        controls.press()
        check(controls.cancelled == 3 && controls.submitted == 2 && !controls.state.isThinking, "silent resident activity remains stoppable after reply and speech end")
        controls.state.canStop = true
        controls.speechStatus.isSpeaking = true
        controls.press()
        check(controls.state.canStop && controls.cancelled == 3 && controls.speechStops == 2, "speaking stop preserves an active resident task")
        let liveStop = LiveCamControls()
        var liveSpeechStops = 0
        AgentSpeechStatusStore.shared.onStopSpeaking = { liveSpeechStops += 1; AgentSpeechStatusStore.shared.isSpeaking = false }
        AgentSpeechStatusStore.shared.isSpeaking = true
        liveStop.press()
        check(liveSpeechStops == 1 && liveStop.cancelled == 0 && liveStop.thinking, "Live Cam speaking stop preserves task and thinking state")
        liveStop.press()
        check(liveStop.cancelled == 1 && !liveStop.thinking, "Live Cam non-speaking task stop retains cancellation")
        let liveCam = LiveCamSubmission()
        let livePanel = LiveCamPanel()
        liveCam.window = livePanel
        liveCam.setWishMachineTasks([generatingWish])
        check(livePanel.wishMachineTasks.tasks == [generatingWish] && !liveCam.isThinking && liveCam.status.isEmpty, "Live Cam forwards wish identity and stage without creating thinking or application errors")
        liveCam.send("先找歌")
        while liveCam.pending["先找歌"] == nil { await Task.yield() }
        liveCam.send("换个风格")
        while liveCam.pending["换个风格"] == nil { await Task.yield() }
        liveCam.pending.removeValue(forKey: "先找歌")?.resume(throwing: CancellationError())
        for _ in 0..<10 { await Task.yield() }
        check(liveCam.isThinking && liveCam.status.isEmpty, "late error from older message cannot overwrite current guidance state")
        liveCam.pending.removeValue(forKey: "换个风格")?.resume()
        for _ in 0..<10 { await Task.yield() }
        check(liveCam.isThinking, "message admission completion does not finish the agent loop")
        let completedWish = WishMachineTaskPresentation(id: wishID, title: "咖啡杯", status: "已摆放", detail: nil, isTerminal: true)
        liveCam.setWishMachineTasks([completedWish])
        check(livePanel.wishMachineTasks.tasks.count == 1 && livePanel.wishMachineTasks.tasks.first == completedWish && liveCam.isThinking, "same wish updates its existing task independently of ongoing dialog")
        controller.setWishMachineTasks([])
        liveCam.setWishMachineTasks([])
        check(controller.wishMachineTasks.tasks.isEmpty && livePanel.wishMachineTasks.tasks.isEmpty, "host scope clearing reaches both task surfaces")
        let input = Interaction()
        input.keyDown(with: NSEvent(keyCode: 13))
        check(input.spatialStage.movements == [.forward], "W still moves in the scene")
        input.spatialStage.boosted = true
        _ = input.resignFirstResponder()
        check(input.spatialStage.movements.isEmpty && !input.spatialStage.boosted, "entering text editor stops previously held camera motion")
        input.window?.firstResponder = NSTextView()
        for key: UInt16 in [13, 0, 1, 2, 49] {
            input.keyDown(with: NSEvent(keyCode: key))
            check(input.spatialStage.movements.isEmpty && input.forwarded.last == key, "typing key \(key) is not consumed as a camera shortcut")
        }
        input.window?.firstResponder = input
        input.keyDown(with: NSEvent(keyCode: 2))
        check(input.spatialStage.movements == [.right], "D works again when scene regains focus")
        input.keyUp(with: NSEvent(keyCode: 2))
        check(input.spatialStage.movements.isEmpty, "key up still ends camera motion")
        input.scrollWheel(with: NSEvent(keyCode: 0, scrollingDeltaY: 2))
        check(input.spatialStage.dollyCalls == 1, "scene wheel dolly preserved")
        input.propEditor.isOpen = true
        // ── 装修模式下的相机键：编辑器不再无条件拦截 ──────────────────────────
        // 回归缺陷：`keyDown` 里曾有一条 `if propEditor.isOpen { return }`，装修时 WASD 全被
        // 吃掉，用户连换个角度看落点都做不到。相机键属于"编辑器不要的键"，必须落到相机。
        input.forwarded.removeAll()
        let cameraKeys: [(UInt16, SpatialMovement)] = [(13, .forward), (1, .backward), (0, .left), (2, .right)]
        for (key, movement) in cameraKeys {
            input.keyDown(with: NSEvent(keyCode: key))
            check(input.spatialStage.movements == [movement],
                  "camera key \(key) still moves the camera while the decoration editor is open")
            input.keyUp(with: NSEvent(keyCode: key))
            check(input.spatialStage.movements.isEmpty,
                  "camera key \(key) release still stops motion while the decoration editor is open")
        }
        check(input.forwarded.isEmpty,
              "while decorating, camera keys are consumed as camera motion instead of falling through the responder chain")
        input.keyDown(with: NSEvent(keyCode: 13))
        input.keyDown(with: NSEvent(keyCode: 2))
        check(input.spatialStage.movements == [.forward, .right],
              "holding W+D while decorating keeps both camera axes active")
        input.keyUp(with: NSEvent(keyCode: 13))
        input.keyUp(with: NSEvent(keyCode: 2))
        check(input.spatialStage.movements.isEmpty, "releasing the camera axes stops motion while decorating")
        // Shift 相机加速在装修模式下同样可用（与非装修模式的 `MetalStageView` 一致）。
        input.flagsChanged(with: NSEvent(keyCode: 56, modifierFlags: .shift))
        check(input.spatialStage.boosted, "Shift still boosts camera speed while the decoration editor is open")
        input.flagsChanged(with: NSEvent(keyCode: 56))
        check(!input.spatialStage.boosted, "releasing Shift drops the camera speed boost while decorating")
        // 编辑器自己的键仍然优先：既不能被相机抢走，也不许变成相机位移，更不许被转发出去。
        input.keyDown(with: NSEvent(keyCode: 53))
        check(input.propEditor.escapeCalls == 1 && input.spatialStage.movements.isEmpty && input.forwarded.isEmpty,
              "scene Escape cancels prop preview first and never becomes camera motion")
        input.keyDown(with: NSEvent(keyCode: 51))
        for _ in 0..<10 { await Task.yield() }
        check(input.propEditor.withdrawCalls == 1 && input.spatialStage.movements.isEmpty && input.forwarded.isEmpty,
              "Delete reclaims the prop while decorating and never becomes camera motion")
        input.keyDown(with: NSEvent(keyCode: 6, modifierFlags: .command, charactersIgnoringModifiers: "z"))
        for _ in 0..<10 { await Task.yield() }
        check(input.propEditor.undoCalls == 1 && input.spatialStage.movements.isEmpty && input.forwarded.isEmpty,
              "Cmd+Z undoes a placement while decorating and never becomes camera motion")
        input.window?.firstResponder = NSTextView()
        input.keyDown(with: NSEvent(keyCode: 53))
        check(input.propEditor.escapeCalls == 1 && input.forwarded.last == 53, "text focus owns Escape before scene editor")
        // 文本焦点优先于相机（焦点判断在 `keyDown` 最前面）：装修面板里打字时 WASD 不许被抢。
        for key: UInt16 in [13, 0, 1, 2] {
            input.keyDown(with: NSEvent(keyCode: key))
            check(input.spatialStage.movements.isEmpty && input.forwarded.last == key,
                  "text focus still owns camera key \(key) while the decoration editor is open")
        }
        // ── 门禁的判据来源：只有**真正的输入框**才算"正在打字" ──────────────────────
        // 真机 2026-09-29：用户在「摆放」面板点了一行 → 进了携带态（青色圆环画出来了）→ 但
        // 鼠标不跟手、点圆环没反应、`R`/`,`/`.`/Esc 全没反应。门禁里那条
        // `window?.firstResponder is NSTextView` 太宽：装修面板自己也是 SwiftUI 托管视图，
        // 点一下它里面的东西就可能把 first responder 交给一个 `NSTextView` —— 那是"刚点完
        // 列表"，不是"正在打字"。探针注入**生产判据本体**，两种 responder 于是可分辨。
        let composerHost = NSView()
        let composerField = NSTextView()
        composerHost.addSubview(composerField)
        // 窗口里**除了输入框之外**的文本视图（装修面板的托管视图里的控件、设置里的文本区…）：
        // 判据只该问"是不是那个输入框"，不该问"窗口里有没有文本视图"。
        let otherHost = NSView()
        let otherEditor = NSTextView()
        otherHost.addSubview(otherEditor)
        input.isTextInputFocused = {
            stageTextInputOwnsFocus(host: composerHost, firstResponder: input.window?.firstResponder)
        }
        // 输入框**真的**在打字：键盘仍然归它（这条保护一个字都不许放宽）。
        input.window?.firstResponder = composerField
        input.keyDown(with: NSEvent(keyCode: 53))
        check(input.propEditor.escapeCalls == 1 && input.forwarded.last == 53,
              "typing in the real input field still owns Escape before the scene editor")
        for key: UInt16 in [13, 0, 1, 2] {
            input.keyDown(with: NSEvent(keyCode: key))
            check(input.spatialStage.movements.isEmpty && input.forwarded.last == key,
                  "typing in the real input field still owns camera key \(key) while the decoration editor is open")
        }
        // 别处的 `NSTextView` 拿焦点**不是**打字：场景必须照常收键（旧判据在这里把场景挡死）。
        input.forwarded.removeAll()
        input.window?.firstResponder = otherEditor
        input.keyDown(with: NSEvent(keyCode: 53))
        check(input.propEditor.escapeCalls == 2 && input.forwarded.isEmpty,
              "a text view that is not the real input field must not take Escape away from the scene editor")
        input.keyDown(with: NSEvent(keyCode: 13))
        check(input.spatialStage.movements == [.forward],
              "a text view that is not the real input field must not block the scene camera keys")
        input.keyUp(with: NSEvent(keyCode: 13))
        check(input.spatialStage.movements.isEmpty, "releasing the camera key still stops motion")
        // 建造模式步进旋转键：R / ⇧R，以及 Sims 4 肌肉记忆的 `,`（逆时针）/ `.`（顺时针）。
        // 步长（45°）在映射层验证，这里只验键码与方向。
        input.window?.firstResponder = input
        input.spatialStage.isResidentPropBuildModeActive = true
        var rotations: [Int] = []
        input.onGridRotate = { rotations.append($0) }
        input.keyDown(with: NSEvent(keyCode: 43))
        input.keyDown(with: NSEvent(keyCode: 47))
        input.keyDown(with: NSEvent(keyCode: 15, charactersIgnoringModifiers: "r"))
        input.keyDown(with: NSEvent(keyCode: 15, modifierFlags: .shift, charactersIgnoringModifiers: "r"))
        check(rotations == [-1, 1, 1, -1], "`,` is counter-clockwise, `.` is clockwise, and Shift+R keeps reversing R")
        // `⌘,`（设置…）与 `⌘.`（取消）是系统/App 快捷键，不能被旋转吃掉。
        input.keyDown(with: NSEvent(keyCode: 43, modifierFlags: .command))
        input.keyDown(with: NSEvent(keyCode: 47, modifierFlags: .command))
        check(rotations == [-1, 1, 1, -1], "Cmd+, and Cmd+. are not swallowed as rotation shortcuts")
        // 不在建造模式时这些键不该旋转（R 依然按老规矩只在建造模式里生效）。
        input.spatialStage.isResidentPropBuildModeActive = false
        input.keyDown(with: NSEvent(keyCode: 43))
        input.keyDown(with: NSEvent(keyCode: 15, charactersIgnoringModifiers: "r"))
        check(rotations == [-1, 1, 1, -1], "rotation keys stay inert outside build mode")

        // ── 场景内旋转手柄：锚点 = footprint 中心的投影 + 固定屏幕偏移 ──────────
        // bug 的本质是"偏移随相机距离缩放"（世界空间外扩把圆环顶到光标前面）。锚点计算已经
        // 纯函数化（`ResidentPropRotationHandleAnchor.center`），于是可以用**两个不同尺度**的
        // 真实投影断言：同一个世界点在不同相机距离下，圆心相对投影中心的偏移**完全相等**。
        let handleViewSize = CGSize(width: 1440, height: 900)
        // 与 `MarbleSpatialView` 同一套投影：perspective(fov 66°) * rotationX(-pitch) *
        // rotationY(-yaw) * translation(-camera.position)。相机在 y = 0.8 m、俯角 25°、
        // yaw 0，离世界点（一个格心）的水平距离就是 `groundDistance`。
        func handleProjection(groundDistance: Float) -> simd_float4x4 {
            let world = SIMD3<Float>(0, 0, -2)
            let fov: Float = 66 * .pi / 180
            let aspect = Float(handleViewSize.width / handleViewSize.height)
            let y = 1 / tan(fov * 0.5), x = y / aspect
            let near: Float = 0.05, far: Float = 250, z = far / (near - far)
            let projection = simd_float4x4(columns: (
                SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)
            ))
            let pitch: Float = -25 * .pi / 180
            let cosine = cos(pitch), sine = sin(pitch)
            let rotation = simd_float4x4(columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, cosine, -sine, 0),
                SIMD4(0, sine, cosine, 0), SIMD4(0, 0, 0, 1)
            ))
            let camera = SIMD3<Float>(0, 0.8, world.z + groundDistance)
            let translation = simd_float4x4(columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                SIMD4(0, 0, 1, 0), SIMD4(-camera.x, -camera.y, -camera.z, 1)
            ))
            return projection * rotation * translation
        }
        func handleScreenPoint(_ world: SIMD3<Float>, _ viewProjection: simd_float4x4) -> SIMD2<Float> {
            let clip = viewProjection * SIMD4(world, 1)
            return SIMD2((clip.x / clip.w + 1) / 2, (1 - clip.y / clip.w) / 2)
        }
        func handleAnchorOffset(_ normalized: SIMD2<Float>) -> CGPoint {
            let centre = ResidentPropRotationHandleAnchor.center(
                projectedCenter: normalized, viewSize: handleViewSize)
            return CGPoint(
                x: centre.x - CGFloat(normalized.x) * handleViewSize.width,
                y: centre.y - CGFloat(1 - normalized.y) * handleViewSize.height
            )
        }
        let handleWorld = SIMD3<Float>(0, 0, -2)
        let nearProjection = handleScreenPoint(handleWorld, handleProjection(groundDistance: 1))
        let farProjection = handleScreenPoint(handleWorld, handleProjection(groundDistance: 3))
        check(abs(nearProjection.x - farProjection.x) > 0.001 || abs(nearProjection.y - farProjection.y) > 0.001,
              "the same footprint centre projects to different points at different camera distances")
        let nearOffset = handleAnchorOffset(nearProjection)
        let farOffset = handleAnchorOffset(farProjection)
        check(nearOffset == farOffset,
              "the handle offset from the projected footprint centre is independent of camera distance")
        check(nearOffset == ResidentPropRotationHandleAnchor.screenOffset,
              "the handle offset is exactly the named screen-space constant")
        check(nearOffset.x == ResidentPropRotationHandleAnchor.screenOffsetX
                && nearOffset.y == ResidentPropRotationHandleAnchor.screenOffsetY,
              "both named offset constants feed the anchor")
        // 偏移量的下界（2026-09-29 换了个理由）：圆环是**静态提示**，原来那个 32 pt 悬停命中区
        // （`rotationHandleHitRadius` / `isRotationHandleHit`）已整体删除 —— 现在全文件不再
        // 出现手型光标，也不再有"悬停变亮"，见 `test-resident-prop-editor.swift` 里
        // "圆环不再随悬停变亮、不再改光标"那组断言。仍然要守的是：**可见圆环不许压住
        // footprint 中心的投影点**（那是落点、也是用户在瞄的地方）。所以偏移必须大于圆环
        // 半径；半径由脚本顶部从生产源码里读出并钉住（`\#(rotationRingRadius)` pt），
        // 这里不另抄魔数。34/10 这个值一个字都没动。
        check(hypot(nearOffset.x, nearOffset.y) > \#(rotationRingRadius),
              "the screen offset stays outside the visible ring radius (\#(rotationRingRadius) pt) so the ring never sits on the footprint centre the user is aiming at")
        // 上界：每个分量都要落在 hover 格的投影范围内（格心吸附跟着光标走，跨过一列/一行
        // 圆环就会跟着跳一格）。0.25 m 的格子在 1.5 / 2.0 / 2.2 m 处的投影半宽×半深实测约
        // 51.0×21.2 / 40.3×13.6 / 37.1×11.6 pt，34/10 都装得下（2.2 m 就是这套偏移的边界）；
        // 44 pt 这类垂直偏移在 ~0.85 m 外就出格了。
        for (groundDistance, expected) in [
            (Float(1.5), SIMD2<Float>(51.0, 21.2)),
            (Float(2.0), SIMD2<Float>(40.3, 13.6)),
            (Float(2.2), SIMD2<Float>(37.1, 11.6)),
        ] {
            let projection = handleProjection(groundDistance: groundDistance)
            let centre = handleScreenPoint(handleWorld, projection)
            let column = handleScreenPoint(handleWorld + SIMD3<Float>(0.25, 0, 0), projection)
            let row = handleScreenPoint(handleWorld + SIMD3<Float>(0, 0, -0.25), projection)
            let halfWidth = abs(column.x - centre.x) * Float(handleViewSize.width) / 2
            let halfDepth = abs(row.y - centre.y) * Float(handleViewSize.height) / 2
            check(abs(halfWidth - expected.x) < 0.5 && abs(halfDepth - expected.y) < 0.5,
                  "the projected cell at \(groundDistance) m measures \(expected) pt (bounds the offset)")
            check(abs(nearOffset.x) < CGFloat(halfWidth) && abs(nearOffset.y) < CGFloat(halfDepth),
                  "the handle stays inside the hovered cell at \(groundDistance) m, so the pointer can reach it")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(count) stage resident chat checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-stage-chat-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let source = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: source, atomically: true, encoding: .utf8)
func run(_ binary: String, _ args: [String]) throws -> Int32 {
    let task = Process(); task.executableURL = URL(fileURLWithPath: binary); task.arguments = args
    try task.run(); task.waitUntilExit(); return task.terminationStatus
}
let executable = temporary.appendingPathComponent("test")
// Type-check the real SwiftUI view and AppKit button without launching a host.
let uiSource = temporary.appendingPathComponent("UI.swift")
let ui = "import SwiftUI\nimport AppKit\nimport Observation\n@MainActor\n@Observable\n"
    + declaration("final class AgentSpeechStatusStore", in: speechSource) + "\n@MainActor\n"
    + noticeTypes + "\n@MainActor\n"
    + declaration("struct ResidentSpeechErrorNotice:", in: overlay) + "\n@MainActor\n"
    + declaration("struct WishMachineTaskStatusView:", in: overlay) + "\n@MainActor\n"
    + state + "\n@MainActor\n"
    + declaration("struct StageResidentComposer:", in: overlay) + "\n@MainActor\n"
    + declaration("private final class StageResidentChatButton:", in: controller)
try ui.write(to: uiSource, atomically: true, encoding: .utf8)
let attachmentSources = ["Presence/ResidentImageAttachment.swift", "Presence/PropImagePreparation.swift", "Presence/PropGenerationClient.swift", "Presence/WishMachineTaskPresentation.swift"].map { sources.appendingPathComponent($0).path }
let checked = try run("/usr/bin/swiftc", ["-j1", "-typecheck", "-target", "arm64-apple-macos14.0", uiSource.path] + attachmentSources)
guard checked == 0 else { exit(checked) }
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", source.path, "-o", executable.path] + attachmentSources)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
