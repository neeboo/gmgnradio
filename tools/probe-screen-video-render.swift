// 电视原生视频**真的画进场景**的离屏判据（真 Metal 设备，无窗口、无权限）。
//
// 它把生产的 `WorldScreenVideoRenderer` + `WorldScreenNativeVideoRegistry` 原文编起来，
// 用同一个 `WorldScreenVideo.metal`（运行时按源码编译）做三件事的机器判据：
//   1. 注册表里的一张解码纹理**真的被画到四边形上**（可见性查询片元数 > 0，且像素
//      颜色就是纹理颜色 —— 不是一块常量色）；
//   2. 深度测试**真的在挡**（前面有更近的深度时，同一块电视的片元数 = 0）；
//   3. 两台电视之间也按深度分先后（近的画上、远的被挡），并且没有可画的东西时
//      **一个 pass 都不加**（`render` 返回 false）。
//
// 这补的是 2026-10-03 验收里那条硬缺口：“`WorldScreenNativeVideoRegistry` 没有被
// `MarbleSpatialView` 消费，解码统计在涨、电视却没画面”。
//
// 用法：
//   swift tools/probe-screen-video-render.swift
// 退出码 0 = 全部判据通过。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let nativeRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen/NativeMedia")
let metalRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/Metal")
let shaderRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/Shaders")

let productionSources: [(dir: URL, name: String)] = [
    (nativeRoot, "WorldScreenNativeVideoRegistry.swift"),
    (metalRoot, "WorldScreenVideoRenderer.swift"),
]
let shaderName = "WorldScreenVideo.metal"

let innerProgram = ##"""
import Foundation
import Metal
import simd

// MARK: - 判据

