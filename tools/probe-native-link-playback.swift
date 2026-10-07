// 网站链接**原生播放**的离屏探针：页面链接 → 受控解析 → 原生解码 → Metal 纹理。
//
// 它把生产的解析编排（ScreenLinkResolverService）+ 原生播放器（NativeLinkPlayer）
// **原文**编起来跑，所以它证明的是"解析出来的流真的能被 AVPlayer 解出帧、真的进了
// Metal 纹理"，而不是"插件匹配成功"。
//
// 用法：
//   swift tools/probe-native-site-link.swift                  # 离线：只验描述派生与状态
//   swift tools/probe-native-site-link.swift <page-url> [秒]   # 真实链接（需要 GMGN_SCREEN_LINK_HELPER 指向 yt-dlp 的绝对路径）
//
// 证据口径（stdout JSON，**绝不打印签名的媒体地址**）：
//   resolved / site / hasAudio / splitStreams / decodedFrames / gpuCopies /
//   pixelWidth / pixelHeight / timeAdvancedSeconds / verdict
// 退出码 0 仅当：解析成功 + **有声音** + 至少 2 帧解码 + 至少 2 次 GPU 拷贝 + 时间前进 ≥ 0.5 s。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resolverRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen/LinkResolver")
let nativeRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen/NativeMedia")
let screenRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen")

