// 菜单栏装修入口回归（纯逻辑 + 生产源码合同；无 AppKit/窗口/GPU/权限）。
//
// 覆盖「装修模式找不到」的可发现性修复：
//   1. 菜单里多一条装修入口，位置表达原意（紧跟在「进入空间」后、在「设置」前，
//      且不受电台插件门禁影响 —— 它不是播放器条目）；
//   2. 标题跟着装修状态走：未装修「装修空间」/ 装修中「结束装修」；
//   3. 点「装修空间」一步到位：**先**把空间呈现出来（等价于「进入空间」）**再**进装修；
//   4. 点「结束装修」只退出装修：不重新呈现空间、不关空间窗口；
//   5. 空间还没呈现 / 世界快照还没到时**不静默丢弃**：挂起意图，由既有回调补一次。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func read(_ path: String) throws -> String {
    try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}

func declaration(_ signature: String, in text: String, last: Bool = false) -> String {
    let found = last
        ? text.range(of: signature, options: .backwards)
        : text.range(of: signature)
    guard let start = found?.lowerBound,
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

let appSource = try read("App/GMGNRadioApp.swift")
let controllerSource = try read("VisualEngine/StageWindowController.swift")

// ── 生产接线合同 ────────────────────────────────────────────────────────────
let contentToggle = declaration("func toggleDecorationEditor()", in: controllerSource, last: true)
let pendingReplay = declaration(
    "private func applyPendingDecorationEditorRequest()", in: controllerSource
)
let propEditorToggle = declaration("private func togglePropEditor()", in: controllerSource)
let presentationCallback = declaration(
    "private func applySpatialPresentation(", in: controllerSource
)

let wiringChecks: [(Bool, String)] = [
    (appSource.contains("case toggleDecoration"),
     "the menu entry enum has a decoration entry"),
    (appSource.contains("case .toggleDecoration:"),
     "the menu builder renders the decoration entry"),
    (appSource.contains("AppMenuAction.toggleDecorationEditor.perform(on: appDelegate)"),
     "the menu button routes through AppMenuAction instead of view-local logic"),
    (appSource.contains("StageDecorationMenuTitle.resolve(")
        && appSource.contains("isDecorating: stageDecorationMenu.isDecorating"),
     "the button title is projected from the observed decoration state"),
    (appSource.contains("@StateObject private var stageDecorationMenu = StageDecorationMenuStore.shared"),
     "the menu host observes a source that changes when decoration toggles"),
    (appSource.contains("controller.toggleDecorationEditor()"),
     "AppMenuAction forwards the decoration entry to the app controller"),
    (appSource.contains("func toggleDecorationEditor()"),
     "the app controller protocol/delegate exposes the decoration entry"),
    (controllerSource.contains("var isDecorationEditorOpen: Bool"),
     "the menu can read whether the editor is open"),
    (controllerSource.contains("stageContentView?.toggleDecorationEditor()"),
     "the controller's narrow entry only forwards, it does not reorder window lifecycle"),
    (contentToggle.contains("if residentPropEditor.isOpen"),
     "the content view distinguishes enter-decoration from leave-decoration"),
    (!contentToggle.contains("window?.close")
        && !contentToggle.contains("closeStage")
        && !contentToggle.contains("onCloseHandler"),
     "leaving decoration never closes the space window"),
    (contentToggle.contains("pendingDecorationEditorRequest = true"),
     "a failed open is parked instead of silently dropped"),
    (pendingReplay.contains("spatialStage.isWorldPresentationRequested")
        && pendingReplay.contains("!residentPropEditor.snapshot.worldID.isEmpty"),
     "the parked request waits for both presentation and a world snapshot"),
    (presentationCallback.contains("applyPendingDecorationEditorRequest()"),
     "the existing presentation callback replays the parked request"),
    (controllerSource.contains("residentPropEditor.$snapshot.sink"),
     "a late world snapshot also replays the parked request"),
    (controllerSource.contains("StageDecorationMenuStore.shared.update(isDecorating: open)"),
     "the title source is fed by the single open/close funnel"),
    (propEditorToggle.contains("guard spatialStage.isWorldPresentationRequested else { return }"),
     "the in-window toggle keeps its presentation guard untouched"),
]

let harness = #"""
import Foundation
import Combine

\#(declaration("@MainActor\nfinal class StageDecorationMenuStore", in: appSource))
\#(declaration("enum StageDecorationMenuTitle", in: appSource))
\#(declaration("enum SystemResidentMenuEntry:", in: appSource))
\#(declaration("enum SystemResidentMenuPolicy", in: appSource))
\#(declaration("struct StageDecorationEntryAction", in: appSource))

@main
@MainActor
struct Main {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(label)") }
        }

        let pluginOff = SystemResidentMenuPolicy.entries(isRadioPluginEnabled: false)
        let pluginOn = SystemResidentMenuPolicy.entries(isRadioPluginEnabled: true)

        // 1) 条目位置表达原意：装修入口紧跟「进入空间」，排在「设置」之前。
        check(pluginOff == [.showLiveCam, .enterSpace, .toggleDecoration, .settings, .quit],
              "gate off keeps the space group plus settings and quit, with decoration inside the space group")
        check(pluginOn == [.showLiveCam, .enterSpace, .toggleDecoration, .openPlayer, .settings, .quit],
              "gate on restores every previous entry in its original order and inserts decoration after enter-space")
        for entries in [pluginOff, pluginOn] {
            let space = entries.firstIndex(of: .enterSpace)
            let decoration = entries.firstIndex(of: .toggleDecoration)
            let settings = entries.firstIndex(of: .settings)
            check(decoration != nil, "the decoration entry exists in the menu")
            check(space != nil && decoration == space.map { $0 + 1 },
                  "the decoration entry sits right after enter-space")
            check(decoration != nil && settings != nil && decoration! < settings!,
                  "the decoration entry stays above the settings divider")
        }

        // 2) 标题跟着状态走。
        check(StageDecorationMenuTitle.resolve(isDecorating: false) == "装修空间",
              "not decorating reads as enter decoration")
        check(StageDecorationMenuTitle.resolve(isDecorating: true) == "结束装修",
              "decorating reads as leave decoration")

        // 3) 标题的状态源一开始是「未装修」，并且只反映最后一次状态。
        check(StageDecorationMenuStore.shared.isDecorating == false,
              "the menu starts on the enter-decoration title")
        StageDecorationMenuStore.shared.update(isDecorating: true)
        check(StageDecorationMenuStore.shared.isDecorating,
              "opening the editor flips the title source")
        StageDecorationMenuStore.shared.update(isDecorating: true)
        check(StageDecorationMenuStore.shared.isDecorating,
              "repeating the same state cannot double-toggle the title")
        StageDecorationMenuStore.shared.update(isDecorating: false)
        check(!StageDecorationMenuStore.shared.isDecorating,
              "closing the editor flips the title source back")

        // 4) 一步到位：先呈现空间，再进装修；结束装修不重新呈现空间。
        var isDecorating = false
        var isWorldPresented = false
        var calls: [String] = []
        let action = StageDecorationEntryAction(
            isDecorationEditorOpen: { isDecorating },
            showStage: {
                calls.append("showStage")
                isWorldPresented = true
            },
            toggleDecorationEditor: {
                calls.append("toggleDecorationEditor(worldPresented: \(isWorldPresented))")
                isDecorating.toggle()
            }
        )

        action.perform()
        check(calls == ["showStage", "toggleDecorationEditor(worldPresented: true)"],
              "one click presents the space first and only then enters decoration")
        check(isDecorating, "the first click enters decoration mode")

        action.perform()
        check(calls == [
            "showStage",
            "toggleDecorationEditor(worldPresented: true)",
            "toggleDecorationEditor(worldPresented: true)",
        ], "leaving decoration does not present or re-show the space again")
        check(!isDecorating, "the second click leaves decoration mode")

        action.perform()
        check(calls.count == 5 && calls[3] == "showStage",
              "re-entering decoration presents the space again, then opens the editor")

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\(status): \(checks) decoration menu checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-stage-decoration-menu-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("StageDecorationMenu.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("stage-decoration-menu-test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("FAIL: the decoration menu harness did not compile against the production declarations")
    exit(compile.terminationStatus)
}

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
if wiringFailures > 0 { print("FAIL: \(wiringFailures) decoration menu wiring checks failed") }
exit(testExit == 0 && wiringFailures == 0 ? 0 : 1)