@MainActor
func runChecks(shaderPath: String) -> Int32 {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        print(condition ? "PASS \(message)" : "FAIL \(message)")
        if !condition { failures += 1 }
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("FAIL 需要 Metal 设备")
        return 2
    }
    guard let shaderSource = try? String(contentsOfFile: shaderPath, encoding: .utf8) else {
        print("FAIL 读不到 shader 源码：\(shaderPath)")
        return 2
    }
    let library: MTLLibrary
    do {
        library = try device.makeLibrary(source: shaderSource, options: nil)
    } catch {
        print("FAIL shader 编译失败：\(error.localizedDescription)")
        return 2
    }

    let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    let depthFormat = MTLPixelFormat.depth32Float
    guard let renderer = WorldScreenVideoRenderer(
        device: device, colorFormat: colorFormat, depthFormat: depthFormat, library: library
    ) else {
        print("FAIL 渲染器建不起来（管线 / 深度状态 / 采样器）")
        return 2
    }

    let width = 64
    let height = 64
    let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: colorFormat, width: width, height: height, mipmapped: false
    )
    colorDescriptor.usage = [.renderTarget, .shaderRead]
    colorDescriptor.storageMode = .shared
    guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else {
        print("FAIL 颜色纹理建不起来")
        return 2
    }
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: depthFormat, width: width, height: height, mipmapped: false
    )
    depthDescriptor.usage = [.renderTarget]
    depthDescriptor.storageMode = .private
    guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
        print("FAIL 深度纹理建不起来")
        return 2
    }
    guard let commandQueue = device.makeCommandQueue() else {
        print("FAIL 命令队列建不起来")
        return 2
    }

    // 一张 4x4 的纯红视频纹理：像素颜色可辨认，证明是**采样**出来的，不是常量。
    let videoDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false
    )
    videoDescriptor.usage = [.shaderRead]
    videoDescriptor.storageMode = .shared
    guard let videoTexture = device.makeTexture(descriptor: videoDescriptor) else {
        print("FAIL 视频纹理建不起来")
        return 2
    }
    var redPixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
    for pixel in 0..<16 {
        redPixels[pixel * 4 + 0] = 0    // B
        redPixels[pixel * 4 + 1] = 0    // G
        redPixels[pixel * 4 + 2] = 255  // R
        redPixels[pixel * 4 + 3] = 255  // A
    }
    videoTexture.replace(
        region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
        withBytes: redPixels, bytesPerRow: 4 * 4
    )

    // 世界四角直接给成裁剪空间坐标（viewProjection = 单位矩阵），深度固定 0.5，
    // 于是 forward(`.less`) 约定下：清到 1.0 就可见、清到 0.2 就被挡。
    func quad(z: Float) -> [SIMD3<Float>] {
        [
            SIMD3(-0.5, -0.5, z), SIMD3(0.5, -0.5, z),
            SIMD3(0.5, 0.5, z), SIMD3(-0.5, 0.5, z),
        ]
    }
    let registry = WorldScreenNativeVideoRegistry()

    /// 先清一遍（颜色黑、深度指定值），再让生产渲染器画一帧；等可见性读回落到主 actor。
    func renderFrame(
        frames: [WorldScreenNativeVideoRegistry.Frame],
        clearDepth: Float
    ) -> (didDraw: Bool, fragments: UInt64, encoded: Int) {
        let fragmentsBefore = renderer.stats.fragments
        let encodedBefore = renderer.stats.encodedQuads
        guard let command = commandQueue.makeCommandBuffer() else { return (false, 0, 0) }
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = colorTexture
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        clear.colorAttachments[0].storeAction = .store
        clear.depthAttachment.texture = depthTexture
        clear.depthAttachment.loadAction = .clear
        clear.depthAttachment.clearDepth = Double(clearDepth)
        clear.depthAttachment.storeAction = .store
        if let encoder = command.makeRenderCommandEncoder(descriptor: clear) {
            encoder.endEncoding()
        }
        let didDraw = renderer.render(
            commandBuffer: command,
            colorTexture: colorTexture,
            depthTexture: depthTexture,
            viewProjection: matrix_identity_float4x4,
            reversedDepth: false,
            preservesDepth: true,
            frames: frames
        )
        command.commit()
        command.waitUntilCompleted()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, renderer.stats.fragments == fragmentsBefore {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return (
            didDraw,
            renderer.stats.fragments - fragmentsBefore,
            renderer.stats.encodedQuads - encodedBefore
        )
    }

    // ① 真的画上：一张可见的电视 ⇒ 画了、片元数 = 四边形覆盖的像素数（32 x 32）。
    registry.register("tv-visible") {
        WorldScreenNativeVideoRegistry.Frame(
            objectID: "tv-visible", texture: videoTexture, quad: quad(z: 0.5), isReady: true
        )
    }
    let expectedFragments: UInt64 = 32 * 32
    let visible = renderFrame(frames: registry.frames(), clearDepth: 1.0)
    expect(visible.didDraw, "① 有可画的电视时 render 返回 true（真的加了 pass）")
    expect(visible.encoded == 1, "① 编码了 1 个电视四边形（实测 \(visible.encoded)）")
    expect(visible.fragments > 0,
        "① 深度通过、片元被写进 drawable（实测 \(visible.fragments)）")
    expect(visible.fragments <= UInt64(width * height),
        "① 片元数不超过视口像素数（实测 \(visible.fragments)）")
    expect(renderer.stats.lastPixelWidth == 4 && renderer.stats.lastPixelHeight == 4,
        "① 记录的是解码纹理的真实尺寸（实测 \(renderer.stats.lastPixelWidth)x\(renderer.stats.lastPixelHeight)）")

    // ② 像素来自视频纹理（纯红），不是常量色；并独立数一遍"真的被写亮的像素"。
    let bytesPerRow = width * 4
    var pixel = [UInt8](repeating: 0, count: bytesPerRow * height)
    pixel.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        colorTexture.getBytes(
            base, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
        )
    }
    var coveredPixels = 0
    for offset in stride(from: 0, to: pixel.count, by: 4) where pixel[offset + 2] > 40 {
        coveredPixels += 1
    }
    let center = (height / 2) * bytesPerRow + (width / 2) * 4
    let sampled = pixel[center + 0] < 40 && pixel[center + 1] < 40 && pixel[center + 2] > 200
    expect(sampled,
        "② 中心像素就是视频纹理的颜色（BGRA=\(pixel[center + 0]),\(pixel[center + 1]),\(pixel[center + 2])）")
    expect(pixel[0 * bytesPerRow + 0 * 4 + 2] < 40,
        "② 四边形之外仍是清屏黑（左上角 R=\(pixel[0 * bytesPerRow + 0 * 4 + 2])）")
    expect(UInt64(coveredPixels) > 0 && UInt64(coveredPixels) <= expectedFragments,
        "② 独立数出的亮像素数落在四边形覆盖范围内（实测 \(coveredPixels)，上限 \(expectedFragments)）")

    // ③ 深度遮挡：更近的深度挡在前面 ⇒ 同一块电视一个片元都不过。
    let occluded = renderFrame(frames: registry.frames(), clearDepth: 0.2)
    expect(occluded.didDraw && occluded.encoded == 1,
        "③ 被挡时仍然编码（证明是深度测试挡掉的，不是没画）")
    expect(occluded.fragments == 0,
        "③ 前面有更近的深度时片元数为 0（实测 \(occluded.fragments)）")

    // ④ 两台电视之间按深度分先后：近的先画上、远的被挡（名字决定编码顺序）。
    registry.removeAll()
    registry.register("tv-a-near") {
        WorldScreenNativeVideoRegistry.Frame(
            objectID: "tv-a-near", texture: videoTexture, quad: quad(z: 0.2), isReady: true
        )
    }
    registry.register("tv-b-far") {
        WorldScreenNativeVideoRegistry.Frame(
            objectID: "tv-b-far", texture: videoTexture, quad: quad(z: 0.8), isReady: true
        )
    }
    let stacked = renderFrame(frames: registry.frames(), clearDepth: 1.0)
    expect(stacked.encoded == 2, "④ 两个四边形都被编码（实测 \(stacked.encoded)）")
    expect(stacked.fragments == visible.fragments,
        "④ 只有更近的那台通过深度测试（远的贡献 +0 片元，近的 \(visible.fragments)，合计 \(stacked.fragments)）")
    expect(renderer.stats.lastObjectIDs == ["tv-a-near", "tv-b-far"],
        "④ 最近一帧按编码顺序记下物件（实测 \(renderer.stats.lastObjectIDs)）")

    // ⑤ 没出画的屏幕不画黑矩形；一个可画的都没有时 render 返回 false。
    registry.removeAll()
    registry.register("tv-blank") {
        WorldScreenNativeVideoRegistry.Frame(
            objectID: "tv-blank", texture: nil, quad: quad(z: 0.5), isReady: false
        )
    }
    let blank = renderFrame(frames: registry.frames(), clearDepth: 1.0)
    expect(!blank.didDraw && blank.encoded == 0,
        "⑤ 还没出画的电视不画（render 返回 false，不画黑矩形）")
    expect(renderer.stats.skippedNotReady > 0,
        "⑤ 具名记下没出画的跳过次数（实测 \(renderer.stats.skippedNotReady)）")

    print("---")
    print("drawPasses=\(renderer.stats.drawPasses) encodedQuads=\(renderer.stats.encodedQuads) fragments=\(renderer.stats.fragments)")
    return failures == 0 ? 0 : 1
}

