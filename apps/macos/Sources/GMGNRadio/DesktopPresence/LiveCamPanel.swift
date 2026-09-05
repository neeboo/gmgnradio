import AppKit
import CoreGraphics
import SwiftUI

enum LiveCamFeed: Equatable, Sendable {
    case virtualWorld
}

struct LiveCamPlayerMenuSnapshot: Equatable, Sendable {
    static let noProgram = LiveCamPlayerMenuSnapshot(
        trackTitle: nil,
        isPlaying: false,
        canTogglePlayback: false,
        canSelectPrevious: false,
        canSelectNext: false
    )

    let trackTitle: String?
    let isPlaying: Bool
    let canTogglePlayback: Bool
    let canSelectPrevious: Bool
    let canSelectNext: Bool

    var menuTitle: String {
        trackTitle ?? "暂无播放节目"
    }

    var playPauseTitle: String {
        isPlaying ? "暂停" : "播放"
    }

    static func resolve(
        playerState: LocalMusicPlaybackState,
        hasPreparedProgram: Bool,
        trackTitle: String?,
        canSelectPrevious: Bool,
        canSelectNext: Bool
    ) -> Self {
        let route = ProgramPlaybackToggleRoute.resolve(
            playerState: playerState,
            hasPreparedProgram: hasPreparedProgram
        )
        return Self(
            trackTitle: trackTitle,
            isPlaying: route == .pauseLocal,
            canTogglePlayback: route != .unavailable,
            canSelectPrevious: canSelectPrevious,
            canSelectNext: canSelectNext
        )
    }
}

enum LiveCamSpaceEntryPolicy {
    static let maximumClickDrift: CGFloat = 4

    static func shouldEnterSpace(
        downLocation: CGPoint?,
        upLocation: CGPoint,
        acceptsBackdropClick: Bool
    ) -> Bool {
        guard acceptsBackdropClick, let downLocation else {
            return false
        }
        let drift = hypot(
            upLocation.x - downLocation.x,
            upLocation.y - downLocation.y
        )
        return drift <= maximumClickDrift
    }
}

struct LiveCamLayout: Equatable, Sendable {
    let size: CGSize
    let cornerRadius: CGFloat

    static let compactPortrait = LiveCamLayout(
        size: CGSize(width: 224, height: 336),
        cornerRadius: 28
    )
}

enum LiveCamPointerBinding: Int, Equatable, Sendable {
    case moveWindow = 0
    case rotateCamera = 2

    var buttonNumbers: [Int] {
        switch self {
        case .moveWindow:
            [0]
        case .rotateCamera:
            [1, 2]
        }
    }

    var buttonMasks: [Int] {
        buttonNumbers.map { 1 << $0 }
    }
}

struct LiveCamWindowPointerDelta: Equatable, Sendable {
    static func resolve(
        previousScreenLocation: CGPoint?,
        currentScreenLocation: CGPoint
    ) -> CGSize {
        guard let previousScreenLocation else { return .zero }
        return CGSize(
            width: currentScreenLocation.x - previousScreenLocation.x,
            height: currentScreenLocation.y - previousScreenLocation.y
        )
    }
}

@MainActor
final class LiveCamInteractionView: NSView {
    private enum ReplyPresentation {
        case agentReply
        case chatStatus
    }

    let spaceButton = NSButton()
    let playerButton = NSButton()
    let chatButton = NSButton()
    let voiceButton = NSButton()
    let settingsButton = NSButton()
    let messageField = NSTextField()
    let sendButton = NSButton()

    private let controls = NSStackView()
    private let composer = NSVisualEffectView()
    private let replyBubble = NSVisualEffectView()
    private let replyLabel = NSTextField(wrappingLabelWithString: "")
    private var replyPresentation: ReplyPresentation?
    private var onEnterSpace: @MainActor () -> Void
    private var onOpenPlayer: @MainActor () -> Void
    private var onOpenSettings: @MainActor () -> Void
    private var onPreviousTrack: @MainActor () -> Void
    private var onTogglePlayback: @MainActor () -> Void
    private var onNextTrack: @MainActor () -> Void
    private var playerMenuSnapshotProvider: @MainActor () -> LiveCamPlayerMenuSnapshot
    private var onSendMessage: @MainActor (String) -> Void
    private var onToggleVoice: @MainActor () -> Void
    var onComposerVisibilityChanged: @MainActor (Bool) -> Void = { _ in }

