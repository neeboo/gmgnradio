// Native chat state and production keyboard handlers, with no app/window/GPU.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let controller = try String(contentsOf: sources.appendingPathComponent("VisualEngine/StageWindowController.swift"), encoding: .utf8)
let overlay = try String(contentsOf: sources.appendingPathComponent("VisualEngine/StageOverlayView.swift"), encoding: .utf8)
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
let keyboard = ["override func keyDown(", "override func keyUp(", "override func resignFirstResponder()", "override func scrollWheel(", "private static func movement("].map {
    declaration($0, in: controller)
}.joined(separator: "\n")
let replyMethods = ["func beginResidentReply()", "func finishResidentReply(", "func showResidentChatStatus("].map {
    declaration($0, in: controller)
}.joined(separator: "\n")
let chatToggle = declaration("private func toggleResidentChat()", in: controller)
precondition(!chatToggle.contains("cancel") && !chatToggle.contains("residentChat"), "collapsing chat must not cancel or reset its state")
precondition(controller.contains("residentComposer.trailingAnchor.constraint(equalTo: transportControls.trailingAnchor)"), "composer belongs above the bottom-right controls")
precondition(overlay.contains("ScrollView") && overlay.contains(".textSelection(.enabled)"), "reply must remain readable and selectable")
let harness = #"""
import Foundation
import Combine
@MainActor
\#(state)
enum SpatialMovement: Hashable { case forward, backward, left, right }
final class NSTextView {}
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
    \#(keyboard)
}
@MainActor final class Controller {
    let residentChat = StageResidentChatState()
    \#(replyMethods)
}
@MainActor final class SpeechStatus { var isSpeaking = false }
@MainActor final class ComposerControls {
    let state = StageResidentChatState()
    let speechStatus = SpeechStatus()
    var cancelled = 0
    var submitted = 0
    func onCancelMessage() { cancelled += 1 }
    func submit() { submitted += 1 }
    func press() { performPrimaryAction() }
    \#(canStop)
    \#(primaryAction)
}
@main struct Tests {
    @MainActor static func main() {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ text: String) { count += 1; if !condition { failures += 1; print("FAIL: \(text)") } }
        let state = StageResidentChatState()
        check(state.takeMessage() == nil && !state.isThinking, "blank message is not submitted")
        state.draft = "  去点唱机放首歌  \n"
        check(state.takeMessage() == "去点唱机放首歌" && state.draft.isEmpty && state.isThinking, "submit trims message and starts waiting")
        state.draft = "下一条"
        check(state.takeMessage() == nil && state.draft == "下一条", "waiting does not submit another accidental Enter")
        state.finish("正在播放")
        check(state.reply == "正在播放" && !state.isThinking, "reply exits waiting")
        check(state.takeMessage() == "下一条", "new message works after reply")
        state.cancel()
        check(!state.isThinking && !state.reply.isEmpty, "stop exits waiting immediately")
        let controller = Controller()
        controller.beginResidentReply()
        check(controller.residentChat.isThinking, "controller forwards shared reply start")
        controller.finishResidentReply("你好")
        check(controller.residentChat.reply == "你好" && !controller.residentChat.isThinking, "controller forwards shared reply finish")
        controller.beginResidentReply()
        controller.showResidentChatStatus("连接失败")
        check(controller.residentChat.reply == "连接失败" && !controller.residentChat.isThinking, "controller failure status clears waiting")
        let controls = ComposerControls()
        controls.state.finish("完整的文字回复")
        controls.speechStatus.isSpeaking = true
        controls.press()
        check(controls.cancelled == 1 && controls.submitted == 0, "speaking button stops audio instead of sending")
        check(controls.state.reply == "完整的文字回复", "stopping audio preserves completed reply")
        controls.speechStatus.isSpeaking = false
        controls.state.begin()
        controls.press()
        check(!controls.state.isThinking && controls.cancelled == 2, "thinking stop retains existing cancellation behavior")
        controls.press()
        check(controls.submitted == 1, "idle primary button still sends")
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
let speechSource = try String(contentsOf: sources.appendingPathComponent("Agent/AgentSpeech.swift"), encoding: .utf8)
let ui = "import SwiftUI\nimport AppKit\nimport Observation\n@MainActor\n@Observable\n"
    + declaration("final class AgentSpeechStatusStore", in: speechSource) + "\n@MainActor\n"
    + declaration("struct ResidentSpeechErrorNotice:", in: overlay) + "\n@MainActor\n"
    + state + "\n@MainActor\n"
    + declaration("struct StageResidentComposer:", in: overlay) + "\n@MainActor\n"
    + declaration("private final class StageResidentChatButton:", in: controller)
try ui.write(to: uiSource, atomically: true, encoding: .utf8)
let checked = try run("/usr/bin/swiftc", ["-j1", "-typecheck", "-target", "arm64-apple-macos14.0", uiSource.path])
guard checked == 0 else { exit(checked) }
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", source.path, "-o", executable.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
