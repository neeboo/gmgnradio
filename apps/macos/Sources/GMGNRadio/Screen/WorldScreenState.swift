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
        }
    }
}
