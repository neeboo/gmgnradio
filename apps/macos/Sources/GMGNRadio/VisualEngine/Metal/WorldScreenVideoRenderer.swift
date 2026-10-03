import Foundation
@preconcurrency import Metal
import os
import simd

// MARK: - 把原生视频帧**真的画进 3D 场景**的那一个 pass

/// `WorldScreenNativeVideoRegistry` → 场景像素的唯一消费者。
///
/// 之前这份注册表登记了 provider，但 `MarbleSpatialView` 从没读过它：解码统计在涨，
/// 屏幕上却没有画面。这个类补上的正是"最后一步"：把每台电视的**世界四角**与
/// **解码出来的 `MTLTexture`** 画进与房间/道具/角色**共用**的 color + depth 里。
///
/// ## 深度遮挡是双向的
///
/// - **测试**：房间 GLB 遮挡网格 / 已摆放道具 / 更近的电视先把深度写进去，电视被挡；
/// - **写入**：电视自己写深度，于是它身后的角色与道具被电视挡住
///   （`drawAvatar` 的 `hasPreparedOccluder` 链接手）。
///
/// 深度约定与 `marbleOccluderVertex` 逐字同式：SceneKit 反向深度（PMX 角色那一档）
/// 用 `.greater` + `z = w - z`，否则 `.less`。两者共用同一张深度缓冲，不能各写各的。
///
/// ## 为什么 shader 在运行时按源码编译
///
/// 生产的 `.metal` 文件（`Shaders/WorldScreenVideo.metal`）会被编进 app 的默认
/// metallib；但 `tools/probe-screen-video-render.swift` 是把这份 Swift 源码原样
/// 用 `swiftc` 编起来跑的，拿不到 app bundle 的默认库。所以这里同时提供
/// `init?(device:colorFormat:depthFormat:library:)`：探针把**同一个 `.metal` 文件**
/// 的源码用 `makeLibrary(source:)` 编出来传进去。生产与判据因此编的是同一份 shader。
@MainActor
final class WorldScreenVideoRenderer {
    /// 一帧里实际提交了多少电视、每台过了多少深度测试的片元。E2E / 诊断只读。
    ///
    /// `drawPasses` / `encodedQuads` 证明"渲染器真的消费了注册表并编码了视频纹理"；
    /// `fragments` 是 GPU **视野计数**（visible fragment count），证明四边形真的通过了
    /// 深度测试、有像素被写进 drawable —— 不是"解码器解出了帧"。
    struct Stats: Equatable, Sendable {
        /// 至少编码了一台电视的渲染 pass 数。
        var drawPasses = 0
        /// 累计编码的电视四边形数（含被深度测试挡掉的那些）。
        var encodedQuads = 0
        /// 累计通过深度测试的片元数（可见性查询）。
        var fragments: UInt64 = 0
        /// 登记了但这一帧还没有纹理 / 还没出画的屏幕数（不许画黑矩形）。
        var skippedNotReady = 0
        /// 最近一帧画了哪些物件。
        var lastObjectIDs: [String] = []
        /// 最近一帧第一台电视的纹理尺寸。
        var lastPixelWidth = 0
        var lastPixelHeight = 0
    }

