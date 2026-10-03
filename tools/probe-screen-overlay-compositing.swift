// **现场量具**（不进 `make test-harnesses` 门禁）：覆盖层的代价**到底花在谁身上**。
//
// 真机 2026-10-03 的第二次报障：「镜头对着电视去缩放还是爆卡」。上一轮把"宿主每帧改尺寸
// ⇒ WKWebView 每帧重排重画"压掉 40×（120 次 → 3 次），我们这一侧每帧只剩 0.25 ms，
// 可真机照旧卡 —— 所以剩下的钱**不在我们的 CPU 上**。这一份量具去把那笔钱找出来。
//
// 它量四件事，每一件都有明确的对照：
//
//   1. **待机**（`stop()` 之后、什么都没在放）：屏幕上还留着几个 `WebContent` 内容进程？
//      这两秒里它们烧掉多少 CPU？（`stop()` 只 `stopLoading` + 载空页，**不销毁**视图）
//   2. **播放代理**（高分辨率静态页 + 120 帧推进）：每帧 `CATransaction` commit/flush 的
//      墙钟、到"合成器收下"的延迟、以及我们这一侧的记账。
//   3. **摘出视图树**（同一个网页层还在，只是不在树里）+ 120 帧推进：与 2 的差 = 这个层
//      参与合成要多少钱。
//   4. **销毁**（`removeFromSuperview()` + 丢掉引用）+ 2 秒：内容进程多久消失。
//
// 关于"合成耗时"这个口径，先把话说在前面（这是本量具**实测**出来的边界，不是猜的）：
// 屏幕外的 `NSWindow`（-2400, -2400）会被 WindowServer 裁掉，于是 render server 那一半
// 在客户端量不出来 —— 三相同一段 120 帧推进里 `WindowServer` 的 CPU 是平的
// （0.81 / 0.80 / 0.76 s per 2 s），`commit` 也只有 0.02–0.07 ms。**能离线量到的是
// "我们这一侧"与"进程与变换的次数"，量不到的是显示管线上的重采样。** 那一条只能真机量。
//
// 手法沿袭仓里既有的离线探针：
//   * 驱动的是**生产那一份** `WorldScreenOverlayController` / `WorldScreenSurface` 原文；
//   * 窗口放在屏幕外（-2400, -2400）+ `orderFrontRegardless()`。**必须在窗口里**：
//     不在任何窗口里的离屏 `WKWebView` 页面是"不可见"的，连最简视频都不播
//     （上一轮的量具陷阱）；
//   * 页面是本地生成的，**不碰网络**：一张 2048 × 1152 的高分辨率图（`data:` URL）
//     铺满视口 —— 层内容画一次就不再变，于是"每帧重新合成这张大纹理"被单独隔离出来
//     （视频层就是这个形状：内容在别处更新，我们每帧给它换一个透视变换）；
//   * 每帧一节显式 `CATransaction`：`commit` + `flush` 的墙钟就是"这一帧交给合成器"的钱；
//     再挂 `setCompletionBlock` 量到"合成器真的收下了"为止；
//   * 跨进程那一半用**进程 CPU 时间**（`ps -o time=`）量：`WebContent` 与本进程。
//
// 用法（**-O 是必须的**，debug 下同一段代码慢 ~70 倍，量的就成了编译器）：
//
// ```bash
// swift tools/probe-screen-overlay-compositing.swift
// ```
//
// 只报告数字，不设判据（判据在 `tools/test-resident-screen-overlay.swift` 里）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen")

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

// ---------------------------------------------------------------------------
// MARK: 内层程序：四相
// ---------------------------------------------------------------------------

let probeProgram = ##"""
import AppKit
import Foundation
import WebKit
import simd

var probeFailures = 0
func probeCheck(_ condition: Bool, _ message: String) {
    if condition { print("PROBE-PASS \(message)") } else {
        print("PROBE-FAIL \(message)"); probeFailures += 1
    }
}

