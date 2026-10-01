// Hostless red/green checks for the 系统消息 window: the promised interactions
// (single click selects, double-click and 「打开」 mark read through onOpenEntry,
// the unread dot follows `isRead`, selection survives a snapshot push) are driven
// through REAL AppKit events against the production window controller, plus
// source pins for the pieces that only exist between the window and the app
// (the open wiring, the dot field, the read write point, and the activation that
// makes the window key at all).
//
// 真机缺陷：app 是 LSUIElement（accessory），系统消息又多半从 LiveCam 那块
// `.nonactivatingPanel` 上打开；`openSystemInbox()` 只做 `showWindow` +
// `makeKeyAndOrderFront` 而不激活 app，窗口会被排到最前却**不是** key window ——
// 标题栏是灰的、「打开」这个默认按钮是灰的、列表点了没有选中态，于是"双击或按
// 「打开」标记为已读"整条承诺都不发生（taskd 里那几条消息永远没有 readAt）。
// 因此这里既实测窗口行为，也把"开窗前先激活"钉成断言。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { fatalError("missing \(signature)") }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced declaration \(signature)")
}

let ui = try read("Presence/ResidentSystemInboxUI.swift")
let app = try read("App/GMGNRadioApp.swift")
var failures = 0
func check(_ result: Bool, _ label: String) {
    if !result { failures += 1; print("FAIL: \(label)") }
}

// MARK: - Source pins (the parts a window harness cannot reach)

let openSystemInbox = declaration("private func openSystemInbox()", in: app)
check(openSystemInbox.contains("NSApplication.shared.activate(ignoringOtherApps: true)"),
    "opening the system message window must activate the accessory app, or the window is never key")
if let activation = openSystemInbox.range(of: "activate(ignoringOtherApps: true)"),
   let presented = openSystemInbox.range(of: "showWindow(") {
    check(activation.lowerBound < presented.lowerBound,
        "the window is activated before it is shown, so the first click lands on a key window")
}
check(openSystemInbox.contains("controller.onOpenEntry ="), "the window's open handler is wired at creation")
let openHandler = declaration("controller.onOpenEntry = { [weak self] row in", in: app)
check(openHandler.contains("markRead(taskKey: taskKey") && openHandler.contains("worldID: worldID")
        && openHandler.contains("residentScope: context.sessionScope"),
    "打开/双击 reaches the durable markRead for this entry's own scope, never a background ACK")
check(app.contains("isRead: entry.isRead"), "the list row carries the entry's persisted read state")
check(ui.contains("let dot = NSTextField(labelWithString: row.isRead ? \" \" : \"●\")"),
    "the blue dot is driven by isRead alone")
check(ui.contains("tableView.doubleAction = #selector(openSelected)"),
    "double-click opens the message")
check(ui.contains("openButton.action = #selector(openSelected)"), "the 打开 button opens the message")
check(ui.contains("openButton.isEnabled = selectedRowID != nil"),
    "打开 is enabled exactly when a row is selected")
check(!ui.contains("markRead"), "the window itself never writes read state; only the app's open handler does")

// MARK: - Real AppKit behaviour

let harness = #"""
import AppKit

