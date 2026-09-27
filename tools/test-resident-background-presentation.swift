// 后台/自驱回合的呈现策略回归（纯逻辑，无 AppKit/Observation/窗口/GPU）。
//
// 抽取生产 StageWindowController 的三个呈现方法 + ResidentAgentLoop 的回合归属位，
// 验证：后台回合只更新状态，绝不抢开聊天或收起用户面板；用户回合仍自动展开。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func declaration(_ signature: String, _ text: String) -> String {
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

let controllerSource = try String(
    contentsOf: sources.appendingPathComponent("VisualEngine/StageWindowController.swift"), encoding: .utf8)
let loopSource = try String(
    contentsOf: sources.appendingPathComponent("Agent/ResidentAgentLoop.swift"), encoding: .utf8)
let appSource = try String(
    contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)

let revealMethods = [
    declaration("func setResidentThinking(", controllerSource),
    declaration("func finishResidentReply(", controllerSource),
    declaration("func showResidentChatStatus(", controllerSource),
].joined(separator: "\n")

// 生产接线：应用层用回合归属决定是否自动展开。断言的是一次性源码合同，
// 不是本地镜像，避免方法体与调用点各自漂移。
let wiringChecks: [(Bool, String)] = [
    (appSource.contains("setResidentThinking(thinking, autoRevealsChat: !backgroundTurn)"),
     "App passes background ownership into setResidentThinking"),
    (appSource.contains("finishResidentReply(reply, autoRevealsChat: autoRevealsChat)"),
     "App passes background ownership into finishResidentReply"),
    (appSource.contains("residentAgentLoop?.lastFinishedRunWasBackground != true"),
     "App reads the finished-run ownership for reply presentation"),
    (appSource.contains("presentResidentLoopFailure"),
     "App routes loop failures through the ownership-aware presenter"),
    (appSource.contains("showResidentFailureStatus(text, autoRevealsChat: !backgroundTurn)"),
     "App suppresses chat reveal for background failures"),
    (loopSource.contains("private(set) var lastFinishedRunWasBackground = false"),
     "Loop exposes finished-run ownership to the host"),
    (loopSource.contains("lastFinishedRunWasBackground = wasBackground"),
     "Loop records ownership before onReply/onFailure callbacks"),
]

let harness = #"""
import Foundation

@MainActor final class ResidentChat {
    var isThinking = false
    var reply = ""
    var statusNotice: String?
    func setThinking(_ value: Bool) { isThinking = value }
    func finish(_ text: String) { reply = text; isThinking = false }
    func showStatus(_ text: String) { statusNotice = text }
}

@MainActor final class Content {
    var composerHidden = true
    var pickerHidden = false
    var reveals = 0
    func showResidentChat() {
        reveals += 1
        composerHidden = false
        pickerHidden = true
    }
    func collapse() { composerHidden = true }
}

@MainActor final class Controller {
    let residentChat = ResidentChat()
    let stageContentView: Content? = Content()
    \#(revealMethods)
}

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}

@main struct Main {
    @MainActor static func main() {
        let controller = Controller()
        let content = controller.stageContentView!

        // 用户回合：首个 thinking=true 自动展开并收起重叠面板。
        content.pickerHidden = false
        controller.setResidentThinking(true)
        check(!content.composerHidden, "user-initiated turn reveals the chat")
        check(content.pickerHidden, "user-initiated turn clears the overlapping picker")

        // 后台回合：状态照常更新，但既不展开聊天也不收起用户面板。
        controller.setResidentThinking(false)
        content.collapse()
        content.pickerHidden = false
        let revealsBefore = content.reveals
        controller.setResidentThinking(true, autoRevealsChat: false)
        check(controller.residentChat.isThinking, "background turn still updates thinking state")
        check(content.composerHidden && content.reveals == revealsBefore,
              "background turn never reveals a collapsed chat")
        check(!content.pickerHidden, "background turn never closes the user's panel")

        // 后台回复：照常写入聊天状态，但不抢开。
        controller.finishResidentReply("后台生活记录", autoRevealsChat: false)
        check(controller.residentChat.reply == "后台生活记录" && !controller.residentChat.isThinking,
              "background reply is recorded")
        check(content.composerHidden && content.reveals == revealsBefore,
              "background reply never reveals a collapsed chat")

        // 后台失败：可见状态，但不抢开。
        controller.showResidentChatStatus("后台失败：稍后重试", autoRevealsChat: false)
        check(controller.residentChat.statusNotice == "后台失败：稍后重试" && content.composerHidden,
              "background failure notice is visible without stealing open the chat")

        // 前台失败/回复仍然展开。
        content.collapse()
        controller.showResidentChatStatus("前台失败", autoRevealsChat: true)
        check(!content.composerHidden, "foreground failure reveals the chat for retry")
        content.collapse()
        controller.finishResidentReply("前台回复", autoRevealsChat: true)
        check(!content.composerHidden, "foreground reply reveals the chat")

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\(status): \(checks) background presentation checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-background-presentation-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("Presentation.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("presentation-test")
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
if wiringFailures > 0 { print("FAIL: \(wiringFailures) presentation wiring checks failed") }
exit(testExit == 0 && wiringFailures == 0 ? 0 : 1)
