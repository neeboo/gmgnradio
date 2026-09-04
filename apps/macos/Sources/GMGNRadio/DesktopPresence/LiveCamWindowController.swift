import AppKit

enum LiveCamChatError: LocalizedError {
    case voiceSessionConnecting
    case voiceSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .voiceSessionConnecting:
            "Agent 还在连接，稍等一下再发送。"
        case .voiceSessionUnavailable:
            "先点麦克风连接 Agent，再发送文字。"
        }
    }
}

@MainActor
final class LiveCamWindowController: NSWindowController, NSWindowDelegate {
    private enum Constants {
        static let margin: CGFloat = 16
        static let snapDistance: CGFloat = 18
        static let savedDisplayID = "liveCam.displayID"
        static let savedOriginX = "liveCam.origin.x"
        static let savedOriginY = "liveCam.origin.y"
    }

    private let renderSurfaceController: StageRenderSurfaceController
    private let cameraCoordinator: StageCameraCoordinator
    private let shouldPresent: @MainActor () -> Bool
    private let defaults: UserDefaults
    private let surfaceContainer = NSView()
    private var onEnterSpace: @MainActor () -> Void
    private var onSendMessage: @MainActor (String) async throws -> Void
    private var onToggleVoice: @MainActor () -> Void
    private var isTransitioningToFullStage = false
    private var presentationRevision: UInt64 = 0
    private var agentReplyBuffer = ""

    init(
        renderSurfaceController: StageRenderSurfaceController,
        cameraCoordinator: StageCameraCoordinator,
        defaults: UserDefaults = .standard,
        frame: CGRect = CGRect(
            origin: CGPoint(x: 28, y: 112),
            size: LiveCamLayout.compactPortrait.size
        ),
        apertureMask: LiveCamApertureMask = .roundedRectangle(
            cornerRadius: LiveCamLayout.compactPortrait.cornerRadius
        ),
        voiceState: RealtimeVoiceConnectionState = .disconnected,
        shouldPresent: @escaping @MainActor () -> Bool = { true },
        onEnterSpace: @escaping @MainActor () -> Void = {},
        onOpenPlayer: @escaping @MainActor () -> Void = {},
        onOpenSettings: @escaping @MainActor () -> Void = {},
        onPreviousTrack: @escaping @MainActor () -> Void = {},
        onTogglePlayback: @escaping @MainActor () -> Void = {},
        onNextTrack: @escaping @MainActor () -> Void = {},
        playerMenuSnapshotProvider: @escaping @MainActor () -> LiveCamPlayerMenuSnapshot = {
            .noProgram
        },
        onSendMessage: @escaping @MainActor (String) async throws -> Void = { _ in },
        onToggleVoice: @escaping @MainActor () -> Void = {}
    ) {
        self.renderSurfaceController = renderSurfaceController
        self.cameraCoordinator = cameraCoordinator
        self.shouldPresent = shouldPresent
        self.defaults = defaults
        self.onEnterSpace = onEnterSpace
        self.onSendMessage = onSendMessage
        self.onToggleVoice = onToggleVoice

        surfaceContainer.wantsLayer = true
        surfaceContainer.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = LiveCamPanel(
            frame: Self.initialFrame(defaultFrame: frame, defaults: defaults),
            contentView: surfaceContainer,
            apertureMask: apertureMask,
            onOpenPlayer: onOpenPlayer,
            onOpenSettings: onOpenSettings,
            onPreviousTrack: onPreviousTrack,
            onTogglePlayback: onTogglePlayback,
            onNextTrack: onNextTrack,
            playerMenuSnapshotProvider: playerMenuSnapshotProvider
        )
        super.init(window: panel)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.setEnterSpaceHandler { [weak self] in
            self?.enterSpace()
        }
        panel.setRotateHandler { [weak self] translation in
            self?.rotateCamera(by: translation)
        }
        panel.setMoveHandler { [weak self] translation, phase in
            self?.moveWindow(by: translation, phase: phase)
        }
        panel.setSendMessageHandler { [weak self] message in
            self?.sendMessage(message)
        }
        panel.setToggleVoiceHandler { [weak self] in
            self?.onToggleVoice()
        }
        panel.setVoiceState(voiceState)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    func connect(
        to stageWindowController: StageWindowController,
        onEnterSpace: @escaping @MainActor () -> Void
    ) {
        self.onEnterSpace = onEnterSpace
        stageWindowController.setOnWillPresentSpaceHandler { [weak self] in
            self?.prepareForFullStagePresentation()
        }
        stageWindowController.setOnShowPlayerHandler { [weak self] in
            self?.show()
        }
        stageWindowController.setOnCloseHandler { [weak self] in
            self?.resumeAfterFullStageClosed()
        }
    }

    func show() {
        guard shouldPresent() else {
            hide()
            return
        }
        guard let panel = window as? LiveCamPanel else { return }
        presentationRevision &+= 1
        let revision = presentationRevision
        let needsFreshFrame = renderSurfaceController.owner != .liveCam
            || !panel.isVisible
        isTransitioningToFullStage = false
        if needsFreshFrame {
            panel.alphaValue = 0
        }
        cameraCoordinator.activateLiveCam()
        renderSurfaceController.attachToLiveCam(surfaceContainer)
        panel.orderFrontRegardless()
        renderSurfaceController.setOwnerVisibility(
            true,
            occluded: false,
            owner: .liveCam
        )
        guard needsFreshFrame else {
            panel.alphaValue = 1
            return
        }
        renderSurfaceController.onNextLiveCamFrame { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.presentationRevision == revision,
                  self.renderSurfaceController.owner == .liveCam,
                  panel.isVisible
            else {
                return
            }
            panel.alphaValue = 1
        }
    }

    func hide() {
        presentationRevision &+= 1
        (window as? LiveCamPanel)?.closeChatComposer()
        window?.alphaValue = 0
        renderSurfaceController.setOwnerVisibility(
            false,
            owner: .liveCam
        )
        renderSurfaceController.detach(from: .liveCam)
        window?.orderOut(nil)
    }

    func setLowPowerMode(_ enabled: Bool) {
        renderSurfaceController.setLiveCamQuality(enabled ? .low : .balanced)
    }

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        (window as? LiveCamPanel)?.setVoiceState(state)
    }

