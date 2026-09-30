import AppKit
import CoreGraphics
import SwiftUI
import Observation

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
final class LiveCamInteractionView: NSView, NSTextFieldDelegate, NSGestureRecognizerDelegate {
    enum ReplyPresentation {
        case agentReply
        case chatStatus
    }

    let spaceButton = NSButton()
    let playerButton = NSButton()
    let chatButton = NSButton()
    let mailButton = ResidentSystemMailBadgeButton(identifier: "livecam.button.system-inbox")
    let voiceButton = NSButton()
    let settingsButton = NSButton()
    let messageField = ResidentAttachmentTextField()
    private let images = ResidentAttachmentStore()
    private var recovery = ResidentDraftRecovery()
    private let attachButton = NSButton()
    private var composerHeight: NSLayoutConstraint?
    let sendButton = NSButton()
    let stopButton = NSButton()
    private var residentThinking = false
    private var residentProgress: String?
    private var residentDeliveryMessage: String?
    private var residentStatusNotice: String?
    private var residentStatusKind: ResidentStatusNoticeKind = .info
    private var residentVoiceState = RealtimeVoiceConnectionState.disconnected
    private var residentCanStop = false
    private let wishMachineTasks = WishMachineTaskPresentationStore()
    private var systemInboxHandler: (@MainActor () -> Void)?

    private let controls = NSStackView()
    private let composer = NSVisualEffectView()
    private let replyBubble = NSVisualEffectView()
    private let replyLabel = NSTextField(wrappingLabelWithString: "")
    private let replyDismissButton = NSButton()
    private let fullReplyScroll = NSScrollView()
    private let fullReplyText = NSTextView()
    private var compactReplyHeight: NSLayoutConstraint?
    private var expandedReplyHeight: NSLayoutConstraint?
    private var latestReplyText = ""
    private var replyDismissed = false
    /// 回复气泡的回合号：同一回合内重复观察同一文本保持去重（不撤销用户关闭），
    /// 新回合即使回复与上一回合完全相同也要重新显示，合法重复不被吞掉。
    private var replyTurn = 0
    private var latestReplyTurn = -1
    /// 最近对话快照（宿主持有的同一份数据）：展开聊天后按回合回看，绝不只留
    /// 最后一条；展示层只渲染，不做回合判定。
    private var residentTranscriptLines: [ResidentChatTranscriptLine] = []
    private let deliveryNotice = NSVisualEffectView()
    private let deliveryLabel = NSTextField(wrappingLabelWithString: "")
    private var deliveryHeight: NSLayoutConstraint?
    private var replyPresentation: ReplyPresentation?
    private var onEnterSpace: @MainActor () -> Void
    private var onOpenPlayer: @MainActor () -> Void
    private var onOpenSettings: @MainActor () -> Void
    private var onPreviousTrack: @MainActor () -> Void
    private var onTogglePlayback: @MainActor () -> Void
    private var onNextTrack: @MainActor () -> Void
    private var playerMenuSnapshotProvider: @MainActor () -> LiveCamPlayerMenuSnapshot
    private var onSendMessage: @MainActor (ResidentChatSubmission) -> Void
    private var onCancelMessage: @MainActor () -> Void = {}
    private var onToggleVoice: @MainActor () -> Void
    var onComposerVisibilityChanged: @MainActor (Bool) -> Void = { _ in }

    var isComposerVisible: Bool {
        !composer.isHidden
    }

    var replyText: String {
        latestReplyText
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
        onSendMessage: @escaping @MainActor (ResidentChatSubmission) -> Void = { _ in },
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
        observeSpeechPlayback()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func setSendMessageHandler(
        _ handler: @escaping @MainActor (ResidentChatSubmission) -> Void
    ) {
        onSendMessage = handler
    }

    func setToggleVoiceHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        onToggleVoice = handler
    }

    func setCancelMessageHandler(_ handler: @escaping @MainActor () -> Void) {
        onCancelMessage = handler
    }

