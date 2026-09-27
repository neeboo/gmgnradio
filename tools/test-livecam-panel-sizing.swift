// Real AppKit layout, with explicitly authorized NSApplication initialization.
// Never runs/activates the application or shows a window; no GMGN host or GPU.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
let panelSource = try read("DesktopPresence/LiveCamPanel.swift")
guard panelSource.contains("func setResidentCanStop(") else {
    print("FAIL: Live Cam cannot stop a silent owned activity")
    exit(1)
}
guard panelSource.contains("func setResidentDeliveryNotice("), panelSource.contains("observeSpeechPlayback") else {
    print("FAIL: Live Cam has no separate delivery notice or reactive speech stop")
    exit(1)
}
guard panelSource.contains("func setResidentThinking("), panelSource.contains("livecam.button.stop") else {
    print("FAIL: Live Cam has no independent immediate stop while entering human guidance")
    exit(1)
}
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
let dependencies = "import SwiftUI\nimport Observation\n"
    + declaration("enum LocalMusicPlaybackState:", in: try read("AudioEngine/LocalMusicPlayer.swift")) + "\n"
    + declaration("enum ProgramPlaybackToggleRoute:", in: try read("AudioEngine/ProgramPlaybackQueue.swift")) + "\n"
    + declaration("enum RealtimeVoiceConnectionState:", in: try read("Settings/AgentSettingsModel.swift")) + "\n"
    + declaration("enum ResidentStatusNoticeKind:", in: try read("Agent/ResidentAgentLoop.swift")) + "\n"
    + declaration("struct ResidentStatusNoticeDecision:", in: try read("Agent/ResidentAgentLoop.swift")) + "\n"
    + declaration("enum ResidentStatusNoticeMerge", in: try read("Agent/ResidentAgentLoop.swift")) + "\n"
    + declaration("enum LiveCamWindowDragPhase:", in: try read("DesktopPresence/WindowPlacement.swift")) + "\n"
    // Live Cam 控件依赖的两个跨文件声明：共享的对话记录行模型（Sendable，两个聊天
    // 表面口径一致）与系统消息入口按钮（AppKit，@MainActor）。此前缺失时编译器只会
    // 报 "cannot find type" 并连带退化成 "cannot infer contextual base"，因此必须把
    // 真实声明补进抽取清单，而不是放宽或删除任何断言。
    + declaration("struct ResidentChatTranscriptLine:", in: try read("Agent/ResidentAgentLoop.swift")) + "\n@MainActor\n"
    + declaration("final class ResidentSystemMailBadgeButton: NSView {", in: try read("Presence/ResidentSystemInboxUI.swift")) + "\n@MainActor\n@Observable\n"
    + declaration("final class AgentSpeechStatusStore", in: try read("Agent/AgentSpeech.swift")) + "\n@MainActor\n"
    + declaration("struct ResidentSpeechErrorNotice:", in: try read("VisualEngine/StageOverlayView.swift")) + "\n@MainActor\n"
    + declaration("struct WishMachineTaskStatusView:", in: try read("VisualEngine/StageOverlayView.swift"))
let harness = #"""
import AppKit
import SwiftUI

