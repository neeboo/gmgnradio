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
        Settings {
            Text(ProductIdentity.displayName)
                .frame(width: 420, height: 280)
        }

        MenuBarExtra(ProductIdentity.displayName, systemImage: "waveform.circle.fill") {
            SettingsLink {
                Text("Settings")
            }
            Divider()
            Button("Quit gmgn radio") {
                NSApplication.shared.terminate(nil)
            }
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
    }
}