    var isComposerVisible: Bool {
        !composer.isHidden
    }

    var replyText: String {
        replyLabel.stringValue
    }

    var isReplyHidden: Bool {
        replyBubble.isHidden
    }

    init(
        onEnterSpace: @escaping @MainActor () -> Void = {},
        onOpenPlayer: @escaping @MainActor () -> Void = {},
        onOpenSettings: @escaping @MainActor () -> Void = {},
        onPreviousTrack: @escaping @MainActor () -> Void = {},
        onTogglePlayback: @escaping @MainActor () -> Void = {},
        onNextTrack: @escaping @MainActor () -> Void = {},
        playerMenuSnapshotProvider: @escaping @MainActor () -> LiveCamPlayerMenuSnapshot = {
            .noProgram
        },
        onSendMessage: @escaping @MainActor (String) -> Void = { _ in },
        onToggleVoice: @escaping @MainActor () -> Void = {}
    ) {
        self.onEnterSpace = onEnterSpace
        self.onOpenPlayer = onOpenPlayer
        self.onOpenSettings = onOpenSettings
        self.onPreviousTrack = onPreviousTrack
        self.onTogglePlayback = onTogglePlayback
        self.onNextTrack = onNextTrack
        self.playerMenuSnapshotProvider = playerMenuSnapshotProvider
        self.onSendMessage = onSendMessage
        self.onToggleVoice = onToggleVoice
        super.init(frame: .zero)
        configureViews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func setSendMessageHandler(
        _ handler: @escaping @MainActor (String) -> Void
    ) {
        onSendMessage = handler
    }

    func setToggleVoiceHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        onToggleVoice = handler
    }

    func focusComposer() {
        guard isComposerVisible else { return }
        window?.makeFirstResponder(messageField)
    }

    func closeComposer() {
        guard isComposerVisible else { return }
        composer.isHidden = true
        onComposerVisibilityChanged(false)
    }

    func showReply(_ text: String) {
        show(text, as: .agentReply)
    }

    func showChatStatus(_ text: String) {
        show(text, as: .chatStatus)
    }

    func dismissChatStatus() {
        guard replyPresentation == .chatStatus else { return }
        show("", as: .chatStatus)
    }