    /// 一个 pass 里最多几台电视（与 `WorldScreenOverlayController.maximumSimultaneousScreens`
    /// 同一量级；多出来的这一帧不画，下一帧继续）。
    static let maximumScreens = 8

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "WorldScreenVideoRenderer"
    )

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let forwardDepthState: MTLDepthStencilState
    private let reverseDepthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    /// 可见性查询缓冲（每个 pass 一张，帧间轮转）。空 = 设备不支持，只少了 `fragments` 证据。
    private let visibilityBuffers: [MTLBuffer]
    private let visibilitySlotStride = MemoryLayout<UInt64>.stride
    private var visibilityIndex = 0

    private(set) var stats = Stats()

    /// 生产入口：用 app 默认 metallib 里的 `worldScreenVideo*`。
    convenience init?(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else {
            Self.log.error("默认 Metal 库不可用，电视视频 pass 关闭")
            return nil
        }
        self.init(
            device: device, colorFormat: colorFormat, depthFormat: depthFormat, library: library
        )
    }

    init?(
        device: MTLDevice,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        library: MTLLibrary
    ) {
        guard let vertexFunction = library.makeFunction(name: "worldScreenVideoVertex"),
              let fragmentFunction = library.makeFunction(name: "worldScreenVideoFragment")
        else {
            Self.log.error("WorldScreenVideo.metal 里的函数找不到，电视视频 pass 关闭")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "gmgn radio world screen video"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            Self.log.error("电视视频管线建不起来，电视视频 pass 关闭")
            return nil
        }
        func makeDepth(_ compare: MTLCompareFunction) -> MTLDepthStencilState? {
            let state = MTLDepthStencilDescriptor()
            state.depthCompareFunction = compare
            // **写深度**：电视身后的角色与道具必须被它挡住。
            state.isDepthWriteEnabled = true
            return device.makeDepthStencilState(descriptor: state)
        }
        guard let forward = makeDepth(.less), let reverse = makeDepth(.greater) else {
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "gmgn radio world screen video sampler"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        // 4 张轮转，配合 `MarbleSpatialRenderer.inFlightSemaphore(value: 2)`：读回的那一张
        // 绝不会被还在编码的帧重写。
        var buffers: [MTLBuffer] = []
        for index in 0..<4 {
            let length = Self.maximumScreens * MemoryLayout<UInt64>.stride
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                buffers = []
                break
            }
            buffer.label = "gmgn radio screen video visibility \(index)"
            buffers.append(buffer)
        }
        self.device = device
        self.pipeline = pipeline
        self.forwardDepthState = forward
        self.reverseDepthState = reverse
        self.sampler = sampler
        self.visibilityBuffers = buffers
    }

    /// 画这一帧的电视。没有可画的（没登记 / 都没出画）时返回 `false`，一个 pass 都不加。
    ///
    /// `preservesDepth` 与 `MarbleSpatialDepthPolicy` 同义：前序 pass（房间 / 道具 / 角色
    /// 之前的那一段）已经写过同一约定的深度时用 `.load`；否则 `.clear` 到本约定的远端，
    /// 免得拿一张上面残留着别的约定的深度做测试。
    @discardableResult
    func render(
        commandBuffer: MTLCommandBuffer,
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        viewProjection: simd_float4x4,
        reversedDepth: Bool,
        preservesDepth: Bool,
        frames: [WorldScreenNativeVideoRegistry.Frame]
    ) -> Bool {
        var drawable: [(frame: WorldScreenNativeVideoRegistry.Frame, texture: MTLTexture)] = []
        for frame in frames {
            guard frame.isReady, frame.quad.count == 4, let texture = frame.texture else {
                stats.skippedNotReady += 1
                continue
            }
            drawable.append((frame, texture))
            if drawable.count >= Self.maximumScreens { break }
        }
        guard !drawable.isEmpty else { return false }

        // 顶点固定 4 个四角（BL, BR, TR, TL）。uv 与生产 `WorldScreenQuad.corners` 同序：
        // 角点系列从**左下**起逆时针，纹理左上为 (0,0)，所以 BL→(0,1)、TL→(0,0)。
        let texcoords: [SIMD2<Float>] = [
            SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0),
        ]
        var uniforms = WorldScreenVideoUniforms(
            viewProjection: viewProjection,
            depthConvention: SIMD4<Float>(reversedDepth ? 1 : 0, 0, 0, 0)
        )

        let queryBuffer: MTLBuffer? = visibilityBuffers.isEmpty
            ? nil
            : visibilityBuffers[visibilityIndex]
        if !visibilityBuffers.isEmpty {
            visibilityIndex = (visibilityIndex + 1) % visibilityBuffers.count
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = preservesDepth ? .load : .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = reversedDepth ? 0 : 1
        if let queryBuffer {
            pass.visibilityResultBuffer = queryBuffer
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.label = "gmgn radio world screen video"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(reversedDepth ? reverseDepthState : forwardDepthState)
        // 正面背面都画：电视的摆放 yaw 由世界状态决定，绕线不该让画面凭空消失。
        encoder.setCullMode(.none)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for (index, entry) in drawable.enumerated() {
            let positions = entry.frame.quad
            positions.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setVertexBytes(base, length: bytes.count, index: 0)
            }
            texcoords.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setVertexBytes(base, length: bytes.count, index: 1)
            }
            withUnsafeBytes(of: &uniforms) { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setVertexBytes(
                    base, length: MemoryLayout<WorldScreenVideoUniforms>.stride, index: 2
                )
            }
            encoder.setFragmentTexture(entry.texture, index: 0)
            if queryBuffer != nil {
                encoder.setVisibilityResultMode(
                    .counting, offset: index * visibilitySlotStride
                )
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        stats.drawPasses += 1
        stats.encodedQuads += drawable.count
        stats.lastObjectIDs = drawable.map(\.frame.objectID)
        stats.lastPixelWidth = drawable[0].texture.width
        stats.lastPixelHeight = drawable[0].texture.height

        if let queryBuffer {
            let readback = VisibilityReadback(buffer: queryBuffer, slots: drawable.count)
            commandBuffer.addCompletedHandler { [weak self] command in
                guard command.status == .completed else { return }
                let fragments = readback.total()
                guard fragments > 0 else { return }
                Task { @MainActor [weak self] in
                    self?.stats.fragments += fragments
                }
            }
        }
        return true
    }
}

/// GPU 可见性读回需要跨 `@Sendable` 的完成回调带一张 `MTLBuffer`；缓冲的生命周期由
/// `WorldScreenVideoRenderer` 的 4 张轮转 owning，回调只读，不共享可变状态。
private final class VisibilityReadback: @unchecked Sendable {
    private let buffer: MTLBuffer
    private let slots: Int

    init(buffer: MTLBuffer, slots: Int) {
        self.buffer = buffer
        self.slots = slots
    }

    func total() -> UInt64 {
        guard slots > 0 else { return 0 }
        let contents = buffer.contents().bindMemory(to: UInt64.self, capacity: slots)
        var sum: UInt64 = 0
        for index in 0..<slots {
            sum += contents[index]
        }
        return sum
    }
}

/// 顶点 uniform 的内存布局必须与 `WorldScreenVideo.metal` 的 `WorldScreenVideoUniforms`
/// 逐字一致：`float4x4`（64 字节）+ `float4`（16 字节）。
struct WorldScreenVideoUniforms {
    var viewProjection: simd_float4x4
    var depthConvention: SIMD4<Float>
}