    func setSystemInboxHandler(_ handler: @escaping @MainActor () -> Void) {
        systemInboxHandler = handler
        mailButton.setAction { [weak self] in self?.systemInboxHandler?() }
    }

    func setSystemInboxUnread(_ count: Int) {
        mailButton.setUnreadCount(count)
    }

    func setEnterSpaceHandler(_ handler: @escaping @MainActor () -> Void) {
        onEnterSpace = handler
    }

    func setResidentThinking(_ thinking: Bool) {
        let startsNewTurn = thinking && !residentThinking
        residentThinking = thinking
        if startsNewTurn {
            // 新回合：旧回合作废，回复气泡即使文本相同也要重新显示；旧失败提示
            // 也已由用户的新动作接手。
            replyTurn += 1
            residentStatusNotice = nil
            residentStatusKind = .info
        }
        if thinking {
            if residentProgress == nil { residentProgress = "等待居民回应…" }
        }
        if !thinking { residentProgress = nil }
        updateResidentStatusNotice()
        updateComposerActions()
    }

    func setResidentProgress(_ text: String?) {
        residentProgress = text
        updateResidentStatusNotice()
    }

    func setWishMachineTasks(_ tasks: [WishMachineTaskPresentation]) {
        wishMachineTasks.update(tasks)
    }

    /// 面板上的"恢复自动领取"动作接到宿主（不是模型工具）：解除不依赖措辞。
    func setWishContinuationResumeHandler(_ handler: @escaping (UUID) -> Void) {
        wishMachineTasks.onResumeAutomaticContinuation = handler
    }

    func setResidentCanStop(_ canStop: Bool) {
        residentCanStop = canStop
        updateComposerActions()
    }

    func setResidentDeliveryNotice(_ text: String?) {
        residentDeliveryMessage = text
        updateResidentStatusNotice()
    }

    /// 最近对话快照（宿主推送）：展开聊天后按回合可滚动回看发给居民的话、
    /// 较早的回复，以及明确的未送达/取消标记。
    func setResidentTranscript(_ lines: [ResidentChatTranscriptLine]) {
        residentTranscriptLines = lines
        updateReplyDisclosure()
    }

    /// 普通应用提示：不得覆盖尚未处理的失败或语音临时提示。
    func showChatStatus(_ text: String) {
        applyStatusNotice(text, kind: .info)
    }

    /// 语音连接/收音的临时提示；连接结论落地后可被 dismissVoiceStatus 清除。
    func showVoiceStatus(_ text: String) {
        applyStatusNotice(text, kind: .voice)
    }

    /// 失败提示走独立类别：后续普通应用信息不得把它盖掉。
    func showFailureStatus(_ text: String) {
        applyStatusNotice(text, kind: .failure)
    }

    /// 只清除语音临时提示，绝不抹掉真正的失败提示。
    func dismissVoiceStatus() {
        guard residentStatusKind == .voice else { return }
        applyStatusNotice(nil, kind: .info)
    }

    /// 换世界/换后端等上下文切换：清掉旧提示与旧进度，失败提示也不例外。
    func clearTransientStatus() {
        residentStatusNotice = nil
        residentStatusKind = .info
        residentProgress = nil
        updateResidentStatusNotice()
    }

    var residentStatusText: String? { residentStatusNotice }

    private func applyStatusNotice(_ text: String?, kind: ResidentStatusNoticeKind) {
        let decision = ResidentStatusNoticeMerge.resolve(
            incoming: text,
            kind: kind,
            current: residentStatusNotice,
            currentKind: residentStatusKind
        )
        residentStatusNotice = decision.text
        residentStatusKind = decision.kind
        updateResidentStatusNotice()
    }

