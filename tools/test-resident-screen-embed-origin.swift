// 电视机「官方嵌入页的**来源**」判据 —— 真机 2026-10-02「视频播放器配置错误 / 错误 153」。
//
// 与 `tools/test-resident-screen-overlay.swift` 分开成一份，理由是**判据的输入不同**：
// 那一份钉的是几何 / 遮挡 / 指针 / 白名单，这一份钉的是"嵌入页被谁嵌住"。
//
// ## 先有取证，才有判据
//
// 离屏 WKWebView（macOS 26.5.2 / Swift 6.3.3）实测，同一个官方嵌入 URL
// `https://www.youtube.com/embed/aPcL35kgL6A`：
//
// | 载入方式 | 文档 origin | 画面 |
// |---|---|---|
// | 顶层直载（改动前的 `load(url:)`） | `https://www.youtube.com` | 「视频播放器配置错误 / 错误 153」 |
// | 回环 HTTP 服务里放 `<iframe>` | `http://127.0.0.1:<random>` | **视频正常出画** |
// | `loadHTMLString(_, baseURL: http://127.0.0.1:<random>/)` | `http://127.0.0.1:<random>` | **与上一行逐字节相同的截图** |
// | `loadFileURL(tmp/index.html)` | `file://`（不透明） | 与直载同一条错误 |
// | `loadHTMLString(_, baseURL: https://www.youtube.com)` | `https://www.youtube.com`（伪） | 「此视频不能观看 / 错误代码：152 - 4」 |
// | Twitch `player.twitch.tv` 顶层直载 | `https://player.twitch.tv` | 跳到 `embed-error.html?errorCode=NoParent` |
//
// 于是结论是两条，且都进了判据：
//
// 1. **顶层直载是缺陷本身**（不是"页面没有 https"）：它缺的是**嵌它的那个文档** ——
//    `document.referrer` 空、没有 parent frame，播放器判定"没有合法的嵌入来源"。
//    Twitch 把同一件事命名为 `NoParent`；
// 2. 补这个来源最省的做法是 `loadHTMLString(_:baseURL:)`：**一个监听套接字都不开**
//    （见 `WorldScreenEmbedOrigin` 的注释）。所以下面「只监听回环 / 随机端口 / 用完即关」
//    这组判据在这里是**空集上成立**，而且判据会拦住任何"引入一个监听者"的改动。
//
// 手法沿袭仓里既有的离线 harness：生产源码**原文**切片现编现跑；注入只在临时副本上做手术。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen")

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS \(message)")
    } else {
        print("FAIL \(message)")
        failureCount += 1
    }
}

func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

// ---------------------------------------------------------------------------
// MARK: 外层文本判据：**加载点**
// ---------------------------------------------------------------------------

/// 「官方嵌入页是怎么被载进来的」的**唯一**判据。
///
/// 四样缺一不可，任何一样丢了都会回到 153：
/// 1. 不许再出现顶层直载（`webView.load(URLRequest(url:))`）；
/// 2. 必须走承载页 + `baseURL:`；
/// 3. 承载来源必须先过 `isLegalEmbeddingOrigin`（构造不出合法来源时要**具名失败**，
///    不许当成没事）；
/// 4. 来源只由 `WorldScreenEmbedOrigin` 一处给（不许出现第二份来源定义）。
func embedLoadSiteProblems(_ source: String) -> [String] {
    var problems: [String] = []
    if source.contains("webView.load(URLRequest(url: url))") {
        problems.append(
            "加载点变回了**顶层直载**嵌入页：没有嵌它的那个文档，"
                + "官方播放器会报 153（Twitch 报 NoParent）"
        )
    }
    if !source.contains("WorldScreenEmbedPage.html(embedURL: url.absoluteString, origin: origin)") {
        problems.append("加载点没有把官方嵌入 URL 放进承载页（`WorldScreenEmbedPage.html`）")
    }
    if !source.contains("webView.loadHTMLString(") || !source.contains("baseURL: baseURL") {
        problems.append("承载页没有拿到一个 baseURL：文档来源是发不出去的")
    }
    if !source.contains("WorldScreenEmbedOrigin.isLegalEmbeddingOrigin(origin)") {
        problems.append("承载来源没有过 `isLegalEmbeddingOrigin` 这一关（构造不出来时会当成没事）")
    }
    if !source.contains("WorldScreenEmbedOrigin.baseURL(port: port)") {
        problems.append("来源不是由 `WorldScreenEmbedOrigin` 一处给的（会出现第二份来源定义）")
    }
    return problems
}

