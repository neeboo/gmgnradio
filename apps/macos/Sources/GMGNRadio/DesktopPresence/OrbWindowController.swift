import AppKit
import SwiftUI

@MainActor
final class OrbWindowController: NSWindowController, NSWindowDelegate {
    private enum Constants {
        static let size = CGSize(width: 168, height: 168)
        static let margin: CGFloat = 24
        static let interactionProximity: CGFloat = 20
        static let savedDisplayID = "orb.displayID"
        static let savedOriginX = "orb.origin.x"
        static let savedOriginY = "orb.origin.y"
    }

    private let defaults: UserDefaults
    private var interactionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let frame = Self.initialFrame(defaults: defaults)
        let host = NSHostingView(rootView: OrbPlaceholderView())
        host.frame = CGRect(origin: .zero, size: Constants.size)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = OrbPanel(frame: frame, contentView: host)
        super.init(window: panel)
        panel.delegate = self
        startInteractionTracking(panel: panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        interactionTask?.cancel()
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, let screen = window.screen else {
            return
        }

        let snapped = WindowPlacement.snappedFrame(
            window.frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            margin: Constants.margin,
            snapDistance: 18
        )
        if snapped.origin != window.frame.origin {
            window.setFrameOrigin(snapped.origin)
        }

        defaults.set(Self.identifier(for: screen), forKey: Constants.savedDisplayID)
        defaults.set(snapped.origin.x, forKey: Constants.savedOriginX)
        defaults.set(snapped.origin.y, forKey: Constants.savedOriginY)
    }

    private func startInteractionTracking(panel: OrbPanel) {
        interactionTask = Task { @MainActor [weak panel] in
            while !Task.isCancelled {
                guard let panel else {
                    return
                }

                let pointer = NSEvent.mouseLocation
                let proximityFrame = panel.frame.insetBy(
                    dx: -Constants.interactionProximity,
                    dy: -Constants.interactionProximity
                )
                let optionPressed = NSEvent.modifierFlags.contains(.option)
                panel.setInteractionEnabled(optionPressed || proximityFrame.contains(pointer))

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func initialFrame(defaults: UserDefaults) -> CGRect {
        let displays = NSScreen.screens.map {
            DisplayFrame(id: identifier(for: $0), visibleFrame: $0.visibleFrame)
        }
        let savedID = defaults.string(forKey: Constants.savedDisplayID)
        let hasSavedOrigin = defaults.object(forKey: Constants.savedOriginX) != nil
            && defaults.object(forKey: Constants.savedOriginY) != nil
        let origin = hasSavedOrigin
            ? CGPoint(
                x: defaults.double(forKey: Constants.savedOriginX),
                y: defaults.double(forKey: Constants.savedOriginY)
            )
            : nil

        return WindowPlacement.restoredFrame(
            size: Constants.size,
            displays: displays,
            savedDisplayID: savedID,
            savedOrigin: origin,
            margin: Constants.margin
        )
    }

    private static func identifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        return number?.stringValue ?? String(describing: screen.frame)
    }
}

private struct OrbPlaceholderView: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.28, green: 0.50, blue: 0.72).opacity(0.48),
                        Color(red: 0.30, green: 0.20, blue: 0.48).opacity(0.22),
                        .clear
                    ],
                    center: .center,
                    startRadius: 12,
                    endRadius: 82
                )
            )
            .padding(8)
            .accessibilityLabel("gmgn radio")
    }
}
