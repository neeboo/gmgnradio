import AppKit
import AVFoundation
import os
import SwiftUI
import UniformTypeIdentifiers
import WorldRuntime
import CryptoKit

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

private enum ResidentPropHostError: LocalizedError {
    case editorOpen, assetUnverified, assetUnavailable, ownershipMismatch
    var errorDescription: String? {
        switch self {
        case .editorOpen: "请先结束摆放，再发送给居民；输入内容会保留。"
        case .assetUnverified: "物件尚未完成本地显示检查，所有权已保留，请稍后重试。"
        case .assetUnavailable: "已领取物件的本地文件缺失或校验失败，没有删除或重新生成，请检查许愿任务。"
        case .ownershipMismatch: "物件存档与领取记录不一致，已保留原记录并停止摆放。"
        }
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
    /// 系统权限弹窗仍未被回答（有界等待结束），不是连接或图片能力故障。
    case microphoneAuthorizationPending

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "没有麦克风权限，请在系统设置里允许 gmgn radio 使用麦克风。"
        case .providerUnavailable:
            "这个实时语音服务尚未接通。"
        case .microphoneAuthorizationPending:
            "还在等待系统权限弹窗：请点「允许」后再点一次麦克风；"
                + "若没有看到弹窗，请在系统设置里允许 gmgn radio 使用麦克风。"
        }
    }
}

/// 麦克风授权的可注入纯逻辑闸门（2026-09-22 P0-4）。
///
/// 根因：`AVCaptureDevice.requestAccess` 没有超时、不响应 `Task` 取消，系统弹窗
/// 未回答时它的 continuation 永不恢复。旧实现把它直接 `await` 在语音连接任务里，
/// 于是 12 秒连接超时取消连接任务后，`enqueueResidentVoiceShutdown` 里的
/// `await connectingTask.value` 永远不落地，`residentVoiceShutdownTask` 从不清零，
/// 下一次连接被 `await previousShutdown?.value` 挡住，重试实际失效。
///
/// 本闸门把系统授权收敛成**有界、可取消、可复用**的结果，不靠延长超时：
/// - 已授权 / 已拒绝：立即返回，不再触碰系统请求；
/// - 首次未决定：只在真正发起系统请求时回调 `onSystemPrompt`，最多等待 `deadline`；
///   等待被取消或超时都立即返回，但系统请求**继续存在**；
/// - 迟到的系统结果写入缓存，下一次 `resolve` 直接复用，绝不弹第二次。
/// 绝不吞掉结果：无论用户先/后回答，闸门都记住答案。
@MainActor
final class MicrophoneAuthorizationGate {
    enum Status: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    enum Outcome: Equatable {
        case authorized
        case denied
        /// 有界等待结束但系统弹窗仍未回答；request 仍在等待迟到结果。
        case awaitingSystemPrompt
        /// 等待方被取消（用户取消录音 / 新请求取代）；request 仍在等待迟到结果。
        case cancelled
    }

    private let currentStatus: @MainActor () -> Status
    private let requestAccess: @MainActor () async -> Bool
    private var requestTask: Task<Void, Never>?
    private var settled: Outcome?
    private var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]

    init(
        status: @escaping @MainActor () -> Status,
        requestAccess: @escaping @MainActor () async -> Bool
    ) {
        self.currentStatus = status
        self.requestAccess = requestAccess
    }

    /// 是否还有一次系统授权请求在等用户回答（只读诊断，不触发请求）。
    var hasPendingSystemRequest: Bool { requestTask != nil }

    /// 有界等待一次授权结论。`onSystemPrompt` 只在**本次真正发起**系统请求时调用一次。
    func resolve(
        deadline: Duration,
        onSystemPrompt: @MainActor () -> Void = {}
    ) async -> Outcome {
        switch currentStatus() {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            break
        }
        // 迟到的系统答案：即便系统状态尚未回流也直接复用，绝不二次弹窗。
        if let settled { return settled }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                waiters[token] = continuation
                startSystemRequestIfNeeded(onSystemPrompt: onSystemPrompt)
                if Task.isCancelled {
                    finishWaiter(token, with: .cancelled)
                    return
                }
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self?.finishWaiter(token, with: .awaitingSystemPrompt)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(token, with: .cancelled)
            }
        }
    }

    /// 连接链路共用的分类：授权成功静默通过，其余各自映射到固定用户文案。
    func resolveOrFail(
        deadline: Duration,
        onSystemPrompt: @MainActor () -> Void = {}
    ) async throws {
        switch await resolve(deadline: deadline, onSystemPrompt: onSystemPrompt) {
        case .authorized: return
        case .cancelled: throw CancellationError()
        case .denied: throw RealtimeVoiceSetupError.microphoneDenied
        case .awaitingSystemPrompt: throw RealtimeVoiceSetupError.microphoneAuthorizationPending
        }
    }

    private func startSystemRequestIfNeeded(onSystemPrompt: @MainActor () -> Void) {
        guard requestTask == nil else { return }
        onSystemPrompt()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.requestAccess()
            self.settle(granted ? .authorized : .denied)
        }
    }

    private func settle(_ outcome: Outcome) {
        requestTask = nil
        settled = outcome
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: outcome)
        }
    }

    private func finishWaiter(_ token: UUID, with outcome: Outcome) {
        guard let continuation = waiters.removeValue(forKey: token) else { return }
        continuation.resume(returning: outcome)
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

    /// 点 Dock 图标（底栏图标）只把应用带回前台。**已经有可见窗口时不得切换
    /// 桌面形态**：`showLiveCam()` 会把正在看的那扇窗直接关掉换成小窗，这正是
    /// 真机上的「点底栏的 icon 就变小窗」。只有没有任何可见窗口时才恢复桌面形态。
    func perform(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        showDesktopPresence()
        return true
    }
}

