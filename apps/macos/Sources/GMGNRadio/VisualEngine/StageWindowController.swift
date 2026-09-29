import AppKit
@preconcurrency import AVFoundation
import Combine
import os
import SwiftUI
import WorldRuntime

/// 「真正的输入框正在打字」——场景键盘/指针门禁的**判据本体**（全工程只有这一份）。
///
/// 判据 = first responder 真的是这个**输入框宿主**自己或它的后代。`NSTextView` 的 field editor
/// 走 `delegate`（它才是真正的宿主控件），所以两种形态都算。
///
/// **任意** `NSTextView` 不算：原来门禁读的是 `window?.firstResponder is NSTextView`，它只问
/// "焦点是不是落在某个文本视图上"，不问"是不是那个输入框"。舞台窗口里并不只有输入框里有文本
/// 视图（聊天输入框的 field editor、设置里的文本区、别处的只读 `NSTextView`…），任何一个拿到
/// 焦点都会被判成"用户在打字"，场景于是既不跟手也不收键。门禁的本意只有一条：
/// **用户在聊天输入框里打字时，场景别抢键盘/指针**（见 `residentComposerOwnsFirstResponder()`）。
@MainActor
func stageTextInputOwnsFocus(host: NSView?, firstResponder: AnyObject?) -> Bool {
    guard let host, let editor = firstResponder as? NSTextView else { return false }
    if editor.isDescendant(of: host) { return true }
    return (editor.delegate as? NSView)?.isDescendant(of: host) == true
}