// ---------------------------------------------------------------------------
// MARK: 外层文本判据：**不许有任何监听套接字**
// ---------------------------------------------------------------------------

/// 监听类 API 的能力痕迹。
///
/// 这一条比"绑回环 + 随机端口 + 用完即关"**更强**：那三条是"开一个服务再开对"，
/// 这一条是"根本不开"。一旦有人为了别的原因（比如想转发请求）在这里引入监听者，
/// 下面这几条会立刻红 —— 那时候"绑哪儿 / 端口怎么挑 / 谁负责关"就必须逐条补齐。
let listeningCapabilityTokens = [
    "NWListener", "NWConnection", "nw_listener", "CFSocket", "socket(",
    "listen(", "bind(", "accept(", "HttpServer", "HTTPServer", "GCDWebServer",
]

func listeningSocketProblems(_ sources: [String: String]) -> [(String, String)] {
    var hits: [(String, String)] = []
    for (name, text) in sources.sorted(by: { $0.key < $1.key }) {
        for token in listeningCapabilityTokens where text.contains(token) {
            hits.append(("\(name):\(token)", token))
        }
    }
    return hits
}

// ---------------------------------------------------------------------------
// MARK: 外层文本判据：**不泄露凭据**
// ---------------------------------------------------------------------------

/// 承载页里**一个凭据字面量都不许有**：那一页是站方播放器的宿主，不是我们的请求。
/// 我们不发请求、不代持 cookie、不读 localStorage —— 于是"日志里泄露 token"这件事
/// 在源头上不存在（来源里只有回环主机 + 随机端口，连 userinfo 都没有）。
let credentialTokens = [
    "document.cookie", "localStorage", "sessionStorage", "Authorization", "Bearer ",
    "password", "api_key", "access_token", "refresh_token", "Set-Cookie",
]

func credentialLeakProblems(html: String, origin: String) -> [String] {
    var problems: [String] = []
    for token in credentialTokens where html.contains(token) {
        problems.append("承载页里出现了凭据字面量「\(token)」")
    }
    if origin.contains("@") {
        problems.append("来源里带了 userinfo（`@`）：那是凭据会待的地方")
    }
    return problems
}

/// 用户看得到的那一句话，**必须**来自 `panelText`（不是带码的工程口径）。
func userFacingCopyProblems(panelCopySource: String, storeSource: String) -> [String] {
    var problems: [String] = []
    if !panelCopySource.contains("case let .failed(failure): return failure.panelText") {
        problems.append("面板那一行不是 `failure.panelText`：用户会看到带错误码的工程口径")
    }
    if !storeSource.contains("failure.panelText") {
        problems.append("`play_screen` 的答复不是 `failure.panelText`：居民会把错误码念给用户")
    }
    if !storeSource.contains("\"cause\": failure.errorDescription") {
        problems.append("技术口径（含错误码）没有进 `details`/日志")
    }
    return problems
}

// ---------------------------------------------------------------------------
// MARK: 内层程序：把生产源码原文切进去现编现跑
// ---------------------------------------------------------------------------

let innerProgram = ##"""
import Foundation

var failuresTotal = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failuresTotal += 1 }
}

/// **真机实测原文**：离屏 WKWebView 顶层直载
/// `https://www.youtube.com/embed/aPcL35kgL6A` 之后 `document.body.innerText` 的原样。
/// 这一段是判据的材料，不是编出来的例子。
let capturedDirectLoadText = "视频播放器配置错误 视频播放器配置错误 错误 153 在 YouTube 上观看此视频 了解详情 错误 153"

/// Twitch 顶层直载后**地址栏**的原样（它把原因写在错误码里）。
let capturedTwitchDirectURL = "https://player.twitch.tv/embed-error.html?errorCode=NoParent"