@main
struct GMGNRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    /// 装修入口的标题要跟着装修状态走，所以菜单宿主必须观察一个会变的源
    /// （和 `LivingWorldActivityMenuStore.shared` 同一套做法，只是这里只需要一个 Bool）。
    @StateObject private var stageDecorationMenu = StageDecorationMenuStore.shared

    var body: some Scene {
        MenuBarExtra(ProductIdentity.displayName, systemImage: "waveform.circle.fill") {
            ForEach(
                SystemResidentMenuPolicy.entries(
                    isRadioPluginEnabled: RadioPluginAvailability.isEnabled()
                ),
                id: \.self
            ) { entry in
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
    /// 装修入口：标题跟着装修状态走（未装修「装修空间」/ 装修中「结束装修」）。
    case toggleDecoration
    case openPlayer
    case settings
    case quit
}

enum SystemResidentMenuPolicy {
    /// P1：默认呈现面只有菜单栏 + 空间 + 设置。
    /// 电台插件关闭（默认）时菜单不含「打开播放器」；插件打开时恢复改动前的完整条目与顺序。
    /// `.openPlayer` 这个 case 与它的按钮实现全部保留，只受门禁控制。
    /// 装修入口（`.toggleDecoration`）紧跟在「进入空间」后面：它属于空间那一组条目，
    /// 而且默认呈现面下也必须存在 —— 它要解决的正是「装修模式找不到」。
    static func entries(
        isRadioPluginEnabled: Bool
    ) -> [SystemResidentMenuEntry] {
        isRadioPluginEnabled
            ? [.showLiveCam, .enterSpace, .toggleDecoration, .openPlayer, .settings, .quit]
            : [.showLiveCam, .enterSpace, .toggleDecoration, .settings, .quit]
    }
}

/// 装修入口的标题是装修状态的**投影**，不是另存一份状态。
enum StageDecorationMenuTitle {
    static func resolve(isDecorating: Bool) -> String {
        isDecorating ? "结束装修" : "装修空间"
    }
}

/// 菜单栏装修条目的刷新源。
///
/// `MenuBarExtra` 的条目在 `body` 求值时构建，所以标题要跟状态走就必须观察一个会变的源。
/// 唯一的写入者是 `StageContentView` 里既有的 `residentPropEditor.$isOpen` 订阅 —— 装修的
/// 每一次开/关（图标按钮、菜单入口、Escape、空间退出、关窗）都从那里经过，不会漏。
@MainActor
final class StageDecorationMenuStore: ObservableObject {
    static let shared = StageDecorationMenuStore()

    @Published private(set) var isDecorating = false

    func update(isDecorating: Bool) {
        guard self.isDecorating != isDecorating else { return }
        self.isDecorating = isDecorating
    }
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
        case .toggleDecoration:
            Button(
                StageDecorationMenuTitle.resolve(
                    isDecorating: stageDecorationMenu.isDecorating
                )
            ) {
                AppMenuAction.toggleDecorationEditor.perform(on: appDelegate)
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
    /// 菜单栏的「装修空间 / 结束装修」：未装修时先呈现空间再进装修，装修中只退出装修。
    func toggleDecorationEditor()
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

/// 菜单栏装修入口的排程。
///
/// 未装修时**一步到位**：先按「进入空间」把空间呈现出来（`requestWorldPresentation` 是同步
/// 的，所以紧接着的装修开关能过 `spatialStage.isWorldPresentationRequested` 这道守卫），
/// 再切换装修编辑器 —— 不要求用户先自己点一次「进入空间」。
/// 已在装修时只退出装修：不重新呈现空间，也不动空间窗口（关掉的是编辑器面板）。
@MainActor
struct StageDecorationEntryAction {
    let isDecorationEditorOpen: () -> Bool
    let showStage: () -> Void
    let toggleDecorationEditor: () -> Void

    func perform() {
        if isDecorationEditorOpen() {
            toggleDecorationEditor()
            return
        }
        showStage()
        toggleDecorationEditor()
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

/// 生活活动与角色动作都**不再**有「顺带显示桌面形态」的判据：它们各自的
/// 呈现决策已并入唯一判据 `LiveCamPresentationPolicy`（触发源为
/// `.livingWorldActivityChange` / `.characterMotionChange`，恒不呈现）。
/// 原先两个只回答「空间开着吗」的策略就是这条缺陷的来源 —— 空间没开时它们
/// 一律回答「该显示小窗」，于是活动开始和菜单动作都把小窗顶了出来。
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
    /// 装修入口：一步到位（先呈现空间，再切换装修编辑器）。
    case toggleDecorationEditor
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
        case .toggleDecorationEditor:
            controller.toggleDecorationEditor()
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
        synthesizer: BailianSpeechSynthesizer(configuration: {
            let preferences = RealtimeVoicePreferences()
            return BailianTTSConfiguration(
                apiKey: preferences.load(provider: .bailian).apiKey ?? "",
                voiceID: preferences.replyVoiceID
            )
        }, onPlaybackChanged: { [weak self] state in
            self?.audioGraph.setResidentSpeechPlaying(state.isPlaying)
            self?.avatarRuntime.setResidentSpeechPlayback(
                isPlaying: state.isPlaying, level: state.level
            )
        })
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
    private var isPreparingMusicLibraryTrack = false
    /// Shared by resident and DJ preparation; newer playback intent invalidates late commits.
    private var musicSelectionGeneration: UInt64 = 0
    private var interruptionCoordinator: InterruptionCoordinator?
    private var orbWindowController: OrbWindowController?
    private var stageWindowController: StageWindowController?
    private var liveCamWindowController: LiveCamWindowController?
    private var residentSystemInboxWindowController: ResidentSystemInboxWindowController?
    /// 迟到的旧一轮提示推送不得覆盖新一轮任务列表。
    private var wishTaskPromptGeneration = 0
    /// 居民跨重启记忆的统一状态合同客户端（gmgn-taskd state_* 域）。
    private lazy var residentMemoryStore: ResidentMemoryStore = {
        let transport = ResidentTaskDaemonStateTransport(client: PropTaskDaemonClient())
        let store = ResidentMemoryStore(client: ResidentStateClient(transport: transport))
        store.onPersistenceError = { [weak self] message in self?.showResidentVoiceStatus(message) }
        return store
    }()
    private var residentMemoryRestoreTask: Task<Void, Never>?
    /// 已绑定记忆的（循环,作用域）：真正的 scope 变化才重新 bind+restore，
    /// 每次 ensureResidentLoop 都重读会不断打断进行中的恢复。
    private var residentMemoryBinding: (loop: ResidentAgentLoop, scope: ResidentStateScope)?
    /// 每次真正重绑定都换新的代次：同 loop 在 A→B→A 间往返时，旧 A 的恢复
    /// 等待者靠代次失配退出，不会误清新一轮恢复任务或提前重启自主行为。
    private var residentMemoryBindingGeneration = UUID()
    /// 最近对话（进程内、有界）：按「世界 + 后端会话」作用域隔离，用户提交时登记
    /// 回合、真实送达/失败/取消时更新同一回合，绝不重复显示；两个聊天表面共用
    /// 这份快照，口径一致。不做持久化：现有唯一按回合存储的是模型长期记忆，
    /// 其冻结合同不允许 Swift 侧重组为界面历史（见体验修复文档）。
    private var residentChatTranscript = ResidentChatTranscript()
    // MARK: 长期记忆（本地编排薄适配器；外部 provider 与原文层接线均已移除）
    /// 编排薄适配器（**只转发 `memory_recall`**），复用 gmgn-taskd 统一状态合同运输。
    ///
    /// 原文层已整体移除（2026-10-01）：原先这里还有「等待显示/语音完成才确认入库」
    /// 的交付凭据（`ResidentMemoryTurnSlot`）、按 runID 记的来源
    /// （`residentTurnSourceByRunID`）与 `confirmDeliveredTurn` 调用链。它们全部
    /// 随 `memory_ingest` / `memory_turn` / `memory_pending` 一起删除了，
    /// 依据见 `docs/plans/2026-09-08-voicemem-rust-contract.md` 的「已移除」一节。
    private lazy var residentConversationMemory: ResidentConversationMemory = {
        ResidentConversationMemory(
            transport: ResidentTaskDaemonStateTransport(client: PropTaskDaemonClient())
        )
    }()
    private var stageRenderSurfaceController: StageRenderSurfaceController?
    private var stageCameraCoordinator: StageCameraCoordinator?
    private var stageAvatarActivityExecutor: StageAvatarActivityExecutor?
    private var residentMotionPlaybackObserverID: UUID?
    private var livingWorldApprovedMotions: [String: StageMotionAsset] = [:]
    private var desktopPresenceObserverID: UUID?
    private var livingWorldContext: WorldAgentContext?
    private var livingCabinJukeboxGate = LivingCabinJukeboxGate()
    /// 一次执行实例里已经报过的"点唱机没出声"原因（同一个原因只报一次）。
    private var reportedJukeboxSilenceInstance: String?
    private var residentActivityOutcome: ResidentActivityOutcome?
    private var residentJukeboxPlaybackOwner: UUID?
    private var worldAgentToolDispatcher: WorldAgentToolDispatcher?
    private var livingWorldVisualTask: Task<Void, Never>?
    private var livingWorldColliderTask: Task<Void, Never>?
    private var livingWorldColliderFraming: MarbleSceneFraming?
    private var sceneFramingObserverID: UUID?
    private var stageAudioMonitor: VisualAudioInputMonitor?
    private var stagePresentationTask: Task<Void, Never>?
    private var realtimeVoiceConnectionTask: Task<Void, Never>?
    private var realtimeVoiceTimeoutTask: Task<Void, Never>?
    private var residentVoiceRequestID: UUID?
    private var residentVoiceAcceptsFinal = false
    private var residentVoiceSession: (any RealtimeDJSession)?
    private var residentVoiceEventTask: Task<Void, Never>?
    private var residentVoiceShutdownTask: Task<Void, Never>?
    /// shutdown 链的代次：只有最新一代落地后才允许把任务指针清空。
    private var residentVoiceShutdownGeneration: UInt64 = 0
    /// 系统麦克风授权只在这里发起，绝不阻塞连接任务与 shutdown 链。
    private lazy var microphoneAuthorizationGate = MicrophoneAuthorizationGate(
        status: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .authorized
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
        },
        requestAccess: { await AVCaptureDevice.requestAccess(for: .audio) }
    )
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
        AgentSpeechStatusStore.shared.onStopSpeaking = { [weak self] in
            self?.agentSpeechAnnouncer.stop()
        }
        spatialStage.onWorldSelectionChanged = { [weak self] in
            self?.safelyReturnHeldProp(reason: "换空间")
            // 换空间不是"用户按了停止"：作废旧空间的对话与提示可以照做，但绝不能
            // 因此写出许愿任务级的持久暂停（那会要求用户回到旧空间手动恢复）。
            self?.cancelResidentMessage(userIntent: false)
            self?.residentAgentLoop?.invalidate()
            self?.residentAgentLoop = nil
            self?.residentWishImages.removeAll()
            // 换空间后旧空间的最近对话立即作废，绝不带到新空间显示。
            self?.resetResidentTranscriptForContextSwitch()
            // 换空间后旧空间的进度/失败/语音提示一律作废，避免把上一条状态带到
            // 新空间；未确认交付的可见提示也重新开始。
            self?.residentUnconfirmedNotice.reset()
            self?.liveCamWindowController?.clearTransientStatus()
            self?.stageWindowController?.clearResidentTransientStatus()
            self?.liveCamWindowController?.setResidentDeliveryNotice(nil)
            self?.stageWindowController?.setResidentDeliveryNotice(nil)
        }
        configureLivingWorld()
        configureStage()
        configureWishMachineService()
        configureResidentConversationMemory()
        startResidentLoopScheduling()
        NotificationCenter.default.addObserver(self, selector: #selector(propGenerationConfigurationDidChange(_:)),
            name: .propGenerationConfigurationDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(residentAutonomyDidChange(_:)),
            name: Notification.Name("gmgnResidentAutonomyChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(agentConversationBackendDidChange(_:)),
            name: .agentConversationBackendDidChange, object: nil)
        desktopPresenceObserverID = avatarRuntime.observe {
            [weak self] snapshot in
            self?.safelyReturnHeldPropIfAvatarChanged(snapshot)
            // 角色快照变化 = 走路、语音电平、Agent 说话、动作、许愿任务……这些
            // 都不是「进入小窗」的动作。这里只做形态清理（插件开时的光球分支），
            // 绝不呈现小窗：见 `LiveCamPresentationTrigger.mayPresentLiveCam`。
            self?.applyDesktopPresence(snapshot, trigger: .avatarSnapshotChange)
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
            // 冷启动的默认桌面形态是产品定义的入口（不是会话中的「切过去」），
            // 所以它是唯一允许使用的非显式触发源。
            showLiveCam(trigger: .launchDefault)
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
        residentLoopSchedulingTask?.cancel()
        _ = returnHeldPropBeforeResidentStop(reason: "退出应用")
        residentAgentLoop?.invalidate()
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
        _ = stopResidentLoop(reason: "切换角色动作")
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
        // 用户显式要求看播放器（菜单/小窗的播放器菜单）。播放器模式里角色只可能画在
        // Live Cam 上（一份渲染面），所以**在这个显式入口**交接一次；`show()`
        // 自己不再顺手呈现小窗，任何非显式路径也不会走到这里。
        liveCamWindowController?.show()
    }

    /// 菜单栏「装修空间 / 结束装修」。
    ///
    /// 装修开关本身在 `StageWindowController`（`toggleDecorationEditor()` 是它对外唯一的窄入口），
    /// 这里只负责「先呈现空间」这半步：空间窗口还没被创建时，`showStage()` 会创建并呈现它，
    /// 之后那次开关就能落到一个已经请求了呈现的空间上。
    func toggleDecorationEditor() {
        StageDecorationEntryAction(
            isDecorationEditorOpen: { [weak self] in
                self?.stageWindowController?.isDecorationEditorOpen ?? false
            },
            showStage: { [weak self] in
                self?.showStage()
            },
            toggleDecorationEditor: { [weak self] in
                self?.stageWindowController?.toggleDecorationEditor()
            }
        ).perform()
    }

    /// 用户显式的「显示 Live Cam」入口（菜单栏/快捷键/窗口按钮）：
    /// 空间开着时它等价于「收成小窗」，这正是用户唯一接受的变小窗动作。
    func showLiveCam() {
        showLiveCam(trigger: .explicitUserAction)
    }

    private func showLiveCam(trigger: LiveCamPresentationTrigger) {
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
        // 没有角色时桌面呈现没有可显示的对象（光球随播放器进插件后不再兜底）：
        // 给出可见、可执行的引导，不能看起来没反应。
        switch LiveCamPresentationRequest.resolve(hasAvatar: avatarRuntime.snapshot.avatar != nil) {
        case .present:
            applyDesktopPresence(avatarRuntime.snapshot, trigger: trigger)
        case let .needsAvatar(guidance):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "还没有可显示的角色"
            alert.informativeText = guidance
            alert.runModal()
        }
    }

    /// 桌面形态的唯一落地处。`trigger` 决定这次调用**有没有资格呈现**小窗：
    /// 居民状态播报、活动开始、角色动作、角色快照变化一律不呈现（只做形态清理），
    /// 见 `LiveCamPresentationPolicy`。呈现之外的清理（插件开时的光球分支）不受
    /// 触发源限制 —— 收起来从来不是「自动切到小窗」。
    private func applyDesktopPresence(
        _ snapshot: StageAvatarRuntimeSnapshot,
        trigger: LiveCamPresentationTrigger
    ) {
        switch DesktopPresenceMode.resolve(
            snapshot: snapshot,
            isRadioPluginEnabled: RadioPluginAvailability.isEnabled()
        ) {
        case .orb:
            liveCamWindowController?.hide()
            orbWindowController?.show()
        case .liveCam:
            orbWindowController?.hide()
            // 门禁关闭后没有角色时不再退回光球：不留空窗口，也不呈现（旧行为）。
            // 这是「收起来」，与「自动切到小窗」相反，所以不受触发源限制。
            if LiveCamPresentationRequest.resolve(hasAvatar: snapshot.avatar != nil) != .present {
                liveCamWindowController?.hide()
                return
            }
            guard LiveCamPresentationPolicy.shouldPresentLiveCam(
                trigger: trigger,
                hasAvatar: snapshot.avatar != nil,
                fullStageIsPresented: stageWindowController?.isPresented == true
            ) else {
                return
            }
            liveCamWindowController?.show()
        }
    }

    func runLivingWorldActivity(id: String) {
        let menu = LivingWorldActivityMenuStore.shared
        guard isResidentActivityAvailable(id) else {
            menu.report("当前角色或已安装动作不支持这项表演，请检查角色和动作素材。")
            return
        }
        _ = stopResidentLoop(reason: "开始生活活动")
        guard menu.canControl(worldID: spatialStage.selectedWorldID) else {
            menu.report("当前空间尚未接入生活活动，请切回生活舱。")
            return
        }
        // 「活动开始了」不是「进入小窗」的动作：这里以前会顺带 `showLiveCam()`，
        // 于是任何一次活动都把小窗顶出来。活动照常开始，窗口形态不动。
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
        let returnedHeldProp = stopResidentLoop(reason: "停止生活活动")
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
            menu.report(returnedHeldProp ? "生活活动已停止。" : "生活活动已停止，但手持物件尚未正式放回，请按提示处理。")
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
            // 「播了一个动作」不是「进入小窗」的动作：这里以前会顺带 `showLiveCam()`，
            // 于是任何一次动作都把窗口形态改掉。动作照常播放，窗口形态不动。
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
        musicSelectionGeneration &+= 1
        let requestedGeneration = musicSelectionGeneration
        orbWindowController?.setState(.thinking)
        activeProgram = nil
        updateStageProgramNavigation()
        programStore.beginPlanning()
        Task { [weak self] in
            guard let self else {
                return
            }
            var ownedGeneration = requestedGeneration
            var committedQueue: ProgramPlaybackQueue?
            let isCurrent: @MainActor () -> Bool = {
                !Task.isCancelled && self.musicSelectionGeneration == ownedGeneration
                    && (committedQueue == nil || self.programPlaybackQueue === committedQueue)
            }
            guard isCurrent() else { return }
            do {
                let plan = try await makeAIProgramPlan(
                    immediateUserInstruction:
                        immediateUserInstruction
                )
                guard isCurrent() else { return }
                let queue = ProgramPlaybackQueue(preflight: PlaybackPreflight(
                    preparer: MusicRuntimePlaybackPreparer(runtime: musicRuntime)))
                try await queue.load(plan)
                guard isCurrent() else { return }
                guard let prepared = queue.current else {
                    throw ProgramPlaybackQueueError.noPlayableSlots(
                        failedTrackIDs: queue.failedTrackIDs
                    )
                }
                committedQueue = queue
                programPlaybackQueue = queue
                activeProgram = plan
                programStore.publish(plan)
                try await playPreparedWithFallback(prepared,
                    isCurrentSelection: isCurrent,
                    onSelectionCommitted: { ownedGeneration = self.musicSelectionGeneration })
            } catch {
                guard isCurrent() else { return }
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

    /// 系统权限弹窗的有界等待上限：只限制「等用户回答授权」这一段，不覆盖连接阶段；
    /// 超时/取消都不丢弃迟到的授权结果（见 `MicrophoneAuthorizationGate`）。
    private static let residentVoiceAuthorizationDeadline: Duration = .seconds(60)

    func connectRealtimeVoice(
        _ configuration: RealtimeVoiceConfiguration
    ) {
        disconnectRealtimeVoice()
        AgentConversationService.shared.cancel()
        guard configuration.provider == .bailian else {
            showResidentVoiceStatus("当前语音输入仅支持百炼转写；其它服务尚未接入，请使用文字。")
            return
        }
        guard configuration.isReadyForResidentTranscription, let apiKey = configuration.apiKey else {
            showResidentVoiceFailure("请在设置中填写百炼 API Key，语音只用于转文字。")
            return
        }
        let requestID = UUID()
        residentVoiceRequestID = requestID
        residentVoiceAcceptsFinal = true
        setRealtimeVoiceState(.connecting)
        let previousShutdown = residentVoiceShutdownTask
        realtimeVoiceConnectionTask = Task { [weak self] in
            guard let self else { return }
            await previousShutdown?.value
            guard residentVoiceRequestID == requestID else { return }
            do {
                // 授权在连接超时窗口之外单独有界等待：系统弹窗未回答不再表现为
                // 「连接超时」，也不会挂住 shutdown 链。
                try await microphoneAuthorizationGate.resolveOrFail(
                    deadline: Self.residentVoiceAuthorizationDeadline
                ) { [weak self] in
                    self?.showResidentVoiceStatus("首次使用麦克风：请在系统弹窗里点「允许」。")
                }
                guard residentVoiceRequestID == requestID, !Task.isCancelled else { return }
                realtimeVoiceTimeoutTask?.cancel()
                realtimeVoiceTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard let self, self.residentVoiceRequestID == requestID else { return }
                    self.disconnectRealtimeVoice()
                    self.showResidentVoiceFailure("连接语音转写超时，请重试。")
                }
                let payload = BailianSessionPayload(
                    apiKey: apiKey,
                    model: "qwen3-asr-flash-realtime",
                    voiceID: "",
                    microphoneDeviceID: configuration.microphoneDeviceID,
                    purpose: .residentTranscription
                )
                let session = BailianRealtimeSession.live(audioGraph: audioGraph, providerTools: [])
                residentVoiceSession = session
                let ticket = RealtimeDJSessionTicket(
                    provider: .bailian,
                    sessionID: "resident-asr-\(requestID.uuidString)",
                    expiresAt: Date(timeIntervalSinceNow: 3_600),
                    providerPayload: try JSONEncoder().encode(payload)
                )
                try await session.connect(ticket: ticket)
                guard residentVoiceRequestID == requestID, !Task.isCancelled else {
                    await session.disconnect()
                    return
                }
                let events = await session.eventStream()
                residentVoiceEventTask = Task { [weak self] in
                    for await event in events {
                        guard let self, !Task.isCancelled,
                              self.residentVoiceRequestID == requestID else { return }
                        await self.consumeResidentVoiceEvent(event, requestID: requestID, session: session)
                        guard !Task.isCancelled,
                              self.residentVoiceRequestID == requestID else { return }
                    }
                }
                try await session.setMicrophoneCaptureEnabled(true)
                guard residentVoiceRequestID == requestID, !Task.isCancelled else { return }
                try await session.setMicrophoneTransmissionEnabled(true)
                guard residentVoiceRequestID == requestID, !Task.isCancelled else { return }
                setRealtimeVoiceState(.listening)
                showResidentVoiceStatus("正在听，说完一句会自动发送。再次点击麦克风可取消。")
                realtimeVoiceTimeoutTask?.cancel()
                realtimeVoiceTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.residentVoiceRequestID == requestID else { return }
                    self.disconnectRealtimeVoice()
                    self.showResidentVoiceFailure("本次录音已超时，请重新点击麦克风。")
                }
            } catch is CancellationError {
                // 用户取消或新请求取代：disconnectRealtimeVoice 已经更新过状态，
                // 这里静默收尾，绝不覆盖成失败。
                return
            } catch {
                guard residentVoiceRequestID == requestID else { return }
                // 清理不能等待正在执行本分支的连接任务自身。
                realtimeVoiceConnectionTask = nil
                disconnectRealtimeVoice()
                setRealtimeVoiceState(.failed(error.localizedDescription))
                showResidentVoiceFailure(error.localizedDescription)
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
        residentVoiceRequestID = nil
        residentVoiceAcceptsFinal = false
        let connectingTask = realtimeVoiceConnectionTask
        connectingTask?.cancel()
        realtimeVoiceConnectionTask = nil
        realtimeVoiceTimeoutTask?.cancel()
        realtimeVoiceTimeoutTask = nil
        residentVoiceEventTask?.cancel()
        residentVoiceEventTask = nil
        agentSpeechAnnouncer.stop()
        let session = residentVoiceSession
        residentVoiceSession = nil
        enqueueResidentVoiceShutdown(session, after: connectingTask)
        setRealtimeVoiceState(.disconnected)
        orbWindowController?.setVoiceLevel(0)
        stageWindowController?.setVoiceLevel(0)
    }

    @discardableResult
    private func enqueueResidentVoiceShutdown(
        _ session: (any RealtimeDJSession)?,
        after connectingTask: Task<Void, Never>? = nil
    ) -> Task<Void, Never> {
        let previousShutdown = residentVoiceShutdownTask
        residentVoiceShutdownGeneration &+= 1
        let generation = residentVoiceShutdownGeneration
        let shutdown = Task { [weak self] in
            await previousShutdown?.value
            // 先关闭连接解除可能不响应 Task.cancel 的握手，再等待其清理完成。
            try? await session?.setMicrophoneCaptureEnabled(false)
            try? await session?.setMicrophoneTransmissionEnabled(false)
            await session?.disconnect()
            if let connectingTask {
                await connectingTask.value
                try? await session?.setMicrophoneCaptureEnabled(false)
                try? await session?.setMicrophoneTransmissionEnabled(false)
                await session?.disconnect()
            }
            // 落地后清零，下一次连接不必再穿过已完成的历史链。
            self?.clearResidentVoiceShutdown(generation: generation)
        }
        residentVoiceShutdownTask = shutdown
        return shutdown
    }

    /// 只有仍是最新一代 shutdown 时才能清空指针，避免清掉刚入队的更新一代。
    private func clearResidentVoiceShutdown(generation: UInt64) {
        guard residentVoiceShutdownGeneration == generation else { return }
        residentVoiceShutdownTask = nil
    }

    func toggleRealtimeVoiceFromStage() {
        if residentVoiceRequestID != nil {
            disconnectRealtimeVoice()
            showResidentVoiceStatus("已取消本次录音。")
        } else {
            connectRealtimeVoice(realtimeVoicePreferences.load())
        }
    }

    private func showResidentVoiceStatus(_ text: String) {
        liveCamWindowController?.showVoiceStatus(text)
        stageWindowController?.showResidentVoiceStatus(text)
    }

    /// 语音连接失败/超时/断麦：失败类别，后续普通提示不得覆盖，用户可原地重试。
    private func showResidentVoiceFailure(_ text: String) {
        liveCamWindowController?.showFailureStatus(text)
        stageWindowController?.showResidentFailureStatus(text)
    }

    /// 居民回合失败的可见出口：后台/自驱回合只写状态，不替用户展开聊天或收起
    /// 面板；用户自己发起的回合仍然立即露出失败提示，方便重试。
    private func presentResidentLoopFailure(_ text: String) {
        // 与失败提示同一终态边界：本轮覆盖的用户提交在历史里标记「未送达」。
        let failedIDs = residentAgentLoop?.lastFinishedTurnSubmissionIDs ?? []
        if !failedIDs.isEmpty {
            residentChatTranscript.markFailed(ids: failedIDs)
            publishResidentTranscript()
        }
        let backgroundTurn = residentAgentLoop?.lastFinishedRunWasBackground == true
        liveCamWindowController?.showFailureStatus(text)
        stageWindowController?.showResidentFailureStatus(text, autoRevealsChat: !backgroundTurn)
    }

    /// 用户按下停止控件。这是**唯一**的"用户停止过"入口：它同时取消本轮、
    /// 让居民保持停止，并（经 `onUserStop`）落盘许愿任务级的自动续办暂停。
    /// `userIntent: false` 只用于宿主自身的上下文切换（换空间）——那里仍要作废
    /// 旧回合与旧提示，但不产生"用户停止"这一持久事实。
    private func cancelResidentMessage(userIntent: Bool) {
        musicSelectionGeneration &+= 1
        disconnectRealtimeVoice()
        // 用户主动停止即已接手：旧的「未确认送达」提示不再显示。
        residentUnconfirmedNotice.acknowledge(
            residentAgentLoop?.snapshot.unconfirmedUserMessages ?? []
        )
        // 明确停止：历史里仍无结论的回合按「未送达」收尾，绝不冒充已送达。
        residentChatTranscript.cancelPendingTurns()
        publishResidentTranscript()
        _ = stopResidentLoop(reason: userIntent ? "用户停止居民" : "换空间", userIntent: userIntent)
    }

    @discardableResult
    private func returnHeldPropBeforeResidentStop(reason: String) -> Bool {
        guard let context = livingWorldContext, let held = context.state.heldProp else { return true }
        let service = residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
            guard let self, let context else { return false }
            return self.livingWorldContext === context
        })
        do {
            let command = try service.returnHeldCommand(objectID: held.objectID)
            try service.commit(command, expectedLayoutRevision: context.state.layoutRevision,
                               requestID: "resident.stop.return.\(context.state.layoutRevision).\(held.objectID)")
            synchronizeResidentPropPresentation()
            return true
        } catch {
            showResidentVoiceStatus("\(reason)已执行，但手持物件未能正式放回，状态仍保留：\(error.localizedDescription)")
            return false
        }
    }

    /// 取消居民当前轮次。
    ///
    /// `userIntent` 是**因果**，不是措辞：只有用户按下停止控件才是 `true`。换播放曲目、
    /// 切角色动作、进出生活活动、换空间、退出应用都只是宿主需要回收本轮，它们一律
    /// `false` —— 否则这些动作会把"停止过"写成持久状态，让用户面对一个自己从没按过
    /// 的「恢复自动领取」按钮，而且无人能自愈。
    @discardableResult
    private func stopResidentLoop(reason: String, userIntent: Bool = false) -> Bool {
        let returnedHeldProp = returnHeldPropBeforeResidentStop(reason: reason)
        if let residentAgentLoop {
            if userIntent { residentAgentLoop.stop() } else { residentAgentLoop.cancel() }
        } else {
            AgentConversationService.shared.cancel()
        }
        return returnedHeldProp
    }

    private func consumeResidentVoiceEvent(
        _ event: RealtimeDJEvent,
        requestID: UUID,
        session: any RealtimeDJSession
    ) async {
        guard residentVoiceRequestID == requestID else { return }
        switch event {
        case let .userTranscriptFinal(text):
            guard residentVoiceAcceptsFinal else { return }
            residentVoiceAcceptsFinal = false
            realtimeVoiceTimeoutTask?.cancel()
            await enqueueResidentVoiceShutdown(session).value
            guard residentVoiceRequestID == requestID else { return }
            residentVoiceRequestID = nil
            residentVoiceSession = nil
            // 当前监听还要把最终稿交给 Agent；避免共享发送入口取消自身。
            residentVoiceEventTask = nil
            setRealtimeVoiceState(.disconnected)
            orbWindowController?.setVoiceLevel(0)
            stageWindowController?.setVoiceLevel(0)
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                showResidentVoiceStatus("没有听清内容，请重新录音或输入文字。")
                return
            }
            await sendLiveCamMessage(transcript)
        case let .userTranscriptDelta(text):
            guard residentVoiceAcceptsFinal else { return }
            showResidentVoiceStatus(text.isEmpty ? "正在转写…" : "正在转写：\(text)")
        case let .userAudioLevel(level):
            orbWindowController?.setVoiceLevel(level.peak)
            stageWindowController?.setVoiceLevel(Float(level.peak))
        case .userSpeechStarted:
            setRealtimeVoiceState(.listening)
        case .userSpeechFinished:
            orbWindowController?.setVoiceLevel(0)
            stageWindowController?.setVoiceLevel(0)
        case let .failure(failure):
            disconnectRealtimeVoice()
            showResidentVoiceFailure(failure.message)
        case .connectionChanged(.disconnected):
            disconnectRealtimeVoice()
            showResidentVoiceFailure("语音转写连接已断开，请重试。")
        default:
            break
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

        musicSelectionGeneration &+= 1

        do {
            activeProgram = nil
            updateStageProgramNavigation()
            try playLocalTrack(url)
        } catch {
            presentPlaybackError(error)
        }
    }

    func toggleLocalPlayback() {
        musicSelectionGeneration &+= 1
        _ = stopResidentLoop(reason: "切换播放器状态")
        residentJukeboxPlaybackOwner = nil
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
        try Task.checkCancellation()
        musicSelectionGeneration &+= 1
        residentJukeboxPlaybackOwner = ResidentActivityOutcome.playbackOwner
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
        musicSelectionGeneration &+= 1
        _ = stopResidentLoop(reason: "选择播放曲目")
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
        residentJukeboxPlaybackOwner = nil
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
        musicSelectionGeneration &+= 1
        _ = stopResidentLoop(reason: "切换上一首")
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
        musicSelectionGeneration &+= 1
        _ = stopResidentLoop(reason: "切换下一首")
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
        allowFallback: Bool = true,
        isCurrentSelection: @MainActor () -> Bool = { true },
        onSelectionCommitted: @MainActor () -> Void = {}
    ) async throws {
        playbackLogger.info(
            "准备播放：track=\(initial.slot.track.id, privacy: .public)，title=\(initial.slot.track.title, privacy: .public)，fallback=\(allowFallback)，opening=\(requestOpening)"
        )
        var prepared: PreparedProgramPlayback? = initial
        while let candidate = prepared {
            guard isCurrentSelection() else { throw CancellationError() }
            do {
                try await playPrepared(
                    candidate,
                    requestOpening: requestOpening,
                    isCurrentSelection: isCurrentSelection,
                    onSelectionCommitted: onSelectionCommitted
                )
                guard isCurrentSelection() else { throw CancellationError() }
                return
            } catch {
                guard isCurrentSelection() else { throw CancellationError() }
                playbackLogger.error(
                    "歌曲播放失败：track=\(candidate.slot.track.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                guard allowFallback else {
                    throw error
                }
                prepared = await programPlaybackQueue
                    .replaceCurrentAfterFailure()
                guard isCurrentSelection() else { throw CancellationError() }
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
        requestOpening: Bool = true,
        isCurrentSelection: @MainActor () -> Bool = { true },
        onSelectionCommitted: @MainActor () -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        if ResidentActivityOutcome.playbackOwner != nil,
           case .providerReference = prepared.target {
            throw ResidentActivityOutcomeError.unsupportedPlaybackSource
        }
        residentJukeboxPlaybackOwner = ResidentActivityOutcome.playbackOwner
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

        musicSelectionGeneration &+= 1
        onSelectionCommitted()
        switch prepared.target {
        case let .localFile(url):
            defer { onSelectionCommitted() }
            try playLocalTrack(url, loadSidecarLyrics: false)
        case let .providerReference(providerID, trackID):
            guard providerID == .appleMusic else {
                throw MusicProviderClientError.playbackUnavailable
            }
            try await musicRuntime.startAppleMusic(trackID: trackID)
            guard isCurrentSelection() else { throw CancellationError() }
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
        guard isCurrentSelection() else { throw CancellationError() }
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
                    approvedMotions: livingWorldApprovedMotions,
                    avatarFormat: avatarRuntime.snapshot.avatar?.format
                )
            )
            livingWorldContext = context
            avatarRuntime.removeMotionPlaybackObserver(residentMotionPlaybackObserverID)
            residentMotionPlaybackObserverID = avatarRuntime.observeMotionPlayback { [weak self] event in
                self?.handleResidentMotionPlayback(event)
            }
            LivingWorldActivityMenuStore.shared.update(
                definitions: context.activityCatalog.definitions.filter { isResidentActivityAvailable($0.id) },
                worldID: context.manifest.worldID
            )
            stageAvatarActivityExecutor = avatarExecutor
            worldAgentToolDispatcher = WorldAgentToolDispatcher(
                takeoverEnabled: { [weak self] in
                    self?.agentPreferences.takeoverEnabled() ?? false
                },
                context: context,
                availableActivity: { [weak self] in self?.isResidentActivityAvailable($0) ?? false }
            )
            let observationScopeID = UUID().uuidString
            context.onEventsPublished = { [weak self, weak context] events in
                guard let self, let context,
                      self.livingWorldContext === context,
                      self.spatialStage.selectedWorldID == context.manifest.worldID else { return }
                let loop = self.ensureResidentLoop()
                for event in events {
                    if let observation = ResidentWorldObservation.event(
                        event, worldID: context.manifest.worldID, scopeID: observationScopeID
                    ) {
                        loop.receiveEvent(observation)
                    }
                }
            }
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
                        props: CollisionVolumeWorld(volumes: ResidentPropPlacementConfiguration.independentCollisionVolumes(context.manifest))
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
        synchronizeResidentLoopPresentation()
        LivingWorldActivityMenuStore.shared.updateActiveActivity(id: snapshot.activeActivity?.id)
        // Capability binds, withdrawals and placements commit through layout
        // revisions; this diff-guarded refresh picks the change up without
        // rebuilding the menu on unchanged snapshots.
        refreshResidentActivityMenu()
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

        if residentPropEditingWorldID == nil, let liveCamera = snapshot.liveCamera,
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
        let applyOutcome = stageAvatarActivityExecutor.apply(
            transform: snapshot.agentTransform,
            activity: activity,
            phase: phase,
            sourceRevision: snapshot.revision,
            activityRequestID: snapshot.activeActivity == nil ? context.currentMovementRequestID : context.currentActivityRequestID,
            phaseContract: contract,
            approvedMotions: LivingWorldAvatarPresentationPolicy
                .compatibleMotions(
                    livingWorldApprovedMotions,
                    avatarFormat: avatarRuntime.snapshot.avatar?.format
                )
        )
        // A capability activity's enter phase has no timed duration: if the
        // button motion resolved to a natural-idle fallback (wrong avatar
        // format or missing asset), the usage must fail instead of hanging
        // or silently "succeeding".
        if case let .applied(applied) = applyOutcome,
           applied.motionPlayback.isNaturalIdleFallback,
           applied.phase == .enter,
           let active = snapshot.activeActivity,
           context.isPropCapabilityActivity(active.id),
           let requestID = applied.activityRequestID
        {
            do {
                try context.failActivityPlayback(requestID: requestID, phase: .enter)
            } catch {
                livingWorldLogger.error("物件使用动作不可用且无法失败回写：\(error.localizedDescription, privacy: .public)")
            }
        }
        if residentPropEditingWorldID == nil {
            stageCameraCoordinator?.followAvatarHorizontally(
                from: previousAvatarPosition,
                to: spatialStage.avatarPlacement.position
            )
        }
    }

    private func handleResidentMotionPlayback(_ event: StageMotionPlaybackEvent) {
        guard let context = livingWorldContext,
              spatialStage.selectedWorldID == context.manifest.worldID,
              let requestID = event.identity.worldActivityRequestID,
              let phase = event.identity.worldActivityPhase else { return }
        do {
            if context.currentActivityRequestID == requestID {
                switch event.outcome {
                case .completed:
                    guard !event.identity.motion.loop else { return }
                    try context.completeActivityPlayback(requestID: requestID, phase: phase)
                case .failed:
                    try context.failActivityPlayback(requestID: requestID, phase: phase)
                }
            } else if context.currentMovementRequestID == requestID,
                      case .failed = event.outcome {
                try context.failMovementPlayback(requestID: requestID)
            }
        } catch {
            livingWorldLogger.error("动作播放结果无法同步到世界")
        }
    }

    private func performLivingCabinJukeboxEffect(_ snapshot: WorldAgentSnapshot) {
        if residentActivityOutcome?.suppressesAutomaticEffect(snapshot) == true { return }
        guard let active = snapshot.activeActivity,
              active.id == "music.listen",
              active.phase == .enter || active.phase == .loop else { return }
        // 从这里往下，每一条不成立都意味着"这一次不会出声"。过去它们共用同一个静默
        // return，真机上只能看到"操作被接受，然后什么都没发生"—— 原因既不上屏也不
        // 可分辨。现在每一条都有名字。
        guard spatialStage.marbleLivingCabin?.worldID == snapshot.worldID else {
            return reportJukeboxSilence(snapshot, "生活舱没有接在这个世界上")
        }
        guard spatialStage.selectedWorldID == snapshot.worldID else {
            return reportJukeboxSilence(snapshot, "当前显示的不是这个世界")
        }
        guard let context = livingWorldContext else {
            return reportJukeboxSilence(snapshot, "生活空间上下文已经不存在")
        }
        guard let startedAt = context.simulation.state.activeActivity?.startedAt else {
            return reportJukeboxSilence(snapshot, "模拟状态里没有这次活动（活动只活在执行器里）")
        }
        guard let requestID = context.currentActivityRequestID else {
            return reportJukeboxSilence(snapshot, "这次活动没有执行请求编号")
        }
        guard livingCabinJukeboxGate.consume(
            worldID: snapshot.worldID, activityID: active.id,
            startedAt: startedAt, phase: active.phase.rawValue, requestID: requestID
        ) else {
            livingWorldLogger.info(
                "点唱机：这次执行实例已经处理过，跳过重复触发 request=\(requestID, privacy: .public)"
            )
            return
        }
        reportedJukeboxSilenceInstance = nil
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            guard spatialStage.selectedWorldID == snapshot.worldID,
                  livingWorldContext === context,
                  livingWorldContext?.currentActivityRequestID == requestID,
                  livingWorldContext?.snapshot.activeActivity?.id == "music.listen"
            else {
                return reportJukeboxSilence(snapshot, "等待播放结果期间世界或活动已经换掉了")
            }
            do {
                try await resumeMusic()
                liveCamWindowController?.showChatStatus("点唱机开始播放音乐。")
            } catch {
                // 良性状态也**必须**上屏：用户问的正是"为什么没出声"。橙色横幅说的是
                // 事实（没有已准备的曲目），不是把正常状态说成故障。
                let isBenign: Bool
                switch error {
                case DJAgentRadioActionError.noProgram, DJAgentRadioActionError.noPreparedProgram:
                    isBenign = true
                default:
                    isBenign = false
                }
                reportJukeboxSilence(
                    snapshot,
                    isBenign
                        ? "点唱机上没有已经准备好的曲目（\(error.localizedDescription)）"
                        : error.localizedDescription
                )
            }
        }
    }

    /// 一次执行实例里同一条原因只报一次，但**一定**报：日志 + 屏上状态。
    /// 静默的失败在真机上与"什么都没发生"无法区分，这正是点唱机缺陷的形态。
    private func reportJukeboxSilence(_ snapshot: WorldAgentSnapshot, _ reason: String) {
        let phase = snapshot.activeActivity?.phase.rawValue ?? "nil"
        let instance = "\(snapshot.worldID):\(snapshot.activeActivity?.id ?? "nil"):\(phase):\(reason)"
        livingWorldLogger.error(
            "点唱机没有出声：\(reason, privacy: .public) instance=\(instance, privacy: .public)"
        )
        guard reportedJukeboxSilenceInstance != instance else { return }
        reportedJukeboxSilenceInstance = instance
        liveCamWindowController?.showChatStatus("点唱机没有出声：\(reason)")
    }

    private func refreshInstalledLivingWorldMotions() {
        defer {
            refreshResidentActivityMenu()
            livingWorldContext?.updateWalkingSpeed(LivingWorldBootstrap.walkingSpeed(
                approvedMotions: livingWorldApprovedMotions,
                avatarFormat: avatarRuntime.snapshot.avatar?.format
            ))
        }
        guard
            let motionPackageStore,
            let motions = try? motionPackageStore.listMotions()
        else {
            return
        }
        let knownIDs = LivingWorldBootstrap.installedLivingMotionIDs.union(ResidentPerformanceMotionPolicy.motionIDs)
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
            },
            onSendMessage: { [weak self] message in
                try await self?.sendResidentSubmission(message, source: .stage)
            },
            onCancelMessage: { [weak self] in
                self?.cancelResidentMessage(userIntent: true)
            },
            onOpenSystemInbox: { [weak self] in
                self?.openSystemInbox()
            }
        )
        // 面板上的"恢复自动领取"= 宿主的一个动作：任务级续办与 run 级停止一起解开。
        stageWindowController?.setWishContinuationResumeHandler { [weak self] id in
            self?.resumeWishAutomaticContinuation(id: id)
        }
        // 建造模式：鼠标移动 → 格子拾取 → footprint 判定 → 整块着色。
        stageWindowController?.onResidentPropGridCursor = { [weak self] normalized in
            self?.residentPropGridHover(normalized: normalized)
        }
        // 建造模式：点一下 → 在吸附后的格心上落地。与悬停同一个归一化口径，
        // 所以落点就是用户最后看到 footprint 停住的那一格。
        stageWindowController?.onResidentPropGridCommit = { [weak self] normalized in
            self?.residentPropGridCommit(normalized: normalized)
        }
        // 建造模式：**空手**在场景里点了一下 → 拿起光标下的已摆物件（等价于点面板那一行）。
        // 手上有物件时不会走这里（那是上面的落地通路），所以两条路不可能互相吃掉。
        stageWindowController?.onResidentPropScenePick = { [weak self] normalized, clickCount in
            self?.residentPropScenePick(normalized: normalized, clickCount: clickCount)
        }
        // R / ⇧R / `,` / `.` / 场景内**右键单击**：45° 步进旋转（Sims 4 官方口径；原来是 90°）。旋转改的是
        // footprint 朝向，重新着色后由 `publishResidentPropGrid` 把新的吸附位置与朝向推给预览。
        stageWindowController?.onResidentPropGridRotate = { [weak self] steps in
            self?.residentPropGridEditor.rotateFootprint(bySteps: steps)
        }
        if let stageWindowController {
            configureResidentPropEditor(stageWindowController)
            let liveCamWindowController = LiveCamWindowController(
                renderSurfaceController: stageRenderSurfaceController,
                cameraCoordinator: stageCameraCoordinator,
                voiceState: RealtimeVoiceStatusStore.shared.state,
                shouldPresent: { [weak self] in
                    guard let self else { return false }
                    let snapshot = self.avatarRuntime.snapshot
                    guard DesktopPresenceMode.resolve(
                        snapshot: snapshot,
                        isRadioPluginEnabled: RadioPluginAvailability.isEnabled()
                    ) == .liveCam else { return false }
                    // Live Cam 是角色视图：没有角色时不呈现空窗口，改走可见引导
                    // （与 applyDesktopPresence 同一判据）。
                    return LiveCamPresentationRequest
                        .resolve(hasAvatar: snapshot.avatar != nil) == .present
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
                    try await self.sendResidentSubmission(message, source: .liveCam)
                },
                onCancelMessage: { [weak self] in
                    self?.cancelResidentMessage(userIntent: true)
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
            liveCamWindowController.setSystemInboxHandler { [weak self] in
                self?.openSystemInbox()
            }
            liveCamWindowController.setWishContinuationResumeHandler { [weak self] id in
                self?.resumeWishAutomaticContinuation(id: id)
            }
            self.liveCamWindowController = liveCamWindowController
            publishResidentTranscript()
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
                case .userTranscriptFinal:
                    // 居民录音由带请求编号的独立转写监听处理。
                    break
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
    private var liveCamMessageID: UUID?
    private var residentAgentLoop: ResidentAgentLoop?
    /// 「补充消息交付未确认」的可见生命周期：用户下一次真实发送/停止/换空间后旧提示
    /// 不再显示；模型上下文（unconfirmedUserMessages）不变。
    private var residentUnconfirmedNotice = ResidentUnconfirmedNoticePolicy()
    // **长期记忆已由用户决定不做**（2026-10-01）。这里原先有一个
    // `ResidentLongTermMemoryNoticePolicy`，每轮给用户一句"长期记忆暂不可用"。
    // 既然不做，就不该在界面上宣传一个不会有的能力（那会让人以为"以后会有"），
    // 所以那句提示连同策略一起删除。「不搞」这件事由
    // `tools/test-no-long-term-memory-capability.swift` 钉住（注入回来 ⇒ FAIL）。
    private let residentActivityOwnership = ResidentActivityOwnership()
    private var residentLoopSchedulingTask: Task<Void, Never>?
    private let propGenerationStore = PropGenerationStore()
    private var wishMachineConfiguration: PropGenerationConfiguration?
    private var wishMachineServiceNotice = "许愿机服务尚未配置，请在空间设置中配置。"
    private lazy var wishMachineCoordinator = WishMachineCoordinator(store: propGenerationStore,
        canClaim: { [weak self] job in self?.wishMachineClaimEvidence(for: job) })
    private struct ResidentWishImageRegistration {
        let attachment: ResidentImageAttachment
        let loopID: ObjectIdentifier
        let worldScope: String
        let conversationID: UUID
        let registeredAt = Date()
    }
    private var residentWishImages: [URL: ResidentWishImageRegistration] = [:]
    private struct ResidentWishScope {
        let loopID: ObjectIdentifier
        let worldID: String
        let residentScope: String
    }
    private var residentWishScope: ResidentWishScope?
    private struct ResidentWishDelivery: Hashable {
        let id: UUID
        let consumer: String
        let worldID: String
        let residentScope: String
    }
    private var residentWishMessageScope: PropTaskContext?
    private var residentWishMessageSubscriptions = Set<String>()
    private var residentWishMessages: [ResidentWishDelivery: PropTaskMessage] = [:]
    private var residentWishAcknowledgements = Set<ResidentWishDelivery>()
    private var residentWishConsumed = Set<ResidentWishDelivery>()
    private var residentWishAcknowledging = Set<ResidentWishDelivery>()
    private var residentWishSnapshotPending = Set<UUID>()
    /// 已经**本地直达**投递给居民循环的持久事实编号。守护进程消息往返是另一条
    /// 通道，它不可用时（网络/守护进程没起来）这条本地通道仍然把"东西已经好了"
    /// 这类事实送进循环；同一个事件只送一次，循环自己也按事件编号去重。
    private var residentWishLocalFactsQueued = Set<UUID>()
    private var residentWishMessagesConfigured = false
    private var residentWishMessageRefreshRunning = false
    private var residentWishMessageRefreshRequested = false
    private var residentWishMessageErrorShown = false

    private struct ResidentOwnedPropAsset {
        let prop: WorldGeneratedProp
        let descriptor: ResidentPropRenderDescriptor
    }
    private var residentOwnedPropAssets: [String: ResidentOwnedPropAsset] = [:]
    private var residentPropAssetContext: ObjectIdentifier?
    private var residentPropPreparationRunning = false
    private var residentPropNotices: [String: String] = [:]
    /// 「已领取但还没写进库存」的补做台账（见 `ResidentPropInventoryBacklog`）。
    ///
    /// 判定本身不放宽：承托几何拿不到时 `ResidentPropPlacementService.validate` 仍然
    /// fail-closed 拒绝。台账解决的是**被拒之后没人补做**：几何就绪那一刻补做一次，
    /// 并且在此期间把"已领取、等待入库"说给用户，而不是让它隐形。
    private var residentPropInventoryBacklog = ResidentPropInventoryBacklog()
    /// 物件**资产**（模型文件）最近一次真实失败的原因：编号 → 可读原因。
    ///
    /// 与"库存"是两件事，必须分开说：库存里有它、模型却没备好时，面板那一条不能消失，
    /// 但也不能假装它现在能摆。只在**真的失败过**时才有记录（不是"暂时还没准备好"），
    /// 否则会在世界切换后的第一个同步周期里误报。
    private var residentPropAssetFailures: [String: String] = [:]
    /// 建造模式的格子数据中枢。网格只在几何变化时派生（按 worldID 缓存），
    /// 已放物件的增删不改变网格。
    private let residentPropGridEditor = ResidentPropGridEditorModel()
    /// 最近一次推给编辑器的吸附目标（位置 + 朝向）。用来跳掉"同一格内移动鼠标"的重复预检。
    private var residentPropGridPushedHover: ResidentPropGridHoverKey?
    /// **正在进行的那一次**格子派生的令牌（nil = 现在没有派生在跑）。
    ///
    /// 为什么是令牌而不是 Bool：Bool 记不住"这次请求后来死了"。2026-09-28 真机上
    /// 面板一直说「格子还在生成，请稍候」，而采样里**没有任何派生在跑** —— 说明
    /// "请求过"必须随任务结束而失效，否则这句话会永远挂着，用户也就永远点不动那一行。
    /// 令牌只由 `activateResidentPropGrid` 发放，由那次派生的收尾收回。
    private var residentPropGridDerivation: UUID?

    /// 面板快照里承托几何的状态：**就绪与否看 `isGridReady`**，`isDeriving` 只回答
    /// "还会不会好"。两个事实都来自 `residentPropGridEditor` 与派生令牌（唯一真相）。
    ///
    /// 它同时是"要不要重推面板快照"的比较键 —— 见 `publishResidentPropGrid`。
    /// 注意它**不回答"承托面能不能用"**：那件事只有 `surfaces` 说了算，见
    /// `ResidentPropSupportReadiness`。
    private struct ResidentPropSupportPhase: Equatable {
        let isGridReady: Bool
        let isDeriving: Bool
    }
    private var residentPropSupportPhase: ResidentPropSupportPhase {
        .init(isGridReady: residentPropGridEditor.isReady,
              isDeriving: residentPropGridDerivation != nil)
    }
    private var publishedResidentPropSupportPhase: ResidentPropSupportPhase?
    /// 最近一次**已经写进日志**的相位。只为压制"推失败时每次鼠标移动都刷一条"。
    private var loggedResidentPropSupportPhase: ResidentPropSupportPhase?

    /// **场景输入链[7]/[8]** 的限流键：上一次已经上报过的「悬停 guard 失败原因」或
    /// 「命中格」签名。`updateResidentPropGridHover` 每次鼠标移动都会被调到（60 Hz），
    /// 所以只在签名变化时报一条 —— 同一个原因 / 同一格不重复刷屏。
    private var loggedResidentPropGridHoverSignature: String?

    /// 「这次点击还能不能拿到摆放几何」—— 面板那句提示与它**一一对应**。
    ///
    /// 为什么要它（而不是直接看 `grid != nil`）：`PropSupportGridBuilder` 的失败是
    /// **fail-closed 但非 nil** 的 —— 种子越界、范围内没有可用几何、没有候选层时它返回
    /// `PropSupportGrid.empty`，而 `grid != nil` 会被 `isReady` 判成"就绪"。于是
    /// `!isGridReady && …` 恒为假，面板只能永远说「格子还在生成，请稍候」：既没有格子在
    /// 生成，也永远点不动那一行。真机 2026-09-28 的截图就是这句话。
    ///
    /// 判据只有两条，各自回答一个问题：
    /// - `hasSurfaces`（`surfaces` 非空）：**现在能不能摆放**（fail-closed 的唯一判据）；
    /// - `isDeriving`（有一次派生真的在跑）：**还会不会好**。
    ///
    /// 两者互斥地覆盖三种事实：有承托面 = 就绪；没有但任务在跑 = 真的在生成；
    /// 没有且没有任务在跑 = 拿不到（无论 `grid` 是不是非 nil 的空网格）。
    enum ResidentPropSupportReadiness: Equatable {
        case deriving
        case ready
        case unavailable

        static func resolve(hasSurfaces: Bool, isDeriving: Bool) -> Self {
            if hasSurfaces { return .ready }
            return isDeriving ? .deriving : .unavailable
        }

        /// 与 `ResidentPropEditorSnapshot.supportGeometryUnavailable` 同义。
        var supportGeometryUnavailable: Bool { self == .unavailable }
    }

    /// 这次点击要不要先把装修会话接回来。
    ///
    /// 为什么需要自救：面板的开关（`ResidentPropEditorState.isOpen`）与宿主的装修会话
    /// （`residentPropEditingID` / `residentPropEditingWorldID`）是两份状态，而
    /// `setResidentPropEditing(true)` 的守卫会**静默** return。一旦会话没接上，面板虽然
    /// 开着，`refreshSnapshot` 却永远答 nil，于是那一行永远停在"还没好"—— 而且关掉面板
    /// 再打开也未必重接（同一个守卫仍然拦）。所以点行时按现状判断一次并重接，
    /// 比"让用户多点几次"可靠：格子已经就绪时点行必须能进携带态。
    enum ResidentPropDecorationSessionRearm {
        static func shouldRearm(hasSession: Bool, sessionWorldID: String?, worldID: String) -> Bool {
            guard hasSession else { return true }
            return sessionWorldID != worldID
        }
    }

    /// 吸附目标的比较键。用**位置 + 朝向**而不是格号：编辑器真正关心的是"预览挪到哪"。
    private struct ResidentPropGridHoverKey: Equatable {
        let x: Float
        let y: Float
        let z: Float
        let yaw: Float
    }
    private var residentPropEditingWorldID: String?
    private var residentPropEditingID: UUID?
    private var residentPropEditingBackgroundEnabled = false
    private var residentPropEditingPreferenceEnabled = false
    private var residentPropTemporaryCancellation = false
    private var residentAvatarObservationInitialized = false

    private func temporarilyPauseResidentForPropEditing() {
        residentPropTemporaryCancellation = true
        defer { residentPropTemporaryCancellation = false }
        residentAgentLoop?.setBackgroundEnabled(false)
    }

    private func residentPropPlacementService(context: WorldAgentContext,
                                              isCurrent: @escaping @MainActor () -> Bool) -> ResidentPropPlacementService {
        ResidentPropPlacementService(context: context,
            // 承托几何来自建造模式的格子模型：派生好的网格 + 能给出三角形的碰撞世界。
            // 建造模式没开或几何不可用时返回 nil，摆放一律被拒绝（fail-closed）。
            support: { [weak self] in
                guard let self, let grid = self.residentPropGridEditor.grid,
                      let collision = self.residentPropGridEditor.supportCollision else { return nil }
                return ResidentPropPlacementSupport(
                    grid: grid,
                    collision: collision,
                    // 「别把唯一通路堵死」这条判据的全部输入（收窄后）。
                    // 拿不到就返回 nil ⇒ 服务拒绝摆放（fail-closed）。
                    routeConstraint: self.residentPropRouteConstraint()
                )
            },
            prepare: { [weak self] prop in
                guard let self, let asset = self.residentOwnedPropAssets[prop.objectID], asset.prop.matchesIdentity(of: prop),
                      self.spatialStage.isResidentPropPrepared(assetID: prop.assetID, modelURL: asset.descriptor.modelURL)
                else { throw ResidentPropHostError.assetUnverified }
            }, isCurrent: isCurrent,
            currentAvatarAssetID: { [weak self] in self?.avatarRuntime.snapshot.avatar?.id },
            makeGripCalibration: { [weak self] prop, avatarID, point in
                guard let self, let avatar = self.avatarRuntime.snapshot.avatar, avatar.id == avatarID else {
                    throw ResidentPropPlacementError.avatarChanged
                }
                if let reason = ResidentPropAttachmentEligibility.rejectionReason(for: avatar) {
                    throw ResidentPropPlacementError.attachmentUnsupported(reason)
                }
                guard let asset = self.residentOwnedPropAssets[prop.objectID], asset.prop.matchesIdentity(of: prop) else {
                    throw ResidentPropHostError.assetUnverified
                }
                // 门槛问的是**这个挂点自己的骨骼**：找不到就报「这个角色没有可用的腰部骨骼」
                // 这类读得懂的话（`PropAttachmentError.missingBone`），而不是静默挂不上。
                try self.spatialStage.validateResidentPropAttachment(avatarID: avatarID,
                    assetID: prop.assetID, modelURL: asset.descriptor.modelURL, point: point)
                guard let calibration = ResidentPropAttachmentEligibility.suggestedCalibration(
                    for: prop, avatar: avatar, point: point) else {
                    throw ResidentPropPlacementError.attachmentUnsupported(
                        "这个物件还没有当前居民的\(PropAttachmentSlots.displayName(for: point))挂点建议。")
                }
                return calibration
            })
    }

    /// Receipts and claim ownership are the only source of local asset paths.
    private func synchronizeOwnedResidentProps() async {
        guard let context = livingWorldContext, spatialStage.selectedWorldID == context.manifest.worldID,
              context.manifest.worldID == WishMachineScene.worldID else {
            residentOwnedPropAssets = [:]; residentPropAssetContext = nil
            // 资产失败是**按上下文**记住的：换世界（或这一刻不是许愿机那个世界）时作废，
            // 否则一个世界的坏资产会在另一个世界里继续冒充"资产未就绪"。
            // 台账（`residentPropInventoryBacklog`）**刻意不在这里清**：领取与"还没入库"
            // 是跨世界仍然成立的事实，回到那个世界后既有的 5 秒同步周期会继续补做。
            residentPropAssetFailures = [:]
            spatialStage.residentPropOutputs = []; spatialStage.residentPropPreview = nil
            spatialStage.residentHeldProp = nil
            spatialStage.residentPropDisplayStand = nil
            stageWindowController?.updateResidentPropEditor(.empty)
            return
        }
        let contextID = ObjectIdentifier(context)
        if residentPropAssetContext != contextID {
            residentOwnedPropAssets = [:]; residentPropNotices = [:]; residentPropAssetFailures = [:]
            residentPropAssetContext = contextID
        }
        guard !residentPropPreparationRunning else { return }
        residentPropPreparationRunning = true
        defer { residentPropPreparationRunning = false }
        /// 这一轮"摆正"要给用户看的话（按物件）。在**既有那几条会 removeValue 的路径之后**
        /// 统一发出去，否则"已按主轴摆正"会被"入库成功"冲掉 —— 用户就只看到结果、看不到原因。
        var orientationNotices: [String: String] = [:]
        let scope = currentResidentWorldContext().sessionScope
        let jobs = wishMachineCoordinator.residentJobs(worldID: context.manifest.worldID, residentScope: scope).filter { $0.stage == .claimed }
        // The Metal view publishes its resident-prop handlers on the first
        // eligible draw, which races launch. Defer the whole pass while the
        // renderer is unready: no task, ownership or model record is touched,
        // and the existing refreshWishMachine cycle retries automatically.
        if ResidentPropStartupRecovery.action(
            rendererReady: spatialStage.canPrepareResidentProp(worldID: context.manifest.worldID),
            error: nil
        ) == .deferUntilRendererReady {
            return
        }
        for job in jobs.filter({ residentOwnedPropAssets[$0.objectID] == nil }).prefix(2) {
            do {
                guard let record = propGenerationStore.jobs.first(where: { $0.id == job.jobID }),
                      let receipt = record.receipt, receipt.state == .completed, let inspection = receipt.result?.inspection,
                      let path = record.localModelPath, job.modelPath == path else { throw ResidentPropHostError.assetUnavailable }
                let url = URL(fileURLWithPath: path)
                let hash = inspection.sha256
                let bytes = inspection.bytes
                try await Task.detached(priority: .utility) {
                    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }), bytes > 0, bytes <= 32 * 1024 * 1024 else { throw ResidentPropHostError.assetUnavailable }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == bytes else { throw ResidentPropHostError.assetUnavailable }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard data.count == bytes, digest == hash.lowercased() else { throw ResidentPropHostError.assetUnavailable }
                }.value
                try Task.checkCancellation()
                guard self.livingWorldContext === context, self.spatialStage.selectedWorldID == context.manifest.worldID else { return }
                let descriptor = ResidentPropRenderDescriptor(objectID: job.objectID, worldID: job.worldID,
                    assetID: "sha256:" + hash.lowercased(), modelURL: url, targetHeightMeters: Float(job.heightMeters),
                    position: .zero, yaw: 0)
                let prepared = try await spatialStage.prepareResidentProp(descriptor)
                guard self.livingWorldContext === context, self.spatialStage.selectedWorldID == context.manifest.worldID else { return }
                // 尺寸标定在**这一处**从"请求尺寸"落成世界尺寸，而且只用唯一那份策略
                // （`WorldPropSizePolicy`）：`job.heightMeters` 是生成请求的高度，原始网格的
                // 实测三维来自渲染器（`prepared.minimum/maximum`）。
                //
                // **用户说了尺寸就按他说的轴归一**（提交时的 `size_intent`）：真机那把剑
                // （"一把 1.1 米的剑"）说的是**最长边** 1.1 m，原来按高度归一成了 8.285 m 长、
                // 比舱室还长、摆放被拒后从房间里消失。没有意图时才走自动推断（细长物件 > 4 按最长边）。
                let extent = prepared.maximum - prepared.minimum
                // ---- 摆正（朝向归一）----------------------------------------------------
                // 生成服务交回来的网格**不保证立着**（真机那把剑的 AABB 是 1.005 × 0.133 × 0.057，
                // 躺着）。这一步只在**入库这一处**做一次，三条路按优先级，而且**都不许猜**：
                //   ① 回执 `authoritative_size` 里声明的 `up_axis` / `forward_axis`（最干净）；
                //   ② 由网格自身的主轴推断（最长边明显不在 Y 轴上 ⇒ 躺着生成）；
                //   ③ 都说不清 ⇒ **保留原样**并在面板上说清楚（`unresolved`）。
                // 摆正**先于**尺寸策略：转正之后的 AABB 才是"这件东西多大"的输入，
                // 于是 1.1 m 的请求得到一把立着的 1.1 m 剑，而不是 8.28 m 长的横棍。
                let declared = receipt.result?.workflowAuthoritativeSize
                let orientation = WorldPropOrientationPolicy.resolve(
                    sourceExtent: WorldVector3(x: extent.x, y: extent.y, z: extent.z),
                    declaredUpAxis: declared?.upAxis,
                    declaredForwardAxis: declared?.forwardAxis
                )
                let orientedExtent = WorldPropOrientationPolicy.orientedExtent(
                    of: WorldVector3(x: extent.x, y: extent.y, z: extent.z), by: orientation
                )
                let sourceExtent = orientedExtent
                // 摆正这件事**必须说出来**（转了要说、"保留原样"更要说）：用户看到物件换了
                // 姿态（或者本该换却没换），画面里得有东西解释这是谁干的、凭什么。
                // 已经立着的资产（绝大多数）notice 是 nil，不打扰。
                // 记在这里、**最后再发**：下面几条既有路径都会 `removeValue`，早发会被冲掉。
                if let notice = orientation.notice {
                    orientationNotices[job.objectID] = "\(job.name)：\(notice)"
                }
                // 契约的意图 → 世界状态的意图：轴/出处就是同一批字面量，越界 ⇒ nil（不静默）。
                let sizeIntent = job.sizeIntent.flatMap {
                    WorldPropSizeIntent(axis: $0.axis.rawValue, meters: $0.meters, source: $0.source.rawValue)
                }
                // 有意图按用户的轴归一；没有意图才走今天的自动推断。
                let intendedSize = sizeIntent.flatMap {
                    WorldPropSizePolicy.intended(sourceExtent: sourceExtent, axis: $0.axis, meters: $0.meters)
                }
                guard let autoSize = intendedSize ?? WorldPropSizePolicy.automatic(
                    sourceExtent: sourceExtent,
                    requestedHeight: Float(job.heightMeters)) else {
                    throw ResidentPropHostError.assetUnavailable
                }
                let prop = WorldGeneratedProp(objectID: job.objectID, sourceWishID: job.id.uuidString,
                    assetID: descriptor.assetID, displayName: job.name,
                    size: autoSize.size, sourceHeight: sourceExtent.y,
                    sizeIntent: sizeIntent,
                    // 已经立着的资产不写这个键 ⇒ 元数据与改造前逐字节相同。
                    orientation: orientation.shouldArchive ? orientation : nil)
                // 用户**手动定过尺寸**的物件：世界状态里那一份 `size` 是唯一定稿，自动基线不再
                // 要求逐位相等 —— 要求相等就等于"改过尺寸的物件在下一次准备时被判成资产归属
                // 不一致"，那件物件会从房间里消失（正是这次要修的观感缺陷）。
                // 带尺寸意图的物件同理（它是"提交时说的"，不是"这次量出来的"）。
                let storedProp = context.state.objectStates[job.objectID]?.generatedProp
                if context.state.objectStates[job.objectID] != nil {
                    guard let storedProp, storedProp.matchesIdentity(of: prop) else { throw ResidentPropHostError.ownershipMismatch }
                }
                // 旧存档（改造前登记的）没有 `orientation`，而它的 `sourceHeight` 是按**原始**
                // 网格量的。网格字节没变（`assetID` 就是 sha256），所以这里把"同一份网格的新
                // 量法"补上：尺寸/尺寸意图/代理/锁**全部以存档那一份为准**，只补朝向与高度基准。
                // 不写回存档 ⇒ 不静默改用户已经保存的东西；渲染与碰撞本会话立刻正确。
                let delivered = storedProp.map { stored in
                    WorldGeneratedProp(
                        objectID: stored.objectID, sourceWishID: stored.sourceWishID,
                        assetID: stored.assetID, displayName: stored.displayName,
                        size: stored.size, sourceHeight: sourceExtent.y,
                        sizeLocked: stored.sizeLocked, collision: stored.collision,
                        authoritativeSize: stored.authoritativeSize, sizeIntent: stored.sizeIntent,
                        orientation: stored.orientation ?? (orientation.shouldArchive ? orientation : nil)
                    )
                } ?? prop
                var preparedDescriptor = descriptor
                preparedDescriptor.orientation = delivered.orientationRotation
                residentOwnedPropAssets[job.objectID] = ResidentOwnedPropAsset(prop: delivered, descriptor: preparedDescriptor)
                residentPropNotices.removeValue(forKey: job.objectID)
                residentPropAssetFailures.removeValue(forKey: job.objectID)
                // 握点推断说了什么，同样**必须说出来**：这条说明走的就是上面
                // `orientationNotices[job.objectID]` 那条既有的可见通道（同一格 →
                // 末尾统一 `residentPropNotices` + `showResidentVoiceStatus`），
                // 不新开第二条 notice 通道。入库这一处是唯一同时握有"最终世界尺寸 +
                // 摆正旋转"的地方（`delivered`），所以握点说明与握点标定读的是
                // 同一次 `PropGripInference` 推断 —— 一句话不会只说给日志听。
                if let gripNotice = ResidentPropAttachmentEligibility.suggestedGripNotice(for: delivered) {
                    let prefix = orientationNotices[job.objectID].map { $0 + " " } ?? "\(job.name)："
                    orientationNotices[job.objectID] = prefix + gripNotice
                }
                // 夹取时**说出来**（夹取是"静默改数字"之外唯一诚实的做法）；
                // 按用户说的尺寸落定时也说出来，让"尺寸是怎么定的"看得见。
                if let reason = autoSize.reason {
                    let message = "\(job.name)：\(reason)"
                    residentPropNotices[job.objectID] = message
                    showResidentVoiceStatus(message)
                } else if let sizeIntent, sizeIntent.source == .user {
                    let message = "\(job.name)：按你说的尺寸 \(sizeIntent.summary)（场景内最长边 "
                        + String(format: "%.2f", autoSize.longestEdge) + " m）。"
                    residentPropNotices[job.objectID] = message
                    showResidentVoiceStatus(message)
                }
            } catch {
                // Losing the renderer or cancelling while switching worlds is
                // not an asset failure; only real damage/size/GPU errors are.
                // A switched world/context retires the old one silently.
                guard self.livingWorldContext === context, self.spatialStage.selectedWorldID == context.manifest.worldID else { return }
                switch ResidentPropStartupRecovery.action(
                    rendererReady: spatialStage.canPrepareResidentProp(worldID: context.manifest.worldID),
                    error: error
                ) {
                case let .report(description):
                    // 资产真的坏了（缺失/校验失败/尺寸/GPU）：原因**留住**。
                    // 面板里那一条不能因为"模型没备好"就消失 —— 「已入库」与
                    // 「我的物件里看得见」是同一条事实（库存记录），而"现在能不能摆"
                    // 是另一条事实（资产）。两条都要说，不许互相冒充。
                    residentPropAssetFailures[job.objectID] = description
                    let message = "\(job.name)：\(description)"
                    if residentPropNotices[job.objectID] != message { showResidentVoiceStatus(message); residentPropNotices[job.objectID] = message }
                case .ignoreRendererLoss, .deferUntilRendererReady, .prepare:
                    break
                }
            }
        }
        guard self.livingWorldContext === context, self.spatialStage.selectedWorldID == context.manifest.worldID else { return }
        let service = residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
            guard let self, let context else { return false }
            return self.livingWorldContext === context && self.spatialStage.selectedWorldID == context.manifest.worldID
        })
        // 台账只认**库存记录**：已经进了库存的条目不该继续挂在"等待入库"上
        // （换世界、存档回滚、或在别的路径上补做成功都会走到这里）。
        residentPropInventoryBacklog.prune { context.state.objectStates[$0]?.generatedProp != nil }
        for job in jobs where context.state.objectStates[job.objectID] == nil {
            guard let asset = residentOwnedPropAssets[job.objectID] else { continue }
            do {
                try await prepareResidentPropMutation(.register(asset.prop), context: context)
                try service.commit(.register(asset.prop), expectedLayoutRevision: context.state.layoutRevision, requestID: "claimed." + job.id.uuidString)
                residentPropNotices.removeValue(forKey: job.objectID)
                if residentPropInventoryBacklog.resolve(objectID: job.objectID) {
                    // 之前对用户说过"已领取，入库尚未保存"：补做成功必须**看得见结果**
                    // （任务行/系统消息同时变成"已领取并入库"），旧那句话被这句取代。
                    showResidentVoiceStatus("\(job.name) 已入库。")
                }
            } catch {
                guard self.livingWorldContext === context, self.spatialStage.selectedWorldID == context.manifest.worldID else { return }
                switch ResidentPropStartupRecovery.action(
                    rendererReady: spatialStage.canPrepareResidentProp(worldID: context.manifest.worldID),
                    error: error
                ) {
                case let .report(description):
                    // 「已领取但没进库存」**不许静默、不许冒充成功**：
                    // 1) 记进补做台账（等承托几何就绪那一刻补做，见 `finishResidentPropGridDerivation`）；
                    // 2) 把服务给出的原因原样说给用户。
                    //
                    // 判定一个字都没放宽：`environmentNotReady` 仍然是拒绝写入。这里修的
                    // 是"被拒之后没人补做"——真机 2026-10-01 `2B 白色长剑` 的
                    // `layoutReceipts` 里没有 `claimed.<jobID>`、`state.json` 的
                    // `objectStates` 里也没有它，而任务行/系统消息却按"模型已备好"
                    // 写着"已领取并入库"。
                    let pending = ResidentPropInventoryBacklog.Pending(
                        objectID: job.objectID, name: job.name, reason: description,
                        // 分类只读**服务抛出来的那个错误值**，不放宽任何判定：
                        // `environmentNotReady` 依旧是拒绝写入，只是它"还会好"。
                        waitsForSupportGeometry: (error as? ResidentPropPlacementError) == .environmentNotReady)
                    residentPropInventoryBacklog.record(pending)
                    let message = ResidentPropInventoryBacklog.pendingNotice(pending)
                    if residentPropNotices[job.objectID] != message { showResidentVoiceStatus(message); residentPropNotices[job.objectID] = message }
                case .ignoreRendererLoss, .deferUntilRendererReady, .prepare:
                    break
                }
            }
        }
        // 摆正的说明放在**最后**：它说的是"这件东西的姿态是怎么定的"，
        // 比"入库成功"更值得留在面板上（后者是流程，前者是事实）。
        for (objectID, message) in orientationNotices.sorted(by: { $0.key < $1.key }) {
            guard residentPropNotices[objectID] != message else { continue }
            residentPropNotices[objectID] = message
            showResidentVoiceStatus(message)
        }
        synchronizeResidentPropPresentation()
    }

    /// 承托几何刚就绪：把"已领取但入库被拒"的待办补做一次。
    ///
    /// 这是**既有的**就绪信号（一次网格派生的收尾），不是新轮询、也不是定时器。
    /// 幂等由三层一起保证：
    /// 1. `drain` 只报"还不在库存里"的条目，几何没就绪时一件都不报；
    /// 2. 真正写入的唯一出口仍是 `synchronizeOwnedResidentProps` → 摆放服务的
    ///    `register`（同一份 fail-closed 判定），它按 `objectStates` 跳过已在库的；
    /// 3. 提交用的回执键是既有的 `claimed.<jobID>`，`WorldSimulation.applyPropLayout`
    ///    按回执去重，所以同一件东西写两遍在状态层就不可能发生。
    private func drainResidentPropInventoryBacklog(reason: String) {
        guard !residentPropInventoryBacklog.isEmpty else { return }
        let attempted = residentPropInventoryBacklog.drain(
            isSupportGeometryReady: residentPropGridEditor.isReady,
            isInInventory: { [weak self] objectID in
                self?.livingWorldContext?.state.objectStates[objectID]?.generatedProp != nil
            })
        guard !attempted.isEmpty else { return }
        livingWorldLogger.notice(
            "入库补做：\(reason, privacy: .public) 几何就绪，补做 \(attempted.count, privacy: .public) 件（\(attempted.joined(separator: ","), privacy: .public)）；写入仍走摆放服务的 register。"
        )
        Task { @MainActor [weak self] in await self?.synchronizeOwnedResidentProps() }
    }

    private func prepareResidentPropMutation(_ command: WorldPropLayoutCommand, context: WorldAgentContext) async throws {
        var ids = Set(context.state.objectStates.compactMap { $0.value.isEnabled && $0.value.generatedProp != nil ? $0.key : nil })
        switch command {
        case .place(let id, _): ids.insert(id)
        case .hold(let id, _, _), .adjustGrip(let id, _, _): ids.insert(id)
        case .returnHeld(let id, _):
            if context.state.heldProp?.returnState.isEnabled == true { ids.insert(id) }
        case .undo: if let previous = context.state.layoutUndo?.previous, previous.isEnabled, let prop = previous.generatedProp { ids.insert(prop.objectID) }
        case .register, .withdraw, .enableCapability, .resize: break
        }
        for id in ids.sorted() {
            guard let asset = residentOwnedPropAssets[id] else { throw ResidentPropHostError.assetUnverified }
            if !spatialStage.isResidentPropPrepared(assetID: asset.prop.assetID, modelURL: asset.descriptor.modelURL) {
                _ = try await spatialStage.prepareResidentProp(asset.descriptor)
            }
            guard livingWorldContext === context, spatialStage.selectedWorldID == context.manifest.worldID else { throw CancellationError() }
        }
    }

    private func residentPropDescriptor(_ item: WorldObjectState) -> ResidentPropRenderDescriptor? {
        // 归属校验按**身份**（尺寸可以不同）：用户手动定过尺寸之后，自动基线必然与存档
        // 里那一份不等 —— 逐位相等会让改过尺寸的物件**从舞台上消失**。
        guard let prop = item.generatedProp, let asset = residentOwnedPropAssets[prop.objectID],
              asset.prop.matchesIdentity(of: prop) else { return nil }
        let p = item.transform.position, q = item.transform.rotation
        // 换算只有一份（`ResidentPropRenderDescriptor.residentProp`）：已摆那一件与在手预览
        // 走同一行代码，所以"预览被描述符判据挡掉、已摆的却画得出来"这种不对称不可能存在。
        // 渲染目标高度必须与判据/碰撞盒同源（`effectiveSize`：有工作流权威尺寸时以它为准）。
        //
        // 摆正旋转读 `asset.prop`（本会话交付的那一份）而不是 `item.generatedProp`：
        // 旧存档里没有这个字段，而"这件网格是躺着的"是本会话量出来的事实 ——
        // 两者仍是**同一个出口**（`WorldGeneratedProp.orientationRotation`），不是第二份朝向。
        return .residentProp(objectID: prop.objectID, worldID: asset.descriptor.worldID, assetID: prop.assetID,
                             modelURL: asset.descriptor.modelURL, targetHeightMeters: prop.effectiveSize.y,
                             position: SIMD3(p.x, p.y, p.z), rotation: SIMD4(q.x, q.y, q.z, q.w),
                             orientation: asset.prop.orientationRotation)
    }

    private func residentPropEditorSnapshot(context: WorldAgentContext) -> ResidentPropEditorSnapshot {
        let service = residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
            guard let self, let context else { return false }
            return self.livingWorldContext === context && self.spatialStage.selectedWorldID == context.manifest.worldID
        })
        let objects = context.state.objectStates.values.filter { $0.generatedProp != nil }
            .sorted { $0.generatedProp!.objectID < $1.generatedProp!.objectID }
        // 摆放面现在是格子派生出来的**承托层**，按高度归并（真实房间有 3,000+ 格，
        // 全列给 UI 没意义）。最低那层叫"地面"，其余按高度命名。
        let surfaces = service.listedSupportLayers().enumerated().map { index, layer in
            ResidentPropEditorSurface(id: layer.id,
                  name: index == 0 ? "地面" : String(format: "台面 %.2f m", layer.supportHeight),
                  position: layer.center, cellCount: layer.cellCount)
        }
        let readiness = ResidentPropSupportReadiness.resolve(
            hasSurfaces: !surfaces.isEmpty,
            isDeriving: residentPropGridDerivation != nil
        )
        return .init(worldID: context.manifest.worldID, revision: context.state.layoutRevision,
              objects: objects,
              // 未摆出物件的初始落点候选（**纯顺序**，判定仍由 `preview` 给）：
              // 同承托高度上格子多的层（平整的桌面/台面）在前，同层内离出生点近的在前。
              surfaces: ResidentPropInitialPlacement.fillingAnchors(
                  surfaces, grid: residentPropGridEditor.grid, spawn: context.manifest.spawn.position),
              canUndo: context.state.layoutUndo != nil, heldProp: context.state.heldProp,
              holdUnavailableReasons: Dictionary(uniqueKeysWithValues: objects.compactMap { item in
                  guard let id = item.generatedProp?.objectID else { return nil }
                  // 「现在为什么不能拿/摆」有**两个**都成立的事实，谁都不能冒充谁：
                  // - 库存里有它（所以它出现在「我的物件」列表里，绝不消失）；
                  // - 资产（模型文件）真的失败了 ⇒ 现在也确实摆不出来，原因如实说。
                  // 这里并入的是**已有的**显示通道（面板选中该行时显示这一行），
                  // 不新增字段、不改判定的归属：资产那条判定仍只在
                  // `residentOwnedPropAssets`/`residentPropAssetFailures`。
                  if let failure = residentPropAssetFailures[id] {
                      return (id, ResidentPropInventoryBacklog.assetNotice(failure))
                  }
                  guard let reason = service.holdEligibility(objectID: id) else { return nil }
                  return (id, reason)
              }),
              // 面板要能区分"格子还在生成"与"这个空间永远拿不到几何"：前者的措辞要和
              // 点击落地那条一致（见 `residentPropGridCommit`），后者不能说"请稍候"。
              //
              // **判据必须同时看承托面与"有没有派生在跑"**（见 `ResidentPropSupportReadiness`）：
              // 只问 `grid != nil` 的话，派生失败留下的空网格会被当成"就绪"，于是面板
              // 永远说"还在生成"、那一行永远点不动（2026-09-28 真机缺陷）。
              supportGeometryUnavailable: readiness.supportGeometryUnavailable,
              // 「靠墙」读的是派生出来的竖直面与**判据说可以**的那批格子（与地板摆放同一个出口）。
              wallFaces: residentPropGridEditor.wallPatches.count,
              wallPlaceableCells: residentPropGridEditor.wallPlaceableCellCount)
    }

    /// 把当前快照推给面板。返回**是否真的推成功** —— 世界已切换/窗口不在时不算推成功，
    /// 调用方据此决定要不要把"这个相位已经推过"记下来（见 `publishResidentPropGrid`）。
    @discardableResult
    private func synchronizeResidentPropPresentation() -> Bool {
        guard let context = livingWorldContext, spatialStage.selectedWorldID == context.manifest.worldID,
              context.manifest.worldID == WishMachineScene.worldID else { return false }
        spatialStage.residentPropOutputs = context.state.objectStates.values.filter(\.isEnabled).compactMap(residentPropDescriptor)
        spatialStage.residentHeldProp = residentHeldPropDescriptor(context: context)
        // 展示台的视觉几何从 manifest 的碰撞体反推：几何只有一个来源（layout.json → world.json），
        // 视觉与碰撞不会各自漂移。世界没声明它就不画，碰撞也一并没有。
        if let table = ResidentPropPlacementConfiguration.tableTransform(in: context.manifest) {
            spatialStage.residentPropDisplayStand = .init(worldID: context.manifest.worldID,
                objectID: "resident.display_table", position: table.position, size: table.size)
        } else {
            spatialStage.residentPropDisplayStand = nil
        }
        guard let stageWindowController else { return false }
        stageWindowController.updateResidentPropEditor(residentPropEditorSnapshot(context: context))
        // 房间里现在有什么变了 ⇒ 那一批"这一格能不能放"的答案全部作废。
        // 判定依赖"现在房间里有什么"，复用旧答案会让红/绿与落地判定分叉 ——
        // 那正是这次要修的缺陷，绝不能靠缓存重新引入。
        residentPropGridEditor.invalidateVerdicts()
        for (id, status) in spatialStage.residentPropRenderStatuses {
            if case .failed(_, let message) = status, residentPropNotices[id] != message {
                showResidentVoiceStatus("物件显示失败，已保存的摆放和所有权仍保留：\(message)")
                residentPropNotices[id] = message
            }
        }
        synchronizeWishMachinePresentation()
        return true
    }

    private func residentHeldPropDescriptor(context: WorldAgentContext) -> ResidentHeldPropDescriptor? {
        guard let held = context.state.heldProp,
              avatarRuntime.snapshot.avatar?.id == held.avatarAssetID,
              let item = context.state.objectStates[held.objectID], let prop = item.generatedProp,
              let calibration = item.gripCalibration,
              let asset = residentOwnedPropAssets[held.objectID], asset.prop.matchesIdentity(of: prop) else { return nil }
        return .init(objectID: prop.objectID, worldID: context.manifest.worldID, assetID: prop.assetID,
                     modelURL: asset.descriptor.modelURL, targetHeightMeters: prop.effectiveSize.y,
                     // 挂在哪个挂点是**持久状态自己说的话**（`WorldHeldProp.hand` / 标定里的 `hand`），
                     // 不是这里再写死一个右手。
                     attachmentPoint: held.attachmentPoint, calibration: calibration,
                     // 手持与已摆共用同一份资产级摆正旋转（同一个出口）。
                     orientation: asset.prop.orientationRotation)
    }

    private func safelyReturnHeldPropIfAvatarChanged(_ snapshot: StageAvatarRuntimeSnapshot) {
        guard residentAvatarObservationInitialized else {
            residentAvatarObservationInitialized = true
            return
        }
        guard let held = livingWorldContext?.state.heldProp, held.avatarAssetID != snapshot.avatar?.id else { return }
        safelyReturnHeldProp(reason: "换角色")
    }

    private func safelyReturnHeldProp(reason: String) {
        guard let context = livingWorldContext, let held = context.state.heldProp else { return }
        do {
            try context.commitPropLayout(.returnHeld(objectID: held.objectID, avatarAssetID: held.avatarAssetID),
                expectedLayoutRevision: context.state.layoutRevision,
                requestID: "system.return.\(reason).\(context.state.layoutRevision)") { _ in }
            synchronizeResidentPropPresentation()
        } catch {
            showResidentVoiceStatus("\(reason)时物件自动放回失败：\(error.localizedDescription)")
        }
    }

    private func configureResidentPropEditor(_ controller: StageWindowController) {
        controller.configureResidentPropEditor(preview: { [weak self] id, placement in
            guard let self, let context = self.livingWorldContext,
                  let editorID = self.residentPropEditingID,
                  self.residentPropEditingWorldID == context.manifest.worldID,
                  self.spatialStage.selectedWorldID == context.manifest.worldID else { throw ResidentPropPlacementError.inactiveContext }
            try await self.prepareResidentPropMutation(.place(objectID: id, placement: placement), context: context)
            return try self.residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
                guard let self, let context else { return false }
                return self.isResidentPropEditorCurrent(context: context, editorID: editorID)
            }).preview(objectID: id, placement: placement)
        }, commit: { [weak self] command, revision, requestID in
            guard let self, let context = self.livingWorldContext,
                  let editorID = self.residentPropEditingID,
                  self.residentPropEditingWorldID == context.manifest.worldID,
                  self.spatialStage.selectedWorldID == context.manifest.worldID else { throw ResidentPropPlacementError.inactiveContext }
            try await self.prepareResidentPropMutation(command, context: context)
            let service = self.residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
                guard let self, let context else { return false }
                return self.isResidentPropEditorCurrent(context: context, editorID: editorID)
            })
            try service.commit(command, expectedLayoutRevision: revision, requestID: requestID)
            self.synchronizeResidentPropPresentation()
            return self.residentPropEditorSnapshot(context: context)
        }, hold: { [weak self] id, point, revision, requestID in
            guard let self, let context = self.livingWorldContext,
                  let editorID = self.residentPropEditingID,
                  self.isResidentPropEditorCurrent(context: context, editorID: editorID) else { throw ResidentPropPlacementError.inactiveContext }
            let service = self.residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
                guard let self, let context else { return false }
                return self.isResidentPropEditorCurrent(context: context, editorID: editorID)
            })
            // 拿起来 / 就地换挂点：同一个入口（面板上"手/背后/腰间"那一行读的就是它）。
            let command = try service.holdCommand(objectID: id, point: point)
            try await self.prepareResidentPropMutation(command, context: context)
            try service.commit(command, expectedLayoutRevision: revision, requestID: requestID)
            self.synchronizeResidentPropPresentation()
            return self.residentPropEditorSnapshot(context: context)
        }, adjustHeldGrip: { [weak self] id, offset, rotation, revision, requestID in
            guard let self, let context = self.livingWorldContext,
                  let editorID = self.residentPropEditingID,
                  self.isResidentPropEditorCurrent(context: context, editorID: editorID) else { throw ResidentPropPlacementError.inactiveContext }
            let service = self.residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
                guard let self, let context else { return false }
                return self.isResidentPropEditorCurrent(context: context, editorID: editorID)
            })
            let command = try service.adjustGripCommand(objectID: id, localOffset: offset, localRotation: rotation)
            try service.commit(command, expectedLayoutRevision: revision, requestID: requestID)
            self.synchronizeResidentPropPresentation()
            return self.residentPropEditorSnapshot(context: context)
        }, returnHeld: { [weak self] id, revision, requestID in
            guard let self, let context = self.livingWorldContext,
                  let editorID = self.residentPropEditingID,
                  self.isResidentPropEditorCurrent(context: context, editorID: editorID) else { throw ResidentPropPlacementError.inactiveContext }
            let service = self.residentPropPlacementService(context: context, isCurrent: { [weak self, weak context] in
                guard let self, let context else { return false }
                return self.isResidentPropEditorCurrent(context: context, editorID: editorID)
            })
            let command = try service.returnHeldCommand(objectID: id)
            try await self.prepareResidentPropMutation(command, context: context)
            try service.commit(command, expectedLayoutRevision: revision, requestID: requestID)
            self.synchronizeResidentPropPresentation()
            return self.residentPropEditorSnapshot(context: context)
        }, refreshSnapshot: { [weak self] in
            // 点一行时按**现状**再要一份：格子派生是异步的，而面板手里的快照是推送来的。
            //
            // 装修已经结束或世界换了就答 nil —— 那时这次点击本来就该作废。但**答 nil 之前
            // 先自救一次**：面板开着而宿主的装修会话没接上（进入分支被守卫静默挡下、或者
            // 上一次会话留下的身份已经过期）时，干等下去只会让那一行永远停在"还没好"。
            // 重接本身走的还是那条既有进入分支，守卫（世界必须一致）一个字都没放宽。
            guard let self, let context = self.livingWorldContext else { return nil }
            if ResidentPropDecorationSessionRearm.shouldRearm(
                hasSession: self.residentPropEditingID != nil,
                sessionWorldID: self.residentPropEditingWorldID,
                worldID: context.manifest.worldID
            ) {
                // 会话属于**别的**世界时，进入分支自己的守卫会把它挡下（`residentPropEditingWorldID`
                // 非 nil）。所以先按既有退出分支把它收干净，再重接 —— 两步都是既有路径，
                // "世界必须一致"这条 fail-closed 守卫一个字都没放宽。
                if self.residentPropEditingWorldID != nil { self.setResidentPropEditing(false) }
                self.setResidentPropEditing(true)
            }
            guard let editorID = self.residentPropEditingID,
                  self.isResidentPropEditorCurrent(context: context, editorID: editorID) else { return nil }
            return self.residentPropEditorSnapshot(context: context)
        }, onPreviewChanged: { [weak self] preview in
            guard let self else { return }
            self.spatialStage.residentPropPreview = preview.flatMap(self.residentPropDescriptor)
        }, onEditingChanged: { [weak self] editing in self?.setResidentPropEditing(editing) })
    }

    private func isResidentPropEditorCurrent(context: WorldAgentContext, editorID: UUID) -> Bool {
        livingWorldContext === context && residentPropEditingWorldID == context.manifest.worldID
            && residentPropEditingID == editorID && spatialStage.selectedWorldID == context.manifest.worldID
    }

    /// 开启建造模式并派生格子。
    ///
    /// 拿不到网格几何时**停用**而不是放行：`context.propSupportQuerying` 为 nil 意味着
    /// 碰撞世界给不出三角形，派生器会得到空网格、评估器会给 `.noSupport` —— 两道都是
    /// fail-closed。与其画一张空网格，不如明确不进入格子系统。
    ///
    /// 日志（`.notice`）是这套状态机的常驻诊断，不是临时脚手架：真机 2026-09-28 的
    /// "永远说还在生成"之所以查了很久，正是因为**这条路每一步都是静默的** ——
    /// 守卫静默 return、任务静默被停用、派生静默返回空网格。下面每条都能独立回答
    /// "这一步有没有发生、结果是什么"。
    private func activateResidentPropGrid(context: WorldAgentContext) {
        residentPropGridEditor.onGridChanged = { [weak self] in self?.publishResidentPropGrid() }
        // 格子的黄/红 = **与落地完全相同的那条判定**（摆放服务）。这一条接线是这次修复的
        // 核心：着色那条路过去跑的是 `PropPlacementEvaluator`（完全不知道路点/通道），
        // 与落地那条路分叉，于是"格子说可放、一点却被拒绝"（真机 273/273）。
        residentPropGridEditor.verdictForPlacement = { [weak self] objectID, footprint, height, position, yaw in
            self?.residentPropVerdict(objectID: objectID, footprint: footprint, height: height,
                                      position: position, yaw: yaw)
        }
        // 「居民还走不走得到活动锚点」这条判据的**可站带**：世界路点的高度范围。
        // 居民只在这些高度上站立/行走，桌面与屋顶都在带外。必须在任何一次摆放判定之前
        // 写进模型，否则移动图建不出来 ⇒ 服务 fail-closed 拒绝摆放。
        residentPropGridEditor.setRouteBand(fromWaypoints: context.manifest.waypoints)
        let collision = context.propSupportQuerying
        let bounds = residentPropGridBounds(context: context)
        guard let collision, let bounds else {
            livingWorldLogger.notice(
                "建造模式：当前空间拿不到摆放几何或导航范围，已停用格子派生。碰撞三角形=\(collision != nil, privacy: .public)，导航范围=\(bounds != nil, privacy: .public)"
            )
            residentPropGridDerivation = nil
            residentPropGridEditor.deactivate()
            publishResidentPropGrid()
            return
        }
        // 派生用的世界把家具体积的**顶面**也当作承托面（合成顶面三角形 + y 受限的
        // `groundHeight`），否则桌面/柜顶永远不成为承托层（§12 回归 2）。
        // 居民落地用的世界不受影响 —— 那个 `groundHeight` 刻意只问网格，否则居民会站到桌子上。
        let derivation = PropSupportDerivationWorld(
            base: collision,
            topVolumes: context.manifest.collisionVolumes.filter(\.isBlocking)
        )
        // 派生放后台：见 `activate` 的说明。开启状态立刻生效（格子会在派生完成后出现）。
        let seed = context.manifest.spawn.position
        let key = context.manifest.worldID
        residentPropGridPushedHover = nil
        // 令牌与这次任务同生共死：面板的"还会不会好"只看令牌在不在（见
        // `ResidentPropSupportReadiness`）。任务**结束时**（无论成功、失败还是被停用）
        // 令牌必须失效，否则一次失败的派生会让面板永远说"格子还在生成"。
        let derivationToken = UUID()
        residentPropGridDerivation = derivationToken
        livingWorldLogger.notice(
            "建造模式：请求派生格子 world=\(key, privacy: .public) bounds=[\(bounds.minimumX, privacy: .public),\(bounds.maximumX, privacy: .public)]×[\(bounds.minimumZ, privacy: .public),\(bounds.maximumZ, privacy: .public)] seed=(\(seed.x, privacy: .public),\(seed.y, privacy: .public),\(seed.z, privacy: .public))"
        )
        Task { [weak self] in
            await self?.residentPropGridEditor.activate(
                collision: derivation, seed: seed, bounds: bounds, key: key
            )
            self?.finishResidentPropGridDerivation(derivationToken)
        }
        publishResidentPropGrid()
    }

    /// 一次格子派生的收尾：令牌失效 + 按**现状**重推面板快照。
    ///
    /// 分开成一步是为了让"请求过"与"任务在跑"始终一致 —— 任务一结束（哪怕它什么都没派
    /// 生出来），面板看到的就必须是"就绪"或"拿不到"，而不是"还在生成"。
    private func finishResidentPropGridDerivation(_ token: UUID) {
        guard residentPropGridDerivation == token else { return }
        residentPropGridDerivation = nil
        let layers = residentPropGridEditor.grid?.layers.count ?? -1
        livingWorldLogger.notice(
            "建造模式：格子派生结束，网格层=\(layers, privacy: .public) 可绘制列=\(self.residentPropGridEditor.renderCells.count, privacy: .public)"
        )
        publishResidentPropGrid()
        // 这里就是"承托几何就绪"那条**既有回调**（一次派生的收尾，命中缓存也走这里）：
        // 领取时被 `environmentNotReady` 拒掉的入库待办，此刻补做（幂等，见该函数）。
        drainResidentPropInventoryBacklog(reason: "格子派生收尾")
    }

    /// 把格子的网格与着色转发给渲染层。模型每次变更后都会调用（见 `onGridChanged`）。
    private func publishResidentPropGrid() {
        spatialStage.isResidentPropBuildModeActive = residentPropGridEditor.isBuildModeActive
        spatialStage.residentPropGridCells = residentPropGridEditor.renderCells
        spatialStage.residentPropGridStates = residentPropGridEditor.cellStates
        spatialStage.residentPropGridSpacing = residentPropGridEditor.isReady ? residentPropGridEditor.spacing : 0
        // 「这里为什么不能放」跟着光标走：原因早就算出来了（`hoveredBlockReason`），
        // 但原来只写在面板下方那行 `notice` 里，而用户的视线在光标/物件上。原样转发给
        // 渲染层，由场景里的那枚小胶囊显示（文案仍由 `PropSupportBlockReason.errorDescription`
        // 投影，这里不拼字符串）。
        spatialStage.residentPropBlockReason = residentPropGridEditor.hoveredBlockReason

        // 承托几何的就绪是**异步**的（真实舱体一次派生 0.5 s，-Onone 6.6 s），而面板的
        // `surfaces` 是快照字段：就绪状态一变就必须重新投影一次快照，否则面板手里一直是
        // "还没派生完"的那一份 —— 格子已经画出来了，点一行却会被 `select()` 的承托守卫
        // 静默挡下（2026-09-28 修的缺陷）。
        //
        // **只在状态变化时推**：本函数每次鼠标移动都会被调用，而一次快照要归并 3,000+ 格。
        //
        // **只有真的推成功才记住这个相位**：世界刚切换、窗口还没建好时
        // `synchronizeResidentPropPresentation()` 会拒绝推送；如果把"相位"记成已推，之后
        // 相位不再变化，面板就永远收不到那一份 —— 于是格子其实早就好了，面板却一直说
        // "还在生成"，关掉再打开也一样（第二个机制，2026-09-28 真机）。推失败时保持
        // 未记录，下一次本函数（鼠标一动就会来）会重试；守卫是 O(1)，不会因此变慢。
        let phase = residentPropSupportPhase
        if publishedResidentPropSupportPhase != phase {
            let pushed = synchronizeResidentPropPresentation()
            if pushed { publishedResidentPropSupportPhase = phase }
            // 相位只报一次：推失败时本函数会被鼠标移动反复调到，不能把日志刷满。
            if pushed || loggedResidentPropSupportPhase != phase {
                loggedResidentPropSupportPhase = phase
                livingWorldLogger.notice(
                    "建造模式：承托几何相位 网格就绪=\(phase.isGridReady, privacy: .public) 派生在跑=\(phase.isDeriving, privacy: .public) 重推面板快照=\(pushed, privacy: .public)"
                )
            }
        }

        // 悬停命中格子后，把预览挪到**吸附后的格心**（含当前 footprint 朝向）。
        // 预览走既有的摆放服务，所以"这里能不能放"由 `PropPlacementEvaluator` 决定；
        // 放不下时编辑器会显示红格与原因，而不是静默不动。
        //
        // **只在吸附目标或朝向变化时才推**：`onGridChanged` 每次鼠标移动都会触发，
        // 而一次预览预检要遍历所有已放物件跑评估器（实测 30 件时约 30 ms）。鼠标在同一个
        // 格子里移动不该重复付这个代价 —— 否则 60 Hz 的移动事件能把主线程打满。
        guard let snapped = residentPropGridEditor.snappedPlacement else {
            // **场景输入链[9b]**（只观测）：从"有悬停目标"变成"没有"时报一条 ——
            // 说明预览停在上一个格心不动了。限流：只在真的从非 nil 掉到 nil 时报，
            // 用既有的 `residentPropGridPushedHover` 当比较键，不引入新状态。
            if residentPropGridPushedHover != nil {
                residentPropGridPushedHover = nil
                livingWorldLogger.notice(
                    "场景输入链[9b] 推给预览：snappedPlacement=nil（悬停没有命中任何格子）→ 本次不推 moveResidentPropGridPointer"
                )
            }
            return
        }
        let target = WorldVector3(x: snapped.position.x, y: snapped.position.y, z: snapped.position.z)
        let hover = ResidentPropGridHoverKey(
            x: target.x, y: target.y, z: target.z, yaw: snapped.yaw
        )
        guard hover != residentPropGridPushedHover else { return }
        residentPropGridPushedHover = hover
        let layerName = residentPropGridEditor.hoveredLayerName ?? "grid"
        // **场景输入链[9]**（只观测）：限流就是上面那条 `hover != residentPropGridPushedHover`
        // —— 只有吸附格心或朝向真的变化时才报一条，鼠标在同一格内移动不会刷屏。
        livingWorldLogger.notice(
            "场景输入链[9] 推给预览：moveResidentPropGridPointer 落点=(\(target.x, privacy: .public), \(target.y, privacy: .public), \(target.z, privacy: .public)) layer=\(layerName, privacy: .public) yaw=\(snapped.yaw, privacy: .public)（同格心+同朝向不重复推）"
        )
        Task { [weak self] in
            await self?.stageWindowController?.moveResidentPropGridPointer(
                to: target, layerName: layerName, yaw: snapped.yaw)
        }
    }

    /// 光标 → 格子悬停。
    ///
    /// 悬停只负责算出**吸附后的格心**，然后交给编辑器去跑预检；真正的落地由编辑器的
    /// `confirm()` 走摆放服务完成，那一步已经是「格子 + footprint」口径（工作项 9）。
    private func residentPropGridHover(normalized: SIMD2<Float>) {
        updateResidentPropGridHover(normalized: normalized)
    }

    /// 「居民还走不走得到活动锚点」这条判据的全部输入（**收窄后**的唯一一条路点约束）。
    ///
    /// 唯一一份推导在格子模型里（`ResidentPropGridEditorModel.routeConstraint(activities:waypoints:)`）：
    /// 移动图按网格缓存、锚点取 `WorldActivityAnchor.entryWaypointID`。这里只负责
    /// 把世界的活动与路点喂进去。
    ///
    /// 拿不到任何一项就返回 nil ⇒ 服务拒绝摆放（fail-closed），而不是跳过判据。
    private func residentPropRouteConstraint() -> ResidentPropPlacementSupport.RouteConstraint? {
        guard let context = livingWorldContext else { return nil }
        return residentPropGridEditor.routeConstraint(
            activities: context.manifest.activities,
            waypoints: context.manifest.waypoints
        )
    }

    /// 格子的黄/红 = **与落地完全相同的那条判定**（`ResidentPropPlacementService`）。
    ///
    /// 这是这次修复的核心：真机 2026-09-29 的缺陷是"格子说可放、一点却被拒绝" ——
    /// 着色走的是 `PropPlacementEvaluator`（不知道路点），落地走的是服务校验（还要求
    /// 居民走得到锚点）。273 个"可放=true"的去重格被服务拒绝 273/273。
    ///
    /// 现在把服务的判定包成同步闭包交给格子模型：服务接受 ⇒ 黄；服务拒绝 ⇒ 红，
    /// 且光标旁那枚标签显示的**就是服务给出的原因**。
    private func residentPropVerdict(objectID: String, footprint: SIMD2<Float>, height: Float,
                                     position: WorldVector3, yaw: Float) -> PropSupportBlockReason? {
        guard let context = livingWorldContext else { return nil }
        let service = residentPropPlacementService(context: context, isCurrent: { [weak self] in
            self?.livingWorldContext === context && self?.residentPropEditingWorldID != nil
        })
        let placement = WorldPropPlacement(
            surfaceID: residentPropGridEditor.hoveredLayerName ?? "grid",
            position: position,
            yaw: yaw
        )
        do {
            // **同一个函数**：落地走 `preview` / `commit`，格子着色走这里 ——
            // 两条路的差别只有"读不读返回值"。
            _ = try service.previewState(objectID: objectID, placement: placement)
            return nil
        } catch {
            // 原因必须**可读**，而且要与落地时面板上那句话同源：几何类原因直接投影，
            // 通道类原因投影成 `.blockedRoute`（文案在 `PropSupportBlockReason` 里）。
            if let reason = error as? PropSupportBlockReason { return reason }
            if case ResidentPropPlacementError.blockedRoute(let id) = error { return .blockedRoute(id) }
            if case ResidentPropPlacementError.blockedBySupport(let reason) = error { return reason }
            if case ResidentPropPlacementError.collision = error { return .blockedByMesh }
            return .noSupport
        }
    }

    /// 悬停与落地**共用**的拾取步骤。
    ///
    /// 两处必须用完全一样的输入（投影、footprint 尺寸/高度、阻挡体积、已放物件），
    /// 否则"红绿格看到的位置"和"真正落地的位置"会拿两套碰撞输入各算一遍。
    /// 返回 false 表示世界上下文或建造模式投影还没就绪（网格正在派生）。
    @discardableResult
    private func updateResidentPropGridHover(normalized: SIMD2<Float>) -> Bool {
        guard let context = livingWorldContext,
              let projection = spatialStage.residentPropBuildModeProjection else {
            noteResidentPropGridHoverGuardFailure(normalized: normalized)
            return false
        }
        let footprint = stageWindowController?.residentPropFootprint
        // 没有在携带任何物件时**不判定**（也就没有一格会变绿）：格子的黄/红由摆放服务
        // 回答，而服务是按 objectID 判定的，没有物件就没有那条判定。
        guard let footprint, let objectID = stageWindowController?.residentPropSelectedObjectID else {
            residentPropGridEditor.clearHover()
            noteResidentPropGridHoverResult(normalized: normalized)
            updateResidentPropHoverTarget(normalized: normalized,
                                          projection: projection.inverseViewProjection, context: context)
            return true
        }
        residentPropGridEditor.updateHover(
            normalizedCursor: normalized,
            inverseViewProjection: projection.inverseViewProjection,
            footprintSize: footprint.size,
            height: footprint.height,
            objectID: objectID,
            blockingVolumes: context.manifest.collisionVolumes.filter(\.isBlocking),
            placedProps: context.state.objectStates.values.compactMap(\.generatedCollisionVolume)
        )
        noteResidentPropGridHoverResult(normalized: normalized)
        updateResidentPropHoverTarget(normalized: normalized, projection: projection.inverseViewProjection,
                                      context: context)
        return true
    }

    /// **场景输入链[7]**：悬停 guard 失败的**哪一个条件**（只观测，不参与判据）。
    ///
    /// 限流：按失败原因去重（同一原因只报一条），坐标取"该原因下的第一条"那一次。
    private func noteResidentPropGridHoverGuardFailure(normalized: SIMD2<Float>) {
        let coordinate = String(format: "(%.3f, %.3f)", normalized.x, normalized.y)
        let reason: String
        let detail: String
        if livingWorldContext == nil {
            reason = "livingWorldContext=nil"
            detail = "世界上下文还没接上（装修会话/世界快照没就绪）"
        } else {
            reason = "residentPropBuildModeProjection=nil"
            detail = "投影不可用：世界可见=\(spatialStage.isWorldVisible) 建造模式=\(spatialStage.isResidentPropBuildModeActive) 格距=\(spatialStage.residentPropGridSpacing) 有投影矩阵=\(spatialStage.residentPropViewProjection != nil)"
        }
        guard loggedResidentPropGridHoverSignature != reason else { return }
        loggedResidentPropGridHoverSignature = reason
        livingWorldLogger.notice(
            "场景输入链[7] App 悬停 guard 失败：\(reason, privacy: .public)（\(detail, privacy: .public)）→ 格子拾取没有跑 归一化=\(coordinate, privacy: .public)"
        )
    }

    /// **场景输入链[8]**：`updateHover` 跑完之后的**结果**（只观测）。
    ///
    /// 限流：按"命中格心 + 朝向 + 层 + 可放性"（或"未命中"）去重 —— 鼠标在同一格内移动
    /// 不重复刷屏，跨格/旋转/可放性变化时各报一条。坐标取"该签名下的第一条"那一次。
    private func noteResidentPropGridHoverResult(normalized: SIMD2<Float>) {
        let coordinate = String(format: "(%.3f, %.3f)", normalized.x, normalized.y)
        guard let snapped = residentPropGridEditor.snappedPlacement else {
            guard loggedResidentPropGridHoverSignature != "miss" else { return }
            loggedResidentPropGridHoverSignature = "miss"
            livingWorldLogger.notice(
                "场景输入链[8] App 悬停未命中：updateHover 已跑但 snappedPlacement=nil（光标没落在任何格子上，网格可能还没派生完）归一化=\(coordinate, privacy: .public)"
            )
            return
        }
        let layer = residentPropGridEditor.hoveredLayerName ?? "nil"
        let blockReason = residentPropGridEditor.hoveredBlockReason.flatMap { $0.errorDescription } ?? "无"
        let signature = "hit|\(snapped.position.x)|\(snapped.position.y)|\(snapped.position.z)|\(snapped.yaw)|\(layer)|\(residentPropGridEditor.canPlaceAtHover)"
        guard loggedResidentPropGridHoverSignature != signature else { return }
        loggedResidentPropGridHoverSignature = signature
        livingWorldLogger.notice(
            "场景输入链[8] App 悬停命中：updateHover 已跑 归一化=\(coordinate, privacy: .public) 吸附格心=(\(snapped.position.x, privacy: .public), \(snapped.position.y, privacy: .public), \(snapped.position.z, privacy: .public)) layer=\(layer, privacy: .public) yaw=\(snapped.yaw, privacy: .public) 可放=\(self.residentPropGridEditor.canPlaceAtHover, privacy: .public) 阻挡原因=\(blockReason, privacy: .public)"
        )
    }

    /// 光标下那件**已摆出**的物件 → 它的 footprint 格子发光（The Sims 的 white glow）。
    ///
    /// 发光写在格子管线的 `cellStates` 里，于是它和 footprint 的判定着色走**同一条**绘制路径，
    /// 并且自动受 `PropSupportGridPresentation.focus` 的焦点裁剪约束（裁剪的锚点就是
    /// `states` 的键）—— 不会绕开裁剪去铺满地面。
    ///
    /// 携带时**不发光**：手上那件的 footprint 已经由摆放预览着色，两套高亮会打架。
    private func updateResidentPropHoverTarget(
        normalized: SIMD2<Float>,
        projection: simd_float4x4,
        context: WorldAgentContext
    ) {
        guard stageWindowController?.isResidentPropCarrying != true else {
            residentPropGridEditor.clearHoveredProp()
            return
        }
        guard let objectID = residentPropHitObjectID(normalized: normalized, inverseViewProjection: projection,
                                                     context: context),
              let volume = context.state.objectStates[objectID]?.generatedCollisionVolume else {
            residentPropGridEditor.clearHoveredProp()
            return
        }
        residentPropGridEditor.setHoveredProp(objectID: objectID, volume: volume)
    }

    /// 光标打在**哪一件已摆物件**上。唯一的命中判据是 `ResidentPropHitTest`
    /// （射线 × `generatedCollisionVolume` 那个 yaw 包围盒 = 摆放校验用的同一个盒子）。
    private func residentPropHitObjectID(
        normalized: SIMD2<Float>,
        inverseViewProjection: simd_float4x4,
        context: WorldAgentContext
    ) -> String? {
        ResidentPropHitTest.hit(
            normalized: normalized,
            inverseViewProjection: inverseViewProjection,
            targets: context.state.objectStates.values.compactMap { item in
                guard let volume = item.generatedCollisionVolume else { return nil }
                let q = volume.rotation
                let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
                return .init(
                    objectID: volume.id,
                    center: SIMD3(volume.center.x, volume.center.y, volume.center.z),
                    halfExtents: SIMD3(volume.halfExtents.x, volume.halfExtents.y, volume.halfExtents.z),
                    yaw: yaw
                )
            }
        )
    }

    /// 建造模式：**空手**点了一下 → 命中已摆物件就拿起它。
    ///
    /// 分流规则只有一份（`ResidentPropSceneClick.resolve`，与控制器共用同一个纯类型）：
    /// 编辑器没打开 / 没命中 / 双击 → 什么都不做；命中 → 走**和面板行完全相同**的
    /// `select(objectID:)`，于是"从场景拿起"和"从面板拿起"不可能有两套行为。
    private func residentPropScenePick(normalized: SIMD2<Float>, clickCount: Int) {
        // 编辑器没打开时点场景物件**不产生任何效果**（防误触）——控制器那边也已经用
        // `propEditor.isOpen` 挡了一层，这里是宿主自己的守卫。
        guard residentPropEditingID != nil, let context = livingWorldContext,
              let projection = spatialStage.residentPropBuildModeProjection else { return }
        let hit = residentPropHitObjectID(normalized: normalized,
                                          inverseViewProjection: projection.inverseViewProjection,
                                          context: context)
        let action = ResidentPropSceneClick.resolve(
            isEditorOpen: residentPropEditingID != nil,
            isBuildModeActive: spatialStage.isResidentPropBuildModeActive,
            // 控制器只在空手时调到这条（手上有物件走落地通路），所以这里恒为 false。
            isCarrying: stageWindowController?.isResidentPropCarrying == true,
            clickCount: clickCount,
            hitObjectID: hit
        )
        guard case .pickUp(let objectID) = action else { return }
        // 这一记拾取是"场景拾起"：告诉控制器双击的第二下该撤回它（而不是丢在光标处）。
        stageWindowController?.noteResidentPropScenePickUp()
        Task { [weak self] in
            await self?.stageWindowController?.selectResidentPropFromScene(objectID: objectID)
        }
    }

    /// 建造模式：点一下 → 在吸附后的格心上落地。
    ///
    /// **刻意不走 `publishResidentPropGrid` 的防抖推送**：那条路径在"鼠标还在同一格"时会
    /// `guard hover != residentPropGridPushedHover else { return }` 直接跳过，而且它是异步
    /// Task —— 点击要么落在上一个格心，要么什么都不发生。点击必须自己按顺序 await
    /// 「挪 + 确认」（见 `moveAndConfirmResidentPropGridPointer`）。
    private func residentPropGridCommit(normalized: SIMD2<Float>) {
        guard updateResidentPropGridHover(normalized: normalized) else {
            // 网格派生在 -Onone 下要 6.6 s。这段窗口里的点击必须给一句人话，
            // 否则用户只会觉得"点了没反应"。
            showResidentVoiceStatus("格子还在生成，请稍候")
            return
        }
        // 红格不提交。原因文案（`PropSupportBlockReason.errorDescription`，已是中文）
        // 就在编辑器面板的 notice 上，这里不覆盖它。
        guard residentPropGridEditor.canPlaceAtHover,
              let snapped = residentPropGridEditor.snappedPlacement,
              let layerName = residentPropGridEditor.hoveredLayerName else { return }
        let yaw = residentPropGridEditor.footprintYaw
        let target = WorldVector3(x: snapped.position.x, y: snapped.position.y, z: snapped.position.z)
        // 先记下这次推送：下面的「挪 + 确认」自己会把预览放到位，防抖路径不该再推一遍
        // （那会和确认抢时序，也白白多跑一次评估器）。
        residentPropGridPushedHover = ResidentPropGridHoverKey(
            x: target.x, y: target.y, z: target.z, yaw: yaw
        )
        Task { [weak self] in
            await self?.stageWindowController?.moveAndConfirmResidentPropGridPointer(
                to: target, layerName: layerName, yaw: yaw)
        }
    }

    /// 格子覆盖的范围：以导航图的 waypoint 包络为准 —— 那**就是**可玩区域，而且已经在
    /// `world.json` 里随包分发，不需要把烘焙 report 的 groundBounds 再搬一份到运行时。
    /// 外扩"一格 + 胶囊半径"，让贴边的格子也落在范围内。
    private func residentPropGridBounds(context: WorldAgentContext) -> WorldPlanarBounds? {
        let positions = context.manifest.waypoints.filter(\.enabled).map(\.position)
        guard let first = positions.first else { return nil }
        var minimumX = first.x, maximumX = first.x
        var minimumZ = first.z, maximumZ = first.z
        for position in positions {
            minimumX = min(minimumX, position.x); maximumX = max(maximumX, position.x)
            minimumZ = min(minimumZ, position.z); maximumZ = max(maximumZ, position.z)
        }
        let parameters = PropSupportGridParameters.default
        let margin = parameters.spacing + parameters.capsuleRadius
        return WorldPlanarBounds(
            minimumX: minimumX - margin, maximumX: maximumX + margin,
            minimumZ: minimumZ - margin, maximumZ: maximumZ + margin
        )
    }

    /// 装修会话的开/关：**这里的两条守卫过去都是静默 return**，而它们决定的正是
    /// "面板开着、却没有人会回答它的点击"。所以每一步都留一条 `.notice`：
    /// 真机上只要看这两条日志，就能立刻区分"进没进装修"和"进不去是因为哪一条"。
    private func setResidentPropEditing(_ editing: Bool) {
        if editing {
            livingWorldLogger.notice(
                "装修：请求进入装修（当前世界=\(self.spatialStage.selectedWorldID ?? "nil", privacy: .public) 期望世界=\(self.livingWorldContext?.manifest.worldID ?? "nil", privacy: .public)）"
            )
            guard residentPropEditingWorldID == nil, let context = livingWorldContext,
                  spatialStage.selectedWorldID == context.manifest.worldID else {
                livingWorldLogger.notice(
                    "装修：请求进入装修被守卫挡下（会话世界=\(self.residentPropEditingWorldID ?? "nil", privacy: .public) 生活空间上下文=\(self.livingWorldContext != nil, privacy: .public) 当前世界=\(self.spatialStage.selectedWorldID ?? "nil", privacy: .public) 期望世界=\(self.livingWorldContext?.manifest.worldID ?? "nil", privacy: .public)）"
                )
                return
            }
            residentPropEditingWorldID = context.manifest.worldID
            residentPropEditingID = UUID()
            livingWorldLogger.notice("装修：进入装修 world=\(context.manifest.worldID, privacy: .public)")
            residentPropEditingBackgroundEnabled = residentAgentLoop?.snapshot.backgroundEnabled ?? false
            residentPropEditingPreferenceEnabled = UserDefaults.standard.bool(forKey: "resident.autonomous.enabled.v1")
            temporarilyPauseResidentForPropEditing()
            liveCamMessageID = nil
            AgentConversationService.shared.cancel()
            avatarRuntime.clearResidentThinking()
            residentActivityOutcome?.abort()
            do { try context.stopActivity() } catch { showResidentVoiceStatus("生活活动停止失败：\(error.localizedDescription)") }
            spatialStage.clearMovement()
            activateResidentPropGrid(context: context)
            Task { @MainActor [weak self] in await self?.synchronizeOwnedResidentProps() }
        } else {
            guard let worldID = residentPropEditingWorldID else {
                // 会话本来就不在：没有格子要收，也没有任务要停。仍然报一条，因为
                // "退出时才发现会话从来没接上"正是真机上最难看出来的一种状态。
                livingWorldLogger.notice("装修：退出装修，但会话本来就没接上（residentPropEditingWorldID 为 nil），无需清理。")
                return
            }
            residentPropEditingWorldID = nil
            residentPropEditingID = nil
            spatialStage.residentPropPreview = nil
            // 令牌与网格必须一起失效：会话没了，就没有"还在生成"这回事了。
            residentPropGridDerivation = nil
            residentPropGridEditor.deactivate()
            livingWorldLogger.notice("装修：退出装修 world=\(worldID, privacy: .public)，格子已停用。")
            publishResidentPropGrid()
            guard spatialStage.selectedWorldID == worldID, livingWorldContext?.manifest.worldID == worldID else { return }
            if UserDefaults.standard.bool(forKey: "resident.autonomous.enabled.v1") == residentPropEditingPreferenceEnabled {
                residentAgentLoop?.setBackgroundEnabled(residentPropEditingBackgroundEnabled)
            } else { refreshResidentAutonomy() }
            residentAgentLoop?.receiveEvent(.init(id: UUID().uuidString, kind: "room.layout.changed",
                summary: "用户已结束摆放。请重新观察真实物件位置；先前活动已中断，不恢复旧路径。"))
        }
    }

    private func bindResidentWishScope(_ worldContext: ResidentWorldContext, loop: ResidentAgentLoop) {
        guard worldContext.worldID == WishMachineScene.worldID else { return }
        residentWishScope = ResidentWishScope(loopID: ObjectIdentifier(loop), worldID: WishMachineScene.worldID,
            residentScope: worldContext.sessionScope)
    }

    private func pauseResidentWishContinuations() {
        guard !residentPropTemporaryCancellation else { return }
        guard let scope = residentWishScope, let loop = residentAgentLoop,
              scope.loopID == ObjectIdentifier(loop) else { return }
        do {
            try wishMachineCoordinator.pauseContinuations(worldID: scope.worldID, residentScope: scope.residentScope)
        } catch {
            showResidentVoiceStatus("本次行动已停止，许愿任务仍保留。自动领取的暂停状态保存失败，重启后可能恢复，请暂勿重启并稍后重试停止。")
        }
    }

    /// 已领产物是否已经在当前空间里真正摆好（宿主读回，不是模型声明）。
    /// 领取后的续办必须凭这份读回决定能否恢复原摆放委托；同一个判据同时供
    /// 工具租约（后台续办）与面板上的一次"恢复"使用。
    private func residentWishPlacementAlreadyCompleted(_ job: WishMachineJob) -> Bool? {
        guard let context = livingWorldContext, context.manifest.worldID == job.worldID,
              let placedState = context.state.objectStates[job.objectID],
              placedState.generatedProp != nil,
              UUID(uuidString: placedState.generatedProp?.sourceWishID ?? "") == job.id else { return nil }
        return placedState.isEnabled
    }

    /// 面板上的**一个动作**：恢复该许愿任务的自动续办，并解除"停止自主行动"。
    /// 这是人类的一次明确操作——不是模型工具，也不需要用户说对任何一句话。
    /// 它同时做两件语义各自独立的事，因为用户按下"恢复"就是这个意思：
    ///   1) 任务级：持久恢复该许愿的自动续办，并授予**一次**可信续办事件
    ///      （每次点击都用新的宿主授权；旧授权在再次停止后不可复用）；
    ///   2) run 级：解除"停止自主"，否则续办事件只会排队而不会真正执行。
    /// 它不新建生成任务、不替用户领取，也不代表后台获得任何新权限：领取与摆放
    /// 仍由居民按本轮授权执行。
    @discardableResult
    private func resumeWishAutomaticContinuation(id: UUID) -> Bool {
        guard let scope = residentWishScope, let loop = residentAgentLoop,
              scope.loopID == ObjectIdentifier(loop) else {
            // 一次操作不能"点了没反应"：接不上当前居民会话/许愿机空间时也要说清楚。
            showResidentVoiceStatus("恢复自动领取失败：当前没有绑定到此空间的居民许愿会话，请重新进入该空间后再试。")
            return false
        }
        // run 级解除先做：即使任务级恢复此刻被拒（例如任务已终态），"停止自主"
        // 这个用户可见的状态也已经被这一个动作解开了。
        loop.resumeAutonomyByUser()
        do {
            let existing = try wishMachineCoordinator.read(id: id, worldID: scope.worldID,
                residentScope: scope.residentScope)
            guard existing.autoContinuationPaused == true else {
                synchronizeWishMachinePresentation()
                return true
            }
            _ = try wishMachineCoordinator.resumeContinuations(id: id, worldID: scope.worldID,
                residentScope: scope.residentScope, authorizationID: UUID(),
                placementAlreadyCompleted: existing.stage == .claimed
                    ? residentWishPlacementAlreadyCompleted(existing) : nil)
        } catch {
            showResidentVoiceStatus("恢复自动领取失败：\(error.localizedDescription)")
            synchronizeWishMachinePresentation()
            return false
        }
        synchronizeWishMachinePresentation()
        Task { @MainActor [weak self] in await self?.refreshWishMachine() }
        return true
    }

    /// 居民自身真实状态快照：来自当前 WorldAgentContext 与角色运行时，
    /// 由宿主在工具调用时注入，模型不能从记忆生成或修改。
    private func residentSelfState() -> ResidentSelfState? {
        guard let context = livingWorldContext,
              spatialStage.selectedWorldID == context.manifest.worldID else { return nil }
        let transform = context.state.agentTransform
        let activity = context.snapshot.activeActivity
        let yaw = atan2(2 * (transform.rotation.w * transform.rotation.y),
            1 - 2 * transform.rotation.y * transform.rotation.y) * 180 / .pi
        return ResidentSelfState(
            space: context.snapshot.displayName,
            position: [Double(transform.position.x), Double(transform.position.y), Double(transform.position.z)],
            yawDegrees: Double(yaw),
            avatarFormat: avatarRuntime.snapshot.avatar?.format.rawValue,
            activityID: activity?.id,
            activityPhase: activity?.phase.rawValue,
            heldPropID: context.state.heldProp?.objectID)
    }

    private func rebindResidentLoopMemory() {
        guard let loop = residentAgentLoop else { return }
        let context = currentResidentWorldContext()
        guard let worldID = context.worldID else { return }
        let scope = ResidentStateScope(worldID: worldID, residentScope: context.sessionScope)
        // 同一循环、同一作用域：不重绑定、不打断进行中的恢复/重试节流。
        if let binding = residentMemoryBinding, binding.loop === loop, binding.scope == scope { return }
        residentMemoryBinding = (loop, scope)
        residentMemoryBindingGeneration = UUID()
        residentMemoryRestoreTask?.cancel()
        residentMemoryRestoreTask = nil
        // bindMemory 会重置循环内的恢复状态机并按新作用域重新开始恢复。
        loop.bindMemory(store: residentMemoryStore, scope: scope)
    }

    /// 恢复未放行前由既有 5 秒调度驱动一次尝试：循环内部按 30 秒节流真实
    /// transport 调用（失败保留失败状态，不新增计时器）。用户消息不经过这里，
    /// 任何时候都能照常进入回合。只有成功/确认无记录/用户已接管才放行自主。
    private func scheduleResidentMemoryRestoreIfNeeded(loop: ResidentAgentLoop) {
        guard residentMemoryRestoreTask == nil else { return }
        guard let binding = residentMemoryBinding, binding.loop === loop else { return }
        let generation = residentMemoryBindingGeneration
        residentMemoryRestoreTask = Task { @MainActor [weak self, weak loop] in
            guard let loop else { return }
            _ = await loop.restoreMemory()
            guard let self, self.residentAgentLoop === loop,
                  self.residentMemoryBindingGeneration == generation,
                  self.residentMemoryBinding?.loop === loop,
                  self.residentMemoryBinding?.scope == binding.scope else { return }
            self.residentMemoryRestoreTask = nil
            // 成功/无记录/用户已接管的迟到失败都不会再阻塞自主；失败则保持
            // 不放行，等既有调度在节流到点后重试。
            if !loop.memoryRestoreBlocksAutonomy { self.refreshResidentAutonomy() }
        }
    }

    /// 把**本地**对话记忆适配器（daemon 的 `memory_recall` / `memory_ingest`）挂到会话服务。
    ///
    /// 这里**不再有任何外部 provider 接线**：`memory_configure` 与"语义压缩 / embedding
    /// 服务"的整套配置（环境变量解析、provider 状态轮询、缺配置/后台整理失败的可见提示）
    /// 已整体移除。记忆模块本身留在 Rust daemon 里（`memory.rs`），不再依赖外部服务；
    /// 安装器里那套记忆 provider 环境变量与 `--configure-memory-only` 同步删除。
    private func configureResidentConversationMemory() {
        AgentConversationService.shared.attachConversationMemory(
            residentConversationMemory
        ) { [weak self] message in
            // **只记日志，不上屏**：记忆交付失败是本地记忆的内部细节，聊天本身
            // 不受影响，用状态行打扰用户只会让人以为"聊天坏了"。
            self?.livingWorldLogger.notice("记忆交付错误：\(message, privacy: .public)")
        }
    }

    /// 最近对话的作用域键：世界 + 居民会话 + 当前对话后端。任一变化（换空间、
    /// 换后端）都会让旧回合立即作废，绝不显示别的世界或别的后端会话的对话。
    private var residentTranscriptScopeKey: String {
        let context = currentResidentWorldContext()
        let backend = AgentConversationService.shared.effectiveBackendID.rawValue
        return "\(context.worldID ?? "-")|\(context.sessionScope)|\(backend)"
    }

    /// 换世界/换后端等上下文切换：旧对话立即作废（activate 只在作用域变化时清空）。
    private func resetResidentTranscriptForContextSwitch() {
        residentChatTranscript.activate(scopeKey: residentTranscriptScopeKey)
        publishResidentTranscript()
    }

    /// 把同一份快照推给两个聊天表面；它们是展示层，不做各自的回合判定。
    private func publishResidentTranscript() {
        let lines = residentChatTranscript.lines()
        liveCamWindowController?.setResidentTranscript(lines)
        stageWindowController?.setResidentTranscript(lines)
    }

    /// 获准的静默完成（居民只更新了安排、没有文字回复）没有 onReply；在既有
    /// 呈现同步里把本轮提交收尾为「已完成、没有回复文字」，不让历史停在等待。
    private func settleSilentResidentTurnIfNeeded() {
        guard residentAgentLoop?.lastFinishedTurnWasSilent == true else { return }
        let ids = residentAgentLoop?.lastFinishedTurnSubmissionIDs ?? []
        guard !ids.isEmpty else { return }
        if residentChatTranscript.markSilentlyCompleted(ids: ids) {
            publishResidentTranscript()
        }
    }

    /// 居民回复交付呈现（ensureResidentLoop 的 onReply）：把回复同步写入可见聊天
    /// 表面。
    ///
    /// **原文层移除后这里不再有任何"记忆确认"**：原先它要按 autoSpeak 的结果挑时机
    /// 调 `confirmDeliveredTurn`（语音整段播完 / 静音文本真实显示），并为此维护一份
    /// 交付凭据。那份凭据与调用链已随 `memory_ingest` 一起删除，所以现在这里只做
    /// 呈现——朗读照旧、显示照旧，且**不再有任何"写记忆"的动作**。
    private func presentResidentReply(_ reply: String) {
        // 先按真实回合身份登记「真正送达」：只更新已记录的用户提交，未知/迟到
        // 的身份不臆造回合，也不重复显示。
        let deliveredIDs = residentAgentLoop?.lastFinishedTurnSubmissionIDs ?? []
        if !deliveredIDs.isEmpty {
            residentChatTranscript.markDelivered(ids: deliveredIDs, reply: reply)
            publishResidentTranscript()
        }
        let speechEnabled = AgentConversationService.shared.preferenceStore.autoSpeakReplies
        agentSpeechAnnouncer.isEnabled = speechEnabled
        // 后台/自驱回合的回复照常写进聊天表面，但绝不替用户展开聊天、收起面板：
        // 只有用户发起的回合才自动露出回复。
        let autoRevealsChat = residentAgentLoop?.lastFinishedRunWasBackground != true
        liveCamWindowController?.finishAgentReply(reply)
        stageWindowController?.finishResidentReply(reply, autoRevealsChat: autoRevealsChat)
        // 朗读照旧。原文层移除**不影响**这一条：原先这里用一个带回调的
        // `announce`，回调里既数"语音交付"又去确认记忆写入；现在没有记忆写入要
        // 确认了，但"整段播完才算语音交付"这个语义仍由 `AgentSpeechAnnouncer`
        // 自己维护，所以直接用无回调的重载即可（不再需要为记忆挑时机）。
        if speechEnabled {
            agentSpeechAnnouncer.announce(reply)
        }
    }

    private func ensureResidentLoop() -> ResidentAgentLoop {
        if let residentAgentLoop {
            bindResidentWishScope(currentResidentWorldContext(), loop: residentAgentLoop)
            rebindResidentLoopMemory()
            return residentAgentLoop
        }
        let loop = ResidentAgentLoop(
            run: { [weak self] input in
                guard let self else { throw CancellationError() }
                return try await self.performResidentTurn(input)
            },
            steer: { text in await AgentConversationService.shared.steerResident(text) },
            onReply: { [weak self] reply in
                guard let self else { return }
                self.presentResidentReply(reply)
            },
            onFailure: { [weak self] message in self?.presentResidentLoopFailure(message) },
            onChange: { [weak self] in self?.synchronizeResidentLoopPresentation() },
            onCancel: { [weak self] in
                AgentConversationService.shared.cancel()
                self?.residentActivityOutcome?.abort()
                try? self?.residentActivityOwnership.stopOwnedActivity()
                self?.agentSpeechAnnouncer.stop()
                self?.avatarRuntime.clearResidentThinking()
                // 这里**不再**暂停许愿任务的自动续办：这条通道对每一次取消都会触发
                // （换空间、退出、自主可用性/网络回收、后台预算回收），它们不是用户
                // 意图。任务级暂停是持久的、只能人工解除的，因此只由 onUserStop 落盘。
            },
            onUserStop: { [weak self] in self?.pauseResidentWishContinuations() }
        )
        residentAgentLoop = loop
        bindResidentWishScope(currentResidentWorldContext(), loop: loop)
        rebindResidentLoopMemory()
        return loop
    }

    private func synchronizeResidentLoopPresentation() {
        let thinking = residentAgentLoop?.snapshot.isRunning ?? false
        // 后台/自驱回合只更新状态，不抢开聊天、不收起用户正在看的面板。
        let backgroundTurn = residentAgentLoop?.snapshot.isBackgroundRun == true
        liveCamWindowController?.setResidentThinking(thinking)
        stageWindowController?.setResidentThinking(thinking, autoRevealsChat: !backgroundTurn)
        let loop = residentAgentLoop?.snapshot
        liveCamWindowController?.setResidentProgress(loop?.progress)
        stageWindowController?.setResidentProgress(loop?.progress)
        let canStop = residentActivityOwnership.hasActiveActivity
            || (loop?.backgroundEnabled == true && loop?.isStopped == false)
        liveCamWindowController?.setResidentCanStop(canStop)
        stageWindowController?.setResidentCanStop(canStop)
        // 「能不能自主」是**一个全局开关**，不是任务属性：停止只驱动任务面板顶部
        // 那一条全局横幅（`setResidentAutonomyStop`）+ 下面这条可读提示，
        // 任何任务行上都不再出现按任务的停止/恢复控件。
        let autonomyStopped = loop?.isAutonomyPausedByUser == true
        liveCamWindowController?.setResidentAutonomyStop(autonomyStopped)
        stageWindowController?.setResidentAutonomyStop(autonomyStopped)
        var notices: [String] = []
        let queuedCount = loop?.pendingUserMessages.count ?? 0
        if queuedCount > 0 { notices.append("\(queuedCount) 条消息排队中。") }
        // "停止"必须看得见：它在界面上不是隐形状态。这里说明停止只停自主续办，
        // 并给出解除路径（任务面板顶部的"恢复自主行动"，或设置里打开自主生活）。
        if loop?.isAutonomyPausedByUser == true {
            notices.append("自主行动已停止：后台不会自行续办、自行领取或摆放；直接下达指令仍会执行。点任务面板上的「恢复自主行动」，或在设置里打开「允许居民自主安排活动」，即可解除。")
        }
        // 交付未确认只在用户尚未接手时提示：用户下次发送/停止/换空间后旧提示不再
        // 显示；模型上下文里的 unconfirmedUserMessages 不变，仍避免重复执行。
        let pendingUnconfirmed = residentUnconfirmedNotice.pending(
            loop?.unconfirmedUserMessages ?? []
        )
        if !pendingUnconfirmed.isEmpty {
            notices.append(
                "有 \(pendingUnconfirmed.count) 条补充消息尚未确认送达，未重复发送。"
                    + "如需重来，请在下一条消息里说明，或切换到别的对话后端新建会话。"
            )
        }
        let notice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        liveCamWindowController?.setResidentDeliveryNotice(notice)
        stageWindowController?.setResidentDeliveryNotice(notice)
        settleSilentResidentTurnIfNeeded()
        refreshResidentBackendGuidance()
    }

    /// 一个后端都没装时不等到用户输入才失败：在聊天表面空闲时先给出可执行的
    /// 设置路径。只在当前没有别的状态提示时显示，绝不盖掉真实失败；装上后端后
    /// 由新回合/新提示自然替换。
    private func refreshResidentBackendGuidance() {
        let hasBackend = AgentConversationService.shared.hasUsableConversationBackend
        guard let guidance = ResidentBackendReadiness.guidance(hasUsableBackend: hasBackend) else {
            return
        }
        guard liveCamWindowController != nil || stageWindowController != nil else { return }
        if let current = liveCamWindowController?.residentStatusText, !current.isEmpty { return }
        if let current = stageWindowController?.residentStatusText, !current.isEmpty { return }
        liveCamWindowController?.showFailureStatus(guidance)
        stageWindowController?.showResidentFailureStatus(guidance)
    }

    private func startResidentLoopScheduling() {
        residentLoopSchedulingTask?.cancel()
        residentLoopSchedulingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                await refreshWishMachine()
                refreshResidentAutonomy()
                // 没有后端时不等用户输入：表面可用就先给出设置路径。
                refreshResidentBackendGuidance()
            }
        }
    }

    @objc private func residentAutonomyDidChange(_ notification: Notification) {
        // 用户在设置里重新打开"允许居民自主安排活动"就是一次明确的人类操作：
        // 它必须真的解开此前的"停止自主行动"。停止不是永久契约，也不该要求
        // 用户猜一句能让居民调用 update_resident_intent 的话。
        if UserDefaults.standard.bool(forKey: "resident.autonomous.enabled.v1") {
            residentAgentLoop?.resumeAutonomyByUser()
        }
        refreshResidentAutonomy()
    }

    /// 切换对话后端：旧后端的进度/失败/语音提示与未确认交付提示都不再适用，
    /// 清掉以免把上一条后端的状态显示在新后端上。
    @objc private func agentConversationBackendDidChange(_ notification: Notification) {
        residentUnconfirmedNotice.reset()
        // 换后端就是换会话：旧后端的最近对话不适用于新后端，立即作废。
        resetResidentTranscriptForContextSwitch()
        liveCamWindowController?.clearTransientStatus()
        stageWindowController?.clearResidentTransientStatus()
        liveCamWindowController?.setResidentDeliveryNotice(nil)
        stageWindowController?.setResidentDeliveryNotice(nil)
    }

    /// 居民视觉：全舞台现用相机的当前观察画面（仅 current_observation，
    /// 无 global/eyes 视角）。表面由真实渲染视图发布；只服务本轮
    /// messageID(=runID)+world：循环已不在本轮、或世界已切换即返回 nil，
    /// 不用 warmup 占位、也不让下一轮 runID 顶替旧会话。
    private func residentVisionSession(messageID: UUID) -> ResidentVisionToolbox.Session? {
        guard let context = livingWorldContext,
              spatialStage.selectedWorldID == context.manifest.worldID,
              residentAgentLoop?.snapshot.runID == messageID else { return nil }
        return ResidentVisionToolbox.Session(runID: messageID,
            worldID: context.snapshot.worldID, worldRevision: context.snapshot.revision)
    }

    private func refreshResidentAutonomy() {
        guard residentPropEditingWorldID == nil else { return }
        let canAct = AgentConversationService.shared.supportsWorldTools
            && livingWorldContext?.manifest.worldID == spatialStage.selectedWorldID
            && livingWorldContext != nil
        if canAct {
            let loop = ensureResidentLoop()
            loop.setBackgroundTurnsPerHour(ResidentPreferences().backgroundTurnsPerHour)
            // 跨重启记忆恢复成功或确认无记录前不开始自主新规划：失败保留在
            // 循环状态里，由既有 5 秒调度按 30 秒节流重试。用户消息不受影响；
            // 用户已接手的旧恢复按 superseded 作废，不会卡死自主。
            if loop.memoryRestoreBlocksAutonomy {
                scheduleResidentMemoryRestoreIfNeeded(loop: loop)
                return
            }
            loop.setBackgroundEnabled(UserDefaults.standard.bool(forKey: "resident.autonomous.enabled.v1"))
            loop.tick()
        } else {
            _ = returnHeldPropBeforeResidentStop(reason: "暂停居民自主生活")
            residentAgentLoop?.setBackgroundEnabled(false)
        }
    }

    private func currentResidentWorldContext() -> ResidentWorldContext {
        guard let context = livingWorldContext,
              spatialStage.selectedWorldID == context.manifest.worldID else {
            return .unavailable(selectedWorldID: spatialStage.selectedWorldID)
        }
        let snapshot = context.snapshot
        let manifest = context.manifest
        let generatedPropIDs = context.state.objectStates.compactMap { id, state in
            state.generatedProp == nil ? nil : id
        }
        let objects = Set(manifest.activities.flatMap(\.propIDs)).union(generatedPropIDs).sorted().map { id in
            let state = context.state.objectStates[id]
            let position = state?.transform.position
            let capability = state?.propCapability
            let displayName = state?.generatedProp.map { prop -> String in
                if let template = capability.flatMap({ WorldPropActivityTemplate.supported[$0.templateID] }) {
                    prop.displayName + "（可按\(template.displayName)模板在空间内模拟使用）"
                } else {
                    prop.displayName + "（外形摆件，无功能）"
                }
            } ?? (id == "prop.jukebox" ? "点唱机" : (id == WishMachineScene.propID ? "许愿机" : nil))
            return ResidentWorldContext.Object(
                id: id,
                displayName: displayName,
                position: position.map { [$0.x, $0.y, $0.z] },
                isEnabled: state?.isEnabled,
                activityIDs: (manifest.activities.filter { $0.propIDs.contains(id) }.map(\.id)
                    + context.propActivityIDs(objectID: id)).sorted()
            )
        }
        let position = snapshot.agentTransform.position
        return ResidentWorldContext(
            selectedWorldID: spatialStage.selectedWorldID,
            worldID: snapshot.worldID,
            displayName: snapshot.displayName,
            revision: snapshot.revision,
            residentPosition: [position.x, position.y, position.z],
            activeActivity: snapshot.activeActivity?.id,
            activityPhase: snapshot.activeActivity?.phase.rawValue,
            objects: objects,
            availableActivities: snapshot.activities.filter { isResidentActivityAvailable($0.id) }.map { activity in
                ResidentWorldContext.Activity(
                    id: activity.id,
                    // Prop capability activities only exist in the combined
                    // catalog; the authored manifest alone would hide their names.
                    displayName: context.activityCatalog.definition(id: activity.id)?.displayName,
                    action: activity.action,
                    entryPlaceID: activity.entryPlaceID
                )
            }
        )
    }

    private func isResidentActivityAvailable(_ id: String) -> Bool {
        // A prop capability activity is usable only when the current avatar
        // format has an approved motion for its receipt-driven enter phase.
        if let context = livingWorldContext,
           context.isPropCapabilityActivity(id),
           let enter = context.activityCatalog.definition(id: id)?.contract(for: .enter) {
            let compatible = LivingWorldAvatarPresentationPolicy.compatibleMotions(
                livingWorldApprovedMotions,
                avatarFormat: avatarRuntime.snapshot.avatar?.format
            )
            return enter.motionIDs.contains { compatible[$0] != nil }
        }
        return ResidentPerformanceMotionPolicy.isAvailable(activityID: id, avatarFormat: avatarRuntime.snapshot.avatar?.format,
                                                    approvedMotions: livingWorldApprovedMotions)
    }

    private func refreshResidentActivityMenu() {
        guard let context = livingWorldContext else { return }
        let definitions = context.activityCatalog.definitions.filter { isResidentActivityAvailable($0.id) }
        let menu = LivingWorldActivityMenuStore.shared
        guard menu.worldID != context.manifest.worldID || menu.items.map(\.id) != definitions.map(\.id) else { return }
        menu.update(definitions: definitions, worldID: context.manifest.worldID)
        menu.updateActiveActivity(id: context.snapshot.activeActivity?.id)
    }

    private func residentWishPlacementGrant(objectID: String, placement: WorldPropPlacement,
                                             worldID: String, residentScope: String) throws -> ResidentPropDelegatedGrant {
        guard currentResidentWorldContext().worldID == worldID,
              currentResidentWorldContext().sessionScope == residentScope,
              residentOwnedPropAssets[objectID] != nil,
              wishMachineCoordinator.residentJobs(worldID: worldID, residentScope: residentScope)
                .contains(where: { $0.objectID == objectID && $0.stage == .claimed && $0.autoContinuationPaused != true })
        else { throw WishMachineError.unauthorized }
        let target = WishPlacementTarget(surfaceID: placement.surfaceID,
            position: .init(x: Double(placement.position.x), y: Double(placement.position.y), z: Double(placement.position.z)),
            yaw: Double(placement.yaw))
        let delegation = try wishMachineCoordinator.resolvePlacementGrant(worldID: worldID,
            residentScope: residentScope, objectID: objectID, surfaceID: placement.surfaceID, target: target)
        let effective = delegation.explicitTarget ?? delegation.boundTarget
        let grantedPlacement = effective.map { target in
            WorldPropPlacement(surfaceID: target.surfaceID,
                position: .init(x: Float(target.position.x), y: Float(target.position.y), z: Float(target.position.z)),
                yaw: Float(target.yaw))
        }
        return ResidentPropDelegatedGrant(objectID: objectID, allowedSurfaceIDs: Set(delegation.allowedSurfaceIDs),
            target: grantedPlacement, requestID: delegation.requestID)
    }

    private func recordResidentWishPlacement(_ grant: ResidentPropDelegatedGrant, placement: WorldPropPlacement,
                                              worldID: String, residentScope: String) throws {
        let target = WishPlacementTarget(surfaceID: placement.surfaceID,
            position: .init(x: Double(placement.position.x), y: Double(placement.position.y), z: Double(placement.position.z)),
            yaw: Double(placement.yaw))
        try wishMachineCoordinator.recordPlacementCompletion(worldID: worldID, residentScope: residentScope,
            objectID: grant.objectID, requestID: grant.requestID, surfaceID: placement.surfaceID, target: target)
    }

    private func reconcileResidentWishPlacements(_ worldContext: ResidentWorldContext) throws {
        guard let context = livingWorldContext, context.manifest.worldID == worldContext.worldID else { return }
        // A crash can happen after the world saved the placement but before the
        // wish journal recorded completion. Read the committed command, never
        // execute it again or replace it with a newly inferred position.
        for delegation in wishMachineCoordinator.placementDelegations(worldID: context.manifest.worldID,
            residentScope: worldContext.sessionScope) where delegation.state == .pending {
            guard let command = context.state.layoutReceipts[delegation.requestID],
                  case .place(let objectID, let placement) = command,
                  delegation.objectID == objectID else { continue }
            let target = WishPlacementTarget(surfaceID: placement.surfaceID,
                position: .init(x: Double(placement.position.x), y: Double(placement.position.y), z: Double(placement.position.z)),
                yaw: Double(placement.yaw))
            try wishMachineCoordinator.recordPlacementCompletion(worldID: context.manifest.worldID,
                residentScope: worldContext.sessionScope, objectID: objectID, requestID: delegation.requestID,
                surfaceID: placement.surfaceID, target: target)
        }
    }

    /// `humanOrderedClaim` 是"本轮是否载有人类明确指令"的**实时**判据（不是建租约
    /// 时的一次快照）：后台 run 被人类引导接手后，本轮就是奉命轮，人类当轮的
    /// 明确领取必须能执行。`allowsPausedWishClaim` 仍只描述"这一轮是不是由人类
    /// 输入发起的"——它决定本轮能否**恢复**任务级自动续办（人类明确要求恢复的
    /// 那一轮才给恢复授权），恢复与领取是两件事。
    private func makeResidentWorldTools(messageID: UUID, wishAuthorizationID: UUID? = nil, allowsPausedWishClaim: Bool = false,
                                       humanOrderedClaim: @escaping @MainActor () -> Bool = { false },
                                       allowsPropMutation: Bool = false) -> ResidentConversationTools? {
        guard AgentConversationService.shared.supportsWorldTools,
              let context = livingWorldContext,
              spatialStage.selectedWorldID == context.manifest.worldID else { return nil }
        let worldID = context.manifest.worldID
        residentActivityOutcome?.abort()
        let isCurrent: @MainActor () -> Bool = { [weak self, weak context] in
            guard let self, let context else { return false }
            return self.liveCamMessageID == messageID
                && self.spatialStage.selectedWorldID == worldID
                && self.livingWorldContext === context
                && self.residentPropEditingWorldID == nil
        }
        // 「这一轮为什么不current」的**具体**原因。没有它，点唱机被提前结束在工具侧
        // 只能说"已取消或被替换"，而真正的原因（比如空间正在装修）既不上屏也不进日志。
        let currentBlocker: @MainActor () -> String? = { [weak self, weak context] in
            guard let self else { return "应用状态已经释放" }
            if self.liveCamMessageID != messageID { return "本轮对话已经被新的一轮替换" }
            if self.spatialStage.selectedWorldID != worldID { return "已经切换到别的世界" }
            guard let context, self.livingWorldContext === context else { return "生活空间已经重新加载" }
            if self.residentPropEditingWorldID != nil { return "空间正在装修（摆放模式），居民的点唱机操作已失去授权" }
            return nil
        }
        let deadline = Date().addingTimeInterval(300)
        let outcome = ResidentActivityOutcome(
            context: context,
            isCurrent: isCurrent,
            currentBlocker: currentBlocker,
            play: { [weak self] owner in
                guard let self else { throw CancellationError() }
                try await self.resumeResidentJukebox(owner: owner)
            },
            pause: { [weak self] owner in
                guard let self else { throw CancellationError() }
                try await self.pauseResidentJukebox(owner: owner)
            },
            deadline: deadline
        )
        residentActivityOutcome = outcome
        let loopTools = ResidentLoopTools(loop: ensureResidentLoop(), runID: messageID,
            selfState: { [weak self] in self?.residentSelfState() })
        // 居民视觉：仅 current_observation（全舞台现用相机），每轮按
        // messageID(=本轮 runID)+worldID 门控；工具调用一律经 session.call。
        let visionSurface = stageRenderSurfaceController?.surfaceView.residentVisionSurfaceHandle
        let visionImages = ResidentVisionImageBox()
        let visionToolbox: ResidentVisionToolbox? = visionSurface.map { surface in
            ResidentVisionToolbox(surface: surface, fileRoot: nil,
                currentSession: { [weak self] in self?.residentVisionSession(messageID: messageID) })
        }
        let additionalTools = ResidentLoopTools.schemas.compactMap { schema -> ResidentWorldToolSession.AdditionalTool? in
            guard let name = schema["name"] as? String,
                  let description = schema["description"] as? String,
                  let inputSchema = schema["inputSchema"] as? [String: Any] else { return nil }
            return ResidentWorldToolSession.AdditionalTool(name: name, description: description,
                inputSchema: inputSchema, validate: { _ in true }, handle: { id, arguments in
                    let result = loopTools.handle(name: name, argumentsJSON: arguments)
                    return RealtimeDJToolResult(callID: id, resultJSON: result.data, isError: result.isError)
                })
        }
        let musicTools = ResidentMusicToolBridge(actions: self, isCurrent: isCurrent)
        let residentScope = currentResidentWorldContext().sessionScope
        let wishTools = worldID == WishMachineScene.worldID
            ? ResidentWishMachineTools(coordinator: wishMachineCoordinator, worldID: worldID,
                residentScope: currentResidentWorldContext().sessionScope,
                authorizationID: wishAuthorizationID, isCurrent: isCurrent, humanOrderedClaim: humanOrderedClaim,
                continuationResumeAuthorizationID: allowsPausedWishClaim ? messageID : nil,
                resumePlacementStatus: { [weak self] job in
                    // 本轮租约已失配就不读回：这份读回只证明"当前"空间的真实摆放。
                    guard isCurrent() else { return nil }
                    return self?.residentWishPlacementAlreadyCompleted(job)
                },
                // 生成服务**声明**的尺寸轴能力：只读接口照实转述，`.unreadable` 时
                // **不声称任何轴被支持**（读不到 ≠ 支持）。桌面侧的实时探测
                // （守护进程 `provider_probe` → `/health` 的 `provider.size_intent`）是另一条线：
                // 接上时只需在这里换掉这个闭包，工具与提示词一行都不用动。
                // 见 docs/plans/2026-10-02-wish-machine-agent-interface.md §7。
                sizeIntentCapability: { .unreadable },
                serviceFacts: { [weak self] in
                    guard let self else { return (false, "") }
                    return (self.wishMachineConfiguration != nil, self.wishMachineServiceNotice)
                }).tools : []
        // 网页参考图：wishworld 的每一次回合（含后台）都注册相同的两个 schema；后台没有
        // 生成授权时 register 会在 handle 内被拒绝，search 仍只读可用。绝不能按
        // wishAuthorizationID 动态移除工具：Codex thread/start 只注册一次 schema，DSH
        // 也缓存清单，后台先建会话后人类 resume 将永久缺工具。登记不等于生成。
        let referenceTools = worldID == WishMachineScene.worldID
            ? ResidentWishReferenceTools.sessionTools(coordinator: wishMachineCoordinator,
                authorizationID: wishAuthorizationID, worldID: worldID, residentScope: residentScope,
                isCurrent: isCurrent)
            : []
        let propTools = worldID == WishMachineScene.worldID
            ? ResidentPropToolBridge(service: residentPropPlacementService(context: context, isCurrent: isCurrent),
                allowsMutation: allowsPropMutation, isCurrent: isCurrent,
                onChange: { [weak self] in self?.synchronizeResidentPropPresentation() },
                prepareMutation: { [weak self, weak context] command in
                    guard let self, let context, isCurrent() else { throw CancellationError() }
                    try await self.prepareResidentPropMutation(command, context: context)
                }, resolveDelegatedGrant: { [weak self] objectID, placement in
                    guard let self, isCurrent() else { throw CancellationError() }
                    return try self.residentWishPlacementGrant(objectID: objectID, placement: placement,
                        worldID: worldID, residentScope: residentScope)
                }, recordDelegatedPlacement: { [weak self] grant, placement in
                    guard let self, isCurrent() else { throw CancellationError() }
                    try self.recordResidentWishPlacement(grant, placement: placement,
                        worldID: worldID, residentScope: residentScope)
                }).tools : []
        // This lease authorizes only registered world, loop and music-library tools for this turn.
        // It does not grant the wider DJ, account, shell or desktop capabilities.
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
            onActivityStarted: { [weak self] context, requestID in
                self?.residentActivityOwnership.claim(context: context, requestID: requestID)
                self?.synchronizeResidentLoopPresentation()
            }, availableActivity: { [weak self] in self?.isResidentActivityAvailable($0) ?? false })
        let visionTools: [ResidentWorldToolSession.AdditionalTool] = visionToolbox.map { toolbox in
            ResidentVisionToolContract.additionalToolSchemas().compactMap { schema in
                guard let name = schema["name"] as? String,
                      let description = schema["description"] as? String,
                      let inputSchema = schema["inputSchema"] as? [String: Any] else { return nil }
                return ResidentWorldToolSession.AdditionalTool(name: name, description: description,
                    inputSchema: inputSchema, validate: { _ in true },
                    handle: { [toolbox, visionImages] id, arguments in
                        // 只在这里取强类型 PNG 产物并存盒；文本回执照常走
                        // session.call 的账本与回执通道。
                        let reply = await toolbox.handleImage(name: name, argumentsJSON: arguments)
                        if !reply.isError, let image = reply.image {
                            visionImages.store(callID: id, image: image)
                        }
                        return RealtimeDJToolResult(callID: id, resultJSON: reply.payloadJSON, isError: reply.isError)
                    })
            }
        } ?? []
        let session = ResidentWorldToolSession(
            scopeID: messageID,
            worldID: worldID,
            dispatcher: dispatcher,
            deadline: deadline,
            isCurrent: isCurrent,
            beforeDispatch: { id, name, arguments in outcome.prepare(callID: id, name: name, argumentsJSON: arguments) },
            afterDispatch: { [weak self] name, arguments, result in
                let completed = await outcome.complete(name: name, argumentsJSON: arguments, result: result)
                if name == "claim_wish_output", !result.isError { await self?.synchronizeOwnedResidentProps() }
                return completed
            },
            onCancel: { outcome.abort(); visionImages.removeAll() },
            additionalTools: additionalTools + musicTools.tools + visionTools + wishTools + referenceTools + propTools,
            maximumCalls: AgentConversationService.shared.effectiveBackendID == .dsh ? nil : 32
        )
        return ResidentConversationTools(
            visionCapable: visionToolbox != nil,
            worldID: worldID,
            schemasJSON: session.toolSchemasJSON,
            call: { [weak self] requestID, name, arguments in
                self?.residentAgentLoop?.recordToolProgress(runID: messageID, toolName: name, phase: .started)
                // 所有工具（含视觉）都经 session.call：租约/取消/次数/deadline
                // 一律走会话账本；原生图片只取自盒内成功回执的强类型产物。
                let result = await session.call(requestID: requestID, name: name, argumentsJSON: arguments)
                let image = visionImages.take(callID: requestID, succeeded: !result.isError)
                self?.residentAgentLoop?.recordToolProgress(runID: messageID, toolName: name,
                    phase: result.isError ? .failed : .returned)
                return ResidentCodexToolReply(resultJSON: result.resultJSON, isError: result.isError, image: image)
            },
            cancel: { session.cancel() },
            allowsSilentCompletion: { loopTools.allowsSilentCompletion }
        )
    }

    private func resumeResidentJukebox(owner: UUID) async throws {
        try Task.checkCancellation()
        guard let context = livingWorldContext,
              spatialStage.selectedWorldID == context.manifest.worldID,
              let active = context.state.activeActivity,
              active.activityID == "music.listen",
              let requestID = context.currentActivityRequestID,
              livingCabinJukeboxGate.consume(worldID: context.manifest.worldID, activityID: active.activityID,
                startedAt: active.startedAt, phase: context.snapshot.activeActivity?.phase.rawValue ?? "", requestID: requestID) else {
            throw ResidentActivityOutcomeError.effectAlreadyHandled
        }
        let route = ProgramPlaybackStartRoute.resolve(playerState: localMusicPlayer.state,
            hasPreparedProgram: activeProgram != nil && programPlaybackQueue.current != nil)
        if route == .unavailable { throw ResidentActivityOutcomeError.musicNotPrepared }
        if route == .startPreparedProgram, let prepared = programPlaybackQueue.current,
           case .providerReference = prepared.target {
            throw ResidentActivityOutcomeError.unsupportedPlaybackSource
        }
        try await ResidentActivityOutcome.$playbackOwner.withValue(owner) {
            try await resumeMusic()
        }
        try Task.checkCancellation()
        guard localMusicPlayer.state == .playing,
              route == .alreadyPlaying || residentJukeboxPlaybackOwner == owner else {
            throw ResidentActivityOutcomeError.interrupted
        }
    }

    private func pauseResidentJukebox(owner: UUID?) async throws {
        guard owner == nil || residentJukeboxPlaybackOwner == owner else { return }
        let route = ProgramPlaybackStartRoute.resolve(playerState: localMusicPlayer.state,
            hasPreparedProgram: activeProgram != nil && programPlaybackQueue.current != nil)
        if route == .startPreparedProgram, let prepared = programPlaybackQueue.current,
           case .providerReference = prepared.target {
            throw ResidentActivityOutcomeError.unsupportedPlaybackSource
        }
        try await pauseMusic()
    }

    private func sendLiveCamMessage(_ message: String) async {
        disconnectRealtimeVoice()
        let loop = ensureResidentLoop()
        // 语音最终转写也是真实用户提交：用稳定身份进入同一份可见历史。
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let submissionID: UUID? = trimmed.isEmpty ? nil : UUID()
        if let submissionID {
            residentChatTranscript.activate(scopeKey: residentTranscriptScopeKey)
            residentChatTranscript.beginTurn(id: submissionID, userText: trimmed, at: Date())
            publishResidentTranscript()
        }
        loop.receiveUserMessage(message, submissionID: submissionID)
        // 语音最终转写入口。**原文层移除后这里不再登记"来源"**：原先要按 runID
        // 变化记 `.voice`（只有它真的启动新的人类轮次时），那份登记只为
        // `memory_ingest` 的 `source` 参数服务，已随原文层一起删除。
    }

    @objc private func propGenerationConfigurationDidChange(_ notification: Notification) {
        configureWishMachineService()
    }

    private func configureWishMachineService() {
        configureWishMessageDelivery()
        do {
            let configuration = try PropGenerationConfigurationStore().load()
            guard configuration != wishMachineConfiguration else { return }
            wishMachineConfiguration = nil
            propGenerationStore.clearConfiguration()
            guard let configuration else {
                wishMachineServiceNotice = "许愿机服务尚未配置，请在空间设置中配置。"
                return
            }
            try propGenerationStore.configure(endpoint: configuration.endpoint, token: configuration.token)
            wishMachineConfiguration = configuration
            wishMachineServiceNotice = "服务配置已读取；是否成功提交以工具回执为准。"
        } catch {
            wishMachineConfiguration = nil
            propGenerationStore.clearConfiguration()
            wishMachineServiceNotice = "许愿机服务配置无法读取，请在空间设置中检查。"
        }
    }

    private func registerWishImages(_ attachments: [ResidentImageAttachment], loop: ResidentAgentLoop, worldScope: String) {
        residentWishImages = residentWishImages.filter { $0.value.loopID == ObjectIdentifier(loop) && $0.value.worldScope == worldScope }
        let conversationID = residentWishImages.values.first?.conversationID ?? UUID()
        for attachment in attachments {
            residentWishImages[attachment.url] = ResidentWishImageRegistration(attachment: attachment,
                loopID: ObjectIdentifier(loop), worldScope: worldScope, conversationID: conversationID)
        }
    }

    private func authorizeWishImages(_ input: ResidentAgentLoop.Input, worldContext: ResidentWorldContext) throws -> UUID? {
        guard !input.isBackground, worldContext.worldID == WishMachineScene.worldID,
              AgentConversationService.shared.supportsWorldTools, let loop = residentAgentLoop,
              loop.isCurrent(runID: input.runID) else { return nil }
        let currentImages = input.imageURLs.compactMap { url -> ResidentWishImageRegistration? in
            guard let registered = residentWishImages[url], registered.loopID == ObjectIdentifier(loop),
                  registered.worldScope == worldContext.sessionScope else { return nil }
            return registered
        }
        guard currentImages.count == input.imageURLs.count else { throw WishMachineError.unknownAttachment }
        let registrations = input.imageURLs.isEmpty
            ? residentWishImages.values.filter { $0.loopID == ObjectIdentifier(loop) && $0.worldScope == worldContext.sessionScope }
                .sorted { $0.registeredAt < $1.registeredAt }
            : currentImages
        // A text-only human turn still opens a run-scoped registration window so the
        // resident may search and register its own reference image before generating.
        // No attachment is authorized until a real image exists, so this grants no
        // generation by itself; background turns never reach here.
        guard let conversationID = registrations.first?.conversationID else { return input.runID }
        let attachments = Array(registrations.suffix(4)).map(\.attachment)
        // Looking at an image does not submit anything. A current human turn can
        // reference its own earlier images; the generation tool still requires a
        // clear manufacturing request, and one authorization can create only one item.
        try wishMachineCoordinator.registerImages(attachments,
            worldID: WishMachineScene.worldID, residentScope: worldContext.sessionScope,
            conversationID: conversationID.uuidString)
        try wishMachineCoordinator.authorize(registeredImageIDs: attachments.map(\.id),
            worldID: WishMachineScene.worldID, residentScope: worldContext.sessionScope,
            conversationID: conversationID.uuidString,
            authorizationID: input.runID, source: .init(author: "用户提供", license: "未核验，仅限个人测试"))
        return input.runID
    }

    private func wishMachineClaimEvidence(for job: WishMachineJob) -> WishMachineClaimEvidence? {
        guard let context = livingWorldContext, context.manifest.worldID == job.worldID,
              spatialStage.selectedWorldID == job.worldID,
              currentResidentWorldContext().sessionScope == job.residentScope else { return nil }
        let position = context.snapshot.agentTransform.position
        // 取物点 = **运行时注册出来的锚点**（声明 × 摆放）。没注册出来就没有领取依据。
        guard let target = context.propAnchorRegistry.entry(activityID: WishMachineScene.activityID)?.position
        else { return nil }
        let dx = Double(position.x - target.x), dy = Double(position.y - target.y), dz = Double(position.z - target.z)
        let outputAvailable = spatialStage.wishMachineOutput?.id == job.objectID
            && spatialStage.wishMachineOutput?.worldID == job.worldID
            && spatialStage.wishMachineOutputStatus == .ready(id: job.objectID)
        // "在跑哪个活动、哪个相位"只认执行器**同一份**一手事实。`snapshot.activeActivity`
        // 把模拟状态的 id 与执行器的相位拼在一起：执行器空转时它给的是"没有 id + 安全待机
        // 的 loop"，于是 `phase == "loop"` 会在什么都没跑的时候成立。领取要的是"真的在跑"。
        let running = context.runningActivity
        return WishMachineClaimEvidence(worldID: job.worldID, activityID: running?.id,
            phase: running?.phase.rawValue,
            distanceMeters: sqrt(dx * dx + dy * dy + dz * dz), outputAvailable: outputAvailable)
    }

    /// The shared unread truth for system task deliveries across both windows.
    /// Content is a user-readable projection of formal wish state; background
    /// ACKs keep their own semantics and are never treated as human reads.
    /// 持久化走统一状态合同（gmgn-taskd inbox 域）；旧 JSON 归档只在作用域
    /// 尚无落库记录时只读导入一次，绝不改写、绝不删除旧文件。
    private lazy var residentSystemInboxStore: ResidentSystemInboxStore = {
        let storage = ResidentSystemInboxStateStorage(client: ResidentStateClient(
            transport: ResidentTaskDaemonStateTransport(client: PropTaskDaemonClient())))
        let legacyArchiveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("GMGNRadio", isDirectory: true)
            .appendingPathComponent("ResidentSystemInbox.json")
        return ResidentSystemInboxStore(
            restore: { scope in
                let stateScope = ResidentStateScope(worldID: scope.worldID, residentScope: scope.residentScope)
                if let durable = try await storage.restore(scope: stateScope) { return durable }
                guard let legacyArchiveURL,
                      let archive = ResidentSystemInboxStateStorage.legacyArchive(at: legacyArchiveURL) else { return nil }
                let imported = ResidentSystemInboxStateStorage.legacyEntries(
                    from: archive, worldID: scope.worldID, residentScope: scope.residentScope)
                return imported.isEmpty ? nil : imported
            },
            persist: { scope, entries in try await storage.persist(scope: ResidentStateScope(
                worldID: scope.worldID, residentScope: scope.residentScope), entries: entries) })
    }()

    private func openSystemInbox() {
        let controller: ResidentSystemInboxWindowController
        if let existing = residentSystemInboxWindowController {
            controller = existing
        } else {
            controller = ResidentSystemInboxWindowController()
            controller.onOpenEntry = { [weak self] row in
                guard let self else { return }
                let context = self.currentResidentWorldContext()
                let taskKey = row.id
                guard let worldID = context.worldID else {
                    self.pushSystemInboxSnapshots()
                    return
                }
                // 已读必须等可靠持久化回执后才算成功；失败保持可见。
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.residentSystemInboxStore.markRead(taskKey: taskKey,
                        worldID: worldID, residentScope: context.sessionScope)
                    self.pushSystemInboxSnapshots()
                }
            }
            residentSystemInboxWindowController = controller
        }
        reloadSystemInboxWindow(controller)
        // 本 app 是 LSUIElement（accessory），而系统消息多半是从 LiveCam 那块
        // `.nonactivatingPanel` 上点开的 —— 此时 app 并没有被激活。少了这句，
        // `makeKeyAndOrderFront` 只会把窗口排到最前却**不会**让它成为 key window：
        // 标题栏是灰的、「打开」作为默认按钮也是灰的、列表点了没有选中态，于是
        // "双击或按「打开」标记为已读"整条承诺都无从发生。舞台窗、登录窗、设置窗
        // 都是先激活再显示，这里补齐同一句。
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = self.currentResidentWorldContext()
            guard let worldID = context.worldID else { return }
            await self.residentSystemInboxStore.restore(worldID: worldID,
                residentScope: context.sessionScope)
            self.pushSystemInboxSnapshots()
        }
    }

    private func reloadSystemInboxWindow(_ controller: ResidentSystemInboxWindowController) {
        controller.window?.subtitle = residentSystemInboxStore.persistenceError ?? ""
        let context = currentResidentWorldContext()
        guard let worldID = context.worldID else { controller.reload([]); return }
        let rows = residentSystemInboxStore.entries(worldID: worldID, residentScope: context.sessionScope)
            .map { entry in
                ResidentSystemInboxWindowController.Row(id: entry.id, title: entry.title,
                    status: entry.status,
                    detail: [entry.status, entry.detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                    isRead: entry.isRead, updatedAt: entry.updatedAt)
            }
        controller.reload(rows)
    }

    private func pushSystemInboxSnapshots() {
        let context = currentResidentWorldContext()
        let unread = context.worldID.map {
            residentSystemInboxStore.unreadCount(worldID: $0, residentScope: context.sessionScope)
        } ?? 0
        stageWindowController?.setSystemInboxUnread(unread)
        liveCamWindowController?.setSystemInboxUnread(unread)
        if let controller = residentSystemInboxWindowController, controller.window?.isVisible == true {
            reloadSystemInboxWindow(controller)
        }
    }

    /// The inbox is the user-readable projection of formal wish state; the
    /// on-site prompts take their 30-second terminal expiry from its anchors.
    /// 投递逐条等待统一状态域持久化；同步的呈现路径不被 IPC 阻塞，带代次
    /// 守卫避免旧一轮的迟到推送覆盖新一轮的任务列表。
    private func pushWishTaskPrompts(_ tasks: [WishMachineTaskPresentation], worldID: String, scope: String) {
        wishTaskPromptGeneration += 1
        let generation = wishTaskPromptGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 每作用域恢复先于投递：CAS revision 校准后提交才不会自相冲突。
            await self.residentSystemInboxStore.restore(worldID: worldID, residentScope: scope)
            for task in tasks {
                _ = await self.residentSystemInboxStore.apply(
                    ResidentSystemDelivery(
                        eventID: "\(task.id.uuidString)|\(task.status)|\(task.isTerminal)|\(task.detail ?? "")",
                        taskID: task.id.uuidString, kind: "wish.task",
                        title: task.title, status: task.status,
                        detail: task.detail ?? "", terminal: task.isTerminal),
                    worldID: worldID, residentScope: scope)
            }
            guard self.wishTaskPromptGeneration == generation else { return }
            let projected = tasks.map { task -> WishMachineTaskPresentation in
                var value = task
                value.promptExpiresAt = self.residentSystemInboxStore.promptExpiry(
                    taskKey: task.id.uuidString, worldID: worldID, residentScope: scope)
                return value
            }
            self.stageWindowController?.setWishMachineTasks(projected)
            self.liveCamWindowController?.setWishMachineTasks(projected)
            self.pushSystemInboxSnapshots()
        }
    }

    private func synchronizeWishMachinePresentation() {
        updateWishMessageScope()
        guard let worldID = currentResidentWorldContext().worldID, worldID == WishMachineScene.worldID else {
            spatialStage.wishMachineOutput = nil
            spatialStage.wishMachineState = .idle
            stageWindowController?.setWishMachineTasks([])
            liveCamWindowController?.setWishMachineTasks([])
            pushResidentConnectivityNotice(worldID: nil, scope: nil)
            pushSystemInboxSnapshots()
            return
        }
        let scope = currentResidentWorldContext().sessionScope
        let jobs = wishMachineCoordinator.residentJobs(worldID: worldID, residentScope: scope)
        pushResidentConnectivityNotice(worldID: worldID, scope: scope)
        // Save the current renderer's failure before replacing its descriptor. The next
        // renderer status belongs to the next artifact and cannot recover this fact.
        if case .failed(let objectID, let message) = spatialStage.wishMachineOutputStatus,
           spatialStage.wishMachineOutput?.id == objectID,
           let job = jobs.first(where: { $0.objectID == objectID && $0.stage == .ready }),
           wishMachineCoordinator.outputRenderFailure(id: job.id, worldID: worldID, residentScope: scope) == nil {
            do {
                try wishMachineCoordinator.recordOutputRenderFailure(id: job.id, worldID: worldID,
                    residentScope: scope, message: message)
            } catch {
                spatialStage.wishMachineState = .failed
                pushWishTaskPrompts(jobs.suffix(20).map { wishMachineTaskPresentation(for: $0) },
                    worldID: worldID, scope: scope)
                pushSystemInboxSnapshots()
                return
            }
        }
        let failedIDs = Set(jobs.filter {
            wishMachineCoordinator.outputRenderFailure(id: $0.id, worldID: worldID, residentScope: scope) != nil
        }.map(\.objectID))
        let identities = Set(jobs.map(\.objectID)).subtracting(failedIDs)
        let ready = wishMachineCoordinator.readyOutputs(worldID: worldID).filter { identities.contains($0.id) }
        if let output = ready.first {
            if !ready.contains(where: { $0.id == spatialStage.wishMachineOutput?.id }) {
                spatialStage.wishMachineOutput = output
            }
        } else { spatialStage.wishMachineOutput = nil }
        if case .failed(let id, _) = spatialStage.wishMachineOutputStatus, spatialStage.wishMachineOutput?.id == id {
            spatialStage.wishMachineState = .failed
        } else if let output = spatialStage.wishMachineOutput,
                  spatialStage.wishMachineOutputStatus == .ready(id: output.id) {
            spatialStage.wishMachineState = .ready
        } else if jobs.contains(where: {
            [.submitting, .submissionUncertain, .generating, .generated].contains($0.stage)
                || ($0.stage == .ready && !failedIDs.contains($0.objectID))
        }) {
            spatialStage.wishMachineState = .generating
        } else if !failedIDs.isEmpty || jobs.last?.stage == .failed || jobs.last?.stage == .interrupted {
            spatialStage.wishMachineState = .failed
        } else { spatialStage.wishMachineState = .idle }
        pushWishTaskPrompts(jobs.suffix(20).map { wishMachineTaskPresentation(for: $0) },
            worldID: worldID, scope: scope)
        pushSystemInboxSnapshots()
    }

    /// **连通性是一条全局提示，不是任务的属性。**
    ///
    /// 它刻意读**整个作用域**（`residentJobs`，不是面板上最近 20 条），所以网络类
    /// 事实不会因为任务滚出面板窗口而消失；`nil` 表示连通正常 —— 横幅据此自动消失，
    /// 不需要用户关掉它。
    ///
    /// 这里**不**把 `propGenerationStore.errorMessage` 也折进来：那条通道同时承载
    /// "缺令牌""配置变更"这类与连通性无关的原因（`PropGenerationError`），
    /// 把它们统一说成"连不上后台"就是换一种假话；本地任务后台 IPC 的原因本来
    /// 已有自己的可见面（`showFailureStatus` / `refreshResidentBackendGuidance`）。
    private func pushResidentConnectivityNotice(worldID: String?, scope: String?) {
        guard let worldID, let scope else {
            stageWindowController?.setWishMachineConnectivity(nil)
            liveCamWindowController?.setWishMachineConnectivity(nil)
            return
        }
        let line = wishMachineCoordinator.residentJobs(worldID: worldID, residentScope: scope)
            .compactMap { ResidentConnectivityFact.firstConnectivityLine(in: $0.lastError) }
            .first
        let notice = line.map(ResidentConnectivityFact.bannerText(for:))
        stageWindowController?.setWishMachineConnectivity(notice)
        liveCamWindowController?.setWishMachineConnectivity(notice)
    }

    private func wishMachineTaskPresentation(for job: WishMachineJob) -> WishMachineTaskPresentation {
        var status: String
        // 连通性是**全局事实**，不是任务属性：它由面板顶部那一条横幅说一次
        // （见 `pushResidentConnectivityNotice`），任务行只剩任务自己的说明。
        var detail = ResidentConnectivityFact.strippingConnectivityLines(from: job.lastError)
        var terminal = false
        // 三轴状态：这里只把事实读出来，判断全在 `ResidentTaskAxisProjection` 里。
        var ownershipFact: ResidentTaskAxisProjection.OwnershipFact = .notClaimed
        var placementFact: ResidentTaskAxisProjection.PlacementFact = .unknown
        switch job.stage {
        case .submitting: status = "正在提交后台"
        case .submissionUncertain: status = "提交待确认"
        case .generating:
            switch job.remoteState {
            case .queued: status = "后台排队中"
            case .waitingResources: status = "等待生成资源"
            case .preflight: status = "检查生成输入"
            default: status = "生成中"
            }
        case .generated: status = "下载与校验中"
        case .ready:
            if let failure = wishMachineCoordinator.outputRenderFailure(id: job.id, worldID: job.worldID,
                residentScope: job.residentScope) {
                status = "场景加载失败"; detail = failure.message; terminal = true
            } else if spatialStage.wishMachineOutput?.id == job.objectID {
                switch spatialStage.wishMachineOutputStatus {
                case .ready(let id) where id == job.objectID: status = "可领取"
                case .failed(let id, let message) where id == job.objectID:
                    status = "场景加载失败"; detail = message
                default: status = "载入场景中"
                }
            } else { status = "等待托盘展示" }
        case .claimed:
            // 「已领取 → 已入库」这一轴**只能**由**库存记录**决定 —— 也就是「我的物件」
            // 列表读的同一份事实（`state.objectStates`，见 `residentPropEditorSnapshot`）。
            // 两处读同一个事实，"说已入库"与"列表里看得见"因此不可能互相矛盾。
            //
            // 以前这里读的是 `residentOwnedPropAssets`（**模型已备好**），而入库
            // 提交发生在模型备好之后：被 `environmentNotReady` 拒掉时模型是好的、
            // 库存里却没有它。真机 2026-10-01 `2B 白色长剑`：`wishes.json` stage=claimed、
            // 资产校验通过、`layoutReceipts` 里**没有** `claimed.<jobID>`、
            // `state.json` 的 `objectStates` 里也没有它 —— 而任务行与系统消息写着
            // "已领取并入库"（30 秒后连那句假话都过期消失）。
            //
            // 这一次读回同时供归属轴与摆放轴使用，所以两条轴不可能互相矛盾。
            let inInventory = livingWorldContext.flatMap { world -> Bool? in
                world.manifest.worldID == job.worldID
                    ? world.state.objectStates[job.objectID]?.generatedProp != nil : nil
            } ?? false
            ownershipFact = inInventory ? .inInventory : .claimedNotInInventory
            if let world = livingWorldContext, world.manifest.worldID == job.worldID,
               let placedState = world.state.objectStates[job.objectID],
               placedState.generatedProp != nil, placedState.isEnabled {
                status = "已摆放"; detail = nil; terminal = true
                // 摆出来了：它当然在库存里，摆放轴到头。
                ownershipFact = .inInventory
                placementFact = .placed
                break
            }
            let delegation = wishMachineCoordinator.placementDelegation(
                worldID: job.worldID, residentScope: job.residentScope, objectID: job.objectID)
            switch delegation?.state {
            case .placed: status = "已摆放"; terminal = true; placementFact = .placed
            case .pending: status = "已领取，等待摆放"; placementFact = .notPlaced
            case .failed:
                status = "摆放失败"; detail = delegation?.lastError; terminal = true
                // 摆放失败不是摆放轴的取值：它只是"还停在低档"，原因由 status/detail 说。
                placementFact = .failed
            case .revoked: status = "摆放已停止"; terminal = true; placementFact = .stopped
            default:
                let assetFailure = residentPropAssetFailures[job.objectID]
                status = ResidentPropInventoryBacklog.status(
                    isInInventory: inInventory,
                    hasAssetFailure: assetFailure != nil,
                    isWaitingForInventory: residentPropInventoryBacklog[job.objectID] != nil)
                // 只有**真的在库存里**才是终态：入库没完成的物件必须一直留在面板上，
                // 不能被 30 秒终态过期藏起来。
                terminal = ResidentPropInventoryBacklog.isTerminal(isInInventory: inInventory)
                // 原因一律可读：要么是"资产没就绪"（模型缺失/校验失败），要么是
                // "入库还没完成"（服务给出的原因 + 会不会自动补做）。
                if let assetFailure {
                    detail = [detail, ResidentPropInventoryBacklog.assetNotice(assetFailure)].compactMap { $0 }.joined(separator: "\n")
                } else if !inInventory, let pending = residentPropInventoryBacklog[job.objectID] {
                    // **只在还没进库存时**挂"等待入库"的详情：进了库存就不许再显示等待态
                    // （台账的清理在同步那条路上；呈现侧也必须自己成立，不依赖清理的时机）。
                    detail = [detail, ResidentPropInventoryBacklog.pendingDetail(pending)].compactMap { $0 }.joined(separator: "\n")
                }
            }
        case .failed: status = "生成失败"; terminal = true
        case .cancelled: status = "已取消"; terminal = true
        case .interrupted: status = "任务已中断"; terminal = true
        }
        if job.cancelRequested == true,
           [.submitting, .submissionUncertain, .generating, .generated].contains(job.stage) {
            status = "取消请求处理中"
        }
        if job.computeMayContinue {
            detail = [detail, "远端计算可能仍在继续。"].compactMap { $0 }.joined(separator: "\n")
        }
        // 「这件东西的尺寸是**怎么定的**」：提交时说过的尺寸意图写进任务行（没有意图的老任务
        // 不因为本契约多出任何一行 —— `sizeIntentLine` 那时是 nil）。用户越界/夹取的原因由
        // 生成入库那一处写进 `residentPropNotices`，两处都不静默。
        if let sizeLine = job.sizeIntentLine {
            detail = [detail, sizeLine].compactMap { $0 }.joined(separator: "\n")
        }
        // 任务级自动续办停止是**授权**，不是任务属性：它不再写进任务行的 detail，
        // 也不再驱动任何按任务的控件；它只驱动面板顶部那条全局横幅
        // （见 `setResidentAutonomyStop` 与 `store.isAutonomyStoppedByUser`）。
        // 任务的 status/detail 从此只说任务自己。
        var generationFact: ResidentTaskAxisProjection.GenerationFact
        switch job.stage {
        case .submitting: generationFact = .submitted
        case .submissionUncertain: generationFact = .submissionUncertain
        case .generating:
            switch job.remoteState {
            case .queued, .submitting, .remotePending: generationFact = .remoteQueued
            case .preflight: generationFact = .remotePreflight
            case .waitingResources: generationFact = .remoteWaitingResources
            default: generationFact = .remoteRunning
            }
        case .generated: generationFact = .downloaded
        case .ready, .claimed: generationFact = .completed
        case .failed: generationFact = .failed
        case .cancelled: generationFact = .cancelled
        case .interrupted: generationFact = .interrupted
        }
        let axes = ResidentTaskAxisProjection.project(generationFact,
            ownership: ownershipFact, placement: placementFact)
        return WishMachineTaskPresentation(id: job.id, title: job.name, status: status, detail: detail,
            isTerminal: terminal, axes: axes, autoContinuationPaused: job.autoContinuationPaused == true)
    }

    private func refreshWishMachine() async {
        configureWishMessageDelivery()
        await wishMachineCoordinator.refreshPending(limit: 2)
        guard !Task.isCancelled else { return }
        synchronizeWishMachinePresentation()
        await synchronizeOwnedResidentProps()
        await refreshWishMachineMessages()
    }

    private func configureWishMessageDelivery() {
        guard !residentWishMessagesConfigured else { return }
        residentWishMessagesConfigured = true
        // The coordinator owns Store.onChange and persists each business projection first.
        wishMachineCoordinator.onChange = { [weak self] in
            guard let self else { return }
            self.synchronizeWishMachinePresentation()
            Task { @MainActor [weak self] in await self?.refreshWishMachineMessages() }
        }
        propGenerationStore.onMessage = { [weak self] consumer, message in
            self?.receiveWishMessage(consumer: consumer, message: message)
        }
        spatialStage.onWishMachineOutputStatusChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.synchronizeWishMachinePresentation()
                await self.refreshWishMachineMessages()
            }
        }
    }

    private func updateWishMessageScope() {
        guard residentWishMessagesConfigured else { return }
        let worldContext = currentResidentWorldContext()
        let next = worldContext.worldID == WishMachineScene.worldID
            ? PropTaskContext(worldID: WishMachineScene.worldID, residentScope: worldContext.sessionScope) : nil
        guard next != residentWishMessageScope else { return }
        if let previous = residentWishMessageScope {
            for consumer in ["world", "ui", "agent"] {
                propGenerationStore.unsubscribeMessages(consumer: consumer, worldID: previous.worldID,
                    residentScope: previous.residentScope)
            }
        }
        residentWishMessageScope = next
        residentWishMessageSubscriptions.removeAll()
        residentWishMessages.removeAll() // Rust retains anything not acknowledged in the old scope.
        residentWishSnapshotPending.removeAll()
        // 本地直达是"本会话此作用域已经送过"的记账：换作用域（含换空间）后新的
        // 居民循环还没见过这些持久事实，必须允许重投一次。
        residentWishLocalFactsQueued.removeAll()
        Task { @MainActor [weak self] in await self?.refreshWishMachineMessages() }
    }

    private func receiveWishMessage(consumer: String, message: PropTaskMessage) {
        guard ["world", "ui", "agent"].contains(consumer) else { return }
        let context = currentResidentWorldContext()
        guard context.worldID == message.worldID, context.sessionScope == message.residentScope,
              message.worldID == WishMachineScene.worldID else { return }
        let delivery = ResidentWishDelivery(id: message.id, consumer: consumer,
            worldID: message.worldID, residentScope: message.residentScope)
        guard !residentWishConsumed.contains(delivery) else {
            if residentWishAcknowledgements.contains(delivery) {
                Task { @MainActor [weak self] in try? await self?.retryWishAcknowledgements() }
            }
            return
        }
        residentWishMessages[delivery] = message
        if message.kind == "task.stateChanged" { residentWishSnapshotPending.insert(message.id) }
        Task { @MainActor [weak self] in await self?.refreshWishMachineMessages() }
    }

    private func refreshWishMachineMessages() async {
        residentWishMessageRefreshRequested = true
        guard !residentWishMessageRefreshRunning else { return }
        residentWishMessageRefreshRunning = true
        defer { residentWishMessageRefreshRunning = false }
        while residentWishMessageRefreshRequested && !Task.isCancelled {
            residentWishMessageRefreshRequested = false
            updateWishMessageScope()
            guard let scope = residentWishMessageScope else { return }
            var failed = false
            for consumer in ["world", "ui", "agent"] where !residentWishMessageSubscriptions.contains(consumer) {
                do {
                    try await propGenerationStore.subscribeMessages(consumer: consumer, worldID: scope.worldID,
                        residentScope: scope.residentScope)
                    guard residentWishMessageScope == scope else {
                        propGenerationStore.unsubscribeMessages(consumer: consumer, worldID: scope.worldID,
                            residentScope: scope.residentScope)
                        break
                    }
                    residentWishMessageSubscriptions.insert(consumer)
                } catch { failed = true }
            }
            guard residentWishMessageScope == scope else { continue }
            if !residentWishSnapshotPending.isEmpty {
                let pending = residentWishSnapshotPending
                await propGenerationStore.refreshSnapshot()
                guard residentWishMessageScope == scope else { continue }
                if propGenerationStore.errorMessage == nil { residentWishSnapshotPending.subtract(pending) }
                else { failed = true }
            }
            synchronizeWishMachinePresentation()
            await synchronizeOwnedResidentProps()
            guard residentWishMessageScope == scope else { continue }
            do { try await publishWishMachineEvents(scope) } catch { failed = true }
            guard residentWishMessageScope == scope else { continue }
            projectWishMessages(scope)
            do { try await retryWishAcknowledgements() } catch { failed = true }
            if failed && !residentWishMessageErrorShown {
                showResidentVoiceStatus("许愿通知暂未完成后台同步，待收消息和确认会继续重试。")
            }
            residentWishMessageErrorShown = failed
        }
    }

    private func publishWishMachineEvents(_ scope: PropTaskContext) async throws {
        for event in wishMachineCoordinator.unpublishedEvents(worldID: scope.worldID, residentScope: scope.residentScope) {
            guard residentWishMessageScope == scope, !Task.isCancelled else { return }
            guard let job = wishMachineCoordinator.residentJobs(worldID: scope.worldID, residentScope: scope.residentScope)
                    .first(where: { $0.id == event.wishID }),
                  let taskID = job.jobID, propGenerationStore.jobs.contains(where: { $0.id == taskID }) else { continue }
            if event.kind == .outputReady {
                guard spatialStage.wishMachineOutput?.id == event.objectID,
                      spatialStage.wishMachineOutputStatus == .ready(id: event.objectID) else { continue }
            }
            let payload = wishMachineEventPayload(event)
            let published = try await propGenerationStore.publishMessage(id: event.id, taskId: taskID,
                worldID: scope.worldID, residentScope: scope.residentScope, kind: "wish." + event.kind.rawValue, payload: payload)
            guard published.id == event.id, published.taskId == taskID, published.worldID == scope.worldID,
                  published.residentScope == scope.residentScope, published.kind == "wish." + event.kind.rawValue,
                  published.payload == payload else { throw PropTaskDaemonError.invalidFrame }
            try wishMachineCoordinator.markEventPublished(id: event.id)
        }
    }

    /// 一条持久事实在消息通道上的载荷。**发布**（守护进程往返）与**本地直达**必须
    /// 用同一份形状，否则同一个事实会因为走哪条通道而给 agent 不同的上下文。
    private func wishMachineEventPayload(_ event: WishMachineEvent) -> [String: PropTaskJSON] {
        var payload: [String: PropTaskJSON] = ["wish_id": .string(event.wishID.uuidString),
            "object_id": .string(event.objectID), "state": .string(event.kind.rawValue),
            "compute_may_continue": .bool(event.computeMayContinue)]
        if let stage = event.stage { payload["stage"] = .string(stage.rawValue) }
        if let remoteState = event.remoteState { payload["remote_state"] = .string(remoteState.rawValue) }
        if let message = event.message { payload["message"] = .string(message) }
        if let cancelRequested = event.cancelRequested { payload["cancel_requested"] = .bool(cancelRequested) }
        if let failureSource = event.failureSource { payload["failure_source"] = .string(failureSource) }
        if let paused = event.autoContinuationPaused { payload["auto_continuation_paused"] = .bool(paused) }
        if let authorizationID = event.continuationResumeAuthorizationID {
            payload["resume_authorization_id"] = .string(authorizationID.uuidString)
        }
        return payload
    }

    private func projectWishMessages(_ scope: PropTaskContext) {
        let context = currentResidentWorldContext()
        guard context.worldID == scope.worldID, context.sessionScope == scope.residentScope else { return }
        let jobs = wishMachineCoordinator.residentJobs(worldID: scope.worldID, residentScope: scope.residentScope)
        let automaticEvents = wishMachineCoordinator.automaticContinuationEvents(
            worldID: scope.worldID, residentScope: scope.residentScope)
        let automaticEventIDs = Set(automaticEvents.map(\.id))
        let resumedEventIDs = Set(automaticEvents.filter { $0.continuationResumeAuthorizationID != nil }.map(\.id))
        for (delivery, message) in residentWishMessages.sorted(by: { $0.value.sequence < $1.value.sequence })
            where delivery.worldID == scope.worldID && delivery.residentScope == scope.residentScope
                && !residentWishConsumed.contains(delivery) && !residentWishSnapshotPending.contains(message.id) {
            guard let job = jobs.first(where: { $0.jobID == message.taskId }) else { continue }
            if delivery.consumer == "world" {
                guard livingWorldContext?.manifest.worldID == scope.worldID else { continue }
                if job.stage == .claimed {
                    guard livingWorldContext?.state.objectStates[job.objectID]?.generatedProp != nil else { continue }
                } else if message.kind == "wish.outputReady" {
                    guard spatialStage.wishMachineOutput?.id == job.objectID,
                          spatialStage.wishMachineOutputStatus == .ready(id: job.objectID) else { continue }
                }
            } else if delivery.consumer == "ui" {
                guard stageWindowController != nil || liveCamWindowController != nil else { continue }
            } else {
                deliverWishFactToAgent(factID: message.id, kind: message.kind, taskID: message.taskId,
                    payload: message.payload, job: job, context: context,
                    automatic: automaticEventIDs.contains(message.id), resumed: resumedEventIDs.contains(message.id))
                continue // Receiving or queuing a notification is not successful consumption.
            }
            residentWishConsumed.insert(delivery)
            residentWishAcknowledgements.insert(delivery)
        }
        // 守护进程消息往返只是**其中一条**通道。事实本身早就耐久地躺在协调器里，
        // 所以这里再走一条**本地直达**：守护进程/隧道不可用时（正是网络故障那段
        // 时间）"东西已经好了"仍然送进居民循环，而不是悄悄躺在磁盘上，等下一次
        // 人类输入或等消息通道复活。授权仍与事实分开：暂停时只投递普通观察。
        projectLocalWishFacts(scope, context: context, automaticEventIDs: automaticEventIDs,
            resumedEventIDs: resumedEventIDs)
    }

    /// 本地持久事实直达 agent 循环。与消息通道共用同一份投递判据
    /// （`deliverWishFactToAgent`），所以"事实通知 vs 自主授权"的分工在两条通道上
    /// 完全一致：不会因为走哪条路而多给或少给一次自主授权。
    private func projectLocalWishFacts(_ scope: PropTaskContext, context: ResidentWorldContext,
                                       automaticEventIDs: Set<UUID>, resumedEventIDs: Set<UUID>) {
        let jobs = wishMachineCoordinator.residentJobs(worldID: scope.worldID, residentScope: scope.residentScope)
        for event in wishMachineCoordinator.pendingEvents(worldID: scope.worldID, residentScope: scope.residentScope) {
            guard !residentWishLocalFactsQueued.contains(event.id) else { continue }
            guard let job = jobs.first(where: { $0.id == event.wishID }), let taskID = job.jobID else { continue }
            // 与发布侧同一条判据：托盘没有真的显示出来之前，"产物就绪"不是既成事实。
            if event.kind == .outputReady {
                guard spatialStage.wishMachineOutput?.id == event.objectID,
                      spatialStage.wishMachineOutputStatus == .ready(id: event.objectID) else { continue }
            }
            deliverWishFactToAgent(factID: event.id, kind: "wish." + event.kind.rawValue, taskID: taskID,
                payload: wishMachineEventPayload(event), job: job, context: context,
                automatic: automaticEventIDs.contains(event.id), resumed: resumedEventIDs.contains(event.id))
            residentWishLocalFactsQueued.insert(event.id)
        }
    }

    /// 把一条已经发生的事实投递给居民循环，并在这里、也只在这里区分两件事：
    /// - **事实通知**：无论暂停与否都入队，下一次人类轮次立刻看得见（不丢掉）；
    /// - **自主行动授权**：只有未被用户停止、且任务级自动续办未被暂停时，才把它
    ///   当成一次可信续办（`receiveContinuationEvent`）交给后台自行执行。
    private func deliverWishFactToAgent(factID: UUID, kind: String, taskID: UUID, payload: [String: PropTaskJSON],
                                        job: WishMachineJob, context: ResidentWorldContext,
                                        automatic: Bool, resumed: Bool = false) {
        guard residentPropEditingWorldID == nil else { return }
        let loop = ensureResidentLoop()
        guard !loop.snapshot.isInvalidated else { return }
        // 停止只停自主行动，不停"事实的入队"：已经发生的事实（产物就绪、失败、
        // 摆放完成）照常排队，供下一次人类明确指令当轮看见并使用。反过来，
        // 停止期间绝不发放自主续办授权（下面的 isStopped 分支只投递普通观察），
        // 因此被停止后不会自行领取、摆放或新建生成。
        // Queue observations even during a turn or an intent pause, so the next
        // human input can see them. The loop still gates autonomous execution;
        // acknowledgement remains tied to successful consumption below.
        bindResidentWishScope(context, loop: loop)
        if kind == "wish.outputReady" && job.stage != .claimed {
            guard spatialStage.wishMachineOutput?.id == job.objectID,
                  spatialStage.wishMachineOutputStatus == .ready(id: job.objectID) else { return }
        }
        var payload = payload
        payload["wish_id"] = .string(job.id.uuidString)
        payload["object_id"] = .string(job.objectID)
        payload["auto_continuation_paused"] = .bool(job.autoContinuationPaused == true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload) else { return }
        let observation = ResidentAgentLoop.Event(id: "wish." + factID.uuidString,
            kind: kind + "." + taskID.uuidString + "." + factID.uuidString,
            summary: String(decoding: data, as: UTF8.self))
        let terminal = ["wish.failed", "wish.cancelled", "wish.interrupted", "wish.placed"].contains(kind)
        if loop.snapshot.isStopped {
            loop.receiveEvent(observation)
        } else if terminal || resumed || (kind == "wish.outputReady" && automatic && job.stage != .claimed) {
            loop.receiveContinuationEvent(observation)
        } else { loop.receiveEvent(observation) }
    }

    private func acknowledgeWishEvents(_ observations: [ResidentAgentLoop.Event], worldContext: ResidentWorldContext) async throws {
        guard worldContext.worldID == WishMachineScene.worldID else { return }
        let current = currentResidentWorldContext()
        guard current.worldID == worldContext.worldID, current.sessionScope == worldContext.sessionScope else { return }
        let consumed = Set(observations.map(\.id))
        for (delivery, _) in residentWishMessages where delivery.consumer == "agent"
            && delivery.worldID == worldContext.worldID && delivery.residentScope == worldContext.sessionScope
            && consumed.contains("wish." + delivery.id.uuidString) {
            residentWishConsumed.insert(delivery)
            residentWishAcknowledgements.insert(delivery)
        }
        try await retryWishAcknowledgements()
    }

    private func retryWishAcknowledgements() async throws {
        var failure: Error?
        for delivery in residentWishAcknowledgements where !residentWishAcknowledging.contains(delivery) {
            let context = currentResidentWorldContext()
            guard context.worldID == delivery.worldID, context.sessionScope == delivery.residentScope else { continue }
            residentWishAcknowledging.insert(delivery)
            do {
                try await propGenerationStore.acknowledgeMessage(id: delivery.id, consumer: delivery.consumer,
                    worldID: delivery.worldID, residentScope: delivery.residentScope)
                residentWishAcknowledgements.remove(delivery)
                residentWishMessages.removeValue(forKey: delivery)
            } catch { failure = error }
            residentWishAcknowledging.remove(delivery)
        }
        if let failure { throw failure }
    }

    private func wishMachinePromptContext(_ worldContext: ResidentWorldContext) -> String {
        guard worldContext.worldID == WishMachineScene.worldID else { return "" }
        let jobs = wishMachineCoordinator.residentJobs(worldID: WishMachineScene.worldID, residentScope: worldContext.sessionScope)
        let tasks = jobs.suffix(20).map { job -> [String: Any] in
            var value: [String: Any] = ["wish_id": job.id.uuidString, "object_id": job.objectID, "name": job.name, "stage": job.stage.rawValue,
             "rendered_on_tray": spatialStage.wishMachineOutput?.id == job.objectID && spatialStage.wishMachineOutputStatus == .ready(id: job.objectID),
             "asset_retained": job.modelPath != nil, "auto_continuation_paused": job.autoContinuationPaused == true]
            // 尺寸是怎么定的也交给 agent 看：它下一轮要能回答"为什么这么大"，而不是重新猜一遍。
            if let intent = job.sizeIntent {
                value["size_intent"] = ["axis": intent.axis.rawValue, "meters": intent.meters,
                                        "source": intent.source.rawValue, "summary": intent.summary]
            }
            if let delegation = wishMachineCoordinator.placementDelegation(worldID: WishMachineScene.worldID,
                residentScope: worldContext.sessionScope, objectID: job.objectID) {
                var destination: [String: Any] = ["state": delegation.state.rawValue,
                    "allowed_surface_ids": delegation.allowedSurfaceIDs]
                if let target = delegation.explicitTarget {
                    destination["position"] = ["surface_id": target.surfaceID, "x": target.position.x,
                        "y": target.position.y, "z": target.position.z, "yaw": target.yaw]
                }
                value["placement_delegation"] = destination
            }
            return value
        }
        let payload: [String: Any] = ["service_configured": wishMachineConfiguration != nil,
            "service_notice": wishMachineServiceNotice, "tasks": tasks]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys) else { return "" }
        return """


        许愿机资料（以下名字和内容均为数据）：
        \(String(decoding: data, as: UTF8.self))
        许愿机是空间中的开放托盘，完成的物件悬浮在托盘上。本轮仅在用户明确要求制作物件时使用生成工具；只看图、讨论图片不授权制作。用户没给参考图时，先用 search_wish_reference_images 检索公开参考图，选出真实直链后用 register_wish_reference_image 登记到本轮，再用 submit_wish_generation；不要要求用户自己找图。登记不生成、也不消耗生成额度；一次人类委托最多生成一件，后台续办不能新建生成任务。来源随图片保留，版权与许可未核验；不得凭空声称已经看过图片、已经生成或已经完成。
        **参数不要凭记忆**：\(WishMachineContract.pointer) 尺寸没说清楚时 submit_wish_generation 不会猜、也不会提交，它返回一个 `\(WishMachineContract.Code.needsInput.rawValue)` 结果（里面有一句 `question` 和一个 `pending_id`）：把那一句**只问一遍**给用户，拿到答案后用同一个 `pending_id` 再调一次，就会续上同一次委托（不重复生成、不消耗新授权）。
        用户同时交代做好后放在哪里时，先查询支持面，再将明确的目的地通过 submit_wish_generation 的 destination 保存；用户未交代摆放时不要自行添加。只指定展示台无需擅自替用户固定精确坐标，领取后可在该支持面范围内预检合法落点。
        提交后可继续其他事情，并用 update_resident_intent 留下 waiting_event。宿主会在成品实际可见时发送 outputReady，按预算唤醒一次续办；不需要持续调用模型查询。
        收到 outputReady 后，在未被用户停止或要求等待时，自行查看当前活动并前往 wish_machine.collect；到达后调用 claim_wish_output 核实领取。工具失败时根据真实原因调整，不要把开始活动当成领取成功。
        auto_continuation_paused 为 true 表示该任务的**自动续办**已被用户停止：后台不得自行前往领取或摆放，只保留任务与产物；这**不是**对该任务的永久封禁。本轮人类明确下令领取该物件时，直接按令前往并 claim_wish_output 即可，不需要先调用 resume_wish_continuation；普通聊天不恢复旧委托。按令领取不会自动重新打开自动续办。
        claimed 表示领取登记，宿主还需将校验过的物件保存进库存。用 read_owned_props 核对入库，不要因暂无库存再次生成。
        当前支持面可用 list_placement_surfaces 查询，物件位置为底中心、yaw 为弧度。后台仅可续办 placement_delegation.state 为 pending 的原摆放委托：只摆本次产物、只用允许支持面，并遵守用户指定的精确位置和朝向。领取并用 read_owned_props 核实入库后，查询 layout_revision、预检、调用 apply_prop_placement，直到工具确认。放不下时在委托允许范围内调整；仍放不下就留在库存并说明。placed、revoked 或 failed 的委托不再自动执行。其他移动、收回、手持或撤销仍需本轮人类明确指令。
        resume_wish_continuation 只用于把该任务的**自动续办**（后台自行领取与摆放）重新打开，它不是领取已就绪产物的前置条件。用户本轮明确要求恢复指定许愿时，先调用 resume_wish_continuation（指定 wish_id 并确认恢复），仅在成功回执后说明该许愿授权已恢复；随后需要自主续办时，再调用 update_resident_intent 并设置 resume_paused_intent=true。仅更新居民意图不会恢复许愿授权。普通聊天或后台通知不得恢复暂停任务。已实际摆好的物件无需重复领取或摆放。
        生成物件目前只有外形，没有冲泡或战斗功能。正式领取且最长边不超过 \(ResidentPropAttachmentEligibility.holdableLongestEdgeText)的小道具，可由当前已适配的 2B 角色拿在右手、挂在背后或挂在腰间：hold_prop 的 slot 参数决定挂点（rightHand 拿在手里 / back 挂在背后 / waist 挂在腰间），用户说"挂背后 / 挂腰上 / 拿手里"时选对应项，已经拿在手上的同一件物件换挂点也用它；操作必须依次使用正式工具 hold_prop、adjust_held_prop_grip、return_held_prop，其中微调按需执行。只依据工具回执说明结果（回执里的 held_slot_name 就是它现在挂在哪儿），其他角色或更大物件仍只能摆放。
        """
    }

    private enum ResidentSubmissionSource { case stage, liveCam }

    private func sendResidentSubmission(_ submission: ResidentChatSubmission, source: ResidentSubmissionSource) async throws {
        guard residentPropEditingWorldID == nil else { throw ResidentPropHostError.editorOpen }
        let imageURLs = submission.attachments.map(\.url)
        // **居民图片链[2] 提交**的日志不在这里：这个方法被多个离线 harness 原文抽取
        // 编译（test-living-resident-loop / test-resident-loop-app /
        // test-resident-submission-recovery），不属于本方法的日志设施会让它们编不过。
        // [2] 由 `ResidentAgentLoop.receiveUserMessage`（紧跟其后的同一入口）与
        // [4]/[7]（`AgentConversationService.validateImageSupport` / `send`）打出。
        try AgentConversationService.shared.validateImageSupport(imageURLs: imageURLs)
        disconnectRealtimeVoice()
        let loop = ensureResidentLoop()
        // 用户已接手：旧的「未确认送达」提示不再显示；模型上下文仍保留这些条目，
        // 居民不会被要求重复执行。
        residentUnconfirmedNotice.acknowledge(loop.snapshot.unconfirmedUserMessages)
        let submissionWorld = currentResidentWorldContext()
        let worldScope = submissionWorld.sessionScope
        registerWishImages(submission.attachments, loop: loop, worldScope: worldScope)
        // 可见历史：先登记这次真实提交（作用域随世界/后端隔离），回合结论由
        // 真正送达/失败/取消更新同一个回合，绝不重复显示。
        residentChatTranscript.activate(scopeKey: residentTranscriptScopeKey)
        residentChatTranscript.beginTurn(id: submission.id, userText: submission.text,
                                         at: submission.createdAt)
        publishResidentTranscript()
        loop.receiveUserMessage(submission.text, imageURLs: imageURLs, submissionID: submission.id,
                                onUndelivered: { [weak self, weak loop] in
            guard let self, let loop, self.residentAgentLoop === loop,
                  !loop.snapshot.isInvalidated,
                  self.currentResidentWorldContext().sessionScope == worldScope,
                  self.currentResidentWorldContext().worldID == submissionWorld.worldID else { return }
            self.residentChatTranscript.markCancelled(ids: [submission.id])
            self.publishResidentTranscript()
            let notice = "已停止，未送达图文已回到输入框，未自动重发。"
            switch source {
            case .stage: self.stageWindowController?.restoreResidentSubmission(submission, notice: notice)
            case .liveCam: self.liveCamWindowController?.restoreResidentSubmission(submission, notice: notice)
            }
        }, onFailure: { [weak self, weak loop] failure in
            guard let self, let loop, self.residentAgentLoop === loop,
                  !loop.snapshot.isStopped, !loop.snapshot.isInvalidated,
                  self.currentResidentWorldContext().sessionScope == worldScope else { return }
            self.residentChatTranscript.markFailed(ids: [submission.id])
            self.publishResidentTranscript()
            let notice = "本轮未完成：\(failure)\n可能已有部分操作发生。请确认现场后再发送。"
            switch source {
            case .stage: self.stageWindowController?.restoreResidentSubmission(submission, notice: notice)
            case .liveCam: self.liveCamWindowController?.restoreResidentSubmission(submission, notice: notice)
            }
        })
    }

    private func performResidentTurn(_ input: ResidentAgentLoop.Input) async throws -> String {
        guard residentPropEditingWorldID == nil else { throw ResidentPropHostError.editorOpen }
        let messageID = input.runID
        guard residentAgentLoop?.isCurrent(runID: messageID) == true else { throw CancellationError() }
        avatarRuntime.beginResidentThinking(runID: messageID)
        defer { avatarRuntime.endResidentThinking(runID: messageID) }
        let worldContext = currentResidentWorldContext()
        if let loop = residentAgentLoop { bindResidentWishScope(worldContext, loop: loop) }
        try reconcileResidentWishPlacements(worldContext)
        let requestWorld = livingWorldContext
        liveCamMessageID = messageID
        defer { if liveCamMessageID == messageID { liveCamMessageID = nil } }
        let wishAuthorizationID = try authorizeWishImages(input, worldContext: worldContext)
        // 奉命轮 = 本轮由人类输入发起，或后台 run 已被人类引导接手。领取授权
        // 按每次工具调用实时求值：停止只停自主，不吊销人类当轮的明确指令。
        let worldTools = makeResidentWorldTools(messageID: messageID, wishAuthorizationID: wishAuthorizationID,
            allowsPausedWishClaim: !input.isBackground,
            humanOrderedClaim: { [weak self] in
                guard let self else { return false }
                return !input.isBackground || self.residentAgentLoop?.runHasHumanInput(runID: messageID) == true
            },
            allowsPropMutation: !input.isBackground)
        defer {
            worldTools?.cancel()
        }
        let finishCancellation: @MainActor () -> Void = { [weak self] in
            worldTools?.cancel()
            guard let self, self.liveCamMessageID == messageID else { return }
            self.liveCamMessageID = nil
        }
        let reply: String
        // 真实用户文字只来自 input.userMessages（键盘/语音最终转写）；后台/自驱轮
        // 没有真实输入时为 nil，绝不把 input.promptText（宿主拼装上下文）入库。
        let realUserText = input.userMessages.isEmpty
            ? nil : input.userMessages.joined(separator: "\n")
        do {
            let prompt = worldTools == nil ? input.userMessages.joined(separator: "\n") : input.promptText
            reply = try await AgentConversationService.shared.send(
                prompt + (worldTools == nil ? "" : wishMachinePromptContext(worldContext)),
                imageURLs: input.imageURLs,
                worldContext: worldContext, worldTools: worldTools,
                userMessage: realUserText,
                onCancel: finishCancellation
            )
        } catch AgentConversationError.cancelled {
            throw CancellationError()
        }
        guard liveCamMessageID == messageID,
              residentAgentLoop?.isCurrent(runID: messageID) == true else { throw CancellationError() }
        guard currentResidentWorldContext().sessionScope == worldContext.sessionScope,
              currentResidentWorldContext().worldID == worldContext.worldID,
              worldTools == nil || livingWorldContext === requestWorld else {
            finishCancellation()
            throw CancellationError()
        }
        // 原文层移除后这里不再登记"本轮交付凭据"（原 `registerResidentMemoryTurn`）：
        // 凭据的唯一用途是之后调 `confirmDeliveredTurn` 去 `memory_ingest`，那条链
        // 已整体删除。守卫本身保留——它仍然保护下面那些**真正写东西**的动作
        // （确认许愿通知、同步面板）。
        //
        // 这里**不再**给用户任何"记忆"提示：长期记忆已由用户决定不做，
        // 界面上不该出现一个不会有的能力的说明（见 `test-no-long-term-memory-capability`）。
        if !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || residentAgentLoop?.allowsSilentCompletion(runID: input.runID) == true {
            do { try await acknowledgeWishEvents(input.events, worldContext: worldContext) }
            catch {
                showResidentVoiceStatus("本轮回复已完成，许愿通知的确认暂未保存；正在重试保存，不会重复执行本轮操作。")
            }
        }
        synchronizeWishMachinePresentation()
        return reply
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

    private func makeMusicLibraryAgentService() -> MusicLibraryAgentService {
        let selectedWorld = spatialStage.selectedWorldID
        let context = livingWorldContext
        let runtime = musicRuntime
        let selectionGeneration = musicSelectionGeneration
        return MusicLibraryAgentService(
            store: musicLibraryStore,
            fetchPage: { provider, playlistID, offset, limit in
                return try await runtime.fetchPlaylistPage(providerID: provider,
                    playlistID: playlistID, offset: offset, limit: limit)
            },
            makeQueue: {
                // Preparation owns a private queue until the selection is ready.
                return ProgramPlaybackQueue(preflight: PlaybackPreflight(
                    preparer: MusicRuntimePlaybackPreparer(runtime: runtime)), lockedCapacity: 0)
            },
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && spatialStage.selectedWorldID == selectedWorld
                    && livingWorldContext === context
                    && musicSelectionGeneration == selectionGeneration
            },
            commit: { [weak self] plan, queue, index in
                guard let self else { throw CancellationError() }
                guard musicSelectionGeneration == selectionGeneration else {
                    throw DJAgentMusicLibraryError.interrupted
                }
                try commitMusicLibraryPreparation(plan: plan, queue: queue, index: index)
            }
        )
    }

    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage {
        try makeMusicLibraryAgentService().list(query: query, offset: offset, limit: limit)
    }

    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        try await makeMusicLibraryAgentService().read(playlistID: playlistID, offset: offset, limit: limit)
    }

    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        guard !isPreparingMusicLibraryTrack, !isStartingProgramPlayback else {
            throw DJAgentMusicLibraryError.busy
        }
        isPreparingMusicLibraryTrack = true
        defer { isPreparingMusicLibraryTrack = false }
        return try await makeMusicLibraryAgentService().prepare(playlistID: playlistID, trackID: trackID)
    }

    private func commitMusicLibraryPreparation(plan: ProgramPlan, queue: ProgramPlaybackQueue, index: Int) throws {
        try Task.checkCancellation()
        guard !isStartingProgramPlayback else { throw DJAgentMusicLibraryError.busy }
        musicSelectionGeneration &+= 1
        localMusicPlayer.stop()
        residentJukeboxPlaybackOwner = nil
        committedPlaybackTrack = nil
        activeProgram = plan
        programPlaybackQueue = queue
        programStore.publish(plan)
        programStore.activateSlot(at: index)
        stageWindowController?.setPlaybackState(.ready)
        updateStageProgramNavigation()
    }

    func playProgramTrack(
        trackID: String?,
        slotIndex: Int?
    ) async throws {
        musicSelectionGeneration &+= 1
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
        residentJukeboxPlaybackOwner = nil
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
        musicSelectionGeneration &+= 1
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
        musicSelectionGeneration &+= 1
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
        musicSelectionGeneration &+= 1
        residentJukeboxPlaybackOwner = nil
        guard localMusicPlayer.state == .playing else {
            return
        }
        localMusicPlayer.pause()
        orbWindowController?.setState(.idle)
        stageWindowController?.setPlaybackState(.paused)
    }

    func resumeMusic() async throws {
        try Task.checkCancellation()
        musicSelectionGeneration &+= 1
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
            residentJukeboxPlaybackOwner = ResidentActivityOutcome.playbackOwner
            try localMusicPlayer.play()
            try await confirmAudiblePlayback(reason: "resumeLocal")
            orbWindowController?.setState(.playing)
            stageWindowController?.setPlaybackState(.playing)
        case .startPreparedProgram:
            try await startSelectedProgramPlayback(
                requestOpening: false,
                allowFallback: false
            )
            try await confirmAudiblePlayback(reason: "startPreparedProgram")
        case .unavailable:
            throw DJAgentRadioActionError.noProgram
        }
    }

    /// 「真的出声了」的判据与日志：音频图自报在播，**而且播放位置在前进**。
    ///
    /// 过去这里只认自己记的 `localMusicPlayer.state`：`AVAudioPlayerNode.play()` 一被
    /// 调用状态就变成 `.playing`，于是"操作被接受、曲目也备好、扬声器没有声音"在代码
    /// 里和"放得好好的"完全一样。位置不动就是没出声，必须抛出去，不能记成成功。
    private func confirmAudiblePlayback(reason: String) async throws {
        let observed = try await localMusicPlayer.confirmPlaybackProgress()
        playbackLogger.info(
            "点唱机出声证据：reason=\(reason, privacy: .public)，isPlaying=\(self.localMusicPlayer.isGraphPlaying)，position=\(observed.start, format: .fixed(precision: 3))→\(observed.current, format: .fixed(precision: 3))，track=\(self.localMusicPlayer.track?.title ?? "nil", privacy: .public)"
        )
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
        musicSelectionGeneration &+= 1
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
        residentJukeboxPlaybackOwner = nil
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
        musicSelectionGeneration &+= 1
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
                    musicSelectionGeneration &+= 1
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
            "当前没有已准备的播放节目。"
        case .noPreparedProgram:
            "后台还没有准备好可切换的新节目"
        case .trackNotFound:
            "节目中找不到这首歌"
        case .busy:
            "播放器正在切歌，请稍后再试"
        }
    }
}

