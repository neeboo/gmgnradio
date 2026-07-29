import AppKit
import SwiftUI

@MainActor
final class StageWindowController: NSWindowController, NSWindowDelegate {
    private let audioFeatures: VisualAudioFeatureStore
    private let audioMonitor: (any VisualAudioMonitoring)?
    private let presentation: StagePresentationModel
    private weak var stageContentView: StageContentView?

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
        stageContentView = nil
        audioMonitor?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        stageContentView = nil
        audioMonitor?.stop()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        stageContentView?.setWindowMode(.fullScreen)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        stageContentView?.setWindowMode(.windowed)
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
        let contentView = StageContentView(
            frame: CGRect(origin: .zero, size: contentSize),
            audioFeatures: audioFeatures,
            presentation: presentation,
            onToggleWindowMode: { [weak window] in
                window?.toggleFullScreen(nil)
            }
        )
        stageContentView = contentView
        window.contentView = contentView
        window.center()
        return window
    }
}

@MainActor
private final class StageContentView: NSView {
    private let windowModeButton: StageWindowModeButton

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        presentation: StagePresentationModel,
        onToggleWindowMode: @escaping @MainActor () -> Void
    ) {
        windowModeButton = StageWindowModeButton(
            mode: .windowed,
            action: onToggleWindowMode
        )
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

        windowModeButton.translatesAutoresizingMaskIntoConstraints = false
        windowModeButton.layer?.zPosition = 20
        addSubview(windowModeButton)
        NSLayoutConstraint.activate([
            windowModeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -22
            ),
            windowModeButton.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -22
            ),
            windowModeButton.widthAnchor.constraint(equalToConstant: 42),
            windowModeButton.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setWindowMode(_ mode: StageWindowMode) {
        windowModeButton.setMode(mode)
    }
}

@MainActor
private final class StageOverlayHostingView: NSHostingView<StageOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class StageWindowModeButton: NSButton {
    private let handler: @MainActor () -> Void

    init(
        mode: StageWindowMode,
        action: @escaping @MainActor () -> Void
    ) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("stage.window-mode-toggle")
        target = self
        self.action = #selector(performAction)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        contentTintColor = NSColor(
            calibratedRed: 0.02,
            green: 0.18,
            blue: 0.55,
            alpha: 1
        )
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 21
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(
            calibratedRed: 0.18,
            green: 0.44,
            blue: 0.92,
            alpha: 0.18
        ).cgColor
        layer?.shadowColor = NSColor(
            calibratedRed: 0.05,
            green: 0.24,
            blue: 0.60,
            alpha: 0.24
        ).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setMode(mode)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setMode(_ mode: StageWindowMode) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .semibold
        )
        image = NSImage(
            systemSymbolName: mode.buttonSymbolName,
            accessibilityDescription: mode.accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        toolTip = mode.accessibilityLabel
        setAccessibilityLabel(mode.accessibilityLabel)
    }

    @objc
    private func performAction() {
        handler()
    }
}
