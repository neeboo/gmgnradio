import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProductIdentity {
    static let displayName = "gmgn radio"
    static let bundleIdentifier = "ai.gmgn.radio"
}

@main
struct GMGNRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra(ProductIdentity.displayName, systemImage: "waveform.circle.fill") {
            Button("开始 AI 电台") {
                AppMenuAction.startAIProgram.perform(on: appDelegate)
            }
            Divider()
            Button("播放本地音乐…") {
                AppMenuAction.chooseLocalTrack.perform(on: appDelegate)
            }
            Button("暂停 / 继续音乐") {
                AppMenuAction.toggleLocalPlayback.perform(on: appDelegate)
            }
            Divider()
            Button("打开 360°舞台") {
                AppMenuAction.showStage.perform(on: appDelegate)
            }
            Button("关闭 360°舞台") {
                AppMenuAction.closeStage.perform(on: appDelegate)
            }
            Divider()
            Button("设置…") {
                SettingsMenuAction(
                    openSettings: { openSettings() },
                    scheduleActivation: { activation in
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            activation()
                        }
                    },
                    activateApplication: {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    },
                    revealSettingsWindow: {
                        guard let window = NSApplication.shared.windows.first(where: {
                            $0.styleMask.contains(.titled)
                        }) else {
                            return
                        }
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                    }
                ).perform()
            }
            Button("退出桌面背景") {
                AppMenuAction.exitImmersiveVisuals.perform(on: appDelegate)
            }
            Divider()
            Button("Quit gmgn radio") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            GMGNSettingsView {
                AppMenuAction.startAIProgram.perform(on: appDelegate)
            }
                .frame(minWidth: 540, minHeight: 440)
        }
        .defaultSize(width: 580, height: 500)
    }
}

@MainActor
protocol GMGNApplicationControlling: AnyObject {
    func startAIProgram()
    func showStage()
    func closeStage()
    func chooseLocalTrack()
    func toggleLocalPlayback()
    func exitImmersiveVisuals()
}

enum AppMenuAction: Sendable {
    case startAIProgram
    case showStage
    case closeStage
    case chooseLocalTrack
    case toggleLocalPlayback
    case exitImmersiveVisuals

