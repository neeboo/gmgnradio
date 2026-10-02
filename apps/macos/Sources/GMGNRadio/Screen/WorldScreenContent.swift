import Foundation

// MARK: - 屏幕内容：只走官方嵌入页

/// 一台电视**现在放什么**。落盘在 `metadata["gmgn.screen-content.v1"]`。
struct WorldScreenContent: Equatable, Sendable, Codable {
    /// 内容的种类。本切片**只有**官方嵌入一种。
    ///
    /// `direct`（用户给的直链）与 `local`（本地文件）是**设计上留的位置**、
    /// **本切片不做** —— 先把"官方嵌入 + 白名单 + 具名失败"这条钉死，
    /// 再谈别的。留一个不做事的枚举成员比事后补一个"其实还有一条路"要诚实。
    enum Kind: String, Codable, Equatable, Sendable {
        case officialEmbed = "official_embed"
    }

    let objectID: String
    let kind: Kind
    /// 最终要交给 `WKWebView` 的那个**官方嵌入页** URL。
    let url: String
    /// 给人看的一句（视频标题 / BV 号 / 视频 id）。可以为空。
    let title: String

    var isValid: Bool {
        if case .success = WorldScreenEmbedPolicy.validate(url) {
            return !objectID.isEmpty && objectID.count <= 256 && url.count <= 2048
        }
        return false
    }
}

/// 「这个 URL 为什么不能放」的**具名**原因。一条都不许静默。
enum WorldScreenContentIssue: Error, Equatable, Sendable {
    /// 用户还没说要放什么 —— 这是"信息不足"，走**成功**通道（`insufficient_input`）。
    case missingInput
    /// 连接不是 https。
    case insecureScheme(String)
    /// URL 本身就解析不出来。
    case malformedURL(String)
    /// 域名不在**官方嵌入**白名单里。
    case unsupportedHost(String)
    /// 域名对，但不是那个站的**嵌入路径**（比如把 `www.youtube.com/watch` 直接塞进来）。
    case notEmbedPath(host: String, path: String)
    /// 路径对，但里面**没有视频 id**（`https://www.youtube.com/embed/`）。
    case missingVideoID(host: String)

    /// 给用户/agent 的**一句**人话。面板那一行与工具回执是**同一份**文案。
    var errorDescription: String {
        switch self {
        case .missingInput:
            "还没说放什么。给我一个官方嵌入页链接（YouTube / 哔哩哔哩），或先在面板里选一部。"
        case let .insecureScheme(scheme):
            "只支持官方嵌入页：链接的协议是「\(scheme.isEmpty ? "空" : scheme)」，必须是 https。"
        case let .malformedURL(raw):
            "这个链接读不出来：「\(raw.prefix(80))」。"
        case let .unsupportedHost(host):
            "只支持官方嵌入页。「\(host.isEmpty ? "没有域名" : host)」不在允许的嵌入域名里。"
        case let .notEmbedPath(host, path):
            "「\(host)」是允许的嵌入域名，但「\(path)」不是嵌入路径。请用官方嵌入链接（YouTube 的 /embed/、哔哩哔哩的 player.bilibili.com）。"
        case let .missingVideoID(host):
            "「\(host)」的链接里没有可播放的视频。请给完整的嵌入链接，或者直接给视频 id（哔哩哔哩就是 BV 号）。"
        }
    }
}

/// 官方嵌入的**白名单**（唯一处）。
///
/// 是白名单不是黑名单：不在表里的一律拒绝。理由是可审计 —— "不允许"是一个**有限**的
/// 集合，而"不允许抓流"是一个**无限**的集合，用黑名单表达它必然漏。
///
/// 这个类型**只做一件事**：判断"这个 URL 是不是那个站官方提供的嵌入页"。
/// 它不解析响应、不拼接 CDN 地址、不读 cookie、不改 UA —— 站方给什么就放什么。
enum WorldScreenEmbedPolicy {
    struct Rule {
        let host: String
        /// 允许的路径前缀。
        let pathPrefixes: [String]
        let displayName: String
        /// 「这条路径上真的有可播的东西吗」——只查**标识符在不在**，不解析任何响应。
        let hasIdentifier: @Sendable (URL) -> Bool
    }

