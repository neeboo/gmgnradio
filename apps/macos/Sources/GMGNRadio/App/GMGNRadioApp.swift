import AppKit
import SwiftUI

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
            Button("打开 360°舞台") {
                (NSApplication.shared.delegate as? AppDelegate)?
                    .showStage()
            }
            Button("关闭 360°舞台") {
                (NSApplication.shared.delegate as? AppDelegate)?
                    .closeStage()
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
                (NSApplication.shared.delegate as? AppDelegate)?
                    .exitImmersiveVisuals()
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audioFeatures = VisualAudioFeatureStore()
    private let stagePresentation = StagePresentationModel()
    private let realtimeDJSessionController = RealtimeDJSessionController()
    private var orbWindowController: OrbWindowController?
    private var stageWindowController: StageWindowController?
    private var stageAudioMonitor: VisualAudioInputMonitor?
    private var stagePresentationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = OrbWindowController(audioFeatures: audioFeatures)
        orbWindowController = controller
        controller.show()
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

    func exitImmersiveVisuals() {
        orbWindowController?.exitImmersiveVisuals()
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
