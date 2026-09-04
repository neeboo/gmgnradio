import AppKit
import CoreGraphics

enum LiveCamFeed: Equatable, Sendable {
    case virtualWorld
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

    let chatButton = NSButton()
    let voiceButton = NSButton()
    let messageField = NSTextField()
    let sendButton = NSButton()

    private let controls = NSStackView()
    private let composer = NSVisualEffectView()
    private let replyBubble = NSVisualEffectView()
    private let replyLabel = NSTextField(wrappingLabelWithString: "")
    private var replyPresentation: ReplyPresentation?
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
        onSendMessage: @escaping @MainActor (String) -> Void = { _ in },
        onToggleVoice: @escaping @MainActor () -> Void = {}
    ) {
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
            chatButton,
            symbolName: "message.fill",
            label: "文字聊天",
            action: #selector(toggleComposer)
        )
        configureButton(
            voiceButton,
            symbolName: "mic",
            label: "开始语音",
            action: #selector(toggleVoice)
        )

        controls.orientation = .vertical
        controls.spacing = 6
        controls.alignment = .centerX
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(chatButton)
        controls.addArrangedSubview(voiceButton)
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

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.widthAnchor.constraint(equalToConstant: 30),
            controls.heightAnchor.constraint(equalToConstant: 66),
            chatButton.widthAnchor.constraint(equalToConstant: 30),
            chatButton.heightAnchor.constraint(equalToConstant: 30),
            voiceButton.widthAnchor.constraint(equalToConstant: 30),
            voiceButton.heightAnchor.constraint(equalToConstant: 30),

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
    private var onOpenFullStage: @MainActor () -> Void
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
        onOpenFullStage: @escaping @MainActor () -> Void = {},
        onSendMessage: @escaping @MainActor (String) -> Void = { _ in },
        onToggleVoice: @escaping @MainActor () -> Void = {}
    ) {
        self.onOpenFullStage = onOpenFullStage
        interactionView = LiveCamInteractionView(
            onSendMessage: onSendMessage,
            onToggleVoice: onToggleVoice
        )
        apertureView = LiveCamApertureView(
            frame: CGRect(origin: .zero, size: frame.size),
            contentView: contentView,
            interactionView: interactionView,
            apertureMask: apertureMask ?? .ellipse,
            onDoubleClick: onOpenFullStage
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

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

    func requestOpenFullStage() {
        onOpenFullStage()
    }

    func setOpenFullStageHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        onOpenFullStage = handler
        apertureView.onDoubleClick = handler
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
    var onDoubleClick: @MainActor () -> Void
    var onMove: @MainActor (
        CGSize,
        LiveCamWindowDragPhase
    ) -> Void = { _, _ in }
    var onRotate: @MainActor (CGSize) -> Void = { _ in }
    private var lastMoveScreenLocation: CGPoint?
    private var lastRotateScreenLocation: CGPoint?

    init(
        frame: CGRect,
        contentView: NSView,
        interactionView: LiveCamInteractionView,
        apertureMask: LiveCamApertureMask,
        onDoubleClick: @escaping @MainActor () -> Void
    ) {
        portalContentView = contentView
        self.interactionView = interactionView
        self.apertureMask = apertureMask
        self.onDoubleClick = onDoubleClick
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

        let recognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleDoubleClick(_:))
        )
        recognizer.numberOfClicksRequired = 2
        recognizer.buttonMask = LiveCamPointerBinding.moveWindow.buttonMasks[0]
        addGestureRecognizer(recognizer)
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
    private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let location = recognizer.location(in: self)
        guard apertureMask.path(in: bounds).contains(location) else { return }
        onDoubleClick()
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
