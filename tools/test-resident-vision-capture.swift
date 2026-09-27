// Hostless offline checks for the resident vision capture pipeline.
// Compiles and RUNS the shipping production sources (ResidentVisionCapture.swift
// plus ResidentVisionTools.swift argument policy) with an injected fake frame
// surface — no GPU, no App, no desktop capture.
//
// Run:  swift tools/test-resident-vision-capture.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let captureSource = sources.appendingPathComponent("Presence/ResidentVisionCapture.swift")
let toolsSource = sources.appendingPathComponent("Agent/ResidentVisionTools.swift")
guard FileManager.default.fileExists(atPath: captureSource.path),
      FileManager.default.fileExists(atPath: toolsSource.path) else {
    print("FAIL: production vision sources missing")
    exit(1)
}

let harness = #"""
import Foundation
import CoreGraphics
import ImageIO

// MARK: - 结果计数

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value {
        failures += 1
        print("FAIL: \(message)")
    }
}

// MARK: - 可注入的假帧源:测试跑的是生产 ResidentVisionCaptureService/门控逻辑

@MainActor
final class FakeVisionSurface: ResidentVisionSurface {
    enum Behavior {
        case valid
        case emptyPixels
        case zeroSize
        case wrongWorld(String)
        case oldFrame
        case agedFrame
        case noise(width: Int, height: Int)
        case explicit(ResidentVisionSurfaceFrameResult)
        case hang
    }
    var behavior: Behavior
    var requestedAt: Date?
    init(_ behavior: Behavior = .valid) { self.behavior = behavior }

    func captureCurrentObservation(
        request: ResidentVisionCaptureRequest,
        requestedAt: Date
    ) async -> ResidentVisionSurfaceFrameResult {
        self.requestedAt = requestedAt
        switch behavior {
        case .valid:
            return .frame(makeFrame(requestedAt: requestedAt, worldID: request.worldID))
        case .emptyPixels:
            return .frame(makeFrame(requestedAt: requestedAt, worldID: request.worldID, empty: true))
        case .zeroSize:
            return .frame(ResidentVisionRenderedFrame(
                pixelsBGRA: Data(repeating: 0x80, count: 16), width: 0, height: 0,
                bytesPerRow: 16,
                stamp: makeStamp(requestedAt: requestedAt, worldID: request.worldID)))
        case let .wrongWorld(world):
            return .frame(makeFrame(requestedAt: requestedAt, worldID: world))
        case .oldFrame:
            return .frame(makeFrame(
                requestedAt: requestedAt, worldID: request.worldID,
                capturedAt: requestedAt.addingTimeInterval(-60)))
        case .agedFrame:
            return .frame(makeFrame(
                requestedAt: requestedAt, worldID: request.worldID,
                capturedAt: requestedAt.addingTimeInterval(-10)))
        case let .noise(width, height):
            let bytesPerRow = width * 4
            var noise = Data(repeating: 0, count: bytesPerRow * height)
            var seed: UInt64 = 0x9E3779B97F4A7C15
            noise.withUnsafeMutableBytes { raw in
                let buffer = raw.bindMemory(to: UInt8.self)
                for index in 0..<buffer.count {
                    seed = seed &* 6364136223846793005
                        &+ 1442695040888963407
                    buffer[index] = UInt8(truncatingIfNeeded: seed >> 33)
                }
            }
            let stamp = makeStamp(requestedAt: requestedAt, worldID: request.worldID)
            return .frame(ResidentVisionRenderedFrame(
                pixelsBGRA: noise, width: width, height: height,
                bytesPerRow: bytesPerRow, stamp: stamp))
        case let .explicit(result):
            return result
        case .hang:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return .failure(code: .cancelled, message: "cancelled")
            }
            return .failure(code: .timeout, message: "hang ended")
        }
    }

    func makeStamp(requestedAt: Date, worldID: String, capturedAt: Date? = nil) -> ResidentVisionRenderedStamp {
        ResidentVisionRenderedStamp(
            surfaceProfile: "full_stage_drawable",
            frameIndex: 41,
            capturedAt: capturedAt ?? requestedAt.addingTimeInterval(0.02),
            worldID: worldID,
            residentAvatarID: "resident.pmx",
            residentAvatarFrameRevision: 7,
            residentPosition: [0, 0, 0],
            camera: ResidentVisionCameraStamp(
                label: "test full-stage observer",
                kind: .fullStageObserver,
                position: [0, 1.2, 2], yaw: 0, pitch: 0,
                fieldOfViewDegrees: 66, coordinateSpace: "test"))
    }

    func makeFrame(
        requestedAt: Date, worldID: String, capturedAt: Date? = nil,
        empty: Bool = false
    ) -> ResidentVisionRenderedFrame {
        let width = 4, height = 4, bytesPerRow = 16
        let pixels = empty ? Data() : Data(repeating: 0x80, count: bytesPerRow * height)
        return ResidentVisionRenderedFrame(
            pixelsBGRA: pixels, width: width, height: height, bytesPerRow: bytesPerRow,
            stamp: makeStamp(requestedAt: requestedAt, worldID: worldID, capturedAt: capturedAt))
    }
}

