import Foundation

// MARK: - 原生媒体描述：**跨平台**（从解析回执派生，不含 AVFoundation）

/// 一条要交给原生播放器的媒体流。
///
/// ⚠️ `url` 是带签名的临时地址（运行时内存）。
struct NativeScreenMediaStream: Equatable, Sendable {
    let url: String
    /// 解析器给的格式 id（诊断用，**不是地址**）。
    let formatID: String
    /// 服务端要求的请求头（逐字带上；不含 cookie / Authorization）。
    let headers: [String: String]
    let isVideo: Bool
    let isAudio: Bool
    let isManifest: Bool
}

/// 原生播放器的输入：一到两条流（分轨 = 视频 + 音频；合流 = 一条）。
///
/// 与 `ScreenLinkResolutionValue` 一样**不实现 `Codable`**：它是派生结论，不许落盘。
struct NativeScreenMediaDescriptor: Equatable, Sendable {
    let pageURL: String
    let title: String
    let site: ScreenLinkSite
    let isLive: Bool
    let streams: [NativeScreenMediaStream]
    /// 解析回执里的工程口径（不含地址）。
    let note: String

    var videoStream: NativeScreenMediaStream? { streams.first { $0.isVideo } }
    /// 只数**独立**的音频轨：合流的那一条身兼两职，不算独立音频。
    var audioStream: NativeScreenMediaStream? {
        streams.first { $0.isAudio && !$0.isVideo }
    }

    /// 从解析回执派生。**只搬运字段**，不改任何地址。
    init(resolution: ScreenLinkResolutionValue) {
        self.pageURL = resolution.pageURL
        self.title = resolution.title
        self.site = resolution.site
        self.isLive = resolution.isLive
        self.note = resolution.note
        var streams: [NativeScreenMediaStream] = [
            NativeScreenMediaStream(
                url: resolution.video.url, formatID: resolution.video.formatID,
                headers: resolution.video.headers,
                isVideo: true, isAudio: resolution.video.hasAudio,
                isManifest: resolution.video.isManifest
            )
        ]
        if let audio = resolution.audio {
            streams.append(NativeScreenMediaStream(
                url: audio.url, formatID: audio.formatID, headers: audio.headers,
                isVideo: false, isAudio: true, isManifest: audio.isManifest
            ))
        }
        self.streams = streams
    }

    init(
        pageURL: String, title: String, site: ScreenLinkSite, isLive: Bool,
        streams: [NativeScreenMediaStream], note: String
    ) {
        self.pageURL = pageURL
        self.title = title
        self.site = site
        self.isLive = isLive
        self.streams = streams
        self.note = note
    }

    /// 视频轨自带声音（没有独立音频轨）。
    var isMuxed: Bool { audioStream == nil && (videoStream?.isAudio ?? false) }
}

/// 原生播放的具名状态。
enum NativeScreenPlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case stopped
    case failed(NativeScreenPlaybackFailure)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .idle: "未开始"
        case .preparing: "正在取流"
        case .playing: "播放中"
        case .stopped: "已停止"
        case let .failed(failure): "失败：\(failure.panelText)"
        }
    }
}

/// 原生播放的具名失败。
enum NativeScreenPlaybackFailure: Error, Equatable, Sendable {
    case metalUnavailable
    case noVideoTrack
    /// 解析出来有音频轨，但播放器加载不到它 —— **绝不**降级成无声视频。
    case noAudioTrack
    case assetUnreadable(String)
    case frameOutputUnavailable
    case cancelled

    var panelText: String {
        switch self {
        case .metalUnavailable: "这台电视现在画不出来，暂时放不了。"
        case .noVideoTrack: "这条视频没有能放的画面。"
        case .noAudioTrack: "这条视频的声音取不出来，换一条再试。"
        case .assetUnreadable: "这条视频打不开，换一条再试。"
        case .frameOutputUnavailable: "这条视频的画面取不出来，换一条再试。"
        case .cancelled: "已经取消。"
        }
    }

    var technicalDescription: String {
        switch self {
        case .metalUnavailable: "metal_unavailable"
        case .noVideoTrack: "no_video_track"
        case .noAudioTrack: "no_audio_track"
        case let .assetUnreadable(reason): "asset_unreadable=\(reason)"
        case .frameOutputUnavailable: "frame_output_unavailable"
        case .cancelled: "cancelled"
        }
    }
}

/// 原生媒体后端。macOS 侧是 `NativeLinkPlayer`；Windows 侧将来接同一份协议
/// （**OS 进程与原生播放各自适配**，描述与失败形状一个字不动）。
@MainActor
protocol NativeScreenMediaPlaying: AnyObject {
    var state: NativeScreenPlaybackState { get }
    var hasAudio: Bool { get }
    func start()
    func stop()
}
