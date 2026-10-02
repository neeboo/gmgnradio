// **现场探针**（不进 `make test-harnesses` 门禁）：把生产代码生成的那一页真的塞进一个
// 离屏 `WKWebView`，看它到底是"播放器配置错误"还是"出画"。
//
// 它为什么单独存在：`tools/test-resident-screen-embed-origin.swift` 是**离线**判据
// （现编现跑纯值，不碰网络也不碰 WebKit），而真机 2026-10-02 那个 153 只有把页面
// 真的载一次才看得见。两条一起才完整：一条钉"来源对不对"，一条钉"载起来是什么样"。
//
// 用法：
//
// ```bash
// swift tools/probe-screen-embed-live.swift                 # 默认用用户给的那个视频
// swift tools/probe-screen-embed-live.swift aPcL35kgL6A /tmp/screen.png 26
// ```
//
// 判据（退出码）：
//   * 0 —— 承载页的 origin 是合法 http(s)，且页面**没有**出现播放器错误；
//   * 1 —— 出现了错误原文（例：`错误 153` / `该嵌入配置错误`）或来源不合法。
//
// 它**不启动 App**、不写任何用户数据、不碰 cookie（用的是 `WKWebsiteDataStore.default()`
// 的离屏实例，与 App 的进程无关）。
import AppKit
import WebKit

let arguments = CommandLine.arguments
let videoID = arguments.count > 1 ? arguments[1] : "aPcL35kgL6A"
let pngPath = arguments.count > 2 ? arguments[2] : ""
let seconds = arguments.count > 3 ? Double(arguments[3]) ?? 26 : 26

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen")

func fail(_ message: String) -> Never {
    print("PROBE-FAIL \(message)")
    exit(1)
}

// MARK: 1) 用**生产源码**生成承载页与 baseURL

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-live-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

let generatorDirectory = temporary.appendingPathComponent("generator")
try FileManager.default.createDirectory(at: generatorDirectory, withIntermediateDirectories: true)
let generator = generatorDirectory.appendingPathComponent("main.swift")
try """
import Foundation
let port = WorldScreenEmbedOrigin.randomPort()
let origin = WorldScreenEmbedOrigin.originString(port: port)
print("ORIGIN=\\(origin)")
print("LEGAL=\\(WorldScreenEmbedOrigin.isLegalEmbeddingOrigin(origin))")
print("LOOPBACK=\\(WorldScreenEmbedOrigin.isLoopbackOnly(origin: origin))")
print("BASEURL=\\(WorldScreenEmbedOrigin.baseURL(port: port)?.absoluteString ?? "nil")")
print("HTML<<<")
print(WorldScreenEmbedPage.html(
    embedURL: "https://www.youtube.com/embed/\(videoID)", origin: origin
))
print(">>>HTML")
""".write(to: generator, atomically: true, encoding: .utf8)

