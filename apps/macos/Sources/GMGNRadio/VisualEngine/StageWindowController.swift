import AppKit
@preconcurrency import AVFoundation
import Combine
import SwiftUI

@MainActor
final class StageWindowController: NSWindowController, NSWindowDelegate {
    private let audioFeatures: VisualAudioFeatureStore
    private let artwork: StageArtworkStore
    private let audioMonitor: (any VisualAudioMonitoring)?
    private let presentation: StagePresentationModel
    private let visualDirections: StageVisualDirectionStore
    private let videos: StageVideoPlaybackStore
    private let programStore: DJProgramStore
    private let lyrics: StageLyricsStore
    private let playbackPosition: @MainActor () -> TimeInterval
    private let onTogglePlayback: @MainActor () -> Void
    private let onPlayProgramTrack: @MainActor (String, Int) -> Void
    private let onPreviousTrack: @MainActor () -> Void
    private let onNextTrack: @MainActor () -> Void
    private let onReplanProgram: @MainActor () -> Void
    private let onToggleVoice: @MainActor () -> Void
    private var playbackState: LocalMusicPlaybackState
    private var voiceState: RealtimeVoiceConnectionState
    private weak var stageContentView: StageContentView?

    init(
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore = StageArtworkStore(),
        audioMonitor: (any VisualAudioMonitoring)? = nil,
        presentation: StagePresentationModel = StagePresentationModel(),
        visualDirections: StageVisualDirectionStore = StageVisualDirectionStore(),
        videos: StageVideoPlaybackStore = StageVideoPlaybackStore(),
        programStore: DJProgramStore = .shared,
        lyrics: StageLyricsStore = .shared,
        playbackPosition: @escaping @MainActor () -> TimeInterval = { 0 },
        playbackState: LocalMusicPlaybackState = .idle,
        voiceState: RealtimeVoiceConnectionState = .disconnected,
        onTogglePlayback: @escaping @MainActor () -> Void = {},
        onPlayProgramTrack:
            @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onPreviousTrack: @escaping @MainActor () -> Void = {},
        onNextTrack: @escaping @MainActor () -> Void = {},
        onReplanProgram: @escaping @MainActor () -> Void = {},
        onToggleVoice: @escaping @MainActor () -> Void = {}
    ) {
        self.audioFeatures = audioFeatures
        self.artwork = artwork
        self.audioMonitor = audioMonitor
        self.presentation = presentation
        self.visualDirections = visualDirections
        self.videos = videos
        self.programStore = programStore
        self.lyrics = lyrics
        self.playbackPosition = playbackPosition
        self.playbackState = playbackState
        self.voiceState = voiceState
        self.onTogglePlayback = onTogglePlayback
        self.onPlayProgramTrack = onPlayProgramTrack
        self.onPreviousTrack = onPreviousTrack
        self.onNextTrack = onNextTrack
        self.onReplanProgram = onReplanProgram
        self.onToggleVoice = onToggleVoice
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

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        voiceState = state
        stageContentView?.setVoiceState(state)
    }

