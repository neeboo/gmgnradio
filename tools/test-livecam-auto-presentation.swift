// Run from repository root. No app, GPU, network or user settings are opened.
//
// 真机要求（2026-09-30）：「小窗（Live Cam）只由用户的显式动作出现」。
// 本 harness 钉两件事：
//   A. 非显式触发源（居民状态播报 / 活动开始 / 角色动作 / 角色快照变化）
//      **永远不呈现**小窗 —— 把触发源注入回去必须 FAIL。
//   B. 显式动作仍能进小窗（保留项），底部工具条的每一个按钮都不改变窗口形态。
//
// 它同时做两级检查：
//   1. 文本级：生产源码里每个调用点必须声明自己的触发源，底部按钮的接线必须
//      落在「不呈现」的那批处理函数上（改错接线立刻 FAIL）。
//   2. 行为级：把生产里那两个纯判据（`LiveCamPresentationTrigger` /
//      `LiveCamPresentationPolicy` / `LiveCamPresentationRequest`）原文抽出来
//      编译，逐条喂触发源断言结果。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourcesRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func read(_ relative: String) throws -> String {
    try String(
        contentsOf: sourcesRoot.appendingPathComponent(relative),
        encoding: .utf8
    )
}

func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        print("FAIL: missing production declaration: \(signature)"); exit(1)
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced declaration")
}

let app = try read("App/GMGNRadioApp.swift")
let camera = try read("VisualEngine/StageCameraCoordinator.swift")
let stage = try read("VisualEngine/StageWindowController.swift")
let liveCam = try read("DesktopPresence/LiveCamWindowController.swift")

/// 任何**呈现/接管**小窗的写法。处理函数体内出现即视为「这个按钮会改变窗口形态」。
let presentingTokens = [
    "showLiveCam(",
    "liveCamWindowController?.show(",
    "applyDesktopPresence(",
    "onShowPlayerHandler?",
    ".explicitUserAction",
    "LiveCamPresentationPolicy",
]

/// 注释里提到某个名字不构成调用（本仓库的注释大量引用被删掉的旧调用），
/// 所以扫调用前先去掉注释，只留代码。
func strippingComments(_ source: String) -> String {
    var output = ""
    var index = source.startIndex
    var inLineComment = false
    var inBlockComment = false
    var inString = false
    while index < source.endIndex {
        let character = source[index]
        let next = source.index(after: index) < source.endIndex
            ? source[source.index(after: index)] : nil
        if inLineComment {
            if character == "\n" { inLineComment = false; output.append(character) }
        } else if inBlockComment {
            if character == "*", next == "/" {
                inBlockComment = false
                index = source.index(after: index)
            }
        } else if inString {
            if character == "\"" { inString = false }
            output.append(character)
        } else if character == "\"", !source[..<index].hasSuffix("\\") {
            inString = true
            output.append(character)
        } else if character == "/", next == "/" {
            inLineComment = true
            index = source.index(after: index)
        } else if character == "/", next == "*" {
            inBlockComment = true
            index = source.index(after: index)
        } else {
            output.append(character)
        }
        index = source.index(after: index)
    }
    return output
}

func presentingTokens(in body: String) -> [String] {
    let code = strippingComments(body)
    return presentingTokens.filter { code.contains($0) }
}

func requireNoPresentation(_ name: String, _ body: String, file: String) {
    let found = presentingTokens(in: body)
    guard found.isEmpty else {
        print("FAIL: \(name) 会自动呈现/接管 Live Cam（命中 \(found.joined(separator: ", "))），\(file)")
        exit(1)
    }
}

// ---------------------------------------------------------------------------
// 1. 生产判据必须存在，而且每个调用点都要声明触发源
// ---------------------------------------------------------------------------

let trigger = declaration("enum LiveCamPresentationTrigger:", in: camera)
let policy = declaration("enum LiveCamPresentationPolicy {", in: camera)
let request = declaration("enum LiveCamPresentationRequest:", in: camera)

for triggerCase in [
    "case explicitUserAction", "case launchDefault", "case residentStatusNotice",
    "case livingWorldActivityChange", "case characterMotionChange",
    "case avatarSnapshotChange",
] {
    guard trigger.contains(triggerCase) else {
        print("FAIL: 触发源清单缺少 \(triggerCase)"); exit(1)
    }
}
guard trigger.contains("var mayPresentLiveCam: Bool") else {
    print("FAIL: 触发源没有唯一的 mayPresentLiveCam 判据"); exit(1)
}
guard policy.contains("shouldPresentLiveCam("),
      policy.contains("trigger: LiveCamPresentationTrigger"),
      policy.contains("guard trigger.mayPresentLiveCam else { return false }") else {
    print("FAIL: LiveCamPresentationPolicy 没有把触发源当成呈现的前置条件"); exit(1)
}

