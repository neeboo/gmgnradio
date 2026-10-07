import AppKit
import Foundation
import ImageIO

enum PropGenerationError: Error { case invalidInput }

@main struct UnityChatImageDropChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-drop-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = directory.appendingPathComponent("human.png")
        try png.write(to: image)
        let unsupported = directory.appendingPathComponent("unsupported.txt")
        let bridge = UnityChatImageBridge(directory: directory.appendingPathComponent("drafts"), parentWindow: { nil })
        defer { bridge.close() }
        func count() -> Int { bridge.snapshot()["count"] as! Int }
        func ready() async throws {
            let deadline = Date().addingTimeInterval(5)
            while bridge.snapshot()["isPreparing"] as! Bool {
                precondition(Date() < deadline, "Drop preparation must finish")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let initial = bridge.snapshot()["generation"] as! UInt64
        precondition(!bridge.addDroppedImages(urls: [unsupported]))
        precondition(bridge.snapshot()["error"] as? String == "目前只支持图片附件。")
        precondition(count() == 0 && !(bridge.snapshot()["isPreparing"] as! Bool))
        precondition(bridge.snapshot()["generation"] as! UInt64 > initial)
        precondition(!bridge.command(["op": "chat.attachments.drop", "urls": [image.absoluteString]]), "No JSON local path admission")
        precondition(bridge.addDroppedImages(urls: [image]))
        precondition(bridge.snapshot()["isPreparing"] as! Bool)
        precondition(!(bridge.snapshot()["isSelecting"] as! Bool))
        precondition(!bridge.addDroppedImage(data: png), "Reentrant drag is rejected")
        precondition(bridge.snapshot()["error"] as? String == "图片尚在准备，请稍后发送。")
        try await ready()
        precondition(count() == 1)
        let entries = bridge.snapshot()["attachments"] as! [[String: String]]
        precondition(entries[0]["name"] == "human.png" && entries[0]["thumbnailPNG"] != nil)
        let submission = try bridge.takeSubmission(text: "", attachmentIDs: entries.map { $0["id"]! }, generation: bridge.snapshot()["generation"] as! UInt64)
        let copy = submission.attachments[0].url
        precondition(copy != image && copy.path.hasPrefix(directory.path))
        precondition(CGImageSourceCreateWithURL(copy as CFURL, nil) != nil)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        precondition(bridge.restoreSubmission(submission))
        precondition(bridge.addDroppedImages(urls: [image, unsupported]))
        try await ready()
        precondition(count() == 2 && bridge.snapshot()["error"] as? String == "目前只支持图片附件。", "Mixed drops retain valid image and expose unsupported file")
        precondition(bridge.addDroppedImage(data: png)); try await ready()
        precondition(count() == 3)
        precondition(bridge.addDroppedImages(urls: [image, image])); try await ready()
        precondition(count() == 4 && bridge.snapshot()["error"] as? String == "每条消息最多添加 4 张图片。")
        precondition(!bridge.addDroppedImage(data: png))
        precondition(!bridge.addDroppedImages(urls: [image]))
        precondition(count() == 4 && bridge.snapshot()["error"] as? String == "每条消息最多添加 4 张图片。")
        bridge.close()
        precondition(count() == 0)
        precondition(!bridge.addDroppedImage(data: png) && !bridge.addDroppedImages(urls: [image]))
        precondition(bridge.snapshot()["error"] as? String == "图片输入会话已结束。")
        precondition(FileManager.default.fileExists(atPath: copy.path), "Already issued copy remains available to its async submission")

        let closing = UnityChatImageBridge(directory: directory.appendingPathComponent("closing"), parentWindow: { nil }, prepare: { url in
            try await Task.sleep(for: .milliseconds(80))
            return try await PropImagePreparation.prepare(url: url)
        })
        precondition(closing.addDroppedImages(urls: [image]))
        closing.close()
        let deadline = Date().addingTimeInterval(5)
        while closing.snapshot()["isPreparing"] as! Bool {
            precondition(Date() < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(closing.snapshot()["count"] as! Int == 0, "Late preparation after close cannot resurrect draft")
        print("PASS: human-only file/bitmap drops, real private PNG copy/preview, unsupported/mixed payloads, reentrant preparation guard, four-image cap, close and late completion cleanup")
    }
}
