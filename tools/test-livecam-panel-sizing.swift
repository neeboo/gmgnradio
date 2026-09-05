// Real AppKit layout, with explicitly authorized NSApplication initialization.
// Never runs/activates the application or shows a window; no GMGN host or GPU.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
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
