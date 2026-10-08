import Foundation
import Metal
import simd

// MARK: - 网站链接原生播放的会话管理（Rust 缓存 → 原生播放器 → 场景纹理登记）

/// 一台电视上「网站链接原生播放」的**唯一**会话管理者。
///
/// 三件事，一件都不许含糊：
/// 1. 换片 / 停 / 删作废 generation 并释放该代缓存 pin；晚到 prepare 回执仍必须清理 pin。
/// 2. Rust 拥有解析、下载、缓存和淘汰；本地描述只交给原生播放器，Swift 不取远程媒体。
/// 3. **渲染器只读已发布帧**：帧泵产出纹理，登记的 provider 每帧只读
///    `currentFrameTexture`，不在 draw 中索取视频输出。没有渲染器消费时帧泵仍运行。
@MainActor
final class NativeScreenPlaybackCoordinator {
    /// `play_screen` 等"当场能报出来的失败"的窗口。与官方嵌入那一份同一个量级。
    static let immediateFailureWindow: Duration = .seconds(3)
    /// 解析完成后等"出第一帧 / item 就绪"的上限。到点仍没出画就如实说"正在出画"。
    static let readinessWindow: Duration = .seconds(10)

    private let cache: any ScreenMediaCaching
    private let registry: WorldScreenNativeVideoRegistry
    private let device: MTLDevice?
    private let authority: any ScreenPlaybackAuthorizing
    private let worldID: @MainActor () -> String?

    private struct Session {
        var generation: UInt64
        var originalURL: String
        var player: NativeLinkPlayer?
        var state: WorldScreenSurfaceState
        var task: Task<Void, Never>?
        var consumerID = UUID().uuidString
        var cacheKey: String?
        var cacheState: ScreenMediaCacheState?
        var isLive = false
        var playlistID: String?
        var playlist: ScreenVideoPlaylist?
        var advancing = false
        var failedGeneration: UInt64?
        var ticket: RustScreenPlaybackTicket?
        var playingReceiptSent = false
        var receiptTask: Task<Void, Never>?
    }

    private var sessions: [String: Session] = [:]
    private var nextGeneration: UInt64 = 0
    private var pendingStarts: [String: String] = [:]
    /// 状态变了（会话内状态或 `read_screen` 读到的内容）。
    var onChange: (@MainActor () -> Void)?

    init(
        cache: any ScreenMediaCaching,
        registry: WorldScreenNativeVideoRegistry,
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        authority: any ScreenPlaybackAuthorizing = RustScreenPlaybackClient(),
        worldID: @escaping @MainActor () -> String? = { nil }
    ) {
        self.cache = cache
        self.registry = registry
        self.device = device
        self.authority = authority
        self.worldID = worldID
    }

    // MARK: 读

    struct Snapshot {
        let state: WorldScreenSurfaceState
        let isPlaying: Bool
        let contentURL: String
        let cacheState: ScreenMediaCacheState?
        let playlist: ScreenVideoPlaylist?
        var playlistText: String? {
            guard let playlist else {return nil}
            let bounded = playlist.truncated == true ? "（本次载入前\(playlist.itemLimit ?? playlist.items.count)条）" : ""
            return "播放列表 \(playlist.currentIndex + 1)/\(playlist.items.count)\(bounded)"
        }
    }

    /// 原生播放器**真实解码**的只读度量（E2E / 诊断用）。没有原生会话时 `nil`，
    /// 由调用方如实报"不可用"，不编造 0。
    struct Metrics {
        let decodedFrames: Int
        let gpuCopies: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let currentSeconds: Double
        let durationSeconds: Double?
        let playbackEndCount: Int
        let itemStatus: Int
        let isLive: Bool
        /// 声音链的真实读数：静音开关 / 音量 / 速率 + 解码 PCM 采样（tap）。
        let hasAudio: Bool
        let isMuted: Bool
        let volume: Float
        let playbackRate: Float
        let sampledAudioBuffers: Int
        let sampledAudioFrames: Int
        let audioPeakAmplitude: Float
        let audioTapAttached: Bool
        /// 挂载方式（`track:<id>`）或未挂原因（`unsupported:hls-manifest` /
        /// `disabled:env` / `create_failed:<n>`），只读诊断。
        let audioTapInstallDetail: String
        /// 卡顿定位：timeControlStatus / 等待原因 / 缓冲健康度。不参与"通过"判定。
        let timeControlStatus: Int
        let waitingReason: String
        let isPlaybackLikelyToKeepUp: Bool
        let isPlaybackBufferEmpty: Bool
        let isPlaybackBufferFull: Bool
        let preparationPhase: String
        let sourceHTTPFailureStatuses: [Int]
        let isManifest: Bool
    }

