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
guard overlay.contains("private func performPrimaryAction()") else {
    print("FAIL: speech playback has no stop action that preserves the completed reply")
    exit(1)
}
let primaryAction = declaration("private func performPrimaryAction()", in: overlay)
let canStop = declaration("private var canStopReply:", in: overlay)
let steeringControls = ["private var hasDraft:", "private var primaryStops:", "private func stopReply()"].map {
    declaration($0, in: overlay)
}.joined(separator: "\n")
let keyboard = ["override func keyDown(", "override func keyUp(", "override func resignFirstResponder()", "override func scrollWheel(", "private static func movement("].map {
    declaration($0, in: controller)
}.joined(separator: "\n")
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
let harness = #"""
import Foundation
import Combine
import AppKit
import Observation
@MainActor @Observable
\#(speechStore)
\#(noticeTypes)
@MainActor
\#(state)
enum SpatialMovement: Hashable { case forward, backward, left, right }
final class Window { var firstResponder: AnyObject? }
struct NSEvent { let keyCode: UInt16; var scrollingDeltaY: Double = 0; var hasPreciseScrollingDeltas = false }
@MainActor class Responder {
    var window: Window? = Window()
    var forwarded: [UInt16] = []
    func keyDown(with event: NSEvent) { forwarded.append(event.keyCode) }
    func keyUp(with event: NSEvent) {}
    func resignFirstResponder() -> Bool { true }
    func scrollWheel(with event: NSEvent) {}
}
@MainActor final class Store {
    var isWorldVisible = true
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
    final class PropEditor {
        var isOpen = false
        var escapeCalls = 0
        func escape() { escapeCalls += 1 }
    }
    let propEditor = PropEditor()
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
        check(controller.stageContentView?.residentComposer.isHidden == false, "toolbar voice connection reveals its feedback before transcripts arrive")
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
        input.keyDown(with: NSEvent(keyCode: 13))
        check(input.spatialStage.movements.isEmpty, "editing cannot leak W into camera movement")
        input.keyDown(with: NSEvent(keyCode: 53))
        check(input.propEditor.escapeCalls == 1, "scene Escape cancels prop preview first")
        input.window?.firstResponder = NSTextView()
        input.keyDown(with: NSEvent(keyCode: 53))
        check(input.propEditor.escapeCalls == 1 && input.forwarded.last == 53, "text focus owns Escape before scene editor")
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
