import Foundation
@preconcurrency import Metal
import simd

/// 建造模式格子的 Metal pass。
///
/// 刻意与 `ResidentPropRenderer` 同构（同样的 render 签名、同样的深度约定、同样返回
/// "是否写入了深度"），这样它可以插在同一个帧循环里，并复用 splat 场景的**同一个深度纹理**
/// —— 格子因此会被墙和家具正确遮挡，不需要任何额外工作。
///
/// 与 `ResidentPropRenderer` 的一处关键差别：**格子只做深度测试，不写深度**。
/// 它是视觉提示，不应该把后面画的物件或角色挡掉。
@MainActor final class PropSupportGridRenderer {
    /// 与 `PropSupportGrid.metal` 的 `PropSupportGridInstance` 逐字段对应。
    private struct GPUInstance {
        var centerSize: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private struct Uniforms {
        var viewProjection: simd_float4x4
    }

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private var pipeline: MTLRenderPipelineState?
    private var forwardDepthState: MTLDepthStencilState?
    private var reversedDepthState: MTLDepthStencilState?
    private var instanceBuffer: MTLBuffer?
    private var instanceCapacity = 0
    private(set) var lastInstanceCount = 0

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
    }

    /// 返回是否绘制了任何格子。签名与 `ResidentPropRenderer.render` 对齐，
    /// 便于在同一帧里按相同方式串联。
    @discardableResult
    func render(
        commandBuffer: MTLCommandBuffer,
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        viewProjection: simd_float4x4,
        reversedDepth: Bool,
        preservesDepth: Bool,
        instances: [PropSupportGridPresentation.Instance]
    ) -> Bool {
        lastInstanceCount = 0
        guard !instances.isEmpty,
              let pipeline = pipelineState(),
              let depthState = depthStencilState(reversedDepth: reversedDepth),
              let buffer = instanceBuffer(for: instances)
        else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = preservesDepth ? .load : .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = reversedDepth ? 0 : 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Build-mode prop support grid"

        var uniforms = Uniforms(viewProjection: viewProjection)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: instances.count)
        encoder.endEncoding()
        lastInstanceCount = instances.count
        return true
    }

    /// 格子实例 → GPU 布局。颜色由呈现层给出的状态决定（`CellState.tint`），
    /// 距离淡出已经体现在 `alpha` 里，这里只做相乘。
    private func instanceBuffer(for instances: [PropSupportGridPresentation.Instance]) -> MTLBuffer? {
        var gpu = instances.map { instance -> GPUInstance in
            let tint = instance.state.tint
            return GPUInstance(
                centerSize: SIMD4(instance.center.x, instance.center.y, instance.center.z, instance.size),
                color: SIMD4(tint.x, tint.y, tint.z, tint.w * instance.alpha)
            )
        }
        let length = MemoryLayout<GPUInstance>.stride * gpu.count
        guard length > 0 else { return nil }

        if let buffer = instanceBuffer, instanceCapacity >= length {
            memcpy(buffer.contents(), &gpu, length)
            return buffer
        }
        // 缓冲按 2 的幂增长，避免每帧重建；上限由调用方按距离裁剪控制，
        // 这里不做任何"拒绝绘制"的判断。
        let capacity = max(length, max(instanceCapacity * 2, 4096))
        guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
        memcpy(buffer.contents(), &gpu, length)
        instanceBuffer = buffer
        instanceCapacity = capacity
        return buffer
    }

    private func pipelineState() -> MTLRenderPipelineState? {
        if let pipeline { return pipeline }
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "propSupportGridVertex"),
              let fragmentFunction = library.makeFunction(name: "propSupportGridFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Prop support grid"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat

        // 距离淡出需要 alpha 混合。
        let attachment = descriptor.colorAttachments[0]
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .sourceAlpha
        attachment?.sourceAlphaBlendFactor = .sourceAlpha
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let created = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipeline = created
        return created
    }

    private func depthStencilState(reversedDepth: Bool) -> MTLDepthStencilState? {
        if reversedDepth, let reversedDepthState { return reversedDepthState }
        if !reversedDepth, let forwardDepthState { return forwardDepthState }

        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = reversedDepth ? .greater : .less
        // 只测试、不写入：格子不应该遮挡它之后绘制的任何东西。
        descriptor.isDepthWriteEnabled = false
        guard let created = device.makeDepthStencilState(descriptor: descriptor) else { return nil }
        if reversedDepth { reversedDepthState = created } else { forwardDepthState = created }
        return created
    }
}