let productionSources: [(dir: URL, name: String)] = [
    (resolverRoot, "ScreenLinkContract.swift"),
    (resolverRoot, "ScreenLinkRedaction.swift"),
    (resolverRoot, "BundledHelperManifest.swift"),
    (resolverRoot, "YtDlpInvocation.swift"),
    (resolverRoot, "YtDlpResultParser.swift"),
    (resolverRoot, "ScreenLinkProcess.swift"),
    (resolverRoot, "ScreenLinkHelperLocator.swift"),
    (resolverRoot, "ScreenLinkResolverService.swift"),
    (nativeRoot, "NativeScreenMediaDescriptor.swift"),
    (nativeRoot, "ScreenMediaCacheClient.swift"),
    (root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence"), "TaskdHTTPTransport.swift"),
    (nativeRoot, "ScreenLinkAssetLoader.swift"),
    (nativeRoot, "NativeLinkPlayer.swift"),
    (nativeRoot, "WorldScreenNativeVideoRegistry.swift"),
    (nativeRoot, "NativeScreenPlaybackCoordinator.swift"),
    // 会话作废判据要用到 `WorldScreenSurfaceState` / `WorldScreenCommandOutcome`，把它们的
    // **生产产地**（Foundation + simd，无 AppKit / WorldRuntime 依赖）一起切进来。
    (screenRoot, "WorldScreenGeometry.swift"),
    (screenRoot, "WorldScreenInference.swift"),
    (screenRoot, "WorldScreenState.swift"),
    (screenRoot, "WorldScreenContent.swift"),
    (screenRoot, "ResidentScreenTools.swift"),
]

let innerProgram = ##"""
import Foundation
import AVFoundation
import CoreVideo
import Metal

// MARK: 离线判据

/// 受控的假解析器：按 `pageURL` 给（延迟, 回执）。用来驱动"换片 / 停 / 删"的作废判据。
final class ScriptedFakeResolver: ScreenMediaCaching, @unchecked Sendable {
    struct Entry: Sendable {
        let delay: Duration
        let outcome: ScreenLinkResolution
        var queued: Bool = false
    }
    private let script: [String: Entry]
    private let requestLock = NSLock()
    private var recordedHeights: [Int] = []
    private var recordedReleases: [String] = []
    private var recordedCancels: [String] = []
    var heights: [Int] { requestLock.withLock { recordedHeights } }
    var releases: [String] { requestLock.withLock { recordedReleases } }
    var cancels: [String] { requestLock.withLock { recordedCancels } }
    init(script: [String: Entry]) { self.script = script }
    func prepare(pageURL: String, maxHeight: Int, consumerID: String) async throws -> ScreenMediaCacheStatus {
        requestLock.withLock { recordedHeights.append(maxHeight) }
        guard let entry = script[pageURL] else { throw ScreenMediaCacheError.invalidResponse }
        try? await Task.sleep(for: entry.delay)
        if entry.queued { return ScreenMediaCacheStatus(cacheKey: pageURL, state: .queued, descriptor: nil, errorCode: nil) }
        switch entry.outcome {
        case let .resolved(value):
            return ScreenMediaCacheStatus(cacheKey: pageURL, state: .ready,
                descriptor: NativeScreenMediaDescriptor(resolution: value), errorCode: nil)
        case .failed:
            return ScreenMediaCacheStatus(cacheKey: pageURL, state: .failed, descriptor: nil, errorCode: "media_cache_failed")
        }
    }
    func status(cacheKey: String) async throws -> ScreenMediaCacheStatus { throw ScreenMediaCacheError.invalidResponse }
    func release(cacheKey: String, consumerID: String) async throws {
        requestLock.withLock { recordedReleases.append(cacheKey) }
    }
    func cancel(cacheKey: String, consumerID: String) async throws {
        requestLock.withLock { recordedCancels.append(cacheKey) }
    }
}

/// 一份"地址无效"的成功回执：播放器会 fail，但状态里不带任何特定失败码 —— 用来区分
/// "旧片的失败"与"新片自己的失败"。
func invalidResolution(pageURL: String) -> ScreenLinkResolutionValue {
    let video = ScreenLinkStream(
        url: "https://invalid.invalid/v", formatID: "v", container: "mp4",
        videoCodec: "avc1", audioCodec: "mp4a", width: 640, height: 360, frameRate: 30,
        bandwidth: 1, isManifest: false, hasVideo: true, hasAudio: true, headers: [:]
    )
    return ScreenLinkResolutionValue(
        pageURL: pageURL, site: .twitch, title: "t", durationSeconds: nil, isLive: false,
        video: video, audio: nil, resolvedAt: Date(), expiresAt: nil,
        extractor: "twitch", note: ""
    )
}

@MainActor
func runOfflineChecks() async -> Int32 {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        print(condition ? "PASS \(message)" : "FAIL \(message)")
        if !condition { failures += 1 }
    }
    let canonical = "https://www.youtube.com/watch?v=0w-nL_Qr_Do"
    expect(ScreenMediaCacheClient.samePage(canonical, "https://youtu.be/0w-nL_Qr_Do?si=share"), "缓存：YouTube分享链接保留同一视频身份")
    expect(ScreenMediaCacheClient.samePage(canonical, canonical + "&t=12"), "缓存：跟踪及播放时间参数不改变视频身份")
    expect(ScreenMediaCacheClient.samePage("https://www.youtube.com/watch?v=xc7yzjCwH5g", "https://www.youtube.com/watch?v=xc7yzjCwH5g&list=RDNrsQHYM9hT4&index=2"), "缓存：用户实际播放列表链接匹配当前视频回执")
    expect(!ScreenMediaCacheClient.samePage(canonical, "https://youtu.be/abcdefghijk"), "缓存：拒绝不同视频回执")
    expect(!ScreenMediaCacheClient.samePage(canonical, "https://evil.invalid/watch?v=0w-nL_Qr_Do"), "缓存：拒绝未授权站点")
    expect(!ScreenMediaCacheClient.samePage("https://www.bilibili.com/video/BV1234567890?p=1", "https://m.bilibili.com/video/BV1234567890?p=2"), "缓存：不同分P保留身份隔离")

    // The audio item may retain its tap after the owning player is stopped/released.
    // Exercise actual MTAudioProcessingTap init/finalize without any network or playback.
    do {
        weak var weakSampler: NativeAudioSampleTap?
        autoreleasepool {
        let asset = AVMutableComposition()
        let track = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let item = AVPlayerItem(asset: asset)
        var sampler: NativeAudioSampleTap? = NativeAudioSampleTap()
        weakSampler = sampler
        sampler!.install(on: item, track: track)
        expect(sampler!.isAttached, "离线：实际音频 tap 创建成功")
        sampler = nil
        expect(weakSampler != nil, "离线：owner释放后后台 tap 仍保活采样器")
        item.audioMix = nil
        }
        try? await Task.sleep(for: .milliseconds(100))
        expect(weakSampler == nil, "离线：tap finalize 释放采样器，没有额外保活泄漏")
        let item = AVPlayerItem(asset: AVMutableComposition())
        var unavailable: NativeAudioSampleTap? = NativeAudioSampleTap()
        weak var weakUnavailable = unavailable
        unavailable!.install(on: item, track: nil)
        unavailable = nil
        expect(weakUnavailable == nil, "离线：未创建 tap 的失败路径不增加 sampler retain")
        let failingAsset = AVMutableComposition()
        let failingTrack = failingAsset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        var failingSampler: NativeAudioSampleTap? = NativeAudioSampleTap()
        weak var weakFailingSampler = failingSampler
        failingSampler!.install(on: item, track: failingTrack, allocator: kCFAllocatorNull)
        expect(!failingSampler!.isAttached && failingSampler!.installDetail.hasPrefix("create_failed:"),
            "离线：实际tap分配失败路径被记录")
        failingSampler = nil
        expect(weakFailingSampler == nil, "离线：tap创建失败未保活sampler")
    }
    if let fixture = ProcessInfo.processInfo.environment["GMGN_NATIVE_LINK_LIFECYCLE_FIXTURE"],
       let device = MTLCreateSystemDefaultDevice() {
        let file = URL(fileURLWithPath: fixture).absoluteString
        let streams = [
            NativeScreenMediaStream(url: file, formatID: "fixture-video", headers: [:], isVideo: true, isAudio: false, isManifest: false),
            NativeScreenMediaStream(url: file, formatID: "fixture-audio", headers: [:], isVideo: false, isAudio: true, isManifest: false)
        ]
        let descriptor = NativeScreenMediaDescriptor(pageURL: "fixture", title: "fixture", site: .youtube,
            isLive: false, streams: streams, note: "offline composition lifecycle")
        let player = NativeLinkPlayer(device: device, descriptor: descriptor)!
        for cycle in 0..<2 {
            player.start()
            let deadline = Date().addingTimeInterval(5)
            let priorFrames = player.decodedFrameCount
            while player.decodedFrameCount < priorFrames + 10 && Date() < deadline {
                _ = player.copyFrameTexture()
                try? await Task.sleep(for: .milliseconds(33))
            }
            expect(player.retainedSourceAssetCount == 2 && player.decodedFrameCount >= priorFrames + 10,
                "离线：分轨播放保活两份实际源资产并连续供帧 cycle=\(cycle)")
            player.stop()
            expect(player.retainedSourceAssetCount == 0, "离线：stop释放分轨源资产 cycle=\(cycle)")
        }
    }
    let video = ScreenLinkStream(
        url: "https://media.example/v?expire=9999999999", formatID: "137", container: "mp4",
        videoCodec: "avc1", audioCodec: nil, width: 1920, height: 1080, frameRate: 30,
        bandwidth: 4000, isManifest: false, hasVideo: true, hasAudio: false,
        headers: ["User-Agent": "UA"]
    )
    let audio = ScreenLinkStream(
        url: "https://media.example/a?expire=9999999999", formatID: "140", container: "m4a",
        videoCodec: nil, audioCodec: "mp4a", width: nil, height: nil, frameRate: nil,
        bandwidth: 128, isManifest: false, hasVideo: false, hasAudio: true,
        headers: ["User-Agent": "UA"]
    )
    let resolution = ScreenLinkResolutionValue(
        pageURL: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", site: .youtube,
        title: "Sample", durationSeconds: 120, isLive: false, video: video, audio: audio,
        resolvedAt: Date(), expiresAt: Date(timeIntervalSince1970: 9_999_999_999),
        extractor: "youtube", note: "extractor=youtube live=false"
    )
    let descriptor = NativeScreenMediaDescriptor(resolution: resolution)
    expect(descriptor.streams.count == 2 && descriptor.videoStream != nil && descriptor.audioStream != nil,
        "离线：分轨回执派生成视频 + 音频两条流")
    expect(descriptor.audioStream?.headers["User-Agent"] == "UA",
        "离线：请求头被逐字带到播放描述")
    expect(!descriptor.isMuxed, "离线：分轨描述不是 muxed")
    let muxed = NativeScreenMediaDescriptor(
        pageURL: "https://www.bilibili.com/video/BV1xx411c7mD", title: "m", site: .bilibili,
        isLive: false,
        streams: [NativeScreenMediaStream(
            url: "https://media.example/m", formatID: "18", headers: [:],
            isVideo: true, isAudio: true, isManifest: false
        )],
        note: ""
    )
    expect(muxed.isMuxed, "离线：合流描述被认成 muxed")
    expect(NativeScreenPlaybackState.failed(.noAudioTrack).displayText.contains("声音"),
        "离线：无声失败有一句人话")

    // =========================================================
    // 离线：会话作废 —— 换片 / 停 / 删之后的**过期解析结果不许发布**
    // =========================================================
    guard let device = MTLCreateSystemDefaultDevice() else {
        expect(false, "离线：需要 Metal 设备驱动原生会话作废判据")
        return failures == 0 ? 0 : 1
    }
    let registry = WorldScreenNativeVideoRegistry()

    // ① `stop` 之后回来的结果不许把状态改回播放 / 失败。
    let stopResolver = ScriptedFakeResolver(script: [
        "https://www.twitch.tv/a": .init(
            delay: .milliseconds(600), outcome: .resolved(invalidResolution(pageURL: "https://www.twitch.tv/a"))
        ),
    ])
    let stopCoordinator = NativeScreenPlaybackCoordinator(
        cache: stopResolver, registry: registry, device: device
    )
    let stopTask = Task { @MainActor in
        await stopCoordinator.play(
            objectID: "tv-stop", pageURL: "https://www.twitch.tv/a", quadProvider: { nil }
        )
    }
    try? await Task.sleep(for: .milliseconds(150))
    _ = await stopCoordinator.play(objectID: "tv-stop", pageURL: "https://www.twitch.tv/a", quadProvider: { nil })
    stopCoordinator.stop("tv-stop")
    _ = await stopTask.value
    expect(stopResolver.heights == [2160], "离线：缓存请求保持 2160 高度目标")
    try? await Task.sleep(for: .milliseconds(800))
    expect(stopCoordinator.snapshot(for: "tv-stop")?.state == .stopped,
        "离线：stop 之后回来的过期解析结果不许发布（状态仍是 stopped，实测 \(String(describing: stopCoordinator.snapshot(for: "tv-stop")?.state))）")
    expect(stopCoordinator.snapshot(for: "tv-stop")?.isPlaying == false,
        "离线：stop 之后 isPlaying 仍为 false")
    expect(stopResolver.releases == ["https://www.twitch.tv/a"], "离线：stop 后晚到 ready 的 pin 只释放一次")

    // ② 删电视之后回来的结果不许复活会话 / 留下取帧登记。
    let removeResolver = ScriptedFakeResolver(script: [
        "https://www.twitch.tv/a": .init(
            delay: .milliseconds(600), outcome: .resolved(invalidResolution(pageURL: "https://www.twitch.tv/a"))
        ),
    ])
    let removeCoordinator = NativeScreenPlaybackCoordinator(
        cache: removeResolver, registry: registry, device: device
    )
    let removeTask = Task { @MainActor in
        await removeCoordinator.play(
            objectID: "tv-remove", pageURL: "https://www.twitch.tv/a", quadProvider: { nil }
        )
    }
    try? await Task.sleep(for: .milliseconds(150))
    removeCoordinator.remove("tv-remove")
    _ = await removeTask.value
    try? await Task.sleep(for: .milliseconds(800))
    expect(removeCoordinator.snapshot(for: "tv-remove") == nil,
        "离线：删电视之后回来的过期解析结果不许复活会话")
    expect(!registry.frames().contains { $0.objectID == "tv-remove" },
        "离线：删电视之后渲染器取帧表里也不许留下它")
    expect(removeResolver.releases == ["https://www.twitch.tv/a"], "离线：remove 后晚到 ready 的 pin 被释放")

    let queuedCache = ScriptedFakeResolver(script: [
        "https://www.youtube.com/watch?v=abcdefghijk": .init(delay: .milliseconds(600),
            outcome: .failed(.drmProtected), queued: true),
    ])
    let queuedCoordinator = NativeScreenPlaybackCoordinator(cache: queuedCache, registry: registry, device: device)
    let queuedTask = Task { @MainActor in
        await queuedCoordinator.play(objectID: "tv-queued", pageURL: "https://www.youtube.com/watch?v=abcdefghijk", quadProvider: { nil })
    }
    try? await Task.sleep(for: .milliseconds(100))
    queuedCoordinator.stop("tv-queued")
    _ = await queuedTask.value
    try? await Task.sleep(for: .milliseconds(100))
    expect(queuedCache.releases.count == 1 && queuedCache.cancels.count == 1,
        "离线：stop 后晚到 queued 回执释放 owner 并取消无消费者任务")

    // ③ 换片：旧片（慢）先发起、新片（快）后发起；旧片的失败**不许**覆盖新片。
    let swapResolver = ScriptedFakeResolver(script: [
        "https://www.twitch.tv/slow": .init(delay: .milliseconds(700), outcome: .failed(.drmProtected)),
        "https://www.twitch.tv/fast": .init(
            delay: .milliseconds(50), outcome: .resolved(invalidResolution(pageURL: "https://www.twitch.tv/fast"))
        ),
    ])
    let swapCoordinator = NativeScreenPlaybackCoordinator(
        cache: swapResolver, registry: registry, device: device
    )
    let slowTask = Task { @MainActor in
        await swapCoordinator.play(
            objectID: "tv-swap", pageURL: "https://www.twitch.tv/slow", quadProvider: { nil }
        )
    }
    try? await Task.sleep(for: .milliseconds(120))
    _ = await swapCoordinator.play(
        objectID: "tv-swap", pageURL: "https://www.twitch.tv/fast", quadProvider: { nil }
    )
    _ = await slowTask.value
    try? await Task.sleep(for: .milliseconds(800))
    let swapSnapshot = swapCoordinator.snapshot(for: "tv-swap")
    expect(swapSnapshot?.contentURL == "https://www.twitch.tv/fast",
        "离线：换片后会话记的是新片（实测 \(swapSnapshot?.contentURL ?? "nil")）")
    if case let .failed(.nativeLink(info)) = swapSnapshot?.state,
       info.technicalDescription.contains("drm") {
        expect(false, "离线：换片后先回来的旧失败不许覆盖新片")
    } else {
        expect(true, "离线：换片后先回来的旧失败没有覆盖新片")
    }

    return failures == 0 ? 0 : 1
}

