import CryptoKit
import Foundation

// MARK: - 显式测试宿主控制面（文件邮箱）
//
// 只在 `GMGN_E2E_DATA_ROOT` 显式启用时启动（见 `E2ERuntime`）。它**不新开监听套接字**、
// 不申请任何系统权限，只用测试根下的两个目录收发 JSON 文件：
//
//   <root>/control/inbox/<id>.json    驱动器写、宿主读
//   <root>/control/outbox/<id>.json   宿主写、驱动器读
//   <root>/control/ready              宿主就绪标记
//   <root>/control/stopped            宿主正常退出标记
//
// 这样做的好处是"隔离测试"这条纪律可以机械核对：所有通道都在测试根里，拔掉这个目录
// 就等于没有控制面。生产（未设环境变量）时本类型根本不会被实例化。
//
// 命令的语义**全部由注入的 Handler 提供**，而 Handler 由 AppDelegate 用**现有生产入口**
// 实现（用户提交、居民工具会话、真实 Metal 回读、收件箱投影）。控制面自己不认识
// `world_upsert`，也不可能替业务流程写权威。

@MainActor
final class E2EHostControl {
    /// 由宿主注入的生产入口集合。每个闭包都是 MainActor 隔离的真实调用。
    struct Handler {
        var status: @MainActor () async -> [String: Any]
        var submitWish: @MainActor (_ text: String, _ attachmentPaths: [String]) async throws -> [String: Any]
        /// 只读引用现有素材，按生产 `registerImages` + `authorize` 打开一次生成授权。
        var authorizeWish: @MainActor (_ attachmentPaths: [String]) async throws -> [String: Any]
        var invokeTool: @MainActor (_ name: String, _ arguments: [String: Any]) async throws -> [String: Any]
        var captureFrames: @MainActor (_ count: Int, _ intervalMilliseconds: Int, _ trackGrounding: Bool) async -> [String: Any]
        var playbackState: @MainActor () async -> [String: Any]
        /// 只在显式测试控制面存在：把一条 file-based 媒体直链交给**生产**原生播放器，
        /// 用于非 HLS 声音采样链对照（不改 `play_screen` 白名单、不碰 HLS 判据）。
        var playDirectMedia: @MainActor (_ objectID: String, _ url: String) async -> [String: Any]
        var inboxState: @MainActor () async -> [String: Any]
        /// 收件箱"显式已读"：与收件箱详情里那一次用户点击走同一个 `markRead`。
        var markInboxRead: @MainActor (_ taskKey: String) async throws -> [String: Any]
        var terminate: @MainActor () -> Void
    }

    private let fileManager: FileManager
    private let inbox: URL
    private let outbox: URL
    private let readyMarker: URL
    private let stoppedMarker: URL
    private let handler: Handler
    private var pollTask: Task<Void, Never>?

    private init(
        fileManager: FileManager,
        inbox: URL,
        outbox: URL,
        readyMarker: URL,
        stoppedMarker: URL,
        handler: Handler
    ) {
        self.fileManager = fileManager
        self.inbox = inbox
        self.outbox = outbox
        self.readyMarker = readyMarker
        self.stoppedMarker = stoppedMarker
        self.handler = handler
    }

    /// 显式测试启用时返回控制面实例；否则返回 nil，生产零副作用。
    @discardableResult
    static func startIfEnabled(
        handler: Handler,
        fileManager: FileManager = .default
    ) -> E2EHostControl? {
        guard E2ERuntime.isEnabled,
              E2ERuntime.bootstrap(fileManager: fileManager),
              let inbox = E2ERuntime.inboxRoot,
              let outbox = E2ERuntime.outboxRoot,
              let controlRoot = E2ERuntime.controlRoot
        else { return nil }
        let control = E2EHostControl(
            fileManager: fileManager,
            inbox: inbox,
            outbox: outbox,
            readyMarker: controlRoot.appendingPathComponent(E2ERuntime.readyMarkerName),
            stoppedMarker: controlRoot.appendingPathComponent(E2ERuntime.stoppedMarkerName),
            handler: handler
        )
        control.start()
        return control
    }