func pump(_ seconds: TimeInterval) {
    guard seconds > 0 else { return }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func runPS(_ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 一个进程的**累计 CPU 时间**（秒）。`ps -o time=` 给的是 `MM:SS.ss`。
func cpuSeconds(of pid: Int32) -> Double {
    guard let output = try? runPS(["-o", "time=", "-p", "\(pid)"]),
          let raw = output.split(separator: "\n").first.map(String.init)?
              .trimmingCharacters(in: .whitespaces), !raw.isEmpty
    else { return 0 }
    let parts = raw.split(separator: ":")
    if parts.count == 3 {
        return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60
            + (Double(parts[2]) ?? 0)
    }
    if parts.count == 2 { return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0) }
    return Double(raw) ?? 0
}

func totalCPUSeconds(of pids: [Int32]) -> Double {
    pids.reduce(0) { $0 + cpuSeconds(of: $1) }
}

/// 现在活着的 `WebContent` 进程集合。
func webContentProcesses() -> Set<Int32> {
    guard let output = try? runPS(["-Ao", "pid=,comm="]) else { return [] }
    var found: Set<Int32> = []
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { continue }
        guard let pid = Int32(trimmed[trimmed.startIndex ..< space]) else { continue }
        if String(trimmed[trimmed.index(after: space)...]).contains("WebKit.WebContent") {
            found.insert(pid)
        }
    }
    return found
}

func windowServerPID() -> Int32? {
    guard let output = try? runPS(["-Ao", "pid=,comm="]) else { return nil }
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { continue }
        guard let pid = Int32(trimmed[trimmed.startIndex ..< space]) else { continue }
        if String(trimmed[trimmed.index(after: space)...]).hasSuffix("WindowServer") { return pid }
    }
    return nil
}

/// 一张 2048 × 1152 的高分辨率图（`data:` URL）。层内容只画这一次 ——
/// 于是这一相里"每帧重新合成这张大纹理"这件事被单独隔离出来（视频层就是这个形状）。
func bigImageDataURL(width: Int, height: Int) -> String {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return "" }
    for index in 0 ..< 24 {
        let t = CGFloat(index) / 23
        context.setFillColor(CGColor(
            red: 0.05 + 0.6 * t, green: 0.12 + 0.4 * (1 - t), blue: 0.28 + 0.5 * t, alpha: 1
        ))
        context.fill(CGRect(
            x: CGFloat(index) * CGFloat(width) / 24, y: 0,
            width: CGFloat(width) / 24 + 1, height: CGFloat(height)
        ))
    }
    for index in 0 ..< 60 {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
        context.fill(CGRect(
            x: 0, y: CGFloat(index) / 59 * CGFloat(height), width: CGFloat(width), height: 3
        ))
    }
    guard let image = context.makeImage() else { return "" }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return "" }
    return "data:image/png;base64," + data.base64EncodedString()
}