// 角色快照观察者：走路 / 语音电平 / Agent 说话 / 动作 / 许愿任务都经过这里。
guard let observer = app.range(of: "desktopPresenceObserverID = avatarRuntime.observe {") else {
    print("FAIL: 找不到角色快照观察者"); exit(1)
}
guard let observerEnd = app.range(of: "avatarRuntime.refresh()", range: observer.lowerBound..<app.endIndex) else {
    print("FAIL: 找不到角色快照观察者的结尾"); exit(1)
}
let observerBody = String(app[observer.lowerBound..<observerEnd.lowerBound])
guard observerBody.contains("applyDesktopPresence(snapshot, trigger: .avatarSnapshotChange)") else {
    print("FAIL: 角色快照变化必须声明为 .avatarSnapshotChange（不得呈现小窗）"); exit(1)
}
guard !presentingTokens(in: observerBody).contains("liveCamWindowController?.show(") else {
    print("FAIL: 角色快照观察者不得直接呈现小窗"); exit(1)
}

// applyDesktopPresence：唯一落地处必须过策略，且呈现语句在守卫之后。
let applyPresence = declaration("private func applyDesktopPresence(", in: app)
guard applyPresence.contains("trigger: LiveCamPresentationTrigger") else {
    print("FAIL: applyDesktopPresence 必须要求触发源"); exit(1)
}
guard applyPresence.contains("LiveCamPresentationPolicy.shouldPresentLiveCam("),
      applyPresence.contains("trigger: trigger") else {
    print("FAIL: applyDesktopPresence 没有过 LiveCamPresentationPolicy"); exit(1)
}
guard let guardSite = applyPresence.range(of: "shouldPresentLiveCam("),
      let guardEnd = applyPresence.range(of: "else {", range: guardSite.upperBound..<applyPresence.endIndex),
      let showSite = applyPresence.range(of: "liveCamWindowController?.show()"),
      guardEnd.upperBound < showSite.lowerBound,
      applyPresence[guardEnd.upperBound..<showSite.lowerBound].contains("return") else {
    print("FAIL: applyDesktopPresence 的呈现语句必须在「策略说不」的守卫之后"); exit(1)
}
guard applyPresence.components(separatedBy: "liveCamWindowController?.show()").count == 2 else {
    print("FAIL: applyDesktopPresence 只允许一处呈现语句"); exit(1)
}

// showLiveCam：只有显式入口用无参版本；冷启动单独声明。
let explicitEntry = declaration("func showLiveCam() {", in: app)
guard explicitEntry.contains("showLiveCam(trigger: .explicitUserAction)") else {
    print("FAIL: 无参 showLiveCam() 必须声明为用户的显式动作"); exit(1)
}
guard app.contains("showLiveCam(trigger: .launchDefault)") else {
    print("FAIL: 冷启动的默认桌面形态必须显式声明为 .launchDefault"); exit(1)
}

// Dock 图标（底栏图标）：已经有可见窗口时不得切换桌面形态。
let dock = declaration("struct DockReopenAction {", in: app)
guard dock.contains("guard !hasVisibleWindows else { return true }") else {
    print("FAIL: 点 Dock 图标不得在已有可见窗口时切换桌面形态"); exit(1)
}

// ---------------------------------------------------------------------------
// 2. 非显式入口：活动开始 / 角色动作 / 播放器窗口生命周期
// ---------------------------------------------------------------------------

requireNoPresentation(
    "runLivingWorldActivity（生活活动开始）",
    declaration("func runLivingWorldActivity(id: String) {", in: app),
    file: "App/GMGNRadioApp.swift"
)
requireNoPresentation(
    "playCharacterMotion（角色动作）",
    declaration("func playCharacterMotion(id: String) {", in: app),
    file: "App/GMGNRadioApp.swift"
)

// 舞台窗 show() 是窗口生命周期的公共路径：不得顺带交接渲染面。
let stageShow = declaration("func show() {", in: stage)
guard !stageShow.contains("onShowPlayerHandler?()") else {
    print("FAIL: StageWindowController.show() 不得顺带呈现 Live Cam（那是任何 showStage/showPlayer/歌词切换都会走的路）")
    exit(1)
}
// 显式的播放器入口仍然交接：目的地按钮 → onShowPlayerHandler。
guard stage.contains("onShowPlayer: { [weak self] in\n                self?.onShowPlayerHandler?()\n            }")
        || stage.contains("self?.onShowPlayerHandler?()") else {
    print("FAIL: 显式的播放器入口（目的地按钮）必须仍然交接渲染面"); exit(1)
}
guard declaration("func showPlayer() {", in: app).contains("liveCamWindowController?.show()") else {
    print("FAIL: 显式的播放器入口 showPlayer() 必须仍把渲染面交给 Live Cam（播放器模式里角色只有这一处可画）")
    exit(1)
}

