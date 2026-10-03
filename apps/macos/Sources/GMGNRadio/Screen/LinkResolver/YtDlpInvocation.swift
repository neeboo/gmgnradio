import Foundation

// MARK: - yt-dlp 的**参数**构造（纯值、跨平台、可离线断言）

/// 把一次 `ScreenLinkRequest` 变成一条**受控**的 yt-dlp 命令行。
///
/// ## 纪律（每一条都有判据钉着，见 `tools/test-screen-link-resolver.swift`）
///
/// 1. **只用模拟模式**：`--dump-single-json` 只打印信息，不下载文件、不落盘；
/// 2. **不读任何用户配置**：`--ignore-config` —— 否则 `~/.config/yt-dlp/config` 里
///    一条 `--cookies-from-browser` 就会把"不读浏览器账号 cookies"这条红线绕过去；
/// 3. **不读 cookies、不登录、不绕地区**：显式 `--no-cookies`，且参数表里**结构上
///    没有** `--cookies*` / `--username` / `--password` / `--netrc` / `--geo-bypass`
///    这些位置（`forbiddenArgumentTokens` 逐条断言）；
/// 4. **不联网更新、不写缓存**：`--no-update` + `--no-cache-dir`；
/// 5. **只处理用户给的那一个视频**：`--no-playlist`（别把整个播放列表拉下来）；
/// 6. **JS 运行时只认内置路径**：需要时用 `--js-runtimes <name>:<绝对路径>` 指向随 app
///    走的运行时；缺省**不**依赖 PATH 上的 node/deno。
struct YtDlpInvocation: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]

    /// **结构上禁止**出现在参数表里的开关。判据直接扫 `arguments`。
    ///
    /// 这不是"记得别加"，而是"加了就红"：`--cookies-from-browser` 一旦混进来，
    /// 用户浏览器里的登录态就会被解析器代持 —— 那是这条产品线的红线。
    static let forbiddenArgumentTokens: [String] = [
        "--cookies", "--cookies-from-browser", "--username", "--password",
        "--netrc", "--netrc-cmd", "--geo-bypass", "--geo-bypass-country",
        "--proxy", "--write-cookies", "-U", "--update", "--config-locations",
    ]

    /// 构造一次模拟解析的参数。
    ///
    /// - Parameters:
    ///   - request: 用户给的公开网站链接与上限。
    ///   - executablePath: **受控路径**（内置目录 / 开发覆盖），不是 PATH 查询结果。
    ///   - javascriptRuntimeName: 内置 JS 运行时的名字（如 `deno`），可选。
    ///   - javascriptRuntimePath: 该运行时的**绝对路径**，与名字同时给才生效。
    static func make(
        request: ScreenLinkRequest,
        executablePath: String,
        javascriptRuntimeName: String? = nil,
        javascriptRuntimePath: String? = nil
    ) -> YtDlpInvocation {
        var arguments: [String] = [
            "--ignore-config",
            "--no-warnings",
            "--no-color",
            "--no-progress",
            "--no-cache-dir",
            "--no-update",
            "--no-cookies",
            "--no-playlist",
            "--simulate",
            "--dump-single-json",
        ]
        if let runtimeName = javascriptRuntimeName, let runtimePath = javascriptRuntimePath {
            arguments += ["--js-runtimes", "\(runtimeName):\(runtimePath)"]
        }
        arguments += ["-f", formatSelector(for: request)]
        arguments += ["--", request.pageURL]
        return YtDlpInvocation(executablePath: executablePath, arguments: arguments)
    }

    /// 格式选择器。
    ///
    /// - 优先"最佳视频 + 最佳音频"（YouTube 高清几乎都是分轨；AVPlayer 侧用
    ///   `AVMutableComposition` 把两轨合成一个 item，见 `NativeLinkPlayer`）；
    /// - **优先 AVPlayer 真能解的编码**：第一段挑 H.264 视频 + AAC 音频。yt-dlp 的
    ///   "bestvideo" 常常是 AV1 / VP9，而 `AVPlayer` 对它们的支持依机器/系统而定 ——
    ///   真机实测（2026-10-03）在默认选择下 `decodedFrames=0`（出不了帧），换成
    ///   `[vcodec^=avc1]+[acodec^=mp4a]` 之后正常出帧。挑不到再退回"最佳"；
    /// - 加 `/b` 兜底：站点没有分轨时退回自带声音的合流格式；
    /// - 用户设了高度上限时**逐条**带上 `[height<=H]`。
    ///
    /// 如果站点**只有** AVPlayer 不支持的编码（例如纯 DASH/VP9/AV1），那属于
    /// "AVPlayer 不够"的情形：`ScreenLinkStream.isManifest` 会如实标出来，后续应改用
    /// FFmpeg/libmpv 解码（`NativeScreenMediaPlaying` 协议不变）。本轮不静默降级。
    static func formatSelector(for request: ScreenLinkRequest) -> String {
        let limit = request.preferredMaximumHeight.map { "[height<=\(max($0, 144))]" } ?? ""
        if request.allowsSeparateStreams {
            return "bv*\(limit)[vcodec^=avc1]+ba[acodec^=mp4a]/bv*\(limit)+ba/b\(limit)/b"
        }
        return "b\(limit)/b"
    }
}