@MainActor
final class StageWindowController: NSWindowController, NSWindowDelegate {
    fileprivate static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "StageWindowController"
    )

    private let audioFeatures: VisualAudioFeatureStore
    private let artwork: StageArtworkStore
    private let audioMonitor: (any VisualAudioMonitoring)?
    private let presentation: StagePresentationModel
    private let visualDirections: StageVisualDirectionStore
    private let videos: StageVideoPlaybackStore
    private let programStore: DJProgramStore
    private let libraryStore: SyncedMusicLibraryStore
    private let lyrics: StageLyricsStore
    private let spatialStage: SpatialStageStore
    private let marbleLibrary: MarbleWorldLibrary
    private let avatarRuntime: StageAvatarRuntimeStore
    private let renderSurfaceController: StageRenderSurfaceController
    private let cameraCoordinator: StageCameraCoordinator
    private let playbackPosition: @MainActor () -> TimeInterval
    private let onTogglePlayback: @MainActor () -> Void
    private let onPlayProgramTrack: @MainActor (String, Int) -> Void
    private let onPlayLibraryTrack: @MainActor (String, Int) -> Void
    private let onOpenLibraryPlaylist: @MainActor (String) -> Void
    private let onLoadMoreLibraryTracks: @MainActor (String) -> Void
    private let onPreviousTrack: @MainActor () -> Void
    private let onNextTrack: @MainActor () -> Void
    private let onReplanProgram: @MainActor () -> Void
    private let onToggleVoice: @MainActor () -> Void
    private let onRunActivity: @MainActor (String) -> Void
    private let onStopActivity: @MainActor () -> Void
    private let onManageAssets: @MainActor () -> Void
    private let onSendMessage: @MainActor (ResidentChatSubmission) async throws -> Void
    private let onCancelMessage: @MainActor () -> Void
    private let onOpenSystemInbox: @MainActor () -> Void
    private var systemInboxUnread = 0
    private let residentChat = StageResidentChatState()
    private let wishMachineTasks = WishMachineTaskPresentationStore()
    private let residentPropEditor = ResidentPropEditorState()

    /// 建造模式的光标回调，转发给交互视图。
    var onResidentPropGridCursor: ((SIMD2<Float>) -> Void)? {
        didSet { stageContentView?.onGridCursor = onResidentPropGridCursor }
    }

    /// 建造模式「点一下落地」的回调，转发给交互视图。参数与 `onResidentPropGridCursor`
    /// 同一套约定：**归一化、左上原点**，与 `PropSupportGridPicker` 一致。
    var onResidentPropGridCommit: ((SIMD2<Float>) -> Void)? {
        didSet { stageContentView?.onGridCommit = onResidentPropGridCommit }
    }

    var onResidentPropGridRotate: ((Int) -> Void)? {
        didSet { stageContentView?.onGridRotate = onResidentPropGridRotate }
    }

    /// 建造模式：**空手**时在场景里点了一下（归一化、左上原点、`clickCount`）。
    ///
    /// 与 `onResidentPropGridCommit`（手上有物件时的落地）分成两条是刻意的：分流规则只有
    /// 一份（`ResidentPropSceneClick.resolve`），而"手上有没有物件"由本视图判定 ——
    /// 于是"点已摆物件 = 拾取"和"点地 = 放下"不可能互相吃掉。
    var onResidentPropScenePick: ((SIMD2<Float>, Int) -> Void)? {
        didSet { stageContentView?.onScenePick = onResidentPropScenePick }
    }

    /// 鼠标此刻是不是"手上拿着物件"（场景拾取/落地分流要读它）。
    var isResidentPropCarrying: Bool {
        residentPropEditor.isCarrying
    }

    /// 场景里**空手**点中一件已摆物件：等价于点面板里那一行（同一条 `select(objectID:)`）。
    func selectResidentPropFromScene(objectID: String) async {
        await residentPropEditor.select(objectID: objectID)
    }

    /// 宿主真的派发了一次"场景里拾起"：让交互视图知道双击的第二下该撤回谁。
    func noteResidentPropScenePickUp() {
        stageContentView?.noteScenePickUp()
    }

    /// 建造模式：把预览挪到吸附后的格心（层名 + footprint 朝向）。
    func moveResidentPropGridPointer(to position: WorldVector3, layerName: String, yaw: Float) async {
        await residentPropEditor.moveGridPointer(to: position, layerName: layerName, yaw: yaw)
    }

    /// 建造模式：把预览挪到吸附后的格心，然后**立刻落地**。
    ///
    /// 与 `moveResidentPropGridPointer` 分成两个入口是刻意的。悬停推送走
    /// `publishResidentPropGrid` 的防抖路径（同一个格心不重复推），点击不能借用它：
    /// 鼠标停在原地点击时格子没变，那条路径会直接跳过推送。点击必须自己
    /// **按顺序 await**「挪 + 确认」，否则会落在上一个格心（甚至什么都不发生）。
    ///
    /// `canConfirm` 是 internal（`ResidentPropEditorState` 同模块），此处直接可用。
    func moveAndConfirmResidentPropGridPointer(
        to position: WorldVector3,
        layerName: String,
        yaw: Float
    ) async {
        await residentPropEditor.moveGridPointer(to: position, layerName: layerName, yaw: yaw)
        if residentPropEditor.canConfirm { await residentPropEditor.confirm() }
    }

    /// 建造模式算 footprint 用的物件尺寸：优先"正在拖动/待确认"的那个，否则用选中的。
    /// 没有选中任何物件时返回 nil，调用方退回"一格"的 footprint。
    /// 推导只有一份（`ResidentPropEditorState.footprint`）：场景内旋转手柄也要用它。
    var residentPropFootprint: (size: SIMD2<Float>, height: Float)? {
        residentPropEditor.footprint
    }
    private var playbackState: LocalMusicPlaybackState
    private var voiceState: RealtimeVoiceConnectionState
    private weak var stageContentView: StageContentView?
    private var onWillPresentSpaceHandler: (@MainActor () -> Void)?
    private var onShowPlayerHandler: (@MainActor () -> Void)?
    private var onCloseHandler: (@MainActor () -> Void)?
    private var didHandleCurrentClose = false

    init(
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore = StageArtworkStore(),
        audioMonitor: (any VisualAudioMonitoring)? = nil,
        presentation: StagePresentationModel = StagePresentationModel(),
        visualDirections: StageVisualDirectionStore = StageVisualDirectionStore(),
        videos: StageVideoPlaybackStore = StageVideoPlaybackStore(),
        programStore: DJProgramStore = .shared,
        libraryStore: SyncedMusicLibraryStore = .shared,
        lyrics: StageLyricsStore = .shared,
        spatialStage: SpatialStageStore = SpatialStageStore(),
        marbleLibrary: MarbleWorldLibrary? = nil,
        avatarRuntime: StageAvatarRuntimeStore = .shared,
        renderSurfaceController: StageRenderSurfaceController? = nil,
        cameraCoordinator: StageCameraCoordinator? = nil,
        playbackPosition: @escaping @MainActor () -> TimeInterval = { 0 },
        playbackState: LocalMusicPlaybackState = .idle,
        voiceState: RealtimeVoiceConnectionState = .disconnected,
        onTogglePlayback: @escaping @MainActor () -> Void = {},
        onPlayProgramTrack:
            @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onPlayLibraryTrack:
            @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onOpenLibraryPlaylist:
            @escaping @MainActor (String) -> Void = { _ in },
        onLoadMoreLibraryTracks:
            @escaping @MainActor (String) -> Void = { _ in },
        onPreviousTrack: @escaping @MainActor () -> Void = {},
        onNextTrack: @escaping @MainActor () -> Void = {},
        onReplanProgram: @escaping @MainActor () -> Void = {},
        onToggleVoice: @escaping @MainActor () -> Void = {},
        onRunActivity: @escaping @MainActor (String) -> Void = { _ in },
        onStopActivity: @escaping @MainActor () -> Void = {},
        onManageAssets: @escaping @MainActor () -> Void = {},
        onSendMessage: @escaping @MainActor (ResidentChatSubmission) async throws -> Void = { _ in },
        onCancelMessage: @escaping @MainActor () -> Void = {},
        onOpenSystemInbox: @escaping @MainActor () -> Void = {}
    ) {
        self.audioFeatures = audioFeatures
        self.artwork = artwork
        self.audioMonitor = audioMonitor
        self.presentation = presentation
        self.visualDirections = visualDirections
        self.videos = videos
        self.programStore = programStore
        self.libraryStore = libraryStore
        self.lyrics = lyrics
        self.spatialStage = spatialStage
        let resolvedMarbleLibrary = marbleLibrary
            ?? MarbleWorldLibrary(spatialStage: spatialStage)
        self.marbleLibrary = resolvedMarbleLibrary
        self.avatarRuntime = avatarRuntime
        self.renderSurfaceController = renderSurfaceController
            ?? StageRenderSurfaceController(
                spatialStage: spatialStage,
                library: resolvedMarbleLibrary,
                avatarRuntime: avatarRuntime
            )
        self.cameraCoordinator = cameraCoordinator
            ?? StageCameraCoordinator(spatialStage: spatialStage)
        self.playbackPosition = playbackPosition
        self.playbackState = playbackState
        self.voiceState = voiceState
        self.onTogglePlayback = onTogglePlayback
        self.onPlayProgramTrack = onPlayProgramTrack
        self.onPlayLibraryTrack = onPlayLibraryTrack
        self.onOpenLibraryPlaylist = onOpenLibraryPlaylist
        self.onLoadMoreLibraryTracks = onLoadMoreLibraryTracks
        self.onPreviousTrack = onPreviousTrack
        self.onNextTrack = onNextTrack
        self.onReplanProgram = onReplanProgram
        self.onToggleVoice = onToggleVoice
        self.onRunActivity = onRunActivity
        self.onStopActivity = onStopActivity
        self.onManageAssets = onManageAssets
        self.onSendMessage = onSendMessage
        self.onCancelMessage = onCancelMessage
        self.onOpenSystemInbox = onOpenSystemInbox
        residentChat.voiceActive = voiceState == .listening
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    func setOnCloseHandler(_ handler: (@MainActor () -> Void)?) {
        onCloseHandler = handler
    }

    func configureResidentPropEditor(
        preview: @escaping @MainActor (String, WorldPropPlacement) async throws -> WorldObjectState,
        commit: @escaping @MainActor (WorldPropLayoutCommand, UInt64, String) async throws -> ResidentPropEditorSnapshot,
        hold: (@MainActor (String, UInt64, String) async throws -> ResidentPropEditorSnapshot)? = nil,
        adjustHeldGrip: (@MainActor (String, WorldVector3, WorldQuaternion, UInt64, String) async throws -> ResidentPropEditorSnapshot)? = nil,
        returnHeld: (@MainActor (String, UInt64, String) async throws -> ResidentPropEditorSnapshot)? = nil,
        refreshSnapshot: (@MainActor () -> ResidentPropEditorSnapshot?)? = nil,
        onPreviewChanged: @escaping @MainActor (WorldObjectState?) -> Void,
        onEditingChanged: @escaping @MainActor (Bool) -> Void
    ) {
        residentPropEditor.preview = preview
        residentPropEditor.commit = commit
        residentPropEditor.hold = hold
        residentPropEditor.adjustHeldGrip = adjustHeldGrip
        residentPropEditor.returnHeld = returnHeld
        residentPropEditor.refreshSnapshot = refreshSnapshot
        residentPropEditor.onPreviewChanged = onPreviewChanged
        residentPropEditor.onEditingChanged = onEditingChanged
    }

    func updateResidentPropEditor(_ snapshot: ResidentPropEditorSnapshot) {
        residentPropEditor.update(snapshot)
    }

    /// 菜单栏要读的装修状态：装修面板此刻是否打开。
    var isDecorationEditorOpen: Bool {
        residentPropEditor.isOpen
    }

    /// 菜单栏「装修空间 / 结束装修」的**窄入口**：只转交装修编辑器的开关，
    /// 不重排窗口生命周期（空间窗口的开/关仍由既有路径负责）。
    /// 空间还没呈现、世界快照还没到时由内容视图挂起意图，见 `StageContentView.toggleDecorationEditor()`。
    func toggleDecorationEditor() {
        stageContentView?.toggleDecorationEditor()
    }

    func setOnWillPresentSpaceHandler(_ handler: (@MainActor () -> Void)?) {
        onWillPresentSpaceHandler = handler
    }

    func setOnShowPlayerHandler(_ handler: (@MainActor () -> Void)?) {
        onShowPlayerHandler = handler
    }

    func setPlaybackState(_ state: LocalMusicPlaybackState) {
        playbackState = state
        stageContentView?.setPlaybackState(state)
    }

    func setVoiceState(_ state: RealtimeVoiceConnectionState) {
        let startsListening = state == .connecting && voiceState != .connecting
        let changed = state != voiceState
        voiceState = state
        residentChat.voiceActive = state == .listening
        stageContentView?.setVoiceState(state)
        if startsListening {
            residentChat.showVoiceStatus("正在连接语音转写…")
        } else if changed, state != .connecting {
            // 语音状态已改变：「正在连接/正在听」这类临时提示不再成立，清掉；
            // 真正的失败提示（failure 类别）不受影响。
            residentChat.dismissVoiceStatus()
        }
        let activity: StageAvatarActivity = switch state {
        case .listening:
            .listening
        case .speaking:
            .speaking
        case .disconnected, .connecting, .connected, .failed:
            .idle
        }
        avatarRuntime.setActivity(activity)
    }

    func beginResidentReply() {
        residentChat.begin()
        stageContentView?.showResidentChat()
    }
    func setResidentThinking(_ thinking: Bool, autoRevealsChat: Bool = true) {
        let startsNewTurn = thinking && !residentChat.isThinking
        residentChat.setThinking(thinking)
        // 后台/自驱回合不得抢开聊天或收起用户正在看的面板：状态照常更新，
        // 只有真正由用户发起的回合才自动展开。
        if startsNewTurn && autoRevealsChat { stageContentView?.showResidentChat() }
    }
    func setResidentProgress(_ text: String?) { residentChat.progress = text }
    func setWishMachineTasks(_ tasks: [WishMachineTaskPresentation]) { wishMachineTasks.update(tasks) }

    func setSystemInboxUnread(_ count: Int) {
        systemInboxUnread = count
        stageContentView?.setSystemInboxUnread(count)
    }
    func setResidentCanStop(_ canStop: Bool) { residentChat.canStop = canStop }
    func setResidentDeliveryNotice(_ text: String?) { residentChat.deliveryNotice = text }
    /// 最近对话快照（宿主推送）：按回合回看发给居民的话与较早的回复。
    func setResidentTranscript(_ lines: [ResidentChatTranscriptLine]) {
        residentChat.setTranscript(lines)
    }
    func finishResidentReply(_ text: String, autoRevealsChat: Bool = true) {
        residentChat.finish(text)
        if !text.isEmpty && autoRevealsChat { stageContentView?.showResidentChat() }
    }
    func showResidentChatStatus(_ text: String, autoRevealsChat: Bool = true) {
        residentChat.showStatus(text)
        if !text.isEmpty && autoRevealsChat { stageContentView?.showResidentChat() }
    }
    /// 失败提示走独立类别：后续普通应用信息不得把它盖掉。
    func showResidentFailureStatus(_ text: String, autoRevealsChat: Bool = false) {
        residentChat.showFailureStatus(text)
        if !text.isEmpty && autoRevealsChat { stageContentView?.showResidentChat() }
    }
    /// 语音连接/收音的临时提示（正在听等），连接结论落地后可被清除。
    func showResidentVoiceStatus(_ text: String) {
        residentChat.showVoiceStatus(text)
    }
    /// 换世界/换后端等上下文切换：清掉旧提示与旧进度，失败提示也不例外。
    func clearResidentTransientStatus() {
        residentChat.clearTransient()
    }
    var residentStatusText: String? { residentChat.statusNotice }
    func restoreResidentSubmission(_ submission: ResidentChatSubmission, notice: String) {
        residentChat.restore(submission, notice: notice)
        stageContentView?.showResidentChat()
    }

    func setVoiceLevel(_ level: Float) {
        avatarRuntime.setVoiceLevel(level)
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
        Self.log.notice(
            "Showing stage requested=\(self.spatialStage.isWorldPresentationRequested, privacy: .public) visible=\(self.spatialStage.isWorldVisible, privacy: .public)"
        )
        didHandleCurrentClose = false
        if spatialStage.isWorldPresentationRequested {
            onWillPresentSpaceHandler?()
            cameraCoordinator.activateFullStage(
                defaultCamera: SpatialWorldCalibration.resolve(
                    worldID: spatialStage.selectedWorldID
                )?.cameraHome
            )
        }
        if window == nil {
            window = makeWindow()
        }
        guard let window else {
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if spatialStage.isWorldPresentationRequested {
            stageContentView?.attachRenderSurface()
        } else {
            onShowPlayerHandler?()
        }
        updateRenderSurfaceVisibility(for: window)
        Self.log.notice(
            "Stage shown surfaceOwner=\(String(describing: self.renderSurfaceController.owner), privacy: .public) requested=\(self.spatialStage.isWorldPresentationRequested, privacy: .public) visible=\(self.spatialStage.isWorldVisible, privacy: .public)"
        )
        videos.resume()
        try? audioMonitor?.start()
    }

    override func close() {
        guard let window else {
            return
        }
        finishCurrentClose()
        window.delegate = nil
        window.close()
        self.window = nil
        stageContentView = nil
        videos.pause()
        audioMonitor?.stop()
        onCloseHandler?()
    }

    func windowWillClose(_ notification: Notification) {
        finishCurrentClose()
        window = nil
        stageContentView = nil
        videos.pause()
        audioMonitor?.stop()
        let handler = onCloseHandler
        Task { @MainActor in
            await Task.yield()
            handler?()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateRenderSurfaceVisibility(for: window)
    }

    /// 窗口失焦**不是**放弃编辑的意图，因此这里不关装修会话。
    ///
    /// 装修的"在手"状态只是一份**本地草稿**（`ResidentPropEditorState` 的 `placement` /
    /// `candidate`，`preview` 从不改世界），切到别的窗口去说话不构成"我放弃这次编辑"；
    /// The Sims 也不会因为切窗口就退出建造模式。
    ///
    /// 真机 2026-09-28 的阻塞缺陷正出在这里：用户只是「打开装修 → 点了一下物件那一行 →
    /// 切到别的窗口说话」，装修在打开 4.4 s 后自己退出了，而 Debug 构建下一次派生要 4.8 s ——
    /// 派生每次都被掐死、结果被丢弃，于是面板永远说"还在生成"、那一行永远点不动。
    ///
    /// 只有**明确**的关闭意图才结束会话，它们各有自己的入口：面板 X 与 `Esc` 链
    /// （`ResidentPropEditorState.escape()` / `close()`）、切换到别的面板（程序单 / 视觉选择 /
    /// 聊天）、切换空间或世界（`applySpatialPresentation`）、关窗（`windowWillClose` /
    /// `finishCurrentClose`）、退出空间。这里只留一条常驻诊断：真机上"装修为什么还开着/没了"
    /// 必须能一眼看出是失焦被保留，而不是没人接上。
    func windowDidResignKey(_ notification: Notification) {
        Self.log.notice(
            "装修：空间窗口失焦，保留装修会话与在手草稿（失焦不是放弃编辑）。editorOpen=\(self.residentPropEditor.isOpen, privacy: .public)"
        )
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
            libraryStore: libraryStore,
            lyrics: lyrics,
            spatialStage: spatialStage,
            marbleLibrary: marbleLibrary,
            avatarRuntime: avatarRuntime,
            renderSurfaceController: renderSurfaceController,
            playbackPosition: playbackPosition,
            playbackState: playbackState,
            voiceState: voiceState,
            onTogglePlayback: onTogglePlayback,
            onPlayProgramTrack: onPlayProgramTrack,
            onPlayLibraryTrack: onPlayLibraryTrack,
            onOpenLibraryPlaylist: onOpenLibraryPlaylist,
            onLoadMoreLibraryTracks: onLoadMoreLibraryTracks,
            onPreviousTrack: onPreviousTrack,
            onNextTrack: onNextTrack,
            onReplanProgram: onReplanProgram,
            onToggleVoice: onToggleVoice,
            onRunActivity: onRunActivity,
            onStopActivity: onStopActivity,
            onManageAssets: onManageAssets,
            residentChat: residentChat,
            wishMachineTasks: wishMachineTasks,
            residentPropEditor: residentPropEditor,
            onOpenSystemInbox: onOpenSystemInbox,
            onSendMessage: onSendMessage,
            onCancelMessage: onCancelMessage,
            onEnterSpace: { [weak self] in
                self?.onWillPresentSpaceHandler?()
            },
            onShowPlayer: { [weak self] in
                self?.onShowPlayerHandler?()
            },
            onToggleWindowMode: { [weak window] in
                window?.toggleFullScreen(nil)
            }
        )
        stageContentView = contentView
        contentView.setSystemInboxUnread(systemInboxUnread)
        window.contentView = contentView
        if residentChat.isThinking || residentChat.voiceActive || !residentChat.reply.isEmpty || residentChat.statusNotice != nil {
            contentView.showResidentChat()
        }
        window.center()
        return window
    }

    private func updateRenderSurfaceVisibility(for window: NSWindow) {
        renderSurfaceController.setOwnerVisibility(
            window.isVisible,
            occluded: StageWindowOcclusionPolicy.isOccluded(
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized
            ),
            owner: .fullStage
        )
    }

    private func finishCurrentClose() {
        guard !didHandleCurrentClose else { return }
        didHandleCurrentClose = true
        AgentSpeechStatusStore.shared.stopSpeaking()
        residentPropEditor.close()
        cameraCoordinator.captureUserCamera()
        renderSurfaceController.setOwnerVisibility(
            false,
            owner: .fullStage
        )
        renderSurfaceController.detach(from: .fullStage)
    }
}

struct StageSurfacePresentationState: Equatable {
    let isSpatialWorldHidden: Bool
    let isPointCloudHidden: Bool
    let isWorldInteractionHidden: Bool
    let isLoadingIndicatorHidden: Bool
    let isDestinationButtonHidden: Bool

    static func resolve(
        isWorldPresentationRequested: Bool,
        isWorldVisible: Bool
    ) -> Self {
        Self(
            isSpatialWorldHidden: !isWorldVisible,
            isPointCloudHidden: isWorldPresentationRequested,
            isWorldInteractionHidden: !isWorldVisible,
            isLoadingIndicatorHidden: !isWorldPresentationRequested
                || isWorldVisible,
            isDestinationButtonHidden: false
        )
    }
}

enum StageDestinationAction: Equatable {
    case enterSpace
    case showPlayer

    static func resolve(isWorldPresentationRequested: Bool) -> Self {
        isWorldPresentationRequested ? .showPlayer : .enterSpace
    }
}

struct StageDestinationContent: Equatable {
    let title: String
    let symbolName: String
    let accessibilityLabel: String
    let toolTip: String

    static func resolve(isWorldPresentationRequested: Bool) -> Self {
        if isWorldPresentationRequested {
            return Self(
                title: "播放器",
                symbolName: "circle.hexagongrid.fill",
                accessibilityLabel: "切换到播放器",
                toolTip: "返回播放器"
            )
        }
        return Self(
            title: "空间",
            symbolName: "cube.transparent",
            accessibilityLabel: "进入空间",
            toolTip: "进入空间"
        )
    }
}

struct StagePointerDragDelta: Equatable {
    let width: CGFloat
    let height: CGFloat

    static func resolve(
        previousLocation: CGPoint?,
        currentLocation: CGPoint,
        eventDelta: CGSize
    ) -> Self {
        guard let previousLocation else {
            return Self(
                width: eventDelta.width,
                height: eventDelta.height
            )
        }
        let locationWidth = currentLocation.x - previousLocation.x
        let locationHeight = previousLocation.y - currentLocation.y
        if abs(locationWidth) > 0.0001 || abs(locationHeight) > 0.0001 {
            return Self(width: locationWidth, height: locationHeight)
        }
        return Self(
            width: eventDelta.width,
            height: eventDelta.height
        )
    }
}

/// 场景内旋转手柄的**屏幕锚点**：投影后的 footprint 中心 + **固定屏幕空间偏移**。
///
/// **为什么必须是屏幕空间偏移**：偏移若落在世界空间（原先的做法是"沿 footprint 局部 +Z
/// 外扩 `max(0.35, 0.6 × 最大半宽)` 米"），投影到屏幕上就是 `外扩米数 / 相机距离` 量级 ——
/// 相机越近，手柄离光标越远（fov 66°、视口约 900 pt 时 32 pt 只覆盖 `0.046 × 相机距离`
/// 米），而吸附锚点跟着光标走，于是"光标每越过一格，手柄同步前进一格"，只有把镜头拉到
/// 4–7 m 以外才点得到。固定 pt 偏移与相机距离**无关**：任意距离、任意格子，圆环都贴在
/// footprint 中心投影点的右上侧同一个位置。
///
/// 偏移量的取值不是随手写的，它被两条约束夹住（见
/// `tools/test-stage-resident-chat.swift` 里"偏移与相机距离无关"的断言）：
/// 1. **必须大于命中半径 32 pt**（`StageWorldInteractionView.rotationHandleHitRadius`）：
///    否则圆环的命中区会盖住 hover 格的**格心**，"点一下落地"就会被误判成旋转。
///    所以 `hypot(screenOffsetX, screenOffsetY) ≈ 35.4 pt > 32 pt`。
/// 2. **每个分量都要落在 hover 格的投影范围内**：格心的吸附跟着光标走，光标从格心走向
///    圆环时只要跨过一列/一行，圆环就会跟着跳一格。0.25 m 的格子在 1440×900、fov 66°、
///    相机高 0.8 m、俯角 25° 时，地面 1.0/1.5/2.0/2.2/2.5 m 处的格子投影半宽×半深约为
///    70×38 / 51×21 / 40×14 / 37×12 / 33×9 pt，所以垂直分量尤其要小：地面平的深度轴在
///    屏幕上被俯角压扁，44 pt 这类垂直偏移在 ~0.85 m 之外就落到格子外面（原定的 48/44
///    就是这样）。34/10 到 ~2.2 m 为止都还在格子里；再远就需要更小的偏移，而更小的偏移
///    会掉进约束 1 的 32 pt 命中区 —— 这个分界是这套屏幕偏移机制的边界，不是靠调数字
///    绕得开的（`tools/test-stage-resident-chat.swift` 把 1.5 / 2.0 / 2.2 m 三档钉住了）。
enum ResidentPropRotationHandleAnchor {
    /// 相对 footprint 中心投影点的固定屏幕偏移，落在光标的右上侧（AppKit 点，y 轴向上为正）。
    static let screenOffsetX: CGFloat = 34
    static let screenOffsetY: CGFloat = 10
    static let screenOffset = CGPoint(x: screenOffsetX, y: screenOffsetY)

    /// 归一化（左上原点）投影点 → 视图坐标（左下原点）的手柄圆心。
    ///
    /// 纯函数：输入只有投影点与视图尺寸，**没有任何随相机距离缩放的量** —— 这正是
    /// "同一世界点在不同相机距离下，手柄屏幕偏移恒定"这条性质可以被离线断言的原因。
    static func center(projectedCenter: SIMD2<Float>, viewSize: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(projectedCenter.x) * viewSize.width + screenOffsetX,
            y: CGFloat(1 - projectedCenter.y) * viewSize.height + screenOffsetY
        )
    }
}

