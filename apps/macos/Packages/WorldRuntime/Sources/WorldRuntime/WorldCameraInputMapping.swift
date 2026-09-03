public enum WorldCameraInputMapping: Sendable {
    public static func yawDelta(
        horizontalDrag: Float,
        sensitivity: Float
    ) -> Float {
        -horizontalDrag * sensitivity
    }

    public static func pitchDelta(
        verticalDrag: Float,
        sensitivity: Float
    ) -> Float {
        -verticalDrag * sensitivity
    }
}
