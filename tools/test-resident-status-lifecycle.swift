// 过期状态与失败恢复提示的回归（纯逻辑，无 AppKit/Observation/窗口/GPU）。
//
// 覆盖源码确认的 P1-7 现象：
//   1. 状态行类别合并：普通信息不得覆盖失败；语音临时提示可被连接结论清除；
//   2. 换世界/换后端清掉旧提示；
//   3. 语音已连接后不再残留「正在连接语音转写…」；
//   4. 补充消息「未确认送达」提示有明确生命周期，不再永久滞留；
//   5. LiveCam 回复按回合去重：新回合的相同回复必须重新显示。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func read(_ path: String) throws -> String {
    try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}

func declaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let opening = text[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)")
        exit(1)
    }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}

let loopSource = try read("Agent/ResidentAgentLoop.swift")
let liveCamSource = try read("DesktopPresence/LiveCamPanel.swift")
let overlaySource = try read("VisualEngine/StageOverlayView.swift")
let controllerSource = try read("VisualEngine/StageWindowController.swift")
let appSource = try read("App/GMGNRadioApp.swift")

let noticeTypes = [
    declaration("enum ResidentStatusNoticeKind:", in: loopSource),
    declaration("struct ResidentStatusNoticeDecision:", in: loopSource),
    declaration("enum ResidentStatusNoticeMerge", in: loopSource),
    declaration("struct ResidentUnconfirmedNoticePolicy", in: loopSource),
].joined(separator: "\n")

let replyPolicy = [
    declaration("enum ReplyPresentation", in: liveCamSource),
    declaration("static func shouldPresentReply(", in: liveCamSource),
].joined(separator: "\n")

let composerPolicy = declaration("static func composerPrimaryActionStops(", in: liveCamSource)
let voiceStateEnum = declaration("enum RealtimeVoiceConnectionState:", in: try read("Settings/AgentSettingsModel.swift"))
let activityEnum = declaration("enum StageAvatarActivity:", in: try read("VisualEngine/SpatialStageStore.swift"))
let stageVoiceState = declaration("func setVoiceState(", in: controllerSource)

let chatStateVoiceMethods = [
    declaration("func showStatus(", in: overlaySource),
    declaration("func showVoiceStatus(", in: overlaySource),
    declaration("func showFailureStatus(", in: overlaySource),
    declaration("func dismissStatus()", in: overlaySource),
    declaration("func dismissVoiceStatus()", in: overlaySource),
    declaration("func clearTransient()", in: overlaySource),
    declaration("private func applyStatus(", in: overlaySource),
].joined(separator: "\n")

// 生产接线：断言的是一次性源码合同，不是本地镜像，避免逻辑与调用点各自漂移。
let wiringChecks: [(Bool, String)] = [
    (appSource.contains("residentUnconfirmedNotice.pending("),
     "App renders only not-yet-acknowledged unconfirmed deliveries"),
    (appSource.contains("residentUnconfirmedNotice.acknowledge("),
     "App acknowledges unconfirmed deliveries on user takeover"),
    (appSource.contains("residentUnconfirmedNotice.reset()"),
     "App resets the unconfirmed notice policy on world/backend switch"),
    (appSource.contains("liveCamWindowController?.clearTransientStatus()")
        && appSource.contains("stageWindowController?.clearResidentTransientStatus()"),
     "App clears stale status on world/backend switch"),
    (appSource.contains("agentConversationBackendDidChange")
        && (try? read("Agent/AgentConversationService.swift"))?.contains(".agentConversationBackendDidChange") == true,
     "backend switch posts a notification the host observes"),
    (appSource.contains("showResidentVoiceFailure("),
     "voice failures use the failure severity so routine info cannot overwrite them"),
    (liveCamSource.contains("dismissVoiceStatus()"),
     "Live Cam drops the voice transient notice once voice reaches a conclusion"),
    (!liveCamSource.contains("prefix(240)"),
     "Live Cam no longer silently truncates replies at 240 characters"),
    (liveCamSource.contains("cellSize(forBounds:"),
     "Live Cam measures the delivery notice so multi-line errors are not clipped"),
    (overlaySource.contains("dismissVoiceStatus()"),
     "space chat drops the voice transient notice once voice reaches a conclusion"),
    (liveCamSource.contains("Self.composerPrimaryActionStops("),
     "Live Cam composer uses the narrowed primary-stop policy"),
]