// MARK: 真实链接

final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// 泵主 RunLoop，直到 `work` 完成 —— 解析与 AVPlayer 都靠主队列推进，等待必须让出。
func pump<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        let value = await work()
        box.set(value)
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if semaphore.wait(timeout: .now()) == .success { return box.get() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return box.get()
}

/// 让受控辅助程序把**选中的那几条流**取到临时文件，返回一个本地文件描述。
///
/// 这是"AVPlayer 直连签名地址不够"时**明确**的处理方案：辅助程序自己处理请求头、
/// Range 配额、URL 轮换与重试；我们只解码本地文件，不持有也不打印任何临时地址。
@MainActor
func prepareLocalDescriptor(
    value: ScreenLinkResolutionValue, helper: String, pageURL: String, directory: URL
) -> NativeScreenMediaDescriptor? {
    let base = [
        "--ignore-config", "--no-warnings", "--no-color", "--no-progress",
        "--no-cache-dir", "--no-update", "--no-cookies", "--no-playlist", "--force-overwrites",
    ]
    func download(formatID: String, tag: String) -> URL? {
        let output = directory.appendingPathComponent("\(tag).%(ext)s").path
        let result = runHelper(helper, base + ["-f", formatID, "-o", output, "--", pageURL])
        guard result.status == 0 else {
            let scrubbed = scrubURLs(result.output)
            FileHandle.standardError.write(Data("DOWNLOAD FAIL \(tag) exit=\(result.status) \(scrubbed)\n".utf8))
            return nil
        }
        return findDownloadedFile(in: directory, prefix: tag + ".")
    }
    var streams: [NativeScreenMediaStream] = []
    guard let videoFile = download(formatID: value.video.formatID, tag: "video") else { return nil }
    streams.append(NativeScreenMediaStream(
        url: videoFile.absoluteString, formatID: value.video.formatID, headers: [:],
        isVideo: true, isAudio: value.audio == nil && value.video.hasAudio, isManifest: false
    ))
    if let audio = value.audio {
        guard let audioFile = download(formatID: audio.formatID, tag: "audio") else { return nil }
        streams.append(NativeScreenMediaStream(
            url: audioFile.absoluteString, formatID: audio.formatID, headers: [:],
            isVideo: false, isAudio: true, isManifest: false
        ))
    }
    return NativeScreenMediaDescriptor(
        pageURL: value.pageURL, title: value.title, site: value.site, isLive: value.isLive,
        streams: streams, note: value.note
    )
}

