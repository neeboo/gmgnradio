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
            Button("桌宠设置…") {
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
            PresenceSettingsView()
                .frame(minWidth: 540, minHeight: 440)
        }
        .defaultSize(width: 580, height: 500)
    }
}

@MainActor
protocol GMGNApplicationControlling: AnyObject {
    func showStage()
    func closeStage()
    func chooseLocalTrack()
    func toggleLocalPlayback()
    func exitImmersiveVisuals()
}

enum AppMenuAction: Sendable {
    case showStage
    case closeStage
    case chooseLocalTrack
    case toggleLocalPlayback
    case exitImmersiveVisuals

    @MainActor
    func perform(on controller: any GMGNApplicationControlling) {
        switch self {
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
    private let realtimeDJSessionController = RealtimeDJSessionController()
    private lazy var audioGraph = AudioGraphController(
        visualStore: audioFeatures
    )
    private lazy var localMusicPlayer = LocalMusicPlayer(graph: audioGraph)
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
        case .ready, .paused, .finished:
            try? localMusicPlayer.play()
            orbWindowController?.setState(.playing)
        case .idle:
            break
        }
    }

    func exitImmersiveVisuals() {
        orbWindowController?.exitImmersiveVisuals()
    }

    private func playLocalTrack(_ url: URL) throws {
        try localMusicPlayer.load(url)
        try localMusicPlayer.play()
        orbWindowController?.setState(.playing)
        showStage()
    }

    private func presentPlaybackError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "这首音乐暂时播放不了"
        alert.informativeText = error.localizedDescription
        alert.runModal()
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
            presentation: stagePresentation
        )

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
        try await realtimeDJSessionController.updateContext(context)
    }
}
