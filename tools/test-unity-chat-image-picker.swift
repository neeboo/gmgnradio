import AppKit
import Foundation

enum PropGenerationError: Error { case invalidInput }

/// Compile with the production attachment store, preparation, image bridge and
/// window bridge. Only temporary windows and cancellation are exercised; no
/// image is selected, prepared, uploaded or read.
@main struct UnityChatImagePickerChecks {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await checks()
                print("PASS: real attached visible AppKit image sheet, selection/preparation split, duplicate/send guards, cancel/reopen, close cleanup and missing/busy parent errors")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        application.run()
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "PickerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "AppKit sheet state timed out"]) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func checks() async throws {
        let rpc = try PrivateRPC(CommandLine.arguments[1])
        let authority = RustChatAttachmentClient(call: rpc.call)
        let directory = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("gmgn-picker-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 440, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.title = "Temporary image picker regression"
        parent.orderFront(nil)
        defer { parent.close() }
        let bridge = UnityChatImageBridge(directory: directory, authority: authority, parentWindow: { parent }, prepare: { _ in
            preconditionFailure("Cancellation regression must never prepare/read an image")
        })
        defer { bridge.close() }
        let pick = ["op": "chat.attachments.pick"]
        precondition(bridge.command(pick))
        try await wait { parent.attachedSheet is NSOpenPanel && parent.attachedSheet?.isVisible == true }
        let first = parent.attachedSheet as! NSOpenPanel
        precondition(first.sheetParent === parent, "Picker belongs to its real parent window")
        precondition(bridge.snapshot()["isSelecting"] as! Bool)
        precondition(!(bridge.snapshot()["isPreparing"] as! Bool))
        precondition(!(bridge.snapshot()["canSubmit"] as! Bool))
        precondition(!bridge.command(pick))
        precondition(parent.attachedSheet === first)
        precondition(bridge.snapshot()["error"] as? String == "请先选择图片或取消选择。")
        do {
            _ = try await bridge.takeSubmission(text: "hello", attachmentIDs: [], generation: bridge.snapshot()["generation"] as! UInt64)
            preconditionFailure("Submission during selection must be blocked")
        } catch UnityChatImageBridge.ImageError.selecting { }
        first.cancel(nil)
        try await wait { !(bridge.snapshot()["isSelecting"] as! Bool) && parent.attachedSheet == nil }
        precondition(bridge.snapshot()["canSubmit"] as! Bool)
        precondition(bridge.snapshot()["error"] is NSNull)
        precondition(bridge.command(pick))
        try await wait { parent.attachedSheet is NSOpenPanel }
        let second = parent.attachedSheet!
        precondition(second !== first)
        bridge.close()
        try await wait { parent.attachedSheet == nil }
        precondition(!(bridge.snapshot()["isSelecting"] as! Bool))
        precondition(!(bridge.snapshot()["isPreparing"] as! Bool))
        precondition(!bridge.command(pick))

        let missing = UnityChatImageBridge(directory: directory.appendingPathComponent("missing"), authority: authority, parentWindow: { nil })
        precondition(!missing.command(pick))
        precondition(!(missing.snapshot()["isSelecting"] as! Bool))
        precondition(missing.snapshot()["error"] as? String == "未找到聊天窗口，请重新打开聊天后选择图片。")
        missing.close()

        let busySheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.beginSheet(busySheet, completionHandler: { _ in })
        let busy = UnityChatImageBridge(directory: directory.appendingPathComponent("busy"), authority: authority, parentWindow: { parent })
        precondition(!busy.command(pick))
        precondition(!(busy.snapshot()["isSelecting"] as! Bool))
        precondition(busy.snapshot()["error"] as? String == "请先关闭当前对话框，再选择图片。")
        busy.close(); parent.endSheet(busySheet); busySheet.orderOut(nil)
        try await wait { parent.attachedSheet == nil }

        let closing = UnityChatImageBridge(directory: directory, parentWindow: { parent })
        precondition(closing.command(pick))
        try await wait { parent.attachedSheet is NSOpenPanel }
        parent.close()
        try await wait { !(closing.snapshot()["isSelecting"] as! Bool) && parent.attachedSheet == nil }
        precondition(!(closing.snapshot()["isPreparing"] as! Bool))
        closing.close()
    }
}
