import AppKit
@preconcurrency import MetalKit

@MainActor
enum ImmersivePresentationPolicy {
    static let windowLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
    )
    static let ignoresMouseEvents = true
}

enum ImmersiveTransitionDirection: Sendable {
    case entering
    case exiting
}

struct ImmersiveTransition: Equatable, Sendable {
    let direction: ImmersiveTransitionDirection
    let startedAt: Float
    let duration: Float

    func progress(at time: Float) -> Float {
        let linear = min(max((time - startedAt) / max(duration, 0.001), 0), 1)
        let smooth = linear * linear * (3 - 2 * linear)
        return direction == .entering ? smooth : 1 - smooth
    }

    func isComplete(at time: Float) -> Bool {
        time >= startedAt + duration
    }
}

enum ImmersiveSceneGeometry {
    static func normalizedOrigin(
        orbCenter: CGPoint,
        screenFrame: CGRect
    ) -> SIMD2<Float> {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return SIMD2<Float>(0.5, 0.5)
        }

        let x = min(max((orbCenter.x - screenFrame.minX) / screenFrame.width, 0), 1)
        let y = min(max((orbCenter.y - screenFrame.minY) / screenFrame.height, 0), 1)
        return SIMD2<Float>(Float(x), Float(y))
    }
}

@MainActor
final class ImmersiveSceneController {
    private let audioFeatures: VisualAudioFeatureStore
    private var window: NSWindow?
    private weak var sourceWindow: NSWindow?
    private var metalView: ImmersiveMetalView?

    init(audioFeatures: VisualAudioFeatureStore) {
        self.audioFeatures = audioFeatures
    }

    var isPresented: Bool {
        window != nil
    }

    func enter(from orbWindow: NSWindow) {
        guard window == nil, let screen = orbWindow.screen ?? NSScreen.main else {
            return
        }

        let origin = ImmersiveSceneGeometry.normalizedOrigin(
            orbCenter: CGPoint(x: orbWindow.frame.midX, y: orbWindow.frame.midY),
            screenFrame: screen.frame
        )
        let metalView = ImmersiveMetalView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            origin: origin,
            audioFeatures: audioFeatures
        )
        metalView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let baselineMode = ProcessInfo.processInfo.environment["GMGN_BASELINE"] == "1"
        window.backgroundColor = baselineMode ? .black : .clear
        window.isOpaque = baselineMode
        window.hasShadow = false
        window.level = ImmersivePresentationPolicy.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = metalView
        window.ignoresMouseEvents = ImmersivePresentationPolicy.ignoresMouseEvents
        window.orderFrontRegardless()

        sourceWindow = orbWindow
        orbWindow.alphaValue = 0
        self.window = window
        self.metalView = metalView
        metalView.beginEntering()
    }

    func exit() {
        guard let metalView else {
            return
        }

        metalView.beginExiting { [weak self] in
            self?.finishExit()
        }
    }

    private func finishExit() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        metalView = nil
        sourceWindow?.alphaValue = 1
        sourceWindow?.orderFrontRegardless()
        sourceWindow = nil
    }
}

private struct ImmersiveUniforms {
    var resolution: SIMD2<Float>
    var origin: SIMD2<Float>
    var time: Float
    var progress: Float
    var audioLow: Float
    var audioMid: Float
    var audioHigh: Float
}

@MainActor
private final class ImmersiveMetalView: MTKView {
    private var immersiveRenderer: ImmersiveRenderer!

    init(
        frame: CGRect,
        origin: SIMD2<Float>,
        audioFeatures: VisualAudioFeatureStore
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Apple Silicon Mac")
        }

        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = min(
            120,
            window?.screen?.maximumFramesPerSecond ?? 60
        )
        autoResizeDrawable = true

        do {
            immersiveRenderer = try ImmersiveRenderer(
                device: device,
                colorPixelFormat: colorPixelFormat,
                origin: origin,
                audioFeatures: audioFeatures
            )
            delegate = immersiveRenderer
        } catch {
            preconditionFailure("Unable to create immersive renderer: \(error)")
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    func beginEntering() {
        immersiveRenderer.beginEntering()
    }

    func beginExiting(completion: @escaping @MainActor () -> Void) {
        immersiveRenderer.beginExiting(completion: completion)
    }
}

@MainActor
private final class ImmersiveRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let origin: SIMD2<Float>
    private let audioFeatures: VisualAudioFeatureStore
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var transition = ImmersiveTransition(
        direction: .entering,
        startedAt: 0,
        duration: 0.9
    )
    private var exitCompletion: (@MainActor () -> Void)?

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        origin: SIMD2<Float>,
        audioFeatures: VisualAudioFeatureStore
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw OrbRendererError.missingCommandQueue
        }
        guard let library = device.makeDefaultLibrary() else {
            throw OrbRendererError.missingShaderLibrary
        }
        guard let vertexFunction = library.makeFunction(name: "immersiveVertex") else {
            throw OrbRendererError.missingShaderFunction("immersiveVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "immersiveFragment") else {
            throw OrbRendererError.missingShaderFunction("immersiveFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "gmgn radio immersive scene"
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
        self.origin = origin
        self.audioFeatures = audioFeatures
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        startedAt = clock.now
        super.init()
    }

    func beginEntering() {
        transition = ImmersiveTransition(
            direction: .entering,
            startedAt: elapsedSeconds,
            duration: 0.9
        )
    }

    func beginExiting(completion: @escaping @MainActor () -> Void) {
        transition = ImmersiveTransition(
            direction: .exiting,
            startedAt: elapsedSeconds,
            duration: 0.75
        )
        exitCompletion = completion
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let time = elapsedSeconds
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        var uniforms = ImmersiveUniforms(
            resolution: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)
            ),
            origin: origin,
            time: time,
            progress: transition.progress(at: time),
            audioLow: audioFeatures.current.low,
            audioMid: audioFeatures.current.mid,
            audioHigh: audioFeatures.current.high
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ImmersiveUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if transition.direction == .exiting, transition.isComplete(at: time) {
            let completion = exitCompletion
            exitCompletion = nil
            completion?()
        }
    }

    private var elapsedSeconds: Float {
        let components = startedAt.duration(to: clock.now).components
        return Float(
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}