func makeRequest(
    sessionID: UUID = UUID(),
    worldID: String = "world.marble-living-cabin",
    expectedWorldRevision: UInt64? = nil,
    timeout: TimeInterval = 1,
    includeFileURL: Bool = true
) -> ResidentVisionCaptureRequest {
    ResidentVisionCaptureRequest(
        sessionID: sessionID, worldID: worldID,
        expectedWorldRevision: expectedWorldRevision,
        timeout: timeout, includeFileURL: includeFileURL)
}

@MainActor
func runService(
    surface: (any ResidentVisionSurface)?,
    fileRoot: URL?,
    context: ResidentVisionGate.ContextSnapshot?,
    request: ResidentVisionCaptureRequest,
    pngMaximumBytes: Int = ResidentVisionImagePolicy.maximumPNGBytes
) async -> ResidentVisionCaptureOutcome {
    let service = ResidentVisionCaptureService(
        surface: surface, fileRoot: fileRoot,
        context: { context }, now: { Date() },
        pngMaximumBytes: pngMaximumBytes)
    return await service.capture(request)
}

// MARK: - 目录只登记真实可捕获的视角

@MainActor
func testCatalog() {
    let ids = ResidentVisionCatalog.registeredIDs
    check(ids == ["current_observation"], "目录只登记已实现的 current_observation,实际 \(ids)")
    check(!ResidentVisionCatalog.isRegistered(
        ResidentVisionUnregisteredPerspective.globalOverview),
        "global_overview 不得登记为可用")
    check(!ResidentVisionCatalog.isRegistered(
        ResidentVisionUnregisteredPerspective.residentEye),
        "resident_eye 不得登记为可用")
    let capability = ResidentVisionCatalog.capability(for: .currentObservation)
    check(!capability.requiresOffscreenCamera, "current_observation 是共享观察相机,不是离屏相机")
    check(capability.showsResidentAvatarWhenPresent, "观察画面在场时可看到居民角色自身")
    check(capability.showsSpace, "观察画面呈现空间环境")
}

// MARK: - PNG 编码走生产路径(真实 ImageIO 编解码)