@MainActor
func runHelper(_ helper: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: helper)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    var environment = ["PATH": "", "HOME": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
    if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = tmp }
    process.environment = environment
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func findDownloadedFile(in directory: URL, prefix: String) -> URL? {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )) ?? []
    return items.first {
        $0.lastPathComponent.hasPrefix(prefix) && !$0.lastPathComponent.hasSuffix(".part")
    }
}

/// 诊断输出里抹掉任何 URL（不打印签名地址）。
func scrubURLs(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "https?://\\S+") else {
        return String(text.suffix(300))
    }
    let scrubbed = regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<url>"
    )
    return String(scrubbed.suffix(300))
}

@MainActor var cachedResolvedValue: ScreenLinkResolutionValue?

@MainActor
func runLive(pageURL: String, observationSeconds: Double, audioSamplingOverride: Bool? = nil, videoOnlyOverride: Bool? = nil) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"no_metal_device\"}")
        return 2
    }
    // 受控定位：只认显式开发覆盖（`GMGN_SCREEN_LINK_HELPER`），不查 PATH。
    let diagnosticDeno = ProcessInfo.processInfo.environment["GMGN_SCREEN_LINK_DENO"]
    let resolver = ScreenLinkResolverService.live(
        bundleHelpersDirectory: ProcessInfo.processInfo.environment["GMGN_SCREEN_LINK_HELPERS_DIRECTORY"],
        managedHelpersDirectory: nil,
        allowDevOverride: true,
        javascriptRuntimeName: diagnosticDeno == nil ? nil : "deno",
        javascriptRuntimePath: diagnosticDeno
    )
    // 小高度：探针只证明"真解码出帧"，不下载 4K。
    let diagnosticHeight = ProcessInfo.processInfo.environment["GMGN_SCREEN_LINK_MAX_HEIGHT"]
        .flatMap(Int.init) ?? 360
    let request = ScreenLinkRequest(pageURL: pageURL, preferredMaximumHeight: diagnosticHeight, timeout: .seconds(120))
    let resolved = cachedResolvedValue.map { ScreenLinkResolution.resolved($0) }
        ?? pump(timeout: 135, { await resolver.resolve(request) })
    guard let resolution = resolved else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"resolve_timeout\"}")
        return 2
    }
    guard let value = resolution.value else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"resolve_failed\",\"failure\":\"\(String(describing: resolution.failure))\"}")
        return 2
    }
    cachedResolvedValue = value
    FileHandle.standardError.write(Data("PROBE resolved format=\(value.video.formatID) tapOverride=\(audioSamplingOverride.map(String.init) ?? "default") videoOnly=\(videoOnlyOverride.map(String.init) ?? "default")\n".utf8))
    // 真机 2026-10-03 实测：一个签名地址只允许约 5 次 Range 请求（~20 MB），之后 403。
    // 所以**直链**走"受控辅助程序取到临时文件再本地解码"；**HLS / 直播**（Twitch 那一类）
    // 的清单本身允许多次请求，`AVPlayer` 原生支持，直接流式播放。
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-native-media-\(UUID())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor: NativeScreenMediaDescriptor
    if value.isLive || value.video.isManifest || ProcessInfo.processInfo.environment["GMGN_NATIVE_LINK_DIRECT_STREAM"] == "1" {
        descriptor = NativeScreenMediaDescriptor(resolution: value)
    } else {
        guard let helper = ProcessInfo.processInfo.environment["GMGN_SCREEN_LINK_HELPER"],
              !helper.isEmpty
        else {
            print("{\"verdict\":\"FAILED\",\"reason\":\"helper_env_missing\"}")
            return 2
        }
        guard let local = prepareLocalDescriptor(
            value: value, helper: helper, pageURL: pageURL, directory: directory
        ) else {
            print("{\"verdict\":\"FAILED\",\"reason\":\"download_failed\"}")
            return 2
        }
        descriptor = local
    }
    // Diagnostic-only isolation of the video asset; never changes production stream selection.
    let videoOnly = videoOnlyOverride ?? (ProcessInfo.processInfo.environment["GMGN_NATIVE_LINK_VIDEO_ONLY"] == "1")
    let playbackDescriptor = videoOnly ? NativeScreenMediaDescriptor(
        pageURL: descriptor.pageURL, title: descriptor.title, site: descriptor.site,
        isLive: descriptor.isLive, streams: descriptor.streams.filter { $0.isVideo }, note: descriptor.note
    ) : descriptor
    guard let player = NativeLinkPlayer(device: device, descriptor: playbackDescriptor, audioSamplingOverride: audioSamplingOverride) else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"player_init\"}")
        return 2
    }
    player.start()
    // Track loading/network preparation is separate from the playback observation window.
    let preparationDeadline = Date().addingTimeInterval(90)
    while player.itemStatus == -1 && player.lastErrorDescription == nil && Date() < preparationDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30.0))
    }
    var timeAdvanced = 0.0
    var firstSeconds: Double?
    var observedFailure = false
    let deadline = Date().addingTimeInterval(observationSeconds)
    while Date() < deadline {
        _ = player.copyFrameTexture()
        if player.itemStatus == AVPlayerItem.Status.failed.rawValue || player.lastErrorDescription != nil
            || !player.sourceHTTPFailureStatuses.isEmpty {
            observedFailure = true
        }
        let seconds = player.currentSeconds
        if firstSeconds == nil, seconds > 0 { firstSeconds = seconds }
        timeAdvanced = max(timeAdvanced, seconds - (firstSeconds ?? 0))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30.0))
    }
    // **在 stop() 之前**读诊断：stop() 会把状态改写成 stopped，从而掩盖失败原因。
    let stateBeforeStop = String(describing: player.state)
    let errorBeforeStop = player.lastErrorDescription ?? ""
    let itemStatusBeforeStop = player.itemStatus
    let installed = itemStatusBeforeStop != -1
    let audioTapAttached = player.isAudioTapAttached
    let sampledAudioBuffers = player.audioSampleBufferCount
    let sampledAudioFrames = player.audioSampleFrameCount
    let audioPeakAmplitude = player.audioPeakAmplitude
    let audioTapInstallDetail = player.audioTapInstallDetail
    let isMutedBeforeStop = player.isMuted
    let volumeBeforeStop = player.volume
    let rateBeforeStop = player.playbackRate
    // timeControlStatus / waitingReason / 缓冲健康度也必须在 stop() 之前读：
    // stop() 会把 player 置 nil，读到的 -1 会把"播放中"误报成"未播放"。
    let timeControlStatusBeforeStop = player.timeControlStatus
    let waitingReasonBeforeStop = player.waitingReason
    let likelyToKeepUpBeforeStop = player.isPlaybackLikelyToKeepUp
    let bufferEmptyBeforeStop = player.isPlaybackBufferEmpty
    let sourceHTTPFailuresBeforeStop = player.sourceHTTPFailureStatuses
    let outputMappedSeconds = player.outputHostMappedSeconds
    let loadedRanges = player.loadedTimeRangeSeconds
    let retainedSourceAssetCount = player.retainedSourceAssetCount
    player.stop()
    let releasedSourcesOnStop = player.retainedSourceAssetCount == 0
    // 画面判据与声音判据分开：HLS（`videoIsManifest`）平台**不支持**
    // `AVPlayerItem.audioMix`（Apple 文档原文："An audio mix can only be used with
    // file-based media and is not supported for use with media served using HTTP Live
    // Streaming."），所以 HLS 上 tap 一定挂不上。只要画面真的在放，就不能把
    // "平台不支持声音采样"误报成"播放停滞"，也不能反过来把没采样当声音通过。
    let requiredAdvance = min(20, max(0.5, observationSeconds - 5))
    // A running audio clock and two initial video frames do not establish continuing video output.
    let requiredFrames = max(2, Int(requiredAdvance * 10))
    let videoPassed = !observedFailure && errorBeforeStop.isEmpty
        && itemStatusBeforeStop == AVPlayerItem.Status.readyToPlay.rawValue
        && rateBeforeStop > 0 && value.hasAudio && player.hasAudio && player.decodedFrameCount >= requiredFrames
        && player.gpuCopyCount >= requiredFrames && timeAdvanced >= requiredAdvance
    let audioPassed = audioTapAttached && sampledAudioBuffers > 0 && sampledAudioFrames > 0
        && audioPeakAmplitude > 0
    let verdict: String
    if videoPassed && audioPassed {
        verdict = "PLAYING_NATIVE_SITE_TEXTURE"
    } else if videoPassed && value.video.isManifest {
        verdict = "PLAYING_VIDEO_HLS_AUDIO_TAP_UNSUPPORTED"
    } else {
        verdict = "FAILED_OR_STALLED"
    }
    let report: [String: Any] = [
        "verdict": verdict,
        "diagnosticVideoOnly": videoOnly,
        "site": value.site.rawValue,
        "splitStreams": value.audio != nil,
        "videoFormatID": value.video.formatID,
        "preferredMaximumHeight": diagnosticHeight,
        "videoIsManifest": value.video.isManifest,
        "videoHeaderCount": value.video.headers.count,
        "audioHeaderCount": value.audio?.headers.count ?? -1,
        "localStreams": descriptor.streams.allSatisfy { $0.url.hasPrefix("file:") },
        "descriptorStreams": descriptor.streams.count,
        "hasAudio": value.hasAudio,
        "playerHasAudioTrack": player.hasAudio,
        "isMuted": isMutedBeforeStop,
        "volume": Double(volumeBeforeStop),
        "rate": Double(rateBeforeStop),
        "audioTapAttached": audioTapAttached,
        "audioTapInstallDetail": audioTapInstallDetail,
        "sampledAudioBuffers": sampledAudioBuffers,
        "sampledAudioFrames": sampledAudioFrames,
        "audioPeakAmplitude": Double(audioPeakAmplitude),
        "decodedFrames": player.decodedFrameCount,
        "framePolls": player.framePollCount,
        "frameNoNew": player.frameNoNewCount,
        "frameCopyNil": player.frameCopyNilCount,
        "frameInFlightSkips": player.frameInFlightSkipCount,
        "lastVideoFrameSeconds": player.lastVideoFrameSeconds.isFinite ? player.lastVideoFrameSeconds : -1,
        "outputHostMappedSeconds": outputMappedSeconds.isFinite ? outputMappedSeconds : -1,
        "loadedTimeRanges": loadedRanges,
        "retainedSourceAssets": retainedSourceAssetCount,
        "releasedSourcesOnStop": releasedSourcesOnStop,
        "gpuCopies": player.gpuCopyCount,
        "pixelWidth": player.pixelWidth,
        "pixelHeight": player.pixelHeight,
        "timeAdvancedSeconds": timeAdvanced,
        "requiredAdvanceSeconds": requiredAdvance,
        "requiredFrames": requiredFrames,
        "observedFailure": observedFailure,
        "sourceHTTPFailureStatuses": sourceHTTPFailuresBeforeStop,
        "itemStatus": itemStatusBeforeStop,
        "timeControlStatus": timeControlStatusBeforeStop,
        "waitingReason": waitingReasonBeforeStop,
        "likelyToKeepUp": likelyToKeepUpBeforeStop,
        "bufferEmpty": bufferEmptyBeforeStop,
        "playerError": player.currentItemError ?? "",
        "playerState": stateBeforeStop,
        "playerLastError": errorBeforeStop,
        "itemInstalled": installed,
        "scope": "site page -> controlled resolve -> native decode -> Metal texture; no scene render",
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        print(json)
        fflush(stdout)
    }
    return verdict == "FAILED_OR_STALLED" ? 2 : 0
}

