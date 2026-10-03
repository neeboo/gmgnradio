import Foundation
import Metal
import simd

// MARK: - 网站链接原生播放的**会话管理**（解析 → 原生播放器 → 场景纹理登记）

/// 一台电视上「网站链接原生播放」的**唯一**会话管理者。
///
/// 三件事，一件都不许含糊：
/// 1. **换片 / 停 / 删都会作废在途的解析**：每次 `play` 递增 generation 并取消上一个 Task；
///    解析回来时 generation 不对就**直接丢弃**（过期结果不可发布，更不许复活已删电视）；
/// 2. **解析地址只在内存**：`ScreenLinkResolutionValue` 不落盘；落盘的是用户粘的原始链接
///    （由 `WorldScreenStore` 走 `WorldScreenContent(kind: .nativeLink)` 写）；
/// 3. **帧由渲染器拉**：登记一个 provider，渲染器每帧读 `copyFrameTexture()`。
///    没有渲染器消费时也能按"item 已就绪"报播放中（`read_screen` 不依赖画面）。
@MainActor
final class NativeScreenPlaybackCoordinator {
    /// `play_screen` 等"当场能报出来的失败"的窗口。与官方嵌入那一份同一个量级。
    static let immediateFailureWindow: Duration = .seconds(3)
    /// 解析完成后等"出第一帧 / item 就绪"的上限。到点仍没出画就如实说"正在出画"。
    static let readinessWindow: Duration = .seconds(10)

    private let resolver: any ScreenLinkResolving
    private let registry: WorldScreenNativeVideoRegistry
    private let device: MTLDevice?

    private struct Session {
        var generation: UInt64
        var originalURL: String
        var player: NativeLinkPlayer?
        var state: WorldScreenSurfaceState
        var task: Task<Void, Never>?
    }

    private var sessions: [String: Session] = [:]
    /// 状态变了（会话内状态或 `read_screen` 读到的内容）。
    var onChange: (@MainActor () -> Void)?

    init(
        resolver: any ScreenLinkResolving,
        registry: WorldScreenNativeVideoRegistry,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) {
        self.resolver = resolver
        self.registry = registry
        self.device = device
    }

    // MARK: 读

    struct Snapshot {
        let state: WorldScreenSurfaceState
        let isPlaying: Bool
        let contentURL: String
    }

    /// 原生播放器**真实解码**的只读度量（E2E / 诊断用）。没有原生会话时 `nil`，
    /// 由调用方如实报"不可用"，不编造 0。
    struct Metrics {
        let decodedFrames: Int
        let gpuCopies: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let currentSeconds: Double
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
        /// 挂载方式（`all-tracks` / `track`）或失败原因，只读诊断。
        let audioTapInstallDetail: String
    }

    func metrics(for objectID: String) -> Metrics? {
        guard let session = sessions[objectID], let player = session.player else { return nil }
        return Metrics(
            decodedFrames: player.decodedFrameCount,
            gpuCopies: player.gpuCopyCount,
            pixelWidth: player.pixelWidth,
            pixelHeight: player.pixelHeight,
            currentSeconds: player.currentSeconds,
            itemStatus: player.itemStatus,
            isLive: false,
            hasAudio: player.hasAudio,
            isMuted: player.isMuted,
            volume: player.volume,
            playbackRate: player.playbackRate,
            sampledAudioBuffers: player.audioSampleBufferCount,
            sampledAudioFrames: player.audioSampleFrameCount,
            audioPeakAmplitude: player.audioPeakAmplitude,
            audioTapAttached: player.isAudioTapAttached,
            audioTapInstallDetail: player.audioTapInstallDetail
        )
    }