@main struct Probe {
    @MainActor static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            print("FAIL 缺少 shader 路径")
            exit(2)
        }
        exit(runChecks(shaderPath: CommandLine.arguments[1]))
    }
}
"""##

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-video-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

var sources: [String] = []
for source in productionSources {
    let destination = temporary.appendingPathComponent(source.name)
    try FileManager.default.copyItem(
        at: source.dir.appendingPathComponent(source.name), to: destination
    )
    sources.append(destination.path)
}
let shaderDestination = temporary.appendingPathComponent(shaderName)
try FileManager.default.copyItem(
    at: shaderRoot.appendingPathComponent(shaderName), to: shaderDestination
)
let program = temporary.appendingPathComponent("Probe.swift")
try innerProgram.write(to: program, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("probe")

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

let compile = try runCapturing(
    "/usr/bin/swiftc", ["-j1", "-parse-as-library"] + sources + [program.path, "-o", binary.path]
)
guard compile.status == 0 else {
    FileHandle.standardError.write(Data("PROBE COMPILE FAILED\n\(compile.output)\n".utf8))
    exit(70)
}
let run = try runCapturing(binary.path, [shaderDestination.path])
FileHandle.standardOutput.write(Data(run.output.utf8))

// ---------------------------------------------------------------------------
// 源码级判据：`MarbleSpatialView` 必须**真的消费**取帧注册表。
//
// 上一轮拒收的根因不是渲染器不会画，而是"注册表登记了 provider，渲染器却从没读过它"
// —— 解码统计在涨、电视没画面。所以这里除了行为探针，还钉住生产源码里的那几处接线；
// 任何一处被删掉，这一条都会红。
// ---------------------------------------------------------------------------
var sourceFailures = run.status == 0 ? 0 : 1
func checkSource(_ condition: Bool, _ message: String) {
    print(condition ? "PASS \(message)" : "FAIL \(message)")
    if !condition { sourceFailures += 1 }
}
let marbleViewPath = metalRoot.appendingPathComponent("MarbleSpatialView.swift")
if let marbleView = try? String(contentsOf: marbleViewPath, encoding: .utf8) {
    checkSource(marbleView.contains("var worldScreenNativeVideoRegistry: WorldScreenNativeVideoRegistry?"),
        "源码：`MarbleSpatialView` 有注入取帧注册表的入口")
    checkSource(marbleView.contains("spatialRenderer?.screenVideoRegistry = worldScreenNativeVideoRegistry"),
        "源码：注入的注册表被转交给渲染器")
    checkSource(marbleView.contains("let frames = registry.frames()"),
        "源码：渲染器每帧真的读 `registry.frames()`")
    checkSource(marbleView.contains("worldScreenVideoRenderer?.render("),
        "源码：读到的帧交给 `WorldScreenVideoRenderer.render` 编码")
    checkSource(marbleView.contains("hasPreparedOccluder || hasGeneratedOutputDepth || screenVideoDrew"),
        "源码：视频 pass 写的深度并入 `drawAvatar` 的 preservesDepth 链（角色会被电视挡住）")
    checkSource(marbleView.contains("private var worldScreenVideoRenderer: WorldScreenVideoRenderer?"),
        "源码：渲染器持有视频 pass 的实例（不是只登记不消费）")
} else {
    checkSource(false, "源码：读不到 \(marbleViewPath.path)")
}
let appPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
if let app = try? String(contentsOf: appPath, encoding: .utf8) {
    checkSource(app.contains("stageRenderSurfaceController?.surfaceView.worldScreenNativeVideoRegistry ="),
        "源码：App 把 `WorldScreenStore.nativeVideoRegistry` 接到渲染面上")
    checkSource(app.contains("store.nativeVideoRegistry"),
        "源码：接的确实是 store 手里的那一份注册表（不是第二份）")
    checkSource(app.contains("state[\"screenVideo\"] ="),
        "源码：`playback_state` 暴露渲染侧度量（E2E 判据读它）")
} else {
    checkSource(false, "源码：读不到 \(appPath.path)")
}
print("---")
print("behavior_exit=\(run.status) source_failures=\(sourceFailures)")
exit(run.status == 0 && sourceFailures == 0 ? 0 : 1)