    @MainActor
    func perform(on controller: any GMGNApplicationControlling) {
        switch self {
        case .startAIProgram:
            controller.startAIProgram()
        case .showStage:
            controller.showStage()
        case .closeStage:
            controller.closeStage()
        case .chooseLocalTrack:
            controller.chooseLocalTrack()
        case .toggleLocalPlayback:
            controller.toggleLocalPlayback()
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
        openSettings()
        scheduleActivation {
            activateApplication()
            revealSettingsWindow()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, GMGNApplicationControlling {
    private let audioFeatures = VisualAudioFeatureStore()
    private let stagePresentation = StagePresentationModel()
    private let stageVisualDirections = StageVisualDirectionStore()
    private let programStore = DJProgramStore.shared
    private let stageLyrics = StageLyricsStore.shared
    private let realtimeDJSessionController = RealtimeDJSessionController()
    private lazy var musicRuntime = MusicRuntime.live()
    private lazy var audioGraph = AudioGraphController(
        visualStore: audioFeatures
    )
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
    private var stageAudioMonitor: VisualAudioInputMonitor?
    private var stagePresentationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = OrbWindowController(audioFeatures: audioFeatures)
        orbWindowController = controller
        controller.show()
        interruptionCoordinator = InterruptionCoordinator(
            audio: audioGraph,
            interruptSession: { [weak self] in
                try? await self?.realtimeDJSessionController.interrupt()
            },
            updateState: { [weak self] state in
                self?.orbWindowController?.setState(state)
            }
        )
        configureStage()

        let environment = ProcessInfo.processInfo.environment
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
        }
        if let trackPath = environment["GMGN_LOCAL_TRACK"] {
            do {
                try playLocalTrack(URL(fileURLWithPath: trackPath))
            } catch {
                presentPlaybackError(error)
            }
        }
    }

    func showStage() {
        if stageWindowController == nil {
            configureStage()
        }
        stageWindowController?.show()
    }

    func startAIProgram() {
        orbWindowController?.setState(.thinking)
        activeProgram = nil
        updateStageProgramNavigation()
        programStore.beginPlanning()
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let agent = try CodexTrackRankingAgent.live()
                let brief = Self.currentProgramBrief()
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
        switch localMusicPlayer.state {
        case .playing:
            localMusicPlayer.pause()
            orbWindowController?.setState(.idle)
            stageWindowController?.setPlaybackState(.paused)
        case .ready, .paused, .finished:
            do {
                try localMusicPlayer.play()
                orbWindowController?.setState(.playing)
                stageWindowController?.setPlaybackState(.playing)
            } catch {
                presentPlaybackError(error)
            }
        case .idle:
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
        if loadSidecarLyrics {
            publishSidecarLyrics(for: url)
        }
        try localMusicPlayer.load(url)
        try localMusicPlayer.play()
        orbWindowController?.setState(.playing)
        stageWindowController?.setPlaybackState(.playing)
        showStage()
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
        alert.messageText = "DJ 暂时排不了节目"
        alert.informativeText = error.localizedDescription
        alert.runModal()
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
        _ initial: PreparedProgramPlayback
    ) async throws {
        var prepared: PreparedProgramPlayback? = initial
        while let candidate = prepared {
            do {
                try await playPrepared(candidate)
                return
            } catch {
                prepared = await programPlaybackQueue
                    .replaceCurrentAfterFailure()
            }
        }
        throw ProgramPlaybackQueueError.noPlayableSlots(
            failedTrackIDs: programPlaybackQueue.failedTrackIDs
        )
    }

    private func playPrepared(
        _ prepared: PreparedProgramPlayback
    ) async throws {
        guard let activeProgram else { return }
        let slot = prepared.slot
        guard let index = activeProgram.slots.firstIndex(where: {
            $0.track.id == slot.track.id
        }) else {
            return
        }

        programStore.activateSlot(at: index)
        stageLyrics.clear()
        stageVisualDirections.update(
            ProgramVisualDirector().cue(for: slot)
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
            stageLyrics.publish(lyrics, trackID: lyricTrackID)
        }

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
            showStage()
        }
        updateStageProgramNavigation()
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
            hostHint: current.hostHint,
            hostPreference: DJAgentPreferences().hostPrompt(),
            immediateUserInstruction:
                plan.brief.immediateUserInstruction
        )
        stagePresentation.apply(context)
        try? await realtimeDJSessionController.updateContext(context)
    }

    private static func currentProgramBrief(
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
            conversationMode: .ambient
        )
    }

    private func configureStage() {
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
            audioMonitor: monitor,
            presentation: stagePresentation,
            visualDirections: stageVisualDirections,
            programStore: programStore,
            lyrics: stageLyrics,
            playbackPosition: { [weak self] in
                self?.audioGraph.playbackPosition ?? 0
            },
            playbackState: localMusicPlayer.state,
            onTogglePlayback: { [weak self] in
                self?.toggleLocalPlayback()
            },
            onPreviousTrack: { [weak self] in
                self?.playPreviousProgramTrack()
            },
            onNextTrack: { [weak self] in
                self?.playNextProgramTrack()
            }
        )
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
                await interruptionCoordinator?.consume(event)
                stagePresentation.consume(event)
            }
        }
    }

    private func updateStageProgramNavigation() {
        let hasProgram = activeProgram != nil
        stageWindowController?.setProgramNavigation(
            canGoPrevious: hasProgram
                && programPlaybackQueue.canReturnToPrevious,
            canGoNext: hasProgram && programPlaybackQueue.canAdvance
        )
    }

    private func publishSidecarLyrics(for audioURL: URL) {
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
            trackID: audioURL.path
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
}
