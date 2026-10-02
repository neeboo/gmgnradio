import Foundation

// MARK: - 官方嵌入页的**来源**：它必须被一个有合法 http(s) origin 的文档嵌住

/// 一块屏幕**怎么被载入**这件事，只有这一处。
///
/// ## 真机 2026-10-02 的取证
///
/// 电视上 YouTube 嵌入页显示「视频播放器配置错误 / 错误 153」。离屏 WKWebView
/// （macOS 26.5.2 / Swift 6.3.3）逐项实测下来，**"origin 不合法"这个说法是不准的**：
///
/// * **顶层直载** `https://www.youtube.com/embed/<id>`（= 本文件出现之前
///   `WorldScreenSurface.load(url:)` 的行为）：`document.location.origin` 实测就是
///   `https://www.youtube.com` —— 一个**完全合法**的 https origin —— 播放器**照样**报
///   153。所以 153 与"页面自己没有 https"无关；
/// * 缺的是**嵌它的那个文档**：顶层直载时 `document.referrer` 是空串、没有 parent frame，
///   播放器因此判定"没有合法的嵌入来源"，画出那块错误界面。同一件事 Twitch 说得更直白
///   —— 直载 `player.twitch.tv` 会跳到 `embed-error.html?errorCode=NoParent`
///   （「哎哟！该嵌入配置错误」）。**`NoParent` 与 153 是同一个缺陷的两个名字**；
/// * 把**同一个**官方嵌入 URL 放进一个 `<iframe>`，而这个 `<iframe>` 所在的文档有一个
///   合法的 http(s) origin（实测 `http://127.0.0.1:<port>`），这段视频就开始播。
///
/// ## 为什么不用回环 HTTP 服务
///
/// 起一个只监听 `127.0.0.1` 的极小 HTTP 服务也能补上这个来源（实测同样能播），但
/// `WKWebView.loadHTMLString(_:baseURL:)` 可以**直接把那份来源发给文档**：实测两者渲染
/// 出的画面**逐字节相同**（同为那张 poster 截图）。于是选它，因为它严格更安全也更简单：
///
/// * **一个监听套接字都不开**：没有端口要挑、没有 `accept` 循环、没有并发、没有请求日志
///   —— "只绑回环 / 随机端口 / 用完即关 / 不泄露凭据"这四条在这里是**空集上成立**，
///   比"开一个再关掉"强一层；
/// * origin 的端口是**随机**挑的，且**故意没有任何监听者**：这样它绝不会与真机上真的
///   在 80 / 8000 / 8080 上跑的本地服务**共用同一个 origin**（共用 origin = 共用
///   localStorage 与同一套同源判据）；
/// * 文档内容是本地常量，唯一的子资源是站方的**绝对 https** 官方嵌入地址 ——
///   我们不转发、不代持、不读任何凭据，也不碰 UA / cookie。
///
/// 被否掉的另一条路：`loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))`
/// （把承载页伪装成 youtube.com）。实测在**本机这个 WebKit 版本上直接不可用** ——
/// 画面是「此视频不能观看 / 错误代码：152 - 4」；而且它会把我们这份 HTML 放进
/// **youtube.com 自己的 origin**（可读写该站的 localStorage / 同源判据），是真正的来源伪造。
enum WorldScreenEmbedOrigin {
    /// 承载文档 origin 的主机部分。**只允许回环**：这是"不对外"这条红线的唯一取值处。
    static let loopbackHost = "127.0.0.1"

    /// 随机的**本机高位端口**取值范围。
    ///
    /// 取高位是因为它们既不在特权区间，也不在 macOS 常用的本地服务端口（80 / 3000 /
    /// 8000 / 8080 / 8888 …）附近；而**这个端口上没有任何监听者** —— 我们既不接受、
    /// 也不发起任何连接，`<iframe>` 指向的是站方的绝对 https 地址。
    static let portRange: ClosedRange<UInt16> = 49152...65535

    static func randomPort() -> UInt16 {
        UInt16.random(in: portRange)
    }

    /// 承载文档的 origin 字面量。`<iframe>` 的 `origin=` 参数必须**逐字**等于它。
    static func originString(port: UInt16) -> String {
        "http://\(loopbackHost):\(port)"
    }

    /// 交给 `loadHTMLString(_:baseURL:)` 的那份 baseURL。
    static func baseURL(port: UInt16) -> URL? {
        URL(string: originString(port: port) + "/")
    }

    /// 这个来源会不会被 WebKit 当作**不是不透明来源**的合法 http(s) 来源。
    ///
    /// `file://`、`about:blank`、`data:`、自定义 scheme 都不是 —— 判据是"scheme 是
    /// http/https 且有主机名"，与实测里失败（`file://`、无 origin）和成功
    /// （`http://127.0.0.1:<port>`）两边的读数一致。
    static func isLegalEmbeddingOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// 判据用：这个来源是不是**只在回环**上（不是 `0.0.0.0`、不是某个具体网卡、
    /// 也不是外网域名）。
    static func isLoopbackOnly(origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return host == loopbackHost
    }
}

// MARK: - 承载页（唯一一份 HTML）

