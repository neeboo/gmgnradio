import AppKit
import simd
import Testing
@testable import GMGNRadio

@Test
@MainActor
func stageUsesANearBlackCanvasForNeonVisuals() throws {
    let spatialStage = SpatialStageStore()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage,
        marbleLibrary: stageMarbleLibraryForUI(spatialStage: spatialStage)
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

@Test
func moodPalettesKeepTheEnvironmentDarkAndLowChroma() {
    let palettes: [StageVisualPalette] = [
        .amber,
        .aqua,
        .indigo,
        .rose,
        .emerald,
        .silver,
    ]

    for palette in palettes {
        let brightest = max(
            palette.background.x,
            max(palette.background.y, palette.background.z)
        )
        let darkest = min(
            palette.background.x,
            min(palette.background.y, palette.background.z)
        )
        #expect(brightest <= 0.022)
        #expect(brightest - darkest <= 0.014)
    }
}