    private func show(_ text: String, as presentation: ReplyPresentation) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        replyLabel.stringValue = normalized
        replyBubble.isHidden = normalized.isEmpty
        replyPresentation = normalized.isEmpty ? nil : presentation
    }

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        let symbolName: String
        let label: String
        switch state {
        case .disconnected:
            symbolName = "mic"
            label = "开始语音"
        case .connecting:
            symbolName = "ellipsis.circle"
            label = "正在连接语音"
        case .connected:
            symbolName = "mic.fill"
            label = "语音已连接"
        case .listening:
            symbolName = "waveform"
            label = "正在听"
        case .speaking:
            symbolName = "waveform.circle.fill"
            label = "Agent 正在说话"
        case .failed:
            symbolName = "exclamationmark.mic"
            label = "语音连接失败"
        }
        voiceButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )
        voiceButton.toolTip = label
        switch state {
        case .connected, .listening, .speaking:
            dismissChatStatus()
        case .disconnected, .connecting, .failed:
            break
        }
    }

    private func configureViews() {
        configureButton(
            spaceButton,
            symbolName: "cube.transparent",
            label: "进入空间",
            identifier: "livecam.button.space",
            action: #selector(enterSpace)
        )
        configureButton(
            playerButton,
            symbolName: "music.note",
            label: "播放器",
            identifier: "livecam.button.player",
            action: #selector(presentPlayerMenuAction)
        )
        configureButton(
            chatButton,
            symbolName: "message.fill",
            label: "文字聊天",
            identifier: "livecam.button.chat",
            action: #selector(toggleComposer)
        )
        configureButton(
            voiceButton,
            symbolName: "mic",
            label: "开始语音",
            identifier: "livecam.button.voice",
            action: #selector(toggleVoice)
        )
        configureButton(
            settingsButton,
            symbolName: "gearshape.fill",
            label: "设置",
            identifier: "livecam.button.settings",
            action: #selector(openSettings)
        )

        controls.orientation = .vertical
        controls.spacing = 6
        controls.alignment = .centerX
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(spaceButton)
        controls.addArrangedSubview(playerButton)
        controls.addArrangedSubview(chatButton)
        controls.addArrangedSubview(voiceButton)
        controls.addArrangedSubview(settingsButton)
        addSubview(controls)

        configureGlass(composer)
        composer.isHidden = true
        addSubview(composer)

        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.isBordered = false
        messageField.drawsBackground = false
        messageField.focusRingType = .none
        messageField.font = .systemFont(ofSize: 12)
        messageField.textColor = .white
        messageField.placeholderString = "跟 Agent 说点什么…"
        messageField.target = self
        messageField.action = #selector(submitMessage)
        composer.addSubview(messageField)

        configureButton(
            sendButton,
            symbolName: "arrow.up",
            label: "发送",
            identifier: "livecam.button.send",
            action: #selector(submitMessage)
        )
        composer.addSubview(sendButton)

        configureGlass(replyBubble)
        replyBubble.isHidden = true
        addSubview(replyBubble)

        replyLabel.translatesAutoresizingMaskIntoConstraints = false
        replyLabel.font = .systemFont(ofSize: 12)
        replyLabel.textColor = .white
        replyLabel.maximumNumberOfLines = 4
        replyLabel.lineBreakMode = .byTruncatingTail
        replyBubble.addSubview(replyLabel)

        let speechErrorNotice = NSHostingView(rootView: ResidentSpeechErrorNotice())
        speechErrorNotice.translatesAutoresizingMaskIntoConstraints = false
        speechErrorNotice.identifier = NSUserInterfaceItemIdentifier("livecam.speech-error")
        addSubview(speechErrorNotice)

        NSLayoutConstraint.activate([
            speechErrorNotice.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            speechErrorNotice.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            speechErrorNotice.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.widthAnchor.constraint(equalToConstant: 30),
            controls.heightAnchor.constraint(equalToConstant: 174),
            spaceButton.widthAnchor.constraint(equalToConstant: 30),
            spaceButton.heightAnchor.constraint(equalToConstant: 30),
            playerButton.widthAnchor.constraint(equalToConstant: 30),
            playerButton.heightAnchor.constraint(equalToConstant: 30),
            chatButton.widthAnchor.constraint(equalToConstant: 30),
            chatButton.heightAnchor.constraint(equalToConstant: 30),
            voiceButton.widthAnchor.constraint(equalToConstant: 30),
            voiceButton.heightAnchor.constraint(equalToConstant: 30),
            settingsButton.widthAnchor.constraint(equalToConstant: 30),
            settingsButton.heightAnchor.constraint(equalToConstant: 30),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            composer.heightAnchor.constraint(equalToConstant: 42),
            messageField.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 10),
            messageField.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            messageField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            sendButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -6),
            sendButton.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),

            replyBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            replyBubble.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8),
            replyBubble.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            replyLabel.leadingAnchor.constraint(equalTo: replyBubble.leadingAnchor, constant: 10),
            replyLabel.trailingAnchor.constraint(equalTo: replyBubble.trailingAnchor, constant: -10),
            replyLabel.topAnchor.constraint(equalTo: replyBubble.topAnchor, constant: 8),
            replyLabel.bottomAnchor.constraint(equalTo: replyBubble.bottomAnchor, constant: -8),
        ])
    }

    private func configureButton(
        _ button: NSButton,
        symbolName: String,
        label: String,
        identifier: String,
        action: Selector
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = label
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        button.layer?.cornerRadius = 15
    }

    private func configureGlass(_ view: NSVisualEffectView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
    }

    func isPassiveDecoration(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node === self {
                return true
            }
            if node is NSButton || node === controls || node === composer {
                return false
            }
            current = node.superview
        }
        return false
    }

    func makePlayerMenu() -> NSMenu {
        let snapshot = playerMenuSnapshotProvider()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.setAccessibilityIdentifier("livecam.player.menu")

        let trackItem = NSMenuItem(
            title: snapshot.menuTitle,
            action: nil,
            keyEquivalent: ""
        )
        trackItem.isEnabled = false
        trackItem.setAccessibilityIdentifier("livecam.player.menu.track")
        menu.addItem(trackItem)
        menu.addItem(.separator())

        menu.addItem(playerMenuItem(
            "上一首",
            identifier: "livecam.player.menu.previous",
            isEnabled: snapshot.canSelectPrevious,
            action: #selector(performPreviousTrackMenuAction)
        ))
        menu.addItem(playerMenuItem(
            snapshot.playPauseTitle,
            identifier: "livecam.player.menu.playback",
            isEnabled: snapshot.canTogglePlayback,
            action: #selector(performTogglePlaybackMenuAction)
        ))
        menu.addItem(playerMenuItem(
            "下一首",
            identifier: "livecam.player.menu.next",
            isEnabled: snapshot.canSelectNext,
            action: #selector(performNextTrackMenuAction)
        ))
        menu.addItem(.separator())
        menu.addItem(playerMenuItem(
            "进入播放器",
            identifier: "livecam.player.menu.openPlayer",
            isEnabled: true,
            action: #selector(performOpenPlayerMenuAction)
        ))
        return menu
    }

    private func playerMenuItem(
        _ title: String,
        identifier: String,
        isEnabled: Bool,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.isEnabled = isEnabled
        item.setAccessibilityIdentifier(identifier)
        item.target = self
        return item
    }

    func presentPlayerMenu() {
        let menu = makePlayerMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: playerButton.bounds.height + 4),
            in: playerButton
        )
    }

    @objc
    private func enterSpace() {
        onEnterSpace()
    }

    @objc
    private func presentPlayerMenuAction() {
        presentPlayerMenu()
    }

    @objc
    private func openSettings() {
        onOpenSettings()
    }

    @objc
    private func performPreviousTrackMenuAction() {
        onPreviousTrack()
    }

    @objc
    private func performTogglePlaybackMenuAction() {
        onTogglePlayback()
    }

    @objc
    private func performNextTrackMenuAction() {
        onNextTrack()
    }

    @objc
    private func performOpenPlayerMenuAction() {
        onOpenPlayer()
    }

    @objc
    private func toggleComposer() {
        composer.isHidden.toggle()
        let isVisible = !composer.isHidden
        onComposerVisibilityChanged(isVisible)
        if isVisible {
            focusComposer()
        }
    }

    @objc
    private func submitMessage() {
        let message = messageField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        messageField.stringValue = ""
        closeComposer()
        onSendMessage(message)
    }

    @objc
    private func toggleVoice() {
        onToggleVoice()
    }
}