    func snapshot(for objectID: String) -> Snapshot? {
        guard let session = sessions[objectID] else { return nil }
        return Snapshot(
            state: session.state,
            isPlaying: session.player.map { $0.decodedFrameCount > 0 || $0.state.isPlaying } ?? false,
            contentURL: session.originalURL
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
        quadProvider: @escaping @MainActor () -> [SIMD3<Float>]?
    ) async -> WorldScreenCommandOutcome {
        invalidate(objectID)
        let generation = (sessions[objectID]?.generation ?? 0) + 1
        sessions[objectID] = Session(
            generation: generation, originalURL: pageURL, player: nil,
            state: .loading(url: pageURL), task: nil
        )
        onChange?()

        guard let device else {
            publish(objectID, generation, .failed(.nativeLink(Self.mapScreenLinkFailure(.unsupportedPlatform))))
            return .failure(
                .screenSurfaceUnavailable,
                NativeScreenPlaybackFailure.metalUnavailable.panelText,
                details: ["screen_id": objectID]
            )
        }

        let resolver = self.resolver
        let request = ScreenLinkRequest(pageURL: pageURL, timeout: .seconds(60))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await resolver.resolve(request)
            // **过期结果不可发布**：换片 / 停 / 删之后 generation 已变。
            guard self.isCurrent(objectID, generation) else { return }
            switch resolution {
            case let .failed(failure):
                self.publish(objectID, generation, .failed(.nativeLink(Self.mapScreenLinkFailure(failure))))
            case let .resolved(value):
                self.install(
                    objectID: objectID, generation: generation, device: device,
                    value: value, quadProvider: quadProvider
                )
            }
        }
        sessions[objectID]?.task = task

        // 当场等一小段：缺 helper / 网络立即失败 / 立刻出画都能在这次调用里说清楚。
        let deadline = ContinuousClock.now + Self.immediateFailureWindow
        while ContinuousClock.now < deadline {
            if let session = sessions[objectID], session.generation == generation {
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
        let descriptor = NativeScreenMediaDescriptor(resolution: value)
        guard let player = NativeLinkPlayer(device: device, descriptor: descriptor) else {
            publish(objectID, generation, .failed(.nativeLink(Self.mapScreenLinkFailure(.outputUnreadable("player_init")))))
            return
        }
        // 帧由渲染器拉；`isReady` 只在真的有帧之后为真（没出画不画黑矩形）。
        registry.register(objectID) { [weak player] in
            guard let player else { return nil }
            return WorldScreenNativeVideoRegistry.Frame(
                objectID: objectID,
                texture: player.copyFrameTexture(),
                quad: quadProvider() ?? [],
                isReady: player.decodedFrameCount > 0
            )
        }
        sessions[objectID]?.player = player
        player.onStateChange = { [weak self] state in
            guard let self, self.isCurrent(objectID, generation) else { return }
            if case let .failed(failure) = state {
                self.publish(objectID, generation, .failed(.nativeLink(Self.linkFailure(failure))))
            } else if state.isPlaying {
                self.publish(objectID, generation, .playing(url: value.pageURL))
            }
        }
        player.start()
        publish(objectID, generation, .loading(url: value.pageURL))

        // 等"item 就绪 / 第一帧"：到点没出画也不谎报（状态仍是 loading）。
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + Self.readinessWindow
            while ContinuousClock.now < deadline {
                guard let self, self.isCurrent(objectID, generation) else { return }
                guard let session = sessions[objectID], let current = session.player else { return }
                if current.decodedFrameCount > 0 || current.state.isPlaying || current.itemStatus == 1 {
                    self.publish(objectID, generation, .playing(url: value.pageURL))
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
        guard let session = sessions[objectID] else { return }
        session.task?.cancel()
        session.player?.stop()
        registry.unregister(objectID)
        // 会话留着（`stop_screen` 之后 `read_screen` 仍读得到"上次放的是什么、已停"），
        // 但把 generation 推一格：任何在途解析的结果都不会再发布。
        sessions[objectID] = Session(
            generation: session.generation + 1, originalURL: session.originalURL,
            player: nil, state: .stopped, task: nil
        )
        onChange?()
    }

    /// 物件被收回 / 世界切换：**彻底**清掉会话（过期结果不许复活它）。
    func remove(_ objectID: String) {
        guard let session = sessions.removeValue(forKey: objectID) else { return }
        session.task?.cancel()
        session.player?.stop()
        registry.unregister(objectID)
        onChange?()
    }

    func stopAll() {
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
        registry.unregister(objectID)
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