    func setProgramNavigation(
        canGoPrevious: Bool,
        canGoNext: Bool
    ) {
        stageContentView?.setProgramNavigation(
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext
        )
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
        videos.resume()
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
        videos.pause()
        audioMonitor?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        stageContentView = nil
        videos.pause()
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
            artwork: artwork,
            presentation: presentation,
            visualDirections: visualDirections,
            videos: videos,
            programStore: programStore,
            lyrics: lyrics,
            playbackPosition: playbackPosition,
            playbackState: playbackState,
            voiceState: voiceState,
            onTogglePlayback: onTogglePlayback,
            onPlayProgramTrack: onPlayProgramTrack,
            onPreviousTrack: onPreviousTrack,
            onNextTrack: onNextTrack,
            onReplanProgram: onReplanProgram,
            onToggleVoice: onToggleVoice,
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
    private let overlayState: StageOverlayState
    private var programRail: StageProgramRailHostingView!
    private var visualPicker: StageVisualPickerHostingView!
    private var transportControls: StageTransportControlsView!
    private var isProgramRailVisible = false
    private var isVisualPickerVisible = false

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore,
        presentation: StagePresentationModel,
        visualDirections: StageVisualDirectionStore,
        videos: StageVideoPlaybackStore,
        programStore: DJProgramStore,
        lyrics: StageLyricsStore,
        playbackPosition: @escaping @MainActor () -> TimeInterval,
        playbackState: LocalMusicPlaybackState,
        voiceState: RealtimeVoiceConnectionState,
        onTogglePlayback: @escaping @MainActor () -> Void,
        onPlayProgramTrack: @escaping @MainActor (String, Int) -> Void,
        onPreviousTrack: @escaping @MainActor () -> Void,
        onNextTrack: @escaping @MainActor () -> Void,
        onReplanProgram: @escaping @MainActor () -> Void,
        onToggleVoice: @escaping @MainActor () -> Void,
        onToggleWindowMode: @escaping @MainActor () -> Void
    ) {
        overlayState = StageOverlayState()
        super.init(frame: frame)

        let programButton = StageProgramButton { [weak self] in
            self?.toggleProgramRail()
        }
        let programSelection = StageProgramRailSelection(
            onPlay: onPlayProgramTrack,
            onReplan: onReplanProgram
        )
        let playbackButton = StagePlaybackButton(
            state: playbackState,
            action: onTogglePlayback
        )
        let previousButton = StageTrackNavigationButton(
            direction: .previous,
            action: onPreviousTrack
        )
        let nextButton = StageTrackNavigationButton(
            direction: .next,
            action: onNextTrack
        )
        let voiceButton = StageVoiceButton(
            state: voiceState,
            action: onToggleVoice
        )
        let visualButton = StageVisualButton { [weak self] in
            self?.toggleVisualPicker()
        }
        let windowModeButton = StageWindowModeButton(
            mode: .windowed,
            action: onToggleWindowMode
        )
        transportControls = StageTransportControlsView(
            programButton: programButton,
            previousButton: previousButton,
            playbackButton: playbackButton,
            nextButton: nextButton,
            voiceButton: voiceButton,
            visualButton: visualButton,
            windowModeButton: windowModeButton
        )
        wantsLayer = true

        let videoView = StageVideoPlayerView(frame: bounds, videos: videos)
        videoView.identifier = NSUserInterfaceItemIdentifier(
            "stage.video-background"
        )
        videoView.autoresizingMask = [.width, .height]
        videoView.layer?.zPosition = 0
        addSubview(videoView)

        let metalView = MetalStageView(
            frame: bounds,
            audioFeatures: audioFeatures,
            artwork: artwork,
            visualDirections: visualDirections,
            videos: videos
        )
        metalView.autoresizingMask = [.width, .height]
        metalView.identifier = NSUserInterfaceItemIdentifier(
            "stage.metal-particles"
        )
        metalView.wantsLayer = true
        metalView.layer?.zPosition = 1
        addSubview(metalView)

        let overlay = StageOverlayHostingView(
            rootView: StageOverlayView(
                presentation: presentation,
                overlayState: overlayState,
                lyrics: lyrics,
                videos: videos,
                audioFeatures: audioFeatures,
                playbackPosition: playbackPosition
            )
        )
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.zPosition = 10
        addSubview(overlay)

        programRail = StageProgramRailHostingView(
            rootView: StageProgramRailView(
                programStore: programStore,
                selection: programSelection,
                videos: videos,
                audioFeatures: audioFeatures
            )
        )
        programRail.identifier = NSUserInterfaceItemIdentifier(
            "stage.program-rail"
        )
        programRail.translatesAutoresizingMaskIntoConstraints = false
        programRail.wantsLayer = true
        programRail.layer?.zPosition = 18
        programRail.isHidden = true
        addSubview(programRail)

        visualPicker = StageVisualPickerHostingView(
            rootView: StageVisualPickerView(
                lyrics: lyrics,
                visualDirections: visualDirections,
                videos: videos,
                programStore: programStore
            )
        )
        visualPicker.identifier = NSUserInterfaceItemIdentifier(
            "stage.visual-picker"
        )
        visualPicker.translatesAutoresizingMaskIntoConstraints = false
        visualPicker.wantsLayer = true
        visualPicker.layer?.zPosition = 19
        visualPicker.isHidden = true
        addSubview(visualPicker)

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
            transportControls.widthAnchor.constraint(equalToConstant: 322),
            transportControls.heightAnchor.constraint(equalToConstant: 48),

            programRail.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -18
            ),
            programRail.bottomAnchor.constraint(
                equalTo: transportControls.topAnchor,
                constant: -10
            ),
            programRail.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            programRail.widthAnchor.constraint(equalToConstant: 350),
            programRail.heightAnchor.constraint(equalToConstant: 430),

