import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os
import CryptoKit
import Darwin

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

/// **「这个 URL 是不是一张图片文件」的唯一一份实现。**
///
/// `ResidentAttachmentStore.add(urls:)` 的校验与拖拽落点的高亮判据**都读它**，于是
/// 「＋ 选择文件」「⌘V」「访达拖进来」三条路对同一份 URL 不可能得出不同结论：拖拽既
/// 没有收下 `＋` 会拒的文件（没有放宽），也没有拒掉 `＋` 会收的文件（没有收紧）。
enum ResidentImageFilePolicy {
    static func isImageFileURL(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

enum ResidentAttachmentPastePolicy {
    enum Content { case text, image, files }
    static func classify(fileURLs: [URL], hasImage: Bool) -> Content {
        if !fileURLs.isEmpty { return .files }
        return hasImage ? .image : .text
    }
}

/// **居民图片链[1] 拖拽落点**：判据是纯函数，`hitTest` 与 NSDraggingDestination 回调只读
/// 它，视图里没有第二份判断。
///
/// 三条硬性口径：
/// * **不新开附件通道** —— 落点只把 URL / 位图交给 `ResidentAttachmentStore` 既有的
///   `add(urls:)` / `add(imageData:)`。校验、归一化（PNG、≤2048px、≤8MiB、剥 EXIF）、
///   4 张上限与 `居民图片链[1]` 日志**全部**由那一条路负责，这里一个字都不重复。
/// * **非图片不亮起** —— `payload(...)` 用与 store 同一个 `ResidentImageFilePolicy`
///   判据；纯文本拖动、`.txt` 文件拖动一律 `.unsupported`（于是不亮、不接、也没有假成功）。
/// * **不抢场景鼠标交互** —— `allowsHitTesting(...)` 要求"**本 app 自己没按着鼠标**"且
///   "当前是拖动事件"。装修的点击/拖动/旋转与相机操作都是本 app 按着鼠标，而它们的事件
///   类型同样是 `leftMouseDragged` —— 与访达拖进来**无法靠事件类型区分**，所以"本 app
///   没按着鼠标"这一条是必需的，缺了它相机拖动会被落点截住。
enum ResidentImageDropPolicy {
    /// Finder 拖文件时声明的是**文件 URL**，不是 `public.image`（"从访达拖进来的永远是
    /// 文件拖动，不是图片拖动"），所以文件一律按 URL 扩展名判；`public.image/png/tiff`
    /// 只用来认「直接把位图内容拖进来」的那条路（预览、浏览器里拖图）。
    static let registeredTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .init("NSFilenamesPboardType"),
        .init("com.apple.pasteboard.promised-file-url"),
        .init(UTType.image.identifier),
        .init(UTType.png.identifier),
        .init(UTType.tiff.identifier),
    ]

    static func isPointerDragEvent(_ type: AppKit.NSEvent.EventType?) -> Bool {
        switch type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return true
        default: return false
        }
    }

    /// `hitTest` 是否参与命中。两条缺一不可（理由见上面第三条）。
    static func allowsHitTesting(eventType: AppKit.NSEvent.EventType?, localMouseIsDown: Bool) -> Bool {
        guard !localMouseIsDown else { return false }
        return isPointerDragEvent(eventType)
    }

    enum Payload: Equatable {
        /// 拖的是文件 URL。**一次把这一笔里的所有文件 URL 都交出去**（不在落点先筛一遍），
        /// 由 `add(urls:)` 逐个校验并逐个给出可见原因 —— 混合拖拽（图片 + 别的文件）里
        /// 那个非图片文件不会被静默丢掉。
        case fileURLs([URL])
        /// 拖的是位图内容（没有文件 URL）。与 ⌘V 走同一个 `add(imageData:)`。
        case bitmap
        case unsupported

        var isAccepted: Bool { self != .unsupported }
    }

    /// 纯判据：**至少有一个图片文件 URL**（或有效位图）才接受。
    /// 只看有没有位图/文件 URL 是不够的 —— `.txt` 拖动同样带文件 URL。
    static func payload(fileURLs: [URL], hasBitmap: Bool) -> Payload {
        if fileURLs.contains(where: ResidentImageFilePolicy.isImageFileURL) { return .fileURLs(fileURLs) }
        return hasBitmap ? .bitmap : .unsupported
    }

    /// 轻量分类（**不读位图字节**）：`draggingUpdated` 每次移动都会调它，读大图会卡。
    static func payload(from pasteboard: NSPasteboard) -> Payload {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let hasBitmap = pasteboard.availableType(from: [.png, .tiff]) != nil
        return payload(fileURLs: urls, hasBitmap: hasBitmap)
    }