@MainActor
func testPNGEncode() {
    let width = 4, height = 4, bytesPerRow = 16
    var pixels = Data()
    for y in 0..<height {
        for x in 0..<width {
            pixels.append(UInt8((x * 60) & 0xFF)) // B
            pixels.append(UInt8((y * 60) & 0xFF)) // G
            pixels.append(UInt8(0x80))            // R
            pixels.append(0xFF)                   // A
        }
    }
    do {
        let png = try ResidentVisionPNG.encode(
            bgra8Pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
        check(ResidentVisionPNG.looksPlausible(png), "PNG 头与最小尺寸有效")
        let decoded = ResidentVisionPNG.decodedDimensions(png)
        check(decoded?.width == width && decoded?.height == height,
              "PNG 可被 ImageIO 解码且尺寸正确,实际 \(String(describing: decoded))")
    } catch {
        check(false, "PNG 编码失败 \(error)")
    }
}

// MARK: - 新鲜度门控(生产逻辑)

@MainActor
func testGate() {
    let request = makeRequest()
    let requestedAt = Date()
    let frame = FakeVisionSurface().makeFrame(requestedAt: requestedAt, worldID: request.worldID)

    let wrongWorldFrame = FakeVisionSurface().makeFrame(
        requestedAt: requestedAt, worldID: "world.other")
    check(isReject(ResidentVisionGate.verdict(
        request: request, requestedAt: requestedAt,
        frame: wrongWorldFrame, context: nil, now: Date()), code: .staleWorld),
        "画面世界与请求世界不符 → stale_world")

    let oldFrame = FakeVisionSurface().makeFrame(
        requestedAt: requestedAt, worldID: request.worldID,
        capturedAt: requestedAt.addingTimeInterval(-60))
    check(isReject(ResidentVisionGate.verdict(
        request: request, requestedAt: requestedAt,
        frame: oldFrame, context: nil, now: Date()), code: .staleFrame),
        "画面早于请求 → stale_frame")

    let agedFrame = FakeVisionSurface().makeFrame(
        requestedAt: requestedAt, worldID: request.worldID,
        capturedAt: Date().addingTimeInterval(-10))
    check(isReject(ResidentVisionGate.verdict(
        request: request, requestedAt: requestedAt,
        frame: agedFrame, context: nil, now: Date()), code: .staleFrame),
        "超过最大时限 → stale_frame")

    let emptyFrame = FakeVisionSurface().makeFrame(
        requestedAt: requestedAt, worldID: request.worldID, empty: true)
    check(isReject(ResidentVisionGate.verdict(
        request: request, requestedAt: requestedAt,
        frame: emptyFrame, context: nil, now: Date()), code: .noPicture),
        "空画面 → no_picture")

    let switchedContext = ResidentVisionGate.ContextSnapshot(
        worldID: "world.other", worldRevision: 3)
    check(isReject(ResidentVisionGate.verdict(
        request: request, requestedAt: requestedAt,
        frame: frame, context: switchedContext, now: Date()), code: .staleWorld),
        "上下文空间已切换 → stale_world")

    let resetContext = ResidentVisionGate.ContextSnapshot(
        worldID: request.worldID, worldRevision: 3)
    let resetRequest = makeRequest(expectedWorldRevision: 10)
    check(isReject(ResidentVisionGate.verdict(
        request: resetRequest, requestedAt: requestedAt,
        frame: frame, context: resetContext, now: Date()), code: .staleFrame),
        "世界重载后画面旧于期望状态 → stale_frame")

    let acceptVerdict = ResidentVisionGate.verdict(
        request: request, requestedAt: requestedAt,
        frame: frame,
        context: ResidentVisionGate.ContextSnapshot(
            worldID: request.worldID, worldRevision: 5),
        now: Date())
    check(acceptVerdict == .accept, "同世界新画面 → accept")
}

@MainActor
func isReject(_ verdict: ResidentVisionGate.Verdict, code: ResidentVisionErrorCode) -> Bool {
    if case let .reject(rejectCode, _) = verdict { return rejectCode == code }
    return false
}

@MainActor
func failureCode(_ outcome: ResidentVisionCaptureOutcome) -> ResidentVisionErrorCode? {
    if case let .failure(code, _) = outcome { return code }
    return nil
}

// MARK: - 服务成功路径

@MainActor
func testServiceSuccess() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-success-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let surface = FakeVisionSurface()
    let outcome = await runService(
        surface: surface, fileRoot: root,
        context: ResidentVisionGate.ContextSnapshot(
            worldID: "world.marble-living-cabin", worldRevision: 9),
        request: makeRequest(sessionID: sessionID))
    guard case let .success(image) = outcome else {
        check(false, "合法请求应成功")
        return
    }
    check(ResidentVisionPNG.looksPlausible(image.pngData), "返回真实 PNG")
    let dims = ResidentVisionPNG.decodedDimensions(image.pngData)
    check(dims?.width == 4 && dims?.height == 4, "PNG 尺寸与帧一致")
    check(image.metadata.worldID == "world.marble-living-cabin", "元数据 worldID")
    check(image.metadata.camera.kind == .fullStageObserver, "元数据 camera.kind")
    check(image.metadata.perspective == .currentObservation, "元数据 perspective")
    check(image.metadata.residentAvatarID == "resident.pmx", "元数据含居民角色 ID")
    check(image.metadata.capturedAt >= surface.requestedAt ?? .distantPast,
          "捕获时间不早于请求时间")
    check(image.metadata.frameIndex == 41, "帧号透传")
    check(image.metadata.width == 4 && image.metadata.height == 4, "帧尺寸")
    check(image.metadata.expectedWorldRevision == nil,
          "未提供期望 revision 时,元数据不得回显/伪造任何 world revision")
    guard let fileURL = image.fileURL else {
        check(false, "includeFileURL 应返回会话私有文件 URL")
        return
    }
    check(ResidentVisionFilePolicy.isScoped(fileURL, root: root), "文件位于会话根内")
    check(fileURL.path.contains(sessionID.uuidString), "文件位于会话子目录")
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(permissions & 0o077 == 0,
              "画面文件应仅属主可读写,实际权限 \(String(permissions, radix: 8))")
        let data = try Data(contentsOf: fileURL)
        check(data == image.pngData, "磁盘文件与返回 PNG 一致")
    } catch {
        check(false, "文件属性/内容检查失败 \(error)")
    }
}

