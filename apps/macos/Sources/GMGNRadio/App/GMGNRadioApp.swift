import AppKit
import AVFoundation
import os
import SwiftUI
import UniformTypeIdentifiers
import WorldRuntime

enum ProductIdentity {
    static let displayName = "gmgn radio"
    static let bundleIdentifier = "ai.gmgn.radio"
}

private enum MusicLibraryCacheError: LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        "歌单已返回，但本地保存校验失败；没有覆盖原有歌单。"
    }
}

enum ApplicationLaunchPolicy {
    private static let testEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto",
    ]

    static func shouldRestoreUserState(
        environment: [String: String]
    ) -> Bool {
        guard environment["GMGN_DISABLE_USER_STATE_RESTORE"] != "1" else {
            return false
        }
        return !testEnvironmentKeys.contains { key in
            !(environment[key] ?? "").isEmpty
        }
    }

    static func shouldShowDesktopPresenceOnLaunch(
        environment: [String: String]
    ) -> Bool {
        guard environment["GMGN_HIDE_STAGE_ON_LAUNCH"] != "1" else {
            return false
        }
        return shouldRestoreUserState(environment: environment)
    }
}

enum RealtimeVoiceSetupError: LocalizedError {
    case microphoneDenied
    case providerUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "没有麦克风权限，请在系统设置里允许 gmgn radio 使用麦克风。"
        case .providerUnavailable:
            "这个实时语音服务尚未接通。"
        }
    }
}

@MainActor
final class ApplicationActivationCoordinator {
    typealias SetPolicy = @MainActor (NSApplication.ActivationPolicy) -> Bool
    typealias Activate = @MainActor () -> Void

    private let setPolicy: SetPolicy
    private let activate: Activate

    init(
        setPolicy: @escaping SetPolicy = {
            NSApplication.shared.setActivationPolicy($0)
        },
        activate: @escaping Activate = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    ) {
        self.setPolicy = setPolicy
        self.activate = activate
    }

    func promoteToForeground() {
        _ = setPolicy(.regular)
        activate()
    }
}

@MainActor
struct ApplicationIconInstaller {
    typealias LoadIcon = @MainActor () -> NSImage?
    typealias ApplyIcon = @MainActor (NSImage) -> Void

    private let loadIcon: LoadIcon
    private let applyIcon: ApplyIcon

    init(
        loadIcon: @escaping LoadIcon = {
            guard let path = Bundle.main.path(
                forResource: "AppIcon",
                ofType: "icns"
            ) else {
                return nil
            }
            return NSImage(contentsOfFile: path)
        },
        applyIcon: @escaping ApplyIcon = {
            NSApplication.shared.applicationIconImage = $0
        }
    ) {
        self.loadIcon = loadIcon
        self.applyIcon = applyIcon
    }

    @discardableResult
    func install() -> Bool {
        guard let icon = loadIcon() else {
            return false
        }
        applyIcon(icon)
        return true
    }
}

@MainActor
struct DockReopenAction {
    let showDesktopPresence: @MainActor () -> Void

    func perform(hasVisibleWindows: Bool) -> Bool {
        _ = hasVisibleWindows
        showDesktopPresence()
        return true
    }
}

@main
struct GMGNRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra(ProductIdentity.displayName, systemImage: "waveform.circle.fill") {
            ForEach(SystemResidentMenuPolicy.entries, id: \.self) { entry in
                systemResidentMenuItem(for: entry)
            }
        }

        Settings {
            GMGNSettingsView(
                shortcutSettings: appDelegate.shortcutSettingsStore,
                connectRealtimeVoice: { configuration in
                    appDelegate.connectRealtimeVoice(configuration)
                },
                disconnectRealtimeVoice: {
                    appDelegate.disconnectRealtimeVoice()
                },
                agentConfigurationChanged: {
                    appDelegate.refreshAgentConfiguration()
                }
            )
                .frame(minWidth: 540, minHeight: 440)
        }
        .defaultSize(width: 580, height: 500)
    }
}

enum SystemResidentMenuEntry: Hashable, Sendable {
    case showLiveCam
    case enterSpace
    case openPlayer
    case settings
    case quit
}

enum SystemResidentMenuPolicy {
    static let entries: [SystemResidentMenuEntry] = [
        .showLiveCam,
        .enterSpace,
        .openPlayer,
        .settings,
        .quit,
    ]
}

