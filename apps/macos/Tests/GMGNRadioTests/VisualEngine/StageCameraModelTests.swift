import Testing
@testable import GMGNRadio

@Test
func idleStageCameraCompletesAFullOrbit() {
    var camera = StageCameraModel()

    for _ in 0 ..< (60 * 60) {
        camera.step(deltaTime: 1.0 / 60.0)
    }

    #expect(camera.frame.yaw > .pi * 2)
}

@Test
func draggingStageCameraChangesYawAndPitch() {
    var camera = StageCameraModel()
    camera.beginDrag()
    camera.drag(deltaX: 120, deltaY: -40)

    #expect(camera.frame.yaw > 0)
    #expect(camera.frame.pitch > 0)
}

@Test
func stageCameraPitchCannotFlipOver() {
    var camera = StageCameraModel()
    camera.beginDrag()
    camera.drag(deltaX: 0, deltaY: -10_000)

    #expect(camera.frame.pitch <= StageCameraModel.maximumPitch)

    camera.drag(deltaX: 0, deltaY: 20_000)

    #expect(camera.frame.pitch >= -StageCameraModel.maximumPitch)
}

@Test
func stageCameraInertiaDecaysAfterDrag() {
    var camera = StageCameraModel()
    camera.beginDrag()
    camera.drag(deltaX: 90, deltaY: 0)
    camera.endDrag()

    let firstVelocity = camera.frame.yawVelocity
    camera.step(deltaTime: 0.5)

    #expect(camera.frame.yawVelocity > 0)
    #expect(camera.frame.yawVelocity < firstVelocity)
}