func run(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
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

let generatorBinary = generatorDirectory.appendingPathComponent("generator")
let generated = try run("/usr/bin/swiftc", [
    "-j1",
    screenRoot.appendingPathComponent("WorldScreenState.swift").path,
    screenRoot.appendingPathComponent("WorldScreenEmbedOrigin.swift").path,
    generator.path,
    "-o", generatorBinary.path,
])
guard generated.status == 0 else {
    fail("生产源码没编起来（exit \(generated.status)）：\n\(generated.output)")
}
let emitted = try run(generatorBinary.path, [])
guard emitted.status == 0 else { fail("生成器没跑起来：\n\(emitted.output)") }

func emittedValue(_ key: String) -> String? {
    emitted.output.split(separator: "\n")
        .first(where: { $0.hasPrefix("\(key)=") })
        .map { String($0.dropFirst(key.count + 1)) }
}
guard let origin = emittedValue("ORIGIN"),
      let baseURLString = emittedValue("BASEURL"),
      let baseURL = URL(string: baseURLString),
      let html = emitted.output.split(separator: "\n")
          .firstIndex(where: { $0 == "HTML<<<" })
          .map({ index -> String in
              let rest = emitted.output.split(separator: "\n", omittingEmptySubsequences: false)
              guard let end = rest.firstIndex(where: { $0 == ">>>HTML" }) else { return "" }
              return rest[(index + 1)..<end].joined(separator: "\n")
          })
else { fail("生成器没有吐出承载页 / 来源") }

print("PROBE-ORIGIN \(origin)")
print("PROBE-BASEURL \(baseURLString)")
print("PROBE-LEGAL \(emittedValue("LEGAL") ?? "?")  LOOPBACK \(emittedValue("LOOPBACK") ?? "?")")
if emittedValue("LEGAL") != "true" || emittedValue("LOOPBACK") != "true" {
    fail("承载页的来源不合法 / 不是回环：\(origin)")
}

// MARK: 2) 离屏载入生产那一页

final class LiveProbe: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var didFinish = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = false
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 540), configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        print("PROBE-NAV didFinish \(webView.url?.absoluteString ?? "nil")")
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: any Error
    ) { print("PROBE-NAV didFailProvisional \(e.localizedDescription)") }
    func webView(_ webView: WKWebView, didFail n: WKNavigation!, withError e: any Error) {
        print("PROBE-NAV didFail \(e.localizedDescription)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = LiveProbe()

/// 内置负对照（与 `tools/test-resident-*.swift` 里那套 `*_INJECT` 同一形状）：
///
/// * `SCREEN_EMBED_INJECT=direct-load` —— 按**改动前**的方式顶层直载官方嵌入页
///   （没有嵌它的那个文档）⇒ 这一轮**必须**红，而且红在「错误 153」那一句上；
/// * `SCREEN_EMBED_INJECT=no-origin` —— 承载页不给 `baseURL` ⇒ 来源是不透明的
///   ⇒ 这一轮**必须**红。
let injection = ProcessInfo.processInfo.environment["SCREEN_EMBED_INJECT"] ?? ""
switch injection {
case "direct-load":
    print("PROBE-INJECT direct-load：故意按改动前的方式顶层直载嵌入页（应当复现 153）")
    probe.webView.load(URLRequest(url: URL(string: "https://www.youtube.com/embed/\(videoID)")!))
case "no-origin":
    print("PROBE-INJECT no-origin：故意不给承载页 baseURL（应当没有合法来源）")
    probe.webView.loadHTMLString(html, baseURL: nil)
default:
    probe.webView.loadHTMLString(html, baseURL: baseURL)
}

/// 直接复用**生产**的那一段取数脚本 —— 探针要看的正是 native 侧真的读到了什么。
let probeScript = """
(function () {
  var title = String(document.title || '');
  var body = (document.body && document.body.innerText) ? document.body.innerText : '';
  return JSON.stringify({
    title: title.slice(0, 400),
    text: body.replace(/\\s+/g, ' ').slice(0, 600),
    href: location.href, origin: location.origin,
    iframes: document.querySelectorAll('iframe').length
  });
})();
"""

var lastReport = ""
let deadline = Date().addingTimeInterval(seconds)
var tick = 0
while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    tick += 1
    if tick % 4 == 0 {
        probe.webView.evaluateJavaScript(probeScript) { value, _ in
            if let value = value as? String { lastReport = value }
        }
    }
}
probe.webView.evaluateJavaScript(probeScript) { value, _ in
    if let value = value as? String { lastReport = value }
}
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
print("PROBE-REPORT \(lastReport)")

if !pngPath.isEmpty {
    var done = false
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(x: 0, y: 0, width: 960, height: 540)
    probe.webView.takeSnapshot(with: configuration) { image, error in
        if let image, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: pngPath))
            print("PROBE-SNAPSHOT \(pngPath)")
        } else {
            print("PROBE-SNAPSHOT-FAILED \(error?.localizedDescription ?? "nil")")
        }
        done = true
    }
    let waitUntil = Date().addingTimeInterval(12)
    while !done, Date() < waitUntil { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
}

// MARK: 3) 判据

let errorMarkers = [
    "视频播放器配置错误", "错误 153", "Error 153",
    "该嵌入配置错误", "NoParent", "此视频不能观看",
]
let hit = errorMarkers.first { lastReport.contains($0) }
if let hit {
    fail("承载页上出现了播放器错误原文「\(hit)」：\(lastReport)")
}
if !lastReport.contains("\"origin\":\"\(origin)\"") {
    fail("承载页的 origin 不是 \(origin)：\(lastReport)")
}
print("PROBE-PASS 承载页 origin = \(origin)（合法 http(s) + 回环 + 无监听者），"
    + "页面上没有出现任何播放器错误原文（视频 id \(videoID)）")
exit(0)