            visualPicker.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -18
            ),
            visualPicker.bottomAnchor.constraint(
                equalTo: transportControls.topAnchor,
                constant: -10
            ),
            visualPicker.widthAnchor.constraint(equalToConstant: 590),
            visualPicker.heightAnchor.constraint(equalToConstant: 378)
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

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        transportControls.setVoiceState(state)
    }

    func setProgramNavigation(
        canGoPrevious: Bool,
        canGoNext: Bool
    ) {
        transportControls.setProgramNavigation(
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext
        )
    }

    private func toggleProgramRail() {
        isProgramRailVisible.toggle()
        if isProgramRailVisible {
            isVisualPickerVisible = false
            visualPicker.isHidden = true
            transportControls.setVisualPickerExpanded(false)
        }
        programRail.isHidden = !isProgramRailVisible
        transportControls.setProgramRailExpanded(isProgramRailVisible)
        overlayState.setProgramRailVisible(isProgramRailVisible)
    }

    private func toggleVisualPicker() {
        isVisualPickerVisible.toggle()
        if isVisualPickerVisible {
            isProgramRailVisible = false
            programRail.isHidden = true
            transportControls.setProgramRailExpanded(false)
            overlayState.setProgramRailVisible(false)
        }
        visualPicker.isHidden = !isVisualPickerVisible
        transportControls.setVisualPickerExpanded(isVisualPickerVisible)
    }
}

@MainActor
private final class StageVideoPlayerView: NSView {
    private let playerLayer: AVPlayerLayer
    private let toneLayer = CAGradientLayer()
    private var brightnessCancellable: AnyCancellable?

