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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {}
