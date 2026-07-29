@preconcurrency import MetalKit

enum StageRendererError: Error {
    case missingCommandQueue
    case missingShaderLibrary
    case missingShaderFunction(String)
    case missingVertexBuffer
    case missingDepthState
}

@MainActor
final class StageRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let vertexCount: Int
    private let audioFeatures: VisualAudioFeatureStore
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var previousFrameAt: ContinuousClock.Instant
    private var camera = StageCameraModel()

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        audioFeatures: VisualAudioFeatureStore
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw StageRendererError.missingCommandQueue
        }
        guard let library = device.makeDefaultLibrary() else {
            throw StageRendererError.missingShaderLibrary
        }

        backgroundPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexFunction: "stageBackgroundVertex",
            fragmentFunction: "stageBackgroundFragment",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: .invalid,
            blending: false
        )
        particlePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexFunction: "stageParticleVertex",
            fragmentFunction: "stageParticleFragment",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            blending: true
        )

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(
            descriptor: depthDescriptor
        ) else {
            throw StageRendererError.missingDepthState
        }

        let geometry = StageParticleGeometry.djTotem(seed: 0x474D474E)
        let buffer = geometry.vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil as MTLBuffer?
            }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        guard let buffer else {
            throw StageRendererError.missingVertexBuffer
        }
        buffer.label = "gmgn radio DJ particle geometry"

        self.commandQueue = commandQueue
        self.depthState = depthState
        vertexBuffer = buffer
        vertexCount = geometry.vertices.count
        self.audioFeatures = audioFeatures
        startedAt = clock.now
        previousFrameAt = startedAt
        super.init()
    }

    func beginDrag() {
        camera.beginDrag()
    }

    func drag(deltaX: Float, deltaY: Float) {
        camera.drag(deltaX: deltaX, deltaY: deltaY)
    }

    func endDrag() {
        camera.endDrag()
    }

    func resetCamera() {
        camera = StageCameraModel()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = clock.now
        let deltaTime = Self.seconds(previousFrameAt.duration(to: now))
        previousFrameAt = now
        camera.step(deltaTime: deltaTime)

        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else {
            return
        }

        var uniforms = StageUniforms.make(
            camera: camera.frame,
            audio: audioFeatures.current,
            time: Self.seconds(startedAt.duration(to: now)),
            viewport: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)
            )
        )

        encoder.label = "gmgn radio 360 stage"
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<StageUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )

        encoder.setRenderPipelineState(particlePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<StageUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: vertexCount
        )
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        blending: Bool
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexFunction) else {
            throw StageRendererError.missingShaderFunction(vertexFunction)
        }
        guard let fragment = library.makeFunction(name: fragmentFunction) else {
            throw StageRendererError.missingShaderFunction(fragmentFunction)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "gmgn radio \(fragmentFunction)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        if blending, let attachment = descriptor.colorAttachments[0] {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func seconds(_ duration: Duration) -> Float {
        let components = duration.components
        return Float(
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}

