@preconcurrency import MetalKit

@MainActor
final class OrbMetalView: MTKView {
    private var orbRenderer: OrbRenderer!

    init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Apple Silicon Mac")
        }

        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true
        wantsLayer = true
        layer?.isOpaque = false

        do {
            orbRenderer = try OrbRenderer(
                device: device,
                colorPixelFormat: colorPixelFormat
            )
            orbRenderer.attach(to: self)
            orbRenderer.setState(.idle)
        } catch {
            preconditionFailure("Unable to create orb renderer: \(error)")
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        orbRenderer?.setState(.idle)
    }

    func setState(_ state: DJState) {
        orbRenderer.setState(state)
    }
}
