import Foundation

// MARK: - 网站链接原生播放：**跨平台**的请求 / 回执 / 取消 / 错误

/// 这一次播放请求的**网站类别**。与"谁来解析"无关（纯分类）：Windows 适配层与 macOS
/// 适配层、以及将来的任何解析器都读同一份。
enum ScreenLinkSite: String, Codable, Equatable, Sendable, CaseIterable {
    case youtube
    case bilibili
    case twitch
    case other

    /// 面板 / 回执上给人看的那一个名字。
    var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .bilibili: "哔哩哔哩"
        case .twitch: "Twitch"
        case .other: "网站"
        }
    }
}

/// 一次解析请求。**只有用户粘的那个网站链接**（原始页面 URL）与几个上限；
/// 没有任何凭据、cookie、浏览器导入、地区/付费绕过开关。
struct ScreenLinkRequest: Equatable, Sendable {
    /// 用户给的公开网站链接（原始页面地址）。
    let pageURL: String
    /// 希望的最高高度（像素）。`nil` = 不设上限，由解析器选最佳。
    let preferredMaximumHeight: Int?
    /// 是否允许"视频轨 + 音频轨"分开取。`false` 时只接受**自带声音的合流格式**
    /// （用于明确不接受分轨的场景；默认 `true`，因为 YouTube 的高清几乎都是分轨）。
    let allowsSeparateStreams: Bool
    /// 整次解析（含子进程启动）的上限。
    let timeout: Duration

    init(
        pageURL: String,
        preferredMaximumHeight: Int? = 2160,
        allowsSeparateStreams: Bool = true,
        timeout: Duration = .seconds(45)
    ) {
        self.pageURL = pageURL
        self.preferredMaximumHeight = preferredMaximumHeight
        self.allowsSeparateStreams = allowsSeparateStreams
        self.timeout = timeout
    }
}

/// 解析出来的**一条流**。
///
/// ⚠️ `url` 是**带签名的临时地址**：它只在**内存**里活，绝不落盘、绝不进日志、绝不进
/// 面板/回执。要写日志只能过 `ScreenLinkRedaction.redacted(_:)`。
struct ScreenLinkStream: Equatable, Sendable {
    /// 带签名的媒体地址（临时，运行时用）。
    let url: String
    let formatID: String
    let container: String
    let videoCodec: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bandwidth: Int?
    /// 这是 HLS / DASH 清单而不是单个媒体文件。
    let isManifest: Bool
    let hasVideo: Bool
    let hasAudio: Bool
    /// 取这条流时**服务端要求的请求头**（User-Agent / Referer 之类）。
    ///
    /// 它**不是凭据**：解析器从不产出 cookie / Authorization。播放器必须**逐字**带上它，
    /// 否则真实回执常见 403（"明明解析出来了却放不出"）。
    let headers: [String: String]

    /// 日志口径：只说格式，不说地址。
    var technicalDescription: String {
        var pieces = ["format=\(formatID)", "container=\(container)"]
        if let videoCodec { pieces.append("v=\(videoCodec)") }
        if let audioCodec { pieces.append("a=\(audioCodec)") }
        if let width, let height { pieces.append("\(width)x\(height)") }
        if isManifest { pieces.append("manifest") }
        return pieces.joined(separator: " ")
    }
}

/// 一次**成功**的解析结果：标题、时长、视频/音频流与请求头。
///
/// 刻意**不实现 `Codable`**：解析地址（含签名）是**派生结论**，不许落盘、不许当事实。
/// 落盘的永远是用户粘的那个原始网站链接（`WorldScreenContent.url`）。
struct ScreenLinkResolutionValue: Equatable, Sendable {
    let pageURL: String
    let site: ScreenLinkSite
    let title: String
    let durationSeconds: Double?
    let isLive: Bool
    let video: ScreenLinkStream
    /// 分轨时的音频流。`nil` = 视频流自带声音。
    let audio: ScreenLinkStream?
    let resolvedAt: Date
    /// 地址自身的过期时刻（解析器能读到时）。`nil` = 未知。
    let expiresAt: Date?
    let extractor: String
    /// 工程口径的一句话（**不是**给用户的）。不含地址、不含凭据。
    let note: String

    /// 有没有声音。**"分轨 + 有音频轨"与"合流"都算有声音**。
    var hasAudio: Bool {
        audio != nil || video.hasAudio
    }

    /// 全部需要请求头的流（视频 + 音频）。
    var streams: [ScreenLinkStream] {
        audio.map { [video, $0] } ?? [video]
    }
}

/// 「为什么放不了」的**具名**原因。一条都不许静默。
///
/// 分两类听众：`panelText` 是给用户的**一句人话**（一个数字都不许有），
/// `technicalDescription` 是日志/`details` 口径（可以带码，但不许带地址/凭据）。
enum ScreenLinkFailure: Error, Equatable, Sendable {
    case cancelled
    case emptyInput
    case malformedURL
    case unsupportedScheme(String)
    case unsupportedSite(String)
    /// 找不到内置辅助程序。`searched` 是**受控的查找位置**（不是用户 PATH）。
    case missingHelper(searched: [String])
    case helperNotExecutable(String)
    case helperIntegrityMismatch(expected: String, actual: String)
    case helperVersionMismatch(expected: String, actual: String)
    case helperLaunchFailed(String)
    case helperTimedOut
    /// 网络层不通（DNS / 连不上 / 连接被重置 / 被中间设备掐断）。
    case network
    case helperFailed(code: Int32, summary: String)
    /// 需要登录 / 私享 / 会员。
    case loginRequired
    case membersOnly
    case geoRestricted
    case drmProtected
    case notFound
    case noPlayableStream
    /// 辅助程序返回的 JSON 读不出来。
    case outputUnreadable(String)
    /// 这个平台没有进程适配层（Windows 那一半还没接）。
    case unsupportedPlatform

