@preconcurrency import MetalKit

enum OrbRendererError: Error {
    case missingCommandQueue
    case missingShaderLibrary
    case missingShaderFunction(String)
}

@MainActor
final class OrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var state: DJState = .idle
    private weak var view: MTKView?

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw OrbRendererError.missingCommandQueue
        }
        guard let library = device.makeDefaultLibrary() else {
            throw OrbRendererError.missingShaderLibrary
        }
        guard let vertexFunction = library.makeFunction(name: "orbVertex") else {
            throw OrbRendererError.missingShaderFunction("orbVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "orbFragment") else {
            throw OrbRendererError.missingShaderFunction("orbFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "gmgn radio orb"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        let attachment = descriptor.colorAttachments[0]
        attachment?.isBlendingEnabled = true
        attachment?.sourceRGBBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.commandQueue = commandQueue
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        startedAt = clock.now
        super.init()
    }

    func attach(to view: MTKView) {
        self.view = view
        view.delegate = self
        updatePreferredFramesPerSecond()
    }

    func setState(_ state: DJState) {
        self.state = state
        updatePreferredFramesPerSecond()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor
            )
        else {
            return
        }

        var uniforms = OrbUniforms.forState(state)
        uniforms.resolution = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )
        uniforms.time = elapsedSeconds

        encoder.label = "gmgn radio orb encoder"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<OrbUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private var elapsedSeconds: Float {
        let duration = startedAt.duration(to: clock.now)
        let components = duration.components
        return Float(
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }

    private func updatePreferredFramesPerSecond() {
        guard let view else {
            return
        }
        let screenMaximumFPS = view.window?.screen?.maximumFramesPerSecond ?? 60
        view.preferredFramesPerSecond = OrbUniforms.preferredFramesPerSecond(
            for: state,
            screenMaximumFPS: screenMaximumFPS
        )
        view.isPaused = state == .dormant
        if state != .dormant {
            view.setNeedsDisplay(view.bounds)
        }
    }
}
