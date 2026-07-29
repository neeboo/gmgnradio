import AppKit
import Testing
@testable import GMGNRadio

@Test
@MainActor
func stageWindowControllerReusesTheOpenWindowAndCanReopen() {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )

    controller.show()
    let firstWindow = controller.window
    controller.show()

    #expect(controller.window === firstWindow)
    #expect(controller.isPresented)

    controller.close()

    #expect(!controller.isPresented)

    controller.show()

    #expect(controller.isPresented)
    #expect(controller.window !== firstWindow)

    controller.close()
}

@Test
@MainActor
func stageWindowControllerRunsAudioMonitoringOnlyWhilePresented() {
    let monitor = StageAudioMonitorSpy()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        audioMonitor: monitor
    )

    controller.show()

    #expect(monitor.startCallCount == 1)

    controller.close()

    #expect(monitor.stopCallCount == 1)
}

@MainActor
private final class StageAudioMonitorSpy: VisualAudioMonitoring {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}