    /// 这一笔的确切内容（用于"拖了没反应"时一眼看出是哪一类被拒）。
    static func describe(_ pasteboard: NSPasteboard, payload: Payload) -> String {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let extensions = Set(urls.map { $0.pathExtension.lowercased() }).sorted().joined(separator: ",")
        let declared = (pasteboard.types ?? []).prefix(5).map(\.rawValue).joined(separator: ",")
        return "文件URL数=\(urls.count) 扩展名=[\(extensions)] 接受=\(payload.isAccepted) 声明类型=[\(declared)]"
    }
}

/// **本 app 自己有没有按着鼠标。** 拖拽落点不抢场景交互的关键一条（见
/// `ResidentImageDropPolicy.allowsHitTesting`）。
///
/// 局部事件监听器在本 app 收到事件时**先于 `hitTest`** 运行；它只读、**原样返回事件**
/// （不消费、不改写），所以对既有的鼠标行为是零改动，只是让落点在这些时刻彻底不参与命中。
@MainActor
enum ResidentImageDropMouseWatch {
    nonisolated(unsafe) private static var mouseDownInFlight = false
    private static var monitor: Any?

    /// 与物理按键状态一起读：万一某一次 mouseUp 没能送达，`pressedMouseButtons` 会把它
    /// 自愈，落点不会永久卡在"参与命中"上。
    static var isLocalMouseDown: Bool { mouseDownInFlight && AppKit.NSEvent.pressedMouseButtons != 0 }

