import AppKit
import Foundation
import UniformTypeIdentifiers
import ImageIO

/// Explicit human picker/clipboard actions reuse the original image preparation store.
/// Selection creates only private local draft copies, never a model or wish grant.
@MainActor
final class UnityChatImageBridge {
    enum ImageError: Error, LocalizedError {
        case closed, selecting, preparing, staleDraft, emptySubmission
        var errorDescription: String? {
            switch self {
            case .closed: "图片输入会话已结束。"
            case .selecting: "请先选择图片或取消选择。"
            case .preparing: "图片尚在准备，请稍后发送。"
            case .staleDraft: "图片草稿已变化，请确认当前图片后重试。"
            case .emptySubmission: "请填写消息或添加图片；每条消息最多 4 张图片。"
            }
        }
    }
    static let supportedCommands = ["chat.attachments.pick", "chat.attachments.paste", "chat.attachments.pasteIfImage", "chat.attachments.remove"]
    private let store: ResidentAttachmentStore
    private let pasteboard: @MainActor () -> NSPasteboard
    private let parentWindow: @MainActor () -> NSWindow?
    private var generation: UInt64 = 0
    private var panel: NSOpenPanel?
    private var parentCloseObserver: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    private var notice: String?
    private var closed = false
    private var cleaningClosedStore = false
    private var issued: [UUID: ResidentChatSubmission] = [:]
    private var thumbnailCache: [UUID: String] = [:]

    init(directory: URL,
         authority: RustChatAttachmentClient? = nil,
         pasteboard: @escaping @MainActor () -> NSPasteboard = { .general },
         parentWindow: @escaping @MainActor () -> NSWindow? = { UnityWindowModeBridge.shared.targetWindow },
         prepare: @escaping @Sendable (URL) async throws -> Data = { try await PropImagePreparation.prepare(url: $0) }) {
        self.pasteboard = pasteboard
        self.parentWindow = parentWindow
        store = ResidentAttachmentStore(directory:directory,authority:authority,prepare:prepare)
        store.onChange = { [weak self] in
            guard let self else { return }
            generation &+= 1
            if closed { discardUnsentDraft() }
        }
    }
    private var isSelecting: Bool { panel != nil }
    private var isPreparing: Bool { preparation != nil || store.isPreparing }
    private var isBusy: Bool { isSelecting || isPreparing }
    private var busyError: ImageError { isSelecting ? .selecting : .preparing }
    func snapshot() -> [String: Any] {
        let activeIDs = Set(store.attachments.prefix(4).map(\.id))
        thumbnailCache = thumbnailCache.filter { activeIDs.contains($0.key) }
        return ["generation": generation, "attachments": store.attachments.prefix(8).map {
            var value = ["id": $0.id.uuidString, "name": String($0.displayName.prefix(160))]
            if activeIDs.contains($0.id), let preview = thumbnail(for: $0) { value["thumbnailPNG"] = preview }
            return value
        }, "count": store.attachments.count, "maxAttachments": 4,
         "isSelecting": isSelecting, "isPreparing": isPreparing, "canSubmit": !closed && !isBusy && store.canSubmit,
         "error": (notice ?? store.errorMessage).map { String($0.prefix(600)) } as Any? ?? NSNull()]
    }
    private func thumbnail(for image: ResidentImageAttachment) -> String? {
        if let cached = thumbnailCache[image.id] { return cached.isEmpty ? nil : cached }
        thumbnailCache[image.id] = ""
        guard let source = CGImageSourceCreateWithURL(image.url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        for pixelSize in [96, 80] {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        guard encoded.length <= 32 * 1024 else { continue }
        let base64 = (encoded as Data).base64EncodedString()
        thumbnailCache[image.id] = base64
        return base64
        }
        return nil
    }
    @discardableResult
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String, Self.supportedCommands.contains(op) else { return false }
        // A text-field paste must leave ordinary text to Unity's text editor.
        // Only inspect the clipboard in response to the user's paste gesture.
        if op == "chat.attachments.pasteIfImage" {
            let clipboard = pasteboard()
            let urls = (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let imageFiles = urls.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            guard imageFiles || clipboard.availableType(from: [.png, .tiff]) != nil else { return false }
            if isBusy { notice = busyError.localizedDescription; generation &+= 1; return true }
            if store.attachments.count >= 4 { notice = "每条消息最多添加 4 张图片。"; generation &+= 1; return true }
            // True means the image paste was consumed, including preparation
            // failures; no file path should also enter the message text.
            _ = command(["op": "chat.attachments.paste"])
            return true
        }
        guard !isBusy else { notice = busyError.localizedDescription; generation &+= 1; return false }
        notice = nil
        switch op {
        case "chat.attachments.pick":
            guard store.attachments.count < 4 else { notice = "每条消息最多添加 4 张图片。"; generation &+= 1; return false }
            // A standalone panel can remain behind Unity's fullscreen Space.
            // Always attach to its real window; unavailable/busy parents fail
            // visibly instead of leaving an invisible picker and stuck state.
            guard let parent = parentWindow(), parent.isVisible else {
                notice = "未找到聊天窗口，请重新打开聊天后选择图片。"; generation &+= 1; return false
            }
            guard parent.attachedSheet == nil else {
                notice = "请先关闭当前对话框，再选择图片。"; generation &+= 1; return false
            }
            let picker = NSOpenPanel()
            picker.allowedContentTypes = [.image]; picker.allowsMultipleSelection = true
            picker.canChooseDirectories = false; picker.prompt = "添加图片"
            panel = picker; generation &+= 1
            parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelPicker() }
                }
            picker.beginSheetModal(for: parent) { [weak self] response in
                Task { @MainActor [weak self] in
                    guard let self, panel === picker else { return }
                    clearPicker(); generation &+= 1; notice = nil
                    guard !closed, response == .OK else { return }
                    let urls = picker.urls
                    prepareDraft { await $0.add(urls: urls) }
                }
            }
        case "chat.attachments.paste":
            let clipboard = pasteboard()
            let urls = (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let hasImage = clipboard.availableType(from: [.png, .tiff]) != nil
            switch ResidentAttachmentPastePolicy.classify(fileURLs: urls, hasImage: hasImage) {
            case .files: prepareDraft { await $0.add(urls: urls) }
            case .image:
                guard let type = clipboard.availableType(from: [.png, .tiff]),
                      let data = clipboard.data(forType: type) else { return false }
                prepareDraft { await $0.add(imageData: data) }
            case .text:
                notice = "剪贴板中没有图片。"; generation &+= 1; return false
            }
        case "chat.attachments.remove":
            guard let raw = value["id"] as? String, let id = UUID(uuidString: raw),
                  store.attachments.contains(where: { $0.id == id }) else { return false }
            prepareDraft {await $0.remove(id:id)}
        default: return false
        }
        return true
    }