let harness = #"""
import Foundation

\#(noticeTypes)

enum LiveCamReplyPolicy {
\#(replyPolicy)
\#(composerPolicy)
}

\#(voiceStateEnum)

\#(activityEnum)

@MainActor final class MockChat {
    var statusNotice: String?
    var statusKind: ResidentStatusNoticeKind = .info
    var progress: String?
    var voiceActive = false
    \#(chatStateVoiceMethods)
}

@MainActor final class MockContent {
    var lastVoiceState: RealtimeVoiceConnectionState?
    func setVoiceState(_ state: RealtimeVoiceConnectionState) { lastVoiceState = state }
}

@MainActor final class MockAvatar {
    var lastActivity: StageAvatarActivity?
    func setActivity(_ activity: StageAvatarActivity) { lastActivity = activity }
}

@MainActor final class MockStageController {
    let residentChat = MockChat()
    let stageContentView: MockContent? = MockContent()
    let avatarRuntime = MockAvatar()
    var voiceState = RealtimeVoiceConnectionState.disconnected
    \#(stageVoiceState)
}

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}

@main struct Main {
    @MainActor static func main() {
        // 1) 状态行合并：失败优先，语音临时提示不被普通信息覆盖。
        var d = ResidentStatusNoticeMerge.resolve(incoming: "开始播放", kind: .info,
                                                  current: nil, currentKind: .info)
        check(d.text == "开始播放" && d.kind == .info, "info fills an empty status line")

        d = ResidentStatusNoticeMerge.resolve(incoming: "普通提示", kind: .info,
                                              current: "本轮未完成", currentKind: .failure)
        check(d.text == "本轮未完成" && d.kind == .failure,
              "routine info never overwrites a pending failure")

        d = ResidentStatusNoticeMerge.resolve(incoming: "正在听", kind: .voice,
                                              current: "本轮未完成", currentKind: .failure)
        check(d.text == "本轮未完成" && d.kind == .failure,
              "a voice transient never overwrites a pending failure")

        d = ResidentStatusNoticeMerge.resolve(incoming: "普通提示", kind: .info,
                                              current: "正在连接语音转写…", currentKind: .voice)
        check(d.text == "正在连接语音转写…" && d.kind == .voice,
              "routine info never overwrites a connecting voice notice")

        d = ResidentStatusNoticeMerge.resolve(incoming: "语音连接失败", kind: .failure,
                                              current: "正在连接语音转写…", currentKind: .voice)
        check(d.text == "语音连接失败" && d.kind == .failure,
              "a failure replaces a voice transient")

        d = ResidentStatusNoticeMerge.resolve(incoming: "   ", kind: .info,
                                              current: "本轮未完成", currentKind: .failure)
        check(d.text == nil && d.kind == .info, "blank text explicitly clears the status line")

        // 2) 空间聊天状态机的可见行为。
        let chat = MockChat()
        chat.showFailureStatus("本轮未完成：请重试")
        chat.showStatus("点唱机开始播放音乐。")
        check(chat.statusNotice == "本轮未完成：请重试" && chat.statusKind == .failure,
              "space chat keeps the failure when a routine notice arrives")
        chat.showVoiceStatus("正在连接语音转写…")
        check(chat.statusKind == .failure, "space chat voice notice cannot hide a failure")
        chat.dismissVoiceStatus()
        check(chat.statusKind == .failure, "dismissVoiceStatus never clears a real failure")
        chat.clearTransient()
        check(chat.statusNotice == nil && chat.progress == nil,
              "clearTransient drops stale status and progress on world/backend switch")
        chat.showVoiceStatus("正在连接语音转写…")
        chat.dismissVoiceStatus()
        check(chat.statusNotice == nil, "dismissVoiceStatus clears a voice transient")
        chat.showVoiceStatus("正在听，说完一句会自动发送。")
        check(chat.statusNotice == "正在听，说完一句会自动发送。" && chat.statusKind == .voice,
              "space chat shows the listening notice after voice connects")

        // 3) 语音状态机：连接成功后不残留「正在连接」，断麦后不残留「正在听」。
        let controller = MockStageController()
        controller.setVoiceState(.connecting)
        check(controller.residentChat.statusNotice == "正在连接语音转写…"
                && controller.residentChat.statusKind == .voice,
              "connecting shows the voice transient")
        controller.setVoiceState(.listening)
        check(controller.residentChat.statusNotice == nil,
              "reaching listening clears the connecting notice")
        controller.residentChat.showVoiceStatus("正在听，说完一句会自动发送。")
        controller.setVoiceState(.disconnected)
        check(controller.residentChat.statusNotice == nil,
              "mic off clears the listening voice notice")
        controller.residentChat.showFailureStatus("语音连接失败：重试")
        controller.setVoiceState(.connected)
        check(controller.residentChat.statusNotice == "语音连接失败：重试",
              "voice terminal state never clears an unrelated failure")

        // 4) 未确认交付提示的生命周期。
        var policy = ResidentUnconfirmedNoticePolicy()
        check(policy.pending(["文本补充"]) == ["文本补充"], "an unconfirmed delivery is visible first")
        policy.acknowledge(["文本补充"])
        check(policy.pending(["文本补充"]).isEmpty, "a user takeover clears the old notice")
        check(policy.pending(["文本补充", "新的补充"]) == ["新的补充"],
              "a newly unconfirmed delivery is still surfaced")
        policy.reset()
        check(policy.pending(["文本补充"]) == ["文本补充"], "reset re-arms the notice after a context switch")

        // 5) LiveCam 回复按回合去重。
        check(!LiveCamReplyPolicy.shouldPresentReply("好的", as: .agentReply,
                                                     latestText: "好的", latestPresentation: .agentReply,
                                                     latestTurn: 3, currentTurn: 3),
              "same reply re-observed inside one turn stays deduplicated")
        check(LiveCamReplyPolicy.shouldPresentReply("好的", as: .agentReply,
                                                    latestText: "好的", latestPresentation: .agentReply,
                                                    latestTurn: 3, currentTurn: 4),
              "an identical reply in a new turn is shown again")
        check(LiveCamReplyPolicy.shouldPresentReply("新的一条", as: .agentReply,
                                                    latestText: "好的", latestPresentation: .agentReply,
                                                    latestTurn: 3, currentTurn: 3),
              "a different reply shows within the same turn")

        // 6) 发送/停止不混用：仅自主生活开启的后台预算不得把发送按钮变成停止。
        check(LiveCamReplyPolicy.composerPrimaryActionStops(isThinking: true, isSpeaking: false, hasDraft: false),
              "an active turn lets the primary button stop")
        check(LiveCamReplyPolicy.composerPrimaryActionStops(isThinking: false, isSpeaking: true, hasDraft: false),
              "speaking lets the primary button stop speech")
        check(!LiveCamReplyPolicy.composerPrimaryActionStops(isThinking: false, isSpeaking: false, hasDraft: false),
              "background autonomy alone never turns the send button into stop")
        check(!LiveCamReplyPolicy.composerPrimaryActionStops(isThinking: true, isSpeaking: false, hasDraft: true),
              "a pending draft keeps the primary button as send")

        // 7) 回归判别力：旧实现（文本级去重 / 无条件覆盖 / 后台预算即停止）会让上面的
        // 断言失败。这里显式复刻旧行为，证明这些回归能区分修复前后的语义。
        func legacyTextDedupe(_ text: String, latest: String) -> Bool { text != latest }
        check(!legacyTextDedupe("好的", latest: "好的"),
              "legacy text-level dedupe would swallow a legitimate repeated reply")
        func legacyOverwrite(_ incoming: String, current: String?) -> String? {
            incoming.isEmpty ? nil : incoming
        }
        check(legacyOverwrite("普通提示", current: "本轮未完成") == "普通提示",
              "legacy status merge would let routine info overwrite a failure")
        func legacyPrimaryStops(canStopResident: Bool, hasDraft: Bool) -> Bool {
            canStopResident && !hasDraft
        }
        check(legacyPrimaryStops(canStopResident: true, hasDraft: false),
              "legacy composer would turn send into stop for background autonomy alone")

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\(status): \(checks) resident status lifecycle checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-status-lifecycle-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("StatusLifecycle.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("status-lifecycle-test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus

var wiringFailures = 0
for (ok, label) in wiringChecks where !ok {
    wiringFailures += 1
    print("FAIL: \(label)")
}
if wiringFailures > 0 { print("FAIL: \(wiringFailures) status lifecycle wiring checks failed") }
exit(testExit == 0 && wiringFailures == 0 ? 0 : 1)
