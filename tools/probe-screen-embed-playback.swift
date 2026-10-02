// **现场探针**（不进 `make test-harnesses` 门禁）：官方嵌入页在承载页里**到底有没有开始播**。
//
// 与 `tools/probe-screen-embed-live.swift` 的分工：
//   * 那一份量的是「**来源**对不对」（承载页的 origin 合法吗、页面上有没有出现播放器错误原文）；
//   * 这一份量的是「**播放有没有真的开始**」—— 承载页是同一份生产 HTML，但读数不是
//     主文档的 title/body（跨域 iframe 读不到），而是**注入到每一帧**的一段取数脚本，
//     它把该帧里 `<video>` 的 `currentTime / paused / muted / readyState` postMessage 给顶层。
//
// 为什么可以注入到跨域帧：`WKUserScript(forMainFrameOnly: false)` 的脚本运行在**那一帧
// 自己的 JS 上下文**里。**这是探针专用的量具，不进生产**（生产承载页只读自己这一页的
// `document.title`，见 `WorldScreenEmbedPage`），而且只带数字回来，不带任何内容。
//
// 用法：
//
// ```bash
// swift tools/probe-screen-embed-playback.swift <label> <embedURL> [seconds] [png]
// SCREEN_PLAYBACK_FREE_GESTURE=1 swift tools/probe-screen-embed-playback.swift ...   # 换 WebKit 播放策略
// ```
//
// 判据（退出码）：
//   * 0 —— `currentTime` 真的前进了（PLAYING）；
//   * 2 —— 播放器起得来但**没有开始播**（STALLED，贴出 paused / currentTime / 错误原文）；
//   * 3 —— 帧里出现了播放器错误页原文（PAGE-ERROR）。
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count > 2 else {
    print("用法：swift tools/probe-screen-embed-playback.swift <label> <embedURL> [seconds] [png]")
    exit(64)
}
let label = arguments[1]
let embedURL = arguments[2]
let seconds = arguments.count > 3 ? Double(arguments[3]) ?? 22 : 22
let pngPath = arguments.count > 4 ? arguments[4] : ""
let freeGesture = ProcessInfo.processInfo.environment["SCREEN_PLAYBACK_FREE_GESTURE"] == "1"
/// 对照：不用承载页，直接一张**最简**的 `<video autoplay muted>` 页 —— 用来分辨
/// "播放没起来"到底是**站方播放器/参数**的问题，还是"这台离屏 WKWebView 根本放不了"。
let controlVideo = ProcessInfo.processInfo.environment["SCREEN_PLAYBACK_CONTROL_VIDEO"] ?? ""
/// 对照：把 web 视图**放进一个真的 NSWindow**（放在屏幕外）—— 离屏且不在窗口里的视图
/// 在 WebKit 眼里是"页面不可见"，而视频页会据此改变行为。生产里它当然在窗口里。
let useWindow = ProcessInfo.processInfo.environment["SCREEN_PLAYBACK_WINDOW"] == "1"

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen")

func fail(_ message: String, _ code: Int32) -> Never {
    print("PLAYBACK-FAIL \(label) \(message)")
    exit(code)
}

// MARK: 1) 用**生产源码**生成承载页与 baseURL（与 probe-screen-embed-live.swift 同一手法）

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-playback-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

let generatorDirectory = temporary.appendingPathComponent("generator")
try FileManager.default.createDirectory(at: generatorDirectory, withIntermediateDirectories: true)
let generator = generatorDirectory.appendingPathComponent("main.swift")
// 嵌入 URL 走**环境变量**而不是源码插值：URL 里有 `&` 与 `"`，插进 Swift 字面量里
// 会变成"字符串里的字符串"（实测 swiftc 直接报 `cannot find 'embedURL' in scope`）。
// 生成器是**生产源码原文**的搬运工，这里不改它一个字。
try """
import Foundation
let embedURL = ProcessInfo.processInfo.environment["GMGN_EMBED_URL"] ?? ""
let port = WorldScreenEmbedOrigin.randomPort()
let origin = WorldScreenEmbedOrigin.originString(port: port)
print("ORIGIN=\\(origin)")
print("BASEURL=\\(WorldScreenEmbedOrigin.baseURL(port: port)?.absoluteString ?? "nil")")
print("IFRAMESRC=\\(WorldScreenEmbedPage.playerURL(embedURL: embedURL, origin: origin))")
print("HTML<<<")
print(WorldScreenEmbedPage.html(embedURL: embedURL, origin: origin))
print(">>>HTML")
""".write(to: generator, atomically: true, encoding: .utf8)

var generatorEnvironment = ProcessInfo.processInfo.environment
generatorEnvironment["GMGN_EMBED_URL"] = embedURL