    func metrics(for objectID: String) -> Metrics? {
        guard let session = sessions[objectID], let player = session.player else { return nil }
        return Metrics(
            decodedFrames: player.decodedFrameCount,
            gpuCopies: player.gpuCopyCount,
            pixelWidth: player.pixelWidth,
            pixelHeight: player.pixelHeight,
            currentSeconds: player.currentSeconds,
            durationSeconds: player.durationSeconds,
            playbackEndCount: player.playbackEndCount,
            itemStatus: player.itemStatus,
            isLive: session.isLive,
            hasAudio: player.hasAudio,
            isMuted: player.isMuted,
            volume: player.volume,
            playbackRate: player.playbackRate,
            sampledAudioBuffers: player.audioSampleBufferCount,
            sampledAudioFrames: player.audioSampleFrameCount,
            audioPeakAmplitude: player.audioPeakAmplitude,
            audioTapAttached: player.isAudioTapAttached,
            audioTapInstallDetail: player.audioTapInstallDetail,
            timeControlStatus: player.timeControlStatus,
            waitingReason: player.waitingReason,
            isPlaybackLikelyToKeepUp: player.isPlaybackLikelyToKeepUp,
            isPlaybackBufferEmpty: player.isPlaybackBufferEmpty,
            isPlaybackBufferFull: player.isPlaybackBufferFull,
            preparationPhase: player.preparationPhase,
            sourceHTTPFailureStatuses: player.sourceHTTPFailureStatuses,
            isManifest: player.descriptor.videoStream?.isManifest ?? false
        )
    }

    func snapshot(for objectID: String) -> Snapshot? {
        guard let session = sessions[objectID] else { return nil }
        return Snapshot(
            state: session.state,
            isPlaying: session.player.map { $0.decodedFrameCount > 0 || $0.state.isPlaying } ?? false,
            contentURL: session.originalURL,
            cacheState: session.cacheState,
            playlist: session.playlist
        )
    }

    func hasSession(_ objectID: String) -> Bool { sessions[objectID] != nil }

    /// 有原生会话的物件（快照投影用）。
    var objectIDs: [String] { sessions.keys.sorted() }

    var activeCount: Int { sessions.count }

    // MARK: 放