@MainActor
func runPlaylistFailureRaces(cache:any ScreenMediaCaching,endpoint:String) async -> Bool {
    let registry=WorldScreenNativeVideoRegistry()
    let coordinator=NativeScreenPlaybackCoordinator(cache:cache,registry:registry)
    _ = await coordinator.play(objectID:"advance-failure",pageURL:"https://youtube.com/watch?v=bbbbbbbbbbb&list=PLadvanceFail",quadProvider:{nil})
    let deadline=ContinuousClock.now + .seconds(12)
    while ContinuousClock.now < deadline {
        if case .failed = coordinator.snapshot(for:"advance-failure")?.state {break}
        try? await Task.sleep(for:.milliseconds(50))
    }
    let advanceFailed:Bool
    if case .failed = coordinator.snapshot(for:"advance-failure")?.state {advanceFailed=true} else {advanceFailed=false}
    let advanceStopped=advanceFailed && coordinator.metrics(for:"advance-failure") == nil && registry.isEmpty
    coordinator.remove("advance-failure")
    guard let file=ProcessInfo.processInfo.environment["GMGN_PLAYLIST_FIXTURE_FILE"] else {return false}
    let descriptor=NativeScreenMediaDescriptor(pageURL:"https://www.youtube.com/watch?v=bbbbbbbbbbb",title:"failure race",site:.youtube,isLive:false,
        streams:[NativeScreenMediaStream(url:URL(fileURLWithPath:file).absoluteString,formatID:"file",headers:[:],isVideo:true,isAudio:true,isManifest:false)],note:"isolated fault injection")
    let delayed=DelayedReadyFailureCache(descriptor:descriptor)
    let failing=NativeScreenPlaybackCoordinator(cache:delayed,registry:registry)
    _ = await failing.play(objectID:"item-failure",pageURL:descriptor.pageURL,quadProvider:{nil})
    let pollingDeadline=ContinuousClock.now + .seconds(5)
    while !(await delayed.statusStarted),ContinuousClock.now < pollingDeadline {try? await Task.sleep(for:.milliseconds(20))}
    let oldCallback=failing.sessions["item-failure"]?.player?.onStateChange
    let oldEnd=failing.sessions["item-failure"]?.player?.onPlaybackEnded
    oldCallback?(.failed(.noVideoTrack))
    // Deliver the already-captured pre-failure frame callback and late cache ready.
    oldCallback?(.playing)
    oldEnd?()
    try? await Task.sleep(for:.seconds(1))
    let itemFailed:Bool
    if case .failed = failing.snapshot(for:"item-failure")?.state {itemFailed=true} else {itemFailed=false}
    let itemStopped=itemFailed && failing.metrics(for:"item-failure") == nil && registry.isEmpty
        && failing.snapshot(for:"item-failure")?.isPlaying == false && oldCallback != nil
    failing.remove("item-failure")
    print("PLAYLIST_RACES advance_rpc_failure_stopped=\(advanceStopped) item_failure_late_ready_frame_stopped=\(itemStopped)")
    return advanceStopped && itemStopped
}