@MainActor
struct LiveCamApertureMask {
    private let makePath: @MainActor (CGRect) -> CGPath

    init(_ makePath: @escaping @MainActor (CGRect) -> CGPath) {
        self.makePath = makePath
    }

    func path(in bounds: CGRect) -> CGPath {
        makePath(bounds)
    }

    static let ellipse = LiveCamApertureMask { bounds in
        CGPath(ellipseIn: bounds, transform: nil)
    }

    static func roundedRectangle(cornerRadius: CGFloat) -> Self {
        LiveCamApertureMask { bounds in
            CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }
    }
}

@MainActor
final class LiveCamPanel: NSPanel {
    let feed = LiveCamFeed.virtualWorld
    private var onEnterSpace: @MainActor () -> Void
    private var chatInputActive = false
    let interactionView: LiveCamInteractionView

    var apertureMask: LiveCamApertureMask {
        get { apertureView.apertureMask }
        set { apertureView.apertureMask = newValue }
    }

    private let apertureView: LiveCamApertureView

    init(
        frame: CGRect,
        contentView: NSView,
        apertureMask: LiveCamApertureMask? = nil,
        onEnterSpace: @escaping @MainActor () -> Void = {},
        onOpenPlayer: @escaping @MainActor () -> Void = {},
        onOpenSettings: @escaping @MainActor () -> Void = {},
        onPreviousTrack: @escaping @MainActor () -> Void = {},
        onTogglePlayback: @escaping @MainActor () -> Void = {},
        onNextTrack: @escaping @MainActor () -> Void = {},
        playerMenuSnapshotProvider: @escaping @MainActor () -> LiveCamPlayerMenuSnapshot = {
            .noProgram
        },
        onSendMessage: @escaping @MainActor (String) -> Void = { _ in },
        onToggleVoice: @escaping @MainActor () -> Void = {}
    ) {
        self.onEnterSpace = onEnterSpace
        interactionView = LiveCamInteractionView(
            onOpenPlayer: onOpenPlayer,
            onOpenSettings: onOpenSettings,
            onPreviousTrack: onPreviousTrack,
            onTogglePlayback: onTogglePlayback,
            onNextTrack: onNextTrack,
            playerMenuSnapshotProvider: playerMenuSnapshotProvider,
            onSendMessage: onSendMessage,
            onToggleVoice: onToggleVoice
        )
        apertureView = LiveCamApertureView(
            frame: CGRect(origin: .zero, size: frame.size),
            contentView: contentView,
            interactionView: interactionView,
            apertureMask: apertureMask ?? .ellipse
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        apertureView.onEnterSpace = { [weak self] in
            self?.requestEnterSpace()
        }

        self.contentView = apertureView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        interactionView.onComposerVisibilityChanged = { [weak self] active in
            self?.setChatInputActive(active)
        }
    }

    override var canBecomeKey: Bool {
        chatInputActive
    }

    override var canBecomeMain: Bool {
        false
    }

    func requestEnterSpace() {
        onEnterSpace()
    }

    func setEnterSpaceHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        onEnterSpace = handler
    }