    /// Called only by the AppKit human dragging destination. These methods are
    /// deliberately absent from the JSON command vocabulary: agent messages
    /// cannot nominate local files. The original store owns preparation/copies.
    @discardableResult
    func addDroppedImages(urls: [URL]) -> Bool {
        guard canAcceptDrop() else { return false }
        guard urls.contains(where: ResidentImageFilePolicy.isImageFileURL) else {
            notice = "目前只支持图片附件。"; generation &+= 1; return false
        }
        notice = nil
        prepareDraft { await $0.add(urls: urls) }
        return true
    }
    @discardableResult
    func addDroppedImage(data: Data) -> Bool {
        guard canAcceptDrop() else { return false }
        notice = nil
        prepareDraft { await $0.add(imageData: data) }
        return true
    }
    private func canAcceptDrop() -> Bool {
        if closed { notice = ImageError.closed.localizedDescription }
        else if isBusy { notice = busyError.localizedDescription }
        else if store.attachments.count >= 4 { notice = "每条消息最多添加 4 张图片。" }
        else { return true }
        generation &+= 1
        return false
    }

    /// Host calls this only for the current human chat.send command. The UI sends
    /// IDs and a revision, never arbitrary paths or user-directory access.
    func takeSubmission(text: String, attachmentIDs: [String], generation expected: UInt64) async throws -> ResidentChatSubmission {
        guard !closed else { throw ImageError.closed }
        guard !isBusy else { throw busyError }
        guard expected == generation, attachmentIDs == store.attachments.map({ $0.id.uuidString }) else { throw ImageError.staleDraft }
        guard store.canSubmit, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty else {throw ImageError.emptySubmission}
        let submission = try await store.takeSubmission(text:text)
        guard !closed else {await store.finishSubmission(id:submission.id,state:"cancelled");throw ImageError.closed}
        issued[submission.id] = submission
        return submission
    }
    /// Failed current submissions can recover only images actually issued here.
    @discardableResult
    func restoreSubmission(_ submission: ResidentChatSubmission) async -> Bool {
        guard !closed, let own = issued[submission.id], own == submission else { return false }
        guard await store.restoreSubmission(own) else {return false}
        issued.removeValue(forKey: submission.id)
        return true
    }
    func finishSubmission(id: UUID) async {
        await store.finishSubmission(id:id)
        issued.removeValue(forKey:id)
    }
    func close() {
        guard !closed else { return }
        closed = true; cancelPicker()
        thumbnailCache.removeAll()
        preparation?.cancel(); issued.removeAll()
        discardUnsentDraft(); generation &+= 1
    }
    private func clearPicker() {
        panel = nil
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
    }
    private func cancelPicker() {
        guard let picker = panel else { return }
        clearPicker(); generation &+= 1; notice = nil
        picker.cancel(nil)
    }
    private func prepareDraft(_ action: @escaping @MainActor (ResidentAttachmentStore) async -> Void) {
        generation &+= 1
        preparation = Task { [weak self] in
            guard let self else { return }
            await action(store)
            preparation = nil; generation &+= 1
            if closed { discardUnsentDraft() }
        }
    }
    private func discardUnsentDraft() {
        guard !cleaningClosedStore else { return }
        cleaningClosedStore = true
        Task { [self] in await store.close();cleaningClosedStore = false }
    }
}