actor DelayedReadyFailureCache: ScreenMediaCaching {
    let descriptor:NativeScreenMediaDescriptor
    var statusStarted=false
    init(descriptor:NativeScreenMediaDescriptor) {self.descriptor=descriptor}
    func prepare(pageURL:String,maxHeight:Int,consumerID:String) async throws -> ScreenMediaCacheStatus {
        ScreenMediaCacheStatus(cacheKey:"late-ready",state:.downloading,descriptor:descriptor,errorCode:nil)
    }
    func status(cacheKey:String) async throws -> ScreenMediaCacheStatus {
        statusStarted=true
        try? await Task.sleep(for:.milliseconds(800))
        return ScreenMediaCacheStatus(cacheKey:cacheKey,state:.ready,descriptor:descriptor,errorCode:nil)
    }
    func release(cacheKey:String,consumerID:String) async throws {}
    func cancel(cacheKey:String,consumerID:String) async throws {}
}

@MainActor
func runCachedPlaylist(pageURL:String,endpoint:String) async -> Int32 {
    let cache=ScreenMediaCacheClient(endpointFile:URL(fileURLWithPath:endpoint))
    let coordinator=NativeScreenPlaybackCoordinator(cache:cache,registry:WorldScreenNativeVideoRegistry())
    _ = await coordinator.play(objectID:"playlist-probe",pageURL:pageURL,quadProvider:{nil})
    let deadline=ContinuousClock.now + .seconds(20)
    var first=false,advanced=false,silent=true
    while ContinuousClock.now < deadline {
        let session=coordinator.snapshot(for:"playlist-probe"),metric=coordinator.metrics(for:"playlist-probe")
        if let metric,metric.decodedFrames > 0 {silent = silent && metric.isMuted && metric.volume == 0}
        if session?.playlist?.currentIndex == 1,(metric?.decodedFrames ?? 0) >= 5 {first=true}
        if first,session?.playlist?.currentIndex == 2,(metric?.decodedFrames ?? 0) >= 5 {advanced=true;break}
        try? await Task.sleep(for:.milliseconds(50))
    }
    coordinator.stop("playlist-probe")
    try? await Task.sleep(for:.seconds(3))
    let stopped=coordinator.snapshot(for:"playlist-probe")?.state == .stopped
    let late=Task { await coordinator.play(objectID:"late-playlist",pageURL:"https://youtube.com/playlist?list=PLlate",quadProvider:{nil}) }
    try? await Task.sleep(for:.milliseconds(100))
    coordinator.stop("late-playlist")
    _ = await late.value
    try? await Task.sleep(for:.milliseconds(300))
    let lateStopped=coordinator.snapshot(for:"late-playlist")?.state == .stopped
    let races=await runPlaylistFailureRaces(cache:cache,endpoint:endpoint)
    print("PLAYLIST_PROBE first_requested_video=\(first) actual_ended_advanced=\(advanced) stopped=\(stopped) late_import_stopped=\(lateStopped) failure_races=\(races) silent=\(silent) verdict=\(first && advanced && stopped && lateStopped && races && silent ? "PASS" : "FAIL")")
    return first && advanced && stopped && lateStopped && races && silent ? 0 : 2
}