    private func updateResidentStatusNotice() {
        var lines = [residentProgress, residentDeliveryMessage].compactMap { text -> String? in
            let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? nil : normalized
        }
        // 居民的"在想 / 在说"标在**进度那一行**上，符号取自与舞台头顶气泡、舞台状态行
        // 同一个来源（`ResidentStatusBadge`），所以三处不可能显示不同的符号。
        // `residentProgress` 非空时它的那一行必然排在 `lines[0]`（数组顺序 + compactMap
        // 保序），所以这里不会错标到投递提示上。
        let progressText = (residentProgress ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isSpeaking = AgentSpeechStatusStore.shared.isSpeaking
        if !progressText.isEmpty, !lines.isEmpty {
            lines[0] = ResidentStatusBadge.decorate(
                lines[0],
                isThinking: residentThinking,
                isSpeaking: isSpeaking
            )
        } else if isSpeaking {
            // 没在思考、只有语音在播（TTS 输出阶段）：这一行原本什么都不显示，
            // 用户看不出"它在说话"。
            lines.insert(ResidentStatusBadge.speakingLine, at: 0)
        }
        if let residentStatusNotice, !residentStatusNotice.isEmpty {
            lines.append("应用提示：" + residentStatusNotice)
        }
        let message = lines.joined(separator: "\n")
        deliveryLabel.stringValue = message
        deliveryLabel.toolTip = message
        deliveryNotice.isHidden = message.isEmpty
        updateDeliveryNoticeHeight()
    }

    /// 按真实排版宽度测量高度：多行失败提示（含自动换行）不再被固定行高裁掉。
    private func updateDeliveryNoticeHeight() {
        guard let deliveryHeight else { return }
        guard !deliveryLabel.stringValue.isEmpty else {
            deliveryHeight.constant = 0
            return
        }
        let available = deliveryNotice.bounds.width - 16
        guard available > 20 else {
            deliveryHeight.constant = 42
            return
        }
        let bounds = NSRect(x: 0, y: 0, width: available, height: .greatestFiniteMagnitude)
        let measured = deliveryLabel.cell?.cellSize(forBounds: bounds).height ?? 0
        let height = max(24, ceil(measured) + 16)
        if abs(deliveryHeight.constant - height) > 0.5 {
            deliveryHeight.constant = height
        }
    }

    override func layout() {
        super.layout()
        updateDeliveryNoticeHeight()
    }

    var residentDeliveryNotice: String { deliveryLabel.stringValue }

    private var canStopResident: Bool {
        residentThinking || AgentSpeechStatusStore.shared.isSpeaking || residentCanStop
    }

    private func observeSpeechPlayback() {
        updateComposerActions()
        withObservationTracking {
            _ = AgentSpeechStatusStore.shared.isSpeaking
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSpeechPlayback() }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        updateComposerActions()
    }

    private var hasDraft: Bool {
        !messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.attachments.isEmpty
    }

    private func updateComposerActions() {
        let speaking = AgentSpeechStatusStore.shared.isSpeaking
        let primaryStops = Self.composerPrimaryActionStops(
            isThinking: residentThinking,
            isSpeaking: speaking,
            hasDraft: hasDraft
        )
        let stopLabel = speaking ? "停止说话" : "停止当前任务"
        let label = primaryStops ? stopLabel : "发送消息"
        sendButton.image = NSImage(systemSymbolName: primaryStops ? "stop.fill" : "arrow.up", accessibilityDescription: label)
        sendButton.toolTip = label
        sendButton.setAccessibilityLabel(label)
        sendButton.title = primaryStops && speaking ? "停止说话" : ""
        sendButton.imagePosition = primaryStops && speaking ? .noImage : .imageOnly
        sendButton.isEnabled = primaryStops || (hasDraft && images.canSubmit)
        attachButton.isEnabled = !images.isPreparing && images.attachments.count < 4
        // 独立停止按钮：只要还有可停止的对象就保留明确入口；主按钮已经是停止时
        // 不重复显示。仅因自主生活开启的后台预算不会把主按钮变成停止。
        stopButton.isHidden = !canStopResident || primaryStops
        stopButton.toolTip = stopLabel
        stopButton.setAccessibilityLabel(stopLabel)
        stopButton.title = speaking ? "停止说话" : ""
        stopButton.imagePosition = speaking ? .noImage : .imageOnly
    }

    /// 纯决策：主（发送）按钮何时表示停止。
    ///
    /// 只有真正在进行的人类可见回合（思考中/说话中）才让主按钮变停止；仅因自主
    /// 生活开启的后台预算不改变主按钮语义，避免用户在空输入时点发送误停自主生活。
    static func composerPrimaryActionStops(
        isThinking: Bool,
        isSpeaking: Bool,
        hasDraft: Bool
    ) -> Bool {
        (isThinking || isSpeaking) && !hasDraft
    }

    func focusComposer() {
        guard isComposerVisible else { return }
        window?.makeFirstResponder(messageField)
    }

    func closeComposer() {
        guard isComposerVisible else { return }
        composer.isHidden = true
        updateReplyDisclosure()
        onComposerVisibilityChanged(false)
    }

    func showReply(_ text: String) {
        residentStatusNotice = nil
        residentStatusKind = .info
        updateResidentStatusNotice()
        show(text, as: .agentReply)
    }

    func dismissChatStatus() {
        residentStatusNotice = nil
        residentStatusKind = .info
        updateResidentStatusNotice()
    }

    private func show(_ text: String, as presentation: ReplyPresentation) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldPresentReply(
            normalized,
            as: presentation,
            latestText: latestReplyText,
            latestPresentation: replyPresentation,
            latestTurn: latestReplyTurn,
            currentTurn: replyTurn
        ) else { return }
        latestReplyText = normalized
        latestReplyTurn = replyTurn
        // 不再按 240 字静默截断：标签自身限制 3 行并在末尾显示省略号，
        // 完整文本始终保留在可展开的滚动视图里。
        replyDismissed = false
        replyPresentation = normalized.isEmpty ? nil : presentation
        updateReplyDisclosure()
    }

