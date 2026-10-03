// 电视机覆盖层：**待机不挂网页视图** + **镜头运动时降载**这两条的判据。
//
// 真机 2026-10-03（第二次报「镜头对着电视去缩放还是爆卡」）。上一轮把"宿主每帧改尺寸 ⇒
// WKWebView 每帧重排重画"压掉 40×（120 帧 120 次 → 3 次），我们这一侧每帧只剩 0.25 ms，
// 可真机照旧卡 —— 剩下的钱在**跨进程/合成**那一层，以及"待机也一直挂着一个内容进程"。
// 这一份钉的就是那两个结构性缺口：
//
//   断言11 **待机不挂网页视图**：屏幕没在播放时，容器子树里**没有** `WKWebView`，
//          引用也不留，本进程**一个网页视图都没造过**（⇒ 没有内容进程可言），
//          屏幕上由两层同色占位玻璃呈现；开始播放才挂上（一次性代价记账），
//          `stop()` 把它摘下来并丢掉引用。
//          注入「待机也一直挂着」/「关掉之后不摘视图」⇒ 必须 FAIL。
//
//   断言12 **镜头运动时降载、停下立刻恢复**：相机在动的每一帧都按低分辨率 backing 渲染
//          （渲染档位 ≤ `motionRenderScale × (1+滞回)`），相机停下的**第一帧**就回到全质量
//          并写下精确变换；亚像素漂移（每帧不到半个像素）里变换更新不超过帧数的 1/3；
//          运动期间我们这一侧每帧仍在预算内；**每一帧**（含被跳过的帧）写进图层的变换
//          回投到屏幕四角的偏差 ≤ 0.5 px（对齐判据一个字没放宽）。
//          注入「运动中不降载」/「停下之后停在低质量」/「变换每帧都写」⇒ 必须 FAIL。
//
// 手法沿袭仓里的离线 harness：
//   * 驱动的是**生产源码原文**（`Screen/` 那一组 + `WorldScreenOverlayController.swift`）；
//   * 探针用 `/usr/bin/swiftc -O` 现编现跑：**不启动 App**、不碰 Metal、**不碰网络**
//     （这一份里根本没有页面被载进来——量的是"视图在不在、档位降没降、写了几次"）；
//   * `-O` 是必须的：每帧预算量的是紧的 simd 内层循环，debug 下同一段代码慢 ~70 倍；
//   * 注入负对照在**源码副本**上做手术，真源码一个字节都不动。
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

