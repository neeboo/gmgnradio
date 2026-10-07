import AVFoundation
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Immutable ownership transferred to the GPU completion callback. The destination is
/// published only after completion and never written again; the source resources are
/// retained here because CVMetalTexture does not retain its backing pixel buffer.
private final class NativeVideoFrameCopyResources: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let wrapped: CVMetalTexture
    let source: MTLTexture
    let destination: MTLTexture

    init(buffer: CVPixelBuffer, wrapped: CVMetalTexture, source: MTLTexture,
         destination: MTLTexture) {
        self.buffer = buffer
        self.wrapped = wrapped
        self.source = source
        self.destination = destination
    }
}

// MARK: - macOS 原生播放：AVPlayer + AVPlayerItemVideoOutput → Metal 纹理

/// macOS 的原生媒体后端：**目标视频帧直接进 Metal 纹理**（不是每帧网页截图）。
///
/// ## 为什么是 AVPlayer
///
/// 解析器交出来的是"一个视频地址 + 可选一个音频地址 + 请求头"。Apple 平台上：
/// - **分轨**：用 `AVMutableComposition` 把视频轨与音频轨合成一个 item —— `AVPlayer`
///   本身就能播两条流合成的 asset，不需要 ffmpeg 合并文件；
/// - **请求头**：`AVURLAsset` 的 options 带上服务端要求的头；
/// - **HLS/DASH 清单**：`AVPlayer` 原生支持；
/// - **帧**：`AVPlayerItemVideoOutput` 把解码结果交成 `CVPixelBuffer`，再经
///   `CVMetalTextureCache` 变成 `MTLTexture`。
///
/// ## 什么时候 AVPlayer **不够**（明确方案，不假装）
///
/// 1. 站点给的是 **DASH**（`application/dash+xml`）时，`AVPlayer` 的系统支持有限；
///    此时应改用 FFmpeg/libmpv 解码（`NativeScreenMediaPlaying` 协议不变，只换实现）。
///    本轮解析器默认优先 `https` 直链与 HLS；DASH 会被如实标成 `isManifest`，由后端选择器
///    决定是否交给 AVPlayer。
/// 2. 站点要求 **TLS 指纹伪装**（curl_cffi 那一类）时，解析器侧就取不到地址，报具名失败，
///    与播放器无关。
/// 3. 需要 **逐帧音频可视数据**时不能只靠 AVPlayer；本轮只要求"有声音"，
///    由 `hasAudio` 与真实播放回执证明。
///
/// ## 绝不无声假通过
///
/// 解析回执声明有音频轨时，若这里加载不到音频轨，直接 `.failed(.noAudioTrack)` ——
/// **不降级成无声视频**。判据（`tools/test-native-link-playback.swift`）用真实链接驱动它。
@MainActor
final class NativeLinkPlayer: NativeScreenMediaPlaying {
    private(set) var state: NativeScreenPlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var hasAudio = false
    /// 最近一次具名失败/错误（诊断用，**不含地址**）。
    private(set) var lastErrorDescription: String?
    private(set) var preparationPhase = "idle"
    /// 当前 item 的状态（`AVPlayerItem.Status.rawValue`），诊断用。
    var itemStatus: Int { player?.currentItem?.status.rawValue ?? -1 }
    var currentItemError: String? { player?.currentItem?.error?.localizedDescription }
    /// Source prefetch failures can precede AVPlayerItem failure while buffered frames keep playing.
    var sourceHTTPFailureStatuses: [Int] { assetLoaders.compactMap { $0.lastHTTPStatus } }
    var timeControlStatus: Int { player?.timeControlStatus.rawValue ?? -1 }
    /// 正在等待播放的原因（`AVPlayer.WaitingReason`）；空串 = 没在等。
    var waitingReason: String { player?.reasonForWaitingToPlay?.rawValue ?? "" }
    /// 播放管线健康度：卡顿定位用（不参与"通过"判定，只做诊断）。
    var isPlaybackLikelyToKeepUp: Bool { player?.currentItem?.isPlaybackLikelyToKeepUp ?? false }
    var isPlaybackBufferEmpty: Bool { player?.currentItem?.isPlaybackBufferEmpty ?? false }
    var isPlaybackBufferFull: Bool { player?.currentItem?.isPlaybackBufferFull ?? false }
    /// 有没有过至少一帧真正解码出来的画面。**"准备好了"不算**。
    private(set) var decodedFrameCount = 0
    private(set) var gpuCopyCount = 0
    private(set) var framePollCount = 0
    private(set) var frameNoNewCount = 0
    private(set) var frameCopyNilCount = 0
    private(set) var frameInFlightSkipCount = 0
    private(set) var lastVideoFrameSeconds = -1.0
    var outputHostMappedSeconds: Double { output.map { CMTimeGetSeconds($0.itemTime(forHostTime: CACurrentMediaTime())) } ?? -1 }
    var loadedTimeRangeSeconds: [[Double]] { player?.currentItem?.loadedTimeRanges.map {
        let range = $0.timeRangeValue
        return [CMTimeGetSeconds(range.start), CMTimeGetSeconds(range.duration)]
    } ?? [] }
    /// 最近一次解码帧的像素尺寸。
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    /// 播放位置（秒）。真实回执用它证明"时间在前进"。
    var currentSeconds: Double {
        guard let player else { return 0 }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : 0
    }

