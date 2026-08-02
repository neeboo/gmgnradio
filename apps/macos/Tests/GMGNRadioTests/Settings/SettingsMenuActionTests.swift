import Testing
@testable import GMGNRadio

@MainActor
@Test
func settingsMenuRevealsWindowAfterTheMenuDismisses() {
    var events: [String] = []
    var scheduledActivation: (@MainActor () -> Void)?
    let action = SettingsMenuAction(
        openSettings: { events.append("open") },
        scheduleActivation: { activation in
            events.append("schedule")
            scheduledActivation = activation
        },
        activateApplication: { events.append("activate") },
        revealSettingsWindow: { events.append("reveal") }
    )

    action.perform()
    #expect(events == ["activate", "open", "schedule"])

    scheduledActivation?()
    #expect(
        events == [
            "activate",
            "open",
            "schedule",
            "activate",
            "reveal",
        ]
    )
}