extension GMGNRadioApp {
    @ViewBuilder
    private func systemResidentMenuItem(
        for entry: SystemResidentMenuEntry
    ) -> some View {
        switch entry {
        case .showLiveCam:
            Button("显示 Live Cam") {
                AppMenuAction.showLiveCam.perform(on: appDelegate)
            }
        case .enterSpace:
            Button("进入空间") {
                AppMenuAction.showStage.perform(on: appDelegate)
            }
        case .openPlayer:
            Button("打开播放器") {
                AppMenuAction.showPlayer.perform(on: appDelegate)
            }
        case .settings:
            Divider()
            Button("设置…") {
                appDelegate
                    .makeSettingsMenuAction(openSettings: { openSettings() })
                    .perform()
            }
        case .quit:
            Divider()
            Button("退出 gmgn radio") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor
protocol GMGNApplicationControlling: AnyObject {
    func startAIProgram()
    func showStage()
    func showPlayer()
    func showLiveCam()
    func playCharacterMotion(id: String)
    func closeStage()
    func runLivingWorldActivity(id: String)
    func stopLivingWorldActivity()
    func chooseLocalTrack()
    func toggleLocalPlayback()
    func toggleLyricsVisualMode()
    func exitImmersiveVisuals()
}

enum LivingWorldAvatarPresentationMode: Equatable, Sendable {
    case semanticActivity
    case userIdle
}

enum LivingWorldAvatarPresentationPolicy {
    static func phaseContract(
        mode: LivingWorldAvatarPresentationMode,
        authoredContract: ActivityPhaseContract?
    ) -> ActivityPhaseContract? {
        switch mode {
        case .semanticActivity:
            authoredContract
        case .userIdle:
            nil
        }
    }

    static func compatibleMotions(
        _ motions: [String: StageMotionAsset],
        avatarFormat: StageAvatarFormat?
    ) -> [String: StageMotionAsset] {
        guard let avatarFormat else { return [:] }
        return motions.filter { _, motion in
            switch (avatarFormat, motion.format) {
            case (.pmx, .vmd), (.vrm, .vrma), (_, .procedural):
                true
            default:
                false
            }
        }
    }
}

@MainActor
struct LivingWorldStageEntryAction {
    let requestWorldPresentation: () -> Void
    let showStageWindow: () -> Void

    func perform() {
        requestWorldPresentation()
        showStageWindow()
    }
}

struct CharacterMotionMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isActive: Bool
}

struct LivingWorldActivityMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class LivingWorldActivityMenuStore: ObservableObject {
    static let shared = LivingWorldActivityMenuStore()

    @Published private(set) var items: [LivingWorldActivityMenuItem] = []
    @Published private(set) var worldID: String?
    @Published private(set) var activeActivityID: String?
    @Published private(set) var message: String?

    func update(definitions: [LifeActivityDefinition], worldID: String? = nil) {
        self.worldID = worldID
        items = LivingWorldActivityMenuPolicy.items(definitions: definitions)
        activeActivityID = nil
        message = nil
    }

    func canControl(worldID: String?) -> Bool {
        guard let worldID else { return false }
        return self.worldID == worldID
    }

    func updateActiveActivity(id: String?) {
        guard activeActivityID != id else { return }
        activeActivityID = id
        message = nil
    }

    func report(_ message: String) {
        self.message = message
    }
}

enum LivingWorldActivityMenuPolicy {
    static func items(
        definitions: [LifeActivityDefinition]
    ) -> [LivingWorldActivityMenuItem] {
        definitions.map { definition in
            LivingWorldActivityMenuItem(
                id: definition.id,
                name: definition.displayName ?? displayName(for: definition.activity)
            )
        }
    }

    private static func displayName(for activity: LifeActivity) -> String {
        switch activity {
        case .idle:
            "自然待机"
        case .turn:
            "原地转身"
        case .walk:
            "走到房间中央"
        case .sit:
            "坐到椅子上"
        case .gaze:
            "看向窗外"
        case .listenMusic:
            "听音乐并跳舞（循环）"
        case .interact:
            "操作物件"
        }
    }
}

enum LivingWorldActivityPresentationPolicy {
    static func shouldShowDesktopPresence(
        fullSpaceIsPresented: Bool
    ) -> Bool {
        !fullSpaceIsPresented
    }
}

enum CharacterMotionPresentationPolicy {
    static func shouldShowDesktopPresence(
        fullSpaceIsPresented: Bool
    ) -> Bool {
        !fullSpaceIsPresented
    }
}

enum MusicPlaybackPresentationPolicy {
    static let opensFullStageOnPlaybackStart = false
}

enum CharacterMotionMenuPolicy {
    static let ardyJumpingJacksID = "gmgn.motion.ardy-natural-jumping-jacks"
    static let ardyBackflipID = "gmgn.motion.ardy-backflip"

    private static let productMotions: [(id: String, name: String)] = [
        (MotionPackageStore.naturalIdleID, "待机"),
        (MotionPackageStore.iluvSlapBassID, "Slap Bass"),
        (ardyJumpingJacksID, "ARDY 开合跳"),
        (ardyBackflipID, "后空翻"),
    ]

    static func items(
        motions: [StageMotionAsset],
        activeMotionID: String?
    ) -> [CharacterMotionMenuItem] {
        let motionsByID = Dictionary(uniqueKeysWithValues: motions.map { ($0.id, $0) })
        return productMotions.compactMap { productMotion in
            guard let motion = motionsByID[productMotion.id] else { return nil }
            return CharacterMotionMenuItem(
                id: motion.id,
                name: productMotion.name,
                isActive: motion.id == activeMotionID
            )
        }
    }
}

enum AppMenuAction: Sendable {
    case startAIProgram
    case showStage
    case showPlayer
    case showLiveCam
    case playCharacterMotion(id: String)
    case closeStage
    case runLivingActivity(id: String)
    case stopLivingActivity
    case chooseLocalTrack
    case toggleLocalPlayback
    case toggleLyricsVisualMode
    case exitImmersiveVisuals

    @MainActor
    func perform(on controller: any GMGNApplicationControlling) {
        switch self {
        case .startAIProgram:
            controller.startAIProgram()
        case .showStage:
            controller.showStage()
        case .showPlayer:
            controller.showPlayer()
        case .showLiveCam:
            controller.showLiveCam()
        case let .playCharacterMotion(id):
            controller.playCharacterMotion(id: id)
        case .closeStage:
            controller.closeStage()
        case let .runLivingActivity(id):
            controller.runLivingWorldActivity(id: id)
        case .stopLivingActivity:
            controller.stopLivingWorldActivity()
        case .chooseLocalTrack:
            controller.chooseLocalTrack()
        case .toggleLocalPlayback:
            controller.toggleLocalPlayback()
        case .toggleLyricsVisualMode:
            controller.toggleLyricsVisualMode()
        case .exitImmersiveVisuals:
            controller.exitImmersiveVisuals()
        }
    }
}

@MainActor
struct SettingsMenuAction {
    let openSettings: () -> Void
    let scheduleActivation: (@escaping @MainActor () -> Void) -> Void
    let activateApplication: () -> Void
    let revealSettingsWindow: () -> Void

    func perform() {
        activateApplication()
        openSettings()
        scheduleActivation {
            activateApplication()
            revealSettingsWindow()
        }
    }
}

@MainActor
enum SettingsWindowMatcher {
    static func matches(_ window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled) else {
            return false
        }
        return window.title.localizedCaseInsensitiveContains("settings")
            || window.title.contains("设置")
    }
}

@MainActor
final class AppDelegate:
    NSObject,
    NSApplicationDelegate,
    GMGNApplicationControlling,
    DJAgentRadioActions
{
    private let playbackLogger = Logger(
        subsystem: ProductIdentity.bundleIdentifier,
        category: "DJPlayback"
    )
    private let livingWorldLogger = Logger(
        subsystem: ProductIdentity.bundleIdentifier,
        category: "LivingWorld"
    )
    private let applicationActivation = ApplicationActivationCoordinator()
    private let audioFeatures = VisualAudioFeatureStore()
    private let stageArtwork = StageArtworkStore()
    private let stagePresentation = StagePresentationModel()
    private let stageVisualDirections = StageVisualDirectionStore()
    private let stageVideos = StageVideoPlaybackStore()
    private let spatialStage = SpatialStageStore()
    private let avatarRuntime = StageAvatarRuntimeStore.shared
    private let motionPackageStore = try? MotionPackageStore.liveStore()
    private lazy var marbleWorldLibrary = MarbleWorldLibrary(
        spatialStage: spatialStage
    )
    private let programStore = DJProgramStore.shared
    private let musicLibraryStore = SyncedMusicLibraryStore.shared
    private let stageLyrics = StageLyricsStore.shared
    private let agentPreferences = DJAgentPreferences()
    private let realtimeVoicePreferences = RealtimeVoicePreferences()
    private let realtimeDJSessionController = RealtimeDJSessionController()
    private lazy var agentSpeechAnnouncer = AgentSpeechAnnouncer(
        synthesizer: MacSpeechSynthesizer()
    )
    private let shortcutSettings = GMGNShortcutSettingsStore()
    private var shortcutCoordinator: GMGNShortcutCoordinator?

    var shortcutSettingsStore: GMGNShortcutSettingsStore {
        shortcutSettings
    }
    private lazy var musicRuntime = MusicRuntime.live()
    private var audioGraphStorage: AudioGraphController?
    private var audioGraph: AudioGraphController {
        if let audioGraphStorage {
            return audioGraphStorage
        }
        let graph = AudioGraphController(visualStore: audioFeatures)
        audioGraphStorage = graph
        return graph
    }
    private lazy var localMusicPlayer = LocalMusicPlayer(
        graph: audioGraph,
        onFinished: { [weak self] in
            self?.advanceProgram()
        }
    )
    private lazy var programPlaybackQueue = ProgramPlaybackQueue(
        preflight: PlaybackPreflight(
            preparer: MusicRuntimePlaybackPreparer(runtime: musicRuntime)
        )
    )
    private var activeProgram: ProgramPlan?
    private var interruptionCoordinator: InterruptionCoordinator?
    private var orbWindowController: OrbWindowController?
    private var stageWindowController: StageWindowController?
    private var liveCamWindowController: LiveCamWindowController?
    private var stageRenderSurfaceController: StageRenderSurfaceController?
    private var stageCameraCoordinator: StageCameraCoordinator?
    private var stageAvatarActivityExecutor: StageAvatarActivityExecutor?
    private var livingWorldApprovedMotions: [String: StageMotionAsset] = [:]
    private var desktopPresenceObserverID: UUID?
    private var livingWorldContext: WorldAgentContext?
    private var livingCabinJukeboxGate = LivingCabinJukeboxGate()
    private var worldAgentToolDispatcher: WorldAgentToolDispatcher?
    private var livingWorldVisualTask: Task<Void, Never>?
    private var livingWorldColliderTask: Task<Void, Never>?
    private var livingWorldColliderFraming: MarbleSceneFraming?
    private var sceneFramingObserverID: UUID?
    private var stageAudioMonitor: VisualAudioInputMonitor?
    private var stagePresentationTask: Task<Void, Never>?
    private var realtimeVoiceConnectionTask: Task<Void, Never>?
    private var realtimeVoiceTimeoutTask: Task<Void, Never>?
    private var backgroundProgramAgentTask: Task<Void, Never>?
    private var backgroundProgramRequestID: UUID?
    private var isStartingProgramPlayback = false
    private var committedPlaybackTrack: MusicCandidate?
    private var previousCommittedPlaybackTrack: MusicCandidate?
    private var recentDirectToolName: String?
    private var recentDirectToolDate: Date?
    private lazy var agentToolDispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { [weak self] in
            self?.agentPreferences.takeoverEnabled() ?? false
        },
        actions: self,
        worldDispatcher: { [weak self] in
            self?.worldAgentToolDispatcher
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        ApplicationIconInstaller().install()
        let shortcuts = GMGNShortcutCoordinator(
            settings: shortcutSettings,
            performAction: { [weak self] action in
                self?.performShortcutAction(action)
            }
        )
        shortcutCoordinator = shortcuts
        shortcuts.start()
        playbackLogger.info("应用启动，开始恢复节目与音频状态")
        ProcessInfo.processInfo.disableAutomaticTermination(
            "gmgn radio 需要保持桌宠、电台和实时语音会话在线"
        )
        let controller = OrbWindowController(
            audioFeatures: audioFeatures,
            isStageVisible: { [weak self] in
                self?.stageWindowController?.isPresented ?? false
            },
            showStage: { [weak self] in
                self?.showStage()
            },
            hideStage: { [weak self] in
                self?.closeStage()
            }
        )
        orbWindowController = controller
        configureLivingWorld()
        configureStage()
        desktopPresenceObserverID = avatarRuntime.observe {
            [weak self] snapshot in
            self?.applyDesktopPresence(snapshot)
            self?.refreshInstalledLivingWorldMotions()
        }
        avatarRuntime.refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(musicAccountDidChange),
            name: .musicAccountDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(manualMotionWillActivate),
            name: .gmgnManualMotionWillActivate,
            object: nil
        )
        if ApplicationLaunchPolicy.shouldRestoreUserState(
            environment: environment
        ) {
            programStore.restoreLatest()
            restoreSavedProgramPresentation()
            playbackLogger.info(
                "已恢复本地节目；等待用户明确播放或同步后再读取音乐账号"
            )
        } else {
            playbackLogger.info(
                "测试或隔离启动：跳过真实节目与音乐账号恢复"
            )
        }

        if
            let modeName = environment["GMGN_STAGE_VIDEO_MODE"],
            let mode = StageVideoPlaybackMode(rawValue: modeName)
        {
            stageVideos.setMode(mode)
        }
        if let videoPath = environment["GMGN_STAGE_VIDEO"] {
            stageVideos.add([URL(fileURLWithPath: videoPath)])
        }
        if
            let moodName = environment["GMGN_VISUAL_MOOD"],
            let mood = StageVisualMood(rawValue: moodName)
        {
            stageVisualDirections.update(mood)
        }
        if
            let stateName = environment["GMGN_ORB_STATE"],
            let state = DJState(rawValue: stateName)
        {
            controller.setState(state)
        }
        if environment["GMGN_BASELINE_IMMERSIVE"] == "1" {
            controller.enterImmersiveVisuals()
        }
        if environment["GMGN_STAGE"] == "1" {
            showStage()
        } else if ApplicationLaunchPolicy.shouldShowDesktopPresenceOnLaunch(
            environment: environment
        ) {
            showLiveCam()
        }
        if let trackPath = environment["GMGN_LOCAL_TRACK"] {
            do {
                try playLocalTrack(URL(fileURLWithPath: trackPath))
            } catch {
                presentPlaybackError(error)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutCoordinator?.stop()
        avatarRuntime.removeObserver(desktopPresenceObserverID)
        desktopPresenceObserverID = nil
        livingWorldVisualTask?.cancel()
        livingWorldColliderTask?.cancel()
        spatialStage.removeSceneFramingObserver(sceneFramingObserverID)
        sceneFramingObserverID = nil
        livingWorldContext?.stopTicking()
    }

    @objc private func manualMotionWillActivate(_ notification: Notification) {
        guard let context = livingWorldContext else { return }
        do {
            try context.stopActivity(reason: "用户从设置选择动作")
        } catch {
            livingWorldLogger.error(
                "设置动作前停止生活活动失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performShortcutAction(_ action: GMGNShortcutAction) {
        switch action {
        case .togglePlayback:
            toggleLocalPlayback()
        case .previousTrack:
            playPreviousProgramTrack()
        case .nextTrack:
            playNextProgramTrack()
        case .volumeUp:
            adjustMusicVolume(by: 0.08)
        case .volumeDown:
            adjustMusicVolume(by: -0.08)
        case .toggleVoice:
            toggleRealtimeVoiceFromStage()
        case .toggleStage:
            if stageWindowController?.isPresented == true {
                closeStage()
            } else {
                showStage()
            }
        case .toggleLyrics:
            toggleLyricsVisualMode()
        }
    }

    private func adjustMusicVolume(by delta: Float) {
        audioGraph.musicVolume = min(
            1,
            max(0, audioGraph.musicVolume + delta)
        )
    }

    @objc private func musicAccountDidChange(_ notification: Notification) {
        guard
            let rawProviderID = notification.userInfo?["providerID"] as? String,
            let connected = notification.userInfo?["connected"] as? Bool
        else {
            return
        }
        let providerID = MusicProviderID(rawValue: rawProviderID)
        if connected {
            refreshSyncedMusicLibrary(providerID: providerID)
        } else {
            musicLibraryStore.remove(providerID: providerID)
        }
    }

    private func refreshSyncedMusicLibrary(
        providerID: MusicProviderID
    ) {
        guard !musicLibraryStore.isSyncing else {
            publishMusicLibrarySyncResult(
                providerID: providerID,
                errorDescription: "已有音乐同步任务正在进行。"
            )
            return
        }
        musicLibraryStore.setSyncing(true)
        Task { [weak self] in
            guard let self else {
                return
            }
            defer { musicLibraryStore.setSyncing(false) }
            do {
                let library = try await musicRuntime.fetchLibrary(
                    providerID: providerID
                )
                guard musicLibraryStore.mergeAndVerify(
                    playlists: library.playlists
                ) else {
                    throw MusicLibraryCacheError.verificationFailed
                }
                publishMusicLibrarySyncResult(
                    providerID: providerID,
                    playlistCount: library.playlists.count
                )
            } catch {
                playbackLogger.error(
                    "音乐歌单同步失败：provider=\(providerID.rawValue, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                publishMusicLibrarySyncResult(
                    providerID: providerID,
                    errorDescription: error.localizedDescription
                )
            }
        }
    }

    private func publishMusicLibrarySyncResult(
        providerID: MusicProviderID,
        playlistCount: Int? = nil,
        errorDescription: String? = nil
    ) {
        var userInfo: [String: Any] = [
            "providerID": providerID.rawValue,
        ]
        if let playlistCount {
            userInfo["playlistCount"] = playlistCount
        }
        if let errorDescription {
            userInfo["errorDescription"] = errorDescription
        }
        NotificationCenter.default.post(
            name: .musicLibrarySyncDidFinish,
            object: nil,
            userInfo: userInfo
        )
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        DockReopenAction { [weak self] in
            self?.showLiveCam()
        }.perform(hasVisibleWindows: flag)
    }

    func showStage() {
        promoteToForeground()
        if livingWorldContext == nil {
            configureLivingWorld()
        }
        if stageWindowController == nil {
            configureStage()
        }
        LivingWorldStageEntryAction(
            requestWorldPresentation: { [spatialStage] in
                spatialStage.requestWorldPresentation()
            },
            showStageWindow: { [weak self] in
                self?.stageWindowController?.show()
            }
        ).perform()
    }

    func showPlayer() {
        promoteToForeground()
        if livingWorldContext == nil {
            configureLivingWorld()
        }
        if stageWindowController == nil {
            configureStage()
        }
        spatialStage.exitWorld()
        stageWindowController?.show()
    }

    func showLiveCam() {
        if stageWindowController?.isPresented == true {
            stageWindowController?.close()
            return
        }
        if livingWorldContext == nil {
            configureLivingWorld()
        }
        if stageWindowController == nil {
            configureStage()
        }
        applyDesktopPresence(avatarRuntime.snapshot)
    }

    private func applyDesktopPresence(
        _ snapshot: StageAvatarRuntimeSnapshot
    ) {
        switch DesktopPresenceMode.resolve(snapshot: snapshot) {
        case .orb:
            liveCamWindowController?.hide()
            orbWindowController?.show()
        case .liveCam:
            orbWindowController?.hide()
            guard stageWindowController?.isPresented != true else { return }
            liveCamWindowController?.show()
        }
    }

    func runLivingWorldActivity(id: String) {
        let menu = LivingWorldActivityMenuStore.shared
        guard menu.canControl(worldID: spatialStage.selectedWorldID) else {
            menu.report("当前空间尚未接入生活活动，请切回生活舱。")
            return
        }
        if LivingWorldActivityPresentationPolicy.shouldShowDesktopPresence(
            fullSpaceIsPresented: stageWindowController?.isPresented == true
        ) {
            showLiveCam()
        }
        guard let context = livingWorldContext,
              context.manifest.worldID == menu.worldID else {
            menu.report("生活空间尚未就绪，请稍后再试。")
            livingWorldLogger.error("生活空间当前不可用，无法开始菜单活动")
            return
        }
        guard let definition = context.manifest.activityDefinitions.first(
            where: { $0.id == id }
        ) else {
            menu.report("当前空间没有这项活动。")
            livingWorldLogger.error(
                "示例空间未声明活动：\(id, privacy: .public)"
            )
            return
        }
        do {
            try context.startActivity(id: definition.id)
            menu.report("已安排：\(definition.displayName ?? id)")
        } catch {
            menu.report("活动未能开始：\(error.localizedDescription)")
            livingWorldLogger.error(
                "菜单活动启动失败：id=\(id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func stopLivingWorldActivity() {
        let menu = LivingWorldActivityMenuStore.shared
        guard menu.canControl(worldID: spatialStage.selectedWorldID) else {
            menu.report("请回到活动所在的生活舱后再停止。")
            return
        }
        guard let context = livingWorldContext,
              context.manifest.worldID == menu.worldID else {
            menu.report("生活空间尚未就绪，请稍后再试。")
            livingWorldLogger.error("生活空间当前不可用，无法停止活动")
            return
        }
        do {
            try context.stopActivity()
            menu.report("生活活动已停止。")
        } catch {
            menu.report("活动未能停止：\(error.localizedDescription)")
            livingWorldLogger.error(
                "停止生活活动失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func playCharacterMotion(id: String) {
        guard let motionPackageStore else {
            livingWorldLogger.error("动作库当前不可用")
            return
        }
        do {
            guard let motion = try motionPackageStore.listMotions().first(
                where: { $0.id == id }
            ) else {
                throw MotionPackageError.motionNotFound
            }
            if avatarRuntime.snapshot.avatar?.format == .pmx,
               motion.format == .vrma
            {
                livingWorldLogger.error(
                    "动作与当前 PMX 角色不兼容：motion=\(motion.name, privacy: .public)"
                )
                return
            }

            if livingWorldContext == nil {
                configureLivingWorld()
            }
            try livingWorldContext?.stopActivity(
                reason: "用户从菜单选择动作"
            )
            try motionPackageStore.activate(id: motion.id)
            avatarRuntime.refresh()
            if CharacterMotionPresentationPolicy.shouldShowDesktopPresence(
                fullSpaceIsPresented: stageWindowController?.isPresented == true
            ) {
                showLiveCam()
            }
            livingWorldLogger.info(
                "已从菜单播放角色动作：motion=\(motion.name, privacy: .public)"
            )
        } catch {
            livingWorldLogger.error(
                "菜单动作播放失败：id=\(id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func promoteToForeground() {
        applicationActivation.promoteToForeground()
    }

    func makeSettingsMenuAction(
        openSettings: @escaping () -> Void
    ) -> SettingsMenuAction {
        SettingsMenuAction(
            openSettings: openSettings,
            scheduleActivation: { activation in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    activation()
                }
            },
            activateApplication: { [weak self] in
                self?.promoteToForeground()
            },
            revealSettingsWindow: { [weak self] in
                self?.revealSettingsWindow()
            }
        )
    }

    func revealSettingsWindow() {
        guard let window = NSApplication.shared.windows.first(
            where: SettingsWindowMatcher.matches
        ) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func openPresenceSettings() {
        GMGNSettingsNavigation.shared.page = .presence
        openSystemSettings()
    }

    func openSystemSettings() {
        makeSettingsMenuAction(openSettings: { [weak self] in
            let revealedExistingWindow = NSApplication.shared.windows.contains(
                where: SettingsWindowMatcher.matches
            )
            if revealedExistingWindow {
                self?.revealSettingsWindow()
            } else {
                NSApp.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            }
        }).perform()
    }

    func toggleLyricsVisualMode() {
        let modes = StageLyricsVisualMode.allCases
        let currentIndex = modes.firstIndex(of: stageLyrics.visualMode) ?? 0
        let nextMode = modes[(currentIndex + 1) % modes.count]
        stageLyrics.setVisualMode(nextMode)
        showStage()
    }

    func startAIProgram() {
        startAIProgram(immediateUserInstruction: nil)
    }

    private func startAIProgram(
        immediateUserInstruction: String?
    ) {
        orbWindowController?.setState(.thinking)
        activeProgram = nil
        updateStageProgramNavigation()
        programStore.beginPlanning()
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let plan = try await makeAIProgramPlan(
                    immediateUserInstruction:
                        immediateUserInstruction
                )
                activeProgram = plan
                programStore.publish(plan)
                try await programPlaybackQueue.load(plan)
                guard let prepared = programPlaybackQueue.current else {
                    throw ProgramPlaybackQueueError.noPlayableSlots(
                        failedTrackIDs: programPlaybackQueue.failedTrackIDs
                    )
                }
                try await playPreparedWithFallback(prepared)
            } catch {
                orbWindowController?.setState(.failed)
                activeProgram = nil
                updateStageProgramNavigation()
                programStore.fail(error.localizedDescription)
                presentProgramError(error)
            }
        }
    }

    private func makeAIProgramPlan(
        immediateUserInstruction: String?
    ) async throws -> ProgramPlan {
        let agent = try CodexTrackRankingAgent.live()
        let brief = Self.currentProgramBrief(
            immediateUserInstruction: immediateUserInstruction
        )
        let plan = try await musicRuntime.makeProgramPlan(
            brief: brief,
            agent: agent
        )
        guard !plan.slots.isEmpty else {
            throw ProgramPlannerError.insufficientPlayableCandidates(
                required: 5,
                available: 0
            )
        }
        return plan
    }

    func connectRealtimeVoice(
        _ configuration: RealtimeVoiceConfiguration
    ) {
        realtimeVoiceConnectionTask?.cancel()
        realtimeVoiceTimeoutTask?.cancel()
        setRealtimeVoiceState(.connecting)
        orbWindowController?.setState(.reconnecting)
        prepareInterruptionCoordinator()

        realtimeVoiceTimeoutTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await RealtimeVoiceConnectionDeadline(
                    duration: .seconds(12)
                ).wait()
            } catch is CancellationError {
                return
            } catch {
                guard RealtimeVoiceStatusStore.shared.state == .connecting
                else {
                    return
                }
                realtimeVoiceConnectionTask?.cancel()
                await realtimeDJSessionController.deactivate()
                orbWindowController?.setVoiceLevel(0)
                orbWindowController?.setState(.failed)
                setRealtimeVoiceState(.failed(
                    error.localizedDescription
                ))
            }
        }

        realtimeVoiceConnectionTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                guard await Self.requestMicrophoneAccess() else {
                    throw RealtimeVoiceSetupError.microphoneDenied
                }
                guard configuration.isReadyToConnect else {
                    throw RealtimeVoiceSetupError.providerUnavailable
                }

                let session: any RealtimeDJSession
                let ticket: RealtimeDJSessionTicket
                switch configuration.provider {
                case .bailian:
                    guard
                        let apiKey = configuration.apiKey,
                        let model = configuration.model,
                        let voiceID = configuration.voiceID
                    else {
                        throw RealtimeVoiceSetupError.providerUnavailable
                    }
                    let payload = BailianSessionPayload(
                        apiKey: apiKey,
                        model: model,
                        voiceID: voiceID,
                        microphoneDeviceID:
                            configuration.microphoneDeviceID
                    )
                    session = BailianRealtimeSession.live(
                        audioGraph: audioGraph,
                        providerTools: agentToolDispatcher.providerTools
                    )
                    ticket = RealtimeDJSessionTicket(
                        provider: .bailian,
                        sessionID: "bailian-\(UUID().uuidString)",
                        expiresAt: Date(timeIntervalSinceNow: 86_400),
                        providerPayload: try JSONEncoder().encode(payload)
                    )
                    prepareInterruptionCoordinator()
                case .elevenLabs:
                    let payload = ElevenLabsSessionPayload(
                        agentID: configuration.agentID,
                        conversationToken: configuration.conversationToken,
                        apiKey: configuration.apiKey,
                        voiceID: configuration.voiceID
                    )
                    session = ElevenLabsRealtimeSession.live()
                    ticket = RealtimeDJSessionTicket(
                        provider: .elevenLabs,
                        sessionID: "elevenlabs-\(UUID().uuidString)",
                        expiresAt: Date(timeIntervalSinceNow: 86_400),
                        providerPayload: try JSONEncoder().encode(payload)
                    )
                case .doubao:
                    throw RealtimeVoiceSetupError.providerUnavailable
                }
                agentToolDispatcher.resetSession()
                _ = try await activateRealtimeDJSession(
                    session,
                    ticket: ticket
                )
                try await realtimeDJSessionController
                    .setMicrophoneCaptureEnabled(true)
                try await realtimeDJSessionController
                    .setMicrophoneTransmissionEnabled(true)

                try Task.checkCancellation()
                guard
                    RealtimeVoiceStatusStore.shared.state
                        .canCompleteConnectionAttempt
                else {
                    await realtimeDJSessionController.deactivate()
                    return
                }
                realtimeVoiceTimeoutTask?.cancel()
                setRealtimeVoiceState(.connected)
                orbWindowController?.setState(
                    audioGraphStorage?.isMusicPlaying == true
                        ? .playing
                        : .idle
                )
                if
                    let activeProgram,
                    let slotIndex = programStore.activeSlotIndex
                {
                    await present(
                        plan: activeProgram,
                        slotIndex: slotIndex
                    )
                } else {
                    await refreshAgentContext()
                }
            } catch {
                await realtimeDJSessionController.deactivate()
                guard RealtimeVoiceStatusStore.shared.state == .connecting
                else {
                    return
                }
                realtimeVoiceTimeoutTask?.cancel()
                orbWindowController?.setVoiceLevel(0)
                orbWindowController?.setState(.failed)
                setRealtimeVoiceState(.failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                ))
            }
        }
    }

    private func prepareInterruptionCoordinator() {
        let route = RealtimeVoicePlaybackAudioRoute.resolve(
            hasExistingPlaybackAudio: audioGraphStorage != nil
        )
        guard
            route == .reuseExistingPlaybackAudio,
            interruptionCoordinator == nil,
            let audioGraphStorage
        else {
            return
        }
        interruptionCoordinator = InterruptionCoordinator(
            audio: audioGraphStorage,
            interruptSession: { [weak self] in
                try? await self?.realtimeDJSessionController.interrupt()
            },
            updateState: { [weak self] state in
                self?.orbWindowController?.setState(state)
            }
        )
    }

    func disconnectRealtimeVoice() {
        realtimeVoiceConnectionTask?.cancel()
        realtimeVoiceConnectionTask = nil
        realtimeVoiceTimeoutTask?.cancel()
        realtimeVoiceTimeoutTask = nil
        setRealtimeVoiceState(.disconnected)
        orbWindowController?.setVoiceLevel(0)
        orbWindowController?.setState(
            audioGraphStorage?.isMusicPlaying == true
                ? .playing
                : .idle
        )
        Task { [weak self] in
            guard let self else {
                return
            }
            await realtimeDJSessionController.deactivate()
            agentToolDispatcher.resetSession()
        }
    }

    func toggleRealtimeVoiceFromStage() {
        switch RealtimeVoiceStatusStore.shared.state {
        case .connecting:
            disconnectRealtimeVoice()
        case .connected, .listening, .speaking:
            disconnectRealtimeVoice()
        case .disconnected, .failed:
            let configuration = realtimeVoicePreferences.load()
            guard configuration.isReadyToConnect else {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "先设置 DJ 的声音"
                alert.informativeText =
                    "在“设置 → DJ”里完成当前语音服务配置，然后回到舞台开麦。"
                alert.runModal()
                return
            }
            connectRealtimeVoice(configuration)
        }
    }

    func refreshAgentConfiguration() {
        Task { [weak self] in
            await self?.refreshAgentContext()
        }
    }

    func closeStage() {
        stageWindowController?.close()
    }

    func chooseLocalTrack() {
        let panel = NSOpenPanel()
        panel.title = "选择一首音乐"
        panel.prompt = "播放"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            activeProgram = nil
            updateStageProgramNavigation()
            try playLocalTrack(url)
        } catch {
            presentPlaybackError(error)
        }
    }

    func toggleLocalPlayback() {
        let route = ProgramPlaybackToggleRoute.resolve(
            playerState: localMusicPlayer.state,
            hasPreparedProgram:
                activeProgram != nil && programPlaybackQueue.current != nil
        )
        playbackLogger.info(
            "底部播放按钮：player=\(String(describing: self.localMusicPlayer.state), privacy: .public)，route=\(String(describing: route), privacy: .public)，queue=\(self.programPlaybackQueue.current?.slot.track.id ?? "nil", privacy: .public)"
        )
        switch route {
        case .pauseLocal:
            localMusicPlayer.pause()
            orbWindowController?.setState(.idle)
            stageWindowController?.setPlaybackState(.paused)
        case .resumeLocal:
            do {
                try localMusicPlayer.play()
                orbWindowController?.setState(.playing)
                stageWindowController?.setPlaybackState(.playing)
            } catch {
                presentPlaybackError(error)
            }
        case .startPreparedProgram:
            startPreparedProgramPlayback()
        case .unavailable:
            break
        }
    }

    func exitImmersiveVisuals() {
        orbWindowController?.exitImmersiveVisuals()
    }

    private func playLocalTrack(
        _ url: URL,
        loadSidecarLyrics: Bool = true
    ) throws {
        playbackLogger.info(
            "本地播放开始：url=\(url.path, privacy: .public)，sidecar=\(loadSidecarLyrics)"
        )
        if loadSidecarLyrics {
            stageArtwork.clear()
        }
        do {
            try localMusicPlayer.load(url)
            playbackLogger.info(
                "本地音频已加载：state=\(String(describing: self.localMusicPlayer.state), privacy: .public)，duration=\(self.localMusicPlayer.track?.duration ?? 0, format: .fixed(precision: 2))"
            )
            prepareInterruptionCoordinator()
            if loadSidecarLyrics {
                publishSidecarLyrics(
                    for: url,
                    trackDuration: localMusicPlayer.track?.duration
                )
            }
            try localMusicPlayer.play()
        } catch {
            playbackLogger.error(
                "本地播放失败：url=\(url.path, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        playbackLogger.info(
            "本地音频已启动：state=\(String(describing: self.localMusicPlayer.state), privacy: .public)"
        )
        orbWindowController?.setState(.playing)
        stageWindowController?.setPlaybackState(.playing)
    }

    private func presentPlaybackError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "这首音乐暂时播放不了"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func presentProgramError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let nsError = error as NSError
        if
            nsError.domain == NSURLErrorDomain,
            nsError.code
                == NSURLErrorAppTransportSecurityRequiresSecureConnection
        {
            alert.messageText = "音乐资源连接失败"
            alert.informativeText =
                "音乐服务返回了不安全的播放地址，应用已阻止连接。"
        } else {
            alert.messageText = "DJ 暂时无法完成这个操作"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func restoreSavedProgramPlayback() {
        guard programStore.plan != nil else {
            playbackLogger.info("没有本地节目存档，跳过恢复")
            return
        }
        playbackLogger.info(
            "恢复节目：savedIndex=\(self.programStore.activeSlotIndex ?? -1)"
        )
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let restored = try await SavedProgramPlaybackRestorer(
                    queue: programPlaybackQueue
                ).restore(from: programStore)
                guard let restored else {
                    playbackLogger.error("节目存档存在，但恢复结果为空")
                    return
                }
                activeProgram = restored.plan
                if let restoredIndex = restored.plan.slots.firstIndex(
                    where: {
                        $0.track.id == restored.prepared.slot.track.id
                    }
                ) {
                    programStore.activateSlot(at: restoredIndex)
                }
                playbackLogger.info(
                    "节目恢复完成：track=\(restored.prepared.slot.track.id, privacy: .public)，title=\(restored.prepared.slot.track.title, privacy: .public)，state=\(String(describing: restored.playbackState), privacy: .public)"
                )
                stageWindowController?.setPlaybackState(
                    restored.playbackState
                )
                updateStageProgramNavigation()
            } catch {
                playbackLogger.error(
                    "节目恢复失败：\(error.localizedDescription, privacy: .public)"
                )
                activeProgram = nil
                stageWindowController?.setPlaybackState(.idle)
                updateStageProgramNavigation()
                programStore.fail("上次节目暂时无法继续播放")
            }
        }
    }

    private func startPreparedProgramPlayback() {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await startSelectedProgramPlayback()
            } catch {
                programStore.fail(error.localizedDescription)
                presentProgramError(error)
            }
        }
    }

