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
    + declaration("enum LiveCamWindowDragPhase:", in: try read("DesktopPresence/WindowPlacement.swift")) + "\n@MainActor\n@Observable\n"
    + declaration("final class AgentSpeechStatusStore", in: try read("Agent/AgentSpeech.swift")) + "\n@MainActor\n"
    + declaration("struct ResidentSpeechErrorNotice:", in: try read("VisualEngine/StageOverlayView.swift"))
let harness = #"""
import AppKit
import SwiftUI

@main struct Tests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var count = 0, failures = 0
        func check(_ condition: Bool, _ text: String) {
            count += 1
            if !condition { failures += 1; print("FAIL: \(text)") }
        }
        for requested in [CGSize(width: 224, height: 336), CGSize(width: 320, height: 240)] {
            AgentSpeechStatusStore.shared.lastErrorMessage = nil
            let surface = NSView()
            let panel = LiveCamPanel(frame: CGRect(origin: .zero, size: requested), contentView: surface)
            panel.isReleasedWhenClosed = false
            // The production callback orders the real panel front when typing.
            // Test the real composer toggle while suppressing that window action.
            panel.interactionView.onComposerVisibilityChanged = { _ in }
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
                print("LAYOUT \(label) requested=\(requested) frame=\(panel.frame.size) surface=\(surface.frame.size) notice=\(notice.frame.size)")
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
            panel.setSendMessageHandler { sent.append($0) }
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
            check(!panel.interactionView.stopButton.isHidden && panel.interactionView.stopButton.toolTip == "停止朗读", "speech observation exposes independent stop without thinking")
            panel.interactionView.stopButton.performClick(nil)
            check(stopped == 3 && panel.interactionView.replyText == "保留完整回答", "speech stop uses app cancellation without clearing text")
            AgentSpeechStatusStore.shared.isSpeaking = false
            for _ in 0..<10 { await Task.yield() }
            check(panel.interactionView.stopButton.isHidden, "speech stop disappears after playback finishes")
            panel.setResidentCanStop(true)
            check(!panel.interactionView.stopButton.isHidden && panel.interactionView.stopButton.toolTip == "停止当前任务", "silent owned activity retains independent stop")
            panel.interactionView.stopButton.performClick(nil)
            check(stopped == 4 && panel.interactionView.replyText == "保留完整回答", "silent activity stop reaches application without clearing reply")
            panel.setResidentCanStop(false)
            check(panel.interactionView.stopButton.isHidden, "application-owned stop state clears once activity is stopped")
            check(!panel.isVisible, "steering checks never display a window")
            panel.close()
        }
        AgentSpeechStatusStore.shared.lastErrorMessage = nil
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
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-target", "arm64-apple-macos14.0", base.appendingPathComponent("DesktopPresence/LiveCamPanel.swift").path, deps.path, tests.path, "-o", binary.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(binary.path, []))