@MainActor
private final class StageContentView: NSView {
    /// 建造模式的光标回调，转给真正处理鼠标的交互视图。
    var onGridCursor: ((SIMD2<Float>) -> Void)? {
        didSet { worldInteractionView.onGridCursor = onGridCursor }
    }
    /// 建造模式「点一下落地」的回调，同样转给交互视图。
    var onGridCommit: ((SIMD2<Float>) -> Void)? {
        didSet { worldInteractionView.onGridCommit = onGridCommit }
    }
    var onGridRotate: ((Int) -> Void)? {
        didSet { worldInteractionView.onGridRotate = onGridRotate }
    }
    /// 建造模式：空手时在场景里点了一下（转给交互视图，与 `onGridCommit` 同一条出口口径）。
    var onScenePick: ((SIMD2<Float>, Int) -> Void)? {
        didSet { worldInteractionView.onScenePick = onScenePick }
    }

    /// 宿主真的派发了一次"场景里拾起"：转给交互视图（双击的第二下据此撤回它）。
    func noteScenePickUp() {
        worldInteractionView.noteResidentPropScenePickUp()
    }

    private let overlayState: StageOverlayState
    private let spatialStage: SpatialStageStore
    private let renderSurfaceController: StageRenderSurfaceController
    private let renderSurfaceContainer = StageRenderSurfaceHostingView()
    private let worldLoadingView = StageWorldLoadingView()
    private let worldInteractionView: StageWorldInteractionView
    private weak var metalView: MetalStageView?
    private var programRail: StageProgramRailHostingView!
    private var visualPicker: StageVisualPickerHostingView!
    private var transportControls: StageTransportControlsView!

    func setSystemInboxUnread(_ count: Int) {
        transportControls?.setSystemInboxUnread(count)
    }
    private var destinationButton: StageDestinationButton!
    private var residentComposer: NSHostingView<StageResidentComposer>!
    private let residentTaskFeedback: NSHostingView<WishMachineTaskStatusView>
    private let residentPropEditor: ResidentPropEditorState
    private var propEditorPanel: NSHostingView<ResidentPropEditorView>!
    private var editorVisibilitySubscription: AnyCancellable?
    private var editorSnapshotSubscription: AnyCancellable?
    /// 菜单栏「装修空间」在空间/世界快照还没就绪时挂起的意图。
    /// 不能静默丢弃：等既有的呈现回调或世界快照到达时补一次（见 `applyPendingDecorationEditorRequest()`）。
    private var pendingDecorationEditorRequest = false
    private var worldVisibilityObserverID: UUID?
    private var isProgramRailVisible = false
    private var isVisualPickerVisible = false
    private var isResidentChatExpanded = false
    /// 上一次为"输入框在打字"打过的门禁诊断 owner（同一条不重复打，见 `noteSceneInputGateBlocked()`）。
    private var lastLoggedSceneInputFocusOwner: String?

