import AVFoundation
import CoreVideo
import Foundation
import Metal

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
    /// 当前 item 的状态（`AVPlayerItem.Status.rawValue`），诊断用。
    var itemStatus: Int { player?.currentItem?.status.rawValue ?? -1 }
    var currentItemError: String? { player?.currentItem?.error?.localizedDescription }
    var timeControlStatus: Int { player?.timeControlStatus.rawValue ?? -1 }
    /// 有没有过至少一帧真正解码出来的画面。**"准备好了"不算**。
    private(set) var decodedFrameCount = 0
    private(set) var gpuCopyCount = 0
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

    let descriptor: NativeScreenMediaDescriptor

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    /// 真实音频采样器：把解码后的 PCM 计数并测峰值（无麦克风权限）。它按当前 item
    /// 挂一次 `MTAudioProcessingTap`；清单（HLS）要等轨道协商出来后再挂。
    private let audioSampler = NativeAudioSampleTap()
    private var audioTapTask: Task<Void, Never>?
    /// 资源加载器必须由我们保活（`AVAssetResourceLoader` 不强引用 delegate）。
    private var assetLoaders: [ScreenLinkAssetLoader] = []
    /// 一份私有的目标纹理。每帧从 `CVPixelBuffer` 拷进来一次（一次 GPU blit），
    /// 于是渲染器采样的那张纹理**不依赖** `CVPixelBuffer` 的生命周期（IOSurface 会被回收）。
    private var destinationTexture: MTLTexture?

    init?(device: MTLDevice, descriptor: NativeScreenMediaDescriptor) {
        guard let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else { return nil }
        self.device = device
        self.commandQueue = queue
        self.textureCache = textureCache
        self.descriptor = descriptor
    }

    /// 建 asset / composition / item 并起播。可重入：再次调用会先停掉旧的。
    func start() {
        stop()
        state = .preparing
        let descriptor = self.descriptor
        Task { @MainActor [weak self] in
            do {
                let prepared = try await Self.makePlayerItem(for: descriptor)
                guard let self else { return }
                self.install(prepared)
            } catch let failure as NativeScreenPlaybackFailure {
                self?.lastErrorDescription = failure.technicalDescription
                self?.state = .failed(failure)
            } catch is CancellationError {
                self?.state = .failed(.cancelled)
            } catch {
                let nsError = error as NSError
                let reason = "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
                self?.lastErrorDescription = reason
                self?.state = .failed(.assetUnreadable(reason))
            }
        }
    }

    func stop() {
        framePump?.cancel()
        framePump = nil
        audioTapTask?.cancel()
        audioTapTask = nil
        audioSampler.reset()
        player?.pause()
        if let output, let item = player?.currentItem {
            item.remove(output)
        }
        player = nil
        output = nil
        destinationTexture = nil
        assetLoaders.removeAll()
        isFrameOutputAttached = false
        if state != .failed(.cancelled) { state = .stopped }
    }

    /// 帧泵：`AVPlayerItemVideoOutput` 只在被显式索取时才产出像素。渲染器每帧也会拉
    /// （`WorldScreenVideoRenderer` 经注册表调用同一个入口）；**没有渲染器**时（例如
    /// 命令行 / 控制面只读 `decodedFrames`）这里以 ~30 Hz 自己拉，保证解码真的在跑、
    /// 统计真的在涨。
    ///
    /// 两侧同时拉是安全的：`copyFrameTexture()` 在没有新帧时返回**最近一帧**（不是
    /// `nil`），所以谁先取到新帧都不会让另一个人画不出画面。
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

    /// 返回**最近一帧**纹理：有新像素就解一帧、blit 进私有纹理再返回它；没有新帧就返回
    /// 上一张（`nil` = 还没出过画）。
    ///
    /// 这个方法是渲染器每帧调用的唯一入口；它不截图、不读网页，只读解码输出。
    /// 返回"最近一帧"而不是严格"新帧"是刻意的：帧泵（~30 Hz）与渲染器（~60 Hz）会
    /// 同时拉同一个视频输出，谁先取走新帧都不该让渲染器这一帧空手而归。
    func copyFrameTexture() -> MTLTexture? {
        guard let player, let output else { return destinationTexture }
        if let error = player.currentItem?.error {
            state = .failed(.assetUnreadable(error.localizedDescription))
            return destinationTexture
        }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return destinationTexture }
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
        if destinationTexture?.width != width || destinationTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .renderTarget]
            destinationTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let destination = destinationTexture,
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
        command.commit()
        command.waitUntilCompleted()
        // 有界生命周期：blit 完成前不能回收 `buffer` / `wrapped` / `source`。
        withExtendedLifetime((buffer, wrapped, source)) {}
        guard command.status == .completed else { return destinationTexture }
        gpuCopyCount += 1
        if state != .playing, decodedFrameCount >= 1 { state = .playing }
        return destination
    }

    // MARK: 组装

    private func install(_ prepared: PreparedItem) {
        self.hasAudio = prepared.hasAudio
        self.assetLoaders = prepared.loaders
        let item = prepared.item
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = false
        self.output = output
        self.player = player
        isFrameOutputAttached = true
        // 有音频轨就**在起播前同步挂**：`AVPlayerItem.audioMix` 必须在播放管线建立
        // 之前设置才可靠生效；HLS（清单）协商前拿不到 `AVAssetTrack`，用
        // `AVMutableAudioMixInputParameters()`（trackID 无效 = 作用于全部音轨）。
        // 挂不上再退回等轨道协商后补挂（分轨 item / 罕见的协商延迟）。
        if prepared.hasAudio,
           ProcessInfo.processInfo.environment["GMGN_DISABLE_SCREEN_AUDIO_TAP"] == nil {
            audioSampler.install(on: item, track: prepared.audioTrack)
            if !audioSampler.isAttached {
                attachAudioTapWhenReady(to: item)
            }
        }
        player.play()
        startFramePump()
    }

    /// 清单 / 直播的音频轨要等 item ready 才出现；等到之后补挂音频采样 tap。
    private func attachAudioTapWhenReady(to item: AVPlayerItem) {
        audioTapTask?.cancel()
        audioTapTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if item.status == .readyToPlay { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled, item.status == .readyToPlay else { return }
            // 协商后能拿到具体音轨就用它；拿不到就退回"全部音轨"参数，绝不因为
            // 枚举不到 AVAssetTrack 就放弃真实 PCM 采样。
            let track = (try? await item.asset.loadTracks(withMediaType: .audio))?.first
            self?.audioSampler.install(on: item, track: track)
        }
    }

    /// 组装好的 item + 它到底有没有声音 + 音频轨（挂采样用）+ 需要保活的资源加载器。
    private struct PreparedItem {
        let item: AVPlayerItem
        let hasAudio: Bool
        let audioTrack: AVAssetTrack?
        /// `AVAssetResourceLoader` **不**强引用 delegate —— 不在这里留住，请求头就会丢。
        let loaders: [ScreenLinkAssetLoader]
    }

    private static func makePlayerItem(for descriptor: NativeScreenMediaDescriptor) async throws
        -> PreparedItem
    {
        guard let videoStream = descriptor.videoStream else { throw NativeScreenPlaybackFailure.noVideoTrack }
        let (videoAsset, videoLoader) = makeAsset(for: videoStream)
        var loaders: [ScreenLinkAssetLoader] = []
        if let videoLoader { loaders.append(videoLoader) }

        // HLS / DASH 清单：**不**用 `loadTracks` 预判轨道。清单的轨道是动态的（直播尤其），
        // 主播放列表上的 `loadTracks` 可能返回空 —— 真机实测 Twitch 直播就是这样被误判成
        // `no_video_track`。清单交给 `AVPlayer` 自己协商；有没有声音按解析回执如实报。
        // （分轨的独立音频清单这里不并进去：清单自带的音频组由 AVPlayer 选默认轨。）
        if videoStream.isManifest {
            return PreparedItem(
                item: AVPlayerItem(asset: videoAsset),
                hasAudio: descriptor.audioStream != nil || videoStream.isAudio,
                audioTrack: nil,
                loaders: loaders
            )
        }

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw NativeScreenPlaybackFailure.noVideoTrack }

        let expectsAudio = descriptor.audioStream != nil || videoStream.isAudio
        var audioTrack: AVAssetTrack?
        var audioAsset: AVURLAsset?
        if let audioStream = descriptor.audioStream {
            let (asset, loader) = makeAsset(for: audioStream)
            if let loader { loaders.append(loader) }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw NativeScreenPlaybackFailure.noAudioTrack }
            audioTrack = track
            audioAsset = asset
        } else {
            audioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first
        }
        if expectsAudio, audioTrack == nil { throw NativeScreenPlaybackFailure.noAudioTrack }

        // 合流单文件且没有独立音频流：直接用这份 asset。
        if descriptor.audioStream == nil {
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
        let videoDuration = try await videoAsset.load(.duration)
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero
        )
        let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )
        if let compositionAudio {
            let audioDuration = try await audioAsset.load(.duration)
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero
            )
        } else {
            throw NativeScreenPlaybackFailure.noAudioTrack
        }
        return PreparedItem(
            item: AVPlayerItem(asset: composition), hasAudio: true,
            audioTrack: compositionAudio, loaders: loaders
        )
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

    /// 把直通 `MTAudioProcessingTap` 挂到 item 的音频混合上。
    ///
    /// `track` 为 nil 时（HLS/清单在协商前枚举不到 `AVAssetTrack`）使用
    /// `AVMutableAudioMixInputParameters()`：按 AVFoundation 语义，trackID 为
    /// `kCMPersistentTrackID_Invalid` 的输入参数**作用于该 item 的全部音频轨**。
    /// 必须在 `AVPlayer` 起播前设置 `audioMix` 才可靠生效，所以 `NativeLinkPlayer`
    /// 在 `install(_:)` 里同步调用它，而不是等 `readyToPlay`。
    func install(on item: AVPlayerItem, track: AVAssetTrack?) {
        guard !isAttached else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in _ = tap },
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
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard createStatus == noErr, let tap else {
            lock.withLock { installDetailStorage = "create_failed:\(createStatus)" }
            return
        }
        let parameters: AVMutableAudioMixInputParameters
        let detail: String
        if let track {
            parameters = AVMutableAudioMixInputParameters(track: track)
            detail = "track"
        } else {
            parameters = AVMutableAudioMixInputParameters()
            detail = "all-tracks"
        }
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        lock.withLock { attached = true; installDetailStorage = detail }
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
