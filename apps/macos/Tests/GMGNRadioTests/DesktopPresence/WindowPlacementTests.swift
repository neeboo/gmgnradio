import CoreGraphics
import Testing
@testable import GMGNRadio

@Test
func snapsToVisibleFrameBottomRight() {
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
    let result = WindowPlacement.defaultFrame(
        size: CGSize(width: 168, height: 168),
        visibleFrame: visible,
        margin: 24
    )

    #expect(result.maxX == 1416)
    #expect(result.minY == 64)
}

@Test
func proposedFrameSnapsToNearestVisibleEdge() {
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
    let proposed = CGRect(x: 12, y: 360, width: 168, height: 168)

    let result = WindowPlacement.snappedFrame(
        proposed,
        visibleFrames: [visible],
        margin: 24,
        snapDistance: 18
    )

    #expect(result.minX == 24)
    #expect(result.minY == 360)
}

@Test
func rememberedOriginUsesMatchingDisplayAndStaysVisible() {
    let displays = [
        DisplayFrame(id: "main", visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 860)),
        DisplayFrame(id: "studio", visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    ]

    let result = WindowPlacement.restoredFrame(
        size: CGSize(width: 168, height: 168),
        displays: displays,
        savedDisplayID: "studio",
        savedOrigin: CGPoint(x: 3300, y: 1020),
        margin: 24
    )

    #expect(result.maxX == 3336)
    #expect(result.maxY == 1056)
}

@Test
func removedDisplayFallsBackToMainDisplay() {
    let main = DisplayFrame(
        id: "main",
        visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 860)
    )

    let result = WindowPlacement.restoredFrame(
        size: CGSize(width: 168, height: 168),
        displays: [main],
        savedDisplayID: "missing",
        savedOrigin: CGPoint(x: 2200, y: 500),
        margin: 24
    )

    #expect(result.maxX == 1416)
    #expect(result.minY == 64)
}

@Test
func liveCamDragCanCrossFromTheMainDisplayToASecondaryDisplay() {
    let visibleFrames = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1000, height: 800),
    ]
    let start = CGRect(x: 620, y: 200, width: 360, height: 250)

    var crossing = start
    for _ in 0 ..< 56 {
        crossing = LiveCamWindowMovementPolicy.frame(
            from: crossing,
            translation: CGSize(width: 5, height: 0),
            phase: .changed,
            visibleFrames: visibleFrames,
            margin: 16,
            snapDistance: 18
        )
    }
    #expect(crossing.minX == 900)

    let released = LiveCamWindowMovementPolicy.frame(
        from: crossing,
        translation: CGSize(width: 260, height: 0),
        phase: .ended,
        visibleFrames: visibleFrames,
        margin: 16,
        snapDistance: 18
    )
    #expect(released.minX == 1160)
}
