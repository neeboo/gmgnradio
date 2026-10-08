import AppKit
import Foundation
import ImageIO

// Error sentinel only; production preparation and attachment store compile unchanged.
enum PropGenerationError: Error { case invalidInput }

@main struct UnityChatImageChecks {
    @MainActor static func main() async throws {
        func check(_ value: Bool) { precondition(value) }
        let rpc = try PrivateRPC(CommandLine.arguments[1])
        let authority = RustChatAttachmentClient(call: rpc.call)
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).appendingPathComponent("unity-chat-images-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = NSPasteboard(name: .init("unity-chat-test-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let bridge = UnityChatImageBridge(directory: directory, authority: authority, pasteboard: { clipboard })
        func snapshot() -> (UInt64, [String]) {
            let value = bridge.snapshot()
            let images = value["attachments"] as! [[String: String]]
            precondition(!String(describing: value).contains(directory.path), "UI projection contains no private paths")
            return (value["generation"] as! UInt64, images.map { $0["id"]! })
        }
        let initial = snapshot(); precondition(initial.1.isEmpty)
        clipboard.clearContents(); clipboard.setString("普通文字 /tmp/example.png", forType: .string)
        precondition(!bridge.command(["op": "chat.attachments.pasteIfImage"]))
        precondition(snapshot().0 == initial.0 && bridge.snapshot()["error"] is NSNull,
            "Text paste and typed paths must not mutate attachment state or show an error")
        clipboard.clearContents(); clipboard.setData(png, forType: .png)
        precondition(bridge.command(["op": "chat.attachments.pasteIfImage"]))
        precondition(bridge.snapshot()["isPreparing"] as! Bool)
        precondition(bridge.command(["op": "chat.attachments.pasteIfImage"]), "Preparing image paste remains consumed")
        do { _ = try await bridge.takeSubmission(text: "", attachmentIDs: [], generation: initial.0); preconditionFailure() }
        catch UnityChatImageBridge.ImageError.preparing { }
        while bridge.snapshot()["isPreparing"] as! Bool { try await Task.sleep(for: .milliseconds(10)) }
        let ready = snapshot(); precondition(ready.1.count == 1)
        let preview = (bridge.snapshot()["attachments"] as! [[String: String]])[0]["thumbnailPNG"]!
        let thumbnailData = Data(base64Encoded: preview)!
        precondition(thumbnailData.count <= 32768)
        let thumbnailSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil)!
        let thumbnailImage = CGImageSourceCreateImageAtIndex(thumbnailSource, 0, nil)!
        precondition(thumbnailImage.width <= 96 && thumbnailImage.height <= 96)
        precondition((bridge.snapshot()["attachments"] as! [[String: String]])[0]["thumbnailPNG"] == preview)
        do { _ = try await bridge.takeSubmission(text: "", attachmentIDs: ready.1, generation: initial.0); preconditionFailure() }
        catch UnityChatImageBridge.ImageError.staleDraft { }
        do { _ = try await bridge.takeSubmission(text: "", attachmentIDs: [UUID().uuidString], generation: ready.0); preconditionFailure() }
        catch UnityChatImageBridge.ImageError.staleDraft { }
        let submission = try await bridge.takeSubmission(text: "", attachmentIDs: ready.1, generation: ready.0)
        precondition(submission.canSend && snapshot().1.isEmpty)
        let data = try Data(contentsOf: submission.attachments[0].url)
        precondition(data.count <= 8 * 1024 * 1024 && CGImageSourceCreateWithData(data as CFData, nil) != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: submission.attachments[0].url.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        check(!(await bridge.restoreSubmission(.init(text: "", attachments: submission.attachments))))
        check(await bridge.restoreSubmission(submission)); check(!(await bridge.restoreSubmission(submission)))
        precondition(bridge.command(["op": "chat.attachments.remove", "id": ready.1[0]]))
        while bridge.snapshot()["isPreparing"] as! Bool { try await Task.sleep(for: .milliseconds(10)) }
        precondition(snapshot().1.isEmpty)
        precondition(FileManager.default.fileExists(atPath: submission.attachments[0].url.path), "issued file remains valid for async jobs")
        clipboard.clearContents(); clipboard.writeObjects([submission.attachments[0].url as NSURL])
        precondition(bridge.command(["op": "chat.attachments.pasteIfImage"]), "Copied image file is an attachment")
        while bridge.snapshot()["isPreparing"] as! Bool { try await Task.sleep(for: .milliseconds(10)) }
        let filePaste = snapshot(); precondition(filePaste.1.count == 1)
        precondition(bridge.command(["op": "chat.attachments.remove", "id": filePaste.1[0]]))
        while bridge.snapshot()["isPreparing"] as! Bool { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<5 {
            _ = bridge.command(["op": "chat.attachments.paste"])
            while bridge.snapshot()["isPreparing"] as! Bool { try await Task.sleep(for: .milliseconds(10)) }
        }
        precondition(snapshot().1.count == 4)
        precondition(bridge.command(["op": "chat.attachments.pasteIfImage"]), "Full image draft consumes paste without inserting a path")
        precondition(snapshot().1.count == 4)
        clipboard.clearContents(); clipboard.setString("仍然可以粘贴文字", forType: .string)
        let full = snapshot()
        precondition(!bridge.command(["op": "chat.attachments.pasteIfImage"]))
        precondition(snapshot().0 == full.0, "Full image draft leaves ordinary text paste untouched")
        bridge.close()
        let closeDeadline = Date().addingTimeInterval(8)
        while !snapshot().1.isEmpty {
            precondition(Date() < closeDeadline, "Rust close receipt must clear the draft")
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(snapshot().1.isEmpty)
        precondition(!bridge.command(["op": "chat.attachments.paste"]))
        precondition(FileManager.default.fileExists(atPath: submission.attachments[0].url.path))
        print("PASS: explicit private clipboard, real PNG preparation, image-only send, revision/ID rejection, own recovery, four-image limit and cleanup")
    }
}