    func makePlayerMenu() -> NSMenu {
        interactionView.makePlayerMenu()
    }

    func setRotateHandler(
        _ handler: @escaping @MainActor (CGSize) -> Void
    ) {
        apertureView.onRotate = handler
    }

    func setMoveHandler(
        _ handler: @escaping @MainActor (
            CGSize,
            LiveCamWindowDragPhase
        ) -> Void
    ) {
        apertureView.onMove = handler
    }

    func setSendMessageHandler(
        _ handler: @escaping @MainActor (String) -> Void
    ) {
        interactionView.setSendMessageHandler(handler)
    }

    func setToggleVoiceHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        interactionView.setToggleVoiceHandler(handler)
    }

    func showAgentReply(_ text: String) {
        interactionView.showReply(text)
    }

    func showChatStatus(_ text: String) {
        interactionView.showChatStatus(text)
    }

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        interactionView.setVoiceState(state)
    }

    func closeChatComposer() {
        interactionView.closeComposer()
    }

    private func setChatInputActive(_ active: Bool) {
        chatInputActive = active
        if active {
            makeKeyAndOrderFront(nil)
            interactionView.focusComposer()
        } else if isKeyWindow {
            resignKey()
        }
    }
}

@MainActor
final class LiveCamApertureView: NSView {
    var apertureMask: LiveCamApertureMask {
        didSet {
            updateAperturePath()
        }
    }

    private let portalContentView: NSView
    private let interactionView: LiveCamInteractionView
    private let apertureLayer = CAShapeLayer()
    var onEnterSpace: @MainActor () -> Void = {}
    var onMove: @MainActor (
        CGSize,
        LiveCamWindowDragPhase
    ) -> Void = { _, _ in }
    var onRotate: @MainActor (CGSize) -> Void = { _ in }
    private var clickDownLocation: CGPoint?
    private var lastMoveScreenLocation: CGPoint?
    private var lastRotateScreenLocation: CGPoint?