    /// 放一个公开网站链接。返回时**已经能具名报出来的**失败就直接报；否则报"正在打开"，
    /// 真正的状态由 `onChange` 推进。
    func play(
        objectID: String,
        pageURL: String,
        quadProvider: @escaping @MainActor () -> [SIMD3<Float>]?,
        authorizedTicket: RustScreenPlaybackTicket? = nil
    ) async -> WorldScreenCommandOutcome {
        let ticket: RustScreenPlaybackTicket
        let startRequest = UUID().uuidString
        pendingStarts[objectID] = startRequest
        do {
            if let authorizedTicket { ticket = authorizedTicket }
            else {
                guard let world = worldID(), !world.isEmpty else { throw ScreenMediaCacheError.unavailable }
                let reply = try await authority.begin(worldID: world, screenID: objectID, pageURL: pageURL,
                    isPlaylist: ScreenMediaCacheClient.isYouTubePlaylist(pageURL), requestID: startRequest)
                guard let ready = reply.ticket else { throw ScreenMediaCacheError.server("screen_playback_unresolved_begin") }
                ticket = ready
            }
            guard ticket.screenID == objectID, ticket.worldID == worldID() else { throw ScreenMediaCacheError.invalidResponse }
            guard pendingStarts[objectID] == startRequest else {
                _ = try? await authority.stop(ticket, requestID: UUID().uuidString)
                return .failure(.screenNotFound, "这次屏幕操作已停止。")
            }
            pendingStarts[objectID] = nil
            // Rust has granted the exact existing session. This check only
            // avoids reinstalling this live native executor's identical output;
            // URL/state projections never bypass the authority begin call.
            if let session=sessions[objectID], let current=session.ticket,
               current.worldID==ticket.worldID, current.screenID==ticket.screenID,
               current.hostSessionID==ticket.hostSessionID, current.sessionID==ticket.sessionID,
               current.generation==ticket.generation,
               session.state.isLoading || session.state.isPlaying {
                return Self.outcome(for:session.state,objectID:objectID)
            }
        } catch {
            let failure = (error as? ScreenMediaCacheError) ?? .unavailable
            return .failure(.screenLoadFailed, failure.panelText, details: ["screen_id": objectID, "cause": failure.code])
        }
        invalidate(objectID)
        let generation = allocateGeneration()
        sessions[objectID] = Session(
            generation: generation, originalURL: ticket.pageURL, player: nil,
            state: .loading(url: pageURL), task: nil
        )
        sessions[objectID]?.ticket = ticket
        sessions[objectID]?.playlist = ticket.playlist
        onChange?()

        guard let device else {
            publish(objectID, generation, .failed(.nativeLink(Self.mapScreenLinkFailure(.unsupportedPlatform))))
            return .failure(
                .screenSurfaceUnavailable,
                NativeScreenPlaybackFailure.metalUnavailable.panelText,
                details: ["screen_id": objectID]
            )
        }

        let cache = self.cache
        let consumerID = sessions[objectID]!.consumerID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let playbackURL = ticket.pageURL
                var status = try await cache.prepare(pageURL: playbackURL, maxHeight: 2160, consumerID: consumerID)
                guard self.isCurrent(objectID, generation) else {
                    self.releaseCache(status.cacheKey, consumerID: consumerID, cancel: status.state != .ready)
                    return
                }
                self.sessions[objectID]?.cacheKey = status.cacheKey
                self.sessions[objectID]?.cacheState = status.state
                self.onChange?()
                while self.isCurrent(objectID, generation) {
                    let previousState = self.sessions[objectID]?.cacheState
                    self.sessions[objectID]?.cacheState = status.state
                    if previousState != status.state { self.onChange?() }
                    if status.state == .downloading, status.descriptor == nil, let errorCode = status.errorCode {
                        throw ScreenMediaCacheError.server(errorCode)
                    }
                    if self.sessions[objectID]?.player == nil, let descriptor = status.descriptor,
                       status.state == .downloading || status.state == .streaming || status.state == .ready {
                        guard ScreenMediaCacheClient.samePage(descriptor.pageURL, playbackURL) else { throw ScreenMediaCacheError.invalidDescriptor }
                        self.install(objectID: objectID, generation: generation, device: device,
                            descriptor: descriptor, quadProvider: quadProvider)
                    }
                    switch status.state {
                    case .streaming:
                        guard status.descriptor != nil else {
                            throw ScreenMediaCacheError.server(status.errorCode ?? "media_cache_invalid_descriptor")
                        }
                    case .ready:
                        guard let descriptor = status.descriptor else {
                            throw ScreenMediaCacheError.server(status.errorCode ?? "media_cache_invalid_descriptor")
                        }
                        guard ScreenMediaCacheClient.samePage(descriptor.pageURL, playbackURL) else { throw ScreenMediaCacheError.invalidDescriptor }
                        self.sessions[objectID]?.task = nil
                        return
                    case .failed: throw ScreenMediaCacheError.server(status.errorCode ?? "media_cache_failed")
                    case .missing, .interrupted, .evicted:
                        throw ScreenMediaCacheError.server(status.errorCode ?? "media_cache_\(status.state.rawValue)")
                    case .cancelled: throw CancellationError()
                    case .queued, .resolving, .downloading: break
                    }
                    try await Task.sleep(for: status.state == .streaming ? .seconds(1) : .milliseconds(250))
                    let updated = try await cache.status(cacheKey: status.cacheKey)
                    guard self.isCurrent(objectID, generation) else { return }
                    guard updated.cacheKey == status.cacheKey else { throw ScreenMediaCacheError.invalidResponse }
                    status = updated
                }
            } catch {
                // Natural EOF transfers polling ownership to advance. Its cancelled
                // old downloading poll must not tear down the still-owned queue.
                guard self.isCurrent(objectID, generation),self.sessions[objectID]?.advancing == false else { return }
                let failure = (error as? ScreenMediaCacheError) ?? .unavailable
                self.finishFailure(objectID,generation,.nativeLink(NativeLinkFailureInfo(
                    panelText: failure.panelText, technicalDescription: failure.code)))
            }
        }
        sessions[objectID]?.task = task

        // 当场等一小段；下载任务的 600 秒上限由 Rust 执行，排队期间持续读状态。
        let deadline = ContinuousClock.now + Self.immediateFailureWindow
        while ContinuousClock.now < deadline {
            if let session = sessions[objectID], session.generation == generation || session.failedGeneration == generation {
                if case .failed = session.state {
                    return Self.outcome(for: session.state, objectID: objectID)
                }
                if session.player?.decodedFrameCount ?? 0 > 0 {
                    return .ok(
                        "已经放起来了。",
                        details: ["screen_id": objectID, "content_url": pageURL]
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .ok(
            "正在打开这条链接。",
            details: ["screen_id": objectID, "content_url": pageURL]
        )
    }

    private func install(
        objectID: String, generation: UInt64, device: MTLDevice,
        value: ScreenLinkResolutionValue,
        quadProvider: @escaping @MainActor () -> [SIMD3<Float>]?
    ) {
        install(
            objectID: objectID, generation: generation, device: device,
            descriptor: NativeScreenMediaDescriptor(resolution: value),
            quadProvider: quadProvider
        )
    }

    /// E2E 诊断专用：直接把一条**公开 file-based 媒体**（带音轨的 mp4 等）交给原生播放器，
    /// 不经过网站链接解析器。
    ///
    /// 生产 `play_screen` 只接受受支持的公开观看页；file-based 直链不在白名单里。这个入口
    /// 只在显式测试控制面（`GMGN_E2E_DATA_ROOT`）下被调用，用来证明 `MTAudioProcessingTap`
    /// 的真实 PCM 采样链对 file-based 媒体可用。它复用与生产**完全同一条** `NativeLinkPlayer`
    /// 与声音采样器，不碰 HLS 判据，也不引入任何系统录音 / TCC 权限。
    func playDirectFileMedia(
        objectID: String,
        fileURL: String,
        title: String,
        quadProvider: @escaping @MainActor () -> [SIMD3<Float>]?
    ) async -> WorldScreenCommandOutcome {
        let ticket: RustScreenPlaybackTicket
        let startRequest = UUID().uuidString
        pendingStarts[objectID] = startRequest
        do {
            guard let world = worldID() else { throw ScreenMediaCacheError.unavailable }
            let reply = try await authority.begin(worldID: world, screenID: objectID, pageURL: fileURL,
                isPlaylist: false, requestID: startRequest)
            guard let ready = reply.ticket else { throw ScreenMediaCacheError.invalidResponse }
            ticket = ready
            guard pendingStarts[objectID] == startRequest, ticket.worldID == worldID() else {
                _ = try? await authority.stop(ticket, requestID: UUID().uuidString)
                return .failure(.screenNotFound, "这次屏幕操作已停止。")
            }
            pendingStarts[objectID] = nil
        } catch { return .failure(.screenLoadFailed, "屏幕播放服务未连接。") }
        invalidate(objectID)
        let generation = allocateGeneration()
        sessions[objectID] = Session(
            generation: generation, originalURL: fileURL, player: nil,
            state: .loading(url: fileURL), task: nil
        )
        sessions[objectID]?.ticket = ticket
        onChange?()
        guard let device else {
            publish(objectID, generation, .failed(.nativeLink(Self.mapScreenLinkFailure(.unsupportedPlatform))))
            return .failure(
                .screenSurfaceUnavailable,
                NativeScreenPlaybackFailure.metalUnavailable.panelText,
                details: ["screen_id": objectID]
            )
        }
        let descriptor = NativeScreenMediaDescriptor(
            pageURL: fileURL,
            title: title,
            site: .other,
            isLive: false,
            streams: [
                NativeScreenMediaStream(
                    url: fileURL, formatID: "file-media", headers: [:],
                    isVideo: true, isAudio: true, isManifest: false
                )
            ],
            note: "E2E 非 HLS file-based 声音对照（解析器不参与）"
        )
        install(
            objectID: objectID, generation: generation, device: device,
            descriptor: descriptor, quadProvider: quadProvider
        )
        return .ok("正在打开这条 file-based 媒体。", details: ["screen_id": objectID, "content_url": fileURL])
    }

    private func install(
        objectID: String, generation: UInt64, device: MTLDevice,
        descriptor: NativeScreenMediaDescriptor,
        quadProvider: @escaping @MainActor () -> [SIMD3<Float>]?
    ) {
        guard let player = NativeLinkPlayer(device: device, descriptor: descriptor) else {
            releaseSessionCache(objectID)
            publish(objectID, generation, .failed(.nativeLink(Self.mapScreenLinkFailure(.outputUnreadable("player_init")))))
            return
        }
        // provider 只读取帧泵已发布的纹理；draw 不参与解码或 blit 提交。
        registry.register(objectID) { [weak player] in
            guard let player else { return nil }
            return WorldScreenNativeVideoRegistry.Frame(
                objectID: objectID,
                texture: player.currentFrameTexture,
                quad: quadProvider() ?? [],
                isReady: player.decodedFrameCount > 0
            )
        }
        sessions[objectID]?.player = player
        sessions[objectID]?.isLive = descriptor.isLive
        player.onStateChange = { [weak self] state in
            guard let self, self.isCurrent(objectID, generation) else { return }
            if case let .failed(failure) = state {
                self.finishFailure(objectID,generation,.nativeLink(Self.linkFailure(failure)))
            } else if state.isPlaying {
                self.publish(objectID, generation, .playing(url: descriptor.pageURL))
                self.reportPlaying(objectID, generation)
            }
        }
        player.onPlaybackEnded = { [weak self] in
            guard let self,self.isCurrent(objectID,generation),!descriptor.isLive,
                  self.sessions[objectID]?.advancing == false else {return}
            guard let ticket = self.sessions[objectID]?.ticket else { return }
            self.sessions[objectID]?.advancing=true
            self.sessions[objectID]?.task?.cancel()
            self.sessions[objectID]?.task=Task { @MainActor [weak self] in
                guard let self else {return}
                do {
                    await self.sessions[objectID]?.receiptTask?.value
                    guard self.isCurrent(objectID, generation) else { return }
                    let reply = try await self.authority.receipt(ticket, status: "ended", isLive: false,
                        requestID: "eof-\(ticket.sessionID)-\(ticket.generation)")
                    guard self.isCurrent(objectID,generation) else { return }
                    self.sessions[objectID]?.task=nil
                    if let next = reply.ticket {
                        _ = await self.play(objectID: objectID, pageURL: next.pageURL,
                            quadProvider: quadProvider, authorizedTicket: next)
                    } else { self.stopOutput(objectID) }
                } catch {
                    guard self.isCurrent(objectID,generation) else {return}
                    NSLog("[ScreenPlaylist] event=advance_failed code=%@", (error as? ScreenMediaCacheError)?.code ?? "media_playlist_failed")
                    self.finishFailure(objectID,generation,.nativeLink(NativeLinkFailureInfo(
                        panelText:"播放列表下一条打不开。",technicalDescription:(error as? ScreenMediaCacheError)?.code ?? "media_playlist_failed")))
                }
            }
        }
        player.start()
        publish(objectID, generation, .loading(url: descriptor.pageURL))

        // 等"item 就绪 / 第一帧"：到点没出画也不谎报（状态仍是 loading）。
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + Self.readinessWindow
            while ContinuousClock.now < deadline {
                guard let self, self.isCurrent(objectID, generation) else { return }
                guard let session = sessions[objectID], let current = session.player else { return }
                if current.decodedFrameCount > 0 || current.state.isPlaying {
                    self.publish(objectID, generation, .playing(url: descriptor.pageURL))
                    self.reportPlaying(objectID, generation)
                    return
                }
                if case let .failed(failure) = current.state {
                    self.publish(objectID, generation, .failed(.nativeLink(Self.linkFailure(failure))))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: 停 / 删

    func stop(_ objectID: String) {
        pendingStarts[objectID] = nil
        if let ticket = sessions[objectID]?.ticket {
            let authority = self.authority
            Task { do { _ = try await authority.stop(ticket, requestID: UUID().uuidString) }
                catch { NSLog("[ScreenPlayback] stop_receipt_failed") } }
        }
        stopOutput(objectID)
    }

    private func stopOutput(_ objectID: String) {
        guard let session = sessions[objectID] else { return }
        session.task?.cancel()
        session.player?.stop()
        releaseSessionCache(objectID)
        releaseSessionPlaylist(objectID)
        registry.unregister(objectID)
        // 会话留着（`stop_screen` 之后 `read_screen` 仍读得到"上次放的是什么、已停"），
        // 但把 generation 推一格：任何在途解析的结果都不会再发布。
        sessions[objectID] = Session(
            generation: allocateGeneration(), originalURL: session.originalURL,
            player: nil, state: .stopped, task: nil
        )
        onChange?()
    }

    /// 物件被收回 / 世界切换：**彻底**清掉会话（过期结果不许复活它）。
    func remove(_ objectID: String) {
        pendingStarts[objectID] = nil
        if let ticket = sessions[objectID]?.ticket {
            let authority = self.authority
            Task { do { _ = try await authority.stop(ticket, requestID: UUID().uuidString) }
                catch { NSLog("[ScreenPlayback] remove_receipt_failed") } }
        }
        guard let session = sessions[objectID] else { return }
        session.task?.cancel()
        session.player?.stop()
        releaseSessionCache(objectID)
        releaseSessionPlaylist(objectID)
        sessions.removeValue(forKey: objectID)
        registry.unregister(objectID)
        onChange?()
    }

    func stopAll() {
        pendingStarts.removeAll()
        for objectID in Array(sessions.keys) { remove(objectID) }
    }

    /// 当前正在播放的物件（用来判断容量与"这块屏在不在放"）。
    func playingObjectIDs() -> Set<String> {
        Set(sessions.compactMap { key, session in
            guard let player = session.player else { return nil }
            return player.decodedFrameCount > 0 || player.state.isPlaying ? key : nil
        })
    }

    func isLoading(_ objectID: String) -> Bool {
        sessions[objectID]?.state.isLoading ?? false
    }

    // MARK: 内部

    /// 取消在途解析并丢掉播放器，但**保留** generation 记录，让下一次 play 递增。
    private func invalidate(_ objectID: String) {
        guard let session = sessions[objectID] else { return }
        session.task?.cancel()
        session.player?.stop()
        releaseSessionCache(objectID)
        releaseSessionPlaylist(objectID)
        registry.unregister(objectID)
    }

    private func allocateGeneration() -> UInt64 { nextGeneration &+= 1; return nextGeneration }
    private func finishFailure(_ objectID:String,_ generation:UInt64,_ failure:WorldScreenFailure) {
        guard isCurrent(objectID,generation) else {return}
        if let ticket = sessions[objectID]?.ticket {
            let authority = self.authority
            Task { do { _ = try await authority.receipt(ticket, status: "failed", isLive: false,
                requestID: "failed-\(ticket.sessionID)-\(ticket.generation)") }
                catch { NSLog("[ScreenPlayback] failure_receipt_failed") } }
        }
        let failedGeneration=allocateGeneration()
        sessions[objectID]?.failedGeneration=generation
        sessions[objectID]?.generation=failedGeneration
        sessions[objectID]?.task?.cancel()
        sessions[objectID]?.task=nil
        let player=sessions[objectID]?.player
        sessions[objectID]?.player=nil
        player?.stop()
        registry.unregister(objectID)
        releaseSessionCache(objectID)
        releaseSessionPlaylist(objectID)
        publish(objectID,failedGeneration,.failed(failure))
    }
    private func releaseSessionPlaylist(_ objectID:String) {
        sessions[objectID]?.playlistID=nil
        sessions[objectID]?.playlist=nil
    }

    private func reportPlaying(_ objectID: String, _ generation: UInt64) {
        guard isCurrent(objectID, generation), sessions[objectID]?.playingReceiptSent == false,
              let ticket = sessions[objectID]?.ticket else { return }
        sessions[objectID]?.playingReceiptSent = true
        let authority = self.authority
        let isLive = sessions[objectID]?.isLive ?? false
        sessions[objectID]?.receiptTask = Task { @MainActor [weak self] in
            do { _ = try await authority.receipt(ticket, status: "playing", isLive: isLive,
                requestID: "playing-\(ticket.sessionID)-\(ticket.generation)") }
            catch {
                guard let self, self.isCurrent(objectID, generation) else { return }
                self.finishFailure(objectID, generation, .nativeLink(NativeLinkFailureInfo(
                    panelText: "播放状态回执失败，已停止输出。", technicalDescription: "screen_playback_receipt_failed")))
            }
        }
    }

    private func releaseSessionCache(_ objectID: String) {
        guard let session = sessions[objectID], let key = session.cacheKey else { return }
        sessions[objectID]?.cacheKey = nil
        releaseCache(key, consumerID: session.consumerID, cancel: session.cacheState != .ready)
    }

    private func releaseCache(_ key: String, consumerID: String, cancel: Bool) {
        let cache = self.cache
        Task {
            do {
                try await cache.release(cacheKey: key, consumerID: consumerID)
                if cancel { try await cache.cancel(cacheKey: key, consumerID: consumerID) }
            } catch {
                let code = (error as? ScreenMediaCacheError)?.code ?? "media_cache_release_failed"
                NSLog("[ScreenMediaCache] cleanup_failure=%@", code)
            }
        }
    }

    private func isCurrent(_ objectID: String, _ generation: UInt64) -> Bool {
        guard let session = sessions[objectID] else { return false }
        return session.generation == generation
    }

    private func publish(_ objectID: String, _ generation: UInt64, _ state: WorldScreenSurfaceState) {
        guard isCurrent(objectID, generation) else { return }
        sessions[objectID]?.state = state
        onChange?()
    }

    private static func outcome(
        for state: WorldScreenSurfaceState, objectID: String
    ) -> WorldScreenCommandOutcome {
        guard case let .failed(.nativeLink(failure)) = state else {
            return .ok("正在打开这条链接。", details: ["screen_id": objectID])
        }
        return .failure(
            .screenLoadFailed, failure.panelText,
            details: ["screen_id": objectID, "cause": failure.technicalDescription]
        )
    }

    private static func linkFailure(_ failure: NativeScreenPlaybackFailure) -> NativeLinkFailureInfo {
        let mapped: ScreenLinkFailure
        switch failure {
        case .noAudioTrack, .noVideoTrack: mapped = .noPlayableStream
        case .metalUnavailable, .frameOutputUnavailable: mapped = .outputUnreadable("frame_output")
        case .cancelled: mapped = .cancelled
        case let .assetUnreadable(reason): mapped = .outputUnreadable(reason)
        }
        return mapScreenLinkFailure(mapped)
    }

    /// `ScreenLinkFailure` → `NativeLinkFailureInfo`：只搬两句文案，不改判据。
    /// 这样 `WorldScreenState` 不必依赖解析器目录，离线 harness 仍只切 `Screen/`。
    private static func mapScreenLinkFailure(_ failure: ScreenLinkFailure) -> NativeLinkFailureInfo {
        NativeLinkFailureInfo(
            panelText: failure.panelText,
            technicalDescription: failure.technicalDescription
        )
    }
}