/// 「已领取 → 入库」这条链**唯一的一份**事实与文案，外加"被拒之后补做"的台账。
///
/// 为什么必须收在一处：真机 2026-10-01 的缺陷是**两个投影各读各的事实**——
/// 任务行与系统消息读"模型已备好"（`residentOwnedPropAssets`，由 prepare 写），于是显示
/// "已领取并入库"；而「我的物件」列表读库存（`state.objectStates`），里面**没有**这件东西。
/// 两处于是可以同时为真：用户看到"已进库存"，列表里却找不到（`2B 白色长剑`：
/// `WishMachine/wishes.json` stage=claimed、资产 sha256 与回执一致、
/// `layoutReceipts` 里没有 `claimed.<jobID>`、`state.json` 的 `objectStates` 里没有它）。
///
/// 现在两边都从**库存记录**派生（见 `status(isInInventory:hasAssetFailure:isWaitingForInventory:)`
/// 与 `residentPropEditorSnapshot`），所以"说已入库"与"列表里有"不可能再矛盾。
///
/// 是 `struct` 而不是无 case 的 `enum`：它既是一组静态判定，也是**一份状态**
/// （`pending`），而 `struct` 的隐式逐成员初始化让 `ResidentPropInventoryBacklog()`
/// 直接成立（无 case 的 `enum` 没有隐式初始化器）。
struct ResidentPropInventoryBacklog {
    /// 一件"已领取但还没写进库存"的物件。幂等键是 `objectID`（同一件只留一条）。
    struct Pending: Equatable, Sendable {
        let objectID: String
        let name: String
        /// 服务给出的可读原因，**逐字保留**（fail-closed 的文案是判定的一部分）。
        let reason: String
        /// 这次被拒是不是"承托几何还没就绪"。是 ⇒ 几何一就绪就补做。
        let waitsForSupportGeometry: Bool

