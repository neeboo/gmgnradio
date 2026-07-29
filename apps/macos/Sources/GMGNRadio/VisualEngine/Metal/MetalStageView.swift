@preconcurrency import MetalKit

@MainActor
final class MetalStageView: MTKView {
    private var stageRenderer: StageRenderer!
    private var dragInProgress = false

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        visualDirections: StageVisualDirectionStore = StageVisualDirectionStore()
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Apple Silicon Mac")
        }

        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColorMake(0.004, 0.008, 0.025, 1)
        clearDepth = 1
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true

        do {
            stageRenderer = try StageRenderer(
                device: device,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthStencilPixelFormat,
                audioFeatures: audioFeatures,
                visualDirections: visualDirections
            )
            delegate = stageRenderer
        } catch {
            preconditionFailure("Unable to create 360 stage renderer: \(error)")
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        preferredFramesPerSecond = min(
            120,
            window?.screen?.maximumFramesPerSecond ?? 60
        )
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            endDragIfNeeded()
            stageRenderer.resetCamera()
            return
        }
        dragInProgress = true
        NSCursor.closedHand.push()
        stageRenderer.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        stageRenderer.drag(
            deltaX: Float(event.deltaX),
            deltaY: Float(event.deltaY)
        )
    }

    override func mouseUp(with event: NSEvent) {
        endDragIfNeeded()
    }

    private func endDragIfNeeded() {
        guard dragInProgress else {
            return
        }
        dragInProgress = false
        stageRenderer.endDrag()
        NSCursor.pop()
    }
}
