import AppKit
@preconcurrency import MetalKit

@MainActor
final class StageArtworkStore {
    private(set) var image: CGImage?
    private(set) var revision: UInt64 = 0
    private var loadingURL: URL?

    func load(from url: URL?) async {
        guard let url else {
            clear()
            return
        }
        guard url != loadingURL else {
            return
        }
        loadingURL = url

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard loadingURL == url else {
                return
            }
            var proposedRect = CGRect.zero
            image = NSImage(data: data)?.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            )
            revision &+= 1
        } catch {
            guard loadingURL == url else {
                return
            }
            image = nil
            revision &+= 1
        }
    }

    func clear() {
        loadingURL = nil
        guard image != nil else {
            return
        }
        image = nil
        revision &+= 1
    }
}

@MainActor
final class MetalStageView: MTKView {
    private var stageRenderer: StageRenderer!
    private var dragInProgress = false

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore = StageArtworkStore(),
        visualDirections: StageVisualDirectionStore = StageVisualDirectionStore(),
        videos: StageVideoPlaybackStore = StageVideoPlaybackStore()
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Apple Silicon Mac")
        }

        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        clearDepth = 1
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        wantsLayer = true
        layer?.isOpaque = false

        do {
            stageRenderer = try StageRenderer(
                device: device,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthStencilPixelFormat,
                audioFeatures: audioFeatures,
                artwork: artwork,
                visualDirections: visualDirections,
                videos: videos
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
