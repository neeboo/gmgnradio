import Testing
@testable import GMGNRadio

@Test
@MainActor
func appMenuActionsForwardToTheAdaptedApplicationController() {
    let controller = ApplicationControllerSpy()

    AppMenuAction.showStage.perform(on: controller)
    AppMenuAction.closeStage.perform(on: controller)
    AppMenuAction.exitImmersiveVisuals.perform(on: controller)

    #expect(controller.showStageCallCount == 1)
    #expect(controller.closeStageCallCount == 1)
    #expect(controller.exitImmersiveVisualsCallCount == 1)
}

@MainActor
private final class ApplicationControllerSpy: GMGNApplicationControlling {
    private(set) var showStageCallCount = 0
    private(set) var closeStageCallCount = 0
    private(set) var exitImmersiveVisualsCallCount = 0

    func showStage() {
        showStageCallCount += 1
    }

    func closeStage() {
        closeStageCallCount += 1
    }

    func exitImmersiveVisuals() {
        exitImmersiveVisualsCallCount += 1
    }
}
