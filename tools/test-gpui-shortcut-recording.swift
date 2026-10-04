import Foundation

// Compile and execute the exact production callback with disposable stand-ins.
let source = try String(contentsOfFile: "apps/macos/ProductHost/ProductSettingsParity.swift", encoding: .utf8)
let start = source.range(of: "    private func handleRecordingEvent(")!.lowerBound
let opening = source[start...].firstIndex(of: "{")!
var depth = 0
var end = opening
for index in source[opening...].indices {
    if source[index] == "{" { depth += 1 }
    if source[index] == "}" { depth -= 1 }
    if depth == 0 { end = source.index(after: index); break }
}
let callback = String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
let harness = """
import Foundation
struct NSEvent { let keyCode: Int; let modified: Bool }
enum Scope { case local, global }
struct Target { let action = "play"; let scope: Scope }
struct GMGNKeyCombination {
    let modifiers: [Int]
    init?(event: NSEvent) { modifiers = event.modified ? [1] : [] }
}
final class Store {
    var recordingTarget: Target?
    var assigned = 0
    func cancelRecording() { recordingTarget = nil }
    func assign(_ value: GMGNKeyCombination, to: String, scope: Scope) { assigned += 1; recordingTarget = nil }
}
final class Runtime { let shortcutSettingsStore = Store() }
final class Callback {
    let runtime = Runtime()
    var shortcutValidationMessage: String?
    var removed = 0
    func removeRecordingMonitor() { removed += 1 }
\(callback)
}
let callback = Callback()
let store = callback.runtime.shortcutSettingsStore
store.recordingTarget = Target(scope: .global)
precondition(callback.handleRecordingEvent(NSEvent(keyCode: 0, modified: false)))
precondition(store.assigned == 0 && store.recordingTarget != nil && callback.removed == 0)
precondition(callback.shortcutValidationMessage == "全局快捷键至少需要一个修饰键。")
precondition(callback.handleRecordingEvent(NSEvent(keyCode: 53, modified: false)))
precondition(store.assigned == 0 && store.recordingTarget == nil && callback.shortcutValidationMessage == nil)
store.recordingTarget = Target(scope: .local)
precondition(callback.handleRecordingEvent(NSEvent(keyCode: 0, modified: false)))
precondition(store.assigned == 1 && store.recordingTarget == nil)
store.recordingTarget = Target(scope: .global)
precondition(callback.handleRecordingEvent(NSEvent(keyCode: 0, modified: true)))
precondition(store.assigned == 2 && store.recordingTarget == nil)
print("PASS: production callback global plain rejection, local plain acceptance, Escape cancellation and modified global acceptance")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gpui-shortcut-callback-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("callback.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [file.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