    init(
        frame: CGRect,
        contentView: NSView,
        interactionView: LiveCamInteractionView,
        apertureMask: LiveCamApertureMask
    ) {
        portalContentView = contentView
        self.interactionView = interactionView
        self.apertureMask = apertureMask
        super.init(frame: frame)

        wantsLayer = true
        layer?.mask = apertureLayer
        apertureLayer.fillColor = NSColor.black.cgColor

        portalContentView.frame = bounds
        portalContentView.autoresizingMask = [.width, .height]
        addSubview(portalContentView)

        interactionView.frame = bounds
        interactionView.autoresizingMask = [.width, .height]
        addSubview(interactionView)

        let moveRecognizer = NSPanGestureRecognizer(
            target: self,
            action: #selector(handleMove(_:))
        )
        moveRecognizer.buttonMask = LiveCamPointerBinding.moveWindow.buttonMasks[0]
        addGestureRecognizer(moveRecognizer)
        updateAperturePath()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        portalContentView.frame = bounds
        interactionView.frame = bounds
        interactionView.layoutSubtreeIfNeeded()
        updateAperturePath()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }
        guard apertureMask.path(in: bounds).contains(point) else {
            return nil
        }
        let hit = super.hitTest(point)
        return hit === portalContentView ? self : hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        clickDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseUp(with: event)
            return
        }
        let downLocation = clickDownLocation
        clickDownLocation = nil
        let upLocation = convert(event.locationInWindow, from: nil)
        guard let downLocation else { return }
        let hitView = hitTest(downLocation)
        let acceptsBackdrop = hitView === self
            || (hitView.map { interactionView.isPassiveDecoration($0) } ?? false)
        guard LiveCamSpaceEntryPolicy.shouldEnterSpace(
            downLocation: downLocation,
            upLocation: upLocation,
            acceptsBackdropClick: acceptsBackdrop
        ) else {
            return
        }
        guard apertureMask.path(in: bounds).contains(upLocation) else {
            return
        }
        onEnterSpace()
    }

    override func rightMouseDown(with event: NSEvent) {
        beginCameraRotation(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        beginCameraRotation(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        continueCameraRotation(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        continueCameraRotation(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        endCameraRotation()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        endCameraRotation()
    }

    private func updateAperturePath() {
        apertureLayer.frame = bounds
        apertureLayer.path = apertureMask.path(in: bounds)
    }

    @objc
    private func handleMove(_ recognizer: NSPanGestureRecognizer) {
        let screenLocation: CGPoint
        if let window {
            screenLocation = window.convertPoint(
                toScreen: recognizer.location(in: nil)
            )
        } else {
            screenLocation = NSEvent.mouseLocation
        }
        switch recognizer.state {
        case .began:
            lastMoveScreenLocation = screenLocation
        case .changed:
            let translation = LiveCamWindowPointerDelta.resolve(
                previousScreenLocation: lastMoveScreenLocation,
                currentScreenLocation: screenLocation
            )
            lastMoveScreenLocation = screenLocation
            onMove(translation, .changed)
        case .ended:
            let translation = LiveCamWindowPointerDelta.resolve(
                previousScreenLocation: lastMoveScreenLocation,
                currentScreenLocation: screenLocation
            )
            lastMoveScreenLocation = nil
            onMove(translation, .ended)
        case .cancelled:
            lastMoveScreenLocation = nil
            onMove(.zero, .ended)
        default:
            return
        }
    }

    private func beginCameraRotation(with event: NSEvent) {
        lastRotateScreenLocation = screenLocation(for: event)
    }

    private func continueCameraRotation(with event: NSEvent) {
        let currentLocation = screenLocation(for: event)
        let translation = LiveCamWindowPointerDelta.resolve(
            previousScreenLocation: lastRotateScreenLocation,
            currentScreenLocation: currentLocation
        )
        lastRotateScreenLocation = currentLocation
        guard translation != .zero else { return }
        onRotate(translation)
    }

    private func endCameraRotation() {
        lastRotateScreenLocation = nil
    }

    private func screenLocation(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