    /// 声音这条链上的直接读数（不是"命令成功"）：静音开关、音量、播放速率，以及
    /// **真实的解码 PCM 采样**（`MTAudioProcessingTap` 在输出前取到的样本）。
    var isMuted: Bool { player?.isMuted ?? true }
    var volume: Float { player?.volume ?? 0 }
    var playbackRate: Float { player?.rate ?? 0 }
    var audioSampleBufferCount: Int { audioSampler.sampledBufferCount }
    var audioSampleFrameCount: Int { audioSampler.sampledFrameCount }
    var audioPeakAmplitude: Float { audioSampler.peakAmplitude }
    var isAudioTapAttached: Bool { audioSampler.isAttached }
    /// 最近一次挂 tap 的方式（`all-tracks` / `track:<name>` / 失败原因），只读诊断。
    var audioTapInstallDetail: String { audioSampler.installDetail }

    var onStateChange: (@MainActor (NativeScreenPlaybackState) -> Void)?
    var onPlaybackEnded: (@MainActor () -> Void)?
    private var endObserver: NSObjectProtocol?
    private(set) var playbackEndCount = 0
    var durationSeconds: Double? {
        guard let item = player?.currentItem else { return nil }
        let seconds = CMTimeGetSeconds(item.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    let descriptor: NativeScreenMediaDescriptor

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    /// 真实音频采样器：把解码后的 PCM 计数并测峰值（无麦克风权限）。它按当前 item
    /// 挂一次 `MTAudioProcessingTap`；清单（HLS）要等轨道协商出来后再挂。
    private let audioSampler = NativeAudioSampleTap()
    /// 资源加载器必须由我们保活（`AVAssetResourceLoader` 不强引用 delegate）。
    private var assetLoaders: [ScreenLinkAssetLoader] = []
    // AVAssetTrack.asset is weak. Preserve the original source assets and their
    // resource-loader sessions for the full lifetime of composition playback.
    private var sourceAssets: [AVAsset] = []
    var retainedSourceAssetCount: Int { sourceAssets.count }
    /// 一份私有的目标纹理。每帧从 `CVPixelBuffer` 拷进来一次（一次 GPU blit），
    /// 于是渲染器采样的那张纹理**不依赖** `CVPixelBuffer` 的生命周期（IOSurface 会被回收）。
    private var destinationTexture: MTLTexture?
    private var frameGeneration: UInt64 = 0
    private var copyInFlight = false
    private let audioSamplingOverride: Bool?

    init?(device: MTLDevice, descriptor: NativeScreenMediaDescriptor, audioSamplingOverride: Bool? = nil) {
        guard let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else { return nil }
        self.device = device
        self.commandQueue = queue
        self.textureCache = textureCache
        self.descriptor = descriptor
        self.audioSamplingOverride = audioSamplingOverride
    }

    /// 建 asset / composition / item 并起播。可重入：再次调用会先停掉旧的。
    func start() {
        stop()
        state = .preparing
        let descriptor = self.descriptor
        let generation = frameGeneration
        Task { @MainActor [weak self] in
            do {
                let prepared = try await Self.makePlayerItem(for: descriptor, phase: { [weak self] phase in
                    self?.preparationPhase = phase
                    if ProcessInfo.processInfo.environment["GMGN_SCREEN_LINK_DEBUG"] == "1" {
                        NSLog("[ScreenLinkPreparation] phase=%@", phase)
                    }
                }, resources: { [weak self] loaders in self?.assetLoaders = loaders })
                guard let self,self.frameGeneration == generation else { return }
                self.install(prepared)
            } catch let failure as NativeScreenPlaybackFailure {
                guard self?.frameGeneration == generation else {return}
                self?.lastErrorDescription = failure.technicalDescription
                self?.state = .failed(failure)
            } catch is CancellationError {
                guard self?.frameGeneration == generation else {return}
                self?.state = .failed(.cancelled)
            } catch {
                guard self?.frameGeneration == generation else {return}
                let nsError = error as NSError
                let reason = "\(nsError.domain)#\(nsError.code)"
                self?.lastErrorDescription = reason
                self?.state = .failed(.assetUnreadable(reason))
            }
        }
    }

    func stop() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        frameGeneration &+= 1
        framePump?.cancel()
        framePump = nil
        audioSampler.reset()
        player?.pause()
        if let output, let item = player?.currentItem {
            item.remove(output)
        }
        player = nil
        output = nil
        destinationTexture = nil
        assetLoaders.removeAll()
        sourceAssets.removeAll()
        isFrameOutputAttached = false
        if state != .failed(.cancelled) { state = .stopped }
    }

    /// 帧泵以 ~30 Hz 索取视频输出并提交异步 blit。它仍在 MainActor 上运行；
    /// 渲染器只读取已发布纹理，不在 draw 中调用 AVPlayer / CoreVideo 取帧。
    /// 没有渲染器消费时，帧泵也继续产出帧和解码统计。
    private var framePump: Task<Void, Never>?

    private func startFramePump() {
        framePump?.cancel()
        framePump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                _ = self?.copyFrameTexture()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private var isFrameOutputAttached = false

    /// 有没有出过至少一帧。
    var hasFrame: Bool { destinationTexture != nil && decodedFrameCount > 0 }

    /// 只读最近完成 blit 的不可变纹理；尚未发布首帧时为 nil。
    /// 不触发解码、CoreVideo 包装或 GPU 命令提交，供渲染器每帧读取。
    var currentFrameTexture: MTLTexture? { destinationTexture }

    /// 帧泵和播放器探针的生产入口：有新像素就提交异步 blit，返回上一张已发布纹理。
    /// 渲染器应使用 `currentFrameTexture`，避免在 draw 路径索取解码输出。
    func copyFrameTexture() -> MTLTexture? {
        framePollCount += 1
        guard !copyInFlight else { frameInFlightSkipCount += 1; return destinationTexture }
        guard let player, let output else { return destinationTexture }
        if let error = player.currentItem?.error {
            let reason = assetLoaders.compactMap { $0.lastHTTPStatus }.first.map { "http_status_\($0)" }
                ?? "\((error as NSError).domain)#\((error as NSError).code)"
            lastErrorDescription = reason
            state = .failed(.assetUnreadable(reason))
            return destinationTexture
        }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { frameNoNewCount += 1; return destinationTexture }
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime)
        else { frameCopyNilCount += 1; return destinationTexture }
        lastVideoFrameSeconds = CMTimeGetSeconds(displayTime)
        decodedFrameCount += 1
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        pixelWidth = width
        pixelHeight = height
        guard width > 0, height > 0 else { return destinationTexture }
        var wrapped: CVMetalTexture?
        let created = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
            width, height, 0, &wrapped
        )
        guard created == kCVReturnSuccess, let wrapped,
              let source = CVMetalTextureGetTexture(wrapped) else { return destinationTexture }
        // Published frames are immutable: another command queue may still sample the old
        // frame. Default retained-reference render commands keep it alive until GPU completion.
        // The renderer bounds its in-flight commands; this producer permits only one blit.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let destination = device.makeTexture(descriptor: descriptor),
              let command = commandQueue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return destinationTexture }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        let generation = frameGeneration
        copyInFlight = true
        let resources = NativeVideoFrameCopyResources(
            buffer: buffer, wrapped: wrapped, source: source, destination: destination
        )
        command.addCompletedHandler { @Sendable [weak self, resources] completed in
            // CVMetalTexture alone does not own its CVPixelBuffer. Hold every source
            // resource until the asynchronous copy finishes, even when stop() intervenes.
            withExtendedLifetime(resources) {}
            let succeeded = completed.status == .completed
            Task { @MainActor [weak self, resources] in
                guard let self else { return }
                self.copyInFlight = false
                guard self.frameGeneration == generation, succeeded else { return }
                self.destinationTexture = resources.destination
                self.gpuCopyCount += 1
                if self.state != .playing { self.state = .playing }
            }
        }
        command.commit()
        return destinationTexture
    }

    // MARK: 组装

    private func install(_ prepared: PreparedItem) {
        self.hasAudio = prepared.hasAudio
        self.assetLoaders = prepared.loaders
        self.sourceAssets = prepared.sourceAssets
        let item = prepared.item
        let generation = frameGeneration
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,self.frameGeneration == generation else {return}
                self.playbackEndCount += 1
                NSLog("[ScreenPlayback] event=natural_end position=%.3f duration=%.3f live=%d", self.currentSeconds,
                      self.durationSeconds ?? -1, self.descriptor.isLive)
                self.onPlaybackEnded?()
            }
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = false
        if ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_MUTED"] == "1" { player.isMuted = true }
        self.output = output
        self.player = player
        isFrameOutputAttached = true
        // 声音采样 tap **只挂 file-based 媒体**。Apple 对 `AVPlayerItem.audioMix` 的文档
        // 写得很死：「An audio mix can only be used with file-based media and is not
        // supported for use with media served using HTTP Live Streaming.」
        // 本机实测（macOS 26.5.2，同一台 Twitch HLS / Apple VOD HLS / 本地 MP4）：
        // - 无轨 `AVMutableAudioMixInputParameters()`：HLS 与本地文件**都**把 item 卡在
        //   preparing（decodedFrames=1、rate=0、tap 只回调 22 次且 PCM 全 0）；
        // - 带真实轨的混音：本地文件正常采样（peak≈0.157），HLS 被静默忽略（tap 0 次）。
        // 所以清单/HLS 一律**不设 `audioMix`**，由 `AVPlayer` 原生输出真实声音（不静音、
        // 不改音量）；只有 file-based（单文件合流 / 分轨 composition）才用真实轨挂 tap。
        let tapEnabled = audioSamplingOverride ?? (ProcessInfo.processInfo.environment["GMGN_DISABLE_SCREEN_AUDIO_TAP"] == nil)
        if !prepared.hasAudio {
            audioSampler.noteUnavailable("no-audio-declared")
        } else if !tapEnabled {
            audioSampler.noteUnavailable("disabled:env")
        } else if let track = prepared.audioTrack {
            // file-based：轨道在起播前就已知，同步挂真实轨混音。
            audioSampler.install(on: item, track: track)
        } else {
            // 清单（HLS / 直播）：平台不支持 audioMix，如实记录，不伪造、不卡死播放。
            audioSampler.noteUnavailable("unsupported:hls-manifest")
        }
        player.play()
        startFramePump()
    }

    /// 组装好的 item + 它到底有没有声音 + 音频轨（挂采样用）+ 需要保活的资源加载器。
    private struct PreparedItem {
        let item: AVPlayerItem
        let hasAudio: Bool
        let audioTrack: AVAssetTrack?
        /// `AVAssetResourceLoader` **不**强引用 delegate —— 不在这里留住，请求头就会丢。
        let loaders: [ScreenLinkAssetLoader]
        var sourceAssets: [AVAsset] = []
    }

    private static func makePlayerItem(for descriptor: NativeScreenMediaDescriptor, phase: (String) -> Void,
        resources: ([ScreenLinkAssetLoader]) -> Void) async throws
        -> PreparedItem
    {
        guard let videoStream = descriptor.videoStream else { throw NativeScreenPlaybackFailure.noVideoTrack }
        let (videoAsset, videoLoader) = makeAsset(for: videoStream)
        var loaders: [ScreenLinkAssetLoader] = []
        if let videoLoader { loaders.append(videoLoader) }
        resources(loaders)

        // HLS / DASH 清单：**不**用 `loadTracks` 预判轨道。清单的轨道是动态的（直播尤其），
        // 主播放列表上的 `loadTracks` 可能返回空 —— 真机实测 Twitch 直播就是这样被误判成
        // `no_video_track`。清单交给 `AVPlayer` 自己协商；有没有声音按解析回执如实报。
        // （分轨的独立音频清单这里不并进去：清单自带的音频组由 AVPlayer 选默认轨。）
        if videoStream.isManifest {
            phase("manifest-item")
            return PreparedItem(
                item: AVPlayerItem(asset: videoAsset),
                hasAudio: descriptor.audioStream != nil || videoStream.isAudio,
                audioTrack: nil,
                loaders: loaders
            )
        }

        do {
            phase("video-tracks")
            let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { throw NativeScreenPlaybackFailure.noVideoTrack }

            let expectsAudio = descriptor.audioStream != nil || videoStream.isAudio
            var audioTrack: AVAssetTrack?
            var audioAsset: AVURLAsset?
            if let audioStream = descriptor.audioStream {
                let (asset, loader) = makeAsset(for: audioStream)
                if let loader { loaders.append(loader) }
                resources(loaders)
                phase("audio-tracks")
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let track = tracks.first else { throw NativeScreenPlaybackFailure.noAudioTrack }
                audioTrack = track
                audioAsset = asset
            } else {
                phase("muxed-audio-tracks")
                audioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first
            }
            if expectsAudio, audioTrack == nil { throw NativeScreenPlaybackFailure.noAudioTrack }

            // 合流单文件且没有独立音频流：直接用这份 asset。
            if descriptor.audioStream == nil {
                phase("muxed-item")
                return PreparedItem(
                    item: AVPlayerItem(asset: videoAsset), hasAudio: audioTrack != nil,
                    audioTrack: audioTrack, loaders: loaders
                )
            }
            // 分轨：把视频轨与音频轨合成一个 item —— 不需要 ffmpeg 合并文件。
            guard let audioTrack, let audioAsset else { throw NativeScreenPlaybackFailure.noAudioTrack }
            let composition = AVMutableComposition()
            guard let compositionVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw NativeScreenPlaybackFailure.assetUnreadable("composition_video") }
            phase("video-duration")
            let videoDuration = try await videoAsset.load(.duration)
            phase("video-insert")
            try compositionVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero
            )
            let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            if let compositionAudio {
                phase("audio-duration")
                let audioDuration = try await audioAsset.load(.duration)
                phase("audio-insert")
                try compositionAudio.insertTimeRange(
                    CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero
                )
            } else {
                throw NativeScreenPlaybackFailure.noAudioTrack
            }
            phase("composition-item")
            return PreparedItem(
                item: AVPlayerItem(asset: composition), hasAudio: true,
                audioTrack: compositionAudio, loaders: loaders, sourceAssets: [videoAsset, audioAsset]
            )
        } catch {
            if let status = loaders.compactMap({ $0.lastHTTPStatus }).first {
                throw NativeScreenPlaybackFailure.assetUnreadable("http_status_\(status)")
            }
            throw error
        }
    }

    /// 建一个 AVURLAsset。有请求头时走 `ScreenLinkAssetLoader`（自定义 scheme + 资源加载器）；
    /// 没有请求头时直连，少一层开销。
    private static func makeAsset(for stream: NativeScreenMediaStream)
        -> (AVURLAsset, ScreenLinkAssetLoader?)
    {
        guard let url = URL(string: stream.url) else {
            return (AVURLAsset(url: URL(string: "https://invalid.invalid/")!), nil)
        }
        guard !stream.headers.isEmpty, let custom = ScreenLinkAssetLoader.customURL(for: url) else {
            return (AVURLAsset(url: url), nil)
        }
        let loader = ScreenLinkAssetLoader(
            originalURL: url, headers: stream.headers, tag: stream.formatID
        )
        let asset = AVURLAsset(url: custom)
        asset.resourceLoader.setDelegate(
            loader, queue: DispatchQueue(label: "gmgn.screen.link.resource", qos: .userInitiated)
        )
        return (asset, loader)
    }
}