func run(
    _ binary: String, _ arguments: [String], environment: [String: String]? = nil
) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    if let environment { process.environment = environment }
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
    fail("生产源码没编起来（exit \(generated.status)）：\n\(generated.output)", 3)
}
let emitted = try run(generatorBinary.path, [], environment: generatorEnvironment)
guard emitted.status == 0 else { fail("生成器没跑起来：\n\(emitted.output)", 3) }

func emittedValue(_ key: String) -> String? {
    emitted.output.split(separator: "\n")
        .first(where: { $0.hasPrefix("\(key)=") })
        .map { String($0.dropFirst(key.count + 1)) }
}
guard let origin = emittedValue("ORIGIN"),
      let baseURLString = emittedValue("BASEURL"), let baseURL = URL(string: baseURLString),
      let html = emitted.output.split(separator: "\n")
          .firstIndex(where: { $0 == "HTML<<<" })
          .map({ index -> String in
              let rest = emitted.output.split(separator: "\n", omittingEmptySubsequences: false)
              guard let end = rest.firstIndex(where: { $0 == ">>>HTML" }) else { return "" }
              return rest[(index + 1)..<end].joined(separator: "\n")
          })
else { fail("生成器没有吐出承载页 / 来源", 3) }

print("PLAYBACK-CASE \(label)")
print("PLAYBACK-ORIGIN \(origin)")
print("PLAYBACK-IFRAME-SRC \(emittedValue("IFRAMESRC") ?? "?")")
print("PLAYBACK-FREE-GESTURE \(freeGesture)")

// MARK: 2) 注入到**每一帧**的量具：只带数字回来

let instrument = """
(function () {
  if (window.__gmgnPlaybackProbe) { return; }
  window.__gmgnPlaybackProbe = true;
  function snapshot() {
    var video = document.querySelector('video');
    var body = (document.body && document.body.innerText) ? document.body.innerText : '';
    var state = {
      href: String(location.href).slice(0, 200),
      title: String(document.title || '').slice(0, 120),
      visibility: String(document.visibilityState || ''),
      videos: document.querySelectorAll('video').length,
      text: body.replace(/\\s+/g, ' ').slice(0, 300),
      errors: (window.__gmgnPlaybackErrors || []).slice(0, 3)
    };
    try {
      state.resources = performance.getEntriesByType('resource').slice(-8).map(function (e) {
        return { name: String(e.name).slice(0, 110), ms: Math.round(e.duration),
                 bytes: e.transferSize, kind: e.initiatorType };
      });
    } catch (_) {}
    if (video) {
      state.currentTime = video.currentTime;
      state.duration = video.duration;
      state.paused = video.paused;
      state.muted = video.muted;
      state.volume = video.volume;
      state.readyState = video.readyState;
      state.networkState = video.networkState;
      state.ended = video.ended;
      state.autoplay = video.autoplay;
      state.playbackRate = video.playbackRate;
      state.mediaError = video.error ? (video.error.code + ':' + video.error.message) : null;
      state.buffered = video.buffered ? video.buffered.length : 0;
      state.src = String(video.currentSrc || video.src || '').slice(0, 140);
    }
    return state;
  }
  window.__gmgnPlaybackErrors = window.__gmgnPlaybackErrors || [];
  window.addEventListener('error', function (event) {
    try { window.__gmgnPlaybackErrors.push(String(event.message).slice(0, 200)); } catch (_) {}
  });
  window.addEventListener('unhandledrejection', function (event) {
    try {
      window.__gmgnPlaybackErrors.push('rejection:' + String(event.reason).slice(0, 200));
    } catch (_) {}
  });
  if (window.top === window) {
    window.__gmgnPlaybackFrames = [];
    window.addEventListener('message', function (event) {
      var data = event.data;
      if (data && data.__gmgnPlayback) { window.__gmgnPlaybackFrames.push(data.__gmgnPlayback); }
    });
    // 顶层自己也报一份：对照组（最简 `<video>` 页）就活在顶层。
    setInterval(function () {
      try { window.__gmgnPlaybackFrames.push(snapshot()); } catch (_) {}
    }, 500);
    return;
  }
  setInterval(function () {
    try { window.top.postMessage({ __gmgnPlayback: snapshot() }, '*'); } catch (_) {}
  }, 500);
  try { window.top.postMessage({ __gmgnPlayback: snapshot() }, '*'); } catch (_) {}
})();
"""

// MARK: 3) 离屏载入生产那一页（可选：换掉 WebKit 的播放策略做对照）