@MainActor
func runCached(pageURL: String, endpoint: String, observationSeconds: Double) async -> Int32 {
    let cache = ScreenMediaCacheClient(endpointFile: URL(fileURLWithPath: endpoint))
    let registry = WorldScreenNativeVideoRegistry()
    let coordinator = NativeScreenPlaybackCoordinator(cache: cache, registry: registry, device: MTLCreateSystemDefaultDevice())
    let began = ContinuousClock.now
    _ = await coordinator.play(objectID: "cache-probe", pageURL: pageURL, quadProvider: { nil })
    let firstFrameLimit = Double(ProcessInfo.processInfo.environment["GMGN_CACHE_FIRST_FRAME_TIMEOUT"] ?? "630") ?? 630
    let readyDeadline = ContinuousClock.now + .seconds(firstFrameLimit)
    while coordinator.metrics(for: "cache-probe")?.decodedFrames ?? 0 == 0, ContinuousClock.now < readyDeadline {
        if case .failed = coordinator.snapshot(for: "cache-probe")?.state { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    let initialSeconds = coordinator.metrics(for: "cache-probe")?.currentSeconds ?? 0
    if (coordinator.metrics(for: "cache-probe")?.decodedFrames ?? 0) > 0 {
        let firstFrameCacheState = coordinator.snapshot(for: "cache-probe")?.cacheState?.rawValue ?? "missing"
        let firstFrameMetrics = coordinator.metrics(for: "cache-probe")
        print("CACHE_FIRST_FRAME elapsed=\(began.duration(to: .now)) cacheState=\(firstFrameCacheState) frames=\(firstFrameMetrics?.decodedFrames ?? 0) gpuCopies=\(firstFrameMetrics?.gpuCopies ?? 0)")
        fflush(stdout)
    }
    if (coordinator.metrics(for: "cache-probe")?.decodedFrames ?? 0) > 0,
       !ScreenMediaCacheClient.isYouTubePlaylist(pageURL) {
        _ = await coordinator.play(objectID: "cache-probe", pageURL: pageURL, quadProvider: { nil })
    }
    try? await Task.sleep(for: .seconds(observationSeconds))
    let metric = coordinator.metrics(for: "cache-probe")
    let liveFixture = ProcessInfo.processInfo.environment["GMGN_CACHE_LIVE_FIXTURE"] == "1"
    let silenceRequired = ProcessInfo.processInfo.environment["GMGN_NATIVE_LINK_SILENT"] == "1"
    let audioValid = liveFixture ? (metric?.isLive == true && metric?.hasAudio == true) :
        (metric?.sampledAudioFrames ?? 0) > 0 || (metric?.isManifest == true && metric?.hasAudio == true
            && metric?.audioTapInstallDetail == "unsupported:hls-manifest")
    let silent = !silenceRequired || (metric?.isMuted == true && metric?.volume == 0)
    let advanced = (metric?.currentSeconds ?? 0) - initialSeconds
    let passed = (metric?.decodedFrames ?? 0) >= 200 && (metric?.gpuCopies ?? 0) >= 200 && audioValid && silent
        && advanced >= 19
    print("CACHE_PROBE frames=\(metric?.decodedFrames ?? 0) gpuCopies=\(metric?.gpuCopies ?? 0) audioFrames=\(metric?.sampledAudioFrames ?? 0) advanced=\(advanced) silent=\(silent) live=\(metric?.isLive ?? false) cacheState=\(coordinator.snapshot(for: "cache-probe")?.cacheState?.rawValue ?? "missing") verdict=\(passed ? "PASS" : "FAIL")")
    print("CACHE_PROBE itemStatus=\(metric?.itemStatus ?? -1) timeControl=\(metric?.timeControlStatus ?? -1) hasAudio=\(metric?.hasAudio ?? false) bufferEmpty=\(metric?.isPlaybackBufferEmpty ?? true) bufferFull=\(metric?.isPlaybackBufferFull ?? false)")
    print("CACHE_PROBE preparationPhase=\(metric?.preparationPhase ?? "missing") httpStatuses=\(metric?.sourceHTTPFailureStatuses ?? []) isManifest=\(metric?.isManifest ?? false)")
    coordinator.stop("cache-probe")
    try? await Task.sleep(for: .milliseconds(500))
    return passed ? 0 : 2
}

@main struct Probe {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count >= 2 {
            let pageURL = arguments[1]
            let seconds = arguments.count >= 3 ? (Double(arguments[2]) ?? 20) : 20
            let clamped = min(max(seconds, 5), 180)
            if let endpoint = ProcessInfo.processInfo.environment["GMGN_MEDIA_CACHE_ENDPOINT"] {
                if ProcessInfo.processInfo.environment["GMGN_CACHE_PLAYLIST_FIXTURE"] == "1" {
                    exit(await runCachedPlaylist(pageURL:pageURL,endpoint:endpoint))
                }
                exit(await runCached(pageURL: pageURL, endpoint: endpoint, observationSeconds: clamped))
            }
            if ProcessInfo.processInfo.environment["GMGN_NATIVE_LINK_COMPARE_VARIANTS"] == "1" {
                _ = runLive(pageURL: pageURL, observationSeconds: clamped, audioSamplingOverride: true, videoOnlyOverride: false)
                _ = runLive(pageURL: pageURL, observationSeconds: clamped, audioSamplingOverride: false, videoOnlyOverride: false)
                exit(runLive(pageURL: pageURL, observationSeconds: clamped, audioSamplingOverride: false, videoOnlyOverride: true))
            }
            exit(runLive(pageURL: pageURL, observationSeconds: clamped))
        } else {
            exit(await runOfflineChecks())
        }
    }
}
"""##

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-native-site-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

var sources: [String] = []
for source in productionSources {
    let destination = temporary.appendingPathComponent(source.name)
    try FileManager.default.copyItem(
        at: source.dir.appendingPathComponent(source.name), to: destination
    )
    if source.name == "NativeScreenPlaybackCoordinator.swift" {
        // Access-only fixture seam in a temporary copy, not a production API or behavior change.
        let original=try String(contentsOf:destination,encoding:.utf8)
        guard original.components(separatedBy:"private struct Session").count == 2,
              original.components(separatedBy:"private var sessions:").count == 2 else {fatalError("Session fixture seam changed")}
        try original.replacingOccurrences(of:"private struct Session",with:"struct Session")
            .replacingOccurrences(of:"private var sessions:",with:"var sessions:")
            .write(to:destination,atomically:true,encoding:.utf8)
    }
    if source.name == "NativeLinkPlayer.swift",
       ProcessInfo.processInfo.environment["GMGN_NATIVE_LINK_SILENT"] == "1" {
        let original = try String(contentsOf: destination, encoding: .utf8)
        let marker = "player.isMuted = false"
        guard original.components(separatedBy: marker).count == 2 else {
            fatalError("Silent fixture requires exactly one native player mute installation point")
        }
        try original.replacingOccurrences(of: marker, with: "player.isMuted = true; player.volume = 0")
            .write(to: destination, atomically: true, encoding: .utf8)
    }
    sources.append(destination.path)
}
let program = temporary.appendingPathComponent("Probe.swift")
try innerProgram.write(to: program, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("probe")

func runCapturing(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let compile = try runCapturing(
    "/usr/bin/swiftc", ["-j1", "-parse-as-library"] + sources + [program.path, "-o", binary.path]
)
guard compile.status == 0 else {
    FileHandle.standardError.write(Data("PROBE COMPILE FAILED\n\(compile.output)\n".utf8))
    exit(70)
}
let forwarded = Array(CommandLine.arguments.dropFirst())
let run = Process()
run.executableURL = binary
run.arguments = forwarded
run.standardOutput = FileHandle.standardOutput
run.standardError = FileHandle.standardError
try run.run()
run.waitUntilExit()
exit(run.terminationStatus)