    /// 纯决策：同一回合内重复观察同一文本保持去重；新回合的相同回复必须重新显示。
    static func shouldPresentReply(
        _ text: String,
        as presentation: ReplyPresentation,
        latestText: String,
        latestPresentation: ReplyPresentation?,
        latestTurn: Int,
        currentTurn: Int
    ) -> Bool {
        text != latestText || latestPresentation != presentation || latestTurn != currentTurn
    }

    /// 展开后显示的完整记录：最近对话按回合拼接；后台/自驱回复不在历史里
    /// （或与历史最后一条不同）时单独追加，同一回合绝不重复显示。
    private var expandedReplyContent: String {
        let transcript = ResidentChatTranscriptLine.plainText(residentTranscriptLines)
        guard let standalone = ResidentChatTranscriptLine.standaloneReply(
            latestReplyText, in: residentTranscriptLines
        ) else { return transcript }
        return transcript.isEmpty ? standalone : transcript + "\n\n" + standalone
    }

    private func updateReplyDisclosure() {
        let expanded = isComposerVisible
        compactReplyHeight?.isActive = !expanded
        expandedReplyHeight?.isActive = expanded
        replyLabel.isHidden = expanded
        fullReplyScroll.isHidden = !expanded
        replyLabel.stringValue = latestReplyText
        fullReplyText.string = expandedReplyContent
        // 展开时以最近对话为准；收起时保持原有紧凑气泡（只显示最新回复），
        // 不因历史里有等待中的回合就露出空气泡。
        let hasContent = expanded ? !expandedReplyContent.isEmpty : !latestReplyText.isEmpty
        replyBubble.isHidden = !hasContent || (!expanded && replyDismissed)
    }

    @objc private func dismissReply() {
        replyDismissed = true
        replyBubble.isHidden = true
    }