@main struct Test {
    static func main() {
        // =========================================================
        // 断言 1：承载页拥有一个**合法 http(s) origin**
        // =========================================================
        let port = WorldScreenEmbedOrigin.randomPort()
        let origin = WorldScreenEmbedOrigin.originString(port: port)
        expect(WorldScreenEmbedOrigin.isLegalEmbeddingOrigin(origin),
            "断言1：承载页的 origin 是合法 http(s) 来源（实测 \(origin)）")
        expect(WorldScreenEmbedOrigin.isLoopbackOnly(origin: origin),
            "断言1：承载页的来源只在回环上（\(origin)）")
        let base = WorldScreenEmbedOrigin.baseURL(port: port)
        expect(base.map { WorldScreenEmbedOrigin.isLegalEmbeddingOrigin($0.absoluteString) } == true,
            "断言1：baseURL 本身也是合法来源（实测 \(base?.absoluteString ?? "nil")）")
        // 反例：这些都不是"合法 http(s) origin"。
        for bad in ["file:///tmp/screen/index.html", "about:blank", "data:text/html,<p>x",
                    "null", "", "blob:https://example.com/x"] {
            expect(!WorldScreenEmbedOrigin.isLegalEmbeddingOrigin(bad),
                "断言1：来源「\(bad.isEmpty ? "(空)" : bad)」不算合法来源 —— 回到它就是回到 153")
        }

        // =========================================================
        // 断言 2：回环 / 随机端口 / **没有任何监听套接字** / 无凭据
        // =========================================================
        expect(WorldScreenEmbedOrigin.loopbackHost == "127.0.0.1",
            "断言2：来源主机是 127.0.0.1（实测 \(WorldScreenEmbedOrigin.loopbackHost)）")
        var seen = Set<UInt16>()
        for _ in 0..<256 { seen.insert(WorldScreenEmbedOrigin.randomPort()) }
        expect(seen.count > 1,
            "断言2：端口是随机的（256 次里出现 \(seen.count) 个不同值）")
        expect(seen.allSatisfy { WorldScreenEmbedOrigin.portRange.contains($0) },
            "断言2：端口都落在高位区间 "
                + "\(WorldScreenEmbedOrigin.portRange.lowerBound)–\(WorldScreenEmbedOrigin.portRange.upperBound)")
        for wellKnown: UInt16 in [80, 443, 3000, 8000, 8080, 8888] {
            expect(!seen.contains(wellKnown),
                "断言2：不会挑到常用本地服务端口 \(wellKnown)（挑到就会与真机上的服务共用 origin）")
        }

        // =========================================================
        // 断言 3：承载页把**官方嵌入 URL** 原样嵌住（白名单零放宽、不改写主机）
        // =========================================================
        let embed = "https://www.youtube.com/embed/aPcL35kgL6A"
        let html = WorldScreenEmbedPage.html(embedURL: embed, origin: origin)
        expect(html.components(separatedBy: "<iframe").count - 1 == 1,
            "断言3：承载页里恰好一个 iframe")
        expect(html.contains("src=\"\(WorldScreenEmbedPage.escapeAttribute(embed))"),
            "断言3：iframe 的 src 以那份官方嵌入 URL 本身开头（主机 / 路径 / 视频 id 一个字节没改）")
        // 独立推导：只编码 `:` 与 `/`（**不调生产那个常量** —— 那样就成了自证）。
        let encodedOrigin = origin
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
        expect(html.contains("enablejsapi=1&amp;origin=\(encodedOrigin)"),
            "断言3：只追加了官方 IFrame API 的 enablejsapi / origin（实测 origin 参数 = \(encodedOrigin)）")
        expect(WorldScreenEmbedOrigin.isLegalEmbeddingOrigin(embed),
            "断言3：被嵌的那份 URL 自己仍是合法 https（官方嵌入页）")

        // 白名单：这条路上**没有**任何新放行。
        for bad in ["https://r1---sn-x.googlevideo.com/videoplayback",
                    "http://www.youtube.com/embed/aPcL35kgL6A",
                    "file:///tmp/x.html"] {
            if case .success = WorldScreenEmbedPolicy.validate(bad) {
                expect(false, "断言3：白名单被放宽了 —— \(bad) 被放行")
            } else {
                expect(true, "断言3：\(bad) 仍被拒（零放宽）")
            }
        }
        // 公开观看链接**不是**放宽：它必须被换写成官方嵌入页（主机 + `/embed/` 路径）。
        if case let .success(rewritten) = WorldScreenEmbedPolicy.validate(
            "https://www.youtube.com/watch?v=aPcL35kgL6A"
        ) {
            expect(rewritten.host?.lowercased() == "www.youtube.com"
                    && rewritten.path.hasPrefix("/embed/"),
                "断言3：公开观看链接被换写成官方嵌入页（\(rewritten.absoluteString)）—— 不是放宽")
        } else {
            expect(false, "断言3：公开观看链接没能换写成官方嵌入页")
        }
        if case .success = WorldScreenEmbedPolicy.validate(embed) {
            expect(true, "断言3：官方嵌入页本身仍然放行（\(embed)）")
        } else {
            expect(false, "断言3：官方嵌入页被误拒了（\(embed)）")
        }

        // iframe 的 host 必须还是官方嵌入的那个 host（没有代理 / 没有换域）。
        if let iframeRange = html.range(of: "src=\""),
           let endRange = html[iframeRange.upperBound...].range(of: "\"") {
            let src = String(html[iframeRange.upperBound..<endRange.lowerBound])
            let unescaped = src
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
            let srcHost = URL(string: unescaped)?.host?.lowercased()
            expect(srcHost == "www.youtube.com",
                "断言3：iframe 指向的仍然是官方嵌入域（实测 \(srcHost ?? "nil")）")
        } else {
            expect(false, "断言3：承载页里读不出 iframe 的 src")
        }

        // =========================================================
        // 断言 4：页面侧的失败**具名**，且"没事"与"出事"分得开
        // =========================================================
        let relay = "{\"title\":\"\(WorldScreenEmbedPage.titlePrefix)"
            + "{\\\"event\\\":\\\"onError\\\",\\\"code\\\":150}\",\"text\":\"\"}"
        let reported = WorldScreenPlayerDiagnosis.parse(probeJSON: relay)
        expect(reported?.failure == .refusedEmbedding,
            "断言4：播放器报 150（这段视频不让嵌）⇒ 具名 refusedEmbedding"
                + "（实测 \(String(describing: reported?.failure))）")
        let idle = "{\"title\":\"\(WorldScreenEmbedPage.titlePrefix)"
            + "{\\\"event\\\":\\\"embedding\\\"}\",\"text\":\"\"}"
        expect(WorldScreenPlayerDiagnosis.parse(probeJSON: idle)?.failure == nil,
            "断言4：承载页刚起来（还没报错）⇒ 不是失败，不许误报")
        let ready = "{\"title\":\"\(WorldScreenEmbedPage.titlePrefix)"
            + "{\\\"event\\\":\\\"onReady\\\"}\",\"text\":\"\"}"
        expect(WorldScreenPlayerDiagnosis.parse(probeJSON: ready)?.failure == nil,
            "断言4：播放器 onReady ⇒ 不是失败")
        // 回归网：顶层直载那一路的**实测原文**
        expect(WorldScreenPlayerFailure(pageText: capturedDirectLoadText) == .misconfigured,
            "断言4：顶层直载的实测原文 ⇒ 具名 misconfigured（回归网真的认得出 153 那一页）")
        expect(WorldScreenPlayerFailure(pageText: "哎哟！该嵌入配置错误。") == .refusedEmbedding,
            "断言4：Twitch「该嵌入配置错误」⇒ 具名 refusedEmbedding")
        expect(WorldScreenPlayerFailure(pageText: capturedTwitchDirectURL) == .refusedEmbedding,
            "断言4：Twitch 直载后的 errorCode=NoParent ⇒ 具名 refusedEmbedding")
        expect(WorldScreenPlayerFailure(pageText: "一段正常的页面文字") == nil,
            "断言4：正常页面文字不会被误判成失败")

        // 码 → 具名：官方文档里的那五个码 + 实测的 153 一个都不许漏
        let expected: [(Int, WorldScreenPlayerFailure)] = [
            (2, .badIdentifier), (5, .unsupported), (100, .notFound),
            (101, .refusedEmbedding), (150, .refusedEmbedding),
            (153, .misconfigured), (152, .misconfigured),
        ]
        for (code, want) in expected {
            expect(WorldScreenPlayerFailure(youtubeCode: code) == want,
                "断言4：错误码 \(code) ⇒ \(want)")
        }
        expect(WorldScreenPlayerFailure(youtubeCode: 4242) == .unmapped(4242),
            "断言4：没映射过的码也具名（unmapped(4242)），不许静默")

        // =========================================================
        // 断言 5：失败文案是**人话**，且技术细节留在另一句话里
        // =========================================================
        let codes = [2, 5, 100, 101, 150, 153, 152, 4242]
        let all = codes.map { WorldScreenPlayerFailure(youtubeCode: $0) }
        expect(all.allSatisfy { !$0.panelText.isEmpty },
            "断言5：每一种播放器失败都有一句人话")
        // 判据是**ASCII 数字**：`Character.isNumber` 对「一」「二」也为真（CJK 表意数字），
        // 拿它当判据会把「换一条链接」这种正常中文误判成"泄露了错误码"。
        func hasErrorCodeDigit(_ text: String) -> Bool {
            text.contains { $0.isASCII && $0.isNumber }
        }
        for failure in all where hasErrorCodeDigit(failure.panelText) {
            expect(false, "断言5：人话里带了数字「\(failure.panelText)」—— 用户会看到错误码原文")
        }
        // **一个数字都不许有** —— 「错误 153」这种原文就是这样被挡在门外的。
        expect(all.allSatisfy { !hasErrorCodeDigit($0.panelText) },
            "断言5：八个数的人话里一个 ASCII 数字都没有（不出现「错误 153」这种原文）")
        // 互不相同：判据是**种类**，不是码 —— 101 与 150 本来就是同一件事
        // （作者关掉了嵌入），152 与 153 也是同一件事（播放器不接受这个来源）。
        let kinds: [WorldScreenPlayerFailure] = [
            .refusedEmbedding, .misconfigured, .notFound, .badIdentifier, .unsupported, .unmapped(7),
        ]
        expect(Set(kinds.map(\.panelText)).count == kinds.count,
            "断言5：六种失败的话互不相同（\(kinds.count) 种 / \(Set(kinds.map(\.panelText)).count) 句）"
                + "—— 不拿一句笼统的糊过去")
        expect(WorldScreenPlayerFailure(youtubeCode: 101).panelText
                == WorldScreenPlayerFailure(youtubeCode: 150).panelText,
            "断言5：101 与 150 同一句话（同一个意思：不让在别处播）")
        expect(WorldScreenPlayerFailure(youtubeCode: 153).panelText
                == WorldScreenPlayerFailure(youtubeCode: 152).panelText,
            "断言5：153 与 152 同一句话（同一个意思：播放器不接受这个来源）")
        expect(all.allSatisfy { !$0.technicalDescription.isEmpty },
            "断言5：技术口径也不是空的")
        expect(WorldScreenPlayerFailure(youtubeCode: 153).technicalDescription.contains("153"),
            "断言5：技术口径带得上码（153 进日志与 details，用户看不到）")
        expect(WorldScreenPlayerFailure(youtubeCode: 101).panelText == "这段视频不允许在别处播放。",
            "断言5：101/150 那一句就是「这段视频不允许在别处播放。」"
                + "（实测 \(WorldScreenPlayerFailure(youtubeCode: 101).panelText)）")

        // 接线：失败状态那一行走的是 `panelText`。
        let state = WorldScreenSurfaceState.failed(.playerRefused(.refusedEmbedding))
        expect(state.displayText.contains("这段视频不允许在别处播放"),
            "断言5：失败状态读得出那句人话（实测「\(state.displayText)」）")
        expect(state.isPlaying == false,
            "断言5：播放器拒绝之后**不再**自称 playing")

        // 给外层文本判据递材料：承载页原文（base64，避开换行）与实测来源取样。
        print("HTML-SAMPLE " + Data(html.utf8).base64EncodedString())
        print("ORIGIN-SAMPLE \(origin)")
        print("IFRAME-SAMPLE \(WorldScreenEmbedPage.playerURL(embedURL: embed, origin: origin))")

        print("INNER-FAILURES=\(failuresTotal)")
        if failuresTotal > 0 { exit(1) }
    }
}
"""##

// 现编现跑
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-embed-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

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

/// 生产里参与这一层判据的三份源码（都只依赖 Foundation）。
let innerSourceNames = [
    "WorldScreenState.swift", "WorldScreenContent.swift", "WorldScreenEmbedOrigin.swift",
]

/// 把三份源码复制到临时目录、按需做一组文本替换，编出探针跑一次。
///
/// `note` 非空 = **探针压根没跑起来**（注入锚点找不到 / 编不过），此时 `status` 是 `-1`。
/// 判据必须把这两件事分开，否则"锚点没找到"会被当成"注入被抓住了"（一个恒真的假门禁）。
func runEmbedProbe(
    patches: [(file: String, from: String, to: String)] = []
) throws -> (status: Int32, output: String, note: String) {
    let directory = temporary.appendingPathComponent("probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [String] = []
    for name in innerSourceNames {
        var text = try read(screenRoot.appendingPathComponent(name))
        for patch in patches where patch.file == name {
            guard text.contains(patch.from) else {
                return (-1, "", "注入锚点在 \(name) 里找不到（签名改过？）：\(patch.from)")
            }
            text = text.replacingOccurrences(of: patch.from, with: patch.to)
        }
        let destination = directory.appendingPathComponent(name)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        sources.append(destination.path)
    }
    let program = directory.appendingPathComponent("Probe.swift")
    try innerProgram.write(to: program, atomically: true, encoding: .utf8)
    let binary = directory.appendingPathComponent("probe")
    let compile = try runCapturing(
        "/usr/bin/swiftc", ["-j1", "-parse-as-library"] + sources + [program.path, "-o", binary.path]
    )
    guard compile.status == 0 else {
        return (-1, compile.output,
                "探针没编起来（exit \(compile.status)）—— 注入把源码改坏了："
                    + compile.output.split(separator: "\n")
                        .filter { $0.contains("error:") }.prefix(3)
                        .joined(separator: " | "))
    }
    let run = try runCapturing(binary.path, [])
    return (run.status, run.output, "")
}

/// 把一段注入输出里的 `FAIL` 原话贴出来（红的是哪一条，当场看得见）。
func reportFailures(_ output: String, limit: Int = 2) {
    for line in output.split(separator: "\n").filter({ $0.hasPrefix("FAIL") }).prefix(limit) {
        print("  · \(line)")
    }
}

// MARK: 原件必须全绿

let clean = try runEmbedProbe()
check(clean.note.isEmpty && clean.status == 0 && clean.output.contains("INNER-FAILURES=0"),
    "内层判据（断言 1/2/3/4/5）在**原件**上全部通过"
        + "（exit \(clean.status)，"
        + "\(clean.output.split(separator: "\n").last(where: { $0.hasPrefix("INNER-FAILURES=") }) ?? "没有结论")）"
        + (clean.note.isEmpty ? "" : " —— \(clean.note)"))
reportFailures(clean.output, limit: 5)
for line in clean.output.split(separator: "\n")
where line.hasPrefix("PASS 断言1") || line.hasPrefix("PASS 断言2") {
    print("  · \(line)")
}

// MARK: 外层文本判据

let overlaySource = try read(screenRoot.appendingPathComponent("WorldScreenOverlayController.swift"))
let embedSource = try read(screenRoot.appendingPathComponent("WorldScreenEmbedOrigin.swift"))
let toolsSource = try read(screenRoot.appendingPathComponent("ResidentScreenTools.swift"))
let storeSource = try read(screenRoot.appendingPathComponent("WorldScreenStore.swift"))

let loadSiteProblems = embedLoadSiteProblems(overlaySource)
for problem in loadSiteProblems { print("   · \(problem)") }
check(loadSiteProblems.isEmpty,
    "断言1：嵌入页由一个**拥有合法 http(s) origin 的承载页**载入"
        + "（`loadHTMLString` + 回环随机端口 `baseURL`），不再是顶层直载")

let socketHits = listeningSocketProblems([
    "WorldScreenEmbedOrigin.swift": embedSource,
    "WorldScreenOverlayController.swift": overlaySource,
])
check(socketHits.isEmpty,
    "断言2：这条路上**没有任何监听套接字**（没有可绑错的主机、没有固定端口、"
        + "没有谁负责关的问题）—— 扫 2 份源码，命中 \(socketHits.count) 条"
        + (socketHits.isEmpty ? "" : "：\(socketHits.map(\.0).joined(separator: "；"))"))

let sampleOrigin = clean.output.split(separator: "\n")
    .first(where: { $0.hasPrefix("ORIGIN-SAMPLE ") })
    .map { String($0.dropFirst("ORIGIN-SAMPLE ".count)) } ?? ""
let sampleHTML = clean.output.split(separator: "\n")
    .first(where: { $0.hasPrefix("HTML-SAMPLE ") })
    .flatMap { Data(base64Encoded: String($0.dropFirst("HTML-SAMPLE ".count))) }
    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
check(!sampleOrigin.isEmpty && !sampleHTML.isEmpty,
    "外层材料：内层探针把承载页原文与来源取样递了出来（\(sampleOrigin)）")
let leakProblems = credentialLeakProblems(html: sampleHTML, origin: sampleOrigin)
for problem in leakProblems { print("   · \(problem)") }
check(leakProblems.isEmpty,
    "断言2：承载页与来源里**没有任何凭据字面量**（来源只有回环主机 + 随机端口，连 userinfo 都没有）")

let copyProblems = userFacingCopyProblems(panelCopySource: toolsSource, storeSource: storeSource)
for problem in copyProblems { print("   · \(problem)") }
check(copyProblems.isEmpty,
    "断言5：用户看得见的那一句话来自 `panelText`；带码的工程口径只进 `details`/日志"
        + "（`cause: failure.errorDescription` 仍在）")

print("  · 实测来源取样：origin=\(sampleOrigin)  baseURL=\(sampleOrigin)/")
for line in clean.output.split(separator: "\n") where line.hasPrefix("IFRAME-SAMPLE ") {
    print("  · 实测 iframe 指向：\(line.dropFirst("IFRAME-SAMPLE ".count))")
}

// MARK: 注入负对照 —— 每一条都必须红

/// ① 承载来源回到 `file://`（不透明来源）⇒ 断言 1 必须红。
let fileInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenEmbedOrigin.swift",
    from: "\"http://\\(loopbackHost):\\(port)\"",
    to: "\"file://\\(loopbackHost):\\(port)\""
)])
check(fileInjection.note.isEmpty && fileInjection.status == 1
        && fileInjection.output.contains("合法 http(s) 来源"),
    "断言1（注入负对照「承载来源回到 file://」）：探针必须红在来源不合法这一条上"
        + "（exit \(fileInjection.status)）"
        + (fileInjection.note.isEmpty ? "" : " —— \(fileInjection.note)"))
reportFailures(fileInjection.output)

/// ② 承载页拿不到来源（`about:blank`）⇒ 断言 1 必须红。
let blankInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenEmbedOrigin.swift",
    from: "URL(string: originString(port: port) + \"/\")",
    to: "URL(string: \"about:blank\")"
)])
check(blankInjection.note.isEmpty && blankInjection.status == 1
        && blankInjection.output.contains("baseURL 本身也是合法来源"),
    "断言1（注入负对照「baseURL 换成 about:blank」）：探针必须红在 baseURL 这一条上"
        + "（exit \(blankInjection.status)）"
        + (blankInjection.note.isEmpty ? "" : " —— \(blankInjection.note)"))
reportFailures(blankInjection.output)

/// ③ 绑 `0.0.0.0` ⇒ 断言 2 必须红。
let wildcardInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenEmbedOrigin.swift",
    from: "static let loopbackHost = \"127.0.0.1\"",
    to: "static let loopbackHost = \"0.0.0.0\""
)])
check(wildcardInjection.note.isEmpty && wildcardInjection.status == 1
        && wildcardInjection.output.contains("只在回环上"),
    "断言2（注入负对照「绑 0.0.0.0」）：探针必须红在只在回环这一条上"
        + "（exit \(wildcardInjection.status)）"
        + (wildcardInjection.note.isEmpty ? "" : " —— \(wildcardInjection.note)"))
reportFailures(wildcardInjection.output)

/// ④ 固定端口 ⇒ 断言 2 必须红。
let fixedPortInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenEmbedOrigin.swift",
    from: "UInt16.random(in: portRange)",
    to: "UInt16(8080)"
)])
check(fixedPortInjection.note.isEmpty && fixedPortInjection.status == 1
        && fixedPortInjection.output.contains("端口是随机的"),
    "断言2（注入负对照「固定端口 8080」）：探针必须红在端口随机这一条上"
        + "（exit \(fixedPortInjection.status)）"
        + (fixedPortInjection.note.isEmpty ? "" : " —— \(fixedPortInjection.note)"))
reportFailures(fixedPortInjection.output)

/// ⑤ 引入一个监听者（绑哪儿 / 谁关都没写）⇒ 外层文本判据必须红。
let listenerCopy = temporary.appendingPathComponent("WorldScreenEmbedOriginWithListener.swift")
try (embedSource + "\nlet leakyListener = NWListener(using: .tcp)\n")
    .write(to: listenerCopy, atomically: true, encoding: .utf8)
let listenerHits = listeningSocketProblems([
    "WorldScreenEmbedOriginWithListener.swift": try read(listenerCopy),
])
check(!listenerHits.isEmpty,
    "断言2（注入负对照「引入一个监听者」）：文本判据必须红。原话："
        + listenerHits.map(\.0).joined(separator: "；"))

/// ⑥ 来源里塞进凭据 ⇒ 凭据判据必须红。
let credentialHTML = sampleHTML + "\n<script>var t = document.cookie;</script>\n"
let injectedLeak = credentialLeakProblems(html: credentialHTML, origin: sampleOrigin)
check(!injectedLeak.isEmpty,
    "断言2（注入负对照「承载页碰 cookie」）：凭据判据必须红。原话："
        + injectedLeak.joined(separator: "；"))

/// ⑦ 把原始错误原文当成"人话"丢给用户 ⇒ 断言 5 必须红。
let rawCopyInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenState.swift",
    from: "            \"播放器没能在这块屏幕上启动。再放一次，还不行就换一条链接。\"",
    to: "            \"视频播放器配置错误 错误 153\""
)])
check(rawCopyInjection.note.isEmpty && rawCopyInjection.status == 1
        && rawCopyInjection.output.contains("ASCII 数字都没有"),
    "断言5（注入负对照「把原始错误原文丢给用户」）：探针必须红在"
        + "人话里一个数字都没有这一条上"
        + "（exit \(rawCopyInjection.status)）"
        + (rawCopyInjection.note.isEmpty ? "" : " —— \(rawCopyInjection.note)"))
reportFailures(rawCopyInjection.output)

/// ⑧a 承载页回到"没有来源"（`baseURL: nil`）⇒ 外层文本判据必须红。
let noBaseURLCopy = overlaySource.replacingOccurrences(
    of: "baseURL: baseURL", with: "baseURL: nil"
)
check(noBaseURLCopy != overlaySource, "断言1（注入负对照）：`baseURL: nil` 确实被注入到了副本里")
check(!embedLoadSiteProblems(noBaseURLCopy).isEmpty,
    "断言1（注入负对照「承载页没有来源」）：判据必须红。原话："
        + embedLoadSiteProblems(noBaseURLCopy).joined(separator: "；"))

/// ⑧b 加载点回到**顶层直载** ⇒ 外层文本判据必须红。
let directLoadCopy = overlaySource + "\n// injected\nwebView.load(URLRequest(url: url))\n"
let directProblems = embedLoadSiteProblems(directLoadCopy)
check(!directProblems.isEmpty,
    "断言1（注入负对照「回到顶层直载」）：判据必须红。原话："
        + directProblems.joined(separator: "；"))

/// ⑨ 白名单旁路 ⇒ 断言 3（零放宽）必须红。
let bypassAnchor = "        guard let rule = rules.first(where: { $0.host == host }) else {"
let bypassedBody = "        if host.hasSuffix(\"googlevideo.com\") { return .success(url) }\n"
    + bypassAnchor
let contentSource = try read(screenRoot.appendingPathComponent("WorldScreenContent.swift"))
check(contentSource.replacingOccurrences(of: bypassAnchor, with: bypassedBody) != contentSource,
    "断言3（注入负对照）：白名单旁路确实被注入到了副本里")
let bypassInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenContent.swift", from: bypassAnchor, to: bypassedBody
)])
check(bypassInjection.note.isEmpty && bypassInjection.status == 1
        && bypassInjection.output.contains("白名单被放宽了"),
    "断言3（注入负对照「给白名单开后门」）：探针必须红在白名单被放宽这一条上"
        + "（exit \(bypassInjection.status)）"
        + (bypassInjection.note.isEmpty ? "" : " —— \(bypassInjection.note)"))
reportFailures(bypassInjection.output)

/// ⑩ 承载页把 iframe 改指向别的域 ⇒ 断言 3 必须红。
let rewriteInjection = try runEmbedProbe(patches: [(
    file: "WorldScreenEmbedOrigin.swift",
    from: "return embedURL + separator + \"enablejsapi=1&origin=\" + encodedOrigin",
    to: "return \"https://r1---sn-x.googlevideo.com/videoplayback\" + separator"
        + " + \"enablejsapi=1&origin=\" + encodedOrigin"
)])
check(rewriteInjection.note.isEmpty && rewriteInjection.status == 1
        && rewriteInjection.output.contains("iframe 指向的仍然是官方嵌入域"),
    "断言3（注入负对照「承载页改指 googlevideo」）：探针必须红在 iframe 域这一条上"
        + "（exit \(rewriteInjection.status)）"
        + (rewriteInjection.note.isEmpty ? "" : " —— \(rewriteInjection.note)"))
reportFailures(rewriteInjection.output)

print(failureCount == 0 ? "PASS 嵌入来源判据全部通过" : "FAIL 嵌入来源判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
