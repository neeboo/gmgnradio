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
final class ScriptedFakeResolver: ScreenLinkResolving, @unchecked Sendable {
    struct Entry: Sendable {
        let delay: Duration
        let outcome: ScreenLinkResolution
    }
    private let script: [String: Entry]
    init(script: [String: Entry]) { self.script = script }
    func resolve(_ request: ScreenLinkRequest) async -> ScreenLinkResolution {
        guard let entry = script[request.pageURL] else { return .failed(.unsupportedSite("")) }
        try? await Task.sleep(for: entry.delay)
        return entry.outcome
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
        resolver: stopResolver, registry: registry, device: device
    )
    let stopTask = Task { @MainActor in
        await stopCoordinator.play(
            objectID: "tv-stop", pageURL: "https://www.twitch.tv/a", quadProvider: { nil }
        )
    }
    try? await Task.sleep(for: .milliseconds(150))
    stopCoordinator.stop("tv-stop")
    _ = await stopTask.value
    try? await Task.sleep(for: .milliseconds(800))
    expect(stopCoordinator.snapshot(for: "tv-stop")?.state == .stopped,
        "离线：stop 之后回来的过期解析结果不许发布（状态仍是 stopped，实测 \(String(describing: stopCoordinator.snapshot(for: "tv-stop")?.state))）")
    expect(stopCoordinator.snapshot(for: "tv-stop")?.isPlaying == false,
        "离线：stop 之后 isPlaying 仍为 false")

    // ② 删电视之后回来的结果不许复活会话 / 留下取帧登记。
    let removeResolver = ScriptedFakeResolver(script: [
        "https://www.twitch.tv/a": .init(
            delay: .milliseconds(600), outcome: .resolved(invalidResolution(pageURL: "https://www.twitch.tv/a"))
        ),
    ])
    let removeCoordinator = NativeScreenPlaybackCoordinator(
        resolver: removeResolver, registry: registry, device: device
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

    // ③ 换片：旧片（慢）先发起、新片（快）后发起；旧片的失败**不许**覆盖新片。
    let swapResolver = ScriptedFakeResolver(script: [
        "https://www.twitch.tv/slow": .init(delay: .milliseconds(700), outcome: .failed(.drmProtected)),
        "https://www.twitch.tv/fast": .init(
            delay: .milliseconds(50), outcome: .resolved(invalidResolution(pageURL: "https://www.twitch.tv/fast"))
        ),
    ])
    let swapCoordinator = NativeScreenPlaybackCoordinator(
        resolver: swapResolver, registry: registry, device: device
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

@MainActor
func runLive(pageURL: String, observationSeconds: Double) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"no_metal_device\"}")
        return 2
    }
    // 受控定位：只认显式开发覆盖（`GMGN_SCREEN_LINK_HELPER`），不查 PATH。
    let resolver = ScreenLinkResolverService.live(
        bundleHelpersDirectory: nil,
        managedHelpersDirectory: nil,
        allowDevOverride: true
    )
    // 小高度：探针只证明"真解码出帧"，不下载 4K。
    let request = ScreenLinkRequest(pageURL: pageURL, preferredMaximumHeight: 360, timeout: .seconds(60))
    guard let resolution = pump(timeout: 75, { await resolver.resolve(request) }) else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"resolve_timeout\"}")
        return 2
    }
    guard let value = resolution.value else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"resolve_failed\",\"failure\":\"\(String(describing: resolution.failure))\"}")
        return 2
    }
    // 真机 2026-10-03 实测：一个签名地址只允许约 5 次 Range 请求（~20 MB），之后 403。
    // 所以**直链**走"受控辅助程序取到临时文件再本地解码"；**HLS / 直播**（Twitch 那一类）
    // 的清单本身允许多次请求，`AVPlayer` 原生支持，直接流式播放。
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-native-media-\(UUID())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor: NativeScreenMediaDescriptor
    if value.isLive || value.video.isManifest {
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
    guard let player = NativeLinkPlayer(device: device, descriptor: descriptor) else {
        print("{\"verdict\":\"FAILED\",\"reason\":\"player_init\"}")
        return 2
    }
    player.start()
    var timeAdvanced = 0.0
    var firstSeconds: Double?
    let deadline = Date().addingTimeInterval(observationSeconds)
    while Date() < deadline {
        _ = player.copyFrameTexture()
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
    player.stop()
    let passed = value.hasAudio && player.hasAudio && player.decodedFrameCount >= 2
        && player.gpuCopyCount >= 2 && timeAdvanced >= 0.5
        && audioTapAttached && sampledAudioBuffers > 0 && sampledAudioFrames > 0
        && audioPeakAmplitude > 0
    let report: [String: Any] = [
        "verdict": passed ? "PLAYING_NATIVE_SITE_TEXTURE" : "FAILED_OR_STALLED",
        "site": value.site.rawValue,
        "splitStreams": value.audio != nil,
        "videoFormatID": value.video.formatID,
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
        "gpuCopies": player.gpuCopyCount,
        "pixelWidth": player.pixelWidth,
        "pixelHeight": player.pixelHeight,
        "timeAdvancedSeconds": timeAdvanced,
        "itemStatus": itemStatusBeforeStop,
        "timeControlStatus": player.timeControlStatus,
        "playerError": player.currentItemError ?? "",
        "playerState": stateBeforeStop,
        "playerLastError": errorBeforeStop,
        "itemInstalled": installed,
        "scope": "site page -> controlled resolve -> native decode -> Metal texture; no scene render",
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    return passed ? 0 : 2
}

@main struct Probe {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count >= 2 {
            let pageURL = arguments[1]
            let seconds = arguments.count >= 3 ? (Double(arguments[2]) ?? 20) : 20
            let clamped = min(max(seconds, 5), 180)
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
let run = try runCapturing(binary.path, forwarded)
FileHandle.standardOutput.write(Data(run.output.utf8))
exit(run.status)