final class PlaybackProbe: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var navigations: [String] = []

    init(freeGesture: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = false
        if freeGesture {
            // 对照：官方 API —— "这些媒体类型不需要用户手势"。默认值是 `.audio`。
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: instrument, injectionTime: .atDocumentStart, forMainFrameOnly: false
            )
        )
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 540), configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigations.append("didFinish \(webView.url?.absoluteString ?? "nil")")
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: any Error
    ) { navigations.append("didFailProvisional \(e.localizedDescription)") }
    func webView(_ webView: WKWebView, didFail n: WKNavigation!, withError e: any Error) {
        navigations.append("didFail \(e.localizedDescription)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = PlaybackProbe(freeGesture: freeGesture)
var probeWindow: NSWindow?
if useWindow {
    // 放在屏幕外：**不弹到用户眼前**，但对 WebKit 而言这一页在一个真的窗口里。
    let window = NSWindow(
        contentRect: NSRect(x: -2400, y: -2400, width: 960, height: 540),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = probe.webView
    window.orderFrontRegardless()
    probeWindow = window
    print("PLAYBACK-WINDOW on (offscreen \(window.frame))")
}
if controlVideo.isEmpty {
    probe.webView.loadHTMLString(html, baseURL: baseURL)
    print("PLAYBACK-MODE embed")
} else {
    let control = """
    <!doctype html><html><head><meta charset="utf-8"><title>gmgn-control</title>
    <style>html,body{margin:0;height:100%;background:#111}video{width:100%;height:100%}</style>
    </head><body><video src="\(controlVideo)" autoplay muted playsinline></video></body></html>
    """
    probe.webView.loadHTMLString(control, baseURL: baseURL)
    print("PLAYBACK-MODE control \(controlVideo)")
}

/// 顶层那一帧的取数：把我们注入的收集器数组读回来。
let readScript = """
(function () {
  return JSON.stringify({
    frames: (window.__gmgnPlaybackFrames || []).slice(-12),
    href: location.href
  });
})();
"""

var samples: [String] = []
var lastReport = ""
let deadline = Date().addingTimeInterval(seconds)
var tick = 0
while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    tick += 1
    if tick % 4 == 0 {
        probe.webView.evaluateJavaScript(readScript) { value, _ in
            if let value = value as? String { lastReport = value }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if !lastReport.isEmpty { samples.append(lastReport) }
    }
}
probe.webView.evaluateJavaScript(readScript) { value, _ in
    if let value = value as? String { lastReport = value }
}
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
samples.append(lastReport)

for (index, sample) in samples.enumerated() {
    print("PLAYBACK-SAMPLE[\(index)] \(sample)")
}
for line in probe.navigations { print("PLAYBACK-NAV \(line)") }
if let probeWindow { print("PLAYBACK-WINDOW-VISIBLE \(probeWindow.isVisible)") }

if !pngPath.isEmpty {
    var done = false
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(x: 0, y: 0, width: 960, height: 540)
    probe.webView.takeSnapshot(with: configuration) { image, error in
        if let image, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: pngPath))
            print("PLAYBACK-PNG \(pngPath)")
        } else {
            print("PLAYBACK-PNG-FAILED \(error?.localizedDescription ?? "nil")")
        }
        done = true
    }
    let waitUntil = Date().addingTimeInterval(12)
    while !done, Date() < waitUntil { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
}

// MARK: 4) 判据：`currentTime` 有没有真的前进

/// 从每一份采样里挑出"最大的那个 currentTime"（不挑帧：同一时刻可能有好几帧在报）。
func maxCurrentTime(_ json: String) -> Double? {
    guard let data = json.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let frames = object["frames"] as? [[String: Any]]
    else { return nil }
    let values = frames.compactMap { ($0["currentTime"] as? NSNumber)?.doubleValue }
    return values.max()
}

let times = samples.compactMap(maxCurrentTime)
let advanced = (times.max() ?? 0) - (times.first ?? 0)

let errorMarkers = [
    "该嵌入配置错误", "NoParent", "embed-error", "视频播放器配置错误", "错误 153", "Error 153",
    "此视频不能观看", "播放器配置错误",
]
if let marker = errorMarkers.first(where: { lastReport.contains($0) }) {
    print("PLAYBACK-VERDICT PAGE-ERROR 命中错误原文「\(marker)」")
    exit(3)
}
/// 判据线：`currentTime` 至少前进这么多秒才算"真的开始播"。
///
/// **0.5 秒不够**：B 站播放器起来时会先 seek 到一帧预览（实测停在 0.333 – 0.6 秒），
/// 用 0.5 会把"停在封面上"判成 PLAYING（这条线自己就抓过一次假阳性）。
let playingThreshold = 2.0

if times.count >= 2, advanced >= playingThreshold {
    print("PLAYBACK-VERDICT PLAYING currentTime 前进 \(String(format: "%.2f", advanced)) 秒"
        + "（\(times.map { String(format: "%.1f", $0) }.joined(separator: " → "))）")
    exit(0)
}
print("PLAYBACK-VERDICT STALLED currentTime 没有前进"
    + "（采样 \(times.map { String(format: "%.1f", $0) }.joined(separator: " → "))）")
exit(2)
