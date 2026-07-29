import AppKit
import SwiftUI

@MainActor
final class StageWindowController: NSWindowController, NSWindowDelegate {
    private let audioFeatures: VisualAudioFeatureStore
    private let audioMonitor: (any VisualAudioMonitoring)?
    private let presentation: StagePresentationModel

    init(
        audioFeatures: VisualAudioFeatureStore,
        audioMonitor: (any VisualAudioMonitoring)? = nil,
        presentation: StagePresentationModel = StagePresentationModel()
    ) {
        self.audioFeatures = audioFeatures
        self.audioMonitor = audioMonitor
        self.presentation = presentation
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else {
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? audioMonitor?.start()
    }

    override func close() {
        guard let window else {
            return
        }
        window.delegate = nil
        window.close()
        self.window = nil
        audioMonitor?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        audioMonitor?.stop()
    }

    private func makeWindow() -> NSWindow {
        let contentSize = CGSize(width: 1_180, height: 760)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "gmgn radio — 360°舞台"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.isOpaque = true
        window.hasShadow = true
        window.minSize = CGSize(width: 760, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = StageContentView(
            frame: CGRect(origin: .zero, size: contentSize),
            audioFeatures: audioFeatures,
            presentation: presentation
        )
        window.center()
        return window
    }
}

@MainActor
private final class StageContentView: NSView {
    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        presentation: StagePresentationModel
    ) {
        super.init(frame: frame)
        wantsLayer = true

        let metalView = MetalStageView(
            frame: bounds,
            audioFeatures: audioFeatures
        )
        metalView.autoresizingMask = [.width, .height]
        metalView.wantsLayer = true
        metalView.layer?.zPosition = 0
        addSubview(metalView)

        let overlay = StageOverlayHostingView(
            rootView: StageOverlayView(presentation: presentation)
        )
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.zPosition = 10
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class StageOverlayHostingView: NSHostingView<StageOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