    init(
        frame: CGRect,
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore,
        presentation: StagePresentationModel,
        visualDirections: StageVisualDirectionStore,
        videos: StageVideoPlaybackStore,
        programStore: DJProgramStore,
        libraryStore: SyncedMusicLibraryStore,
        lyrics: StageLyricsStore,
        spatialStage: SpatialStageStore,
        marbleLibrary: MarbleWorldLibrary,
        avatarRuntime: StageAvatarRuntimeStore,
        renderSurfaceController: StageRenderSurfaceController,
        playbackPosition: @escaping @MainActor () -> TimeInterval,
        playbackState: LocalMusicPlaybackState,
        voiceState: RealtimeVoiceConnectionState,
        onTogglePlayback: @escaping @MainActor () -> Void,
        onPlayProgramTrack: @escaping @MainActor (String, Int) -> Void,
        onPlayLibraryTrack: @escaping @MainActor (String, Int) -> Void,
        onOpenLibraryPlaylist: @escaping @MainActor (String) -> Void,
        onLoadMoreLibraryTracks: @escaping @MainActor (String) -> Void,
        onPreviousTrack: @escaping @MainActor () -> Void,
        onNextTrack: @escaping @MainActor () -> Void,
        onReplanProgram: @escaping @MainActor () -> Void,
        onToggleVoice: @escaping @MainActor () -> Void,
        onRunActivity: @escaping @MainActor (String) -> Void,
        onStopActivity: @escaping @MainActor () -> Void,
        onManageAssets: @escaping @MainActor () -> Void,
        residentChat: StageResidentChatState,
        wishMachineTasks: WishMachineTaskPresentationStore,
        residentPropEditor: ResidentPropEditorState,
        onOpenSystemInbox: @escaping @MainActor () -> Void,
        onSendMessage: @escaping @MainActor (ResidentChatSubmission) async throws -> Void,
        onCancelMessage: @escaping @MainActor () -> Void,
        onEnterSpace: @escaping @MainActor () -> Void,
        onShowPlayer: @escaping @MainActor () -> Void,
        onToggleWindowMode: @escaping @MainActor () -> Void
    ) {
        overlayState = StageOverlayState()
        self.spatialStage = spatialStage
        self.renderSurfaceController = renderSurfaceController
        self.residentPropEditor = residentPropEditor
        residentTaskFeedback = NSHostingView(rootView: WishMachineTaskStatusView(state: wishMachineTasks))
        worldInteractionView = StageWorldInteractionView(
            spatialStage: spatialStage,
            propEditor: residentPropEditor
        )
        super.init(frame: frame)

        let programButton = StageProgramButton { [weak self] in
            self?.toggleProgramRail()
        }
        let programSelection = StageProgramRailSelection(
            onPlay: onPlayProgramTrack,
            onPlayPlaylist: onPlayLibraryTrack,
            onOpenPlaylist: onOpenLibraryPlaylist,
            onLoadMorePlaylist: onLoadMoreLibraryTracks,
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
        let chatButton = StageResidentChatButton { [weak self] in
            self?.toggleResidentChat()
        }
        let systemInboxButton = ResidentSystemMailBadgeButton(
            identifier: "stage.system-inbox-toggle",
            action: onOpenSystemInbox
        )
        let propEditorButton = StagePropEditorButton { [weak self] in self?.togglePropEditor() }
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
            chatButton: chatButton,
            systemInboxButton: systemInboxButton,
            propEditorButton: propEditorButton,
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

        renderSurfaceContainer.frame = bounds
        renderSurfaceContainer.identifier = NSUserInterfaceItemIdentifier(
            "stage.shared-render-surface-container"
        )
        renderSurfaceContainer.autoresizingMask = [.width, .height]
        renderSurfaceContainer.wantsLayer = true
        renderSurfaceContainer.layer?.zPosition = 1.5
        addSubview(renderSurfaceContainer)

        let metalView = MetalStageView(
            frame: bounds,
            audioFeatures: audioFeatures,
            artwork: artwork,
            visualDirections: visualDirections,
            videos: videos,
            spatialStage: spatialStage
        )
        metalView.autoresizingMask = [.width, .height]
        metalView.identifier = NSUserInterfaceItemIdentifier(
            "stage.metal-particles"
        )
        metalView.wantsLayer = true
        metalView.layer?.zPosition = 1
        addSubview(metalView)
        self.metalView = metalView

        worldLoadingView.frame = bounds
        worldLoadingView.autoresizingMask = [.width, .height]
        worldLoadingView.layer?.zPosition = 5
        worldLoadingView.isHidden = true
        addSubview(worldLoadingView)

        let environmentEffects = StageEnvironmentHostingView(
            rootView: SpatialEnvironmentEffectsView(
                spatialStage: spatialStage
            )
        )
        environmentEffects.frame = bounds
        environmentEffects.autoresizingMask = [.width, .height]
        environmentEffects.wantsLayer = true
        environmentEffects.layer?.zPosition = 2
        addSubview(environmentEffects)

        worldInteractionView.frame = bounds
        worldInteractionView.autoresizingMask = [.width, .height]
        worldInteractionView.identifier = NSUserInterfaceItemIdentifier(
            "stage.world-interaction"
        )
        worldInteractionView.isHidden = true
        // 场景内的旋转手柄就画在这个视图里（`StageWorldInteractionView.draw(_:)`），因为
        // 它本来就是指针的唯一所有者 —— 画与命中判定同类型、同坐标系。兄弟视图全都用
        // layer.zPosition 排层（世界 1.5 / 环境特效 2 / 加载 5 / 面板 10+），而这里原先
        // 没设 wantsLayer：layer-backed 混排下 `draw(_:)` 会被 Metal 世界整块盖住。
        // 见 `docs/plans/2026-09-28-decoration-in-space-interaction.md` 真机验证项 2 的退路。
        worldInteractionView.wantsLayer = true
        worldInteractionView.layer?.zPosition = 6
        addSubview(worldInteractionView)

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
                libraryStore: libraryStore,
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
                programStore: programStore,
                spatialStage: spatialStage,
                marbleLibrary: marbleLibrary,
                avatarRuntime: avatarRuntime,
                onRunActivity: onRunActivity,
                onStopActivity: onStopActivity,
                onManageAssets: onManageAssets
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

        residentComposer = NSHostingView(rootView: StageResidentComposer(
            state: residentChat,
            onSendMessage: onSendMessage,
            onCancelMessage: onCancelMessage,
            onToggleVoice: onToggleVoice,
            onFocusInput: { [spatialStage] in
                spatialStage.clearMovement()
                spatialStage.setSpeedBoosted(false)
            }
        ))
        residentComposer.identifier = NSUserInterfaceItemIdentifier("stage.resident-chat")
        residentComposer.translatesAutoresizingMaskIntoConstraints = false
        residentComposer.wantsLayer = true
        residentComposer.layer?.zPosition = 17
        residentComposer.isHidden = true
        addSubview(residentComposer)

        residentTaskFeedback.sizingOptions = [.intrinsicContentSize]
        residentTaskFeedback.translatesAutoresizingMaskIntoConstraints = false
        residentTaskFeedback.wantsLayer = true
        residentTaskFeedback.layer?.zPosition = 18
        residentTaskFeedback.isHidden = !spatialStage.isWorldPresentationRequested
        addSubview(residentTaskFeedback)

        propEditorPanel = NSHostingView(rootView: ResidentPropEditorView(state: residentPropEditor))
        propEditorPanel.identifier = NSUserInterfaceItemIdentifier("stage.prop-editor")
        propEditorPanel.translatesAutoresizingMaskIntoConstraints = false
        propEditorPanel.wantsLayer = true
        propEditorPanel.layer?.zPosition = 19
        propEditorPanel.isHidden = true
        addSubview(propEditorPanel)
        // responder 相关的两处接线在这一处收口（门禁判据 + 面板动作后的焦点交回）。
        wireSceneInputOwnership()
        editorVisibilitySubscription = residentPropEditor.$isOpen.sink { [weak self] open in
            self?.propEditorPanel.isHidden = !open
            self?.transportControls.setPropEditorExpanded(open)
            if open {
                self?.pendingDecorationEditorRequest = false
                self?.spatialStage.clearMovement()
                self?.spatialStage.setSpeedBoosted(false)
            }
            // 菜单栏标题的唯一状态源：装修的每一次开/关都经过这里。
            StageDecorationMenuStore.shared.update(isDecorating: open)
        }
        // 世界快照是 `open()` 的前置条件（它要求非空 worldID）。快照迟到时补上挂起的装修意图。
        // `@Published` 在 willSet 发出，所以读值要放到下一拍。
        editorSnapshotSubscription = residentPropEditor.$snapshot.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPendingDecorationEditorRequest()
            }
        }

        destinationButton = StageDestinationButton { [spatialStage] in
            switch StageDestinationAction.resolve(
                isWorldPresentationRequested:
                    spatialStage.isWorldPresentationRequested
            ) {
            case .enterSpace:
                onEnterSpace()
                spatialStage.requestWorldPresentation()
            case .showPlayer:
                spatialStage.exitWorld()
                onShowPlayer()
            }
        }
        destinationButton.translatesAutoresizingMaskIntoConstraints = false
        destinationButton.layer?.zPosition = 21
        addSubview(destinationButton)