    init(frame: CGRect, videos: StageVideoPlaybackStore) {
        playerLayer = AVPlayerLayer(player: videos.player)
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.isOpaque = true
        playerLayer.opacity = videos.brightness
        playerLayer.zPosition = 0
        layer?.addSublayer(playerLayer)

        toneLayer.name = "stage.video-tone-overlay"
        toneLayer.colors = [
            NSColor.black.withAlphaComponent(0.22).cgColor,
            NSColor.black.withAlphaComponent(0.10).cgColor,
            NSColor.black.withAlphaComponent(0.30).cgColor,
        ]
        toneLayer.locations = [0, 0.46, 1]
        toneLayer.startPoint = CGPoint(x: 0.5, y: 1)
        toneLayer.endPoint = CGPoint(x: 0.5, y: 0)
        toneLayer.zPosition = 1
        layer?.addSublayer(toneLayer)

        brightnessCancellable = videos.$brightness
            .removeDuplicates()
            .sink { [weak playerLayer] brightness in
                playerLayer?.opacity = brightness
            }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        toneLayer.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class StageOverlayHostingView: NSHostingView<StageOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class StageProgramRailHostingView:
    NSHostingView<StageProgramRailView>
{}

@MainActor
private final class StageVisualPickerHostingView:
    NSHostingView<StageVisualPickerView>
{}

@MainActor
private final class StageTransportControlsView: NSVisualEffectView {
    private let programButton: StageProgramButton
    private let previousButton: StageTrackNavigationButton
    private let playbackButton: StagePlaybackButton
    private let nextButton: StageTrackNavigationButton
    private let voiceButton: StageVoiceButton
    private let visualButton: StageVisualButton
    private let windowModeButton: StageWindowModeButton

    init(
        programButton: StageProgramButton,
        previousButton: StageTrackNavigationButton,
        playbackButton: StagePlaybackButton,
        nextButton: StageTrackNavigationButton,
        voiceButton: StageVoiceButton,
        visualButton: StageVisualButton,
        windowModeButton: StageWindowModeButton
    ) {
        self.programButton = programButton
        self.previousButton = previousButton
        self.playbackButton = playbackButton
        self.nextButton = nextButton
        self.voiceButton = voiceButton
        self.visualButton = visualButton
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

        let dividers = (0 ..< 6).map { _ in
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.white
                .withAlphaComponent(0.12)
                .cgColor
            return divider
        }

        (
            [
                programButton,
                previousButton,
                playbackButton,
                nextButton,
                voiceButton,
                visualButton,
                windowModeButton
            ] + dividers
        ).forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            programButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 4
            ),
            programButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            programButton.widthAnchor.constraint(equalToConstant: 44),
            programButton.heightAnchor.constraint(equalToConstant: 44),

            dividers[0].leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 48
            ),
            dividers[0].centerYAnchor.constraint(equalTo: centerYAnchor),
            dividers[0].widthAnchor.constraint(equalToConstant: 1),
            dividers[0].heightAnchor.constraint(equalToConstant: 18),

            previousButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 49
            ),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44),

            dividers[1].leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 93
            ),
            dividers[1].centerYAnchor.constraint(equalTo: centerYAnchor),
            dividers[1].widthAnchor.constraint(equalToConstant: 1),
            dividers[1].heightAnchor.constraint(equalToConstant: 18),

            playbackButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 94
            ),
            playbackButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playbackButton.widthAnchor.constraint(equalToConstant: 44),
            playbackButton.heightAnchor.constraint(equalToConstant: 44),

            dividers[2].leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 138
            ),
            dividers[2].centerYAnchor.constraint(equalTo: centerYAnchor),
            dividers[2].widthAnchor.constraint(equalToConstant: 1),
            dividers[2].heightAnchor.constraint(equalToConstant: 18),

            nextButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 139
            ),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),

            dividers[3].leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 183
            ),
            dividers[3].centerYAnchor.constraint(equalTo: centerYAnchor),
            dividers[3].widthAnchor.constraint(equalToConstant: 1),
            dividers[3].heightAnchor.constraint(equalToConstant: 18),

            voiceButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 184
            ),
            voiceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            voiceButton.widthAnchor.constraint(equalToConstant: 44),
            voiceButton.heightAnchor.constraint(equalToConstant: 44),

            dividers[4].leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 228
            ),
            dividers[4].centerYAnchor.constraint(equalTo: centerYAnchor),
            dividers[4].widthAnchor.constraint(equalToConstant: 1),
            dividers[4].heightAnchor.constraint(equalToConstant: 18),

            visualButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 229
            ),
            visualButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            visualButton.widthAnchor.constraint(equalToConstant: 44),
            visualButton.heightAnchor.constraint(equalToConstant: 44),

            dividers[5].leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 273
            ),
            dividers[5].centerYAnchor.constraint(equalTo: centerYAnchor),
            dividers[5].widthAnchor.constraint(equalToConstant: 1),
            dividers[5].heightAnchor.constraint(equalToConstant: 18),

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

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        voiceButton.setState(state)
    }

    func setProgramNavigation(
        canGoPrevious: Bool,
        canGoNext: Bool
    ) {
        previousButton.setEnabled(canGoPrevious)
        nextButton.setEnabled(canGoNext)
    }

    func setWindowMode(_ mode: StageWindowMode) {
        windowModeButton.setMode(mode)
    }

    func setProgramRailExpanded(_ isExpanded: Bool) {
        programButton.setExpanded(isExpanded)
    }

    func setVisualPickerExpanded(_ isExpanded: Bool) {
        visualButton.setExpanded(isExpanded)
    }
}