// MARK: - 服务失败路径(旧空间/旧帧/无画面/超时/不可用)

@MainActor
func testServiceFailures() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-failures-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let noSurface = await runService(
        surface: nil, fileRoot: root, context: nil,
        request: makeRequest())
    check(failureCode(noSurface) == .captureUnavailable,
          "无渲染画面源 → capture_unavailable")

    let wrongSurface = FakeVisionSurface(.wrongWorld("world.other"))
    let wrongOutcome = await runService(
        surface: wrongSurface, fileRoot: root, context: nil,
        request: makeRequest())
    check(failureCode(wrongOutcome) == .staleWorld, "旧空间 → stale_world")

    let switched = await runService(
        surface: FakeVisionSurface(), fileRoot: root,
        context: ResidentVisionGate.ContextSnapshot(
            worldID: "world.other", worldRevision: 3),
        request: makeRequest())
    check(failureCode(switched) == .staleWorld, "捕获中空间切走 → stale_world")

    let oldSurface = FakeVisionSurface(.oldFrame)
    let oldOutcome = await runService(
        surface: oldSurface, fileRoot: root, context: nil,
        request: makeRequest())
    check(failureCode(oldOutcome) == .staleFrame, "旧帧 → stale_frame")

    let agedSurface = FakeVisionSurface(.agedFrame)
    let agedOutcome = await runService(
        surface: agedSurface, fileRoot: root, context: nil,
        request: makeRequest())
    check(failureCode(agedOutcome) == .staleFrame, "超过时限的画面 → stale_frame")

    let emptySurface = FakeVisionSurface(.emptyPixels)
    let emptyOutcome = await runService(
        surface: emptySurface, fileRoot: root, context: nil,
        request: makeRequest())
    check(failureCode(emptyOutcome) == .noPicture, "空画面 → no_picture")

    let explicitSurface = FakeVisionSurface(
        .explicit(.failure(code: .noPicture, message: "无可见画面")))
    let explicitOutcome = await runService(
        surface: explicitSurface, fileRoot: root, context: nil,
        request: makeRequest())
    check(failureCode(explicitOutcome) == .noPicture, "帧源失败原样透传")

    let hangOutcome = await runService(
        surface: FakeVisionSurface(.hang), fileRoot: root, context: nil,
        request: makeRequest(timeout: 0.6))
    check(failureCode(hangOutcome) == .timeout, "帧源挂起 → timeout")
}

// MARK: - 文件策略(会话作用域,工具无路径参数)