        let preferredPanelWidth = visualPicker.widthAnchor.constraint(
            equalToConstant: StageControlPanelLayout.maximumWidth
        )
        let preferredPanelHeight = visualPicker.heightAnchor.constraint(
            equalToConstant: StageControlPanelLayout.maximumHeight
        )
        preferredPanelWidth.priority = .defaultHigh
        preferredPanelHeight.priority = .defaultHigh
        let preferredComposerWidth = residentComposer.widthAnchor.constraint(equalToConstant: 620)
        preferredComposerWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            residentTaskFeedback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            residentTaskFeedback.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            residentTaskFeedback.widthAnchor.constraint(equalToConstant: 280),
            propEditorPanel.trailingAnchor.constraint(equalTo: transportControls.trailingAnchor),
            propEditorPanel.bottomAnchor.constraint(equalTo: transportControls.topAnchor, constant: -12),
            propEditorPanel.widthAnchor.constraint(equalToConstant: 340),
            propEditorPanel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            residentComposer.trailingAnchor.constraint(equalTo: transportControls.trailingAnchor),
            residentComposer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 22),
            residentComposer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
            residentComposer.bottomAnchor.constraint(equalTo: transportControls.topAnchor, constant: -16),
            residentComposer.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
            residentComposer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 22),
            preferredComposerWidth,
            transportControls.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -22
            ),
            transportControls.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -22
            ),
            transportControls.widthAnchor.constraint(equalToConstant: StageControlPanelLayout.transportWidth + StageControlPanelLayout.controlSize),
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
            visualPicker.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            visualPicker.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            visualPicker.widthAnchor.constraint(lessThanOrEqualToConstant: StageControlPanelLayout.maximumWidth),
            visualPicker.heightAnchor.constraint(lessThanOrEqualToConstant: StageControlPanelLayout.maximumHeight),
            preferredPanelWidth,
            preferredPanelHeight,

            destinationButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -22
            ),
            destinationButton.topAnchor.constraint(
                equalTo: topAnchor,
                constant: 28
            ),
            destinationButton.widthAnchor.constraint(
                equalToConstant: 112
            ),
            destinationButton.heightAnchor.constraint(
                equalToConstant: 38
            )
        ])
        destinationButton.apply(
            StageDestinationContent.resolve(
                isWorldPresentationRequested:
                    spatialStage.isWorldPresentationRequested
            )
        )

        startObservingSpatialPresentation()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            spatialStage.removeWorldVisibilityObserver(
                worldVisibilityObserverID
            )
            worldVisibilityObserverID = nil
        } else {
            startObservingSpatialPresentation()
        }
        super.viewWillMove(toWindow: newWindow)
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
        residentPropEditor.close()
        isProgramRailVisible.toggle()
        if isProgramRailVisible {
            isResidentChatExpanded = false
            isVisualPickerVisible = false
            visualPicker.isHidden = true
            transportControls.setVisualPickerExpanded(false)
        }
        programRail.isHidden = !isProgramRailVisible
        transportControls.setProgramRailExpanded(isProgramRailVisible)
        overlayState.setProgramRailVisible(isProgramRailVisible)
        updateResidentComposerVisibility()
    }

    private func toggleVisualPicker() {
        residentPropEditor.close()
        isVisualPickerVisible.toggle()
        if isVisualPickerVisible {
            isResidentChatExpanded = false
            isProgramRailVisible = false
            programRail.isHidden = true
            transportControls.setProgramRailExpanded(false)
            overlayState.setProgramRailVisible(false)
        }
        visualPicker.isHidden = !isVisualPickerVisible
        transportControls.setVisualPickerExpanded(isVisualPickerVisible)
        updateResidentComposerVisibility()
    }

    private func toggleResidentChat() {
        residentPropEditor.close()
        guard spatialStage.isWorldPresentationRequested else { return }
        isResidentChatExpanded.toggle()
        if isResidentChatExpanded {
            isProgramRailVisible = false
            isVisualPickerVisible = false
            programRail.isHidden = true
            visualPicker.isHidden = true
            transportControls.setProgramRailExpanded(false)
            transportControls.setVisualPickerExpanded(false)
            overlayState.setProgramRailVisible(false)
        }
        updateResidentComposerVisibility()
    }

    func showResidentChat() {
        // Feedback may arrive while another surface owns focus or an edit is in progress.
        // Keep the edit intact and reveal the existing composer without moving keyboard focus.
        guard spatialStage.isWorldPresentationRequested, !residentPropEditor.isOpen else { return }
        isResidentChatExpanded = true
        isProgramRailVisible = false
        isVisualPickerVisible = false
        programRail.isHidden = true
        visualPicker.isHidden = true
        transportControls.setProgramRailExpanded(false)
        transportControls.setVisualPickerExpanded(false)
        overlayState.setProgramRailVisible(false)
        updateResidentComposerVisibility()
    }

    private func togglePropEditor() {
        guard spatialStage.isWorldPresentationRequested else { return }
        if residentPropEditor.isOpen { residentPropEditor.close(); return }
        isResidentChatExpanded = false
        isProgramRailVisible = false
        isVisualPickerVisible = false
        programRail.isHidden = true
        visualPicker.isHidden = true
        transportControls.setProgramRailExpanded(false)
        transportControls.setVisualPickerExpanded(false)
        overlayState.setProgramRailVisible(false)
        updateResidentComposerVisibility()
        window?.makeFirstResponder(worldInteractionView)
        residentPropEditor.open()
    }

    /// 菜单栏「装修空间 / 结束装修」在空间内部的落地。
    ///
    /// 已在装修 → 只退出装修（`togglePropEditor()` 的关闭分支，空间窗口保持打开）。
    /// 未装修 → 先按进场路径开一次；没打开就**挂起意图**而不是静默返回，原因有两种：
    ///   1. 空间还没请求呈现（守卫失败）——由呈现回调 `applySpatialPresentation` 补；
    ///   2. 世界快照还没到（`open()` 要求非空 worldID）——由快照订阅补。
    func toggleDecorationEditor() {
        if residentPropEditor.isOpen {
            pendingDecorationEditorRequest = false
            togglePropEditor()
            return
        }
        togglePropEditor()
        if !residentPropEditor.isOpen {
            pendingDecorationEditorRequest = true
        }
    }

    /// 补上挂起的装修请求（菜单入口一步到位，不要求用户点第二次）。
    /// 快照/呈现还没就绪时**保留**挂起状态，等下一次既有回调。
    private func applyPendingDecorationEditorRequest() {
        guard pendingDecorationEditorRequest,
              spatialStage.isWorldPresentationRequested,
              !residentPropEditor.snapshot.worldID.isEmpty,
              !residentPropEditor.isOpen else { return }
        pendingDecorationEditorRequest = false
        togglePropEditor()
    }

    /// 「正在打字」的唯一判据：first responder 必须真的是 `residentComposer` 自己或它的后代。
    ///
    /// 判据本体在 `stageTextInputOwnsFocus(host:firstResponder:)`；这里只提供"谁是输入框宿主"。
    /// 装修门禁（`consumesPropPointer` / `keyDown`）与这里共用同一个判据，不各写一份。
    private func residentComposerOwnsFirstResponder() -> Bool {
        stageTextInputOwnsFocus(host: residentComposer, firstResponder: window?.firstResponder)
    }

    /// responder 相关的两处接线（只有这一处，两个方向不会分家）：
    ///
    /// 1. **门禁判据**：场景交互视图只认**真正的输入框**（`residentComposerOwnsFirstResponder()`），
    ///    不把任意 `NSTextView` 当成"正在打字"。原来的判据 `window?.firstResponder is NSTextView`
    ///    只问"焦点在不在某个文本视图上"，窗口里任何一个文本视图拿到焦点都会被误判成打字 ——
    ///    场景于是既不跟手也不收键，而用户其实只是在别处点了一下。
    /// 2. **焦点交回**：面板动作（`select` / `undo` / `withdraw`）做完之后，把键盘焦点交回场景
    ///    交互视图（`returnSceneFocus(trigger:)`，走既有的 `makeFirstResponder` 路径）。
    ///
    /// 接在这里而不是 `StageWindowController.configureResidentPropEditor`：那个入口只注入
    /// 预览/提交/手持这些**服务**回调，而这里要的是本视图拥有的场景交互视图。
    private func wireSceneInputOwnership() {
        worldInteractionView.isTextInputFocused = { [weak self] in
            guard let self, self.residentComposerOwnsFirstResponder() else { return false }
            self.noteSceneInputGateBlocked()
            return true
        }
        residentPropEditor.onSceneFocusRequested = { [weak self] trigger in
            self?.returnSceneFocus(trigger: trigger)
        }
    }

    /// 门禁被"正在打字"挡下时的诊断（`.notice`；同一条 owner 只报一次，鼠标每动一下不会刷屏）。
    ///
    /// 与 `returnSceneFocus(trigger:)` 那条配对看：真机上只要出现这条，就知道**是谁**挡住了
    /// 场景输入（owner 是 responder 的**动态类型**）—— 不必再猜。
    private func noteSceneInputGateBlocked() {
        let owner = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        guard lastLoggedSceneInputFocusOwner != owner else { return }
        lastLoggedSceneInputFocusOwner = owner
        StageWindowController.log.notice(
            "场景门禁：真正的输入框正在打字，场景不抢键盘/指针 owner=\(owner, privacy: .public)"
        )
    }

    /// **面板**动作结束后把键盘焦点交回场景交互视图。
    ///
    /// 走的是既有的 `makeFirstResponder(worldInteractionView)` 那条路径（与 `togglePropEditor()`
    /// 开面板时同一个出口），不新造机制。`.notice` 打出**交回前**的 owner，与门禁那条配对：
    /// 真机上"点完行之后焦点有没有回到场景"一眼可读。
    private func returnSceneFocus(trigger: String) {
        guard let window else { return }
        let before = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        window.makeFirstResponder(worldInteractionView)
        StageWindowController.log.notice(
            "摆放面板动作=\(trigger, privacy: .public) 焦点交回场景：交回前 owner=\(before, privacy: .public) 交回后 owner=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public)"
        )
    }

    private func updateResidentComposerVisibility() {
        let wasVisible = !residentComposer.isHidden
        let ownedFocus = residentComposerOwnsFirstResponder()
        if !spatialStage.isWorldPresentationRequested { isResidentChatExpanded = false }
        residentComposer.isHidden = !isResidentChatExpanded
            || isProgramRailVisible || isVisualPickerVisible
        transportControls.setResidentChatExpanded(!residentComposer.isHidden)
        transportControls.setResidentChatAvailable(spatialStage.isWorldPresentationRequested)
        if wasVisible, residentComposer.isHidden, ownedFocus {
            window?.makeFirstResponder(worldInteractionView)
        }
    }

    func attachRenderSurface() {
        renderSurfaceController.attachToFullStage(renderSurfaceContainer)
    }

    private func startObservingSpatialPresentation() {
        guard worldVisibilityObserverID == nil else { return }
        worldVisibilityObserverID = spatialStage.observeWorldVisibility {
            [weak self] isWorldVisible in
            self?.applySpatialPresentation(isWorldVisible: isWorldVisible)
        }
    }

    private func applySpatialPresentation(isWorldVisible _: Bool) {
        residentTaskFeedback.isHidden = !spatialStage.isWorldPresentationRequested
        if !spatialStage.isWorldPresentationRequested {
            residentPropEditor.close()
            // 空间已经退出：挂起的装修意图作废，不能等下次进空间时突然弹出来。
            pendingDecorationEditorRequest = false
        }
        transportControls.setPropEditorAvailable(spatialStage.isWorldPresentationRequested)
        if spatialStage.isWorldPresentationRequested {
            attachRenderSurface()
        }
        // Attaching the local room can synchronously finish presentation and
        // reenter this observer. Do not restore the older loading state.
        let isWorldVisible = spatialStage.isWorldVisible
        let state = StageSurfacePresentationState.resolve(
            isWorldPresentationRequested:
                spatialStage.isWorldPresentationRequested,
            isWorldVisible: isWorldVisible
        )
        renderSurfaceContainer.isHidden = state.isSpatialWorldHidden
        metalView?.isHidden = state.isPointCloudHidden
        worldInteractionView.isHidden = state.isWorldInteractionHidden
        worldLoadingView.isHidden = state.isLoadingIndicatorHidden
        updateResidentComposerVisibility()
        if isWorldVisible, !(window?.firstResponder is NSTextView) {
            window?.makeFirstResponder(worldInteractionView)
        } else if !state.isPointCloudHidden, !(window?.firstResponder is NSTextView), let metalView {
            window?.makeFirstResponder(metalView)
        }
        renderSurfaceController.setWorldPresentationVisible(isWorldVisible)
        destinationButton.isHidden = state.isDestinationButtonHidden
        destinationButton.apply(
            StageDestinationContent.resolve(
                isWorldPresentationRequested:
                    spatialStage.isWorldPresentationRequested
            )
        )
        transportControls.setVisualPickerMode(
            StageVisualPickerMode.resolve(
                isWorldPresentationRequested:
                    spatialStage.isWorldPresentationRequested
            )
        )
        // 呈现/退出的既有回调：菜单入口挂起的装修意图在这里补一次（快照没到就继续挂着）。
        applyPendingDecorationEditorRequest()
        StageWindowController.log.notice(
            "Applied stage presentation requested=\(self.spatialStage.isWorldPresentationRequested, privacy: .public) visible=\(isWorldVisible, privacy: .public) worldHidden=\(state.isSpatialWorldHidden, privacy: .public) pointCloudHidden=\(state.isPointCloudHidden, privacy: .public) loadingHidden=\(state.isLoadingIndicatorHidden, privacy: .public)"
        )
    }
}