@main struct Tests {
    @MainActor static func main() {
        var checks = 0, failures = 0, finished = false
        func check(_ condition: Bool, _ text: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(text)") }
        }
        func finish() {
            guard !finished else { return }
            finished = true
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) system message window checks, \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        // A harness must never hang the suite: never click a non-key window
        // (AppKit's row tracking waits for events there) and always finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            check(false, "the system message window checks did not finish in time")
            finish()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = ResidentSystemInboxWindowController()
        var opened: [String] = []
        controller.onOpenEntry = { row in opened.append(row.id) }
        guard let window = controller.window, let content = window.contentView else {
            check(false, "the system message window exists"); finish(); return
        }
        let now = Date()
        func rows() -> [ResidentSystemInboxWindowController.Row] { (1...4).map {
            .init(id: "t\($0)", title: "斧头\($0)", status: "已摆放", detail: "detail \($0)",
                  isRead: false, updatedAt: now.addingTimeInterval(Double(-$0))) } }
        controller.reload(rows())
        window.setContentSize(NSSize(width: 720, height: 460))
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.alphaValue = 0          // headless harness: never display anything
        let table = controller.probeTableView
        let button = controller.probeOpenButton
        let placeholder = controller.probeDetailPlaceholder
        let detail = controller.probeDetailText

        func cell(_ row: Int) -> NSView {
            content.layoutSubtreeIfNeeded()
            return table.view(atColumn: 0, row: row, makeIfNecessary: true)!
        }
        func post(_ type: NSEvent.EventType, _ row: Int, clickCount: Int, number: Int) {
            let point = cell(row).convert(NSPoint(x: cell(row).bounds.midX, y: cell(row).bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: number, clickCount: clickCount,
                pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        func click(_ row: Int) { post(.leftMouseDown, row, clickCount: 1, number: 11); post(.leftMouseUp, row, clickCount: 1, number: 21) }
        func dot(_ row: Int) -> String {
            content.layoutSubtreeIfNeeded()
            return cell(row).subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? ""
        }

        app.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        func afterWindowIsKey(_ body: @escaping @MainActor () -> Void, attempts: Int = 20) {
            if window.isKeyWindow { body(); return }
            if attempts == 0 {
                check(false, "the system message window becomes the key window as soon as it is shown")
                finish(); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { afterWindowIsKey(body, attempts: attempts - 1) }
        }

        afterWindowIsKey {
            // A real user clicks a window that has finished activating: give the
            // activation transition a beat so the first click is not consumed by it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                check(window.isKeyWindow, "the shown system message window is key, so its controls are live")
                check(table.numberOfRows == 4, "every inbox entry has a row")
                check(!button.isEnabled, "打开 starts disabled with nothing selected")
                check(!placeholder.isHidden, "the instruction is shown until a message is selected")
                check(dot(0) == "●", "an unread entry shows its blue dot")

                click(0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    check(table.selectedRow == 0, "a single click selects the clicked message")
                    check(button.isEnabled, "打开 becomes available once a message is selected")
                    check(placeholder.isHidden, "selecting a message replaces the instruction with its content")
                    check(!detail.string.isEmpty && detail.string.contains("detail 1"),
                        "the selected message's full content is shown")

                    // Snapshot pushes must not drop the selection (that is what makes
                    // "select, then press 打开" impossible on a real machine).
                    controller.reload(rows())
                    check(table.selectedRow == 0 && button.isEnabled && placeholder.isHidden,
                        "a repaint (snapshot push) keeps the selected unread message selected")

                    // Double-click: AppKit dispatches exactly this action.
                    click(2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        check(table.selectedRow == 2, "the double-clicked message is the selected one")
                        table.sendAction(table.doubleAction!, to: table.target)
                        check(opened == ["t3"], "double-click opens (marks read) the selected message")
                        button.performClick(nil)
                        check(opened == ["t3", "t3"], "pressing 打开 opens the selected message")

                        // Marking read must clear the dot and keep the selection.
                        let read = rows().map { row -> ResidentSystemInboxWindowController.Row in
                            .init(id: row.id, title: row.title, status: row.status, detail: row.detail,
                                  isRead: true, updatedAt: row.updatedAt)
                        }
                        controller.reload(read)
                        check(dot(2) == " ", "a read message loses its blue dot")
                        check(table.selectedRow == 2 && button.isEnabled,
                            "the read message stays selected, so a second message can be opened next")
                        finish()
                    }
                }
            }
        }
        app.run()
    }
}

extension ResidentSystemInboxWindowController {
    var probeTableView: NSTableView { tableView }
    var probeOpenButton: NSButton { openButton }
    var probeDetailPlaceholder: NSTextField { detailPlaceholder }
    var probeDetailText: NSTextView { detailText }
}
"""#
// AppKit needs the run loop; the extension above is appended to the real source
// file on purpose so its private members stay reachable.

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-system-inbox-window-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let combined = temporary.appendingPathComponent("Sources.swift")
try (ui + "\n" + harness).write(to: combined, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("system-inbox-window")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-parse-as-library", combined.path, "-o", executable.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { print("FAIL: the system message window harness did not compile"); exit(1) }

let test = Process()
test.executableURL = executable
try test.run()
test.waitUntilExit()
if failures > 0 { exit(1) }
exit(test.terminationStatus)
