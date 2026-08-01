import Testing
@testable import GMGNRadio

@Test
@MainActor
func appMenuActionsForwardToTheAdaptedApplicationController() {
    let controller = ApplicationControllerSpy()

    AppMenuAction.startAIProgram.perform(on: controller)
    AppMenuAction.showStage.perform(on: controller)
    AppMenuAction.closeStage.perform(on: controller)
    AppMenuAction.chooseLocalTrack.perform(on: controller)
    AppMenuAction.toggleLocalPlayback.perform(on: controller)
    AppMenuAction.toggleLyricsVisualMode.perform(on: controller)
    AppMenuAction.exitImmersiveVisuals.perform(on: controller)

    #expect(controller.startAIProgramCallCount == 1)
    #expect(controller.showStageCallCount == 1)
    #expect(controller.closeStageCallCount == 1)
    #expect(controller.chooseLocalTrackCallCount == 1)
    #expect(controller.toggleLocalPlaybackCallCount == 1)
    #expect(controller.toggleLyricsVisualModeCallCount == 1)
    #expect(controller.exitImmersiveVisualsCallCount == 1)
}

@MainActor
private final class ApplicationControllerSpy: GMGNApplicationControlling {
    private(set) var startAIProgramCallCount = 0
    private(set) var showStageCallCount = 0
    private(set) var closeStageCallCount = 0
    private(set) var chooseLocalTrackCallCount = 0
    private(set) var toggleLocalPlaybackCallCount = 0
    private(set) var toggleLyricsVisualModeCallCount = 0
    private(set) var exitImmersiveVisualsCallCount = 0

    func startAIProgram() {
        startAIProgramCallCount += 1
    }

    func showStage() {
        showStageCallCount += 1
    }

    func closeStage() {
        closeStageCallCount += 1
    }

    func chooseLocalTrack() {
        chooseLocalTrackCallCount += 1
    }

    func toggleLocalPlayback() {
        toggleLocalPlaybackCallCount += 1
    }

    func toggleLyricsVisualMode() {
        toggleLyricsVisualModeCallCount += 1
    }

    func exitImmersiveVisuals() {
        exitImmersiveVisualsCallCount += 1
    }
}
