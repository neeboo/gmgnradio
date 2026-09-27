import AppKit
import Foundation

@main struct ResidentAttachmentTests {
    @MainActor static func main() async throws {
        let image = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/example.png"), displayName: "图片")
        precondition(ResidentChatSubmission(text: "", attachments: [image]).canSend)
        precondition(!ResidentChatSubmission(text: " \n", attachments: []).canSend)
        precondition(ResidentAttachmentPastePolicy.classify(fileURLs: [], hasImage: false) == .text)
        precondition(ResidentAttachmentPastePolicy.classify(fileURLs: [], hasImage: true) == .image)
        precondition(ResidentAttachmentPastePolicy.classify(fileURLs: [URL(fileURLWithPath: "/tmp/a.pdf")], hasImage: true) == .files)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resident-images-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResidentAttachmentStore(directory: directory, prepare: { _ in Data([137, 80, 78, 71]) })
        await store.add(urls: (0..<5).map { URL(fileURLWithPath: "/tmp/\($0).png") })
        precondition(store.attachments.count == 4)
        precondition(store.errorMessage != nil)
        let sent = store.takeAttachments()
        precondition(store.attachments.isEmpty)
        store.restore(sent)
        precondition(store.attachments == sent)
        let attributes = try FileManager.default.attributesOfItem(atPath: sent[0].url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let failed = ResidentAttachmentStore(directory: directory, prepare: { _ in throw CocoaError(.fileReadCorruptFile) })
        await failed.add(urls: [URL(fileURLWithPath: "/tmp/broken.png")])
        precondition(failed.attachments.isEmpty && failed.errorMessage != nil && !failed.isPreparing)
        store.remove(id: sent[0].id)
        precondition(store.attachments.count == 3)
        precondition(FileManager.default.fileExists(atPath: sent[0].url.path), "submitted image stays available for async jobs")
        let original = directory.appendingPathComponent("original.png")
        try Data([1, 2, 3]).write(to: original)
        let drafts = ResidentAttachmentStore(directory: directory, prepare: { _ in Data([137, 80, 78, 71]) })
        await drafts.add(urls: [original])
        let draft = drafts.attachments[0]
        drafts.remove(id: draft.id)
        precondition(!FileManager.default.fileExists(atPath: draft.url.path), "unused draft copy is removed")
        precondition(FileManager.default.fileExists(atPath: original.path), "original image is never removed")
        precondition(FileManager.default.fileExists(atPath: sent[0].url.path), "removing a draft cannot remove an earlier submitted image")
        store.restore([image, .init(id: UUID(), url: image.url, displayName: "新增")])
        precondition(store.attachments.count == 5 && !store.canSubmit)
        precondition(!ResidentChatSubmission(text: "hello", attachments: store.attachments).canSend)
        print("PASS: image-only submission, paste classification, four-image limit, failure retention and private file permissions")
    }
}