/// 官方嵌入页的**承载文档**。它自己没有任何内容，只有那个 `<iframe>` 与一段转发。
///
/// 为什么需要那段转发：播放器住在**跨域** iframe 里，主文档读不到它的文字，所以
/// "播放器在里面报了什么"必须由播放器**主动说出来**。官方 IFrame API 的
/// `enablejsapi=1` 正是为此而设：加上它、并把 `origin=` 设成承载页自己的 origin 之后，
/// 播放器会把 `onReady` / `onError` / `onStateChange` postMessage 给 parent ——
/// 也就是**我们自己这一页**。这一页再把最近一条转写进 `document.title`，native 侧只读
/// 那一行。**不去读 iframe 内部**（读不到，也不该读）。
enum WorldScreenEmbedPage {
    /// native 侧认的那一行前缀。用 `document.title` 当信道是因为它是**同一个文档**里
    /// 我们能读、而跨域播放器改不动的一格。
    static let titlePrefix = "gmgn-screen:"

    static let playerElementID = "gmgn-screen-player"

    /// native 侧轮询用的取数脚本：只读这一页**自己**的 title 与文字。
    static let probeScript = """
    (function () {
      var title = String(document.title || '');
      var body = (document.body && document.body.innerText) ? document.body.innerText : '';
      return JSON.stringify({
        title: title.slice(0, 400),
        text: body.replace(/\\s+/g, ' ').slice(0, 600)
      });
    })();
    """

    /// 官方嵌入 URL → 播放器 src。**只追加官方 API 的两个参数**，主机 / 路径 / 视频 id
    /// 一个字节都不动（白名单判的是那三样，这里不许重写它们）。
    static func playerURL(embedURL: String, origin: String) -> String {
        let separator = embedURL.contains("?") ? "&" : "?"
        let encodedOrigin = origin.addingPercentEncoding(
            withAllowedCharacters: originQueryAllowed
        ) ?? ""
        return embedURL + separator + "enablejsapi=1&origin=" + encodedOrigin
    }

    /// `origin` 参数允许原样保留的字符：字母、数字、`.`。
    ///
    /// 官方文档要求把 `origin` 做 URL 编码，而这里**只编码真正需要编码的 `:` 与 `/`**
    /// —— 于是真机实测那一份 `origin=http%3A%2F%2F127.0.0.1%3A<port>` 与生产逐字一致。
    /// 把 `.` 也编成 `%2E` 是合法的 URL 编码，但**不是**实测过的那一份，不取。
    static let originQueryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: ".")
        return set
    }()

    static func html(embedURL: String, origin: String) -> String {
        let source = escapeAttribute(playerURL(embedURL: embedURL, origin: origin))
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <title>\(titlePrefix){"event":"idle"}</title>
        <style>html,body{margin:0;height:100%;background:#1b1e24;overflow:hidden}
        iframe{border:0;width:100%;height:100%;display:block}</style></head><body>
        <iframe id="\(playerElementID)" src="\(source)"
         allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        <script>
        (function () {
          function report(payload) {
            try { document.title = '\(titlePrefix)' + JSON.stringify(payload); } catch (_) {}
          }
          window.addEventListener('message', function (event) {
            try {
              var data = event.data;
              if (typeof data === 'string') { data = JSON.parse(data); }
              if (!data || !data.event) { return; }
              if (data.event === 'onError') { report({ event: 'onError', code: Number(data.info) }); }
              else if (data.event === 'onReady') { report({ event: 'onReady' }); }
              else if (data.event === 'onStateChange') {
                report({ event: 'onStateChange', state: Number(data.info) });
              }
            } catch (_) {}
          });
          report({ event: 'embedding' });
        })();
        </script></body></html>
        """
    }

    /// 属性值转义。只有这一处 —— 于是"URL 里的 `&` 会不会把属性截断"不必各写一份。
    static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - native 侧读到的诊断

/// 轮询 `probeScript` 拿到的那一份读数 → 具名失败（或"没事"）。
struct WorldScreenPlayerDiagnosis: Equatable, Sendable {
    /// 播放器报的事件名（`onError` / `onReady` / `onStateChange` / `embedding`），
    /// 或 `pageText`（回归网从页面文字里认出来的）。
    let event: String
    /// 播放器给的错误码（`onError` 才有）。
    let code: Int?
    /// 回归网从页面文字里认出来的那一类。
    var scanned: WorldScreenPlayerFailure?

    var failure: WorldScreenPlayerFailure? {
        if let scanned { return scanned }
        guard event == "onError" else { return nil }
        return WorldScreenPlayerFailure(youtubeCode: code ?? -1)
    }

    /// 解析 native 侧那一次 `evaluateJavaScript` 的返回值。
    ///
    /// 两条信道，优先级明确：先认**播放器自己说的**（`document.title` 里那一行），
    /// 认不到再看**页面文字**（顶层直载的回归网）。
    static func parse(probeJSON: String) -> WorldScreenPlayerDiagnosis? {
        guard let data = probeJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let title = (object["title"] as? String) ?? ""
        let text = (object["text"] as? String) ?? ""
        if title.hasPrefix(WorldScreenEmbedPage.titlePrefix),
           let relayData = String(title.dropFirst(WorldScreenEmbedPage.titlePrefix.count))
               .data(using: .utf8),
           let relay = (try? JSONSerialization.jsonObject(with: relayData)) as? [String: Any],
           let event = relay["event"] as? String {
            let code = (relay["code"] as? NSNumber)?.intValue
            return WorldScreenPlayerDiagnosis(event: event, code: code, scanned: nil)
        }
        if let scanned = WorldScreenPlayerFailure(pageText: text) {
            return WorldScreenPlayerDiagnosis(event: "pageText", code: nil, scanned: scanned)
        }
        return nil
    }
}
