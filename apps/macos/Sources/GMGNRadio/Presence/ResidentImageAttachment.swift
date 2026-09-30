import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// **居民图片链[1] 附件**：用户给的图片到底有没有真的进草稿。
///
/// 图片收不到时，第一个可能断掉的地方就是这里：点击「+」选的、粘贴的、或从
/// 访达拖进来的图片，如果从来没有成为 `ResidentImageAttachment`，后面整条链
/// （提交 → 轮次 → 两道判据 → ACP 线）根本不会被走到，日志里也不会有任何
/// 图片相关记录 —— 与「判据失败」长得一模一样。所以这里把**每一个**接入与
/// 拒绝都写出来，带确切原因（不是 UI 文案）。
///
/// 常驻诊断，限流 24 条/进程：这些都是用户动作触发的低频事件。
@MainActor
private enum ResidentImageChainLog {
    static let log = Logger(subsystem: "ai.gmgn.radio", category: "ResidentImageTransport")
    private static var budget = 24
    static func note(_ message: String) {
        guard budget > 0 else { return }
        budget -= 1
        log.notice("\(message, privacy: .public)")
    }
    static func failure(_ message: String) {
        guard budget > 0 else { return }
        budget -= 1
        log.error("\(message, privacy: .public)")
    }
}

struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let displayName: String
}

struct ResidentChatSubmission: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let text: String
    var attachments: [ResidentImageAttachment]
    init(text: String, attachments: [ResidentImageAttachment] = [], id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.attachments = attachments
    }
    var canSend: Bool { attachments.count <= 4 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
}

/// A small draft-only recovery buffer, shared by both chat surfaces. The original
/// submission date survives delayed failures; callback order does not reorder a conversation.
struct ResidentDraftRecovery {
    private var restored: [ResidentChatSubmission] = []
    private var renderedPrefix: String? = ""

    mutating func restore(_ submission: ResidentChatSubmission, text: String, attachments: [ResidentImageAttachment]) -> (text: String, attachments: [ResidentImageAttachment]) {
        guard !restored.contains(where: { $0.id == submission.id }) else { return (text, attachments) }
        let earliest = restored.first?.createdAt
        var untouchedDraft: String?
        if let prefix = renderedPrefix {
            if prefix.isEmpty { untouchedDraft = text }
            else if text == prefix { untouchedDraft = "" }
            else if text.hasPrefix(prefix + "\n") { untouchedDraft = String(text.dropFirst(prefix.count + 1)) }
        }
        restored.append(submission)
        restored.sort {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        let resultText: String
        if let untouchedDraft {
            let prefix = restored.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            resultText = [prefix, untouchedDraft].filter { !$0.isEmpty }.joined(separator: "\n")
            renderedPrefix = prefix
        } else {
            // The user edited the recovered text. Preserve that entire edit rather
            // than rebuilding it from stale submissions; place this new failure beside it.
            let segments = earliest.map { submission.createdAt < $0 } == true ? [submission.text, text] : [text, submission.text]
            resultText = segments.filter { !$0.isEmpty }.joined(separator: "\n")
            renderedPrefix = nil
        }
        let available = attachments + submission.attachments.filter { image in !attachments.contains { $0.id == image.id } }
        let restoredImages = restored.flatMap(\.attachments)
        var ordered: [ResidentImageAttachment] = []
        for image in restoredImages where available.contains(where: { $0.id == image.id }) && !ordered.contains(where: { $0.id == image.id }) {
            ordered.append(image)
        }
        ordered += available.filter { image in !ordered.contains { $0.id == image.id } }
        return (resultText, ordered)
    }
}

enum ResidentAttachmentPastePolicy {
    enum Content { case text, image, files }
    static func classify(fileURLs: [URL], hasImage: Bool) -> Content {
        if !fileURLs.isEmpty { return .files }
        return hasImage ? .image : .text
    }
}

enum ResidentTextInputPolicy {
    static func shouldApplyExternalText(
        fieldText: String,
        externalText: String,
        isComposing: Bool
    ) -> Bool {
        !isComposing && fieldText != externalText
    }

    static func shouldSubmit(isComposing: Bool) -> Bool {
        !isComposing
    }
}

@MainActor
final class ResidentAttachmentStore: ObservableObject {
    @Published private(set) var attachments: [ResidentImageAttachment] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    var onChange: @MainActor () -> Void = {}
    private let directory: URL
    private let prepare: @Sendable (URL) async throws -> Data
    private var unsentCopies: [UUID: URL] = [:]
    var canSubmit: Bool { !isPreparing && attachments.count <= 4 }