@MainActor
private final class StageVisualButton: NSButton {
    private let handler: @MainActor () -> Void
    private var isExpanded = false

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("stage.visual-toggle")
        target = self
        self.action = #selector(performAction)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 20
        updateContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setExpanded(_ isExpanded: Bool) {
        self.isExpanded = isExpanded
        updateContent()
    }

    @objc
    private func performAction() {
        handler()
    }

    private func updateContent() {
        let label = isExpanded ? "收起视觉选择" : "选择字幕、点阵与 MV"
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: isExpanded
                ? "xmark"
                : "circle.hexagongrid",
            accessibilityDescription: label
        )?.withSymbolConfiguration(configuration)
        contentTintColor = isExpanded
            ? NSColor(
                calibratedRed: 0.34,
                green: 0.9,
                blue: 1,
                alpha: 1
            )
            : NSColor.white.withAlphaComponent(0.72)
        layer?.backgroundColor = isExpanded
            ? NSColor(
                calibratedRed: 0.04,
                green: 0.3,
                blue: 0.42,
                alpha: 0.72
            ).cgColor
            : NSColor.clear.cgColor
        toolTip = label
        setAccessibilityLabel(label)
    }
}

@MainActor
private final class StageProgramButton: NSButton {
    private let handler: @MainActor () -> Void
    private var pointerIsInside = false
    private var isExpanded = false

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("stage.program-toggle")
        target = self
        self.action = #selector(performAction)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 20
        updateContent()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setExpanded(_ isExpanded: Bool) {
        self.isExpanded = isExpanded
        updateContent()
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

    private func updateContent() {
        let label = isExpanded ? "收起节目轨道" : "查看节目轨道"
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: isExpanded ? "music.note.list" : "music.note.list",
            accessibilityDescription: label
        )?.withSymbolConfiguration(configuration)
        toolTip = label
        setAccessibilityLabel(label)
    }

    private func updateAppearance() {
        contentTintColor = isExpanded
            ? NSColor(
                calibratedRed: 0.38,
                green: 0.9,
                blue: 1,
                alpha: 1
            )
            : NSColor.white.withAlphaComponent(pointerIsInside ? 0.92 : 0.64)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(
            isExpanded ? 0.1 : (pointerIsInside ? 0.08 : 0)
        ).cgColor
    }
}

@MainActor
private final class StageTrackNavigationButton: NSButton {
    enum Direction {
        case previous
        case next

        var identifier: String {
            switch self {
            case .previous:
                "stage.previous-track"
            case .next:
                "stage.next-track"
            }
        }

        var symbolName: String {
            switch self {
            case .previous:
                "backward.end.fill"
            case .next:
                "forward.end.fill"
            }
        }

        var label: String {
            switch self {
            case .previous:
                "上一首"
            case .next:
                "下一首"
            }
        }
    }

    private let handler: @MainActor () -> Void
    private var pointerIsInside = false

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(
        direction: Direction,
        action: @escaping @MainActor () -> Void
    ) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(direction.identifier)
        target = self
        self.action = #selector(performAction)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 20
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: direction.symbolName,
            accessibilityDescription: direction.label
        )?.withSymbolConfiguration(configuration)
        toolTip = direction.label
        setAccessibilityLabel(direction.label)
        setEnabled(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
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
        alphaValue = isEnabled ? 1 : 0.28
        contentTintColor = NSColor.white.withAlphaComponent(
            pointerIsInside && isEnabled ? 0.94 : 0.64
        )
        layer?.backgroundColor = NSColor.white.withAlphaComponent(
            pointerIsInside && isEnabled ? 0.1 : 0
        ).cgColor
    }
}