    /// 用户看到的那一句。**一个 ASCII 数字都不许有**（错误码不外泄）。
    var panelText: String {
        switch self {
        case .cancelled: "已经取消。"
        case .emptyInput: "还没说要放什么 —— 粘一个视频链接。"
        case .malformedURL: "这个链接读不出来，换一条再试。"
        case .unsupportedScheme: "只支持网站链接（https）。"
        case .unsupportedSite: "这个网站的链接还放不了，可以试试 YouTube、哔哩哔哩或 Twitch。"
        case .missingHelper: "这台电视现在缺少播放组件，暂时放不了网站链接。"
        case .helperNotExecutable, .helperLaunchFailed: "播放组件启动不起来，暂时放不了。"
        case .helperIntegrityMismatch, .helperVersionMismatch: "播放组件不对劲，先用官方的嵌入方式放吧。"
        case .helperTimedOut: "等了很久也没能取到视频，网络可能不通。"
        case .network: "这台电视连不上网络（可能断网了）。"
        case .helperFailed: "这条视频取不出来，换一条再试。"
        case .loginRequired: "这条视频要登录才能看，先在页面里登录再试。"
        case .membersOnly: "这条视频要付费或会员才能看。"
        case .geoRestricted: "这条视频在当前地区看不了。"
        case .drmProtected: "这条视频有版权保护，放不了。"
        case .notFound: "这条视频不存在，可能已经被删了。"
        case .noPlayableStream: "这条视频没有能放的画面。"
        case .outputUnreadable: "没能读懂这条视频的信息，换一条再试。"
        case .unsupportedPlatform: "这个系统上还放不了网站链接。"
        }
    }

    /// 日志 / `details` 口径。**不带地址、不带凭据**。
    var technicalDescription: String {
        switch self {
        case .cancelled: "cancelled"
        case .emptyInput: "empty_input"
        case .malformedURL: "malformed_url"
        case let .unsupportedScheme(scheme): "unsupported_scheme=\(scheme.isEmpty ? "(empty)" : scheme)"
        case let .unsupportedSite(host): "unsupported_site=\(host.isEmpty ? "(empty)" : host)"
        case let .missingHelper(searched):
            "helper_missing searched=\(searched.joined(separator: ","))"
        case let .helperNotExecutable(path): "helper_not_executable=\(path)"
        case let .helperIntegrityMismatch(expected, actual):
            "helper_sha256_mismatch expected=\(expected) actual=\(actual)"
        case let .helperVersionMismatch(expected, actual):
            "helper_version_mismatch expected=\(expected) actual=\(actual)"
        case let .helperLaunchFailed(reason): "helper_launch_failed=\(reason)"
        case .helperTimedOut: "helper_timed_out"
        case .network: "network_unreachable"
        case let .helperFailed(code, summary):
            "helper_failed code=\(code) summary=\(summary)"
        case .loginRequired: "login_required"
        case .membersOnly: "members_only"
        case .geoRestricted: "geo_restricted"
        case .drmProtected: "drm_protected"
        case .notFound: "not_found"
        case .noPlayableStream: "no_playable_stream"
        case let .outputUnreadable(reason): "output_unreadable=\(reason)"
        case .unsupportedPlatform: "unsupported_platform"
        }
    }
}

/// 一次解析的**回执**。
enum ScreenLinkResolution: Equatable, Sendable {
    case resolved(ScreenLinkResolutionValue)
    case failed(ScreenLinkFailure)

    var value: ScreenLinkResolutionValue? {
        if case let .resolved(value) = self { return value }
        return nil
    }

    var failure: ScreenLinkFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }

    var isResolved: Bool { value != nil }
}

// MARK: - 协议

/// 链接解析的**跨平台协议**：请求进去，回执出来；取消独立成为一条。
///
/// 调用方只认这一个协议，不认"进程"也不认"平台"。macOS 适配层是
/// `ScreenLinkResolverService` + `PosixScreenLinkProcessRunner`；Windows 适配层将来接
/// 同一份协议（进程与原生播放各自适配），因此请求/回执/取消/错误的形状**一个字节都不动**。
protocol ScreenLinkResolving: AnyObject, Sendable {
    /// 解析一个网站链接。会尊重 `Task` 取消；`request.timeout` 到点也必须返回具名失败。
    func resolve(_ request: ScreenLinkRequest) async -> ScreenLinkResolution
}

/// 可以**取消**的一条解析。`ScreenLinkResolverService` 自己实现；测试用假实现也走它。
protocol ScreenLinkCancelling: Sendable {
    /// 取消**当前**这次解析（若还在跑）。进程会被终止，回执是 `.failed(.cancelled)`。
    func cancel()
}
