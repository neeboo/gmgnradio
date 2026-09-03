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
func dockReopenRestoresTheSelectedDesktopPresence() {
    var showDesktopPresenceCount = 0
    let action = DockReopenAction {
        showDesktopPresenceCount += 1
    }

    #expect(action.perform(hasVisibleWindows: false))
    #expect(showDesktopPresenceCount == 1)

    #expect(action.perform(hasVisibleWindows: true))
    #expect(showDesktopPresenceCount == 2)
}

@Test
func normalLaunchShowsDesktopPresenceButTestHostsAndExplicitOptOutDoNot() {
    #expect(
        ApplicationLaunchPolicy.shouldShowDesktopPresenceOnLaunch(
            environment: [:]
        )
    )
    #expect(
        !ApplicationLaunchPolicy.shouldShowDesktopPresenceOnLaunch(
            environment: [
                "XCTestConfigurationFilePath":
                    "/tmp/gmgn-radio.xctestconfiguration",
            ]
        )
    )
    #expect(
        !ApplicationLaunchPolicy.shouldShowDesktopPresenceOnLaunch(
            environment: [
                "GMGN_HIDE_STAGE_ON_LAUNCH": "1",
            ]
        )
    )
}

@Test
@MainActor
func orbMenuActionReflectsStageVisibilityAndTogglesTheStage() {
    var events: [String] = []
    let openAction = OrbStageMenuAction(isStageVisible: false)

    #expect(openAction.title == "打开 360° 舞台")
    openAction.perform(
        showStage: { events.append("show") },
        hideStage: { events.append("hide") }
    )

    let hideAction = OrbStageMenuAction(isStageVisible: true)
    #expect(hideAction.title == "隐藏 360° 舞台")
    hideAction.perform(
        showStage: { events.append("show") },
        hideStage: { events.append("hide") }
    )

    #expect(events == ["show", "hide"])
}

@Test
func desktopPresenceSelectionKeepsAvatarFormatResourcesAndFallsBackToTheOrb() {
    let modelURL = URL(filePath: "/tmp/catgirl.vrm")
    let avatar = DesktopPresenceSelection.resolve(
        snapshot: StageAvatarRuntimeSnapshot(
            modelURL: modelURL,
            name: "Noir",
            revision: 3
        )
    )
    #expect(avatar.kind == .vrm)
    #expect(avatar.avatarSelection?.avatar.modelURL == modelURL)
    #expect(avatar.avatarSelection?.revision == 3)

    let pmxAsset = StageAvatarAsset(
        id: "pmx.catgirl",
        name: "Miku",
        format: .pmx,
        modelURL: URL(filePath: "/tmp/miku/model.pmx"),
        resourceRootURL: URL(filePath: "/tmp/miku")
    )
    let pmx = DesktopPresenceSelection.resolve(
        snapshot: StageAvatarRuntimeSnapshot(
            avatar: pmxAsset,
            motion: StageMotionAsset(
                id: "motion.dance",
                name: "Dance",
                format: .vmd,
                url: URL(filePath: "/tmp/dance.vmd")
            ),
            revision: 4
        )
    )
    #expect(pmx.kind == .pmx)
    #expect(pmx.avatarSelection?.avatar.resourceRootURL == URL(filePath: "/tmp/miku"))
    #expect(pmx.avatarSelection?.motion?.format == .vmd)

    let orb = DesktopPresenceSelection.resolve(
        snapshot: StageAvatarRuntimeSnapshot(
            modelURL: nil,
            name: nil,
            revision: 5
        )
    )
    #expect(orb == .orb)
}

@Test
func shortcutDefaultsCoverTheCoreRadioAndStageActions() {
    #expect(GMGNShortcutAction.allCases.map(\.title) == [
        "播放 / 暂停",
        "上一首",
        "下一首",
        "音量增加",
        "音量降低",
        "开麦 / 关麦",
        "显示 / 隐藏舞台",
        "切换歌词视觉",
    ])

    let assignments = GMGNShortcutAssignment.defaults
    #expect(assignments.count == 8)
    #expect(
        assignments.first { $0.action == .togglePlayback }?
            .local.displayName == "空格"
    )
    #expect(
        assignments.first { $0.action == .previousTrack }?
            .local.displayName == "⌘←"
    )
    #expect(
        assignments.first { $0.action == .toggleStage }?
            .global.displayName == "⌥⌘S"
    )
}

@Test
@MainActor
func assigningAnExistingShortcutSwapsTheConflictingActions() {
    let suiteName = "ai.gmgn.radio.shortcuts.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = GMGNShortcutSettingsStore(defaults: defaults)
    let previous = store.assignment(for: .previousTrack).local
    let next = store.assignment(for: .nextTrack).local

    store.assign(
        next,
        to: .previousTrack,
        scope: .local
    )

    #expect(store.assignment(for: .previousTrack).local == next)
    #expect(store.assignment(for: .nextTrack).local == previous)
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