func runCaptured(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
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
// MARK: 内层程序：待机 / 播放 / 关掉 + 运动 / 停下 / 漂移
// ---------------------------------------------------------------------------

let screenFiles = [
    "WorldScreenGeometry.swift", "WorldScreenInference.swift", "WorldScreenProjection.swift",
    "WorldScreenContent.swift", "WorldScreenState.swift", "ResidentScreenTools.swift",
    "WorldScreenOcclusion.swift",
]

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

let quad = WorldScreenQuad(
    center: SIMD3<Float>(0, 0.8, -3.95), yaw: 0, pitch: 0, halfWidth: 0.62, halfHeight: 0.35)
let corners = quad.worldCorners(placedAt: SIMD3<Float>(0, 0, 0), yaw: 0)
let normal = quad.worldNormal(yaw: 0)
let viewport = SIMD2<Float>(1600, 1000)

func projection(_ camera: WorldScreenCamera) -> WorldScreenProjection {
    WorldScreenProjection(camera: camera, profile: .fullStage, viewportSize: viewport)
}

/// 图层**实际**口径回投之后，覆盖层四角与屏幕四角的偏差（px）。与断言10 同一式：
/// `position + anchorOffset + T(q − anchorOffset)`，读的是图层现在真的拿着的值。
@MainActor
func alignmentError(_ surface: WorldScreenSurface, _ projection: WorldScreenProjection) -> Float {
    guard let normalized = projection.screenQuad(worldCorners: corners),
          let layer = surface.container.layer else { return 0 }
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
    var worst: Float = 0
    for corner in 0 ..< 4 {
        guard let actual = written.apply(to: source[corner] - anchorOffset) else { continue }
        worst = max(worst, simd_length(position + anchorOffset + actual - points[corner]))
    }
    return worst
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // ================= 断言11：待机不挂网页视图 =================
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    let controller = WorldScreenOverlayController(hostView: host)
    let surface = controller.surface(for: "tv-1")

    // 待机 + 镜头在动：这才是"对着电视缩放时那块关着的屏"的形状。
    var idleWorstAlignment: Float = 0
    for frame in 0 ..< 120 {
        let t = Float(frame) / 119
        let camera = WorldScreenCamera(
            position: SIMD3(0.2 * t, 0.85, -2.6 + 4.2 * (1 - t)), yaw: 0.08 * t, pitch: 0)
        let projectionValue = projection(camera)
        controller.update(
            quads: ["tv-1": corners], normals: ["tv-1": normal],
            projection: projectionValue, camera: camera, occluders: .empty)
        if controller.frameCost.didApplyPlacement {
            idleWorstAlignment = max(idleWorstAlignment, alignmentError(surface, projectionValue))
        }
    }
    probeCheck(surface.webView == nil, "待机：这一块屏**一个网页视图都没留着**（`webView == nil`）")
    probeCheck(!surface.isWebViewAttached, "待机：视图树里没有网页视图（`isWebViewAttached == false`）")
    probeCheck(surface.container.subviews.isEmpty,
               "待机：容器子树里一个子视图都没有（实测 \(surface.container.subviews.count) 个）")
    probeCheck(WorldScreenSurface.constructedWebViewCount == 0,
               "待机：本进程**一个网页视图都没造过**（实测 \(WorldScreenSurface.constructedWebViewCount) 个）"
                   + " ⇒ 没有 WebKit 内容进程可言")
    probeCheck(surface.idleAppearanceIsReady,
               "待机：屏幕上是一块'关着的玻璃'（两层同色占位层在、且铺满容器）")
    probeCheck(surface.lastAttachCost == nil, "待机：从来没过'挂上'这一步（一次性代价的账也是空的）")
    probeCheck(idleWorstAlignment <= 0.5,
               String(format: "待机时贴覆盖层照旧：对齐偏差 %.5f px ≤ 0.5 px", idleWorstAlignment))

    // 开始播放：挂上（生产里 `playScreen` 在载页**之前**调这一句）。
    let created = surface.attachWebViewIfNeeded()
    probeCheck(created, "开始播放：这一步真的造并挂上了网页视图")
    probeCheck(surface.isWebViewAttached, "开始播放：网页视图在视图树里")
    probeCheck(WorldScreenSurface.constructedWebViewCount == 1,
               "开始播放：本进程造过 1 个网页视图（实测 \(WorldScreenSurface.constructedWebViewCount)）")
    probeCheck(!surface.idleAppearanceIsReady, "开始播放：占位玻璃让位（隐藏），画面交给网页")
    if let cost = surface.lastAttachCost {
        let milliseconds = Double(cost.components.attoseconds) / 1e15
            + Double(cost.components.seconds) * 1000
        probeCheck(milliseconds >= 0, String(format: "一次性代价被记账：挂上一次 %.2f ms", milliseconds))
    } else {
        probeCheck(false, "一次性代价没有被记账（`lastAttachCost == nil`）")
    }
    probeCheck(surface.attachWebViewIfNeeded() == false,
               "再挂一次是空操作（幂等）：仍然只有 1 个网页视图")

    // 挂着的时候照旧每帧贴（对齐不受影响），然后关掉。
    for frame in 0 ..< 60 {
        let t = Float(frame) / 59
        let camera = WorldScreenCamera(
            position: SIMD3(0.05 * t, 0.85, -0.8 + 1.2 * (1 - t)), yaw: 0.02 * t, pitch: 0)
        controller.update(
            quads: ["tv-1": corners], normals: ["tv-1": normal],
            projection: projection(camera), camera: camera, occluders: .empty)
    }
    surface.stop()
    pump(0.2)
    probeCheck(!surface.isWebViewAttached && surface.webView == nil,
               "关掉之后：网页视图**摘下来了、引用也丢掉了**（待机不再养着内容进程）")
    probeCheck(surface.container.subviews.isEmpty,
               "关掉之后：容器子树里又只剩占位玻璃（实测 \(surface.container.subviews.count) 个子视图）")
    probeCheck(surface.idleAppearanceIsReady, "关掉之后：占位玻璃回来了（'关着的玻璃'观感不变）")

    // ================= 断言12：运动降载 / 停下恢复 / 亚像素不白写 =================
    let host2 = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    let controller2 = WorldScreenOverlayController(hostView: host2)
    let surface2 = controller2.surface(for: "tv-2")
    surface2.attachWebViewIfNeeded()

    // (a) 快速推进 120 帧：这就是"对着电视去缩放"。
    var motionFrames = 0
    var shedFrames = 0
    var restoreFrames = 0
    var transformWrites = 0
    var sizeChanges = 0
    var costs: [Double] = []
    var worstMotionAlignment: Float = 0
    var minimumRenderScale: Float = 1
    var previousCamera: WorldScreenCamera?
    for frame in 0 ..< 120 {
        let t = Float(frame) / 119
        let camera = WorldScreenCamera(
            position: SIMD3(0.2 * t, 0.85, -2.6 + 4.2 * (1 - t)), yaw: 0.08 * t, pitch: 0)
        let projectionValue = projection(camera)
        // 「相机在动」由**相机自己**说了算（不是读覆盖层的判断 —— 那会让判据自证）：
        // 位姿与上一帧不同就是动了。
        let cameraMoved = previousCamera.map {
            $0.position != camera.position || $0.yaw != camera.yaw || $0.pitch != camera.pitch
        } ?? false
        previousCamera = camera
        controller2.update(
            quads: ["tv-2": corners], normals: ["tv-2": normal],
            projection: projectionValue, camera: camera, occluders: .empty)
        let cost = controller2.frameCost
        if cameraMoved { motionFrames += 1 }
        if cost.didShedForMotion { shedFrames += 1 }
        if cost.didRestoreFromMotion { restoreFrames += 1 }
        if cost.didApplyPlacement { transformWrites += 1 }
        if cost.didResizeSurface { sizeChanges += 1 }
        costs.append(cost.milliseconds)
        if cameraMoved { minimumRenderScale = min(minimumRenderScale, cost.renderScale) }
        // **写过的帧**必须与它自己那一份 placement 逐点一致。
        if cost.didApplyPlacement {
            worstMotionAlignment = max(worstMotionAlignment, alignmentError(surface2, projectionValue))
        }
    }
    let motionAverage = costs.reduce(0, +) / Double(costs.count)
    let motionPeak = costs.max() ?? 0
    print(String(format: "MOTION 快速推进：%d 帧里降载 %d 帧、恢复 %d 帧；变换写入 %d 次；"
                 + "宿主尺寸变化 %d 次；渲染档位最低 %.3f；"
                 + "每帧均 %.3f ms 峰 %.3f ms；写过的帧最大对齐偏差 %.5f px",
                 motionFrames, shedFrames, restoreFrames, transformWrites, sizeChanges,
                 minimumRenderScale, motionAverage, motionPeak, worstMotionAlignment))

    // (b) 相机停下：**那一帧之内**必须回到全质量，并写下精确变换。
    let lastCamera = previousCamera ?? WorldScreenCamera()
    controller2.update(
        quads: ["tv-2": corners], normals: ["tv-2": normal],
        projection: projection(lastCamera), camera: lastCamera, occluders: .empty)
    let stopCost = controller2.frameCost
    let restoredScale = stopCost.renderScale
    let stopAlignment = alignmentError(surface2, projection(lastCamera))
    print(String(format: "MOTION 停下第一帧：恢复标记 %@；渲染档位 %.3f；写了变换 %@；对齐 %.5f px",
                 stopCost.didRestoreFromMotion ? "真" : "假", restoredScale,
                 stopCost.didApplyPlacement ? "真" : "假", stopAlignment))

    // (c) 停下之后一动不动 ⇒ 一个字节都不该再写。
    controller2.update(
        quads: ["tv-2": corners], normals: ["tv-2": normal],
        projection: projection(lastCamera), camera: lastCamera, occluders: .empty)
    let idleAgainCost = controller2.frameCost

    // (d) 亚像素漂移 120 帧：每帧不到半个像素 ⇒ 只有攒够了才写一次。
    //
    // 0.00015 m/帧、屏在约 1.35 m 处 ⇒ 四角每帧挪约 0.08 px：攒够半个像素要 ~6 帧。
    // 于是"每帧都写"（120 次）与"只在超过容差时写"（约 20 次）差得很开，闸门有余量。
    var subPixelFrames = 0
    var subPixelWrites = 0
    var worstSubPixelAlignment: Float = 0
    let base = lastCamera.position
    for frame in 0 ..< 120 {
        let camera = WorldScreenCamera(
            position: SIMD3(base.x + 0.00015 * Float(frame + 1), base.y, base.z),
            yaw: lastCamera.yaw, pitch: 0)
        let projectionValue = projection(camera)
        controller2.update(
            quads: ["tv-2": corners], normals: ["tv-2": normal],
            projection: projectionValue, camera: camera, occluders: .empty)
        subPixelFrames += 1
        if controller2.frameCost.didApplyPlacement { subPixelWrites += 1 }
        // **每一帧**都要看对齐 —— 被跳过的帧也一样（那正是"不许放宽"的那一条）。
        worstSubPixelAlignment = max(worstSubPixelAlignment, alignmentError(surface2, projectionValue))
    }
    print(String(format: "MOTION 亚像素漂移：%d 帧里写了 %d 次变换；最大对齐偏差 %.5f px",
                 subPixelFrames, subPixelWrites, worstSubPixelAlignment))

    let problems = WorldScreenFrameBudget.motionProblems(
        motionFrames: motionFrames, shedFrames: shedFrames,
        minimumRenderScale: minimumRenderScale,
        restoredWithinOneFrame: stopCost.didRestoreFromMotion && stopCost.didApplyPlacement,
        restoredRenderScale: restoredScale,
        averageCostMilliseconds: motionAverage, peakCostMilliseconds: motionPeak,
        subPixelFrames: subPixelFrames, subPixelTransformWrites: subPixelWrites)
    for problem in problems { probeCheck(false, "运动降载：\(problem)") }
    if problems.isEmpty { probeCheck(true, "运动降载：降档 / 恢复 / 亚像素节流 / 每帧预算 全部在闸门内") }

    probeCheck(restoreFrames == 0, "运动途中没有误判成'恢复'（恢复只在相机真的停下那一帧）")
    probeCheck(!idleAgainCost.didApplyPlacement,
               "停下之后一动不动 ⇒ 一个字节都不写（`didApplyPlacement == false`）")
    probeCheck(worstMotionAlignment <= 0.5,
               String(format: "运动中**写过**的帧：最大对齐偏差 %.5f px ≤ 0.5 px", worstMotionAlignment))
    probeCheck(worstSubPixelAlignment <= 0.5,
               String(format: "亚像素漂移的**每一帧**（含被跳过的）：最大对齐偏差 %.5f px ≤ 0.5 px"
                      + " —— 节流没有把对齐判据顶破", worstSubPixelAlignment))
    probeCheck(sizeChanges <= WorldScreenFrameBudget.maximumSurfaceSizeChanges,
               "运动这一段宿主尺寸只变 \(sizeChanges) 次 ≤ "
                   + "\(WorldScreenFrameBudget.maximumSurfaceSizeChanges) 次")
}

print(probeFailures == 0 ? "PROBE-FAILURES=0" : "PROBE-FAILURES=\(probeFailures)")
exit(probeFailures == 0 ? 0 : 1)
"""##

// ---------------------------------------------------------------------------
// MARK: 现编现跑（按需做一组文本手术）
// ---------------------------------------------------------------------------

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-idle-motion-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

func runProbe(
    patches: [(file: String, from: String, to: String)]
) throws -> (status: Int32, output: String, note: String) {
    let directory = temporary.appendingPathComponent("probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let optionalScreenFiles = ["WorldScreenEmbedOrigin.swift"].filter {
        FileManager.default.fileExists(atPath: screenRoot.appendingPathComponent($0).path)
    }
    var sources: [String] = []
    for name in screenFiles + ["WorldScreenOverlayController.swift"] + optionalScreenFiles {
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
    let program = directory.appendingPathComponent("main.swift")
    try probeProgram.write(to: program, atomically: true, encoding: .utf8)
    let binary = directory.appendingPathComponent("probe")
    // **-O 是必须的**：每帧预算量的是紧的 simd 内层循环，debug 下慢 ~70 倍。
    let compile = try runCaptured(
        "/usr/bin/swiftc", ["-j1", "-O"] + sources + [program.path, "-o", binary.path])
    guard compile.status == 0 else {
        return (-1, compile.output, "探针没编起来（exit \(compile.status)）—— 注入把源码改坏了")
    }
    let run = try runCaptured(binary.path, [])
    return (run.status, run.output, "")
}

let clean = try runProbe(patches: [])
for line in clean.output.split(separator: "\n")
    .filter({ $0.hasPrefix("MOTION ") || $0.hasPrefix("PROBE-FAIL") }) {
    print("  · \(line)")
}
let conclusion = clean.output.split(separator: "\n")
    .last(where: { $0.hasPrefix("PROBE-FAILURES=") }) ?? "没有结论"
check(clean.note.isEmpty && clean.status == 0 && clean.output.contains("PROBE-FAILURES=0"),
      "断言11/12：原件上跑「待机不挂网页视图」+「运动降载 / 停下恢复 / 亚像素节流」全部通过"
          + "（exit \(clean.status)，\(conclusion)）"
          + (clean.note.isEmpty ? "" : " —— \(clean.note)"))

// ---------------------------------------------------------------------------
// MARK: 注入负对照（在源码副本上做手术，真源码一个字节都不动）
// ---------------------------------------------------------------------------

let injections: [(name: String, patches: [(file: String, from: String, to: String)], expected: String)] = [
    (name: "待机也一直挂着网页视图",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        let surface = WorldScreenSurface(objectID: objectID)\n",
                to: "        let surface = WorldScreenSurface(objectID: objectID)\n"
                    + "        surface.attachWebViewIfNeeded()\n")],
     expected: "待机"),
    (name: "关掉之后不摘视图（留着内容进程）",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        detachWebView()\n        transition(to: .stopped)",
                to: "        transition(to: .stopped)")],
     expected: "关掉之后"),
    (name: "运动中不降载（渲染尺寸照旧全尺寸）",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "            let desiredSize = Self.motionAwareRenderedSize(boundsSize, moving: moving)",
                to: "            let desiredSize = boundsSize")],
     // 生产判据原文（`WorldScreenFrameBudget.motionProblems`）："运动中渲染档位最小只到
     // %.3f（应当 ≤ %.2f）—— backing 没变小"。措辞换过，这里必须逐字对齐；否则注入虽然
     // 真的红了，harness 也会因为找不到旧串而误报 FAIL。
     expected: "运动中渲染档位最小只到"),
    (name: "停下之后停在低质量",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        guard moving else { return fullSize }",
                to: "        _ = moving")],
     expected: "还停在"),
    (name: "变换每帧都写（去掉 0.5 px 闸门）",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "            if surface.appliedFrameSize != targetSize || layerWasReset\n"
                    + "                || lag >= WorldScreenFrameBudget.motionPixelThreshold {",
                to: "            if true {")],
     expected: "每帧不到半个像素"),
]

for injection in injections {
    let probe = try runProbe(patches: injection.patches)
    let caught = probe.note.isEmpty && probe.status == 1
        && probe.output.contains("PROBE-FAILURES=")
        && !probe.output.contains("PROBE-FAILURES=0")
        && probe.output.contains(injection.expected)
    check(caught,
          "断言11/12（注入负对照「\(injection.name)」）：探针必须红在「\(injection.expected)」这一条上"
              + "（exit \(probe.status)）"
              + (probe.note.isEmpty ? "" : " —— \(probe.note)"))
    for line in probe.output.split(separator: "\n").filter({ $0.hasPrefix("PROBE-FAIL") }).prefix(2) {
        print("  · \(line)")
    }
}

print(failureCount == 0 ? "PASS 待机/运动判据全部通过" : "FAIL 待机/运动判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