@MainActor
func testFilePolicy() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-files-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let sessionID = UUID()
        let png = try ResidentVisionPNG.encode(
            bgra8Pixels: Data(repeating: 0x80, count: 16 * 4),
            width: 4, height: 4, bytesPerRow: 16)
        let url = try ResidentVisionFilePolicy.write(
            pngData: png, root: root, sessionID: sessionID, captureID: UUID())
        check(ResidentVisionFilePolicy.isScoped(url, root: root), "写入位置受会话作用域约束")
        let outside = root.appendingPathComponent("elsewhere/\(UUID()).png")
        check(!ResidentVisionFilePolicy.isScoped(outside, root: root), "作用域外路径被拒绝")
        try ResidentVisionFilePolicy.purgeSessionDirectory(root: root, sessionID: sessionID)
        check(!FileManager.default.fileExists(atPath: url.path), "会话目录可清理")
    } catch {
        check(false, "文件策略测试抛错 \(error)")
    }
}

// MARK: - 单飞闸门代次匹配(生产代码;A 取消 → B 开始 → A 迟到回调不能碰 B)

@MainActor
func testSingleFlightGeneration() {
    let flight = ResidentVisionSingleFlight()

    // A 登记。
    let a = UUID()
    check(flight.begin(captureID: a), "空闲时 A 登记成功")
    check(flight.isCurrent(a), "A 是当前请求")
    check(!flight.isIdle, "A 未结束时闸门不空闲")

    // A 未结束时 B 登记被拒(忙)。
    let b = UUID()
    check(!flight.begin(captureID: b), "A 未结束时 B 登记被拒")

    // A 被取消(finish)→ 闸门释放。
    check(flight.finish(a), "A 取消结束当前请求")
    check(flight.isIdle, "A 结束后闸门空闲")
    check(!flight.finish(a), "A 已结束,重复取消无效")

    // B 开始。
    check(flight.begin(captureID: b), "A 取消后 B 登记成功")
    check(flight.isCurrent(b), "B 成为当前请求")
    check(!flight.isCurrent(a), "A 不再是当前请求")

    // A 的旧 GPU 完成迟到 → 不能结束/触碰 B。
    check(!flight.finish(a), "A 旧 GPU 完成迟到:不得结束 B")
    // A 的旧取消任务迟到 → 同样不能结束 B。
    check(!flight.finish(a), "A 旧取消任务迟到:不得结束 B")
    check(flight.isCurrent(b), "两次 A 迟到回调后 B 仍进行中")

    // B 正常结束。
    check(flight.finish(b), "B 结束成功")
    check(flight.isIdle, "B 结束后闸门空闲")
    check(!flight.finish(b), "B 已结束,重复结束无效")
    check(!flight.finish(a), "空闲后过期 A 仍无效")
}

@MainActor
func testSingleFlightFinishOnlyCurrent() {
    let flight = ResidentVisionSingleFlight()
    let x = UUID()
    let y = UUID()
    check(flight.finish(x) == false, "空闲时 finish 不生效")
    check(flight.begin(captureID: x), "x 登记")
    check(flight.finish(y) == false, "用别的 captureID 不能结束 x")
    check(flight.isCurrent(x), "x 不受影响")
    // 同一请求的两个迟到回调竞争:只允许一个 finish 生效。
    let wonFirst = flight.finish(x)
    let wonSecond = flight.finish(x)
    check(wonFirst && !wonSecond, "同一请求多个迟到回调只有一个生效")
}

// MARK: - 编码尺寸/字节预算(512 KiB PNG，预留 base64 和元数据空间)