@MainActor
private final class StageWorldInteractionView: NSView {
    private let spatialStage: SpatialStageStore
    private let propEditor: ResidentPropEditorState
    private var pointerTask: Task<Void, Never>?
    private var pointerTracking: NSTrackingArea?
    private var dragInProgress = false
    private var didLogCurrentDrag = false
    private var lastDragLocationInWindow: CGPoint?
    /// 建造模式里「鼠标按下但还没决定是点一下还是拖相机」的按下点（窗口坐标）。
    /// nil 表示当前没有待判定的按下；超过抖动阈值转成相机拖拽时会被清掉。
    private var propPressOriginInWindow: CGPoint?

    // MARK: - 场景内旋转手柄（第 2 步）

    /// 可见圆环的半径与线宽（屏幕空间恒定，不随距离缩放）。
    private static let rotationHandleRadius: CGFloat = 26
    private static let rotationHandleLineWidth: CGFloat = 3
    /// 手柄命中半径：**比可见圆环大**，便于瞄准。
    private static let rotationHandleHitRadius: CGFloat = 32
    /// 光标是不是正停在手柄上（决定光标形状与圆环亮度）。
    private var isRotationHandleHovered = false
    /// 编辑器状态一变就把手柄重画一遍（开始/结束携带、换格、旋转）。
    private var rotationHandleRefresh: AnyCancellable?

    /// 建造模式的光标回调。参数是**归一化、左上原点**的光标位置，与
    /// `SpatialStageStore.residentPropPoint` 和 `PropSupportGridPicker` 同一套约定。
    var onGridCursor: ((SIMD2<Float>) -> Void)?
    /// 建造模式「点一下落地」的回调。参数与 `onGridCursor` 完全一致（归一化、左上原点），
    /// 这样落点就是用户最后看到 footprint 停住的那个格心。
    var onGridCommit: ((SIMD2<Float>) -> Void)?
    /// 建造模式「空手点了一下」的回调：归一化点 + `clickCount`。手上有物件时**不会**走这里
    /// （那是上面的落地通路），所以宿主拿到的永远是"拾取"这一侧的问题。
    var onScenePick: ((SIMD2<Float>, Int) -> Void)?
    /// 建造模式的 45° 步进旋转（+1 顺时针 / -1 逆时针）。
    var onGridRotate: ((Int) -> Void)?
    /// 本次「手上这件」是不是**刚在场景里单击拾起**的（面板点行不会置它）。
    ///
    /// 双击的第二下据此把这一下撤回原位 + 复位相机，而不是把它丢在光标处 —— 见 `mouseDown`。
    /// 宿主在真的派发了一次拾取时调用 `noteResidentPropScenePickUp()`；下一记空手点击
    /// （`mouseUp` 的 else 分支）就会把它清掉，所以它只在"这一记拾取 → 下一个鼠标事件"
    /// 这一段里为真，不构成第二份选中状态。
    private var didPickUpFromScenePointer = false

    /// 宿主（App）真的派发了一次"场景里拾起"时调用：让双击的第二下知道该撤回谁。
    func noteResidentPropScenePickUp() {
        didPickUpFromScenePointer = true
    }