@main struct Tests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var count = 0, failures = 0
        var retainedPanels: [LiveCamPanel] = []
        func check(_ condition: Bool, _ text: String) {
            count += 1
            if !condition { failures += 1; print("FAIL: \(text)") }
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func clickThroughWindow(_ view: NSView, in panel: NSWindow) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.05,
                                        windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            let root = panel.contentView!
            let hit = root.hitTest(root.convert(point, from: nil))!
            var ancestor: NSView? = hit
            while let current = ancestor {
                for gesture in current.gestureRecognizers {
                    check(gesture.delegate?.gestureRecognizer?(gesture, shouldAttemptToRecognizeWith: down) == false,
                          "ancestor gesture opts out before native close-button tracking")
                }
                ancestor = current.superview
            }
            // Hidden windows do not dispatch a normal AppKit recognition stream.
            // Route through the root hit result and native button mouse tracking
            // after checking all ancestor recognizers at this actual event point.
            NSApp.postEvent(up, atStart: true)
            hit.mouseDown(with: down)
        }
        for requested in [CGSize(width: 224, height: 336), CGSize(width: 320, height: 240)] {
            AgentSpeechStatusStore.shared.lastErrorMessage = nil
            let surface = NSView()
            let panel = LiveCamPanel(frame: CGRect(origin: .zero, size: requested), contentView: surface)
            retainedPanels.append(panel)
            panel.isReleasedWhenClosed = false
            // Use the production window boundary unchanged. Test-only width or
            // height constraints conceal content-driven viewport compression.
            print("INITIAL requested=\(requested) panel=\(panel.frame.size) content=\(String(describing: panel.contentView?.frame.size)) interaction=\(panel.interactionView.frame.size) min=\(panel.contentMinSize) max=\(panel.contentMaxSize)")
            // The production callback orders the real panel front when typing.
            // Test the real composer toggle while suppressing that window action.
            panel.interactionView.onComposerVisibilityChanged = { _ in }
            var firstSpaceEntries = 0, latestSpaceEntries = 0
            panel.setEnterSpaceHandler { firstSpaceEntries += 1 }
            panel.interactionView.spaceButton.performClick(nil)
            check(firstSpaceEntries == 1, "space icon reaches the panel's current stage-entry handler exactly once")
            panel.setEnterSpaceHandler { latestSpaceEntries += 1 }
            panel.interactionView.spaceButton.performClick(nil)
            check(firstSpaceEntries == 1 && latestSpaceEntries == 1, "space icon uses replaced handler rather than stale init closure")
            let notice = panel.interactionView.subviews.first {
                $0.identifier?.rawValue == "livecam.speech-error"
            } as! NSHostingView<ResidentSpeechErrorNotice>
            for (label, error) in [("empty", nil), ("long-error", String(repeating: "语音服务暂时不可用，请检查设置。", count: 8)), ("cleared", nil)] as [(String, String?)] {
                AgentSpeechStatusStore.shared.lastErrorMessage = error
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(25))
                    panel.contentView?.needsLayout = true
                    panel.contentView?.layoutSubtreeIfNeeded()
                }
                print("LAYOUT \(label) requested=\(requested) frame=\(panel.frame.size) content=\(String(describing: panel.contentView?.frame.size)) interaction=\(panel.interactionView.frame.size) surface=\(surface.frame.size) notice=\(notice.frame.size)")
                check(panel.frame.size == requested, "\(label) preserves requested window size")
                check(surface.frame.size == requested, "\(label) preserves render surface size")
                check(!panel.isVisible, "layout test never displays a window")
                if error != nil { check(notice.frame.height > 0, "long error has visible layout height") }
                check(notice.frame.width <= requested.width - 20, "notice stays inside the content width")
            }
            panel.interactionView.messageField.stringValue = "保留草稿"
            for expanded in [true, false] {
                panel.interactionView.chatButton.performClick(nil)
                panel.contentView?.layoutSubtreeIfNeeded()
                check(panel.interactionView.isComposerVisible == expanded, "composer still toggles")
                check(panel.frame.size == requested && surface.frame.size == requested, "composer toggle preserves fixed viewport")
                check(panel.interactionView.messageField.stringValue == "保留草稿", "composer toggle preserves draft")
                check(!panel.isVisible, "composer test never displays a window")
            }
            var sent: [String] = []
            var stopped = 0
            var speechStopped = 0
            AgentSpeechStatusStore.shared.onStopSpeaking = {
                speechStopped += 1
                AgentSpeechStatusStore.shared.isSpeaking = false
            }
            panel.setSendMessageHandler { sent.append($0.text) }
            panel.setCancelMessageHandler { stopped += 1 }
            panel.setResidentThinking(true)
            check(!panel.interactionView.stopButton.isHidden, "independent stop is visible beside a pending draft")
            panel.interactionView.sendButton.performClick(nil)
            check(sent == ["保留草稿"] && stopped == 0, "sending guidance does not cancel the current loop")
            check(panel.interactionView.messageField.stringValue.isEmpty, "submitted guidance clears only the draft")
            panel.interactionView.sendButton.performClick(nil)
            check(stopped == 1 && sent.count == 1, "empty primary action immediately stops current loop")
            panel.interactionView.messageField.stringValue = "换点舒缓的"
            panel.setResidentThinking(true)
            panel.interactionView.stopButton.performClick(nil)
            check(stopped == 2 && panel.interactionView.messageField.stringValue == "换点舒缓的", "independent stop preserves an unsent draft")
            panel.showAgentReply("保留完整回答")
            panel.setResidentDeliveryNotice("有补充消息尚未确认送达，未重复发送。")
            panel.contentView?.layoutSubtreeIfNeeded()
            check(panel.interactionView.replyText == "保留完整回答", "delivery notice never overwrites final reply")
            check(!panel.interactionView.residentDeliveryNotice.isEmpty && panel.frame.size == requested, "delivery notice is visible without changing viewport size")
            panel.setResidentDeliveryNotice(nil)
            check(panel.interactionView.residentDeliveryNotice.isEmpty && panel.interactionView.replyText == "保留完整回答", "clearing delivery notice preserves reply")
            AgentSpeechStatusStore.shared.isSpeaking = true
            for _ in 0..<10 { await Task.yield() }
            check(!panel.interactionView.stopButton.isHidden && panel.interactionView.stopButton.toolTip == "停止说话" && panel.interactionView.stopButton.title == "停止说话", "speech observation exposes visibly labelled speech-only stop")
            panel.interactionView.stopButton.performClick(nil)
            check(speechStopped == 1 && stopped == 2 && panel.interactionView.replyText == "保留完整回答", "speech stop does not cancel resident task/session or clear text")
            AgentSpeechStatusStore.shared.isSpeaking = false
            for _ in 0..<10 { await Task.yield() }
            check(panel.interactionView.stopButton.isHidden, "speech stop disappears after playback finishes")
            panel.setResidentCanStop(true)
            check(!panel.interactionView.stopButton.isHidden && panel.interactionView.stopButton.toolTip == "停止当前任务", "silent owned activity retains independent stop")
            panel.interactionView.stopButton.performClick(nil)
            check(stopped == 3 && panel.interactionView.replyText == "保留完整回答", "silent activity stop reaches application without clearing reply")
            panel.setResidentCanStop(false)
            check(panel.interactionView.stopButton.isHidden, "application-owned stop state clears once activity is stopped")
            let longReply = String(repeating: "这是完整的回复，用来验证文字不会一直挡住角色。\n", count: 80)
            panel.showAgentReply(longReply)
            panel.contentView?.needsLayout = true
            panel.contentView?.layoutSubtreeIfNeeded()
            let views = descendants(panel.interactionView)
            let bubble = views.first { $0.identifier?.rawValue == "livecam.reply-bubble" }
            let dismiss = views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "livecam.reply-dismiss" }
            let fullReply = views.first { $0.identifier?.rawValue == "livecam.full-reply" } as? NSScrollView
            check(bubble != nil && dismiss != nil && fullReply != nil, "desktop reply has compact bubble, dismiss, and full-text disclosure")
            if let bubble, let dismiss, let fullReply {
                check(bubble.frame.width <= min(requested.width - 58, 260) && bubble.frame.height <= 74, "long latest reply stays within compact bubble bounds")
                check(bubble.frame.width >= 100 && bubble.frame.height >= 25 && dismiss.frame.maxX <= bubble.bounds.width, "compact preview and dismiss button have usable visible bounds")
                check(!bubble.isHidden && fullReply.isHidden, "new reply displays only compact preview")
                let cancellationsBeforeDismiss = stopped, speechBeforeDismiss = speechStopped
                let dismissPoint = dismiss.convert(NSPoint(x: dismiss.bounds.midX, y: dismiss.bounds.midY), to: panel.contentView)
                check(panel.contentView?.hitTest(dismissPoint) === dismiss, "close button wins actual root hit testing")
                dismiss.performClick(nil)
                check(bubble.isHidden && panel.interactionView.replyText == longReply.trimmingCharacters(in: .whitespacesAndNewlines), "dismiss hides preview without deleting complete reply")
                check(stopped == cancellationsBeforeDismiss && speechStopped == speechBeforeDismiss, "dismiss never stops task, activity, or speech")
                panel.showAgentReply(longReply)
                check(bubble.isHidden, "repeated observation of the same reply does not undo dismissal")
                panel.interactionView.chatButton.performClick(nil)
                panel.contentView?.layoutSubtreeIfNeeded()
                check(panel.interactionView.isComposerVisible && !bubble.isHidden && !fullReply.isHidden, "chat entry reveals complete latest reply")
                check((fullReply.documentView as? NSTextView)?.string == panel.interactionView.replyText, "expanded reply retains all text for scrolling")
                check(fullReply.frame.height > 0 && (fullReply.documentView?.frame.height ?? 0) > fullReply.contentSize.height, "expanded long reply is laid out as scrollable content")
                panel.interactionView.chatButton.performClick(nil)
                check(bubble.isHidden && fullReply.isHidden, "collapsing chat respects dismissed preview")
                panel.showAgentReply("一条新的回复")
                check(!bubble.isHidden, "new reply reappears after dismiss")
                if let gesture = bubble.gestureRecognizers.first, let action = gesture.action {
                    NSApp.sendAction(action, to: gesture.target, from: gesture)
                    check(panel.interactionView.isComposerVisible && !fullReply.isHidden, "clicking bubble opens full-text chat")
                } else { check(false, "bubble offers a full-text click action") }
                panel.closeChatComposer()
                panel.contentView?.layoutSubtreeIfNeeded()
                check(fullReply.isHidden && bubble.frame.height <= 74, "closing composer returns to compact preview")
                check(panel.frame.size == requested && surface.frame.size == requested, "long reply and disclosure preserve viewport")
            }
            check(!panel.isVisible, "steering checks never display a window")
        }
        // Native mouse tracking starts an AppKit event stream. Run it after all
        // async layout checks so the CLI runner never yields into NSApplication's
        // lifecycle while exercising these intentionally hidden windows.
        for panel in retainedPanels {
            panel.showAgentReply("Agent 没有返回内容，请稍后再试。")
            panel.contentView?.layoutSubtreeIfNeeded()
            let dismiss = descendants(panel.interactionView).compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier() == "livecam.reply-dismiss"
            }!
            clickThroughWindow(dismiss, in: panel)
            check(panel.interactionView.isReplyHidden, "native mouse tracking closes reply after root hit and ancestor gesture filtering")
            panel.showAgentReply("Agent 没有返回内容，请稍后再试。")
            check(panel.interactionView.isReplyHidden, "same error stays dismissed after native close click")
            check(!panel.isVisible, "native mouse tracking never displays the test panel")
        }
        AgentSpeechStatusStore.shared.lastErrorMessage = nil
        AgentSpeechStatusStore.shared.onStopSpeaking = nil
        print("\(failures == 0 ? "PASS" : "FAIL"): \(count) real AppKit sizing checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-livecam-sizing-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let deps = directory.appendingPathComponent("Dependencies.swift")
let tests = directory.appendingPathComponent("Tests.swift")
let binary = directory.appendingPathComponent("tests")
try dependencies.write(to: deps, atomically: true, encoding: .utf8)
try harness.write(to: tests, atomically: true, encoding: .utf8)
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let attachmentSources = ["Presence/ResidentImageAttachment.swift", "Presence/PropImagePreparation.swift", "Presence/PropGenerationClient.swift", "Presence/WishMachineTaskPresentation.swift"].map { base.appendingPathComponent($0).path }
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-target", "arm64-apple-macos14.0", base.appendingPathComponent("DesktopPresence/LiveCamPanel.swift").path, deps.path, tests.path, "-o", binary.path] + attachmentSources)
guard compiled == 0 else { exit(compiled) }
if CommandLine.arguments.contains("--compile-only") { print("PASS: Live Cam attachment UI compiles; no AppKit runtime started"); exit(0) }
exit(try run(binary.path, []))