        init(objectID: String, name: String, reason: String, waitsForSupportGeometry: Bool) {
            self.objectID = objectID; self.name = name; self.reason = reason
            self.waitsForSupportGeometry = waitsForSupportGeometry
        }
    }

    /// `environmentNotReady` 的**分类**（不是放宽）：拿不到承托几何/路线数据时，
    /// 摆放服务仍然 fail-closed 拒绝写入，只是这条拒绝"还会好"。
    ///
    /// 判定一个字都没改，改的只是"被拒之后不许静默、不许没人补做"。分类在**调用点**
    /// 做（`(error as? ResidentPropPlacementError) == .environmentNotReady`，见
    /// `synchronizeOwnedResidentProps`），这里刻意不依赖任何错误类型 —— 于是这份
    /// 台账与文案是纯逻辑，任何 harness 都能逐字编译它来验证。

    /// 补做的条件：还不在库存里 **且** 承托几何已就绪。
    static func shouldRetry(isInInventory: Bool, isSupportGeometryReady: Bool) -> Bool {
        !isInInventory && isSupportGeometryReady
    }

    /// 任务行/系统消息的状态文字。
    ///
    /// 「已入库」字样**只在 `isInInventory`（= `objectStates` 里有带 `generatedProp` 的那一项，
    /// 也就是「我的物件」列表读的同一份事实）时**才允许出现；资产没备好是**另一条**事实
    /// （能不能摆），单独说，不冒充库存。
    static func status(isInInventory: Bool, hasAssetFailure: Bool, isWaitingForInventory: Bool) -> String {
        if isInInventory { return hasAssetFailure ? "已入库，资产未就绪" : "已领取并入库" }
        return isWaitingForInventory ? "已领取，等待入库" : "领取后入库中"
    }