    private func startSelectedProgramPlayback(
        requestOpening: Bool = true,
        allowFallback: Bool = false
    ) async throws {
        playbackLogger.info(
            "请求播放当前歌曲：busy=\(self.isStartingProgramPlayback)，player=\(String(describing: self.localMusicPlayer.state), privacy: .public)，store=\(self.programStore.activeSlot?.track.id ?? "nil", privacy: .public)，queue=\(self.programPlaybackQueue.current?.slot.track.id ?? "nil", privacy: .public)"
        )
        guard !isStartingProgramPlayback else {
            playbackLogger.error("播放被拒绝：已有启动任务正在执行")
            throw DJAgentRadioActionError.busy
        }
        guard
            activeProgram != nil,
            let prepared = programPlaybackQueue.current
        else {
            playbackLogger.error(
                "播放被拒绝：activeProgram=\(self.activeProgram != nil)，queueCurrent=\(self.programPlaybackQueue.current != nil)"
            )
            throw DJAgentRadioActionError.noProgram
        }

        isStartingProgramPlayback = true
        stageWindowController?.setPlaybackState(.idle)
        defer {
            isStartingProgramPlayback = false
        }
        do {
            try await playPreparedWithFallback(
                prepared,
                requestOpening: requestOpening,
                allowFallback: allowFallback
            )
        } catch {
            playbackLogger.error(
                "当前歌曲启动失败：track=\(prepared.slot.track.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            let canRetry = programPlaybackQueue.current != nil
            stageWindowController?.setPlaybackState(
                canRetry ? .ready : .idle
            )
            throw error
        }
    }

    private func playProgramTrack(
        programID: String,
        at slotIndex: Int
    ) {
        guard
            !isStartingProgramPlayback,
            let plan = programStore.selectProgram(id: programID)
                ?? (
                    programStore.plan?.brief.id == programID
                        ? programStore.plan
                        : nil
                ),
            plan.slots.indices.contains(slotIndex)
        else {
            return
        }
        activeProgram = plan
        isStartingProgramPlayback = true
        localMusicPlayer.pause()
        stageWindowController?.setPlaybackState(.idle)
        stageWindowController?.setProgramNavigation(
            canGoPrevious: false,
            canGoNext: false
        )
        Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                isStartingProgramPlayback = false
            }
            do {
                try await programPlaybackQueue.select(
                    plan,
                    at: slotIndex
                )
                guard let prepared = programPlaybackQueue.current else {
                    throw ProgramPlaybackQueueError.noPlayableSlots(
                        failedTrackIDs: programPlaybackQueue.failedTrackIDs
                    )
                }
                try await playPreparedWithFallback(
                    prepared,
                    allowFallback: false
                )
            } catch {
                let canRetry = programPlaybackQueue.current != nil
                stageWindowController?.setPlaybackState(
                    canRetry ? .ready : .idle
                )
                updateStageProgramNavigation()
                programStore.fail(error.localizedDescription)
                presentProgramError(error)
            }
        }
    }

    private func advanceProgram() {
        guard activeProgram != nil else {
            return
        }
        stageWindowController?.setPlaybackState(.finished)
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                if let completed = programPlaybackQueue.current?.slot.track {
                    await musicRuntime.recordPlaybackCompleted(completed)
                }
                guard
                    let next = await programPlaybackQueue
                        .advanceAfterCompletion()
                else {
                    activeProgram = nil
                    stageLyrics.clear()
                    orbWindowController?.setState(.idle)
                    stageWindowController?.setPlaybackState(.idle)
                    updateStageProgramNavigation()
                    return
                }
                try await playPreparedWithFallback(next)
            } catch {
                programStore.fail(error.localizedDescription)
                presentProgramError(error)
            }
        }
    }

    private func playPreviousProgramTrack() {
        guard
            activeProgram != nil,
            let previous = programPlaybackQueue.returnToPrevious()
        else {
            return
        }
        updateStageProgramNavigation()
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await playPreparedWithFallback(previous)
            } catch {
                programStore.fail(error.localizedDescription)
                presentProgramError(error)
            }
        }
    }

    private func playNextProgramTrack() {
        guard activeProgram != nil else {
            return
        }
        stageWindowController?.setProgramNavigation(
            canGoPrevious: false,
            canGoNext: false
        )
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                guard
                    let next = await programPlaybackQueue
                        .advanceAfterCompletion()
                else {
                    activeProgram = nil
                    stageLyrics.clear()
                    orbWindowController?.setState(.idle)
                    stageWindowController?.setPlaybackState(.idle)
                    updateStageProgramNavigation()
                    return
                }
                try await playPreparedWithFallback(next)
            } catch {
                updateStageProgramNavigation()
                programStore.fail(error.localizedDescription)
                presentProgramError(error)
            }
        }
    }

    private func playPreparedWithFallback(
        _ initial: PreparedProgramPlayback,
        requestOpening: Bool = true,
        allowFallback: Bool = true
    ) async throws {
        playbackLogger.info(
            "准备播放：track=\(initial.slot.track.id, privacy: .public)，title=\(initial.slot.track.title, privacy: .public)，fallback=\(allowFallback)，opening=\(requestOpening)"
        )
        var prepared: PreparedProgramPlayback? = initial
        while let candidate = prepared {
            do {
                try await playPrepared(
                    candidate,
                    requestOpening: requestOpening
                )
                return
            } catch {
                playbackLogger.error(
                    "歌曲播放失败：track=\(candidate.slot.track.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                guard allowFallback else {
                    throw error
                }
                prepared = await programPlaybackQueue
                    .replaceCurrentAfterFailure()
                playbackLogger.info(
                    "自动候补：next=\(prepared?.slot.track.id ?? "nil", privacy: .public)"
                )
            }
        }
        throw ProgramPlaybackQueueError.noPlayableSlots(
            failedTrackIDs: programPlaybackQueue.failedTrackIDs
        )
    }

    private func playPrepared(
        _ prepared: PreparedProgramPlayback,
        requestOpening: Bool = true
    ) async throws {
        guard let activeProgram else {
            playbackLogger.error("播放中止：activeProgram 为空")
            throw DJAgentRadioActionError.noProgram
        }
        let slot = prepared.slot
        guard let index = activeProgram.slots.firstIndex(where: {
            $0.track.id == slot.track.id
        }) else {
            playbackLogger.error(
                "播放中止：queue track \(slot.track.id, privacy: .public) 不在 activeProgram"
            )
            throw DJAgentRadioActionError.trackNotFound
        }

        playbackLogger.info(
            "执行歌曲播放：index=\(index)，track=\(slot.track.id, privacy: .public)，provider=\(slot.track.providerID.rawValue, privacy: .public)，title=\(slot.track.title, privacy: .public)，target=\(String(describing: prepared.target), privacy: .public)"
        )
        let previouslyCommittedTrack = committedPlaybackTrack

        switch prepared.target {
        case let .localFile(url):
            try playLocalTrack(url, loadSidecarLyrics: false)
        case let .providerReference(providerID, trackID):
            guard providerID == .appleMusic else {
                throw MusicProviderClientError.playbackUnavailable
            }
            try await musicRuntime.startAppleMusic(trackID: trackID)
            orbWindowController?.setState(.playing)
            stageWindowController?.setPlaybackState(.playing)
        }

        previousCommittedPlaybackTrack = previouslyCommittedTrack
        committedPlaybackTrack = slot.track
        programStore.activateSlot(at: index)
        stageLyrics.clear()
        Task { [weak self] in
            guard let self else {
                return
            }
            let artworkURL = await musicRuntime.artworkURL(for: slot.track)
            guard programStore.activeSlot?.track.id == slot.track.id else {
                return
            }
            await stageArtwork.load(from: artworkURL)
        }
        let visualCue = ProgramVisualDirector().cue(for: slot)
        stageVisualDirections.update(visualCue)
        stageVideos.apply(
            visualCue,
            trackID: slot.track.id,
            trackTitle: slot.track.title
        )
        await present(plan: activeProgram, slotIndex: index)
        let lyricTrackID = slot.track.id
        Task { [weak self] in
            guard
                let self,
                let lyrics = try? await musicRuntime.lyrics(for: slot.track),
                programStore.activeSlot?.track.id == lyricTrackID
            else {
                return
            }
            stageLyrics.publish(
                lyrics,
                trackID: lyricTrackID,
                trackDuration: slot.track.duration
            )
        }
        updateStageProgramNavigation()
        playbackLogger.info(
            "歌曲播放链路完成：track=\(slot.track.id, privacy: .public)，player=\(String(describing: self.localMusicPlayer.state), privacy: .public)"
        )
        if requestOpening {
            await requestTrackOpeningIfNeeded(
                for: slot.hostHint,
                forceForProgramBeat:
                    shouldForceProgramBeat(
                        plan: activeProgram,
                        slot: slot
                    )
            )
        }
    }

    private func requestTrackOpeningIfNeeded(
        for hint: ProgramHostHint,
        forceForProgramBeat: Bool = false
    ) async {
        guard let instruction = DJTrackOpeningRequestBuilder()
            .instruction(
                for: hint,
                forceForProgramBeat: forceForProgramBeat
            )
        else {
            return
        }
        try? await realtimeDJSessionController
            .requestAgentResponse(instruction)
    }

    private func shouldForceProgramBeat(
        plan: ProgramPlan,
        slot: ProgramSlot
    ) -> Bool {
        guard plan.brief.conversationMode != .quiet else {
            return false
        }
        let instruction = plan.brief.immediateUserInstruction?
            .lowercased() ?? ""
        let asksForLessTalk = [
            "少说",
            "安静",
            "别说",
            "不用介绍",
            "quiet",
            "less talk",
            "no talking",
        ].contains(where: instruction.contains)
        guard !asksForLessTalk else {
            return false
        }
        return slot.role == .peak || slot.role == .closer
    }

    private func present(
        plan: ProgramPlan,
        slotIndex: Int
    ) async {
        guard plan.slots.indices.contains(slotIndex) else {
            return
        }
        let current = plan.slots[slotIndex]
        let upcoming = plan.slots
            .dropFirst(slotIndex + 1)
            .map(\.track.id)
        let queuedNext = programPlaybackQueue.locked.first?.slot.track
        let runtimeHostHint = ProgramHostHint(
            shouldTalkBefore: current.hostHint.shouldTalkBefore,
            maxSentenceCount: current.hostHint.maxSentenceCount,
            selectionReason: current.hostHint.selectionReason,
            currentTrack: TrackReference(
                id: current.track.id,
                title: current.track.title,
                artist: current.track.artist
            ),
            nextTrack: queuedNext.map {
                TrackReference(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist
                )
            },
            facts: current.hostHint.facts,
            transitionIntent: current.hostHint.transitionIntent
        )
        let context = RealtimeDJContext(
            playback: PlaybackContext(
                currentTrack: TrackReference(
                    id: current.track.id,
                    title: current.track.title,
                    artist: current.track.artist
                ),
                upcomingTrackIDs: upcoming,
                conversationMode: plan.brief.conversationMode,
                programID: plan.brief.id
            ),
            showPlanSummary: plan.title
                ?? "GMGN RADIO · \(plan.slots.count) 首",
            hostHint: runtimeHostHint,
            hostPreference: DJAgentPreferences().hostPrompt(),
            immediateUserInstruction:
                plan.brief.immediateUserInstruction,
            agentControl: snapshot(
                takeoverEnabled:
                    agentPreferences.takeoverEnabled()
            )
        )
        stagePresentation.apply(context)
        try? await realtimeDJSessionController.updateContext(context)
    }

    private func refreshAgentContext() async {
        if
            let activeProgram,
            let slotIndex = programStore.activeSlotIndex
        {
            await present(plan: activeProgram, slotIndex: slotIndex)
            return
        }
        let context = RealtimeDJContext(
            playback: PlaybackContext(),
            showPlanSummary: programStore.plan?.title
                ?? "当前还没有节目",
            hostPreference: agentPreferences.hostPrompt(),
            agentControl: snapshot(
                takeoverEnabled:
                    agentPreferences.takeoverEnabled()
            )
        )
        stagePresentation.apply(context)
        try? await realtimeDJSessionController.updateContext(context)
    }

    private static func currentProgramBrief(
        immediateUserInstruction: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProgramBrief {
        let hour = calendar.component(.hour, from: now)
        let moodTags: [String]
        let energyArc: [Double]
        switch hour {
        case 0 ..< 6:
            moodTags = ["深夜", "松弛", "陪伴"]
            energyArc = [0.2, 0.35, 0.25]
        case 6 ..< 11:
            moodTags = ["清晨", "清醒", "明亮"]
            energyArc = [0.35, 0.65, 0.55]
        case 11 ..< 18:
            moodTags = ["白天", "专注", "流动"]
            energyArc = [0.45, 0.7, 0.55]
        default:
            moodTags = ["夜晚", "放松", "氛围"]
            energyArc = [0.4, 0.7, 0.35]
        }
        return ProgramBrief(
            id: "program-\(UUID().uuidString)",
            targetDuration: 1_800,
            moodTags: moodTags,
            energyArc: energyArc,
            conversationMode: .ambient,
            immediateUserInstruction: immediateUserInstruction
        )
    }

    private func configureLivingWorld() {
        guard livingWorldContext == nil else { return }

        do {
            let package = try LivingWorldBootstrap.loadBundledCanary(
                preferMarble: DefaultSpacePreference.load() == .livingPod
            )
            let marbleCabin = try LivingWorldBootstrap.loadMarbleCabin(package: package)
            // Bind the generated package before renderer initialization can prewarm
            // an unrelated saved Marble world.
            if let marbleCabin {
                spatialStage.marbleLivingCabin = marbleCabin.presentation
                marbleWorldLibrary.adoptCachedWorld(
                    marbleCabin.world, splatURL: marbleCabin.splatURL,
                    colliderURL: marbleCabin.colliderURL
                )
                spatialStage.installCameraHome(marbleCabin.presentation.camera)
                spatialStage.installAvatarPlacement(marbleCabin.presentation.avatarPlacement)
            } else if DefaultSpacePreference.load() == .livingPod {
                marbleWorldLibrary.selectLocalWorld(id: package.manifest.worldID, scene: .djHouse)
            }
            if stageRenderSurfaceController == nil {
                stageRenderSurfaceController = StageRenderSurfaceController(
                    spatialStage: spatialStage, library: marbleWorldLibrary,
                    avatarRuntime: avatarRuntime
                )
            }
            if stageCameraCoordinator == nil {
                stageCameraCoordinator = StageCameraCoordinator(spatialStage: spatialStage)
            }
            let avatarExecutor = StageAvatarActivityExecutor(
                runtime: avatarRuntime,
                spatialStage: spatialStage,
                worldSpawn: package.manifest.spawn
            )
            var supplementalMotions: [String: StageMotionAsset] = [:]
            let installedMotions = try motionPackageStore?.listMotions() ?? []
            if let slapBass = installedMotions.first(where: {
                $0.id == MotionPackageStore.iluvSlapBassID
            }) {
                supplementalMotions["listen.music"] = slapBass
            }
            supplementalMotions.merge(
                LivingWorldBootstrap.approvedInstalledMotions(installedMotions),
                uniquingKeysWith: { _, installed in installed }
            )
            livingWorldApprovedMotions = try LivingWorldBootstrap.approvedMotions(
                resources: package.manifest.resources,
                packageRoot: package.packageRoot,
                supplementalMotions: supplementalMotions
            )
            let context = try LivingWorldBootstrap.makeContext(
                package: package,
                walkingSpeed: LivingWorldBootstrap.walkingSpeed(
                    approvedMotions: livingWorldApprovedMotions
                )
            )
            livingWorldContext = context
            LivingWorldActivityMenuStore.shared.update(
                definitions: context.manifest.activityDefinitions,
                worldID: context.manifest.worldID
            )
            stageAvatarActivityExecutor = avatarExecutor
            worldAgentToolDispatcher = WorldAgentToolDispatcher(
                takeoverEnabled: { [weak self] in
                    self?.agentPreferences.takeoverEnabled() ?? false
                },
                context: context
            )
            context.onSnapshotChanged = { [weak self] snapshot in
                self?.applyLivingWorldSnapshot(snapshot)
            }
            context.onTickError = { [weak self] error in
                self?.livingWorldLogger.error(
                    "生活空间推进失败：\(error.localizedDescription, privacy: .public)"
                )
            }
            sceneFramingObserverID = spatialStage.observeSceneFraming {
                [weak self] framing in
                self?.prepareLivingWorldCollider(framing: framing)
            }

            if context.snapshot.liveCamera == nil,
               let initialCameraID = package.manifest.cameras.first?.id
            {
                try context.selectCamera(id: initialCameraID)
            } else {
                applyLivingWorldSnapshot(context.snapshot)
            }
            context.startTicking()

            livingWorldVisualTask?.cancel()
            livingWorldVisualTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if marbleCabin != nil {
                    spatialStage.requestWorldPresentation()
                    // The SPZ renderer signals completion only after load succeeds.
                    return
                }
                if DefaultSpacePreference.load() == .livingPod {
                    installLocalLivingPodPresentation(package: package)
                    return
                }
                // Legacy Marble worlds: resolve the SPZ through the world
                // catalog and only then ask for the world presentation.
                let localURL = await marbleWorldLibrary.select(
                    worldID: package.manifest.worldID
                )
                guard !Task.isCancelled else { return }
                if localURL == nil {
                    livingWorldLogger.error(
                        "Warm Kitchen 视觉资源加载失败，保留世界控制与角色状态"
                    )
                }
                spatialStage.requestWorldPresentation()
            }
            let stateVersionDirectory = LivingWorldBootstrap
                .sanitizedPackageVersionDirectory(package.manifest.packageVersion)
            livingWorldLogger.info(
                "生活空间已启动：world=\(package.manifest.worldID, privacy: .public)，state=Application Support/LivingWorld/\(package.manifest.packageID, privacy: .public)/\(stateVersionDirectory, privacy: .public)/state.json"
            )
        } catch {
            marbleWorldLibrary.reportLivingCabinFailure(error)
            liveCamWindowController?.showChatStatus(error.localizedDescription)
            livingWorldLogger.error(
                "生活空间启动失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Boots the bundled living pod on the stage without touching the Marble
    /// catalog: the pod ships with the app, so selecting a remote SPZ or
    /// reporting a "Warm Kitchen" visual failure would be wrong. The stage is
    /// pointed at the local world, the package-authored camera and spawn
    /// calibration are installed, and the world presentation is completed
    /// immediately because the pod renders synchronously from SceneKit.
    private func installLocalLivingPodPresentation(
        package: BundledLivingWorldPackage
    ) {
        marbleWorldLibrary.selectLocalWorld(
            id: package.manifest.worldID,
            scene: .djHouse
        )
        if let calibration = SpatialWorldCalibration.resolve(
            worldID: package.manifest.worldID
        ) {
            spatialStage.installCameraHome(calibration.cameraHome)
            if let avatarPlacement = calibration.avatarPlacement {
                spatialStage.installAvatarPlacement(avatarPlacement)
            }
        }
        spatialStage.requestWorldPresentation()
        spatialStage.finishWorldPresentation()
        livingWorldLogger.info(
            "生活舱本地画面已就绪：world=\(package.manifest.worldID, privacy: .public)"
        )
    }

    private func prepareLivingWorldCollider(
        framing: MarbleSceneFraming
    ) {
        guard let context = livingWorldContext,
              livingWorldColliderFraming != framing
        else {
            return
        }
        livingWorldColliderFraming = framing
        let worldID = context.manifest.worldID
        livingWorldColliderTask?.cancel()
        livingWorldColliderTask = Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            do {
                guard let (url, sourceCoordinates) = try await marbleWorldLibrary
                    .localCollider(for: worldID)
                else {
                    if spatialStage.marbleLivingCabin?.worldID == worldID {
                        throw LivingWorldBootstrapError.invalidMarbleCabin("没有找到生成舱体的碰撞网格。")
                    }
                    livingWorldLogger.notice(
                        "空间没有碰撞 GLB，继续使用包内碰撞体：world=\(worldID, privacy: .public)"
                    )
                    return
                }
                let transform = framing.colliderTransform(
                    sourceCoordinates: sourceCoordinates
                )
                let prepared = try await Task.detached(priority: .utility) {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let triangles = try GLBColliderDecoder().decode(
                        data: data,
                        transform: transform
                    )
                    return (
                        TriangleMeshCollisionWorld(triangles: triangles),
                        triangles
                    )
                }.value
                try Task.checkCancellation()
                guard self.livingWorldContext === context,
                      self.spatialStage.selectedWorldID == worldID
                else {
                    return
                }
                spatialStage.installSceneOccluderTriangles(prepared.1)
                let collision: any WorldCollisionQuerying
                if spatialStage.marbleLivingCabin?.worldID == worldID {
                    collision = MarbleLivingCabinCollisionWorld(
                        environment: prepared.0,
                        props: CollisionVolumeWorld(volumes: context.manifest.collisionVolumes.filter {
                            $0.id == "collision.jukebox"
                        })
                    )
                } else {
                    collision = prepared.0
                }
                let correctedPosition = try context
                    .installCollisionWorldAndReconcilePlacement(collision)
                if let correctedPosition {
                    livingWorldLogger.notice(
                        "碰撞 GLB 修正角色落点：x=\(correctedPosition.x, privacy: .public)，y=\(correctedPosition.y, privacy: .public)，z=\(correctedPosition.z, privacy: .public)"
                    )
                }
                livingWorldLogger.notice(
                    "碰撞与遮挡 GLB 已接管生活空间：world=\(worldID, privacy: .public)，triangles=\(prepared.1.count, privacy: .public)"
                )
            } catch is CancellationError {
                return
            } catch {
                livingWorldColliderFraming = nil
                if spatialStage.marbleLivingCabin?.worldID == worldID {
                    spatialStage.exitWorld()
                    marbleWorldLibrary.reportLivingCabinFailure(error)
                    liveCamWindowController?.showChatStatus("生活舱碰撞网格加载失败：\(error.localizedDescription)")
                    livingWorldLogger.error("生成生活舱碰撞加载失败：\(error.localizedDescription, privacy: .public)")
                    return
                }
                livingWorldLogger.error(
                    "碰撞 GLB 加载失败，继续使用包内碰撞体：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func applyLivingWorldSnapshot(_ snapshot: WorldAgentSnapshot) {
        LivingWorldActivityMenuStore.shared.updateActiveActivity(id: snapshot.activeActivity?.id)
        performLivingCabinJukeboxEffect(snapshot)
        let spatialWeather: SpatialWeather = switch snapshot.weather {
        case .clear, .cloudy:
            .clear
        case .rain, .snow:
            .rain
        }
        if spatialStage.environment.weather != spatialWeather {
            spatialStage.applyEnvironment(weather: spatialWeather)
        }

        if let liveCamera = snapshot.liveCamera,
           let stageCameraCoordinator
        {
            let camera = Self.spatialCamera(from: liveCamera.transform)
            if stageCameraCoordinator.savedDirectorCamera != camera {
                stageCameraCoordinator.updateDirectorCamera(camera)
            }
        }

        guard let stageAvatarActivityExecutor,
              let context = livingWorldContext
        else {
            return
        }
        let activity: LifeActivity
        let phase: LifeActivityPhase
        let presentationMode: LivingWorldAvatarPresentationMode
        let authoredContract: ActivityPhaseContract?
        if let active = snapshot.activeActivity {
            activity = active.activity
            phase = active.phase
            presentationMode = .semanticActivity
            authoredContract = context.activityCatalog
                .definition(id: active.id)?
                .contract(for: active.phase)
        } else if let movement = snapshot.movement {
            activity = .walk(destinationID: movement.destinationID)
            phase = .approach
            presentationMode = .semanticActivity
            authoredContract = context.activityCatalog.definitions.first(where: {
                $0.activity.typeID == "walk"
            })?.contract(for: .approach)
        } else {
            activity = .idle
            phase = .loop
            presentationMode = .userIdle
            authoredContract = context.activityCatalog.definitions.first(where: {
                $0.activity.typeID == "idle"
            })?.contract(for: .loop)
        }
        let contract = LivingWorldAvatarPresentationPolicy.phaseContract(
            mode: presentationMode,
            authoredContract: authoredContract
        )
        let previousAvatarPosition = spatialStage.avatarPlacement.position
        _ = stageAvatarActivityExecutor.apply(
            transform: snapshot.agentTransform,
            activity: activity,
            phase: phase,
            sourceRevision: snapshot.revision,
            phaseContract: contract,
            approvedMotions: LivingWorldAvatarPresentationPolicy
                .compatibleMotions(
                    livingWorldApprovedMotions,
                    avatarFormat: avatarRuntime.snapshot.avatar?.format
                )
        )
        stageCameraCoordinator?.followAvatarHorizontally(
            from: previousAvatarPosition,
            to: spatialStage.avatarPlacement.position
        )
    }

    private func performLivingCabinJukeboxEffect(_ snapshot: WorldAgentSnapshot) {
        guard spatialStage.marbleLivingCabin?.worldID == snapshot.worldID,
              spatialStage.selectedWorldID == snapshot.worldID,
              let active = snapshot.activeActivity,
              let startedAt = livingWorldContext?.simulation.state.activeActivity?.startedAt,
              livingCabinJukeboxGate.consume(
                worldID: snapshot.worldID, activityID: active.id,
                startedAt: startedAt, phase: active.phase.rawValue
              ) else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  spatialStage.selectedWorldID == snapshot.worldID,
                  livingWorldContext?.simulation.state.activeActivity?.startedAt == startedAt,
                  livingWorldContext?.snapshot.activeActivity?.id == "music.listen"
            else { return }
            do {
                try await resumeMusic()
                liveCamWindowController?.showChatStatus("点唱机开始播放音乐。")
            } catch {
                liveCamWindowController?.showChatStatus(
                    "点唱机暂时无法播放，请先在播放器选择音乐。\(error.localizedDescription)"
                )
                livingWorldLogger.error("点唱机播放失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func refreshInstalledLivingWorldMotions() {
        guard
            let motionPackageStore,
            let motions = try? motionPackageStore.listMotions()
        else {
            return
        }
        let knownIDs = LivingWorldBootstrap.installedLivingMotionIDs
        var updated = livingWorldApprovedMotions.filter {
            !knownIDs.contains($0.key)
        }
        updated.merge(
            LivingWorldBootstrap.approvedInstalledMotions(motions),
            uniquingKeysWith: { _, installed in installed }
        )
        guard updated != livingWorldApprovedMotions else { return }
        livingWorldApprovedMotions = updated
        if let snapshot = livingWorldContext?.snapshot {
            applyLivingWorldSnapshot(snapshot)
        }
    }

    private static func spatialCamera(
        from transform: WorldTransform
    ) -> SpatialCameraState {
        let rotation = transform.rotation
        let yaw = atan2(
            2 * (rotation.w * rotation.y + rotation.x * rotation.z),
            1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z)
        )
        let pitchSine = min(
            max(2 * (rotation.w * rotation.x - rotation.z * rotation.y), -1),
            1
        )
        return SpatialCameraState(
            position: SIMD3(
                transform.position.x,
                transform.position.y,
                transform.position.z
            ),
            yaw: yaw,
            pitch: asin(pitchSine)
        )
    }

    private func configureStage() {
        guard stageWindowController == nil else { return }
        if stageRenderSurfaceController == nil
            || stageCameraCoordinator == nil
        {
            configureLivingWorld()
        }
        guard let stageRenderSurfaceController,
              let stageCameraCoordinator
        else {
            livingWorldLogger.error("共享空间画面初始化失败")
            return
        }
        let monitor: VisualAudioInputMonitor?
        if VisualAudioInputPolicy.usesMicrophone(
            environment: ProcessInfo.processInfo.environment
        ) {
            monitor = VisualAudioInputMonitor(store: audioFeatures)
        } else {
            monitor = nil
        }
        stageAudioMonitor = monitor
        stageWindowController = StageWindowController(
            audioFeatures: audioFeatures,
            artwork: stageArtwork,
            audioMonitor: monitor,
            presentation: stagePresentation,
            visualDirections: stageVisualDirections,
            videos: stageVideos,
            programStore: programStore,
            libraryStore: musicLibraryStore,
            lyrics: stageLyrics,
            spatialStage: spatialStage,
            marbleLibrary: marbleWorldLibrary,
            avatarRuntime: avatarRuntime,
            renderSurfaceController: stageRenderSurfaceController,
            cameraCoordinator: stageCameraCoordinator,
            playbackPosition: { [weak self] in
                self?.audioGraphStorage?.playbackPosition ?? 0
            },
            playbackState: .idle,
            voiceState: RealtimeVoiceStatusStore.shared.state,
            onTogglePlayback: { [weak self] in
                self?.toggleLocalPlayback()
            },
            onPlayProgramTrack: { [weak self] programID, slotIndex in
                self?.playProgramTrack(
                    programID: programID,
                    at: slotIndex
                )
            },
            onPlayLibraryTrack: { [weak self] playlistID, trackIndex in
                self?.playSyncedPlaylist(
                    playlistID: playlistID,
                    at: trackIndex
                )
            },
            onOpenLibraryPlaylist: { [weak self] playlistID in
                self?.loadNextSyncedPlaylistPage(playlistID: playlistID)
            },
            onLoadMoreLibraryTracks: { [weak self] playlistID in
                self?.loadNextSyncedPlaylistPage(playlistID: playlistID)
            },
            onPreviousTrack: { [weak self] in
                self?.playPreviousProgramTrack()
            },
            onNextTrack: { [weak self] in
                self?.playNextProgramTrack()
            },
            onReplanProgram: { [weak self] in
                self?.replanUpcomingProgramFromStage()
            },
            onToggleVoice: { [weak self] in
                self?.toggleRealtimeVoiceFromStage()
            },
            onRunActivity: { [weak self] id in
                self?.runLivingWorldActivity(id: id)
            },
            onStopActivity: { [weak self] in
                self?.stopLivingWorldActivity()
            },
            onManageAssets: { [weak self] in
                self?.openPresenceSettings()
            }
        )
        if let stageWindowController {
            let liveCamWindowController = LiveCamWindowController(
                renderSurfaceController: stageRenderSurfaceController,
                cameraCoordinator: stageCameraCoordinator,
                voiceState: RealtimeVoiceStatusStore.shared.state,
                shouldPresent: { [weak self] in
                    guard let self else { return false }
                    return DesktopPresenceMode.resolve(
                        snapshot: self.avatarRuntime.snapshot
                    ) == .liveCam
                },
                onEnterSpace: { [weak self] in
                    self?.showStage()
                },
                onOpenPlayer: { [weak self] in
                    self?.showPlayer()
                },
                onOpenSettings: { [weak self] in
                    self?.openSystemSettings()
                },
                onPreviousTrack: { [weak self] in
                    self?.playPreviousProgramTrack()
                },
                onTogglePlayback: { [weak self] in
                    self?.toggleLocalPlayback()
                },
                onNextTrack: { [weak self] in
                    self?.playNextProgramTrack()
                },
                playerMenuSnapshotProvider: { [weak self] in
                    self?.liveCamPlayerMenuSnapshot() ?? .noProgram
                },
                onSendMessage: { [weak self] message in
                    guard let self else { return }
                    await self.sendLiveCamMessage(message)
                },
                onToggleVoice: { [weak self] in
                    self?.toggleRealtimeVoiceFromStage()
                }
            )
            liveCamWindowController.connect(
                to: stageWindowController,
                onEnterSpace: { [weak self] in
                    self?.showStage()
                }
            )
            self.liveCamWindowController = liveCamWindowController
        }
        updateStageProgramNavigation()

        stagePresentationTask?.cancel()
        stagePresentationTask = Task { [weak self] in
            guard let self else {
                return
            }
            let events = await realtimeDJSessionController.eventStream()
            for await event in events {
                guard !Task.isCancelled else {
                    return
                }
                switch event {
                case let .userAudioLevel(level),
                     let .agentAudioLevel(level):
                    orbWindowController?.setVoiceLevel(level.peak)
                    stageWindowController?.setVoiceLevel(Float(level.peak))
                case .userSpeechStarted:
                    setRealtimeVoiceState(.listening)
                case .userSpeechFinished:
                    orbWindowController?.setVoiceLevel(0)
                    stageWindowController?.setVoiceLevel(0)
                    setRealtimeVoiceState(.connected)
                case .agentAudioStarted:
                    setRealtimeVoiceState(.speaking)
                case .agentAudioFinished:
                    orbWindowController?.setVoiceLevel(0)
                    stageWindowController?.setVoiceLevel(0)
                    setRealtimeVoiceState(.connected)
                case .agentResponseStarted:
                    // Live Cam 文字聊天由 AgentConversationService 负责，
                    // 不再消费实时语音事件作为正式回复。
                    break
                case .agentTranscriptDelta:
                    break
                case let .agentTranscriptFinal(text):
                    playbackLogger.info(
                        "语音 Agent 转写：\(text, privacy: .public)"
                    )
                case let .userTranscriptFinal(text):
                    playbackLogger.info(
                        "用户最终转写：\(text, privacy: .public)"
                    )
                    await handleDirectPlaybackIntent(text)
                    await handleDirectInsertIntent(text)
                    await handleDirectProgramIntent(text)
                    await handleDirectProgramSwitchIntent(text)
                case let .connectionChanged(state):
                    if state == .connected {
                        setRealtimeVoiceState(.connected)
                    } else if state == .disconnected {
                        setRealtimeVoiceState(.disconnected)
                        orbWindowController?.setVoiceLevel(0)
                        stageWindowController?.setVoiceLevel(0)
                    }
                case let .toolCall(call):
                    let arguments = String(
                        data: call.argumentsJSON,
                        encoding: .utf8
                    ) ?? "<invalid-json>"
                    playbackLogger.info(
                        "DJ 工具调用：id=\(call.id, privacy: .public)，name=\(call.name, privacy: .public)，arguments=\(arguments, privacy: .public)"
                    )
                    let result: RealtimeDJToolResult
                    if consumeRecentDirectTool(named: call.name) {
                        playbackLogger.info(
                            "DJ 工具已由本地语音动作提前执行，跳过重复调用：\(call.name, privacy: .public)"
                        )
                        result = acknowledgedDirectToolResult(for: call)
                    } else {
                        result = await agentToolDispatcher.handle(call)
                    }
                    let resultJSON = String(
                        data: result.resultJSON,
                        encoding: .utf8
                    ) ?? "<invalid-json>"
                    playbackLogger.info(
                        "DJ 工具结果：id=\(result.callID, privacy: .public)，isError=\(result.isError)，result=\(resultJSON, privacy: .public)"
                    )
                    do {
                        try await realtimeDJSessionController
                            .submitToolResult(result)
                    } catch {
                        playbackLogger.error(
                            "DJ 工具结果提交失败：id=\(result.callID, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                case let .failure(failure):
                    playbackLogger.error(
                        "实时语音故障：code=\(failure.code, privacy: .public)，recoverable=\(failure.recoverable)，message=\(failure.message, privacy: .public)"
                    )
                    liveCamWindowController?.showChatStatus(failure.message)
                default:
                    break
                }
                await interruptionCoordinator?.consume(event)
                stagePresentation.consume(event)
            }
        }
    }

    private func restoreSavedProgramPresentation() {
        guard let plan = programStore.plan else {
            activeProgram = nil
            updateStageProgramNavigation()
            return
        }
        activeProgram = plan
        stageWindowController?.setPlaybackState(.paused)
        updateStageProgramNavigation()
        playbackLogger.info(
            "恢复节目界面：program=\(plan.brief.id, privacy: .public)，slots=\(plan.slots.count)，index=\(self.programStore.activeSlotIndex ?? -1)"
        )
    }

    private func playSyncedPlaylist(
        playlistID: String,
        at trackIndex: Int
    ) {
        guard
            let playlist = musicLibraryStore.playlist(id: playlistID),
            playlist.tracks.indices.contains(trackIndex)
        else {
            return
        }
        let plan = SyncedPlaylistProgramBuilder.makePlan(from: playlist)
        programStore.publish(plan)
        playProgramTrack(programID: plan.brief.id, at: trackIndex)
    }

    private func loadNextSyncedPlaylistPage(playlistID: String) {
        guard
            let playlist = musicLibraryStore.playlist(id: playlistID),
            playlist.tracks.count < playlist.trackCount,
            musicLibraryStore.beginLoadingPage(playlistID: playlistID)
        else {
            return
        }
        let offset = playlist.tracks.count
        let providerID = playlist.providerID
        Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                musicLibraryStore.finishLoadingPage(
                    playlistID: playlistID
                )
            }
            do {
                let page = try await musicRuntime.fetchPlaylistPage(
                    providerID: providerID,
                    playlistID: playlistID,
                    offset: offset,
                    limit: 20
                )
                musicLibraryStore.append(page)
                playbackLogger.info(
                    "歌单渐进加载：playlist=\(playlistID, privacy: .public)，offset=\(offset)，loaded=\(page.tracks.count)，total=\(page.totalTrackCount)"
                )
            } catch {
                playbackLogger.error(
                    "歌单渐进加载失败：playlist=\(playlistID, privacy: .public)，offset=\(offset)，error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func handleDirectPlaybackIntent(_ transcript: String) async {
        let intent = DJDirectPlaybackIntent.resolve(transcript)
        playbackLogger.info(
            "本地播放意图：text=\(transcript, privacy: .public)，intent=\(String(describing: intent), privacy: .public)"
        )
        guard let intent else {
            return
        }
        do {
            let toolName: String
            switch intent {
            case .playCurrent:
                toolName = "resume_music"
                try await resumeMusic()
            case .next:
                toolName = "next_track"
                try await playNextTrack()
            case .previous:
                toolName = "previous_track"
                try await playPreviousTrack()
            case .pause:
                toolName = "pause_music"
                try await pauseMusic()
            }
            recentDirectToolName = toolName
            recentDirectToolDate = Date()
            if
                intent == .next,
                let activeProgram,
                let index = programStore.activeSlotIndex,
                activeProgram.slots.indices.contains(index)
            {
                let slot = activeProgram.slots[index]
                await requestTrackOpeningIfNeeded(
                    for: slot.hostHint,
                    forceForProgramBeat:
                        shouldForceProgramBeat(
                            plan: activeProgram,
                            slot: slot
                        )
                )
            }
            playbackLogger.info(
                "本地播放意图执行成功：\(toolName, privacy: .public)"
            )
        } catch {
            playbackLogger.error(
                "本地播放意图执行失败：\(error.localizedDescription, privacy: .public)"
            )
            presentProgramError(error)
        }
    }

    private func handleDirectProgramIntent(_ transcript: String) async {
        let intent = DJDirectProgramIntent.resolve(transcript)
        playbackLogger.info(
            "本地编排意图：text=\(transcript, privacy: .public)，intent=\(String(describing: intent), privacy: .public)"
        )
        guard case let .replan(instruction) = intent else {
            return
        }
        do {
            try await replanProgram(
                immediateInstruction: instruction
            )
            recentDirectToolName = "replan_program"
            recentDirectToolDate = Date()
            playbackLogger.info("本地编排意图执行成功：replan_program")
        } catch {
            playbackLogger.error(
                "本地编排意图执行失败：\(error.localizedDescription, privacy: .public)"
            )
            presentProgramError(error)
        }
    }

    private func handleDirectInsertIntent(_ transcript: String) async {
        let intent = DJDirectInsertIntent.resolve(transcript)
        playbackLogger.info(
            "本地插播意图：text=\(transcript, privacy: .public)，intent=\(String(describing: intent), privacy: .public)"
        )
        guard case let .insert(instruction) = intent else {
            return
        }
        do {
            try await insertTrack(immediateInstruction: instruction)
            recentDirectToolName = "insert_track"
            recentDirectToolDate = Date()
            playbackLogger.info("本地插播意图执行成功：insert_track")
        } catch {
            playbackLogger.error(
                "本地插播意图执行失败：\(error.localizedDescription, privacy: .public)"
            )
            presentProgramError(error)
        }
    }

    private func handleDirectProgramSwitchIntent(
        _ transcript: String
    ) async {
        let intent = DJDirectProgramSwitchIntent.resolve(
            transcript,
            hasPreparedProgram: programStore.pendingPlan != nil
        )
        playbackLogger.info(
            "本地节目切换意图：text=\(transcript, privacy: .public)，intent=\(String(describing: intent), privacy: .public)"
        )
        guard intent == .activatePrepared else {
            return
        }
        do {
            try await activatePreparedProgram()
            recentDirectToolName = "activate_prepared_program"
            recentDirectToolDate = Date()
            playbackLogger.info(
                "本地节目切换意图执行成功：activate_prepared_program"
            )
        } catch {
            playbackLogger.error(
                "本地节目切换意图执行失败：\(error.localizedDescription, privacy: .public)"
            )
            presentProgramError(error)
        }
    }

    private func consumeRecentDirectTool(named name: String) -> Bool {
        guard
            recentDirectToolName == name,
            let recentDirectToolDate,
            Date().timeIntervalSince(recentDirectToolDate) < 6
        else {
            return false
        }
        self.recentDirectToolName = nil
        self.recentDirectToolDate = nil
        return true
    }

    private func acknowledgedDirectToolResult(
        for call: RealtimeDJToolCall
    ) -> RealtimeDJToolResult {
        let message: String = switch call.name {
        case "replan_program":
            "后台编排任务已经创建，歌单尚未完成；完成后会主动通知"
        case "insert_track":
            "后台找歌任务已经创建，歌曲尚未找到；完成后会自动插到下一首并主动通知"
        case "activate_prepared_program":
            "已经切换并开始播放准备好的新节目"
        default:
            "播放动作已经执行"
        }
        let response = DJAgentToolResponse(
            ok: true,
            code: nil,
            message: message,
            state: snapshot(
                takeoverEnabled: agentPreferences.takeoverEnabled()
            ),
            tracks: nil,
            currentTrack: nil
        )
        let data = (try? JSONEncoder().encode(response))
            ?? Data(#"{"ok":true,"message":"播放动作已经执行"}"#.utf8)
        return RealtimeDJToolResult(
            callID: call.id,
            resultJSON: data,
            isError: false
        )
    }

    private func setRealtimeVoiceState(
        _ state: RealtimeVoiceConnectionState
    ) {
        RealtimeVoiceStatusStore.shared.state = state
        stageWindowController?.setVoiceState(state)
        liveCamWindowController?.setVoiceState(state)
    }

    /// Live Cam 文字聊天：直连 AgentConversationService，
    /// 不依赖实时语音连接状态。
    private func sendLiveCamMessage(_ message: String) async {
        liveCamWindowController?.beginAgentReply()
        let reply: String
        do {
            reply = try await AgentConversationService.shared.send(message)
        } catch AgentConversationError.cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            liveCamWindowController?.showChatStatus(
                (error as? LocalizedError)?.errorDescription
                    ?? "消息发送失败，请稍后再试。"
            )
            return
        }
        liveCamWindowController?.finishAgentReply(reply)
        agentSpeechAnnouncer.isEnabled =
            AgentConversationService.shared.preferenceStore.autoSpeakReplies
        agentSpeechAnnouncer.announce(reply)
    }

    private func updateStageProgramNavigation() {
        let hasProgram = activeProgram != nil
        stageWindowController?.setProgramNavigation(
            canGoPrevious: hasProgram
                && programPlaybackQueue.canReturnToPrevious,
            canGoNext: hasProgram && programPlaybackQueue.canAdvance
        )
    }

    private func liveCamPlayerMenuSnapshot() -> LiveCamPlayerMenuSnapshot {
        LiveCamPlayerMenuSnapshot.resolve(
            playerState: localMusicPlayer.state,
            hasPreparedProgram: activeProgram != nil
                && programPlaybackQueue.current != nil,
            trackTitle: programStore.activeSlot?.track.title
                ?? localMusicPlayer.track?.title,
            canSelectPrevious: activeProgram != nil
                && programPlaybackQueue.canReturnToPrevious,
            canSelectNext: activeProgram != nil
                && programPlaybackQueue.canAdvance
        )
    }

    private func publishSidecarLyrics(
        for audioURL: URL,
        trackDuration: TimeInterval?
    ) {
        stageLyrics.clear()
        let lrcURL = audioURL
            .deletingPathExtension()
            .appendingPathExtension("lrc")
        guard
            let source = try? String(contentsOf: lrcURL, encoding: .utf8),
            !source.isEmpty
        else {
            return
        }
        stageLyrics.publish(
            MusicLyrics(original: source, translation: nil),
            trackID: audioURL.path,
            trackDuration: trackDuration
        )
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    @discardableResult
    func activateRealtimeDJSession(
        _ session: any RealtimeDJSession,
        ticket: RealtimeDJSessionTicket
    ) async throws -> RealtimeDJSessionSnapshot {
        try await realtimeDJSessionController.activate(
            session,
            ticket: ticket
        )
    }

    func updateRealtimeDJContext(_ context: RealtimeDJContext) async throws {
        stagePresentation.apply(context)
        stageVisualDirections.update(context.visualMood)
        try await realtimeDJSessionController.updateContext(context)
    }

    func snapshot(
        takeoverEnabled: Bool
    ) -> DJAgentRadioState {
        let plan = activeProgram ?? programStore.plan
        let tracks = plan?.slots.enumerated().map { index, slot in
            DJAgentProgramTrack(
                index: index,
                id: slot.track.id,
                title: slot.track.title,
                artist: slot.track.artist
            )
        } ?? []
        return DJAgentRadioState(
            takeoverEnabled: takeoverEnabled,
            playbackState: agentPlaybackState,
            activeTrackID: programStore.activeSlot?.track.id,
            activeSlotIndex: programStore.activeSlotIndex,
            program: tracks
        )
    }

    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? {
        let playbackState = agentPlaybackState
        guard
            playbackState == "playing" || playbackState == "paused",
            let current = committedPlaybackTrack
        else {
            return nil
        }

        let plan = activeProgram ?? programStore.plan
        let position = max(
            0,
            audioGraphStorage?.playbackPosition ?? 0
        )
        let duration = max(current.duration, 0)
        let boundedPosition = duration > 0
            ? min(position, duration)
            : position
        let remaining = duration > 0
            ? max(duration - boundedPosition, 0)
            : 0
        let progress = duration > 0
            ? min(max(boundedPosition / duration, 0), 1)
            : 0

        return DJAgentCurrentTrackSnapshot(
            sampledAt: ISO8601DateFormatter().string(from: Date()),
            playbackState: playbackState,
            isPlaying: playbackState == "playing",
            id: current.id,
            provider: current.providerID.rawValue,
            source: current.source.rawValue,
            title: current.title,
            artist: current.artist,
            album: current.album,
            durationSeconds: duration,
            positionSeconds: boundedPosition,
            remainingSeconds: remaining,
            progress: progress,
            programID: plan?.brief.id,
            programTitle: plan?.title,
            slotIndex: plan?.slots.firstIndex {
                $0.track.id == current.id
            },
            previousTrack: previousCommittedPlaybackTrack.map {
                DJAgentPlaybackTrack(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist
                )
            },
            nextTrack: programPlaybackQueue.locked.first.map {
                DJAgentPlaybackTrack(
                    id: $0.slot.track.id,
                    title: $0.slot.track.title,
                    artist: $0.slot.track.artist
                )
            }
        )
    }

    func playProgramTrack(
        trackID: String?,
        slotIndex: Int?
    ) async throws {
        guard
            let plan = activeProgram ?? programStore.plan
        else {
            throw DJAgentRadioActionError.noProgram
        }
        let resolvedIndex: Int?
        if let trackID {
            resolvedIndex = plan.slots.firstIndex {
                $0.track.id == trackID
            }
        } else {
            resolvedIndex = slotIndex
        }
        guard
            let resolvedIndex,
            plan.slots.indices.contains(resolvedIndex)
        else {
            throw DJAgentRadioActionError.trackNotFound
        }
        guard !isStartingProgramPlayback else {
            throw DJAgentRadioActionError.busy
        }

        activeProgram = plan
        isStartingProgramPlayback = true
        defer { isStartingProgramPlayback = false }
        localMusicPlayer.pause()
        stageWindowController?.setPlaybackState(.idle)
        try await programPlaybackQueue.select(
            plan,
            at: resolvedIndex
        )
        guard let prepared = programPlaybackQueue.current else {
            throw DJAgentRadioActionError.trackNotFound
        }
        try await playPreparedWithFallback(
            prepared,
            requestOpening: false,
            allowFallback: false
        )
    }

    func playNextTrack() async throws {
        guard activeProgram != nil else {
            throw DJAgentRadioActionError.noProgram
        }
        guard
            let next = await programPlaybackQueue
                .advanceAfterCompletion()
        else {
            throw DJAgentRadioActionError.trackNotFound
        }
        try await playPreparedWithFallback(
            next,
            requestOpening: false,
            allowFallback: false
        )
    }

    func playPreviousTrack() async throws {
        guard
            activeProgram != nil,
            let previous = programPlaybackQueue.returnToPrevious()
        else {
            throw DJAgentRadioActionError.trackNotFound
        }
        try await playPreparedWithFallback(
            previous,
            requestOpening: false,
            allowFallback: false
        )
    }

    func pauseMusic() async throws {
        guard localMusicPlayer.state == .playing else {
            return
        }
        localMusicPlayer.pause()
        orbWindowController?.setState(.idle)
        stageWindowController?.setPlaybackState(.paused)
    }

    func resumeMusic() async throws {
        let route = ProgramPlaybackStartRoute.resolve(
            playerState: localMusicPlayer.state,
            hasPreparedProgram:
                activeProgram != nil && programPlaybackQueue.current != nil
        )
        playbackLogger.info(
            "DJ 播放动作：player=\(String(describing: self.localMusicPlayer.state), privacy: .public)，route=\(String(describing: route), privacy: .public)，store=\(self.programStore.activeSlot?.track.id ?? "nil", privacy: .public)，queue=\(self.programPlaybackQueue.current?.slot.track.id ?? "nil", privacy: .public)"
        )
        switch route {
        case .alreadyPlaying:
            playbackLogger.info("DJ 播放动作完成：音乐已经在播放")
            return
        case .resumeLocal:
            try localMusicPlayer.play()
            orbWindowController?.setState(.playing)
            stageWindowController?.setPlaybackState(.playing)
        case .startPreparedProgram:
            try await startSelectedProgramPlayback(
                requestOpening: false,
                allowFallback: false
            )
        case .unavailable:
            throw DJAgentRadioActionError.noProgram
        }
    }

    func replanProgram(
        immediateInstruction: String?
    ) async throws {
        scheduleBackgroundProgramPlan(
            immediateInstruction:
                immediateInstruction
                ?? "根据当前状态重新编排后续节目"
        )
    }

    private func scheduleBackgroundProgramPlan(
        immediateInstruction: String
    ) {
        backgroundProgramAgentTask?.cancel()
        let requestID = UUID()
        backgroundProgramRequestID = requestID
        programStore.beginPlanning()
        playbackLogger.info(
            "后台编排任务已创建：id=\(requestID.uuidString, privacy: .public)，instruction=\(immediateInstruction, privacy: .public)"
        )
        backgroundProgramAgentTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let proposal = try await makeAIProgramPlan(
                    immediateUserInstruction: immediateInstruction
                )
                try Task.checkCancellation()
                guard backgroundProgramRequestID == requestID else {
                    return
                }
                programStore.publishDraft(proposal)
                updateStageProgramNavigation()
                playbackLogger.info(
                    "后台编排任务完成：id=\(requestID.uuidString, privacy: .public)，title=\(proposal.title ?? "未命名节目", privacy: .public)，tracks=\(proposal.slots.count)"
                )
                await refreshAgentContext()
                await notifyDJThatProgramIsReady(
                    proposal,
                    requestInstruction: immediateInstruction
                )
            } catch is CancellationError {
                playbackLogger.info(
                    "后台编排任务已取消：id=\(requestID.uuidString, privacy: .public)"
                )
            } catch {
                guard backgroundProgramRequestID == requestID else {
                    return
                }
                programStore.fail(error.localizedDescription)
                playbackLogger.error(
                    "后台编排任务失败：id=\(requestID.uuidString, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                await notifyDJThatProgramFailed(
                    requestInstruction: immediateInstruction,
                    error: error
                )
            }
            if backgroundProgramRequestID == requestID {
                backgroundProgramAgentTask = nil
                backgroundProgramRequestID = nil
            }
        }
    }

    private func notifyDJThatProgramIsReady(
        _ plan: ProgramPlan,
        requestInstruction: String
    ) async {
        let title = plan.title ?? "新的节目单"
        let tracks = plan.slots.prefix(4)
            .map { "\($0.track.artist)《\($0.track.title)》" }
            .joined(separator: "、")
        let instruction = """
        [gmgn radio 后台编排完成事件]
        用户之前的要求：\(requestInstruction)
        新歌单“\(title)”已经准备好，共 \(plan.slots.count) 首。部分歌曲：\(tracks)。
        这是后台系统事件，不是用户的新发言。请用一到两句话自然告诉用户歌单已经准备好，并询问是否切换过去。此刻不要调用切换工具；等用户确认后再调用 activate_prepared_program。
        """
        do {
            try await realtimeDJSessionController
                .requestAgentResponse(instruction)
        } catch {
            playbackLogger.error(
                "后台编排完成消息发送失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func notifyDJThatProgramFailed(
        requestInstruction: String,
        error: Error
    ) async {
        let instruction = """
        [gmgn radio 后台编排失败事件]
        用户之前的要求：\(requestInstruction)
        实际错误：\(error.localizedDescription)
        这是后台系统事件。请简短告诉用户这次编排没有完成，并说明可以重试；不要声称歌单已经准备好。
        """
        do {
            try await realtimeDJSessionController
                .requestAgentResponse(instruction)
        } catch {
            playbackLogger.error(
                "后台编排失败消息发送失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func activatePreparedProgram() async throws {
        guard let proposal = programStore.pendingPlan else {
            throw DJAgentRadioActionError.noPreparedProgram
        }
        playbackLogger.info(
            "准备切换后台节目：id=\(proposal.brief.id, privacy: .public)，title=\(proposal.title ?? "未命名节目", privacy: .public)"
        )
        try await programPlaybackQueue.load(proposal)
        guard let prepared = programPlaybackQueue.current else {
            throw ProgramPlaybackQueueError.noPlayableSlots(
                failedTrackIDs: programPlaybackQueue.failedTrackIDs
            )
        }
        localMusicPlayer.pause()
        activeProgram = proposal
        programStore.publish(proposal)
        updateStageProgramNavigation()
        try await playPreparedWithFallback(
            prepared,
            allowFallback: false
        )
        await refreshAgentContext()
    }

    private func replanUpcomingProgramFromStage() {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await replanProgram(immediateInstruction: nil)
            } catch {
                presentProgramError(error)
            }
        }
    }

    func insertTrack(
        immediateInstruction: String
    ) async throws {
        scheduleBackgroundTrackInsertion(
            immediateInstruction: immediateInstruction
        )
    }

    private func scheduleBackgroundTrackInsertion(
        immediateInstruction: String
    ) {
        backgroundProgramAgentTask?.cancel()
        let requestID = UUID()
        backgroundProgramRequestID = requestID
        programStore.beginPlanning()
        playbackLogger.info(
            "后台插播任务已创建：id=\(requestID.uuidString, privacy: .public)，instruction=\(immediateInstruction, privacy: .public)"
        )
        backgroundProgramAgentTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let proposal = try await makeAIProgramPlan(
                    immediateUserInstruction:
                        "只为下一首找一首可播歌曲。用户的插播要求：\(immediateInstruction)"
                )
                try Task.checkCancellation()
                guard backgroundProgramRequestID == requestID else {
                    return
                }
                guard
                    let insertedSlot = proposal.slots.first
                else {
                    throw DJAgentRadioActionError.trackNotFound
                }
                let insertedIntoActiveProgram: Bool
                if
                    let current = activeProgram,
                    let activeSlotIndex = programStore.activeSlotIndex,
                    programPlaybackQueue.current != nil
                {
                    insertedIntoActiveProgram = true
                    let revised = DJProgramEditor.revise(
                        current: current,
                        activeSlotIndex: activeSlotIndex,
                        proposal: proposal,
                        mode: .insertNext
                    )
                    activeProgram = revised
                    programStore.publish(revised)
                    programStore.activateSlot(at: activeSlotIndex)
                    await programPlaybackQueue.replaceUpcoming(
                        with: Array(
                            revised.slots.dropFirst(activeSlotIndex + 1)
                        )
                    )
                } else {
                    insertedIntoActiveProgram = false
                    programStore.publishDraft(proposal)
                }
                updateStageProgramNavigation()
                await refreshAgentContext()
                playbackLogger.info(
                    "后台插播任务完成：id=\(requestID.uuidString, privacy: .public)，track=\(insertedSlot.track.id, privacy: .public)，title=\(insertedSlot.track.title, privacy: .public)"
                )
                await notifyDJThatInsertionIsReady(
                    insertedSlot,
                    requestInstruction: immediateInstruction,
                    insertedIntoActiveProgram: insertedIntoActiveProgram
                )
            } catch is CancellationError {
                playbackLogger.info(
                    "后台插播任务已取消：id=\(requestID.uuidString, privacy: .public)"
                )
            } catch {
                guard backgroundProgramRequestID == requestID else {
                    return
                }
                programStore.fail(error.localizedDescription)
                playbackLogger.error(
                    "后台插播任务失败：id=\(requestID.uuidString, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                await notifyDJThatInsertionFailed(
                    requestInstruction: immediateInstruction,
                    error: error
                )
            }
            if backgroundProgramRequestID == requestID {
                backgroundProgramAgentTask = nil
                backgroundProgramRequestID = nil
            }
        }
    }

    private func notifyDJThatInsertionIsReady(
        _ slot: ProgramSlot,
        requestInstruction: String,
        insertedIntoActiveProgram: Bool
    ) async {
        let placement = insertedIntoActiveProgram
            ? "已经插入当前节目的下一首"
            : "已经准备为一份待播放节目"
        let instruction = """
        [gmgn radio 后台插播完成事件]
        用户之前的要求：\(requestInstruction)
        后台找到了 \(slot.track.artist)《\(slot.track.title)》，并验证可播，\(placement)。
        这是后台系统事件。请用一句话自然告诉用户结果，不要再次调用插播、找歌或播放工具。
        """
        do {
            try await realtimeDJSessionController
                .requestAgentResponse(instruction)
        } catch {
            playbackLogger.error(
                "后台插播完成消息发送失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func notifyDJThatInsertionFailed(
        requestInstruction: String,
        error: Error
    ) async {
        let instruction = """
        [gmgn radio 后台插播失败事件]
        用户之前的要求：\(requestInstruction)
        实际错误：\(error.localizedDescription)
        这是后台系统事件。请用一句话告诉用户这次没有找到可播歌曲，可以换个关键词重试。
        """
        do {
            try await realtimeDJSessionController
                .requestAgentResponse(instruction)
        } catch {
            playbackLogger.error(
                "后台插播失败消息发送失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func setVisualMood(
        _ mood: StageVisualMood
    ) async throws {
        let cue = ProgramVisualDirector().cue(
            for: programStore.activeSlot?.role ?? .build,
            mood: mood
        )
        stageVisualDirections.update(cue)
        stageVideos.apply(cue)
    }

    func searchMusic(
        query: String,
        limit: Int
    ) async throws -> [DJAgentMusicTrack] {
        try await musicRuntime.search(
            MusicSearchRequest(
                text: query,
                limit: limit
            )
        ).map { candidate in
            DJAgentMusicTrack(
                id: candidate.id,
                provider: candidate.providerID.rawValue,
                title: candidate.title,
                artist: candidate.artist,
                album: candidate.album,
                duration: candidate.duration,
                isPlayable: candidate.isPlayable
            )
        }
    }

    func setLyricsMode(
        _ mode: StageLyricsVisualMode
    ) async throws {
        stageLyrics.setVisualMode(mode)
    }

    func setSpatialEnvironment(
        scene: SpatialScenePreset?,
        weather: SpatialWeather?
    ) async throws {
        if let scene {
            await marbleWorldLibrary.activate(preset: scene)
            if let error = marbleWorldLibrary.errorMessage {
                throw MarbleWorldClientError.generationFailed(error)
            }
        }
        spatialStage.applyEnvironment(weather: weather)
    }

    func moveSpatialCamera(
        direction: SpatialCameraCommandDirection,
        distance: Float
    ) async throws {
        spatialStage.applyCameraCommand(direction, distance: distance)
    }

    private var agentPlaybackState: String {
        switch localMusicPlayer.state {
        case .idle:
            "idle"
        case .ready:
            "ready"
        case .playing:
            "playing"
        case .paused:
            "paused"
        case .finished:
            "finished"
        }
    }
}

private enum DJAgentRadioActionError: LocalizedError {
    case noProgram
    case noPreparedProgram
    case trackNotFound
    case busy

    var errorDescription: String? {
        switch self {
        case .noProgram:
            "当前还没有可接管的节目"
        case .noPreparedProgram:
            "后台还没有准备好可切换的新节目"
        case .trackNotFound:
            "节目中找不到这首歌"
        case .busy:
            "播放器正在切歌，请稍后再试"
        }
    }
}