@MainActor
func testBoundedBudgetShrinks() {
    let base64Budget = ((ResidentVisionImagePolicy.maximumPNGBytes + 2) / 3) * 4
    check(base64Budget + 65_536 < 1 << 20,
          "图片编码后加 64 KiB 元数据仍低于 1 MiB 传输预算")
    let width = 256, height = 256, bytesPerRow = width * 4
    var noise = Data(repeating: 0, count: bytesPerRow * height)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    noise.withUnsafeMutableBytes { raw in
        let buffer = raw.bindMemory(to: UInt8.self)
        for index in 0..<buffer.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            buffer[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
    }
    do {
        let bounded = try ResidentVisionPNG.encodeBounded(
            bgra8Pixels: noise, width: width, height: height,
            bytesPerRow: bytesPerRow, maximumBytes: 150_000)
        check(bounded.data.count <= 150_000,
              "超预算 PNG 必须缩到 ≤150_000 字节,实际 \(bounded.data.count)")
        check(bounded.width < width || bounded.height < height,
              "超预算 PNG 必须缩小,实际 \(bounded.width)x\(bounded.height)")
        check(bounded.width == 128 && bounded.height == 128,
              "256 噪声缩半到 128x128,实际 \(bounded.width)x\(bounded.height)")
        check(ResidentVisionPNG.looksPlausible(bounded.data), "缩小后仍是 PNG")
        let dims = ResidentVisionPNG.decodedDimensions(bounded.data)
        check(dims?.width == bounded.width && dims?.height == bounded.height,
              "交付尺寸与可解码尺寸一致")
    } catch {
        check(false, "受预算编码不应失败 \(error)")
    }
    // 小帧在默认预算下不缩小、尺寸不变。
    do {
        let small = try ResidentVisionPNG.encodeBounded(
            bgra8Pixels: Data(repeating: 0x80, count: 16 * 4),
            width: 4, height: 4, bytesPerRow: 16)
        check(small.width == 4 && small.height == 4, "预算内不缩小")
        check(small.data.count <= ResidentVisionImagePolicy.maximumPNGBytes,
              "交付 PNG ≤ 512 KiB 图片预算")
    } catch {
        check(false, "小帧编码失败 \(error)")
    }
}

@MainActor
func testBoundedDimensionCap() {
    // 纯色大宽帧字节很小,但尺寸护栏必须把它缩到 maximumDeliveredEdge 内。
    let width = 8192, height = 64
    let pixels = Data(repeating: 0x40, count: width * 4 * height)
    do {
        let bounded = try ResidentVisionPNG.encodeBounded(
            bgra8Pixels: pixels, width: width, height: height,
            bytesPerRow: width * 4)
        check(bounded.width <= ResidentVisionImagePolicy.maximumDeliveredEdge,
              "超宽帧必须缩到护栏内,实际宽 \(bounded.width)")
        check(bounded.width == ResidentVisionImagePolicy.maximumDeliveredEdge,
              "8192 宽缩半到 4096")
        check(bounded.height == 32, "统一半缩:64 高缩到 32")
        let dims = ResidentVisionPNG.decodedDimensions(bounded.data)
        check(dims?.width == bounded.width && dims?.height == bounded.height,
              "尺寸护栏后的 PNG 可解码且尺寸一致")
    } catch {
        check(false, "尺寸护栏不应失败 \(error)")
    }
}

@MainActor
func testBoundedOverBudgetFailsClearly() {
    let width = 256, height = 256, bytesPerRow = width * 4
    var noise = Data(repeating: 0, count: bytesPerRow * height)
    var seed: UInt64 = 0x123456789ABCDEF
    noise.withUnsafeMutableBytes { raw in
        let buffer = raw.bindMemory(to: UInt8.self)
        for index in 0..<buffer.count {
            seed = seed &* 2862933555777941757 &+ 3037000493
            buffer[index] = UInt8(truncatingIfNeeded: seed >> 32)
        }
    }
    do {
        _ = try ResidentVisionPNG.encodeBounded(
            bgra8Pixels: noise, width: width, height: height,
            bytesPerRow: bytesPerRow, maximumBytes: 1_024)
        check(false, "缩到下限仍超预算必须明确失败")
    } catch ResidentVisionPNG.EncodeError.tooLargeForBudget {
        check(true, "缩到下限仍超预算 → tooLargeForBudget")
    } catch {
        check(false, "错误码不符 \(error)")
    }
}

// MARK: - 服务:预算缩小 / 超限明确失败

@MainActor
func testServiceBudgetShrinkAndOverLimit() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-budget-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 预算缩小:256 噪声帧在 150_000 预算下交付 128x128 PNG。
    let shrink = await runService(
        surface: FakeVisionSurface(.noise(width: 256, height: 256)),
        fileRoot: root, context: nil,
        request: makeRequest(), pngMaximumBytes: 150_000)
    guard case let .success(image) = shrink else {
        check(false, "预算内缩小应成功")
        return
    }
    check(image.pngData.count <= 150_000,
          "服务交付 PNG ≤ 预算,实际 \(image.pngData.count)")
    check(image.metadata.width == 128 && image.metadata.height == 128,
          "元数据记录缩小后的实际交付尺寸")
    let dims = ResidentVisionPNG.decodedDimensions(image.pngData)
    check(dims?.width == image.metadata.width
        && dims?.height == image.metadata.height,
        "PNG 实际尺寸与元数据一致")
    check(image.fileURL != nil, "缩小帧仍落会话私有文件")

    // 超限明确失败:极小预算 + 噪声 → image_too_large,不返回超预算图片。
    let over = await runService(
        surface: FakeVisionSurface(.noise(width: 256, height: 256)),
        fileRoot: root, context: nil,
        request: makeRequest(), pngMaximumBytes: 1_024)
    check(failureCode(over) == .imageTooLarge,
          "缩到下限仍超预算 → image_too_large")
}

