import Foundation

struct StageCameraFrame: Equatable, Sendable {
    var yaw: Float
    var pitch: Float
    var distance: Float
    var yawVelocity: Float
    var pitchVelocity: Float
}

struct StageCameraModel: Sendable {
    static let maximumPitch: Float = 0.82

    private static let dragSensitivity: Float = 0.006
    private static let autoOrbitSpeed: Float = 0.12
    private static let inertiaDecay: Float = 2.8

    private(set) var frame = StageCameraFrame(
        yaw: 0,
        pitch: 0.08,
        distance: 8.2,
        yawVelocity: 0,
        pitchVelocity: 0
    )
    private var isDragging = false

    mutating func beginDrag() {
        isDragging = true
        frame.yawVelocity = 0
        frame.pitchVelocity = 0
    }

    mutating func drag(deltaX: Float, deltaY: Float) {
        guard isDragging else {
            return
        }

        let yawDelta = deltaX * Self.dragSensitivity
        let pitchDelta = -deltaY * Self.dragSensitivity
        frame.yaw += yawDelta
        frame.pitch = min(
            max(frame.pitch + pitchDelta, -Self.maximumPitch),
            Self.maximumPitch
        )
        frame.yawVelocity = yawDelta * 9
        frame.pitchVelocity = pitchDelta * 9
    }

    mutating func endDrag() {
        isDragging = false
    }

    mutating func enterAlbumReliefView() {
        frame.yaw = 0
        frame.pitch = 0.08
        frame.yawVelocity = 0
        frame.pitchVelocity = 0
        isDragging = false
    }

    mutating func step(
        deltaTime: Float,
        autoOrbitEnabled: Bool = true
    ) {
        let delta = min(max(deltaTime, 0), 0.1)
        guard delta > 0, !isDragging else {
            return
        }

        let autoOrbit = autoOrbitEnabled ? Self.autoOrbitSpeed : 0
        frame.yaw += (autoOrbit + frame.yawVelocity) * delta
        frame.pitch = min(
            max(
                frame.pitch + frame.pitchVelocity * delta,
                -Self.maximumPitch
            ),
            Self.maximumPitch
        )

        let decay = exp(-Self.inertiaDecay * delta)
        frame.yawVelocity *= decay
        frame.pitchVelocity *= decay
    }
}