@MainActor
private final class StagePlaybackButton: NSButton {
    private let handler: @MainActor () -> Void
    private var pointerIsInside = false
    private var playbackState = LocalMusicPlaybackState.idle

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
        playbackState = state
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
private final class StageVoiceButton: NSButton {
    private let handler: @MainActor () -> Void
    private var pointerIsInside = false
    private var voiceState = RealtimeVoiceConnectionState.disconnected

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(
        state: RealtimeVoiceConnectionState,
        action: @escaping @MainActor () -> Void
    ) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("stage.voice-toggle")
        target = self
        self.action = #selector(performAction)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 20
        setState(state)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setState(_ state: RealtimeVoiceConnectionState) {
        voiceState = state
        let content: (symbol: String, label: String)
        switch state {
        case .disconnected:
            content = ("mic.slash.fill", "麦克风已关闭，点击开麦")
        case .connecting:
            content = ("hourglass", "正在开启麦克风，点击取消")
        case .connected:
            content = ("mic.fill", "麦克风已开启，点击关闭")
        case .listening:
            content = ("waveform.circle.fill", "麦克风已开启，DJ 正在听")
        case .speaking:
            content = ("speaker.wave.2.fill", "DJ 正在说话")
        case let .failed(message):
            content = (
                "exclamationmark.triangle.fill",
                "开麦失败：\(message)；点击重试"
            )
        }
        image = NSImage(
            systemSymbolName: content.symbol,
            accessibilityDescription: content.label
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: 14,
                weight: .semibold
            )
        )
        toolTip = content.label
        setAccessibilityLabel(content.label)
        isEnabled = true
        updateAppearance()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .activeInKeyWindow,
                    .inVisibleRect,
                    .mouseEnteredAndExited,
                ],
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
        let tint: NSColor
        let background: NSColor
        let isLive: Bool
        switch voiceState {
        case .disconnected:
            isLive = false
            tint = NSColor.white.withAlphaComponent(
                pointerIsInside ? 0.9 : 0.56
            )
            background = NSColor.white.withAlphaComponent(
                pointerIsInside ? 0.1 : 0
            )
        case .connecting:
            isLive = false
            tint = NSColor.systemOrange
            background = NSColor.systemOrange.withAlphaComponent(
                pointerIsInside ? 0.24 : 0.14
            )
        case .connected, .listening:
            isLive = true
            tint = NSColor(
                calibratedWhite: 0.05,
                alpha: 0.96
            )
            background = NSColor(
                calibratedRed: 0.38,
                green: 0.92,
                blue: 1,
                alpha: pointerIsInside ? 1 : 0.92
            )
        case .speaking:
            isLive = true
            tint = NSColor(
                calibratedWhite: 0.04,
                alpha: 0.96
            )
            background = NSColor(
                calibratedRed: 0.58,
                green: 0.8,
                blue: 1,
                alpha: pointerIsInside ? 1 : 0.92
            )
        case .failed:
            isLive = false
            tint = NSColor.systemRed
            background = NSColor.systemRed.withAlphaComponent(
                pointerIsInside ? 0.24 : 0.14
            )
        }
        contentTintColor = tint
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = isLive ? 1.5 : 0
        layer?.borderColor = isLive
            ? NSColor.white.withAlphaComponent(0.72).cgColor
            : nil
        updateLivePulse(isLive)
        alphaValue = 1
    }

    private func updateLivePulse(_ active: Bool) {
        guard let layer else {
            return
        }
        guard active else {
            layer.removeAnimation(forKey: "voice-active-pulse")
            layer.shadowOpacity = 0
            return
        }
        layer.shadowColor = NSColor(
            calibratedRed: 0.38,
            green: 0.92,
            blue: 1,
            alpha: 1
        ).cgColor
        layer.shadowRadius = 9
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0.58
        guard
            layer.animation(forKey: "voice-active-pulse") == nil
        else {
            return
        }
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.24
        pulse.toValue = 0.82
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )
        layer.add(pulse, forKey: "voice-active-pulse")
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