// MARK: - 服务:取消竞争与失败恢复(不启动 App/GPU/网络)

@MainActor
func testServiceCancelThenRecover() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-cancel-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A:帧源阻塞,请求在完成前被调用方取消。
    let blocking = FakeVisionSurface(.hang)
    let service = ResidentVisionCaptureService(
        surface: blocking, fileRoot: root,
        context: { nil }, now: { Date() })
    let taskA = Task { await service.capture(makeRequest(timeout: 8)) }
    try? await Task.sleep(for: .milliseconds(200))
    taskA.cancel()
    let outcomeA = await taskA.value
    check(failureCode(outcomeA) == .cancelled,
          "完成前取消 → cancelled(不是 timeout,也不是迟到帧)")

    // B:A 取消后立即在同一服务上请求:必须成功恢复,帧在 B 请求之后新渲染。
    blocking.behavior = .valid
    let outcomeB = await service.capture(makeRequest(timeout: 2))
    guard case let .success(image) = outcomeB else {
        check(false, "取消后 B 请求应恢复成功")
        return
    }
    check(image.metadata.worldID == "world.marble-living-cabin",
          "B 恢复请求返回正确世界画面")
    check(image.metadata.capturedAt >= blocking.requestedAt ?? .distantPast,
          "B 的帧不早于 B 的请求时间(非旧帧)")
}

@MainActor
func testServiceTimeoutThenRecover() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-timeout-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A:帧源挂起 → 服务超时。
    let surface = FakeVisionSurface(.hang)
    let service = ResidentVisionCaptureService(
        surface: surface, fileRoot: root,
        context: { nil }, now: { Date() })
    let timeoutOutcome = await service.capture(makeRequest(timeout: 0.6))
    check(failureCode(timeoutOutcome) == .timeout, "挂起帧源 → timeout")

    // B:同一服务随后立即成功恢复(超时取消没有毒化后续请求)。
    surface.behavior = .valid
    let recovered = await service.capture(makeRequest(timeout: 2))
    check(recovered.isSuccess, "超时后 B 请求应恢复成功")
}

// MARK: - 入口

@main
struct Main {
    @MainActor
    static func main() async {
        testCatalog()
        testPNGEncode()
        testGate()
        await testServiceSuccess()
        await testServiceFailures()
        testFilePolicy()
        testSingleFlightGeneration()
        testSingleFlightFinishOnlyCurrent()
        testBoundedBudgetShrinks()
        testBoundedDimensionCap()
        testBoundedOverBudgetFailsClearly()
        await testServiceBudgetShrinkAndOverLimit()
        await testServiceCancelThenRecover()
        await testServiceTimeoutThenRecover()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident vision capture checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-resident-vision-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("vision-capture")

func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compiled = try run("/usr/bin/swiftc", [
    "-parse-as-library",
    "-framework", "CoreGraphics",
    "-framework", "ImageIO",
    captureSource.path,
    toolsSource.path,
    program.path,
    "-o", executable.path,
])
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