    init(directory: URL? = nil, prepare: @escaping @Sendable (URL) async throws -> Data = { try await PropImagePreparation.prepare(url: $0) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/ResidentAttachments", isDirectory: true)
        self.prepare = prepare
    }

    func add(urls: [URL]) async {
        guard !isPreparing else { return }
        isPreparing = true; errorMessage = nil; onChange()
        defer { isPreparing = false; onChange() }
        let source = urls.count == 1 ? "单个文件/粘贴文件" : "\(urls.count) 个文件"
        ResidentImageChainLog.note(
            "居民图片链[1] 附件接入 来源=\(source) 当前草稿张数=\(attachments.count)"
        )
        for url in urls {
            guard attachments.count < 4 else {
                errorMessage = "每条消息最多添加 4 张图片。"
                ResidentImageChainLog.failure("居民图片链[1] 附件被拒 原因=草稿已满4张 文件=\(url.lastPathComponent)")
                break
            }
            guard url.isFileURL, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                errorMessage = "目前只支持图片附件。"
                ResidentImageChainLog.failure(
                    "居民图片链[1] 附件被拒 原因=不是图片或不是文件URL 是文件URL=\(url.isFileURL) 扩展名=\(url.pathExtension) 文件=\(url.lastPathComponent)"
                )
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await prepare(url)
                guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let id = UUID()
                let destination = directory.appendingPathComponent("\(id.uuidString).png")
                try writePrivate(data, to: destination)
                attachments.append(.init(id: id, url: destination, displayName: url.lastPathComponent))
                unsentCopies[id] = destination
                ResidentImageChainLog.note(
                    "居民图片链[1] 附件就绪 名称=\(url.lastPathComponent) 归一化格式=png 归一化字节=\(data.count) 草稿张数=\(attachments.count) 落盘=\(destination.path)"
                )
            } catch {
                errorMessage = "图片无法读取，请换一张图片。原有附件已保留。"
                // 确切错误类型与文案，绝不只有 UI 文案：真机上就是靠这一行区分
                // 「解码失败」「体积超限」「安全作用域读不到」。
                ResidentImageChainLog.failure(
                    "居民图片链[1] 附件准备失败 文件=\(url.lastPathComponent) 错误类型=\(String(describing: type(of: error))) 错误文案=\(error.localizedDescription) 完整=\(String(describing: error))"
                )
            }
        }
    }

    func add(imageData: Data) async {
        guard !isPreparing else { return }
        guard imageData.count <= 64 * 1024 * 1024 else {
            errorMessage = "这张图片过大，请先缩小图片。"; onChange(); return
        }
        let source = directory.appendingPathComponent("paste-\(UUID().uuidString).png")
        do {
            try writePrivate(imageData, to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            ResidentImageChainLog.note("居民图片链[1] 附件接入 来源=剪贴板位图 字节=\(imageData.count)")
            await add(urls: [source])
        } catch {
            errorMessage = "无法保存粘贴的图片。"; onChange()
            ResidentImageChainLog.failure(
                "居民图片链[1] 附件准备失败 来源=剪贴板位图 错误类型=\(String(describing: type(of: error))) 错误文案=\(error.localizedDescription)"
            )
        }
    }

    func remove(id: UUID) {
        // Only discard our own never-submitted draft copies. A submitted image can
        // still be referenced by an asynchronous wish job after it leaves the UI.
        if let copy = unsentCopies.removeValue(forKey: id),
           copy == directory.appendingPathComponent("\(id.uuidString).png") {
            try? FileManager.default.removeItem(at: copy)
        }
        attachments.removeAll { $0.id == id }
        onChange()
    }
    func takeAttachments() -> [ResidentImageAttachment] {
        let result = attachments
        for image in result { unsentCopies.removeValue(forKey: image.id) }
        attachments = []; onChange()
        ResidentImageChainLog.note(
            "居民图片链[1] 提交取走附件 张数=\(result.count) 文件=[\(result.map(\.url.lastPathComponent).joined(separator: ","))] 名称=[\(result.map(\.displayName).joined(separator: ","))]"
        )
        return result
    }

    func restore(_ images: [ResidentImageAttachment]) {
        attachments = images + attachments.filter { image in !images.contains { $0.id == image.id } }
        if attachments.count > 4 { errorMessage = "失败消息的图片已保留；每条消息最多 4 张，请移除多余图片后发送。" }
        onChange()
        ResidentImageChainLog.note(
            "居民图片链[1] 失败回填附件 回填=\(images.count) 回填后草稿张数=\(attachments.count)"
        )
    }
    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加图片"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in await self?.add(urls: panel.urls) }
        }
    }
    /// Called exclusively from an explicit paste action, never during rendering or initialization.
    func paste(from pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let hasImage = pasteboard.availableType(from: [.png, .tiff]) != nil
        switch ResidentAttachmentPastePolicy.classify(fileURLs: urls, hasImage: hasImage) {
        case .text:
            // 「我粘贴了却没反应」必须留下痕迹：这一行证明粘贴动作确实到了附件层，
            // 只是剪贴板里没有图片（既没有图片文件，也没有 PNG/TIFF 位图）。
            ResidentImageChainLog.note(
                "居民图片链[1] 粘贴未接入 原因=剪贴板里没有图片 文件URL数=\(urls.count) 有PNG或TIFF位图=false 类型=[\(pasteboard.types?.map(\.rawValue).prefix(6).joined(separator: ",") ?? "")]"
            )
            return false
        case .files: Task { await add(urls: urls) }
        case .image:
            guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { return false }
            Task { await add(imageData: data) }
        }
        return true
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
struct ResidentAttachmentStrip: View {
    @ObservedObject var store: ResidentAttachmentStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { image in
                            ZStack(alignment: .topTrailing) {
                                if let thumbnail = NSImage(contentsOf: image.url) {
                                    Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 54, height: 46)
                                        .background(.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                Button { store.remove(id: image.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).help("移除 \(image.displayName)").accessibilityLabel("移除 \(image.displayName)")
                            }
                            .help(image.displayName)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if store.isPreparing { Text("正在准备图片…").font(.system(size: 11)).foregroundStyle(.secondary) }
            if let error = store.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2) }
        }
    }
}

@MainActor
final class ResidentAttachmentTextField: NSTextField {
    var onPasteAttachment: (NSPasteboard) -> Bool = { _ in false }
    override class var cellClass: AnyClass? { get { ResidentAttachmentTextFieldCell.self } set {} }