    init(spatialStage: SpatialStageStore, propEditor: ResidentPropEditorState) {
        self.spatialStage = spatialStage
        self.propEditor = propEditor
        super.init(frame: .zero)
        toolTip = "拖动鼠标调整视角；滚轮拉近或拉远；W/S 沿视线前后移动，A/D 左右移动；双击复位"
        // 手柄画在本视图里（`draw(_:)`），位置完全由编辑器状态决定：状态一变就标脏即可，
        // **不需要任何每帧注册机制** —— 这正是把绘制放在 `draw(_:)` 的好处。
        // 少了这条，"点地即放 / Esc"之后鼠标不动的话，旧圆环会一直留在屏幕上。
        rotationHandleRefresh = propEditor.objectWillChange.sink { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        guard spatialStage.isWorldVisible else {
            super.scrollWheel(with: event)
            return
        }
        spatialStage.dollyCamera(
            scrollDelta: Float(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas
        )
    }

    override func mouseDown(with event: NSEvent) {
        // 双击：把「刚在场景里拾起的那一下」**撤回原位**（preview 从不改世界，所以不需要新状态），
        // 并照旧复位相机。净效果 = "双击不做拾取 + 双击复位相机"。
        // 条件放在最前面：第二下到来时手上已经有物件了，不能再让它掉进"携带态"的分支里被放下。
        let press = ResidentPropSceneClick.resolvePress(
            isEditorOpen: propEditor.isOpen,
            isBuildModeActive: spatialStage.isResidentPropBuildModeActive,
            carryingStartedAtScenePointer: didPickUpFromScenePointer,
            clickCount: event.clickCount
        )
        if press == .reclaimPickUpAndResetCamera {
            didPickUpFromScenePointer = false
            propPressOriginInWindow = nil
            propEditor.cancelPreview()
            endDragIfNeeded()
            spatialStage.resetCamera()
            return
        }
        if consumesPropPointer {
            window?.makeFirstResponder(self)
            // **手柄命中优先于放置**：命中手柄就只旋转，绝不进入下面的放置分支，
            // 也**不记按下点**（记了就会在 mouseUp 被当成"点一下落地"，见那里的守卫）。
            // 旋转按键与 R 键同一个方向约定：+1 顺时针、⇧ 反向。
            if spatialStage.isResidentPropBuildModeActive,
               isRotationHandleHit(at: convert(event.locationInWindow, from: nil)) {
                onGridRotate?(event.modifierFlags.contains(.shift) ? -1 : 1)
                return
            }
            // 建造模式：按下**只记点**，绝不 beginDrag —— 否则左键一按就开始转相机，
            // 「点一下落地」永远不会发生。落地在 mouseUp（见那里），
            // 中间只要手抖超过阈值就会转成相机拖拽（见 mouseDragged）。
            if spatialStage.isResidentPropBuildModeActive {
                propPressOriginInWindow = event.locationInWindow
                updatePropPointer(event)
                return
            }
            // 非建造模式（既有的支持面路径）：行为保持不变。
            updatePropPointer(event, confirm: true)
            return
        }
        // 携带物件时双击是「落地」手势，不能顺手把相机也复位。
        if event.clickCount == 2, !propEditor.isCarrying {
            endDragIfNeeded()
            spatialStage.resetCamera()
            return
        }
        // 建造模式、**空手**：左键在场景里是"拿起/落地"的手势，不是转相机 —— 但按下同样
        // **只记点**：拖动超过 4 pt 才转成相机拖拽（见 `mouseDragged`），抬起时没超过阈值
        // 才算"点一下"（`mouseUp` → `onScenePick`）。于是"空手时也能拖视角"照旧可用。
        if propEditor.isOpen, spatialStage.isResidentPropBuildModeActive {
            window?.makeFirstResponder(self)
            propPressOriginInWindow = event.locationInWindow
            updatePropPointer(event)
            return
        }
        beginDrag(
            buttonNumber: event.buttonNumber,
            locationInWindow: event.locationInWindow
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        beginDrag(
            buttonNumber: event.buttonNumber,
            locationInWindow: event.locationInWindow
        )
    }

    override func otherMouseDown(with event: NSEvent) {
        beginDrag(
            buttonNumber: event.buttonNumber,
            locationInWindow: event.locationInWindow
        )
    }

    override func mouseDragged(with event: NSEvent) {
        // 建造模式（编辑器打开 + 格子激活）在**携带时和空手时是同一套手感**：按下只记点，
        // 超过 4 pt 才转成相机拖拽。空手时也要走这条，否则 `mouseDown` 记下的按下点没人收尾。
        if consumesPropPointer || (propEditor.isOpen && spatialStage.isResidentPropBuildModeActive) {
            // 非建造模式：保持原样（继续把预览挪到支持面上的指针位置）。
            guard spatialStage.isResidentPropBuildModeActive else {
                updatePropPointer(event)
                return
            }
            // 这一下已经判定成"拖相机"了：继续转，别再回头当"点一下"。
            if dragInProgress {
                dragCamera(with: event)
                return
            }
            // 建造模式：没超过点击抖动阈值就还只是「手抖」，继续跟着光标走；
            // 超过了才认定用户在拖相机 —— 这样"想微调落点"不会被当成转视角，
            // 而"按住左键转相机"在建造模式里也依然可用。
            guard let origin = propPressOriginInWindow,
                  !Self.isWithinClickDrift(from: origin, to: event.locationInWindow) else {
                updatePropPointer(event)
                return
            }
            propPressOriginInWindow = nil
            beginDrag(buttonNumber: event.buttonNumber, locationInWindow: origin)
            dragCamera(with: event)
            return
        }
        dragCamera(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        dragCamera(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        dragCamera(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // 建造模式：只有「按下 → 抬起」之间没超过点击抖动阈值，才算"点一下"。
        // 超过阈值的那一下已经在 mouseDragged 里转成相机拖拽（按下点被清掉），
        // 这里就只负责收尾，不会顺手把物件放下。
        guard let origin = propPressOriginInWindow else {
            endDragIfNeeded()
            return
        }
        propPressOriginInWindow = nil
        guard spatialStage.isResidentPropBuildModeActive else {
            endDragIfNeeded()
            return
        }
        updatePropPointer(event)
        guard Self.isWithinClickDrift(from: origin, to: event.locationInWindow),
              let normalized = normalizedPropPointer(for: event) else { return }
        if propEditor.isCarrying {
            // 既有落地通路，原样：手上有物件时单击 = 放下。
            didPickUpFromScenePointer = false
            onGridCommit?(normalized)
        } else {
            // 空手：交给宿主按唯一的那个分流规则（`ResidentPropSceneClick.resolve`）判 ——
            // 命中已摆物件才拾取，点空地什么也不做。
            // 上一次"场景拾起"到这一记为止就算过去了：宿主若真的拾取，会立刻再置回来。
            didPickUpFromScenePointer = false
            onScenePick?(normalized, event.clickCount)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        endDragIfNeeded()
    }

    override func otherMouseUp(with event: NSEvent) {
        endDragIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if inputOwnsFocus { super.keyDown(with: event); return }
        if event.keyCode == 53, propEditor.isOpen {
            propEditor.escape()
            return
        }
        // 建造模式：R 顺时针 45°，Shift+R 逆时针 45°；`,` 逆时针、`.` 顺时针
        // （Sims 4 肌肉记忆，键码也在 `gridRotationSteps(for:)` 里）。
        // 这里与 R 同一段、同一个出口 —— 于是"手柄 / R / ⇧R / , / ."全都汇到
        // `onGridRotate` → `ResidentPropGridEditorModel.rotateFootprint(bySteps:)` 这一条链上。
        if propEditor.isOpen, spatialStage.isResidentPropBuildModeActive,
           let steps = Self.gridRotationSteps(for: event) {
            onGridRotate?(steps)
            return
        }
        // Delete / Forward Delete：收回选中的物件（面板上也有"收回"按钮）。
        if propEditor.isOpen, event.keyCode == 51 || event.keyCode == 117 {
            Task { await propEditor.withdraw() }
            return
        }
        // Cmd+Z：撤销上一次摆放（面板上也有"撤销上次"按钮）。
        if propEditor.isOpen, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            Task { await propEditor.undo() }
            return
        }
        // 走到这里的才是"编辑器不要的键"，而相机键（W/A/S/D）就该落在这里。
        // 原来这里有一条 `if propEditor.isOpen { return }` 的无条件拦截，于是装修模式下
        // 相机**完全**动不了 —— The Sims / Unity / Unreal 里拿着物件时相机照常可用
        // （Unity 甚至从不禁止相机），装修时连换个角度看落点都得先放下物件，是最差的做法。
        //
        // 优先级（自上而下，先命中先 return）：文本焦点 → Esc 放回 → R/⇧R/,/. 旋转 →
        // Delete 收回 → ⌘Z 撤销 → 相机移动 → super。编辑器的键都排在相机之前，所以放行
        // 相机不会把它们抢走。
        guard !inputOwnsFocus,
              let movement = Self.movement(for: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        spatialStage.setMovement(movement, active: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let movement = Self.movement(for: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        spatialStage.setMovement(movement, active: false)
    }

    override func resignFirstResponder() -> Bool {
        spatialStage.clearMovement()
        spatialStage.setSpeedBoosted(false)
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        // 装修模式下 Shift 仍然是相机加速键（与非装修模式的 `MetalStageView` 一致）。
        // 编辑器唯一的 Shift 用途是 ⇧R 逆时针旋转，那是一条 keyDown 组合、且走
        // `PropSupportGridMapping.yaw(rotatedBySteps:)` 的 45° 步进，不吃速度；
        // boost 只影响 `stepCamera` 的位移速度（6 vs 2.5 m/s）。两者同时成立正是想要的：
        // 按住 Shift 一边转一边绕着落点看一圈。所以这里不需要任何仲裁。
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
            // 视图离开窗口后不会再有 mouseUp：把没结算的按下点清掉，
            // 免得下次回到这个视图时第一次 mouseUp 被当成落地。
            propPressOriginInWindow = nil
            didPickUpFromScenePointer = false
            pointerTask?.cancel()
            propEditor.close()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// 「用户正在输入框里打字」——由宿主注入的**唯一**判据（见 `StageContentView.wireSceneInputOwnership()`：
    /// 它接的是 `residentComposerOwnsFirstResponder()`）。
    ///
    /// 为什么不在这里读 `window?.firstResponder is NSTextView`：那个式子**太宽** —— 它只问
    /// "焦点是不是落在某个文本视图上"，不问"是不是那个输入框"。舞台窗口里的文本视图不止输入框
    /// 一个，任何一个拿到焦点都会被判成"用户在打字"，于是场景既不跟手也不收键（真机 2026-09-29
    /// 的三个症状正是这一族：落点不更新、圆环点不动、`R`/`,`/`.` 全没反应）。
    ///
    /// 注入缺失时退回旧的保守判据（任意 `NSTextView`）：宁可少收一次指针/键，也**不许**在
    /// 用户打字时抢走 —— 生产里这个注入恒存在（`StageContentView.init` 里 `wireSceneInputOwnership()`）。
    var isTextInputFocused: (() -> Bool)?

    /// 门禁判据的**唯一**读取点：`consumesPropPointer` 与 `keyDown` 都读它。
    private var inputOwnsFocus: Bool {
        isTextInputFocused?() ?? (window?.firstResponder is NSTextView)
    }

    private var consumesPropPointer: Bool {
        ResidentPropEditorState.consumesScenePointer(isOpen: propEditor.isOpen, moving: propEditor.isCarrying || propEditor.isMoving,
                                                     inputOwnsFocus: inputOwnsFocus)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); pointerTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        // 建造模式**空手**时也要跟手：这时场景里的鼠标回答的是"光标下那件已摆物件要不要发光"
        // （以及"点它就能拿起来"），不发光的格子也就没有可点的目标。
        guard consumesPropPointer || (propEditor.isOpen && spatialStage.isResidentPropBuildModeActive) else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // A tracking area can see moves above another view. Never project a control or input click.
        guard superview?.hitTest(convert(point, to: superview)) === self else { return }
        updatePropPointer(event)
    }

    /// 光标离开交互视图：手柄的 `pointingHand` 不能留在别处（例如 Metal 世界那张没设
    /// 光标区的画面上）。
    override func mouseExited(with event: NSEvent) {
        guard isRotationHandleHovered else { return }
        isRotationHandleHovered = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    /// 建造模式的步进旋转键：`R` / `⇧R`，以及 Sims 4 肌肉记忆的 `,` / `.`。
    private static func gridRotationSteps(for event: NSEvent) -> Int? {
        // `,` 逆时针、`.` 顺时针（The Sims 4 官方口径）。
        // **必须放行 `⌘` 组合**：`⌘,` 是系统/App 的「设置…」、`⌘.` 是「取消」，
        // 不能被旋转吃掉。
        if !event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 43: return -1  // ,
            case 47: return 1   // .
            default: break
            }
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return nil }
        return event.modifierFlags.contains(.shift) ? -1 : 1
    }

    /// 光标位置 → **归一化、左上原点**坐标。与 `SpatialStageStore.residentPropPoint` 和
    /// `PropSupportGridPicker` 的约定一致（AppKit 的视图坐标是左下原点，所以要翻 y）。
    ///
    /// 悬停（`updatePropPointer`）与落地（`mouseUp`）**共用这一个式子**：两边各写一份的话，
    /// 只要有一处飘了，用户看到的 footprint 和真正落地的格子就会错开。
    private func normalizedPropPointer(for event: NSEvent) -> SIMD2<Float>? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2<Float>(Float(point.x / bounds.width), Float(1 - point.y / bounds.height))
    }

    /// 「点一下」还是「拖一下」：与 Live Cam 进入空间同一套阈值与算法
    /// （`LiveCamSpaceEntryPolicy.maximumClickDrift`），不再各留一个魔数。
    private static func isWithinClickDrift(from origin: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) <= LiveCamSpaceEntryPolicy.maximumClickDrift
    }

    private func updatePropPointer(_ event: NSEvent, confirm: Bool = false) {
        guard let normalized = normalizedPropPointer(for: event) else { return }
        // 手柄画在本视图里，所以指针一移动就重算悬停并标脏 —— 圆环跟着 footprint 走，
        // 不需要任何每帧注册机制（选 `draw(_:)` 而不是新开一层 overlay 就是为了这个）。
        updateRotationHandle(at: convert(event.locationInWindow, from: nil))

        // 建造模式交给格子拾取：射线与**每一层**格子平面求交、就近命中，不再依赖
        // "当前摆放面"的单一高度 —— 这正是建造模式能放地面、放桌面、放夹层的原因。
        if spatialStage.isResidentPropBuildModeActive, spatialStage.residentPropBuildModeProjection != nil {
            onGridCursor?(normalized)
            return
        }

        guard let surface = propEditor.surface else { return }
        pointerTask?.cancel()
        guard let position = spatialStage.residentPropPoint(normalizedPoint: normalized, surfaceY: surface.position.y) else {
            propEditor.pointerMissed(); return
        }
        pointerTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await propEditor.movePointer(to: .init(x: position.x, y: position.y, z: position.z))
            if confirm, !Task.isCancelled { await propEditor.confirm() }
        }
    }

    // MARK: - 旋转手柄

    /// 手柄的**世界锚点**：footprint 中心。
    ///
    /// `placement.position` 是吸附后的**锚定格（那一列）的格心**，也就是 footprint 的中心，
    /// 直接拿来用即可 —— **不再**退回最小角、更**不再**沿局部 +Z 外扩任何米数：外扩量属于
    /// 世界空间，投影到屏幕上会随相机距离缩放（近处把圆环顶到光标前面，见
    /// `ResidentPropRotationHandleAnchor`）。屏幕上的偏移由那个纯函数统一加。
    ///
    /// 建造模式这一条与改动前一致（原来是通过 `residentPropBuildModeProjection?.spacing`
    /// 间接要求的）：非建造模式的"在支持面上挪物件"路径也会写 `placement`，那里不该冒出手柄
    /// —— `mouseDown` 本来也只在建造模式里让手柄命中生效。
    private var rotationHandleWorldAnchor: SIMD3<Float>? {
        guard propEditor.isCarrying,
              spatialStage.isResidentPropBuildModeActive,
              let placement = propEditor.placement else { return nil }
        return SIMD3(placement.position.x, placement.position.y, placement.position.z)
    }

    /// 手柄圆环在本视图坐标里的圆心（AppKit 左下原点）。没在手 / 投影不可用时为 nil ——
    /// 也就是不画、不命中。
    ///
    /// 世界 → 屏幕用**既有的** `SpatialStageStore.residentPropScreenPoint(world:)`
    /// （它给的是归一化、左上原点，所以 y 要翻回来），再加上**固定屏幕偏移**
    /// （`ResidentPropRotationHandleAnchor.center`）。整条链上没有任何随距离缩放的量。
    private var rotationHandleCenter: NSPoint? {
        guard let world = rotationHandleWorldAnchor,
              let normalized = spatialStage.residentPropScreenPoint(world: world) else { return nil }
        let center = ResidentPropRotationHandleAnchor.center(
            projectedCenter: normalized,
            viewSize: bounds.size
        )
        return NSPoint(x: center.x, y: center.y)
    }

    /// 手柄命中（可见圆环 26 pt，命中区 32 pt）。
    private func isRotationHandleHit(at point: NSPoint) -> Bool {
        guard let center = rotationHandleCenter else { return false }
        return hypot(point.x - center.x, point.y - center.y) <= Self.rotationHandleHitRadius
    }

    /// 指针移动时更新手柄悬停态：命中就换成 `pointingHand`，并标脏让圆环变亮。
    private func updateRotationHandle(at point: NSPoint) {
        let hovered = isRotationHandleHit(at: point)
        if hovered != isRotationHandleHovered {
            isRotationHandleHovered = hovered
            // 拖相机时 `beginDrag` 已经 push 了 `closedHand`，别去抢光标。
            if !dragInProgress {
                (hovered ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        needsDisplay = true
    }

    /// 手柄：在手的物件旁边画一个 26 pt 圆环（白色 12% 底 + 青色描边，命中时变亮）。
    ///
    /// 画在这里而不是新开一层 overlay：本视图是**指针的唯一所有者**，绘制与命中判定
    /// 同类型、同坐标系；那几个 hosting view 的 `hitTest` 全返回 nil，再开一层等于第三套坐标系。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let center = rotationHandleCenter else { return }
        let radius = Self.rotationHandleRadius
        let ring = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        let isHot = isRotationHandleHovered
        NSColor.white.withAlphaComponent(isHot ? 0.20 : 0.12).setFill()
        ring.fill()
        NSColor.cyan.withAlphaComponent(isHot ? 1 : 0.78).setStroke()
        ring.lineWidth = Self.rotationHandleLineWidth
        ring.stroke()
    }

    private func beginDrag(
        buttonNumber: Int,
        locationInWindow: CGPoint
    ) {
        window?.makeFirstResponder(self)
        guard !dragInProgress else { return }
        dragInProgress = true
        didLogCurrentDrag = false
        lastDragLocationInWindow = locationInWindow
        StageWindowController.log.notice(
            "World camera drag began button=\(buttonNumber, privacy: .public)"
        )
        NSCursor.closedHand.push()
    }

    private func dragCamera(with event: NSEvent) {
        let delta = StagePointerDragDelta.resolve(
            previousLocation: lastDragLocationInWindow,
            currentLocation: event.locationInWindow,
            eventDelta: CGSize(
                width: event.deltaX,
                height: event.deltaY
            )
        )
        lastDragLocationInWindow = event.locationInWindow
        let before = spatialStage.camera
        spatialStage.look(
            deltaX: Float(delta.width),
            deltaY: Float(delta.height)
        )
        guard !didLogCurrentDrag else { return }
        didLogCurrentDrag = true
        StageWindowController.log.notice(
            "World camera drag deltaX=\(delta.width, privacy: .public) deltaY=\(delta.height, privacy: .public) yawBefore=\(before.yaw, privacy: .public) yawAfter=\(self.spatialStage.camera.yaw, privacy: .public) pitchBefore=\(before.pitch, privacy: .public) pitchAfter=\(self.spatialStage.camera.pitch, privacy: .public)"
        )
    }

    private func endDragIfNeeded() {
        guard dragInProgress else { return }
        dragInProgress = false
        lastDragLocationInWindow = nil
        StageWindowController.log.notice(
            "World camera drag ended yaw=\(self.spatialStage.camera.yaw, privacy: .public) pitch=\(self.spatialStage.camera.pitch, privacy: .public)"
        )
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

@MainActor
private final class StageWorldLoadingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityLabel("正在进入生活空间")

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        addSubview(spinner)

        let label = NSTextField(labelWithString: "正在进入生活空间…")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -16
            ),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
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
private final class StageEnvironmentHostingView:
    NSHostingView<SpatialEnvironmentEffectsView>
{
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The shared Metal surface is visual-only in the full-space window. Pointer
/// events must continue through to `MetalStageView`, which owns camera orbit,
/// reset, and keyboard focus. A plain NSView container would intercept drags
/// even though `MarbleSpatialView` itself returns nil from hit testing.
@MainActor
private final class StageRenderSurfaceHostingView: NSView {
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
private final class StageTransportControlsView: NSView {
    private let programButton: StageProgramButton
    private let previousButton: StageTrackNavigationButton
    private let playbackButton: StagePlaybackButton
    private let nextButton: StageTrackNavigationButton
    private let voiceButton: StageVoiceButton
    private let chatButton: StageResidentChatButton
    private let systemInboxButton: ResidentSystemMailBadgeButton
    private let propEditorButton: StagePropEditorButton
    private let visualButton: StageVisualButton
    private let windowModeButton: StageWindowModeButton

    init(
        programButton: StageProgramButton,
        previousButton: StageTrackNavigationButton,
        playbackButton: StagePlaybackButton,
        nextButton: StageTrackNavigationButton,
        voiceButton: StageVoiceButton,
        chatButton: StageResidentChatButton,
        systemInboxButton: ResidentSystemMailBadgeButton,
        propEditorButton: StagePropEditorButton,
        visualButton: StageVisualButton,
        windowModeButton: StageWindowModeButton
    ) {
        self.programButton = programButton
        self.previousButton = previousButton
        self.playbackButton = playbackButton
        self.nextButton = nextButton
        self.voiceButton = voiceButton
        self.chatButton = chatButton
        self.systemInboxButton = systemInboxButton
        self.propEditorButton = propEditorButton
        self.visualButton = visualButton
        self.windowModeButton = windowModeButton
        super.init(frame: .zero)

        identifier = NSUserInterfaceItemIdentifier("stage.transport-controls")
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.105, alpha: 0.98).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let groupDivider = NSView()
        groupDivider.wantsLayer = true
        groupDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let buttons: [NSView] = [
            programButton, previousButton, playbackButton, nextButton,
            voiceButton, chatButton, systemInboxButton, propEditorButton, visualButton, windowModeButton
        ]
        for view in buttons + [groupDivider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for button in buttons {
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.heightAnchor.constraint(equalToConstant: StageControlPanelLayout.controlSize),
                button.widthAnchor.constraint(equalToConstant: button === visualButton
                    ? StageControlPanelLayout.settingsWidth : StageControlPanelLayout.controlSize)
            ])
        }
        NSLayoutConstraint.activate([
            programButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: StageControlPanelLayout.sideInset),
            previousButton.leadingAnchor.constraint(equalTo: programButton.trailingAnchor),
            playbackButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor),
            nextButton.leadingAnchor.constraint(equalTo: playbackButton.trailingAnchor),
            groupDivider.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: StageControlPanelLayout.groupGap),
            groupDivider.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupDivider.widthAnchor.constraint(equalToConstant: 1),
            groupDivider.heightAnchor.constraint(equalToConstant: 20),
            voiceButton.leadingAnchor.constraint(equalTo: groupDivider.trailingAnchor, constant: StageControlPanelLayout.groupGap),
            chatButton.leadingAnchor.constraint(equalTo: voiceButton.trailingAnchor),
            systemInboxButton.leadingAnchor.constraint(equalTo: chatButton.trailingAnchor),
            propEditorButton.leadingAnchor.constraint(equalTo: systemInboxButton.trailingAnchor),
            visualButton.leadingAnchor.constraint(equalTo: propEditorButton.trailingAnchor),
            windowModeButton.leadingAnchor.constraint(equalTo: visualButton.trailingAnchor),
            windowModeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -StageControlPanelLayout.sideInset)
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

    func setResidentChatExpanded(_ isExpanded: Bool) {
        chatButton.setExpanded(isExpanded)
    }

    func setSystemInboxUnread(_ count: Int) {
        systemInboxButton.setUnreadCount(count)
    }

    func setPropEditorExpanded(_ expanded: Bool) { propEditorButton.contentTintColor = expanded ? .systemCyan : .white }
    func setPropEditorAvailable(_ available: Bool) { propEditorButton.isEnabled = available }

    func setResidentChatAvailable(_ isAvailable: Bool) {
        chatButton.isEnabled = isAvailable
        if !isAvailable { chatButton.toolTip = "进入空间后与居民聊天" }
    }

    func setVisualPickerMode(_ mode: StageVisualPickerMode) {
        visualButton.setStageMode(mode)
    }
}

@MainActor
private final class StagePropEditorButton: NSButton {
    private let handler: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "摆放物件")
        isBordered = false; contentTintColor = .white
        target = self; self.action = #selector(activate)
        toolTip = "摆放物件"
        identifier = NSUserInterfaceItemIdentifier("stage.prop-editor-toggle")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func activate() { handler() }
}

@MainActor
private final class StageResidentChatButton: NSButton {
    private let handler: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("stage.resident-chat-toggle")
        target = self
        self.action = #selector(performToggle)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        setExpanded(false)
    }

    required init?(coder: NSCoder) { nil }

    func setExpanded(_ expanded: Bool) {
        image = NSImage(systemSymbolName: expanded ? "bubble.left.fill" : "bubble.left", accessibilityDescription: "聊天")
        contentTintColor = expanded ? .systemCyan : .white.withAlphaComponent(0.72)
        layer?.backgroundColor = expanded ? NSColor.systemBlue.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
        toolTip = expanded ? "收起聊天" : "与居民聊天"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(expanded ? "已展开" : "已收起")
    }

    @objc private func performToggle() { handler() }
}

@MainActor
private final class StageVisualButton: NSButton {
    private let handler: @MainActor () -> Void
    private var isExpanded = false
    private var stageMode: StageVisualPickerMode = .player

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
        imagePosition = .imageLeading
        imageHugsTitle = true
        title = "设置"
        font = .systemFont(ofSize: 12, weight: .medium)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        updateContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setExpanded(_ isExpanded: Bool) {
        self.isExpanded = isExpanded
        updateContent()
    }

    func setStageMode(_ mode: StageVisualPickerMode) {
        guard stageMode != mode else { return }
        stageMode = mode
        updateContent()
    }

    @objc
    private func performAction() {
        handler()
    }

    private func updateContent() {
        let collapsedLabel = "舞台设置：播放器、空间、角色与活动"
        let label = isExpanded ? "收起设置" : collapsedLabel
        title = isExpanded ? "收起" : "设置"
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: isExpanded ? "xmark" : "slider.horizontal.3",
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
                alpha: 0.28
            ).cgColor
            : NSColor.clear.cgColor
        toolTip = label
        setAccessibilityLabel(label)
    }
}

@MainActor
final class StageDestinationButton: NSButton {
    private let handler: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(
            "stage.destination-toggle"
        )
        target = self
        self.action = #selector(performAction)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 19
        layer?.backgroundColor = NSColor(
            calibratedWhite: 0.04,
            alpha: 0.72
        ).cgColor
        layer?.borderColor = NSColor(
            calibratedRed: 0.28,
            green: 0.86,
            blue: 1,
            alpha: 0.48
        ).cgColor
        layer?.borderWidth = 1

        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 11, weight: .semibold)
        contentTintColor = NSColor(
            calibratedRed: 0.48,
            green: 0.95,
            blue: 1,
            alpha: 1
        )
        apply(StageDestinationContent.resolve(isWorldPresentationRequested: false))
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(_ content: StageDestinationContent) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .semibold
        )
        image = NSImage(
            systemSymbolName: content.symbolName,
            accessibilityDescription: content.accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        title = content.title
        toolTip = content.toolTip
        setAccessibilityLabel(content.accessibilityLabel)
    }

    @objc
    private func performAction() {
        handler()
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
        layer?.cornerRadius = 10
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
        layer?.cornerRadius = 10
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
        layer?.cornerRadius = 10
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
        let backgroundOpacity = pointerIsInside && isEnabled ? 0.14 : 0.07
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
        layer?.cornerRadius = 10
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
        layer?.cornerRadius = 10
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