/// 电视声音的**真实采样**：`MTAudioProcessingTap` 插在音频输出链上，把解码后的 PCM
/// 缓冲计数、累计帧数并测峰值。
///
/// 它不需要麦克风/录屏权限（采样的是本进程播放的媒体数据，不是系统输入），也不改音量、
/// 不静音：tap 是直通的，声音照常去默认输出设备。回调跑在实时音频线程上，所以状态用
/// `NSLock` 保护、绝不碰 MainActor。
final class NativeAudioSampleTap: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0
    private var frameCount = 0
    private var peak: Float = 0
    private var attached = false
    private var installDetailStorage = "not-attempted"

    var sampledBufferCount: Int { lock.withLock { bufferCount } }
    var sampledFrameCount: Int { lock.withLock { frameCount } }
    var peakAmplitude: Float { lock.withLock { peak } }
    var isAttached: Bool { lock.withLock { attached } }
    /// 挂载方式 / 失败原因的人类可读诊断（不含地址与凭据）。
    var installDetail: String { lock.withLock { installDetailStorage } }

    func reset() {
        lock.withLock {
            bufferCount = 0
            frameCount = 0
            peak = 0
            attached = false
            installDetailStorage = "not-attempted"
        }
    }

    /// 如实记录"为什么没有挂 tap"（诊断用），不改变已挂状态、不伪造采样。
    /// 例如 HLS/清单：平台文档明确 `AVPlayerItem.audioMix` 不支持 HLS。
    func noteUnavailable(_ reason: String) {
        lock.withLock {
            if !attached { installDetailStorage = reason }
        }
    }

    /// 把直通 `MTAudioProcessingTap` 挂到 item 的音频混合上。
    ///
    /// **只支持 file-based 媒体**。Apple 对 `AVPlayerItem.audioMix` 的原文：
    /// 「An audio mix can only be used with file-based media and is not supported
    /// for use with media served using HTTP Live Streaming.」
    ///
    /// `track == nil`（HLS/清单协商前拿不到 `AVAssetTrack`）时**绝不**退化成无轨的
    /// `AVMutableAudioMixInputParameters()`：本机实测那会把播放管线卡死在 preparing
    /// （`decodedFrames=1`、`rate=0`、PCM 全 0）。这里只记录原因并返回，让 `AVPlayer`
    /// 用原生音频输出真实声音。
    func install(on item: AVPlayerItem, track: AVAssetTrack?, allocator: CFAllocator? = kCFAllocatorDefault) {
        guard !isAttached else { return }
        guard let track else {
            noteUnavailable("unsupported:no-track")
            return
        }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                guard let clientInfo else { return }
                // Audio callbacks can outlive AVPlayer teardown. The tap owns its
                // sampler from successful initialization until its final callback.
                let sampler = Unmanaged<NativeAudioSampleTap>.fromOpaque(clientInfo)
                tapStorageOut.pointee = sampler.retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<NativeAudioSampleTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, processingFormat in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let sampler = Unmanaged<NativeAudioSampleTap>
                    .fromOpaque(storage).takeUnretainedValue()
                sampler.prepare(format: processingFormat)
            },
            unprepare: { tap in _ = tap },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let sampler = Unmanaged<NativeAudioSampleTap>
                    .fromOpaque(storage).takeUnretainedValue()
                var sourceFlags = MTAudioProcessingTapFlags()
                var sourceFrames: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, &sourceFlags, nil, &sourceFrames
                )
                if status == noErr {
                    sampler.record(bufferList: bufferListInOut, frames: sourceFrames)
                }
                numberFramesOut.pointee = sourceFrames
                flagsOut.pointee = flags
            }
        )
        var tap: MTAudioProcessingTap?
        let createStatus = MTAudioProcessingTapCreate(
            allocator, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard createStatus == noErr, let tap else {
            lock.withLock { installDetailStorage = "create_failed:\(createStatus)" }
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        lock.withLock { attached = true; installDetailStorage = "track:\(track.trackID)" }
    }

    /// tap 的 `prepare` 回调给出的真实处理格式。`record` 按它选择正确的采样宽度：
    /// HLS / 系统混音既可能给 float32，也可能给有符号整数 PCM（16/32 位），只按 float
    /// 读会把整段采样误报成静音。
    private struct PCMFormat: Sendable {
        var isFloat = false
        var bitsPerChannel: UInt32 = 0
    }
    private var pcmFormat = PCMFormat()

    private func prepare(format: UnsafePointer<AudioStreamBasicDescription>) {
        let asbd = format.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        lock.withLock {
            pcmFormat = PCMFormat(
                isFloat: isFloat, bitsPerChannel: asbd.mBitsPerChannel
            )
        }
    }

    fileprivate func record(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frames: CMItemCount
    ) {
        let format = lock.withLock { pcmFormat }
        var localPeak: Float = 0
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount > 0 else { continue }
            switch (format.isFloat, format.bitsPerChannel) {
            case (true, 32):
                let count = byteCount / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    let magnitude = abs(samples[index])
                    if magnitude.isFinite { localPeak = max(localPeak, magnitude) }
                }
            case (false, 16):
                let count = byteCount / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    localPeak = max(localPeak, abs(Float(samples[index]) / 32_768))
                }
            case (false, 32):
                let count = byteCount / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count {
                    localPeak = max(localPeak, abs(Float(samples[index]) / 2_147_483_648))
                }
            case (false, 8):
                // 8 位 PCM 是无符号、以 128 为静音中点。
                let count = byteCount / MemoryLayout<UInt8>.size
                let samples = data.bindMemory(to: UInt8.self, capacity: count)
                for index in 0..<count {
                    localPeak = max(localPeak, abs(Float(Int(samples[index]) - 128) / 128))
                }
            default:
                break
            }
        }
        lock.withLock {
            bufferCount += 1
            frameCount += Int(frames)
            peak = max(peak, localPeak)
        }
    }
}
