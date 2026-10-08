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
let nativeState = declaration("final class StageResidentChatState:", in: overlay)
let nativeImages = """
let images = ResidentAttachmentStore(
        directory: E2ERuntime.applicationSupportBase?
            .appendingPathComponent("gmgn radio/ResidentAttachments", isDirectory: true))
"""
precondition(nativeState.contains(nativeImages), "fixture must replace only the native endpoint constructor")
let state = nativeState.replacingOccurrences(of: nativeImages, with: "let images = AttachmentFixture.makeStore()")
let privateAttachmentGlue = #"""
@MainActor enum AttachmentFixture {
    static func settings() -> RustProductSettingsClient {
        let rpc = try! PrivateRPC(CommandLine.arguments[1])
        return RustProductSettingsClient(call: { [rpc] method, data in try rpc.call(method, data) })
    }
    static func makeStore() -> ResidentAttachmentStore {
        let rpc = try! PrivateRPC(CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).appendingPathComponent("stage-draft-\(UUID())", isDirectory: true)
        return ResidentAttachmentStore(directory: directory,
            authority: RustChatAttachmentClient(call: { [rpc] method, data in try rpc.call(method, data) }))
    }
    static func png() -> Data {
        NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:12,pixelsHigh:12,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
    }
    static func issued(_ store: ResidentAttachmentStore, text: String, date: Date) async throws -> ResidentChatSubmission {
        await store.add(imageData: png())
        let issued = try await store.takeSubmission(text: text)
        return .init(text: text, attachments: issued.attachments, id: issued.id, createdAt: date)
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {throw FixtureFailure.timedOut}
            try await Task.sleep(for:.milliseconds(10))
        }
    }
}
"""#
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
    // `ResidentChatTranscriptLine.interruptedText` 的形参是 `ResidentChatTurn.Interruption`，
    // 而 `struct ResidentChatTurn` 只依赖 Foundation —— 必须一并切进来，否则编出的
    // `UI.swift` 找不到 `ResidentChatTurn`（2026-10-03 的既有红）。与
    // `test-livecam-panel-sizing.swift` / `test-resident-chat-transcript.swift` 同一手法。
    declaration("struct ResidentChatTurn:", in: loopSource),
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
// ── 居民状态 → 符号：唯一来源 + 头顶气泡（世界锚定） ─────────────────────────
// 三个渲染点（舞台头顶气泡、舞台状态行、Live Cam 面板状态行）必须都从
// `ResidentStatusBadge` 取符号；emoji 字面量只许在那一份文件里出现。
let badgeSourcePath = sources.appendingPathComponent("VisualEngine/ResidentStatusBadge.swift").path
let badge = try String(contentsOfFile: badgeSourcePath, encoding: .utf8)
let marble = try String(contentsOf: sources.appendingPathComponent("VisualEngine/Metal/MarbleSpatialView.swift"), encoding: .utf8)
let headBadgeView = declaration("struct StageResidentHeadBadgeView:", in: overlay)
guard badge.contains("static let thinkingSymbol"),
      badge.contains("static let speakingSymbol") else {
    print("FAIL: 状态→符号的唯一来源没有命名常量（思考/说话符号必须各只有一份定义）")
    exit(1)
}
guard overlay.contains("ResidentStatusBadge.statusLine("),
      liveCamPanel.contains("ResidentStatusBadge.decorate("),
      headBadgeView.contains("ResidentStatusBadge.symbol(") else {
    print("FAIL: 舞台状态行 / Live Cam 状态行 / 头顶气泡必须共用同一个状态→符号来源")
    exit(1)
}
for (name, source) in [("舞台覆盖层", overlay), ("Live Cam 面板", liveCamPanel),
                       ("Live Cam 窗口控制器", liveCamController)]
where source.contains("🤔") || source.contains("🗣️") {
    print("FAIL: \(name) 里出现了 emoji 字面量 —— 那就是第二份来源，改一处会分叉")
    exit(1)
}
// 头顶锚点必须来自**角色当前摆放 + 既有绑定矩阵 + 既有投影**，不许自己造一套。
guard headBadgeView.contains("MarblePMXFraming.modelTransform("),
      headBadgeView.contains("spatialStage.avatarPlacement") else {
    print("FAIL: 头顶锚点必须复用既有角色绑定矩阵（MarblePMXFraming.modelTransform）并跟随角色摆放")
    exit(1)
}
guard headBadgeView.contains("residentPropScreenPoint("),
      !headBadgeView.contains("perspective"),
      !headBadgeView.contains("lookAt") else {
    print("FAIL: 头顶锚点必须复用既有投影（residentPropScreenPoint），不许新造投影")
    exit(1)
}
// 间隙要按角色**在屏幕上的身高**缩放，所以脚点也要走同一套既有投影（两次投影）。
guard headBadgeView.contains("residentPropScreenPoint(world: placement.position)"),
      headBadgeView.contains("characterScreenHeight: geometry.characterScreenHeight") else {
    print("FAIL: 与头的间隙必须按角色屏高缩放，必须同时投影脚点并把它交给 anchor")
    exit(1)
}
// 跟随的是**身体根节点**（placement + 归一化身高），不是头骨姿态。
guard headBadgeView.contains("spatialStage.avatarPlacement"),
      !headBadgeView.contains("headBone"),
      !headBadgeView.contains("boneMatrix") else {
    print("FAIL: 气泡跟随的应当是身体根节点（点头/转身不该把气泡甩走）")
    exit(1)
}
// 配色也只有一份：气泡视图里不许出现任何颜色字面量（RGB 只在 ResidentStatusBadgeInk 里）。
for literal in ["Color(white:", "Color(red:", "Color.white", "Color.black"] where headBadgeView.contains(literal) {
    print("FAIL: 头顶气泡里出现了颜色字面量 \(literal) —— 配色必须只有一份")
    exit(1)
}
guard headBadgeView.contains("ResidentStatusBadge.cloudFill.color"),
      headBadgeView.contains("ResidentStatusBadge.cloudOutline.color"),
      headBadgeView.contains("ResidentStatusBadge.tailDotFill.color"),
      headBadgeView.contains("ResidentStatusBadge.tailDotOutline.color"),
      headBadgeView.contains("ResidentStatusBadge.symbolInk.color") else {
    print("FAIL: 云体/描边/指向点/符号的配色必须全部从 ResidentStatusBadgeInk 取")
    exit(1)
}
guard badge.contains("static let cloudFill"), badge.contains("static let symbolInk"),
      badge.contains("static var tailDotFill") else {
    print("FAIL: 配色必须在 ResidentStatusBadge 里声明为唯一一份")
    exit(1)
}
// 覆盖层穿透点击：宿主 hosting view 的 hitTest 返回 nil，气泡自己也关掉命中测试。
let overlayHost = declaration("private final class StageOverlayHostingView:", in: controller)
guard overlayHost.contains("override func hitTest(_ point: NSPoint) -> NSView?") else {
    print("FAIL: 头顶气泡所在的覆盖层没有 hitTest 覆写")
    exit(1)
}
guard headBadgeView.contains(".allowsHitTesting(false)") else {
    print("FAIL: 头顶气泡必须 allowsHitTesting(false)，否则会挡住场景的指针")
    exit(1)
}
// 空闲态不画：气泡的存在性只由 `isVisible(isThinking:isSpeaking:)` 决定。
guard headBadgeView.contains("if visible"),
      headBadgeView.contains("ResidentStatusBadge.isVisible(") else {
    print("FAIL: 气泡必须由状态投影决定画不画（空闲态整朵消失）")
    exit(1)
}
// 头顶本地高度与生产绑定矩阵里的 `normalizedHeight` 是**同一个量**：这里读出生产值，
// 下面拿它钉住 `ResidentStatusBadge.headLocalTopY` —— 改一处不会静默错位。
let marblenormalizedHeight: Double = {
    guard let line = marble.split(separator: "\n").first(where: {
              $0.contains("normalizedHeight: Float =")
          }),
          let value = Double(line.split(separator: "=").last?
              .trimmingCharacters(in: .whitespaces) ?? "") else {
        print("FAIL: MarblePMXFraming.normalizedHeight is not declared")
        exit(1)
    }
    return value
}()
// ── 拖拽接收图片（访达把图拖进窗口）──────────────────────────────────────────
//
// 用户一直说"给它图不行"，而图片链那两条判据在生产形状下都是 true —— 真因是全仓
// **没有任何拖拽接收**：从访达把图拖进对话面板，没有附件、没有报错、也没有日志。
// 这一段把"拖进来"锁成与「＋ 选择文件」**同一条附件入口**，且不许落点自己解析图片。
let attachmentSource = try String(contentsOf: sources.appendingPathComponent("Presence/ResidentImageAttachment.swift"), encoding: .utf8)
let composer = declaration("struct StageResidentComposer:", in: overlay)
let chooseImages = declaration("func chooseImages()", in: attachmentSource)
let storeAddURLs = declaration("func add(urls: [URL]) async", in: attachmentSource)
let attachmentStrip = declaration("struct ResidentAttachmentStrip:", in: attachmentSource)
let dropView = declaration("final class ResidentImageDropView:", in: attachmentSource)
let dropTarget = declaration("struct ResidentImageDropTarget:", in: attachmentSource)
let dropPolicy = declaration("enum ResidentImageDropPolicy {", in: attachmentSource)
let dropMouseWatch = declaration("enum ResidentImageDropMouseWatch {", in: attachmentSource)
let dropMouseWatchHitTest = declaration("static func allowsHitTesting", in: attachmentSource)
let dropHitTest = declaration("override func hitTest(_ point: NSPoint) -> NSView?", in: attachmentSource)
let dropEntered = declaration("override func draggingEntered(", in: attachmentSource)
let dropUpdated = declaration("override func draggingUpdated(", in: attachmentSource)
let dropPerform = declaration("override func performDragOperation(", in: attachmentSource)
let acceptDroppedFiles = declaration("private func acceptDroppedImageFiles(_ urls: [URL])", in: composer)
// 断言 1：拖进来的图片文件必须走「＋ 选择文件」**同一条**入口。
guard chooseImages.contains("add(urls: panel.urls)") else {
    print("FAIL: 「＋ 选择文件」不是走 add(urls:)，本断言的前提失效")
    exit(1)
}
guard storeAddURLs.contains("ResidentImageFilePolicy.isImageFileURL(url)"),
      dropPolicy.contains("fileURLs.contains(where: ResidentImageFilePolicy.isImageFileURL)") else {
    print("FAIL: 拖拽判据与 store 的校验不是同一份判据 —— 不许出现第二份「是不是图片」")
    exit(1)
}
guard overlay.contains("ResidentImageDropTarget(") else {
    print("FAIL: 对话面板/输入框上没有注册拖拽落点（拖进来的图片还是不会发生任何事）")
    exit(1)
}
guard composer.contains("ResidentImageDropTarget("),
      composer.contains("onFileURLs: acceptDroppedImageFiles"),
      acceptDroppedFiles.contains("state.images.add(urls: urls)") else {
    print("FAIL: 拖进来的图片文件没有走「＋ 选择文件」同一条入口（ResidentAttachmentStore.add(urls:)）")
    exit(1)
}
guard composer.contains("state.images.add(imageData: data)") else {
    print("FAIL: 直接拖进来的位图没有走「⌘V」同一条入口（ResidentAttachmentStore.add(imageData:)）")
    exit(1)
}
// 落点**不许**自己解析图片字节 / 自己归一化：否则又会变成两份真相。
// 扫描范围包含 composer 上的那两个回执函数（拖拽真正落地的地方）。
for token in ["PropImagePreparation", "NSImage(", "CIImage", "data(contentsOf", "writePrivate",
              "UTType(", "pngData", "CGImageSource", "sips"]
where dropView.contains(token) || dropTarget.contains(token) || composer.contains(token) {
    print("FAIL: 拖拽落点自己解析了图片（\(token)）—— 必须复用既有附件入口，不允许第二条通道")
    exit(1)
}
// 一次拖拽里的所有文件 URL 都要交出去，由 store 逐个校验（混合拖拽里的非图片文件
// 不能被落点先筛掉，否则就是静默丢弃）。
guard dropView.contains("onFileURLs(urls)"), !dropView.contains("urls.filter") else {
    print("FAIL: 拖拽落点自己筛过一遍文件 URL —— 被筛掉的那些会成为静默丢弃")
    exit(1)
}
// 断言 2：非图片拖拽不亮起、不接入、也不报假成功。
// 逐条声明地钉：进入与移动**两处**的高亮都必须读同一份判据，且落点里不允许出现
// 任何**无条件**点亮（`setTargeted(true)`）—— 只看"文件里某处出现过判据"是抓不住的
// （实测把 draggingEntered 改成无条件点亮，只查 contains 的版本照样 PASS）。
guard dropEntered.contains("setTargeted(payload.isAccepted)"),
      dropUpdated.contains("setTargeted(payload.isAccepted)"),
      !dropView.contains("setTargeted(true)"),
      !dropView.contains("onTargetingChange(true)"),
      dropEntered.contains("return payload.isAccepted ? .copy : []"),
      dropUpdated.contains("return payload.isAccepted ? .copy : []"),
      dropPerform.contains("case .unsupported:"),
      dropPerform.contains("return false") else {
    print("FAIL: 拖拽高亮/接受必须只由「这一笔里有没有图片」决定（非图片不许亮起、不许接入）")
    exit(1)
}
// 断言 3：超过上限不许在落点静默截断 —— 上限与拒绝文案都归 store 那一份逻辑。
for token in ["prefix(", "dropLast", "removeLast", "urls[0", "< 4", "> 4", ">= 4", "count == 4"] where acceptDroppedFiles.contains(token) {
    print("FAIL: 拖拽落点自己判/自己截断上限（\(token)）—— 超过 4 张会被静默丢弃，必须由 store 给出可见拒绝")
    exit(1)
}
guard storeAddURLs.contains("每条消息最多添加 4 张图片。") else {
    print("FAIL: 超过 4 张的可见拒绝必须由既有的 store 逻辑给出")
    exit(1)
}
guard attachmentStrip.contains("store.errorMessage") else {
    print("FAIL: 拒绝原因没有被渲染出来（ResidentAttachmentStrip 必须显示 store.errorMessage）")
    exit(1)
}
guard storeAddURLs.contains("原因=上一批还在准备") else {
    print("FAIL: 上一批还在准备时的第二次接入会被静默丢掉（store 必须给出可见原因）")
    exit(1)
}
// 断言 4：拖拽不许抢走场景里的鼠标交互。
guard dropHitTest.contains("ResidentImageDropPolicy.allowsHitTesting("),
      dropHitTest.contains("return nil"),
      dropHitTest.contains("return super.hitTest(point)"),
      dropMouseWatchHitTest.contains("return isPointerDragEvent(eventType)") else {
    print("FAIL: 落点的命中必须由 allowsHitTesting 门禁决定（否则本地点选/相机拖动/装修拖动会被它截住）")
    exit(1)
}
guard dropMouseWatchHitTest.contains("guard !localMouseIsDown"),
      dropMouseWatch.contains("NSEvent.addLocalMonitorForEvents") else {
    print("FAIL: 必须能区分「本 app 自己按着鼠标」（相机旋转/装修拖动的事件类型与访达拖进来相同）")
    exit(1)
}
for token in ["override func mouseDown", "override func mouseDragged", "override func mouseUp", "override func scrollWheel"] where dropView.contains(token) {
    print("FAIL: 落点自己接管了鼠标事件（\(token)）—— 门禁已保证非拖拽时刻它完全不存在")
    exit(1)
}
guard controller.contains("ResidentPropEditorState.consumesScenePointer("),
      controller.contains("Float(1 - point.y / bounds.height)"),
      controller.contains("worldInteractionView.layer?.zPosition = 6"),
      overlayHost.contains("override func hitTest(_ point: NSPoint) -> NSView?") else {
    print("FAIL: 场景指针链路（门禁签名/归一化/世界交互层/覆盖层穿透）必须原样保留")
    exit(1)
}
let harness = #"""
import Foundation
import Combine
import AppKit
import Observation
import simd
import os
\#(privateAttachmentGlue)
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
    var timestamp: TimeInterval = 0
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
    func dollyCamera(scrollDelta: Float, precise: Bool, eventTimestamp: TimeInterval = 0) { dollyCalls += 1 }
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
    let wishMachineTasks = WishMachineTaskPresentationStore(productSettings: AttachmentFixture.settings())
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
    let wishMachineTasks = WishMachineTaskPresentationStore(productSettings: AttachmentFixture.settings())
    func restoreSubmission(_ submission: ResidentChatSubmission) {}
    \#(liveCamPanelTaskSetter)
}
@MainActor final class RecoveryField { var stringValue = "" }
@MainActor final class RecoveryComposer { var isHidden = false }
@MainActor final class LiveCamRecovery {
    let messageField = RecoveryField()
    let composer = RecoveryComposer()
    let images = AttachmentFixture.makeStore()
    var recovery = ResidentDraftRecovery()
    func onComposerVisibilityChanged(_ visible: Bool) {}
    func updateComposerActions() {}
    func updateReplyDisclosure() {}
    func applyStatusNotice(_ text: String, kind: ResidentStatusNoticeKind) {}
    \#(liveCamRestore)
}
/// 测试用的「准备中」闸门：靠状态观测而不是 sleep 的时间差，避免 harness 偶发。
@MainActor final class DropPreparationGate {
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { pending = $0 } }
    func open() { pending?.resume(); pending = nil }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ text: String) { count += 1; if !condition { failures += 1; print("FAIL: \(text)") } }
        let state = StageResidentChatState()
        check(await state.takeMessage() == nil && !state.isThinking, "blank message is not submitted")
        state.draft = "  去点唱机放首歌  \n"
        check(await state.takeMessage()?.text == "去点唱机放首歌" && state.draft.isEmpty && state.isThinking, "submit trims message and starts waiting")
        state.draft = "下一条"
        check(await state.takeMessage()?.text == "下一条" && state.draft.isEmpty && state.isThinking, "human guidance can be submitted while the loop is thinking")
        state.finish("正在播放")
        check(state.reply == "正在播放" && !state.isThinking, "reply exits waiting")
        state.draft = "接着说"
        check(await state.takeMessage()?.text == "接着说", "new message works after reply")
        await state.images.add(imageData: AttachmentFixture.png())
        let attachment = state.images.attachments[0]
        let imageMessage = await state.takeMessage()!
        check(imageMessage.text.isEmpty && imageMessage.attachments == [attachment], "image-only messages can be sent")
        state.restore(imageMessage, error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "此后端暂不支持图片"]))
        try await AttachmentFixture.wait { state.images.attachments == [attachment] && !state.isThinking }
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
        let controllerFailure = try await AttachmentFixture.issued(controller.residentChat.images, text: "失败消息", date: Date())
        controller.restoreResidentSubmission(controllerFailure, notice: "后端连接中断")
        try await AttachmentFixture.wait { controller.residentChat.draft == "失败消息\n后续草稿" }
        check(controller.residentChat.draft == "失败消息\n后续草稿" && controller.residentChat.images.attachments == controllerFailure.attachments, "late delivery failure restores original image and text without losing a newer draft")
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
        for order in [[0, 1], [1, 0]] {
            let stage = StageResidentChatState()
            let cam = LiveCamRecovery()
            let stageA = try await AttachmentFixture.issued(stage.images, text: "A", date: Date(timeIntervalSince1970: 1))
            let stageB = try await AttachmentFixture.issued(stage.images, text: "B", date: Date(timeIntervalSince1970: 2))
            let camA = try await AttachmentFixture.issued(cam.images, text: "A", date: Date(timeIntervalSince1970: 1))
            let camB = try await AttachmentFixture.issued(cam.images, text: "B", date: Date(timeIntervalSince1970: 2))
            stage.draft = "新草稿"
            cam.messageField.stringValue = "新草稿"
            for index in order {
                stage.restore([stageA, stageB][index], notice: "失败")
                cam.restoreSubmission([camA, camB][index])
            }
            try await AttachmentFixture.wait { stage.draft == "A\nB\n新草稿" && cam.messageField.stringValue == "A\nB\n新草稿" }
            check(stage.draft == "A\nB\n新草稿" && stage.images.attachments == stageA.attachments + stageB.attachments, "consecutive stage failure recovery keeps original text and image order")
            check(cam.messageField.stringValue == "A\nB\n新草稿" && cam.images.attachments == camA.attachments + camB.attachments, "consecutive Live Cam failure recovery keeps original text and image order")
            stage.restore(stageA, notice: "重复通知")
            cam.restoreSubmission(camA)
            try await AttachmentFixture.wait { !stage.images.isPreparing && !cam.images.isPreparing }
            check(stage.draft == "A\nB\n新草稿" && cam.messageField.stringValue == stage.draft, "repeated failure receipt does not duplicate recovered text")
        }
        let edited = StageResidentChatState()
        let failureA = try await AttachmentFixture.issued(edited.images, text: "A", date: Date(timeIntervalSince1970: 1))
        let failureB = try await AttachmentFixture.issued(edited.images, text: "B", date: Date(timeIntervalSince1970: 2))
        edited.restore(failureA, notice: "失败")
        try await AttachmentFixture.wait { edited.draft == "A" }
        edited.draft = "A 已修改\n我的新想法"
        edited.restore(failureB, notice: "失败")
        try await AttachmentFixture.wait { edited.draft.hasSuffix("B") }
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
        // ── 居民头顶的思考/说话气泡（世界锚定，主交付） ──────────────────────────
        // 需求原话："在它头顶"、"搞一个 ☁️ 之类的"。所以这组断言守三件事：
        //   1. 状态 → 符号（含叠加规则与空闲态）；
        //   2. 位置 = **角色头顶的世界投影**，不是固定屏幕位置，且角色/相机一动就跟着动；
        //   3. 空闲态整朵（云 + 指向点）不画。
        check(ResidentStatusBadge.symbol(isThinking: true, isSpeaking: false)
                == ResidentStatusBadge.thinkingSymbol,
              "思考中必须出现思考符号")
        check(ResidentStatusBadge.symbol(isThinking: false, isSpeaking: true)
                == ResidentStatusBadge.speakingSymbol,
              "说话中必须出现说话符号")
        check(ResidentStatusBadge.symbol(isThinking: true, isSpeaking: true)
                == ResidentStatusBadge.speakingSymbol,
              "叠加规则明确：说话优先于思考（同时为真时取说话符号）")
        check(ResidentStatusBadge.symbol(isThinking: false, isSpeaking: false) == nil,
              "空闲态没有符号")
        check(!ResidentStatusBadge.isVisible(isThinking: false, isSpeaking: false),
              "空闲态不画头顶气泡")
        for text in [ResidentStatusBadge.idleLabel, ResidentStatusBadge.listeningText] {
            check(!text.contains(ResidentStatusBadge.thinkingSymbol)
                    && !text.contains(ResidentStatusBadge.speakingSymbol),
                  "空闲/听音文案里不许留孤立 emoji（\"\(text)\"）")
        }
        // 文字行三处同源：符号一律从 `ResidentStatusBadge` 来，不在这里另拼字面量。
        check(ResidentStatusBadge.statusLine(
                isThinking: true, isSpeaking: false, isListening: false,
                progress: "正在查询歌单…")
                == ResidentStatusBadge.thinkingSymbol + " 正在查询歌单…",
              "思考行的符号 + 真实进度文案（进度口径不变）")
        check(ResidentStatusBadge.statusLine(
                isThinking: false, isSpeaking: true, isListening: false, progress: "x")
                == ResidentStatusBadge.speakingSymbol + " " + ResidentStatusBadge.speakingText,
              "说话行的符号来自同一个来源")
        check(ResidentStatusBadge.statusLine(
                isThinking: false, isSpeaking: false, isListening: true, progress: "x")
                == ResidentStatusBadge.listeningSymbol + " " + ResidentStatusBadge.listeningText,
              "听音行的符号来自同一个来源")
        check(ResidentStatusBadge.statusLine(
                isThinking: false, isSpeaking: false, isListening: false, progress: "x")
                == ResidentStatusBadge.idleLabel,
              "空闲行与改动前逐字一致（不加符号）")
        check(ResidentStatusBadge.decorate("工具请求已返回，等待居民回应…",
                                          isThinking: true, isSpeaking: false)
                == ResidentStatusBadge.thinkingSymbol + " 工具请求已返回，等待居民回应…",
              "Live Cam 面板的进度行用的是同一个投影函数")

        // 头顶锚点：本地头顶高度经**角色绑定矩阵**变成世界点。
        // 矩阵形状与 `MarblePMXFraming.modelTransform` 一致（平移 × 绕 Y × 均匀缩放）。
        let badgeScale: Float = 0.82
        func badgePlacementTransform(_ position: SIMD3<Float>, yaw: Float = 0) -> simd_float4x4 {
            let cosine = cos(yaw), sine = sin(yaw)
            return simd_float4x4(columns: (
                SIMD4(badgeScale * cosine, 0, -badgeScale * sine, 0),
                SIMD4(0, badgeScale, 0, 0),
                SIMD4(badgeScale * sine, 0, badgeScale * cosine, 0),
                SIMD4(position.x, position.y, position.z, 1)
            ))
        }
        let standingHead = ResidentStatusBadge.headTopWorldPoint(
            modelTransform: badgePlacementTransform(SIMD3(-0.72, 0, -0.58)))
        let walkedHead = ResidentStatusBadge.headTopWorldPoint(
            modelTransform: badgePlacementTransform(SIMD3(0.40, 0, -1.20)))
        check(abs(standingHead.y - badgeScale * ResidentStatusBadge.headLocalTopY) < 0.0001,
              "头顶世界点 = 角色地面高度 + 缩放 × 本地头顶高度")
        check(abs(standingHead.x + 0.72) < 0.0001 && abs(standingHead.z + 0.58) < 0.0001,
              "头顶世界点在水平面上与角色位置重合（正上方，不是固定屏幕位置）")
        check(simd_distance(standingHead, walkedHead) > 0.5,
              "角色走动后头顶世界点随之变化")

        // 与 `MarbleSpatialView` 同一套投影：perspective(fov 66°) × rotationX(-pitch) ×
        // rotationY(-yaw) × translation(-camera.position)。
        let badgeViewSize = CGSize(width: 1440, height: 900)
        func badgeViewProjection(cameraYaw: Float, cameraDistance: Float = 1.8) -> simd_float4x4 {
            let fov: Float = 66 * .pi / 180
            let aspect = Float(badgeViewSize.width / badgeViewSize.height)
            let y = 1 / tan(fov * 0.5), x = y / aspect
            let near: Float = 0.05, far: Float = 250, z = far / (near - far)
            let projection = simd_float4x4(columns: (
                SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)
            ))
            let pitch: Float = -12 * .pi / 180
            let cosine = cos(pitch), sine = sin(pitch)
            let rotation = simd_float4x4(columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, cosine, -sine, 0),
                SIMD4(0, sine, cosine, 0), SIMD4(0, 0, 0, 1)
            ))
            let yawCos = cos(cameraYaw), yawSin = sin(cameraYaw)
            let yawRotation = simd_float4x4(columns: (
                SIMD4(yawCos, 0, -yawSin, 0), SIMD4(0, 1, 0, 0),
                SIMD4(yawSin, 0, yawCos, 0), SIMD4(0, 0, 0, 1)
            ))
            let camera = SIMD3<Float>(0, 1.2, cameraDistance)
            let translation = simd_float4x4(columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                SIMD4(0, 0, 1, 0), SIMD4(-camera.x, -camera.y, -camera.z, 1)
            ))
            return projection * rotation * yawRotation * translation
        }
        /// 与 `SpatialStageStore.residentPropScreenPoint` 逐字同形（归一化、左上原点）。
        func badgeNormalizedPoint(_ world: SIMD3<Float>, _ viewProjection: simd_float4x4) -> CGPoint {
            let clip = viewProjection * SIMD4(world, 1)
            guard clip.w > 0.000001 else { return CGPoint(x: -1, y: -1) }
            return CGPoint(
                x: CGFloat((clip.x / clip.w + 1) / 2),
                y: CGFloat((1 - clip.y / clip.w) / 2)
            )
        }
        /// 头顶 + 脚下的屏幕位置（两次既有投影），以及由此得到的**角色屏高**。
        func badgeScreen(
            head: SIMD3<Float>, foot: SIMD3<Float>,
            cameraYaw: Float, cameraDistance: Float = 1.8
        ) -> (head: CGPoint, foot: CGPoint, characterScreenHeight: CGFloat) {
            let viewProjection = badgeViewProjection(
                cameraYaw: cameraYaw, cameraDistance: cameraDistance)
            let headPoint = ResidentStatusBadge.viewPoint(
                projectedNormalized: badgeNormalizedPoint(head, viewProjection),
                viewSize: badgeViewSize)
            let footPoint = ResidentStatusBadge.viewPoint(
                projectedNormalized: badgeNormalizedPoint(foot, viewProjection),
                viewSize: badgeViewSize)
            return (headPoint, footPoint, abs(footPoint.y - headPoint.y))
        }
        func badgeAnchor(
            head: SIMD3<Float>, foot: SIMD3<Float>,
            cameraYaw: Float, cameraDistance: Float = 1.8
        ) -> CGPoint? {
            let screen = badgeScreen(
                head: head, foot: foot,
                cameraYaw: cameraYaw, cameraDistance: cameraDistance)
            return ResidentStatusBadge.anchor(
                projectedHead: screen.head,
                characterScreenHeight: screen.characterScreenHeight,
                viewSize: badgeViewSize
            )
        }
        let standingFoot = SIMD3<Float>(-0.72, 0, -0.58)
        let standingScreen = badgeScreen(
            head: standingHead, foot: standingFoot, cameraYaw: 0)
        let headPoint = standingScreen.head
        check(standingScreen.characterScreenHeight > 100,
              "站立角色在屏幕上有可测量的身高（间隙的缩放基数是真的，不是 0）")
        guard let anchor = badgeAnchor(head: standingHead, foot: standingFoot, cameraYaw: 0) else {
            check(false, "站立角色的头顶投影应当落在视图内，气泡才画得出来")
            print("\(failures == 0 ? "PASS" : "FAIL"): \(count) stage resident chat checks, \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        check(abs(anchor.x - headPoint.x) < 0.0001,
              "云朵水平居中于头顶投影（指向点正对头顶）")
        check(anchor.y < headPoint.y,
              "云朵在头顶**上方**（左上原点下，y 比头顶小）")
        // 真机反馈："要用白色底，离头要有一点距离才行，现在小云朵卡在头部了"。
        // 所以这里断的不是"云在上面一点点"，而是"云体整体在头顶之上 + 与头留够净空"。
        let standingGap = ResidentStatusBadge.headGap(
            characterScreenHeight: standingScreen.characterScreenHeight)
        check(abs((headPoint.y - anchor.y)
                    - (standingGap + ResidentStatusBadge.tailSpan
                        + ResidentStatusBadge.cloudSize.height / 2)) < 0.0001,
              "云朵中心 = 头顶 − 净空 − 指向点跨度 − 半个云高（**不是以头顶为中心**）")
        let cloud = ResidentStatusBadge.cloudRect(anchor: anchor)
        check(cloud.maxY < headPoint.y,
              "云体整体位于头顶**之上**（底边也在头顶上方）")
        check(cloud.maxY <= headPoint.y
                - (standingGap + ResidentStatusBadge.tailSpan) + 0.0001,
              "云体底边与头顶之间隔着『净空 + 指向点跨度』（不是擦着头发）")
        check(cloud.maxY <= headPoint.y - ResidentStatusBadge.minimumHeadGap,
              "云体底边与头顶的净空不少于 minimumHeadGap（\(ResidentStatusBadge.minimumHeadGap) pt）")
        // 浮动到最低点也仍然满足：云体不压头、净空不被浮动吃掉。
        let lowestCloud = ResidentStatusBadge.cloudRect(
            anchor: anchor, bob: ResidentStatusBadge.bobAmplitude)
        check(lowestCloud.maxY < headPoint.y - ResidentStatusBadge.minimumHeadGap,
              "浮动到最低点，云体底边仍在头顶之上并留够最小净空")
        // 相机一动（拖动/缩放）⇒ 同一个世界头顶点投影到不同屏幕点 ⇒ 气泡跟着动。
        let yawedHeadPoint = badgeScreen(
            head: standingHead, foot: standingFoot, cameraYaw: 0.35).head
        check(hypot(yawedHeadPoint.x - headPoint.x, yawedHeadPoint.y - headPoint.y) > 1,
              "相机一转，头顶投影点就变（气泡不会停在原地滞后一拍）")
        // 角色走动 ⇒ 气泡跟着动。
        if let walkedAnchor = badgeAnchor(
            head: walkedHead, foot: SIMD3(0.40, 0, -1.20), cameraYaw: 0) {
            check(hypot(walkedAnchor.x - anchor.x, walkedAnchor.y - anchor.y) > 1,
                  "角色走动后气泡位置随之变化（锚在角色头顶，不是固定屏幕位置）")
        } else {
            check(false, "走动后的头顶投影应当仍落在视图内")
        }
        // 指向点：由大到小、正对头顶、从云体下垂向头顶，且最后一个点与头顶仍有间隙。
        let dots = ResidentStatusBadge.tailDots(anchor: anchor)
        check(dots.count == 3, "云下面有三个指向圆点（漫画式想法标记）")
        check(dots[0].radius > dots[1].radius && dots[1].radius > dots[2].radius,
              "指向圆点由大到小")
        check(dots.allSatisfy { abs($0.center.x - anchor.x) < 0.0001 },
              "指向圆点全部正对头顶（x 与头顶投影相同）")
        check(dots[2].center.y > dots[0].center.y,
              "最小的点在最下面、离头顶最近")
        check(dots[0].center.y > cloud.maxY,
              "指向圆点都在云底之下（不压在云上）")
        check(dots[2].center.y < headPoint.y,
              "最后一个指向点在头顶之上（从云体下垂向头顶，不是戳进头里）")
        check(headPoint.y - (dots[2].center.y + dots[2].radius)
                >= ResidentStatusBadge.minimumHeadGap,
              "最下面那个指向点的下边缘与头顶至少留 minimumHeadGap（\(ResidentStatusBadge.minimumHeadGap) pt）")
        // 相机拉近/拉远：间隙按角色屏高缩放，但夹在上下限内。
        let nearScreen = badgeScreen(
            head: standingHead, foot: standingFoot, cameraYaw: 0, cameraDistance: 0.8)
        let farScreen = badgeScreen(
            head: standingHead, foot: standingFoot, cameraYaw: 0, cameraDistance: 7.0)
        check(nearScreen.characterScreenHeight > standingScreen.characterScreenHeight
                && farScreen.characterScreenHeight < standingScreen.characterScreenHeight,
              "相机拉近角色屏高变大、拉远变小（间隙的缩放基数确实跟着相机走）")
        check(ResidentStatusBadge.headGap(characterScreenHeight: farScreen.characterScreenHeight)
                >= ResidentStatusBadge.minimumHeadGap,
              "拉远时间隙不小于 minimumHeadGap（云不会贴着头）")
        check(ResidentStatusBadge.headGap(characterScreenHeight: nearScreen.characterScreenHeight)
                <= ResidentStatusBadge.maximumHeadGap,
              "拉近时间隙不超过 maximumHeadGap（云不会被推到看不见）")
        check(ResidentStatusBadge.headGap(characterScreenHeight: 100_000)
                == ResidentStatusBadge.maximumHeadGap,
              "屏高极大时夹在上限（近景不会把云推飞）")
        check(ResidentStatusBadge.headGap(characterScreenHeight: 0)
                == ResidentStatusBadge.minimumHeadGap
                && ResidentStatusBadge.headGap(characterScreenHeight: .nan)
                    == ResidentStatusBadge.minimumHeadGap,
              "拿不到屏高（0 / NaN）时退回最小值，仍不压头")
        // 中段（没被上下限夹住）必须真的**按比例**放大 —— 否则"随屏高缩放"只是一句注释。
        let midGap = 190 * ResidentStatusBadge.headGapRatio
        check(midGap > ResidentStatusBadge.minimumHeadGap
                && midGap < ResidentStatusBadge.maximumHeadGap,
              "测试用的中段屏高确实落在上下限之间（断言本身有效）")
        check(abs(ResidentStatusBadge.headGap(characterScreenHeight: 190) - midGap) < 0.0001,
              "中段间隙 = 角色屏高 × headGapRatio（真的按屏高缩放，不是常量）")
        check(ResidentStatusBadge.headGap(characterScreenHeight: 190)
                > ResidentStatusBadge.headGap(characterScreenHeight: 140),
              "角色在屏幕上越大，间隙越大（单调，近景不压头）")
        // 近景是"卡在头部"最容易复发的场景：这里必须单独守一遍。
        if let nearAnchor = badgeAnchor(
            head: standingHead, foot: standingFoot, cameraYaw: 0, cameraDistance: 0.8) {
            let nearCloud = ResidentStatusBadge.cloudRect(anchor: nearAnchor)
            check(nearCloud.maxY < nearScreen.head.y - ResidentStatusBadge.minimumHeadGap,
                  "近景（头在屏幕上很大）时云体底边与头顶仍有最小净空")
        } else {
            check(false, "近景的头顶投影应当落在视图内")
        }
        // 空闲态 / 头顶投影跑到视图外：整朵不画（也不夹到屏幕边上指向空处）。
        check(ResidentStatusBadge.anchor(
                projectedHead: CGPoint(x: -5, y: 300),
                characterScreenHeight: 300,
                viewSize: badgeViewSize) == nil,
              "头顶投影落到视图外时不画（世界锚定的提示不做夹边）")
        check(ResidentStatusBadge.anchor(
                projectedHead: CGPoint(x: 700, y: 4),
                characterScreenHeight: 300,
                viewSize: badgeViewSize) == nil,
              "画面顶端塞不下整朵云时不画（不会挂半个云出去）")
        // 尺寸恒定：链路上没有任何随距离缩放的量。
        check(ResidentStatusBadge.cloudSize == CGSize(width: 50, height: 36),
              "气泡尺寸是固定屏幕 pt（相机拉远不会缩到看不见）")
        // 配色：白色主体 + 深色符号，云体与指向圆点同一套（RGB 只有一份）。
        check(ResidentStatusBadge.cloudFill.luminance > 0.9
                && ResidentStatusBadge.cloudFill.alpha > 0.9,
              "云体用白色（近白、不透明）填充 —— 真机反馈'要用白色底'")
        check(ResidentStatusBadge.symbolInk.luminance < 0.25,
              "符号墨色是深色（压在白色主体上）")
        check(ResidentStatusBadge.cloudOutline.luminance < 0.4
                && ResidentStatusBadge.cloudOutline.alpha < 0.9,
              "描边是深色细线（亮背景也能分辨，暗背景上不抢戏）")
        check(ResidentStatusBadge.tailDotFill == ResidentStatusBadge.cloudFill
                && ResidentStatusBadge.tailDotOutline == ResidentStatusBadge.cloudOutline,
              "指向圆点与云体**同一套配色**（不另写一份 RGB）")
        check(ResidentStatusBadge.cloudFill != ResidentStatusBadge.symbolInk
                && ResidentStatusBadge.cloudFill.luminance
                    - ResidentStatusBadge.symbolInk.luminance > 0.6,
              "底与符号的亮度差足够大（白底 + 深符号，对比度不是擦边）")
        // 动感：纯时间函数、有界、不累积（不会每帧重排导致抖动）。
        check(abs(ResidentStatusBadge.bobOffset(seconds: 0)) < 0.0001,
              "浮动在 t = 0 时归零（纯时间函数，无累积漂移）")
        check(abs(ResidentStatusBadge.bobOffset(seconds: ResidentStatusBadge.bobPeriod * 3 / 4)
                    + ResidentStatusBadge.bobAmplitude) < 0.0001,
              "浮动在四分之三个周期到达最低点（幅度 = bobAmplitude）")
        check(abs(ResidentStatusBadge.bobOffset(seconds: 12.34))
                <= ResidentStatusBadge.bobAmplitude + 0.0001,
              "浮动幅度有界（克制，不做夸张弹跳）")
        check(abs(ResidentStatusBadge.breathScale(seconds: 0) - 1) < 0.0001
                && abs(ResidentStatusBadge.breathScale(
                    seconds: ResidentStatusBadge.breathPeriod / 4)
                    - (1 + ResidentStatusBadge.breathAmplitude)) < 0.0001,
              "思考时符号呼吸：幅度 = breathAmplitude，周期 = breathPeriod")
        // 云朵几何：四块都在云框内，中间那瓣最高。
        let cloudRect = CGRect(origin: .zero, size: ResidentStatusBadge.cloudSize)
        let blobs = ResidentStatusBadge.cloudBlobs(in: cloudRect)
        check(blobs.count == 4, "云朵由底面 + 三个圆瓣拼成")
        check(blobs.allSatisfy { cloudRect.insetBy(dx: -0.001, dy: -0.001).contains($0.rect) },
              "云瓣都画在云框内（不会溢出到 rect 之外）")
        check(blobs[2].rect.minY < blobs[1].rect.minY && blobs[2].rect.minY < blobs[3].rect.minY,
              "中间那瓣最高（圆润的云形，不是一个方块）")
        // 三瓣必须**真的鼓出来**。只查"在框内 + 中间最高"是不够的：把三瓣半径缩到 0.05×云高，
        // 云就退化成一块圆角矩形加几个小点，那两条照样通过（实测注入 J2 抓不住）。
        let baseTop = cloudRect.maxY - 0.58 * cloudRect.height
        for (index, lobe) in blobs.dropFirst().enumerated() {
            check(lobe.rect.height / 2 > 0.15 * cloudRect.height,
                  "第 \(index + 1) 个圆瓣的半径要够大（> 15% 云高），不然云会退化成圆角矩形")
        }
        check(baseTop - blobs[2].rect.minY > 0.25 * cloudRect.height,
              "最大的那瓣要切实鼓出底面上沿（云朵的辨识度来自这几个圆弧）")
        // 头顶本地高度必须与生产绑定矩阵里的 normalizedHeight 一致。
        check(abs(ResidentStatusBadge.headLocalTopY - Float(\#(marblenormalizedHeight))) < 0.0001,
              "头顶高度与 MarblePMXFraming.normalizedHeight 一致（\#(marblenormalizedHeight) m）")
        // ── 拖拽接收图片（访达拖进来）─────────────────────────────────────────
        // 判据跑的是**生产那一份** `ResidentImageDropPolicy` / `ResidentAttachmentStore`，
        // 不是 harness 里抄的一份副本。
        //
        // 断言 1：拖入图片文件 ⇒ 会被接下去（交给与「＋ 选择文件」同一条 add(urls:)）。
        let droppedImage = URL(fileURLWithPath: "/tmp/猫.png")
        let droppedText = URL(fileURLWithPath: "/tmp/notes.txt")
        check(ResidentImageFilePolicy.isImageFileURL(droppedImage)
                && !ResidentImageFilePolicy.isImageFileURL(droppedText),
              "图片文件的判据与 store 共用同一份（.png 是、.txt 不是）")
        check(ResidentImageDropPolicy.payload(fileURLs: [droppedImage], hasBitmap: false)
                == .fileURLs([droppedImage]),
              "拖进来的图片文件会被接下去")
        // 混合拖拽：一次把这一笔里的所有文件 URL 都交出去，由 store 逐个校验。
        check(ResidentImageDropPolicy.payload(fileURLs: [droppedImage, droppedText], hasBitmap: false)
                == .fileURLs([droppedImage, droppedText]),
              "混合拖拽把所有文件 URL 都交给 store（非图片那个由 store 给出可见原因，不静默）")
        // 断言 2：拖入非图片 ⇒ 不亮起、不接入。
        check(ResidentImageDropPolicy.payload(fileURLs: [droppedText], hasBitmap: false) == .unsupported,
              "拖入非图片文件不会被接入（也不会有假成功）")
        check(ResidentImageDropPolicy.payload(fileURLs: [], hasBitmap: false) == .unsupported,
              "纯文本拖动不会被接入")
        check(ResidentImageDropPolicy.payload(fileURLs: [], hasBitmap: true) == .bitmap,
              "直接拖进来的位图走位图那条路（与 ⌘V 同一条 add(imageData:)）")
        check(!ResidentImageDropPolicy.payload(fileURLs: [droppedText], hasBitmap: false).isAccepted,
              "非图片拖拽的判据是「不接受」⇒ 落点不会亮起")
        // 断言 4：拖拽不许抢走场景鼠标交互。
        check(ResidentImageDropPolicy.allowsHitTesting(eventType: .leftMouseDragged, localMouseIsDown: false),
              "别的 app 拖着东西经过时落点才参与命中")
        check(!ResidentImageDropPolicy.allowsHitTesting(eventType: .leftMouseDragged, localMouseIsDown: true),
              "本 app 自己按着鼠标的拖动（相机旋转/装修拖动）绝不能被落点截住")
        for event in [AppKit.NSEvent.EventType.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .keyDown, .cursorUpdate] {
            check(!ResidentImageDropPolicy.allowsHitTesting(eventType: event, localMouseIsDown: false),
                  "本地点选/悬停/滚动/按键时落点完全不存在（\(event.rawValue)）")
        }
        check(!ResidentImageDropPolicy.allowsHitTesting(eventType: nil, localMouseIsDown: false),
              "没有当前事件时落点完全不存在")
        // 断言 3（+ 断言 1/2 的落点行为）：真的走 store 那一份校验/上限/可见拒绝。
        let dropDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            .appendingPathComponent("gmgn-drop-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dropDirectory) }
        func droppedFile(_ name: String) -> URL {
            let url = dropDirectory.appendingPathComponent(name)
            try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: url)
            return url
        }
        let preparedPNG = AttachmentFixture.png()
        let attachmentRPC = try PrivateRPC(CommandLine.arguments[1])
        let attachmentAuthority = RustChatAttachmentClient(call: { [attachmentRPC] method, data in try attachmentRPC.call(method, data) })
        let cappedStore = ResidentAttachmentStore(
            directory: dropDirectory.appendingPathComponent("capped", isDirectory: true), authority: attachmentAuthority
        ) { _ in preparedPNG }
        await cappedStore.add(urls: (1...6).map { droppedFile("图\($0).png") })
        check(cappedStore.attachments.count == 4,
              "超过 4 张时只接入 4 张（上限仍在 store 那一份逻辑里）")
        check(cappedStore.errorMessage != nil,
              "超过 4 张必须给出可见拒绝，而不是静默丢弃")
        let mixedStore = ResidentAttachmentStore(
            directory: dropDirectory.appendingPathComponent("mixed", isDirectory: true), authority: attachmentAuthority
        ) { _ in preparedPNG }
        await mixedStore.add(urls: [droppedFile("好图.png"), droppedFile("笔记.txt")])
        check(mixedStore.attachments.count == 1 && mixedStore.attachments.first?.displayName == "好图.png",
              "混合拖拽里只有图片被接入")
        check(mixedStore.errorMessage != nil,
              "混合拖拽里的非图片文件必须给出可见原因（不静默丢弃）")
        // 上一批还在准备时的第二次接入（＋/⌘V/拖拽都走 add(urls:)）同样不许静默丢弃。
        let gate = DropPreparationGate()
        let slowStore = ResidentAttachmentStore(
            directory: dropDirectory.appendingPathComponent("slow", isDirectory: true), authority: attachmentAuthority
        ) { _ in
            await gate.wait()
            return preparedPNG
        }
        let slowTask = Task { await slowStore.add(urls: [droppedFile("慢图.png")]) }
        var spins = 0
        while !slowStore.isPreparing, spins < 10_000 { spins += 1; await Task.yield() }
        check(slowStore.isPreparing, "第一笔确实已经进入准备中（这条断言本身有效）")
        await slowStore.add(urls: [droppedFile("第二张.png")])
        gate.open()
        await slowTask.value
        check(slowStore.attachments.count == 1 && slowStore.errorMessage != nil,
              "上一批还在准备时的第二次接入必须给出可见原因，而不是静默丢弃")
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
    + noticeTypes + "\n" + privateAttachmentGlue + "\n@MainActor\n"
    + declaration("struct ResidentSpeechErrorNotice:", in: overlay) + "\n@MainActor\n"
    + declaration("struct WishMachineTaskStatusView:", in: overlay) + "\n@MainActor\n"
    + state + "\n@MainActor\n"
    + declaration("struct StageResidentComposer:", in: overlay) + "\n@MainActor\n"
    + declaration("private final class StageResidentChatButton:", in: controller)
try ui.write(to: uiSource, atomically: true, encoding: .utf8)
// `ResidentStatusBadge.swift` 一并编进来：下面那些断言跑的是**生产那一份**状态→符号
// 投影与气泡几何，不是 harness 里抄的一份副本。
let attachmentSources = ["VisualEngine/ResidentStatusBadge.swift", "Presence/ResidentImageAttachment.swift", "Presence/RustChatAttachmentClient.swift", "Presence/RustProductSettingsClient.swift", "Presence/TaskdHTTPTransport.swift", "Presence/PropImagePreparation.swift", "Presence/PropGenerationClient.swift", "Presence/WishMachineTaskPresentation.swift", "Presence/ResidentOwnershipProjection.swift"].map { sources.appendingPathComponent($0).path } + [root.appendingPathComponent("tools/fixtures/PrivateAttachmentAuthority.swift").path]
// `-disable-sandbox`：Swift 编译器默认用 `sandbox-exec` 隔离宏插件进程，而受限环境下
// 嵌套 sandbox 会被拒（`sandbox_apply: Operation not permitted`），`@Observable` 于是
// 编不过。与 `tools/test-agent-speech-playback.swift` / `test-agent-speech-completion.swift`
// 同一手法 —— 只关编译器自己的插件沙箱，产物与判据一字不变。
let checked = try run("/usr/bin/swiftc", ["-disable-sandbox", "-j1", "-typecheck", "-target", "arm64-apple-macos14.0", uiSource.path] + attachmentSources)
guard checked == 0 else { exit(checked) }
let compiled = try run("/usr/bin/swiftc", ["-disable-sandbox", "-j1", "-parse-as-library", source.path, "-o", executable.path] + attachmentSources)
guard compiled == 0 else { exit(compiled) }
if CommandLine.arguments.contains("--compile-only") { print("PASS: stage resident chat actual async attachment consumers compiled"); exit(0) }
guard CommandLine.arguments.count == 3 else { fatalError("Provide private endpoint and private root, or --compile-only") }
exit(try run(executable.path, Array(CommandLine.arguments.dropFirst())))