    private func start() {
        try? fileManager.removeItem(at: stoppedMarker)
        writeMarker(readyMarker, contents: "ready \(Date().timeIntervalSince1970)\n")
        pollTask = Task { @MainActor [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        writeMarker(stoppedMarker, contents: "stopped \(Date().timeIntervalSince1970)\n")
    }

    // MARK: - 轮询

    private func pollLoop() async {
        while !Task.isCancelled {
            let requests = readyRequestURLs()
            for url in requests {
                await process(url)
                try? fileManager.removeItem(at: url)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func readyRequestURLs() -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: inbox.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { inbox.appendingPathComponent($0) }
    }

    private func process(_ url: URL) async {
        let requestID = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = object["command"] as? String
        else {
            write(response: ["id": requestID, "ok": false, "error": "malformed_request"], for: requestID)
            return
        }
        let params = (object["params"] as? [String: Any]) ?? [:]
        do {
            let result = try await dispatch(command: command, params: params)
            write(response: ["id": requestID, "ok": true, "result": result], for: requestID)
        } catch {
            write(response: ["id": requestID, "ok": false,
                             "error": error.localizedDescription], for: requestID)
        }
    }

    private func dispatch(command: String, params: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "ping":
            return ["pong": true, "at": Date().timeIntervalSince1970]
        case "status":
            return await handler.status()
        case "submit_wish":
            guard let text = params["text"] as? String, !text.isEmpty else {
                throw E2EHostControlError.missingParameter("text")
            }
            let attachments = (params["attachments"] as? [String]) ?? []
            return try await handler.submitWish(text, attachments)
        case "wish_authorize":
            let attachments = (params["attachments"] as? [String]) ?? []
            return try await handler.authorizeWish(attachments)
        case "tool_call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                throw E2EHostControlError.missingParameter("name")
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            return try await handler.invokeTool(name, arguments)
        case "capture_frames":
            let count = max(1, min((params["count"] as? NSNumber)?.intValue ?? 4, 240))
            let interval = max(0, min((params["intervalMs"] as? NSNumber)?.intValue ?? 100, 5_000))
            let trackGrounding = (params["trackGrounding"] as? Bool) ?? false
            return await handler.captureFrames(count, interval, trackGrounding)
        case "playback_state":
            return await handler.playbackState()
        case "play_direct_media":
            guard let objectID = params["objectID"] as? String, !objectID.isEmpty else {
                throw E2EHostControlError.missingParameter("objectID")
            }
            guard let url = params["url"] as? String, !url.isEmpty else {
                throw E2EHostControlError.missingParameter("url")
            }
            return await handler.playDirectMedia(objectID, url)
        case "inbox_state":
            return await handler.inboxState()
        case "inbox_mark_read":
            guard let taskKey = params["taskKey"] as? String, !taskKey.isEmpty else {
                throw E2EHostControlError.missingParameter("taskKey")
            }
            return try await handler.markInboxRead(taskKey)
        case "quit":
            // 先把回执写出去，再异步退出，确保驱动器拿到确认。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.handler.terminate()
            }
            return ["terminating": true]
        default:
            throw E2EHostControlError.unknownCommand(command)
        }
    }

    // MARK: - 文件

    private func write(response: [String: Any], for requestID: String) {
        let safeID = requestID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        let url = outbox.appendingPathComponent("\(safeID.isEmpty ? UUID().uuidString : safeID).json")
        writeJSON(response, to: url)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .prettyPrinted]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // 证据写不出去只能进日志；控制面绝不因为一次写失败崩溃。
            FileHandle.standardError.write(
                Data("E2E control write failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private func writeMarker(_ url: URL, contents: String) {
        try? Data(contents.utf8).write(to: url, options: .atomic)
    }
}

enum E2EHostControlError: LocalizedError {
    case missingParameter(String)
    case unknownCommand(String)
    case runtimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .missingParameter(name): "控制命令缺少参数 \(name)"
        case let .unknownCommand(name): "未知控制命令 \(name)"
        case let .runtimeUnavailable(reason): "测试运行时不可用：\(reason)"
        }
    }
}

// MARK: - 真实 Metal 连续画面

/// 连续抓取**真实 GPU 回读帧**（复用居民视觉那条已验证的无权限回读：
/// `MarbleResidentVisionSurface.captureCurrentObservation` → blit drawable →
/// shared MTLBuffer → BGRA8 → PNG）。不申请录屏/辅助功能权限。
///
/// 每一帧的元数据（尺寸、sha256、文件路径）都返回；驱动器据此证明"连续帧真的在变"，
/// 而不是只拿到一张静态图。单飞回读要求逐帧 await，所以这里是串行抓拍。
@MainActor
enum E2EFrameRecorder {
    static func captureSequence(
        surface: any ResidentVisionSurface,
        worldID: String,
        evidenceRoot: URL,
        count: Int,
        intervalMilliseconds: Int,
        sampleProvider: (@MainActor () -> [String: Any])? = nil,
        fileManager: FileManager = .default
    ) async -> [String: Any] {
        let framesRoot = evidenceRoot.appendingPathComponent("frames", isDirectory: true)
        try? fileManager.createDirectory(at: framesRoot, withIntermediateDirectories: true)
        let sessionID = UUID()
        var frames: [[String: Any]] = []
        var failures: [String] = []
        let attempts = max(1, count)
        for index in 0..<attempts {
            if index > 0, intervalMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(intervalMilliseconds) * 1_000_000)
            }
            let request = ResidentVisionCaptureRequest(
                sessionID: sessionID,
                worldID: worldID,
                reason: "e2e-frame-sequence",
                includeFileURL: false
            )
            let outcome = await surface.captureCurrentObservation(
                request: request, requestedAt: Date()
            )
            switch outcome {
            case let .frame(frame):
                do {
                    let png = try ResidentVisionPNG.encode(
                        bgra8Pixels: frame.pixelsBGRA,
                        width: frame.width,
                        height: frame.height,
                        bytesPerRow: frame.bytesPerRow
                    )
                    let name = String(format: "frame-%04d.png", index)
                    let url = framesRoot.appendingPathComponent(name)
                    try png.write(to: url, options: .atomic)
                    var row: [String: Any] = [
                        "index": index,
                        "path": url.path,
                        "width": frame.width,
                        "height": frame.height,
                        "bytes": png.count,
                        "sha256": sha256Hex(png),
                        "frameIndex": frame.stamp.frameIndex,
                        "capturedAt": frame.stamp.capturedAt.timeIntervalSince1970,
                        "worldID": frame.stamp.worldID,
                        "avatarFrameRevision": frame.stamp.residentAvatarFrameRevision,
                    ]
                    // 运动帧接地：采样必须与**这一帧**同一时刻的角色状态（位置 / 活动 /
                    // 接地诊断）绑定，驱动器才能逐帧断言"运动过程中没有穿地"，
                    // 而不是拿一段静止区间的读数冒充。
                    if let sampleProvider {
                        for (key, value) in sampleProvider() { row[key] = value }
                    }
                    frames.append(row)
                } catch {
                    failures.append("第 \(index) 帧编码失败：\(error.localizedDescription)")
                }
            case let .failure(code, message):
                failures.append("第 \(index) 帧抓取失败：\(code.rawValue) \(message)")
            }
        }
        return ["requested": attempts, "captured": frames.count,
                "frames": frames, "failures": failures]
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