    /// 终态只由**库存记录**决定：入库没完成的物件必须一直留在面板上，不许被
    /// 30 秒终态过期藏掉（真机缺陷的第二半：那句话本身是假的，随后连假话都看不见了）。
    static func isTerminal(isInInventory: Bool) -> Bool { isInInventory }

    /// 提示区的可见文案。**绝不静默**：说清原因，并说清会不会自己好。
    static func pendingNotice(_ pending: Pending) -> String {
        let tail = pending.waitsForSupportGeometry ? "空间就绪后会自动补做。" : "会在下一次同步时重试。"
        return "\(pending.name) 已领取，入库尚未保存：\(pending.reason)\(tail)"
    }

    /// 任务行的详情：与 `pendingNotice` 同一份原因，只是不带名字（行上已有标题）。
    static func pendingDetail(_ pending: Pending) -> String {
        let tail = pending.waitsForSupportGeometry ? "空间就绪后会自动补做。" : "会在下一次同步时重试。"
        return "入库尚未保存：\(pending.reason)\(tail)"
    }

    /// 资产（模型文件）真的坏了时的可读原因。库存里有它、现在却摆不出来的物件
    /// 必须**说得出来为什么**，而不是从列表里消失或假装能用。
    static func assetNotice(_ reason: String) -> String { "资产未就绪：\(reason)" }

