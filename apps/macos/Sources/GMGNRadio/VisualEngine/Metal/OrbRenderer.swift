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
    private let audioFeatures: VisualAudioFeatureStore
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var state: DJState = .idle
    private var voiceLevel: Float = 0
    private var appearance: OrbAppearance
    private var motionModel = OrbMotionModel(
        initial: .idle,
        seed: 0x474D474E,
        time: 0
    )
    private weak var view: MTKView?

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        audioFeatures: VisualAudioFeatureStore,
        appearance: OrbAppearance
    ) throws {
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
        self.audioFeatures = audioFeatures
        self.appearance = appearance
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
        motionModel.transition(
            to: state,
            at: elapsedSeconds,
            audio: audioFeatures.current
        )
        updatePreferredFramesPerSecond()
    }

    func setVoiceLevel(_ level: Float) {
        voiceLevel = min(max(level, 0), 1)
    }

    func setAppearance(_ appearance: OrbAppearance) {
        self.appearance = appearance
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

        let time = elapsedSeconds
        let audio = resolvedAudioFeatures
        let motion = motionModel.frame(at: time, audio: audio)
        var uniforms = OrbUniforms.forState(state)
        uniforms.resolution = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )
        uniforms.time = time
        uniforms.energy = motion.energy
        uniforms.deformation = motion.deformation
        uniforms.glow = motion.glow
        uniforms.particleAmount = motion.particleAmount
        uniforms.hue = motion.hue
        uniforms.opacity = motion.opacity
        uniforms.audioLow = audio.low
        uniforms.audioMid = audio.mid
        uniforms.audioHigh = audio.high
        uniforms.scale = motion.scale
        uniforms.listeningRing = motion.listeningRing
        uniforms.accentColor = appearance.metalColor
        uniforms.flowIntensity = appearance.flowIntensity

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

    private var resolvedAudioFeatures: VisualAudioFeatures {
        guard state == .listening || state == .speaking else {
            return audioFeatures.current
        }
        return VisualAudioFeatures(
            low: voiceLevel,
            mid: voiceLevel,
            high: voiceLevel * 0.72,
            amplitude: voiceLevel
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
