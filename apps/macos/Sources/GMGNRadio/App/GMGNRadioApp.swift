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
            Button("Exit Immersive Visuals") {
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
    private var orbWindowController: OrbWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = OrbWindowController()
        orbWindowController = controller
        controller.show()

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
    }

    func exitImmersiveVisuals() {
        orbWindowController?.exitImmersiveVisuals()
    }
}