    /// 补做**一次**：返回这次该补做的物件编号（升序）。几何没就绪、或台账为空时返回 `[]`。
    ///
    /// 幂等的第 1 层：几何没就绪一件都不补；已经在库存里的条目顺手从台账移除
    /// （不需要补，也不该继续挂着"等待入库"）。第 2、3 层在写入那条路上：
    /// `synchronizeOwnedResidentProps` 按 `objectStates` 跳过已在库的，提交用的是
    /// 既有的回执键 `claimed.<jobID>`（`WorldSimulation.applyPropLayout` 按回执去重）。
    /// 所以"重复触发写两遍"在状态层不可能发生。
    mutating func drain(isSupportGeometryReady: Bool, isInInventory: (String) -> Bool) -> [String] {
        var attempted: [String] = []
        for objectID in pending.keys.sorted() {
            guard let entry = pending[objectID] else { continue }
            if !Self.shouldRetry(isInInventory: isInInventory(entry.objectID), isSupportGeometryReady: isSupportGeometryReady) {
                if isInInventory(entry.objectID) { pending.removeValue(forKey: entry.objectID) }
                continue
            }
            attempted.append(entry.objectID)
        }
        return attempted
    }

    /// key = objectID：同一件东西重复记录只留一条（覆盖原因与名字）。
    private(set) var pending: [String: Pending] = [:]
    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }
    subscript(objectID: String) -> Pending? { pending[objectID] }

    mutating func record(_ value: Pending) { pending[value.objectID] = value }
    /// 入库成功：清掉待办，并回答"之前是不是挂着一条待办"——是 ⇒ 调用方必须
    /// **收回**那句"入库尚未保存"并给出结果，而不是让旧提示留在屏幕上。
    @discardableResult mutating func resolve(objectID: String) -> Bool {
        pending.removeValue(forKey: objectID) != nil
    }
    /// 库存里已经有它了（重启后第一次同步就补做成功、或在别的路径上进库）：
    /// 台账不该再挂着它。**可见状态必须跟着事实消失**，而不是留在屏幕上。
    mutating func prune(isInInventory: (String) -> Bool) {
        pending = pending.filter { !isInInventory($0.key) }
    }
}
