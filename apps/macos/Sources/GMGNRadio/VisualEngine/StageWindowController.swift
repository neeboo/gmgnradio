import AppKit
import SwiftUI

@MainActor
final class StageWindowController: NSWindowController, NSWindowDelegate {
    private let audioFeatures: VisualAudioFeatureStore
    private let audioMonitor: (any VisualAudioMonitoring)?
    private let presentation: StagePresentationModel
    private let visualDirections: StageVisualDirectionStore
    private let onTogglePlayback: @MainActor () -> Void
    private var playbackState: LocalMusicPlaybackState
    private weak var stageContentView: StageContentView?

    init(
        audioFeatures: VisualAudioFeatureStore,
        audioMonitor: (any VisualAudioMonitoring)? = nil,
        presentation: StagePresentationModel = StagePresentationModel(),
        visualDirections: StageVisualDirectionStore = StageVisualDirectionStore(),
        playbackState: LocalMusicPlaybackState = .idle,
        onTogglePlayback: @escaping @MainActor () -> Void = {}
    ) {
        self.audioFeatures = audioFeatures
        self.audioMonitor = audioMonitor
        self.presentation = presentation
        self.visualDirections = visualDirections
        self.playbackState = playbackState
        self.onTogglePlayback = onTogglePlayback
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    func setPlaybackState(_ state: LocalMusicPlaybackState) {
        playbackState = state
        stageContentView?.setPlaybackState(state)
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
        window.backgroundColor = NSColor(
            calibratedRed: 0.004,
            green: 0.008,
            blue: 0.025,
            alpha: 1
        )
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
            visualDirections: visualDirections,
            playbackState: playbackState,
            onTogglePlayback: onTogglePlayback,
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
    private let transportControls: StageTransportControlsView

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        presentation: StagePresentationModel,
        visualDirections: StageVisualDirectionStore,
        playbackState: LocalMusicPlaybackState,
        onTogglePlayback: @escaping @MainActor () -> Void,
        onToggleWindowMode: @escaping @MainActor () -> Void
    ) {
        let playbackButton = StagePlaybackButton(
            state: playbackState,
            action: onTogglePlayback
        )
        let windowModeButton = StageWindowModeButton(
            mode: .windowed,
            action: onToggleWindowMode
        )
        transportControls = StageTransportControlsView(
            playbackButton: playbackButton,
            windowModeButton: windowModeButton
        )
        super.init(frame: frame)
        wantsLayer = true

        let metalView = MetalStageView(
            frame: bounds,
            audioFeatures: audioFeatures,
            visualDirections: visualDirections
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

        transportControls.translatesAutoresizingMaskIntoConstraints = false
        transportControls.layer?.zPosition = 20
        addSubview(transportControls)
        NSLayoutConstraint.activate([
            transportControls.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -22
            ),
            transportControls.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -22
            ),
            transportControls.widthAnchor.constraint(equalToConstant: 104),
            transportControls.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setWindowMode(_ mode: StageWindowMode) {
        transportControls.setWindowMode(mode)
    }

    func setPlaybackState(_ state: LocalMusicPlaybackState) {
        transportControls.setPlaybackState(state)
    }
}

@MainActor
private final class StageOverlayHostingView: NSHostingView<StageOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class StageTransportControlsView: NSVisualEffectView {
    private let playbackButton: StagePlaybackButton
    private let windowModeButton: StageWindowModeButton

    init(
        playbackButton: StagePlaybackButton,
        windowModeButton: StageWindowModeButton
    ) {
        self.playbackButton = playbackButton
        self.windowModeButton = windowModeButton
        super.init(frame: .zero)

        identifier = NSUserInterfaceItemIdentifier("stage.transport-controls")
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.42
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(0.12)
            .cgColor

        [playbackButton, divider, windowModeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            playbackButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            playbackButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playbackButton.widthAnchor.constraint(equalToConstant: 44),
            playbackButton.heightAnchor.constraint(equalToConstant: 44),

            divider.centerXAnchor.constraint(equalTo: centerXAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),

            windowModeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            windowModeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            windowModeButton.widthAnchor.constraint(equalToConstant: 44),
            windowModeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setPlaybackState(_ state: LocalMusicPlaybackState) {
        playbackButton.setState(state)
    }

    func setWindowMode(_ mode: StageWindowMode) {
        windowModeButton.setMode(mode)
    }
}

@MainActor
private final class StagePlaybackButton: NSButton {
    private let handler: @MainActor () -> Void
    private var pointerIsInside = false

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(
        state: LocalMusicPlaybackState,
        action: @escaping @MainActor () -> Void
    ) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("stage.playback-toggle")
        target = self
        self.action = #selector(performAction)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        contentTintColor = NSColor.white
        wantsLayer = true
        layer?.cornerRadius = 20
        setState(state)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setState(_ state: LocalMusicPlaybackState) {
        let isPlaying = state == .playing
        let label = isPlaying ? "暂停" : "播放"
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .semibold
        )
        image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: label
        )?.withSymbolConfiguration(configuration)
        toolTip = label
        setAccessibilityLabel(label)
        isEnabled = state != .idle
        updateAppearance()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                owner: self
            )
        )
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        updateAppearance()
    }

    @objc
    private func performAction() {
        handler()
    }

    private func updateAppearance() {
        let opacity = isEnabled ? 1.0 : 0.36
        let backgroundOpacity = pointerIsInside && isEnabled ? 0.24 : 0.14
        alphaValue = opacity
        contentTintColor = NSColor.white.withAlphaComponent(0.94)
        layer?.backgroundColor = NSColor(
            calibratedRed: 0.08,
            green: 0.58,
            blue: 1,
            alpha: backgroundOpacity
        ).cgColor
    }
}

@MainActor
private final class StageWindowModeButton: NSButton {
    private let handler: @MainActor () -> Void
    private var pointerIsInside = false

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

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
        wantsLayer = true
        layer?.cornerRadius = 20
        setMode(mode)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setMode(_ mode: StageWindowMode) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: mode.buttonSymbolName,
            accessibilityDescription: mode.accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        toolTip = mode.accessibilityLabel
        setAccessibilityLabel(mode.accessibilityLabel)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                owner: self
            )
        )
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        updateAppearance()
    }

    @objc
    private func performAction() {
        handler()
    }

    private func updateAppearance() {
        contentTintColor = NSColor.white.withAlphaComponent(
            pointerIsInside ? 0.92 : 0.64
        )
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(pointerIsInside ? 0.10 : 0)
            .cgColor
    }
}