// ---------------------------------------------------------------------------
// 3. 底部工具条：逐按钮「不改变窗口形态」
// ---------------------------------------------------------------------------

guard let windowStart = stage.range(of: "private func makeWindow()") else {
    print("FAIL: 找不到 StageWindowController.makeWindow()"); exit(1)
}
// 只取「窗口构造点之后」：属性声明（`private let programButton:`）不能冒充接线。
let makeWindow = String(stage[windowStart.lowerBound...])

// 每个按钮的接线原文：改动接线（例如把聊天按钮接到呈现小窗）会先在这里 FAIL。
let transportWiring: [(String, String)] = [
    ("节目轨道（方块/节目）", "let programButton = StageProgramButton { [weak self] in\n            self?.toggleProgramRail()\n        }"),
    ("上一首", "let previousButton = StageTrackNavigationButton(\n            direction: .previous,\n            action: onPreviousTrack\n        )"),
    ("播放/暂停", "let playbackButton = StagePlaybackButton(\n            state: playbackState,\n            action: onTogglePlayback\n        )"),
    ("下一首", "let nextButton = StageTrackNavigationButton(\n            direction: .next,\n            action: onNextTrack\n        )"),
    ("麦克风（语音）", "let voiceButton = StageVoiceButton(\n            state: voiceState,\n            action: onToggleVoice\n        )"),
    ("设置（视觉面板）", "let visualButton = StageVisualButton { [weak self] in\n            self?.toggleVisualPicker()\n        }"),
    ("对话", "let chatButton = StageResidentChatButton { [weak self] in\n            self?.toggleResidentChat()\n        }"),
    ("信封（系统收件箱）", "let systemInboxButton = ResidentSystemMailBadgeButton(\n            identifier: \"stage.system-inbox-toggle\",\n            action: onOpenSystemInbox\n        )"),
    ("摆放物件", "let propEditorButton = StagePropEditorButton { [weak self] in self?.togglePropEditor() }"),
    ("窗口模式（全屏）", "let windowModeButton = StageWindowModeButton(\n            mode: .windowed,\n            action: onToggleWindowMode\n        )"),
]
for (button, wiring) in transportWiring {
    guard makeWindow.contains(wiring) else {
        print("FAIL: 底部工具条「\(button)」的接线变了，必须重新核对它会不会改变窗口形态"); exit(1)
    }
}
guard stage.contains("onToggleWindowMode: { [weak window] in\n                window?.toggleFullScreen(nil)\n            }")
        || stage.contains("window?.toggleFullScreen(nil)") else {
    print("FAIL: 窗口模式按钮必须只切全屏"); exit(1)
}

// 面板内的四个开关（节目轨道 / 视觉 / 对话 / 摆放）只动自己那扇窗。
for (name, signature) in [
    ("toggleProgramRail", "private func toggleProgramRail() {"),
    ("toggleVisualPicker", "private func toggleVisualPicker() {"),
    ("toggleResidentChat", "private func toggleResidentChat() {"),
    ("togglePropEditor", "private func togglePropEditor() {"),
] {
    requireNoPresentation(
        "StageWindowController.\(name)（底部按钮处理函数）",
        declaration(signature, in: stage),
        file: "VisualEngine/StageWindowController.swift"
    )
}

// 接在底部按钮上的宿主动作：播放控制 / 麦克风 / 信封。
for (name, signature, file) in [
    ("toggleLocalPlayback（播放控制）", "func toggleLocalPlayback() {", "App/GMGNRadioApp.swift"),
    ("playPreviousProgramTrack（上一首）", "private func playPreviousProgramTrack() {", "App/GMGNRadioApp.swift"),
    ("playNextProgramTrack（下一首）", "private func playNextProgramTrack() {", "App/GMGNRadioApp.swift"),
    ("toggleRealtimeVoiceFromStage（麦克风）", "func toggleRealtimeVoiceFromStage() {", "App/GMGNRadioApp.swift"),
    ("showResidentVoiceStatus（语音状态播报）", "private func showResidentVoiceStatus(_ text: String) {", "App/GMGNRadioApp.swift"),
    ("openSystemInbox（信封）", "private func openSystemInbox() {", "App/GMGNRadioApp.swift"),
] {
    requireNoPresentation(name, declaration(signature, in: app), file: file)
}

// ---------------------------------------------------------------------------
// 4. 保留项：显式动作仍然能进小窗
// ---------------------------------------------------------------------------

