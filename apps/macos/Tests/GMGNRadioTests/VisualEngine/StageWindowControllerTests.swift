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

@Test
@MainActor
func stageWindowControllerIncludesAWindowModeButton() {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )

    controller.show()

    let button = controller.window?.contentView?
        .descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.window-mode-toggle" }

    #expect(button != nil)
    #expect(button?.toolTip == "进入全屏")
    #expect(button?.action != nil)

    controller.close()
}

@Test
@MainActor
func stagePlaybackButtonControlsAndReflectsTheRealPlayerState() {
    var toggleCount = 0
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        playbackState: .paused,
        onTogglePlayback: { toggleCount += 1 }
    )

    controller.show()

    let button = controller.window?.contentView?
        .descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.playback-toggle" }
    #expect(button?.toolTip == "播放")
    #expect(button?.isEnabled == true)

    controller.setPlaybackState(.playing)
    #expect(button?.toolTip == "暂停")

    button?.performClick(nil)
    #expect(toggleCount == 1)

    controller.setPlaybackState(.idle)
    #expect(button?.isEnabled == false)

    controller.close()
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

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
