import Foundation

// MARK: - 地址脱敏：签名地址永远不许进日志/回执/面板

/// 「这个地址能写进哪里」的**唯一**一处判据。
///
/// 解析器交给我们的媒体地址带签名（YouTube 的 `expire` / `sig` / `n`，B 站的 `deadline`
/// 之类）。它**不是**凭据，但它是**临时授权**：把它写进日志、回执或界面，等于把一次
/// 可复用的取流授权泄漏出去。所以：
///
/// - `redacted(_:)` 只保留 `scheme://host[:port]/path`，**丢掉** query / fragment / userinfo；
/// - `containsCredential(_:)` 给判据用：一段文本里出现 `@`（userinfo）、`cookie` /
///   `authorization` / `token=` 这类字面量就直接判红。
///
/// 这条纪律对**两条后端**都成立：官方嵌入路径里我们没有媒体地址；原生路径里有，
/// 但它只能活在 `ScreenLinkStream.url` 这一个内存字段里。
enum ScreenLinkRedaction {
    /// 只保留**能公开**的那部分：scheme、host、port、path。
    ///
    /// 解析不出来时返回 `"(unreadable)"`（绝不原样回吐，宁可少说）。
    static func redacted(_ raw: String) -> String {
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host else {
            return "(unreadable)"
        }
        var text = "\(scheme)://\(host)"
        if let port = url.port { text += ":\(port)" }
        text += url.path.isEmpty ? "/" : url.path
        return text
    }

    /// 一段文本里**有没有**凭据/临时授权的痕迹。
    ///
    /// 判据是保守的（宁枉勿纵）：命中任何一条就说"有"。它用在**判据**里，不用在生产路径上
    /// 做过滤 —— 生产路径的正确做法是根本不要把它写进去。
    static func containsCredential(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("cookie") || lowered.contains("authorization")
            || lowered.contains("bearer ") || lowered.contains("access_token")
            || lowered.contains("refresh_token") || lowered.contains("password")
            || lowered.contains("set-cookie") || lowered.contains("api_key") {
            return true
        }
        // 查询串里的签名参数名：`sig` / `signature` / `token` / `expire` / `deadline`。
        for token in ["sig=", "signature=", "token=", "expire=", "deadline=", "md5=", "key="] {
            if lowered.contains(token) { return true }
        }
        // URL userinfo（`scheme://user:pass@host`）。
        if let url = URL(string: text), url.user != nil || url.password != nil { return true }
        return false
    }
}

// MARK: - 哪些**公开网站链接**走原生解析

/// 「这个链接是哪个站的**公开观看页**」的**唯一**判据。
///
/// 与官方嵌入白名单（`WorldScreenEmbedPolicy`）是**两件事**，刻意分开：
/// - 嵌入白名单回答"这是不是站方公开的嵌入页"（`/embed/`、`player.html`、`player.twitch.tv`）；
/// - 这里回答"这是不是可以交给解析器的公开观看页"（`/watch`、`/video/BV…`、`twitch.tv/<channel>`）。
///
/// 两条路都**不**接受任何指向视频字节的域名，也**不**读 cookie / 绕登录 / 绕地区：
/// 分类只看主机与路径形状，解析器只拿**公开页面地址**。
enum ScreenLinkSitePolicy {
    /// `@Sendable` 是必需的，不是装饰：`rules` 是全局常量，Swift 6 严格并发下它的元素类型
    /// 必须 Sendable。这里的判据都是**纯函数**（不捕获任何可变状态），所以可以安全地
    /// 标成 `@Sendable`；这样也不用把 `rules` 降级成 `nonisolated(unsafe)` 来绕过检查。
    struct Rule: Sendable {
        let site: ScreenLinkSite
        /// 允许的主机（小写，精确匹配）。
        let hosts: Set<String>
        /// 路径判据（返回 `true` = 这是公开观看页）。
        let isWatchPath: @Sendable (URL) -> Bool
    }

    static let rules: [Rule] = [
        Rule(
            site: .youtube,
            hosts: ["www.youtube.com", "youtube.com", "m.youtube.com", "music.youtube.com"],
            isWatchPath: { url in
                // /watch?v=… ；也接受 /shorts/<id> 与 /live/<id>（都是公开观看页）。
                if url.path == "/watch" {
                    let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "v" })?.value
                    return isYouTubeVideoID(id ?? "")
                }
                for prefix in ["/shorts/", "/live/", "/embed/"] where url.path.hasPrefix(prefix) {
                    return isYouTubeVideoID(String(url.path.dropFirst(prefix.count)))
                }
                return false
            }
        ),
        Rule(
            site: .youtube,
            hosts: ["youtu.be"],
            isWatchPath: { isYouTubeVideoID(String($0.path.dropFirst())) }
        ),
        Rule(
            site: .bilibili,
            hosts: ["www.bilibili.com", "bilibili.com", "m.bilibili.com"],
            isWatchPath: { url in
                if url.path.hasPrefix("/video/") {
                    return isBilibiliVideoID(String(url.path.dropFirst("/video/".count)))
                }
                // 番剧 / 直播回放：只认"有编号"的那些公开页，不猜。
                return url.path.hasPrefix("/bangumi/play/") || url.path.hasPrefix("/list/")
            }
        ),
        Rule(
            site: .bilibili,
            hosts: ["b23.tv"],
            // 短链：路径就是分享码。真正的跳转交给解析器（它自己会跟）。
            isWatchPath: { !$0.path.isEmpty && $0.path != "/" }
        ),
        Rule(
            site: .twitch,
            hosts: ["www.twitch.tv", "twitch.tv", "m.twitch.tv"],
            isWatchPath: { url in
                // 频道页 `/` 与 `/videos/<id>`、`/<channel>` 都接受；`/directory` 这类
                // 纯目录页不接受（它没有可播的东西）。
                let path = url.path
                if path.isEmpty || path == "/" { return false }
                if path.hasPrefix("/videos/") || path.hasPrefix("/clip/") { return true }
                return !["/directory", "/downloads", "/jobs", "/settings", "/subscriptions",
                         "/inventory", "/drops", "/wallet", "/turbo"].contains(path)
            }
        ),
    ]

    /// 这个链接是哪个站的公开观看页。`nil` = 不交给原生解析（可能是官方嵌入页，也可能是
    /// 不支持的站）。
    static func site(forPageURL raw: String) -> ScreenLinkSite? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return nil }
        return rules.first(where: { $0.hosts.contains(host) && $0.isWatchPath(url) })?.site
    }

    /// 这个链接**是不是**原生解析能处理的公开网站链接。
    static func accepts(_ raw: String) -> Bool { site(forPageURL: raw) != nil }

    private static func isYouTubeVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func isBilibiliVideoID(_ value: String) -> Bool {
        value.hasPrefix("BV") && value.count == 12 && value.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
