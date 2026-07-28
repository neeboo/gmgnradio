import AppKit
import SwiftUI

enum ProductIdentity {
    static let displayName = "gmgn radio"
    static let bundleIdentifier = "ai.gmgn.radio"
}

@main
struct GMGNRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(ProductIdentity.displayName, systemImage: "waveform.circle.fill") {
            SettingsLink {
                Text("Settings")
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
            Text(ProductIdentity.displayName)
                .frame(width: 420, height: 280)
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