    func beginAgentReply() {
        agentReplyBuffer = ""
        (window as? LiveCamPanel)?.showAgentReply("…")
    }

    func appendAgentReply(_ delta: String) {
        agentReplyBuffer += delta
        (window as? LiveCamPanel)?.showAgentReply(agentReplyBuffer)
    }

    func finishAgentReply(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            agentReplyBuffer = normalized
        }
        (window as? LiveCamPanel)?.showAgentReply(agentReplyBuffer)
    }

    func showChatStatus(_ text: String) {
        (window as? LiveCamPanel)?.showChatStatus(text)
    }

    private func rotateCamera(by translation: CGSize) {
        let sensitivity: Float = 0.008
        renderSurfaceController.rotateLiveCam(
            deltaYaw: Float(-translation.width) * sensitivity,
            deltaPitch: Float(translation.height) * sensitivity
        )
    }

    private func moveWindow(
        by translation: CGSize,
        phase: LiveCamWindowDragPhase
    ) {
        guard let window else { return }
        let frame = LiveCamWindowMovementPolicy.frame(
            from: window.frame,
            translation: translation,
            phase: phase,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            margin: Constants.margin,
            snapDistance: Constants.snapDistance
        )
        window.setFrameOrigin(frame.origin)
    }

    func enterSpace() {
        guard !isTransitioningToFullStage else { return }
        prepareForFullStagePresentation()
        onEnterSpace()
    }

    func prepareForFullStagePresentation() {
        presentationRevision &+= 1
        isTransitioningToFullStage = true
        (window as? LiveCamPanel)?.closeChatComposer()
        renderSurfaceController.setOwnerVisibility(
            false,
            owner: .liveCam
        )
        window?.alphaValue = 0
        window?.orderOut(nil)
        renderSurfaceController.detach(from: .liveCam)
    }

    func resumeAfterFullStageClosed() {
        guard shouldPresent() else { return }
        guard isTransitioningToFullStage
                || renderSurfaceController.owner != .liveCam
        else {
            return
        }
        show()
    }

    override func close() {
        presentationRevision &+= 1
        (window as? LiveCamPanel)?.closeChatComposer()
        window?.alphaValue = 0
        renderSurfaceController.setOwnerVisibility(
            false,
            owner: .liveCam
        )
        renderSurfaceController.detach(from: .liveCam)
        super.close()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        updateVisibility(for: panel)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, let screen = window.screen else { return }
        defaults.set(Self.identifier(for: screen), forKey: Constants.savedDisplayID)
        defaults.set(window.frame.origin.x, forKey: Constants.savedOriginX)
        defaults.set(window.frame.origin.y, forKey: Constants.savedOriginY)
    }

    func windowWillClose(_ notification: Notification) {
        renderSurfaceController.setOwnerVisibility(
            false,
            owner: .liveCam
        )
        renderSurfaceController.detach(from: .liveCam)
    }

    private func updateVisibility(for panel: NSWindow) {
        let visible = panel.isVisible
        renderSurfaceController.setOwnerVisibility(
            visible,
            occluded: false,
            owner: .liveCam
        )
    }

    private func sendMessage(_ message: String) {
        showChatStatus("…")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await onSendMessage(message)
            } catch {
                showChatStatus(
                    (error as? LocalizedError)?.errorDescription
                        ?? "消息发送失败，请稍后再试。"
                )
            }
        }
    }

    private static func initialFrame(
        defaultFrame: CGRect,
        defaults: UserDefaults
    ) -> CGRect {
        let hasSavedOrigin = defaults.object(forKey: Constants.savedOriginX) != nil
            && defaults.object(forKey: Constants.savedOriginY) != nil
        guard hasSavedOrigin else { return defaultFrame }
        let displays = NSScreen.screens.map {
            DisplayFrame(id: identifier(for: $0), visibleFrame: $0.visibleFrame)
        }
        return WindowPlacement.restoredFrame(
            size: defaultFrame.size,
            displays: displays,
            savedDisplayID: defaults.string(forKey: Constants.savedDisplayID),
            savedOrigin: CGPoint(
                x: defaults.double(forKey: Constants.savedOriginX),
                y: defaults.double(forKey: Constants.savedOriginY)
            ),
            margin: Constants.margin
        )
    }

    private static func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = screen.deviceDescription[key] as? NSNumber
        return number?.stringValue ?? String(describing: screen.frame)
    }

}
