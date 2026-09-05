// Shared speech-error notice: no app, window, audio, or network is started.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let overlay = try String(contentsOf: base.appendingPathComponent("VisualEngine/StageOverlayView.swift"), encoding: .utf8)
let liveCam = try String(contentsOf: base.appendingPathComponent("DesktopPresence/LiveCamPanel.swift"), encoding: .utf8)
let speech = try String(contentsOf: base.appendingPathComponent("Agent/AgentSpeech.swift"), encoding: .utf8)
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        print("FAIL: speech failures have no independent visible notice")
        exit(1)
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced declaration")
}
let notice = declaration("struct ResidentSpeechErrorNotice:", in: overlay)
let store = declaration("final class AgentSpeechStatusStore", in: speech)
precondition(declaration("struct StageResidentComposer:", in: overlay).contains("ResidentSpeechErrorNotice()"))
precondition(liveCam.contains("NSHostingView(rootView: ResidentSpeechErrorNotice())"))
precondition(!notice.contains("state.reply"), "speech error must not replace the agent reply")
let harness = "import SwiftUI\nimport Observation\n@MainActor\n@Observable\n" + store + "\n@MainActor\n" + notice + #"""

final class Flag: @unchecked Sendable { var changed = false }
@main struct Tests {
    @MainActor static func main() {
        let store = AgentSpeechStatusStore.shared
        let view = ResidentSpeechErrorNotice()
        let appeared = Flag()
        withObservationTracking { _ = view.body } onChange: { appeared.changed = true }
        store.lastErrorMessage = "百炼语音合成失败，请检查音色设置。"
        precondition(appeared.changed, "a late speech failure must refresh the visible notice")
        let cleared = Flag()
        withObservationTracking { _ = view.body } onChange: { cleared.changed = true }
        store.lastErrorMessage = nil
        precondition(cleared.changed, "clearing a failure must remove the notice")
        print("PASS: late speech error and clear are observed; both chat surfaces retain separate replies")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-speech-notice-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("Tests.swift")
let executable = directory.appendingPathComponent("tests")
try harness.write(to: source, atomically: true, encoding: .utf8)
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run(); process.waitUntilExit()
    return process.terminationStatus
}
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-target", "arm64-apple-macos14.0", source.path, "-o", executable.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
