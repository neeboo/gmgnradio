import AppKit
import Foundation

enum PropGenerationError: Error { case invalidInput }

@main struct ResidentAttachmentTests {
    @MainActor static func main() async throws {
        func check(_ value: Bool) { precondition(value) }
        let image = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/example.png"), displayName: "图片")
        precondition(ResidentChatSubmission(text: "", attachments: [image]).canSend)
        precondition(!ResidentChatSubmission(text: " \n", attachments: []).canSend)
        precondition(ResidentAttachmentPastePolicy.classify(fileURLs: [], hasImage: false) == .text)
        precondition(ResidentAttachmentPastePolicy.classify(fileURLs: [], hasImage: true) == .image)
        precondition(ResidentAttachmentPastePolicy.classify(fileURLs: [URL(fileURLWithPath: "/tmp/a.pdf")], hasImage: true) == .files)
        let rpc = try PrivateRPC(CommandLine.arguments[1])
        let authority = RustChatAttachmentClient(call: rpc.call)
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).appendingPathComponent("resident-images-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let store = ResidentAttachmentStore(directory: directory.appendingPathComponent("store", isDirectory: true), authority: authority, prepare: { _ in png })
        await store.add(urls: (0..<5).map { URL(fileURLWithPath: "/tmp/\($0).png") })
        precondition(store.attachments.count == 4)
        precondition(store.errorMessage != nil)
        let submission = try await store.takeSubmission(text: "")
        let sent = submission.attachments
        precondition(store.attachments.isEmpty)
        check(await store.restoreSubmission(submission))
        precondition(store.attachments == sent)
        let attributes = try FileManager.default.attributesOfItem(atPath: sent[0].url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let failed = ResidentAttachmentStore(directory: directory.appendingPathComponent("failed", isDirectory: true), authority: authority, prepare: { _ in throw CocoaError(.fileReadCorruptFile) })
        await failed.add(urls: [URL(fileURLWithPath: "/tmp/broken.png")])
        precondition(failed.attachments.isEmpty && failed.errorMessage != nil && !failed.isPreparing)
        await store.remove(id: sent[0].id)
        precondition(store.attachments.count == 3)
        precondition(FileManager.default.fileExists(atPath: sent[0].url.path), "submitted image stays available for async jobs")
        let original = directory.appendingPathComponent("original.png")
        try Data([1, 2, 3]).write(to: original)
        let drafts = ResidentAttachmentStore(directory: directory.appendingPathComponent("drafts", isDirectory: true), authority: authority, prepare: { _ in png })
        await drafts.add(urls: [original])
        let draft = drafts.attachments[0]
        await drafts.remove(id: draft.id)
        precondition(!FileManager.default.fileExists(atPath: draft.url.path), "unused draft copy is removed")
        precondition(FileManager.default.fileExists(atPath: original.path), "original image is never removed")
        precondition(FileManager.default.fileExists(atPath: sent[0].url.path), "removing a draft cannot remove an earlier submitted image")
        let firstRecovery = try await store.takeSubmission(text: "first")
        await store.add(imageData: png); await store.add(imageData: png)
        let secondRecovery = try await store.takeSubmission(text: "second")
        check(await store.restoreSubmission(firstRecovery))
        check(await store.restoreSubmission(secondRecovery))
        precondition(store.attachments.count == 5 && !store.canSubmit)
        precondition(!ResidentChatSubmission(text: "hello", attachments: store.attachments).canSend)
        print("PASS: image-only submission, paste classification, four-image limit, failure retention and private file permissions")
    }
}
