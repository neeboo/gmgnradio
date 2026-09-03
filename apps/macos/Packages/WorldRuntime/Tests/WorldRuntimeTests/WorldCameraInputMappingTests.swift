import Testing
@testable import WorldRuntime

@Test
func draggingTheWorldToTheRightTurnsTheCameraToTheLeft() {
    let yawDelta = WorldCameraInputMapping.yawDelta(
        horizontalDrag: 80,
        sensitivity: 0.0035
    )

    #expect(yawDelta < 0)
    #expect(abs(yawDelta + 0.28) < 0.0001)
}

@Test
func horizontalDirectionDoesNotChangeVerticalCameraInput() {
    let pitchDelta = WorldCameraInputMapping.pitchDelta(
        verticalDrag: -40,
        sensitivity: 0.0035
    )

    #expect(abs(pitchDelta - 0.14) < 0.0001)
}
