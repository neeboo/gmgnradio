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
    private let spatialStage: SpatialStageStore
    private var dragInProgress = false

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore = StageArtworkStore(),
        visualDirections: StageVisualDirectionStore = StageVisualDirectionStore(),
        videos: StageVideoPlaybackStore = StageVideoPlaybackStore(),
        spatialStage: SpatialStageStore = SpatialStageStore()
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Apple Silicon Mac")
        }

        self.spatialStage = spatialStage
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
                videos: videos,
                spatialStage: spatialStage
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
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
            if spatialStage.isWorldVisible {
                spatialStage.resetCamera()
            } else {
                stageRenderer.resetCamera()
            }
            return
        }
        beginCameraDrag()
    }

    override func rightMouseDown(with event: NSEvent) {
        beginCameraDrag()
    }

    override func otherMouseDown(with event: NSEvent) {
        beginCameraDrag()
    }

    private func beginCameraDrag() {
        guard !dragInProgress else { return }
        dragInProgress = true
        NSCursor.closedHand.push()
        if !spatialStage.isWorldVisible {
            stageRenderer.beginDrag()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragCamera(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        dragCamera(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        dragCamera(with: event)
    }

    private func dragCamera(with event: NSEvent) {
        if spatialStage.isWorldVisible {
            spatialStage.look(
                deltaX: Float(event.deltaX),
                deltaY: Float(event.deltaY)
            )
        } else {
            stageRenderer.drag(
                deltaX: Float(event.deltaX),
                deltaY: Float(event.deltaY)
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        endDragIfNeeded()
    }

    override func rightMouseUp(with event: NSEvent) {
        endDragIfNeeded()
    }

    override func otherMouseUp(with event: NSEvent) {
        endDragIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        guard spatialStage.isWorldVisible,
              let movement = Self.movement(for: event.keyCode)
        else {
            super.keyDown(with: event)
            return
        }
        spatialStage.setMovement(movement, active: true)
    }

    override func keyUp(with event: NSEvent) {
        guard spatialStage.isWorldVisible,
              let movement = Self.movement(for: event.keyCode)
        else {
            super.keyUp(with: event)
            return
        }
        spatialStage.setMovement(movement, active: false)
    }

    override func flagsChanged(with event: NSEvent) {
        spatialStage.setSpeedBoosted(
            event.modifierFlags.contains(.shift)
        )
        super.flagsChanged(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            spatialStage.clearMovement()
            spatialStage.setSpeedBoosted(false)
            endDragIfNeeded()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func endDragIfNeeded() {
        guard dragInProgress else {
            return
        }
        dragInProgress = false
        stageRenderer.endDrag()
        NSCursor.pop()
    }

    private static func movement(for keyCode: UInt16) -> SpatialMovement? {
        switch keyCode {
        case 13:
            .forward
        case 1:
            .backward
        case 0:
            .left
        case 2:
            .right
        default:
            nil
        }
    }
}