    static func start() {
        guard monitor == nil else { return }
        let mask: AppKit.NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        monitor = AppKit.NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: mouseDownInFlight = true
            default: mouseDownInFlight = false
            }
            return event
        }
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
    private let authority: RustChatAttachmentClient
    private let authorityIdentity: RustChatAttachmentClient.Identity
    private var authorityOpened = false
    private var draftRevision: UInt64 = 0
    private var frameGeneration: UInt64 = 0
    private var authorityCanSend = true
    private var lifecycleTail: Task<Void, Never>?
    private var pendingMutations = 0
    private var closed = false
    private var knownSubmissions = Set<UUID>()
    var canSubmit: Bool { !isPreparing && pendingMutations == 0 && authorityCanSend }

    init(directory: URL? = nil, authority: RustChatAttachmentClient? = nil,
         prepare: @escaping @Sendable (URL) async throws -> Data = { try await PropImagePreparation.prepare(url: $0) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/ResidentAttachments", isDirectory: true)
        self.prepare = prepare
        let root = WorldAuthorityEndpoint.taskServiceRoot()
        self.authority = authority ?? RustChatAttachmentClient(endpointFile:root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path)
        authorityIdentity = .init(ownerID:SHA256.hash(data:Data(self.directory.standardizedFileURL.path.utf8)).map {String(format:"%02x",$0)}.joined(),
            hostSessionID:UUID().uuidString)
    }

    func add(urls: [URL]) async {
        guard !closed else {return}
        // **不允许静默丢弃**：上一批还在准备时的第二次接入（＋/⌘V/拖拽都走这里）也要
        // 留下可见原因，而不是无声无息地什么都不发生 —— 那正是这次踩的坑。
        guard !isPreparing else {
            errorMessage = "上一批图片还在准备，请稍后再试。"
            ResidentImageChainLog.failure("居民图片链[1] 附件接入被拒 原因=上一批还在准备 文件数=\(urls.count)")
            onChange()
            return
        }
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
            guard ResidentImageFilePolicy.isImageFileURL(url) else {
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
                guard !closed, !Task.isCancelled else {throw CancellationError()}
                guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let id = UUID()
                let destination = directory.appendingPathComponent("\(id.uuidString).png")
                try writePrivate(data, to: destination)
                let hash = SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
                _ = try await mutate { [self] in
                    frameGeneration += 1
                    return try await authority.register(authorityIdentity,revision:draftRevision,frameGeneration:frameGeneration,
                        attachmentID:id,localPath:try canonical(destination).path,sha256:hash,byteCount:data.count,displayName:url.lastPathComponent)
                }
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
        guard !closed else {return}
        // 同上：并发接入不许静默丢弃。
        guard !isPreparing else {
            errorMessage = "上一批图片还在准备，请稍后再试。"
            ResidentImageChainLog.failure("居民图片链[1] 附件接入被拒 原因=上一批还在准备 来源=位图")
            onChange()
            return
        }
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

    func remove(id: UUID) async {
        do {_ = try await mutate { [self] in try await authority.remove(authorityIdentity,revision:draftRevision,attachmentID:id) }}
        catch {errorMessage="图片移除未完成，请重试。";onChange()}
    }
    func takeSubmission(text: String, id: UUID = UUID()) async throws -> ResidentChatSubmission {
        let result = ResidentChatSubmission(text:text,attachments:attachments,id:id)
        let ids = result.attachments.map(\.id)
        let hasText = !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        _ = try await mutate { [self] in
            do {
                return try await authority.take(authorityIdentity,revision:draftRevision,
                    submissionID:id,attachmentIDs:ids,hasText:hasText)
            } catch {
                let failure = error
                // A transport failure may follow a committed take. Only the
                // persisted binding can acknowledge it; never dispatch take again.
                guard let recovered = try? await authority.read(authorityIdentity,submissionID:id),
                      let binding = recovered.submission,
                      binding.submissionID == id.uuidString.lowercased(),
                      binding.attachmentIDs == ids.map({$0.uuidString.lowercased()}),
                      binding.hasText == hasText, binding.state == "issued" else {throw failure}
                return recovered
            }
        }
        knownSubmissions.insert(id)
        ResidentImageChainLog.note(
            "居民图片链[1] Rust确认提交附件 张数=\(result.attachments.count)"
        )
        return result
    }

    @discardableResult
    func restoreSubmission(_ submission: ResidentChatSubmission) async -> Bool {
        // Voice/text-only inputs may never have owned an attachment reference.
        if submission.attachments.isEmpty && !knownSubmissions.contains(submission.id) {return true}
        do {_ = try await mutate { [self] in try await authority.restore(authorityIdentity,revision:draftRevision,submissionID:submission.id) };return true}
        catch {errorMessage="图片恢复未确认，请稍后重试。";onChange();return false}
    }
    func finishSubmission(id: UUID, state: String = "completed") async {
        guard knownSubmissions.contains(id) else {return}
        do {_ = try await mutate { [self] in try await authority.finish(authorityIdentity,revision:draftRevision,submissionID:id,state:state) }
            if state == "completed" {knownSubmissions.remove(id)}
        }
        catch {errorMessage="图片交付状态待确认。";onChange()}
    }
    func close() async {
        closed = true
        do {_ = try await mutate { [self] in try await authority.close(authorityIdentity,revision:draftRevision) }}
        catch {errorMessage="图片输入结束状态待确认。";onChange()}
    }
    private func mutate(_ operation: @escaping @MainActor () async throws -> RustChatAttachmentClient.Reply) async throws -> RustChatAttachmentClient.Reply {
        pendingMutations += 1;onChange()
        defer {pendingMutations -= 1;onChange()}
        let previous = lifecycleTail
        let task = Task { @MainActor [self] in
            await previous?.value
            if !authorityOpened {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
                let opened = try await authority.open(authorityIdentity,directory:try canonical(directory).path)
                try apply(opened);authorityOpened = true
            }
            do {let reply = try await operation();try apply(reply);return reply}
            catch {
                // Reconcile only by reading; a lost response never dispatches a
                // second registration, take, finish or deletion candidate.
                if let state = try? await authority.read(authorityIdentity) {try? apply(state)}
                throw error
            }
        }
        lifecycleTail = Task {_ = try? await task.value}
        return try await task.value
    }
    private func apply(_ reply: RustChatAttachmentClient.Reply) throws {
        let root = try canonical(directory)
        func privateFile(_ path: String) throws -> URL {
            let url = URL(fileURLWithPath:path)
            guard url.deletingLastPathComponent()==root,
                  (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw CocoaError(.fileReadNoPermission)}
            return url
        }
        let images = try reply.snapshot.attachments.map { row -> ResidentImageAttachment in
            guard let id = UUID(uuidString:row.id) else {throw CocoaError(.fileReadCorruptFile)}
            return .init(id:id,url:try privateFile(row.localPath),displayName:row.displayName)
        }
        for path in reply.deletePaths {try? FileManager.default.removeItem(at:try privateFile(path))}
        attachments = images;draftRevision = reply.snapshot.revision
        frameGeneration = reply.snapshot.frameGeneration;authorityCanSend = reply.snapshot.canSend
        if !authorityCanSend {errorMessage="失败消息的图片已保留；每条消息最多 4 张，请移除多余图片后发送。"}
        onChange()
    }
    private func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path,nil) else {throw CocoaError(.fileReadNoSuchFile)}
        defer {free(path)}
        // Foundation standardization rewrites /private/var back to /var on
        // macOS; retain POSIX realpath for the authority's exact-path contract.
        return URL(fileURLWithPath:String(cString:path),isDirectory:url.hasDirectoryPath)
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
        if FileManager.default.fileExists(atPath:directory.path),
           try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {throw CocoaError(.fileWriteNoPermission)}
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
                                Button { Task {await store.remove(id:image.id)} } label: { Image(systemName: "xmark.circle.fill") }
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

/// 拖拽落点的 AppKit 端：**唯一的职责是把拖进来的东西交给 `ResidentAttachmentStore`
/// 既有的入口**，它自己不碰图片字节、不做归一化、不判上限。
///
/// `hitTest` 是这个类里唯一"有风险"的地方，所以判据写得很窄（见
/// `ResidentImageDropPolicy.allowsHitTesting`）：只有"**别的 app 正拖着东西经过**"时
/// 这个视图才存在，其余任何时刻（本地点选、相机拖动、装修点击/拖动/旋转、悬停、滚动）
/// 一律返回 nil —— 对鼠标**逐事件等价于它不存在**。
@MainActor
final class ResidentImageDropView: NSView {
    var onTargetingChange: (Bool) -> Void = { _ in }
    var onFileURLs: ([URL]) -> Void = { _ in }
    var onBitmap: (Data) -> Void = { _ in }
    private var isTargeted = false
    /// `draggingUpdated` 每移动一下就调一次：同一笔拖拽只分类一次（changeCount 变了才重算），
    /// 免得反复读粘贴板。
    private var classifiedChangeCount = -1
    private var classifiedPayload: ResidentImageDropPolicy.Payload = .unsupported

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard ResidentImageDropPolicy.allowsHitTesting(
            eventType: NSApp.currentEvent?.type,
            localMouseIsDown: ResidentImageDropMouseWatch.isLocalMouseDown
        ) else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let payload = payload(of: sender)
        if !payload.isAccepted {
            // 「拖了没反应」必须留下确切原因：这一行说明拖拽确实到了落点，只是不是图片。
            ResidentImageChainLog.note(
                "居民图片链[1] 拖拽未接入 原因=这一笔里没有图片文件URL也没有位图 \(ResidentImageDropPolicy.describe(sender.draggingPasteboard, payload: payload))"
            )
        }
        setTargeted(payload.isAccepted)
        return payload.isAccepted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let payload = payload(of: sender)
        setTargeted(payload.isAccepted)
        return payload.isAccepted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { setTargeted(false) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        payload(of: sender).isAccepted
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setTargeted(false)
        switch payload(of: sender) {
        case .fileURLs(let urls):
            ResidentImageChainLog.note(
                "居民图片链[1] 拖拽接入 来源=访达/文件URL 文件URL数=\(urls.count) 名称=[\(urls.prefix(6).map(\.lastPathComponent).joined(separator: ","))]"
            )
            // 与「＋ 选择文件」**同一条**：校验/归一化/4 张上限/日志都在 store 里。
            onFileURLs(urls)
            return true
        case .bitmap:
            guard let type = sender.draggingPasteboard.availableType(from: [.png, .tiff]),
                  let data = sender.draggingPasteboard.data(forType: type) else {
                ResidentImageChainLog.failure("居民图片链[1] 拖拽被拒 原因=声明了位图类型但读不出字节")
                return false
            }
            ResidentImageChainLog.note("居民图片链[1] 拖拽接入 来源=拖拽位图 类型=\(type.rawValue) 字节=\(data.count)")
            // 与「⌘V」**同一条**：`add(imageData:)` 自己落临时文件后走 `add(urls:)`。
            onBitmap(data)
            return true
        case .unsupported:
            setTargeted(false)
            return false
        }
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { setTargeted(false) }

    private func payload(of sender: any NSDraggingInfo) -> ResidentImageDropPolicy.Payload {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.changeCount != classifiedChangeCount {
            classifiedChangeCount = pasteboard.changeCount
            classifiedPayload = ResidentImageDropPolicy.payload(from: pasteboard)
        }
        return classifiedPayload
    }

    private func setTargeted(_ targeted: Bool) {
        guard isTargeted != targeted else { return }
        isTargeted = targeted
        onTargetingChange(targeted)
    }
}

/// SwiftUI 侧的落点：只做接线，不含任何判据。
///
/// 挂在**对话面板**所在的视图上（`StageResidentComposer` 的 overlay），所以用户在哪输入就在
/// 哪能放。它**不新增可命中的常规视图**：`ResidentImageDropView.hitTest` 在非拖拽时刻一律
/// 返回 nil，场景里的点击/拖动/旋转与相机操作因此完全不受影响。
@MainActor
struct ResidentImageDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onFileURLs: ([URL]) -> Void
    let onBitmap: (Data) -> Void

    func makeNSView(context: Context) -> ResidentImageDropView {
        ResidentImageDropMouseWatch.start()
        let view = ResidentImageDropView()
        view.registerForDraggedTypes(ResidentImageDropPolicy.registeredTypes)
        configure(view)
        return view
    }

    func updateNSView(_ view: ResidentImageDropView, context: Context) { configure(view) }

    private func configure(_ view: ResidentImageDropView) {
        let isTargeted = $isTargeted
        view.onTargetingChange = { targeted in
            if isTargeted.wrappedValue != targeted { isTargeted.wrappedValue = targeted }
        }
        view.onFileURLs = onFileURLs
        view.onBitmap = onBitmap
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
