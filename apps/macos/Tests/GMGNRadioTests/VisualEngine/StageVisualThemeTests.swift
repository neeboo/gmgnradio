import AppKit
import Testing
@testable import GMGNRadio

@Test
@MainActor
func stageUsesANearBlackCanvasForNeonVisuals() throws {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )
    controller.show()

    let windowColor = try #require(
        controller.window?.backgroundColor.usingColorSpace(.deviceRGB)
    )
    #expect(windowColor.redComponent < 0.04)
    #expect(windowColor.greenComponent < 0.04)
    #expect(windowColor.blueComponent < 0.08)

    let metalView = MetalStageView(
        frame: CGRect(x: 0, y: 0, width: 640, height: 400),
        audioFeatures: VisualAudioFeatureStore()
    )
    #expect(metalView.clearColor.red < 0.04)
    #expect(metalView.clearColor.green < 0.04)
    #expect(metalView.clearColor.blue < 0.08)

    controller.close()
}
