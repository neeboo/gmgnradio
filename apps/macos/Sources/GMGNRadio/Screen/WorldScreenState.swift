import Foundation

// MARK: - 一块屏幕的状态（纯值：不依赖 AppKit / WebKit）

/// 一块屏幕的**具名**状态。失败必须是"能读出来的一句话"，不是静默。
enum WorldScreenSurfaceState: Equatable, Sendable {
    case idle
    case loading(url: String)
    case playing(url: String)
    case stopped
    case failed(WorldScreenFailure)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// 面板/工具回执上那一行。
    var displayText: String {
        switch self {
        case .idle: "未开始"
        case let .loading(url): "准备中：\(URL(string: url)?.host ?? url)"
        case let .playing(url): "播放中：\(URL(string: url)?.host ?? url)"
        case .stopped: "已停止"
        case let .failed(failure): "失败：\(failure.errorDescription)"
        }
    }
}

/// 加载失败的原因。**每一句都要能指认到底断在哪一关**。
enum WorldScreenFailure: Error, Equatable, Sendable {
    /// 网络层：DNS / 连不上 / TLS / 连接被重置。
    case network(String)
    /// 页面**加载成功但明确报错**：HTTP 4xx/5xx。
    case httpStatus(Int)
    /// 20 秒没有 `didFinish`。
    case timeout
    /// 被 WebKit 拒绝（内容策略、跨域、帧被拒）。
    case blocked(String)
    /// **页面侧的播放器**报了错：官方播放器自己画了一块错误界面（真机 2026-10-02 的
    /// 「视频播放器配置错误 / 错误 153」就是它）。这一条以前根本收不到 ——
    /// `didFinish` 成功、状态就变成 `playing`，于是用户看到的是一块**显示着错误页的
    /// "播放中"**。载荷是**已经说成人话**的那一句（`WorldScreenPlayerFailure.panelText`）。
    case playerRefused(WorldScreenPlayerFailure)

    var errorDescription: String {
        switch self {
        case let .network(reason):
            "网络不通或连接被中断（\(reason)）。"
        case let .httpStatus(code):
            "嵌入页返回 HTTP \(code)（可能是被拒绝或需要登录）。"
        case .timeout:
            "20 秒内没有加载完成（网络慢，或嵌入页在等登录）。"
        case let .blocked(reason):
            "嵌入被拒绝（\(reason)）。"
        case let .playerRefused(reason):
            // 工具与日志口径：要带得上播放器给的那个码，工程师照着它才能定位。
            reason.technicalDescription
        }
    }

    /// **面板上那一句**：同一件事说给普通人听。
    ///
    /// 与 `errorDescription` 是两个听众、不是两份真相：那一份是**工具与日志**口径
    /// （要带 HTTP 码、要带 WebKit 给的原因，工程师照着它才能定位），这一份只有一句
    /// "放不出来，大概因为什么"。真机 2026-10-02 用户原话：「不要搞为什么然后给展开折叠，
    /// 普通人看得懂吗，里面一堆 key-value 的东西」—— 所以底层的 `reason` 不进面板。
    var panelText: String {
        switch self {
        case .network:
            "这台电视连不上网络（可能断网了）。"
        case .httpStatus:
            "对方没让放（有时候得先在画面里自己登录）。"
        case .timeout:
            "等了 20 秒还没打开（网络慢，或者页面在等登录）。"
        case .blocked:
            "这个视频不让嵌进来放。"
        case let .playerRefused(reason):
            reason.panelText
        }
    }
}

// MARK: - 官方播放器自己报的那一类失败

/// 「**页面里那块播放器**为什么不出画」的具名原因。
///
/// 与 `WorldScreenFailure` 是两件事：那一组是"我们这边加载断了"（网络 / HTTP / 超时 /
/// WebKit 拒绝），这一组是"页面加载成功了，但播放器在里面拒绝播放"。真机 2026-10-02
/// 用户看到的正是后者，而它此前**根本没有任何一条判据收它**。
///
/// 两句话、两个听众（与 `WorldScreenFailure` 同一纪律）：
/// * `panelText` —— 面板 / 回执上那一句，**不许出现任何错误码**；
/// * `technicalDescription` —— 日志与工具 `details` 口径，带得上码。
enum WorldScreenPlayerFailure: Equatable, Sendable {
    /// 这段视频不让嵌（YouTube 101 / 150；Twitch `NoParent`）。
    case refusedEmbedding
    /// 播放器不接受**承载它的那个页面的来源**（YouTube 153 / 152-4）。
    case misconfigured
    /// 视频不存在 / 已删除（YouTube 100）。
    case notFound
    /// 链接里的视频编号无效（YouTube 2）。
    case badIdentifier
    /// 网页播放器放不出来（YouTube 5）。
    case unsupported
    /// 播放器报了一个我们没有映射的码 —— 也**不许静默**。
    case unmapped(Int)

    /// YouTube 官方 IFrame API 的 `onError` 码 → 具名原因。
    init(youtubeCode code: Int) {
        switch code {
        case 2: self = .badIdentifier
        case 5: self = .unsupported
        case 100: self = .notFound
        case 101, 150: self = .refusedEmbedding
        case 153, 152: self = .misconfigured
        default: self = .unmapped(code)
        }
    }

    /// 从**页面文字**里认。这是给"顶层直载嵌入页"那一路留的**回归网**：包装页里
    /// 播放器住在跨域 iframe 里，主文档读不到它的文字，所以这一条在主路径上不会命中
    /// —— 它命中的是"哪天有人把 `load(url:)` 改回直载"。下面每一句都是**实测原文**。
    init?(pageText text: String) {
        if text.contains("视频播放器配置错误") || text.contains("错误 153")
            || text.contains("Error 153") {
            self = .misconfigured
            return
        }
        if text.contains("该嵌入配置错误") || text.contains("NoParent") {
            self = .refusedEmbedding
            return
        }
        return nil
    }

    /// 面板 / 回执上那一句。**一个数字都不许有**（用户看到「错误 153」只会更困惑）。
    var panelText: String {
        switch self {
        case .refusedEmbedding:
            "这段视频不允许在别处播放。"
        case .misconfigured:
            "播放器没能在这块屏幕上启动。再放一次，还不行就换一条链接。"
        case .notFound:
            "这段视频不存在，可能已经被删了。"
        case .badIdentifier:
            "这条链接里的视频编号不对，换一条再试。"
        case .unsupported:
            "这段视频用网页播放器放不出来。"
        case .unmapped:
            "这段视频没能在这块屏幕上播放。换一条链接再试。"
        }
    }

    /// 日志 / `details` 口径：**带码**，而且说清是从哪来的。
    var technicalDescription: String {
        switch self {
        case .refusedEmbedding:
            "官方播放器拒绝嵌入（YouTube 101/150；Twitch NoParent）：这段视频不允许在别处播放。"
        case .misconfigured:
            "官方播放器配置错误（YouTube 153 / 152-4）：播放器不接受承载页的来源。"
        case .notFound:
            "官方播放器报视频不存在（YouTube 100）。"
        case .badIdentifier:
            "官方播放器报参数无效（YouTube 2）：链接里的视频编号不对。"
        case .unsupported:
            "官方播放器报 HTML5 播放器不支持（YouTube 5）。"
        case let .unmapped(code):
            "官方播放器报错误码 \(code)，不在已知映射表里。"
        }
    }
}