    /// 允许的官方嵌入域名与路径。三条，全部是站方公开的嵌入入口。
    static let rules: [Rule] = youtubeRules + [
        Rule(
            host: "player.bilibili.com", pathPrefixes: ["/player.html"],
            displayName: "哔哩哔哩官方播放器",
            hasIdentifier: { url in
                guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems else { return false }
                if let bvid = items.first(where: { $0.name == "bvid" })?.value {
                    return isBilibiliVideoID(bvid)
                }
                return items.contains { $0.name == "aid" && !($0.value ?? "").isEmpty }
            }
        ),
        Rule(
            host: "player.twitch.tv", pathPrefixes: ["/"],
            displayName: "Twitch 官方嵌入",
            hasIdentifier: { url in
                guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems else { return false }
                return items.contains {
                    ($0.name == "channel" || $0.name == "video") && !($0.value ?? "").isEmpty
                }
            }
        ),
    ]

    private static let youtubeRules: [Rule] = [
        "www.youtube.com", "youtube.com", "www.youtube-nocookie.com", "youtube-nocookie.com",
    ].map { host in
        Rule(
            host: host, pathPrefixes: ["/embed"],
            displayName: host.contains("nocookie")
                ? "YouTube 官方嵌入（无 cookie 域）" : "YouTube 官方嵌入",
            hasIdentifier: { url in
                let path = url.path
                guard path.hasPrefix("/embed/") else { return false }
                return isYouTubeVideoID(String(path.dropFirst("/embed/".count)))
            }
        )
    }

    /// 公开观看链接 → 官方嵌入链接的**换写**。换写出来的仍然是官方嵌入页。
    ///
    /// - `https://www.youtube.com/watch?v=<id>` → `https://www.youtube.com/embed/<id>`
    /// - `https://youtu.be/<id>`               → `https://www.youtube.com/embed/<id>`
    /// - `https://www.bilibili.com/video/<BV…>` → `https://player.bilibili.com/player.html?bvid=<BV…>`
    ///
    /// **只搬运 id**：换写函数里没有任何"取流地址 / 解密 / 代理"的位置，
    /// 也**不接受**任何指向视频字节的域名。
    static func rewriteWatchURL(_ raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased()
        else { return nil }
        let path = url.path
        switch host {
        case "www.youtube.com", "youtube.com", "m.youtube.com":
            guard path == "/watch",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "v" })?.value,
                  isYouTubeVideoID(id)
            else { return nil }
            return "https://www.youtube.com/embed/\(id)"
        case "youtu.be":
            let id = String(path.dropFirst())
            guard isYouTubeVideoID(id) else { return nil }
            return "https://www.youtube.com/embed/\(id)"
        case "www.bilibili.com", "bilibili.com", "m.bilibili.com":
            guard path.hasPrefix("/video/") else { return nil }
            let id = String(path.dropFirst("/video/".count))
            guard isBilibiliVideoID(id) else { return nil }
            return "https://player.bilibili.com/player.html?bvid=\(id)&autoplay=0"
        default:
            return nil
        }
    }

    /// 裸 id → 官方嵌入链接。`bvid` 前缀的当哔哩哔哩，11 位 YouTube id 当 YouTube。
    static func embedURL(forBareID raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBilibiliVideoID(id) {
            return "https://player.bilibili.com/player.html?bvid=\(id)&autoplay=0"
        }
        if isYouTubeVideoID(id) {
            return "https://www.youtube.com/embed/\(id)"
        }
        return nil
    }

    static func isYouTubeVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func isBilibiliVideoID(_ value: String) -> Bool {
        value.hasPrefix("BV") && value.count == 12
            && value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// 用户输入 → 官方嵌入 URL。接受三样东西：已经写好的官方嵌入链接、公开观看链接、裸 id。
    ///
    /// 拒绝第一段就在这里：**不是官方嵌入页的，一个都不放行**。
    static func validate(_ raw: String) -> Result<URL, WorldScreenContentIssue> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingInput) }
        let candidate = rewriteWatchURL(trimmed) ?? embedURL(forBareID: trimmed) ?? trimmed
        guard let url = URL(string: candidate) else {
            return .failure(.malformedURL(trimmed))
        }
        // 协议先判：`file:` 这类没有 host 的 URL 必须报"协议不对"，不是"读不出来"。
        guard url.scheme?.lowercased() == "https" else {
            return .failure(.insecureScheme(url.scheme ?? ""))
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .failure(.malformedURL(trimmed))
        }
        guard let rule = rules.first(where: { $0.host == host }) else {
            return .failure(.unsupportedHost(host))
        }
        let path = url.path.isEmpty ? "/" : url.path
        guard rule.pathPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return .failure(.notEmbedPath(host: host, path: path))
        }
        guard rule.hasIdentifier(url) else {
            return .failure(.missingVideoID(host: host))
        }
        return .success(url)
    }

    /// 这条 URL 的展示名（面板/回执上告诉用户"这是哪个站的官方嵌入"）。
    static func displayName(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "官方嵌入" }
        return rules.first { $0.host == host }?.displayName ?? "官方嵌入"
    }
}