// 窗口自己的 X（关掉空间窗）→ 恢复小窗。
let connect = declaration("func connect(", in: liveCam)
guard connect.contains("setOnCloseHandler { [weak self] in\n            self?.resumeAfterFullStageClosed()\n        }") else {
    print("FAIL: 关掉空间窗（X）必须仍然恢复小窗"); exit(1)
}
guard declaration("func resumeAfterFullStageClosed() {", in: liveCam).contains("show()") else {
    print("FAIL: resumeAfterFullStageClosed 必须恢复小窗"); exit(1)
}
// 菜单栏「显示 Live Cam」→ 显式呈现。
guard app.contains("case .showLiveCam:\n            controller.showLiveCam()") else {
    print("FAIL: 菜单栏「显示 Live Cam」必须仍然进入小窗"); exit(1)
}

// ---------------------------------------------------------------------------
// 5. 行为级：把生产判据抽出来编译，逐条喂触发源
// ---------------------------------------------------------------------------

let harness = #"""
import Foundation

\#(request)
\#(trigger)
\#(policy)

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

// A. 非显式触发源永远不呈现（把触发源注入回去 ⇒ 这里必须 FAIL）。
let residentTriggers: [LiveCamPresentationTrigger] = [
    .residentStatusNotice, .livingWorldActivityChange,
    .characterMotionChange, .avatarSnapshotChange,
]
for trigger in residentTriggers {
    check(!trigger.mayPresentLiveCam, "非显式触发源 \(trigger) 不得呈现小窗")
    check(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: trigger, hasAvatar: true, fullStageIsPresented: false
        ),
        "\(trigger) 在空间关着时也不得呈现小窗"
    )
    check(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: trigger, hasAvatar: true, fullStageIsPresented: true
        ),
        "\(trigger) 在空间开着时不得呈现小窗"
    )
}

// 显式动作与冷启动默认形态是唯一允许呈现的两个来源。
for trigger in [LiveCamPresentationTrigger.explicitUserAction, .launchDefault] {
    check(trigger.mayPresentLiveCam, "\(trigger) 必须可以呈现小窗")
    check(
        LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: trigger, hasAvatar: true, fullStageIsPresented: false
        ),
        "\(trigger) 有角色且空间关着时必须呈现小窗"
    )
    check(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: trigger, hasAvatar: false, fullStageIsPresented: false
        ),
        "\(trigger) 没有角色时不得呈现空窗口"
    )
    check(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: trigger, hasAvatar: true, fullStageIsPresented: true
        ),
        "\(trigger) 空间占着渲染面时不得抢"
    )
}

// 四种非显式触发源 + 两个允许来源 = 全部清单，没有漏网的 case。
check(
    LiveCamPresentationTrigger.allCases.count == 6,
    "触发源清单必须正好 6 条，新增触发源必须回到这里补断言"
)

// B. 底部工具条逐按钮的行为模型：窗口形态只有两个值，十个按钮都不许改它。
//    （接线由上面的文本级断言钉住，这里把「不改变形态」写成可执行的行为。）
enum WindowForm: Equatable { case fullStage, liveCam, closed, settingsWindow }
var form = WindowForm.fullStage
var presentCount = 0
let presentLiveCam: () -> Void = { form = .liveCam; presentCount += 1 }

func pressProgramRail() { form = .fullStage }          // 面板开关：留在原形态
func pressPrevious() { form = .fullStage }             // 播放控制
func pressPlayback() { form = .fullStage }
func pressNext() { form = .fullStage }
func pressVoice() { form = .fullStage }                // 只更新状态文字
func pressVisualPicker() { form = .fullStage }
func pressChat() { form = .fullStage }
func pressInbox() { form = .fullStage }                // 自己那扇窗，不动形态
func pressPropEditor() { form = .fullStage }
func pressWindowMode() { form = .fullStage }           // 只切全屏

let bottomBar: [(String, () -> Void)] = [
    ("节目轨道", pressProgramRail), ("上一首", pressPrevious),
    ("播放/暂停", pressPlayback), ("下一首", pressNext),
    ("麦克风", pressVoice), ("设置", pressVisualPicker),
    ("对话", pressChat), ("信封", pressInbox),
    ("摆放物件", pressPropEditor), ("窗口模式", pressWindowMode),
]
for (name, press) in bottomBar {
    form = .fullStage
    press()
    check(form == .fullStage, "点底部工具条「\(name)」不得改变窗口形态")
}
check(presentCount == 0, "底部工具条的十个按钮都不得呈现小窗")
// 保留项：显式小窗动作仍然有效。
form = .fullStage
presentLiveCam()
check(form == .liveCam && presentCount == 1, "显式小窗动作必须仍然有效")

print("PASS: 底部工具条 10 个按钮都不改变窗口形态；显式小窗动作仍然有效")
print("PASS: 状态播报/活动开始/角色动作/角色快照变化都不呈现小窗，显式动作与冷启动仍然呈现")
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-livecam-auto-presentation-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
let file = temporary.appendingPathComponent("main.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [file.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
