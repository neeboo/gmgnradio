import AppKit
import Testing
@testable import GMGNRadio

@Test
@MainActor
func foregroundActivationMakesTheApplicationRegularBeforeActivatingIt() {
    var events: [String] = []
    let coordinator = ApplicationActivationCoordinator(
        setPolicy: { policy in
            events.append(policy == .regular ? "regular" : "other")
            return true
        },
        activate: {
            events.append("activate")
        }
    )

    coordinator.promoteToForeground()

    #expect(events == ["regular", "activate"])
}

@Test
@MainActor
func dockReopenRestoresTheStageWhenNoApplicationWindowIsVisible() {
    var showStageCount = 0
    let action = DockReopenAction {
        showStageCount += 1
    }

    #expect(action.perform(hasVisibleWindows: false))
    #expect(showStageCount == 1)

    #expect(action.perform(hasVisibleWindows: true))
    #expect(showStageCount == 1)
}

@Test
@MainActor
func applicationIconInstallerAppliesTheBundledIcon() {
    let expectedIcon = NSImage(size: NSSize(width: 64, height: 64))
    var appliedIcon: NSImage?
    let installer = ApplicationIconInstaller(
        loadIcon: { expectedIcon },
        applyIcon: { appliedIcon = $0 }
    )

    #expect(installer.install())
    #expect(appliedIcon === expectedIcon)
}