    var isComposingText: Bool {
        (currentEditor() as? NSTextView)?.hasMarkedText() == true
    }
}

@MainActor
private final class ResidentAttachmentTextFieldCell: NSTextFieldCell {
    private let editor = ResidentAttachmentFieldEditor()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let field = controlView as? ResidentAttachmentTextField else { return nil }
        editor.isFieldEditor = true
        editor.onPasteAttachment = { [weak field] pasteboard in field?.onPasteAttachment(pasteboard) ?? false }
        return editor
    }
}

@MainActor
private final class ResidentAttachmentFieldEditor: NSTextView {
    var onPasteAttachment: (NSPasteboard) -> Bool = { _ in false }
    override func paste(_ sender: Any?) {
        if !onPasteAttachment(.general) { super.paste(sender) }
    }
    override func keyDown(with event: AppKit.NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.shift) {
            insertNewlineIgnoringFieldEditor(nil)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
struct ResidentAttachmentInput: NSViewRepresentable {
    @Binding var text: String
    let store: ResidentAttachmentStore
    let onSubmit: () -> Void
    let onFocus: () -> Void
    var onBlur: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ResidentAttachmentTextField {
        let field = ResidentAttachmentTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = .white; field.font = .systemFont(ofSize: 14)
        field.placeholderString = "发消息，或让居民做点什么…"
        field.maximumNumberOfLines = 3
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.delegate = context.coordinator; field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onPasteAttachment = { [weak store] in store?.paste(from: $0) ?? false }
        field.setAccessibilityLabel("给居民发消息")
        field.setAccessibilityIdentifier("stage.resident-input")
        return field
    }
    func updateNSView(_ field: ResidentAttachmentTextField, context: Context) {
        context.coordinator.parent = self
        if ResidentTextInputPolicy.shouldApplyExternalText(
            fieldText: field.stringValue,
            externalText: text,
            isComposing: field.isComposingText
        ) {
            field.stringValue = text
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResidentAttachmentTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let measured = (text as NSString).boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return CGSize(width: width, height: min(64, max(26, ceil(measured.height) + 6)))
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ResidentAttachmentInput
        init(_ parent: ResidentAttachmentInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.text = field.stringValue } }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocus() }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onBlur() }
        @objc func submit(_ sender: ResidentAttachmentTextField) {
            guard ResidentTextInputPolicy.shouldSubmit(
                isComposing: sender.isComposingText
            ) else { return }
            parent.onSubmit()
        }
    }
}