    @objc private func openReply(_ gesture: NSClickGestureRecognizer) {
        guard !replyDismissButton.frame.contains(gesture.location(in: replyBubble)) else { return }
        composer.isHidden = false
        updateReplyDisclosure()
        onComposerVisibilityChanged(true)
        focusComposer()
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // A parent click recognizer otherwise delays/cancels the button's mouse
        // tracking before openReply's later location check can protect it.
        let point = replyDismissButton.convert(event.locationInWindow, from: nil)
        return replyDismissButton.isHidden || !replyDismissButton.bounds.contains(point)
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
        let changedVoiceState = state != residentVoiceState
        residentVoiceState = state
        switch state {
        case .connecting:
            break
        case .disconnected, .connected, .listening, .speaking, .failed:
            // 语音状态已改变：「正在连接/正在听」不再成立，清掉；重复的同一状态
            // 不清除，避免每次收音事件都闪掉 listening 提示。失败提示不受影响。
            if changedVoiceState { dismissVoiceStatus() }
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
            symbolName: "message",
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
            symbolName: "gearshape",
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
        controls.addArrangedSubview(mailButton)
        controls.addArrangedSubview(voiceButton)
        controls.addArrangedSubview(settingsButton)
        configureControlSurface(mailButton)
        mailButton.setIconStyle(pointSize: 16, color: .white)
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
        messageField.maximumNumberOfLines = 3
        messageField.usesSingleLineMode = false
        messageField.cell?.wraps = true
        messageField.cell?.isScrollable = false
        messageField.lineBreakMode = .byWordWrapping
        messageField.target = self
        messageField.action = #selector(submitMessage)
        messageField.delegate = self
        messageField.onPasteAttachment = { [weak self] in self?.images.paste(from: $0) ?? false }
        composer.addSubview(messageField)

        configureButton(attachButton, symbolName: "plus", label: "添加图片附件", identifier: "livecam.button.attach", action: #selector(chooseImages))
        composer.addSubview(attachButton)
        let imageStrip = NSHostingView(rootView: ResidentAttachmentStrip(store: images))
        imageStrip.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(imageStrip)
        images.onChange = { [weak self, weak imageStrip] in
            guard let self else { return }
            let hasImages = !images.attachments.isEmpty || images.isPreparing || images.errorMessage != nil
            imageStrip?.isHidden = !hasImages
            composerHeight?.constant = hasImages ? 140 : 70
            updateComposerActions()
        }
        imageStrip.isHidden = true
        composerHeight = composer.heightAnchor.constraint(equalToConstant: 70)
        composerHeight?.isActive = true
        NSLayoutConstraint.activate([
            attachButton.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 6),
            attachButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -6),
            attachButton.widthAnchor.constraint(equalToConstant: 26),
            attachButton.heightAnchor.constraint(equalToConstant: 30),
            imageStrip.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 10),
            imageStrip.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -10),
            imageStrip.topAnchor.constraint(equalTo: composer.topAnchor, constant: 7),
            imageStrip.bottomAnchor.constraint(lessThanOrEqualTo: composer.bottomAnchor, constant: -70),
        ])

        configureButton(
            sendButton,
            symbolName: "arrow.up",
            label: "发送",
            identifier: "livecam.button.send",
            action: #selector(performPrimaryAction)
        )
        configureButton(
            stopButton,
            symbolName: "stop.fill",
            label: "停止当前任务",
            identifier: "livecam.button.stop",
            action: #selector(stopResident)
        )
        let composerActions = NSStackView(views: [stopButton, sendButton])
        composerActions.orientation = .horizontal
        composerActions.spacing = 6
        composerActions.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(composerActions)
        updateComposerActions()

        configureGlass(deliveryNotice)
        deliveryNotice.isHidden = true
        addSubview(deliveryNotice)
        deliveryLabel.translatesAutoresizingMaskIntoConstraints = false
        deliveryLabel.font = .systemFont(ofSize: 10)
        deliveryLabel.textColor = .systemOrange
        deliveryLabel.maximumNumberOfLines = 0
        deliveryLabel.setAccessibilityIdentifier("livecam.resident-delivery-notice")
        deliveryNotice.addSubview(deliveryLabel)
        deliveryHeight = deliveryNotice.heightAnchor.constraint(equalToConstant: 0)
        deliveryHeight?.isActive = true

        configureGlass(replyBubble)
        replyBubble.identifier = NSUserInterfaceItemIdentifier("livecam.reply-bubble")
        replyBubble.toolTip = "点击查看最近对话"
        let openReplyGesture = NSClickGestureRecognizer(target: self, action: #selector(openReply(_:)))
        openReplyGesture.delegate = self
        replyBubble.addGestureRecognizer(openReplyGesture)
        replyBubble.isHidden = true
        addSubview(replyBubble)

        replyLabel.translatesAutoresizingMaskIntoConstraints = false
        replyLabel.font = .systemFont(ofSize: 12)
        replyLabel.textColor = .white
        replyLabel.maximumNumberOfLines = 3
        replyLabel.lineBreakMode = .byTruncatingTail
        replyBubble.addSubview(replyLabel)

        configureButton(replyDismissButton, symbolName: "xmark", label: "关闭回复气泡", identifier: "livecam.reply-dismiss", action: #selector(dismissReply))
        replyBubble.addSubview(replyDismissButton)
        fullReplyScroll.translatesAutoresizingMaskIntoConstraints = false
        fullReplyScroll.identifier = NSUserInterfaceItemIdentifier("livecam.full-reply")
        fullReplyScroll.hasVerticalScroller = true
        fullReplyScroll.drawsBackground = false
        fullReplyText.isEditable = false
        fullReplyText.isSelectable = true
        fullReplyText.drawsBackground = false
        fullReplyText.font = .systemFont(ofSize: 12)
        fullReplyText.textColor = .white
        fullReplyText.isVerticallyResizable = true
        fullReplyText.isHorizontallyResizable = false
        fullReplyText.autoresizingMask = [.width]
        fullReplyText.textContainer?.widthTracksTextView = true
        fullReplyScroll.documentView = fullReplyText
        fullReplyScroll.isHidden = true
        replyBubble.addSubview(fullReplyScroll)
        compactReplyHeight = replyBubble.heightAnchor.constraint(lessThanOrEqualToConstant: 74)
        compactReplyHeight?.isActive = true
        expandedReplyHeight = replyBubble.heightAnchor.constraint(equalToConstant: 136)
        expandedReplyHeight?.priority = .defaultHigh
        let replyWidth = replyBubble.widthAnchor.constraint(equalToConstant: 260)
        replyWidth.priority = .defaultHigh
        replyWidth.isActive = true

        let speechErrorNotice = NSHostingView(rootView: ResidentSpeechErrorNotice())
        speechErrorNotice.sizingOptions = [.intrinsicContentSize]
        speechErrorNotice.translatesAutoresizingMaskIntoConstraints = false
        speechErrorNotice.identifier = NSUserInterfaceItemIdentifier("livecam.speech-error")
        addSubview(speechErrorNotice)

        let wishTaskNotice = NSHostingView(rootView: WishMachineTaskStatusView(state: wishMachineTasks, maximumHeight: 20, compact: true))
        wishTaskNotice.sizingOptions = [.intrinsicContentSize]
        wishTaskNotice.translatesAutoresizingMaskIntoConstraints = false
        wishTaskNotice.identifier = NSUserInterfaceItemIdentifier("livecam.wish-tasks")
        addSubview(wishTaskNotice)

        NSLayoutConstraint.activate([
            speechErrorNotice.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            speechErrorNotice.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            speechErrorNotice.bottomAnchor.constraint(equalTo: deliveryNotice.topAnchor, constant: -8),
            deliveryNotice.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            deliveryNotice.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            deliveryNotice.bottomAnchor.constraint(equalTo: wishTaskNotice.topAnchor, constant: -6),
            wishTaskNotice.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            wishTaskNotice.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            wishTaskNotice.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
            deliveryLabel.leadingAnchor.constraint(equalTo: deliveryNotice.leadingAnchor, constant: 8),
            deliveryLabel.trailingAnchor.constraint(equalTo: deliveryNotice.trailingAnchor, constant: -8),
            deliveryLabel.centerYAnchor.constraint(equalTo: deliveryNotice.centerYAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.widthAnchor.constraint(equalToConstant: 30),
            controls.heightAnchor.constraint(equalToConstant:
                CGFloat(controls.arrangedSubviews.count) * 30
                + CGFloat(controls.arrangedSubviews.count - 1) * controls.spacing),
            spaceButton.widthAnchor.constraint(equalToConstant: 30),
            spaceButton.heightAnchor.constraint(equalToConstant: 30),
            playerButton.widthAnchor.constraint(equalToConstant: 30),
            playerButton.heightAnchor.constraint(equalToConstant: 30),
            chatButton.widthAnchor.constraint(equalToConstant: 30),
            chatButton.heightAnchor.constraint(equalToConstant: 30),
            mailButton.widthAnchor.constraint(equalToConstant: 30),
            mailButton.heightAnchor.constraint(equalToConstant: 30),
            voiceButton.widthAnchor.constraint(equalToConstant: 30),
            voiceButton.heightAnchor.constraint(equalToConstant: 30),
            settingsButton.widthAnchor.constraint(equalToConstant: 30),
            settingsButton.heightAnchor.constraint(equalToConstant: 30),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            messageField.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 6),
            messageField.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -12),
            messageField.heightAnchor.constraint(equalToConstant: 46),
            messageField.trailingAnchor.constraint(equalTo: composerActions.leadingAnchor, constant: -6),
            composerActions.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -6),
            composerActions.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -6),
            stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            stopButton.heightAnchor.constraint(equalToConstant: 30),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),

            replyBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            replyBubble.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            replyBubble.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            replyBubble.bottomAnchor.constraint(lessThanOrEqualTo: composer.topAnchor, constant: -8),
            replyBubble.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            replyLabel.leadingAnchor.constraint(equalTo: replyBubble.leadingAnchor, constant: 10),
            replyLabel.trailingAnchor.constraint(equalTo: replyDismissButton.leadingAnchor, constant: -5),
            replyLabel.topAnchor.constraint(equalTo: replyBubble.topAnchor, constant: 8),
            replyLabel.bottomAnchor.constraint(equalTo: replyBubble.bottomAnchor, constant: -8),
            replyDismissButton.topAnchor.constraint(equalTo: replyBubble.topAnchor, constant: 5),
            replyDismissButton.trailingAnchor.constraint(equalTo: replyBubble.trailingAnchor, constant: -5),
            replyDismissButton.widthAnchor.constraint(equalToConstant: 20),
            replyDismissButton.heightAnchor.constraint(equalToConstant: 20),
            fullReplyScroll.topAnchor.constraint(equalTo: replyDismissButton.bottomAnchor, constant: 2),
            fullReplyScroll.leadingAnchor.constraint(equalTo: replyBubble.leadingAnchor, constant: 8),
            fullReplyScroll.trailingAnchor.constraint(equalTo: replyBubble.trailingAnchor, constant: -8),
            fullReplyScroll.bottomAnchor.constraint(equalTo: replyBubble.bottomAnchor, constant: -8),
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
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.contentTintColor = .white
        button.toolTip = label
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        configureControlSurface(button)
    }

    private func configureControlSurface(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        view.layer?.cornerRadius = 15
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
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
        updateReplyDisclosure()
        let isVisible = !composer.isHidden
        onComposerVisibilityChanged(isVisible)
        if isVisible {
            focusComposer()
        }
    }

    @objc
    private func chooseImages() { images.chooseImages() }

    func restoreSubmission(_ submission: ResidentChatSubmission) {
        let recovered = recovery.restore(submission, text: messageField.stringValue, attachments: images.attachments)
        messageField.stringValue = recovered.text
        images.restore(recovered.attachments)
        composer.isHidden = false
        updateReplyDisclosure()
        onComposerVisibilityChanged(true)
        updateComposerActions()
    }

    @objc
    private func submitMessage() {
        guard ResidentTextInputPolicy.shouldSubmit(
            isComposing: messageField.isComposingText
        ) else { return }
        let message = messageField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard images.canSubmit, !message.isEmpty || !images.attachments.isEmpty else { return }
        let submission = ResidentChatSubmission(text: message, attachments: images.takeAttachments())
        messageField.stringValue = ""
        recovery = ResidentDraftRecovery()
        setResidentThinking(true)
        closeComposer()
        onSendMessage(submission)
    }

    @objc
    private func performPrimaryAction() {
        if canStopResident && !hasDraft { stopResident() }
        else { submitMessage() }
    }

    @objc
    private func stopResident() {
        if AgentSpeechStatusStore.shared.isSpeaking {
            AgentSpeechStatusStore.shared.stopSpeaking()
            return
        }
        setResidentThinking(false)
        onCancelMessage()
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
        onSendMessage: @escaping @MainActor (ResidentChatSubmission) -> Void = { _ in },
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
        interactionView.setEnterSpaceHandler { [weak self] in
            self?.requestEnterSpace()
        }

        contentMinSize = frame.size
        contentMaxSize = frame.size
        self.contentView = apertureView
        // NSHostingView can propagate its fitting size through the overlay and
        // shrink this borderless window despite contentMinSize/contentMaxSize.
        // The portal owns its viewport; chat content must fit inside it.
        NSLayoutConstraint.activate([
            apertureView.widthAnchor.constraint(equalToConstant: frame.width),
            apertureView.heightAnchor.constraint(equalToConstant: frame.height),
        ])
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
        _ handler: @escaping @MainActor (ResidentChatSubmission) -> Void
    ) {
        interactionView.setSendMessageHandler(handler)
    }

    func setToggleVoiceHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        interactionView.setToggleVoiceHandler(handler)
    }

    func setCancelMessageHandler(_ handler: @escaping @MainActor () -> Void) {
        interactionView.setCancelMessageHandler(handler)
    }

    func setResidentThinking(_ thinking: Bool) {
        interactionView.setResidentThinking(thinking)
    }

    func setResidentProgress(_ text: String?) {
        interactionView.setResidentProgress(text)
    }

    func setResidentCanStop(_ canStop: Bool) {
        interactionView.setResidentCanStop(canStop)
    }

    func setResidentDeliveryNotice(_ text: String?) {
        interactionView.setResidentDeliveryNotice(text)
    }

    func setResidentTranscript(_ lines: [ResidentChatTranscriptLine]) {
        interactionView.setResidentTranscript(lines)
    }

    func showAgentReply(_ text: String) {
        interactionView.showReply(text)
    }

    func showChatStatus(_ text: String) {
        interactionView.showChatStatus(text)
    }

    func showVoiceStatus(_ text: String) {
        interactionView.showVoiceStatus(text)
    }

    func showFailureStatus(_ text: String) {
        interactionView.showFailureStatus(text)
    }

    func clearTransientStatus() {
        interactionView.clearTransientStatus()
    }

    var residentStatusText: String? { interactionView.residentStatusText }

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
final class LiveCamApertureView: NSView, NSGestureRecognizerDelegate {
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
        moveRecognizer.delegate = self
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

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Dragging the resident moves the window; interacting with its controls
        // must keep the native button/text/scroll event stream intact.
        let point = convert(event.locationInWindow, from: nil)
        return interactionView.hitTest(point) == nil
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