let pageHTML: String = {
    let image = bigImageDataURL(width: 2048, height: 1152)
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <style>html,body{margin:0;height:100%;overflow:hidden;background:#123}
    img{position:absolute;left:0;top:0;width:100%;height:100%;display:block}</style>
    </head><body><img src="\(image)"></body></html>
    """
}()

// ---------------------------------------------------------------------------
// MARK: 一相：120 帧推进
// ---------------------------------------------------------------------------

struct PhaseReading {
    var name = ""
    var frames = 0
    var seconds = 0.0
    var updateAverage = 0.0
    var updatePeak = 0.0
    var commitAverage = 0.0
    var commitPeak = 0.0
    var flushAverage = 0.0
    var flushPeak = 0.0
    var frameAverage = 0.0
    var completionAverage = 0.0
    var completionSamples = 0
    var transformWrites = 0
    var sizeChanges = 0
    var webViewResizes = 0
    var worstAlignment: Float = 0
    var ownerCPU = 0.0
    var contentCPU = 0.0
    var renderScaleMinimum: Float = 1
    /// 这一相见过的**最大**宿主渲染尺寸（全质量那一份）。
    var fullBacking = SIMD2<Float>(0, 0)
    /// 这一相见过的**最小**宿主渲染尺寸（降载那一份）。
    var shedBacking = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
}

/// 把这一块屏的网页视图拿出来。
///
/// 生产**待机时根本不造**网页视图（`surface(for:)` 不再急着建），所以量具要显式地要一次
/// —— 与生产 `playScreen` / `load(url:)` 走的是同一句 `attachWebViewIfNeeded()`。
@MainActor
func attachedWebView(_ surface: WorldScreenSurface) -> WKWebView? {
    surface.attachWebViewIfNeeded()
    return surface.webView
}

@MainActor
func driveFrames(
    name: String, controller: WorldScreenOverlayController, surface: WorldScreenSurface,
    webView: WKWebView?, frames: Int, moving: Bool, contentPIDs: [Int32]
) -> PhaseReading {
    var reading = PhaseReading()
    reading.name = name

    let quad = WorldScreenQuad(center: SIMD3<Float>(0, 0.8, -3.95), yaw: 0, pitch: 0,
                               halfWidth: 0.62, halfHeight: 0.35)
    let corners = quad.worldCorners(placedAt: SIMD3<Float>(0, 0, 0), yaw: 0)
    let normal = quad.worldNormal(yaw: 0)

    // 冷启一帧不计入统计。
    let coldCamera = WorldScreenCamera(position: SIMD3(0, 0.85, 1.6), yaw: 0, pitch: 0)
    controller.update(
        quads: ["tv-1": corners], normals: ["tv-1": normal],
        projection: WorldScreenProjection(
            camera: coldCamera, profile: .fullStage, viewportSize: SIMD2(1600, 1000)),
        camera: coldCamera, occluders: .empty)
    pump(0.2)

    let ownerPID = getpid()
    let ownerBefore = cpuSeconds(of: ownerPID)
    let contentBefore = totalCPUSeconds(of: contentPIDs)

    let dt = 1.0 / 60.0
    var updateCosts: [Double] = []
    var commitCosts: [Double] = []
    var flushCosts: [Double] = []
    var frameCosts: [Double] = []
    var completionCosts: [Double] = []
    var transformWrites = 0
    var sizeChanges = 0
    var webViewResizes = 0
    var worstAlignment: Float = 0
    var previousTransform = surface.appliedTransform
    var previousSize = surface.appliedFrameSize
    var previousWebFrame = webView?.frame
    var fullSize = SIMD2<Float>(1, 1)
    var renderScaleMinimum: Float = 1
    var fullBacking = SIMD2<Float>(0, 0)
    var shedBacking = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)

    let loopStart = CFAbsoluteTimeGetCurrent()
    for frame in 0 ..< frames {
        let deadline = loopStart + Double(frame + 1) * dt
        let now = CFAbsoluteTimeGetCurrent()
        if deadline > now { pump(deadline - now) }

        let t = moving ? Float(frame) / Float(max(frames - 1, 1)) : 0
        let camera = WorldScreenCamera(
            position: SIMD3(0.2 * t, 0.85, -2.6 + 4.2 * (1 - t)), yaw: 0.08 * t, pitch: 0)
        let projection = WorldScreenProjection(
            camera: camera, profile: .fullStage, viewportSize: SIMD2(1600, 1000))

        var completionAt: Double?
        let frameStart = CFAbsoluteTimeGetCurrent()
        CATransaction.begin()
        CATransaction.setCompletionBlock { completionAt = CFAbsoluteTimeGetCurrent() }
        let updateStart = CFAbsoluteTimeGetCurrent()
        controller.update(quads: ["tv-1": corners], normals: ["tv-1": normal],
                          projection: projection, camera: camera, occluders: .empty)
        let updateEnd = CFAbsoluteTimeGetCurrent()
        CATransaction.commit()
        let commitEnd = CFAbsoluteTimeGetCurrent()
        CATransaction.flush()
        let flushEnd = CFAbsoluteTimeGetCurrent()

        let wroteTransform = surface.appliedTransform != previousTransform
        if wroteTransform {
            previousTransform = surface.appliedTransform
            transformWrites += 1
        }
        if surface.appliedFrameSize != previousSize {
            previousSize = surface.appliedFrameSize
            sizeChanges += 1
        }
        if let webView, webView.frame != previousWebFrame {
            previousWebFrame = webView.frame
            webViewResizes += 1
        }
        // 渲染档位读**生产自己的账**（`frameCost.renderScale` = 渲染尺寸 ÷ 全质量尺寸）：
        // 自己按"见过的最小 ÷ 见过的最大"算出来的是另一件事（相机由远推近时它恒为 1）。
        renderScaleMinimum = min(renderScaleMinimum, controller.frameCost.renderScale)
        if let applied = surface.appliedFrameSize {
            let size = SIMD2(Float(applied.width), Float(applied.height))
            fullSize = SIMD2(max(fullSize.x, size.x), max(fullSize.y, size.y))
            if size.x * size.y > fullBacking.x * fullBacking.y { fullBacking = size }
            if size.x * size.y < shedBacking.x * shedBacking.y { shedBacking = size }
        }

        // 对齐：按图层**实际**的口径回投（与断言10 同一式）。只在"这一帧真的写过变换"
        // （或第一帧）上判 —— 写过的变换必须与它自己那一份 `placement` 逐点一致。
        if (wroteTransform || frame == 0),
           let normalized = projection.screenQuad(worldCorners: corners),
           let layer = surface.container.layer {
            let points = normalized.map { projection.viewPoint(normalized: $0) }
            let liveSize = surface.container.bounds.size
            let anchor = layer.anchorPoint
            let position = SIMD2(Float(layer.position.x), Float(layer.position.y))
            let written = WorldScreenLayerTransform(cgTransform: layer.transform)
            let source: [SIMD2<Float>] = [
                SIMD2(0, 0), SIMD2(Float(liveSize.width), 0),
                SIMD2(Float(liveSize.width), Float(liveSize.height)),
                SIMD2(0, Float(liveSize.height)),
            ]
            let anchorOffset = SIMD2(
                Float(anchor.x) * Float(liveSize.width), Float(anchor.y) * Float(liveSize.height))
            for corner in 0 ..< 4 {
                guard let actual = written.apply(to: source[corner] - anchorOffset) else { continue }
                worstAlignment = max(
                    worstAlignment, simd_length(position + anchorOffset + actual - points[corner]))
            }
        }

        var waited = 0.0
        while completionAt == nil && waited < 0.05 {
            pump(0.001)
            waited += 0.001
        }
        if let completionAt { completionCosts.append((completionAt - commitEnd) * 1000) }

        updateCosts.append((updateEnd - updateStart) * 1000)
        commitCosts.append((commitEnd - updateEnd) * 1000)
        flushCosts.append((flushEnd - commitEnd) * 1000)
        frameCosts.append((flushEnd - frameStart) * 1000)
    }
    let loopEnd = CFAbsoluteTimeGetCurrent()

    reading.frames = frames
    reading.seconds = loopEnd - loopStart
    reading.updateAverage = updateCosts.reduce(0, +) / Double(frames)
    reading.updatePeak = updateCosts.max() ?? 0
    reading.commitAverage = commitCosts.reduce(0, +) / Double(frames)
    reading.commitPeak = commitCosts.max() ?? 0
    reading.flushAverage = flushCosts.reduce(0, +) / Double(frames)
    reading.flushPeak = flushCosts.max() ?? 0
    reading.frameAverage = frameCosts.reduce(0, +) / Double(frames)
    reading.completionAverage = completionCosts.isEmpty
        ? 0 : completionCosts.reduce(0, +) / Double(completionCosts.count)
    reading.completionSamples = completionCosts.count
    reading.transformWrites = transformWrites
    reading.sizeChanges = sizeChanges
    reading.webViewResizes = webViewResizes
    reading.worstAlignment = worstAlignment
    reading.ownerCPU = cpuSeconds(of: ownerPID) - ownerBefore
    reading.contentCPU = totalCPUSeconds(of: contentPIDs) - contentBefore
    reading.renderScaleMinimum = renderScaleMinimum
    reading.fullBacking = fullSize
    reading.shedBacking = shedBacking.x > 1e6 ? fullSize : shedBacking
    return reading
}

func printReading(_ reading: PhaseReading) {
    print(String(format: "PHASE %@: %d 帧 / %.2f s；我们这一侧 每帧均 %.3f ms 峰 %.3f ms；"
                 + "commit 均 %.3f ms 峰 %.3f ms；flush 均 %.3f ms 峰 %.3f ms；"
                 + "帧记账均 %.3f ms；合成完均 %.3f ms（%d 样本）；"
                 + "变换写入 %d/%d 帧；宿主尺寸变化 %d；WKWebView 换尺寸 %d；"
                 + "最大对齐偏差 %.4f px；渲染档位最低 %.3f；"
                 + "本进程 CPU %.3f s / 内容进程 CPU %.3f s",
                 reading.name, reading.frames, reading.seconds,
                 reading.updateAverage, reading.updatePeak,
                 reading.commitAverage, reading.commitPeak,
                 reading.flushAverage, reading.flushPeak,
                 reading.frameAverage, reading.completionAverage, reading.completionSamples,
                 reading.transformWrites, reading.frames, reading.sizeChanges,
                 reading.webViewResizes, reading.worstAlignment, reading.renderScaleMinimum,
                 reading.ownerCPU, reading.contentCPU))
    print(String(format: "PHASE %@: 宿主 backing 最大 %.0f×%.0f（%.2f Mpx）→ 最小 %.0f×%.0f（%.2f Mpx）",
                 reading.name, reading.fullBacking.x, reading.fullBacking.y,
                 reading.fullBacking.x * reading.fullBacking.y / 1_000_000,
                 reading.shedBacking.x, reading.shedBacking.y,
                 reading.shedBacking.x * reading.shedBacking.y / 1_000_000))
}

// ---------------------------------------------------------------------------
// MARK: 现场
// ---------------------------------------------------------------------------

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // **在窗口里**（放在屏幕外）：不在窗口里的离屏 WKWebView 页面是"不可见"的。
    let window = NSWindow(
        contentRect: NSRect(x: -2400, y: -2400, width: 1600, height: 1000),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    window.contentView = host
    window.orderFrontRegardless()
    pump(0.3)

    let windowServer = windowServerPID()
    let baseline = webContentProcesses()
    print("BASELINE WebContent 进程 = \(baseline.sorted())")

    let controller = WorldScreenOverlayController(hostView: host)
    let surface = controller.surface(for: "tv-1")
    // **待机**：生产现在连视图都不造（`surface(for:)` 不再急着建）。
    // 这一行**不许**调 `attachedWebView`（那一句会挂上视图，把待机测量毁掉）。
    var webView: WKWebView?

    // ---- 相 1：待机（什么都没在放）----
    let stopStart = CFAbsoluteTimeGetCurrent()
    surface.stop()
    let stopCost = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
    pump(1.5)
    let idlePIDs = Array(webContentProcesses().subtracting(baseline)).sorted()
    let idleCPUStart = totalCPUSeconds(of: idlePIDs)
    let ownerIdleStart = cpuSeconds(of: getpid())
    let windowServerIdleStart = windowServer.map { cpuSeconds(of: $0) } ?? 0
    pump(2.0)
    let idleCPU = totalCPUSeconds(of: idlePIDs) - idleCPUStart
    let ownerIdleCPU = cpuSeconds(of: getpid()) - ownerIdleStart
    let windowServerIdle = (windowServer.map { cpuSeconds(of: $0) } ?? 0) - windowServerIdleStart
    print(String(format: "IDLE stop() 本身 %.2f ms；待机时新增 WebContent 进程 %d 个 %@；"
                 + "空转 2.0 s 里 内容进程 CPU %.3f s / 本进程 %.3f s / WindowServer %.3f s",
                 stopCost, idlePIDs.count, "\(idlePIDs)", idleCPU, ownerIdleCPU, windowServerIdle))
    print("IDLE 待机时容器子树里有 WKWebView 吗 = \(surface.webView != nil)"
          + "；造过几个网页视图 = \(WorldScreenSurface.constructedWebViewCount)")

    // 待机但镜头在动：这才是"对着电视缩放时那块关着的屏"的形状。
    let idleMotion = driveFrames(
        name: "1 待机+推进", controller: controller, surface: surface, webView: nil,
        frames: 120, moving: true, contentPIDs: idlePIDs)
    printReading(idleMotion)
    print("IDLE 待机 120 帧之后：占位玻璃就位 = \(surface.idleAppearanceIsReady)"
          + "（容器 \(Int(surface.container.bounds.width))×\(Int(surface.container.bounds.height))）")

    // ---- 相 2：播放代理（高分辨率静态页，层内容不再变）+ 120 帧推进 ----
    // 这一步就是生产里"按下播放"那一下：`playScreen` / `load(url:)` 里的
    // `attachWebViewIfNeeded()`。一次性代价记在 `lastAttachCost` 上。
    webView = attachedWebView(surface)
    if let attachCost = surface.lastAttachCost {
        let milliseconds = Double(attachCost.components.attoseconds) / 1e15
            + Double(attachCost.components.seconds) * 1000
        print(String(format: "PLAYING 挂上网页视图（一次性）：%.2f ms；造过 %d 个",
                     milliseconds, WorldScreenSurface.constructedWebViewCount))
    }
    var playingPIDs: [Int32] = []
    if let webView {
        webView.loadHTMLString(pageHTML, baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !(!webView.isLoading && webView.estimatedProgress >= 1.0) {
            pump(0.05)
        }
        pump(0.5)
        playingPIDs = Array(webContentProcesses().subtracting(baseline)).sorted()
        print("PLAYING 内容进程 = \(playingPIDs)")
    }
    let playing = driveFrames(
        name: "2 播放代理+推进", controller: controller, surface: surface, webView: webView,
        frames: 120, moving: true, contentPIDs: playingPIDs)
    printReading(playing)

    // ---- 相 3：摘出视图树（层还在，只是不参与合成）+ 120 帧推进 ----
    webView?.removeFromSuperview()
    pump(0.3)
    let detached = driveFrames(
        name: "3 摘出视图树+推进", controller: controller, surface: surface, webView: webView,
        frames: 120, moving: true, contentPIDs: playingPIDs)
    printReading(detached)

    // ---- 相 4：销毁（**连引用一起丢掉**）+ 5 秒：内容进程多久消失 ----
    // 与生产 `stop()` 同一条路：`stopLoading` + `removeFromSuperview` + 丢掉引用。
    // 量具这一侧也必须把**自己手里那一份引用**丢掉，否则留下的是量具，不是生产。
    surface.stop()
    webView = nil
    let destroyStart = CFAbsoluteTimeGetCurrent()
    var remaining: [Int32] = playingPIDs
    var elapsed = 0.0
    while elapsed < 20.0 {
        pump(0.25)
        elapsed = CFAbsoluteTimeGetCurrent() - destroyStart
        remaining = Array(webContentProcesses().subtracting(baseline)).sorted()
        if remaining.isEmpty { break }
    }
    print(String(format: "DESTROY %.2f s 之后，属于本次进程的 WebContent 进程 %d 个 %@（丢掉引用之后）",
                 elapsed, remaining.count, "\(remaining)"))
    // 留在池里的那个进程**烧不烧 CPU**：这才是"待机要不要为它付钱"的判据。
    if !remaining.isEmpty {
        let cpuStart = totalCPUSeconds(of: remaining)
        let ownerStart = cpuSeconds(of: getpid())
        let windowServerStart = windowServer.map { cpuSeconds(of: $0) } ?? 0
        pump(2.0)
        print(String(format: "DESTROY 之后空转 2.0 s：残留内容进程 CPU %.3f s / 本进程 %.3f s / WindowServer %.3f s",
                     totalCPUSeconds(of: remaining) - cpuStart,
                     cpuSeconds(of: getpid()) - ownerStart,
                     (windowServer.map { cpuSeconds(of: $0) } ?? 0) - windowServerStart))
    }

    print(String(format: "DIFF 视图存在本身（2−3，同一个层在树里 vs 不在树里）"
                 + "commit %.3f ms｜合成完 %.3f ms｜帧记账 %.3f ms",
                 playing.commitAverage - detached.commitAverage,
                 playing.completionAverage - detached.completionAverage,
                 playing.frameAverage - detached.frameAverage))
    print(String(format: "DIFF 变换churn（待机推进 vs 摘出视图树）"
                 + "commit %.3f ms｜合成完 %.3f ms",
                 idleMotion.commitAverage - detached.commitAverage,
                 idleMotion.completionAverage - detached.completionAverage))
}

print(probeFailures == 0 ? "PROBE-FAILURES=0" : "PROBE-FAILURES=\(probeFailures)")
exit(probeFailures == 0 ? 0 : 1)
"""##

// ---------------------------------------------------------------------------
// MARK: 现编现跑
// ---------------------------------------------------------------------------

/// 覆盖层宿主依赖的屏幕源码清单 —— 与 `test-resident-screen-overlay.swift` 断言10 同一份。
let screenFiles = [
    "WorldScreenGeometry.swift", "WorldScreenInference.swift", "WorldScreenProjection.swift",
    "WorldScreenContent.swift", "WorldScreenState.swift", "ResidentScreenTools.swift",
    "WorldScreenOcclusion.swift",
]

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-compositing-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

var sources: [String] = []
for name in screenFiles + ["WorldScreenOverlayController.swift"] {
    sources.append(screenRoot.appendingPathComponent(name).path)
}
// `WorldScreenEmbedOrigin.swift` 在就带上（覆盖层宿主用到它），不在就跳过。
let embedOrigin = screenRoot.appendingPathComponent("WorldScreenEmbedOrigin.swift")
if FileManager.default.fileExists(atPath: embedOrigin.path) { sources.append(embedOrigin.path) }

let program = temporary.appendingPathComponent("main.swift")
try probeProgram.write(to: program, atomically: true, encoding: .utf8)

let binary = temporary.appendingPathComponent("compositing-probe")
let compile = try run(
    "/usr/bin/swiftc", ["-j1", "-O"] + sources + [program.path, "-o", binary.path])
guard compile.status == 0 else {
    for line in compile.output.split(separator: "\n").suffix(40) { print("   · [编译] \(line)") }
    print("FAIL 量具没编起来（exit \(compile.status)）")
    exit(1)
}

let executed = try run(binary.path, [])
for line in executed.output.split(separator: "\n") where !line.isEmpty { print(line) }
print(executed.status == 0 ? "PASS 覆盖层合成量具跑完" : "FAIL 覆盖层合成量具 exit \(executed.status)")
exit(executed.status == 0 ? 0 : 1)
