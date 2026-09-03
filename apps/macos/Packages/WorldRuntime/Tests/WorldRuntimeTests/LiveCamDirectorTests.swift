import Testing
@testable import WorldRuntime

@Test("Director and user cameras remain independent")
func directorAndUserCamerasRemainIndependent() {
    let director = makeCameraState(id: "camera.director", x: 1)
    let user = makeCameraState(id: "camera.user", x: 2)
    var cameras = LiveCamCameraState(director: director, user: user)

    cameras.user = makeCameraState(id: "camera.user.moved", x: 8)

    #expect(cameras.director == director)
    #expect(cameras.user.transform.position.x == 8)
}

@Test("Default shot timing stays inside the live camera bounds")
func defaultShotTimingStaysInsideBounds() {
    let configuration = LiveCamDirector.Configuration()

    #expect(configuration.shotDwellDurationRange == 8 ... 15)
    #expect(configuration.transitionDurationRange == 1.2 ... 2)
}

@Test("Director holds a shot, transitions, then advances deterministically")
func directorAdvancesDeterministically() {
    let configuration = LiveCamDirector.Configuration(
        shotDwellDurationRange: 8 ... 8,
        transitionDurationRange: 1.2 ... 1.2
    )
    var first = LiveCamDirector(configuration: configuration)
    var second = LiveCamDirector(configuration: configuration)
    let input = makeDirectorInput()

    let firstInitial = first.update(deltaTime: 0, input: input)
    let secondInitial = second.update(deltaTime: 0, input: input)
    #expect(firstInitial == secondInitial)
    #expect(firstInitial?.phase == .holding)

    let firstTransition = first.update(deltaTime: 8, input: input)
    let secondTransition = second.update(deltaTime: 8, input: input)
    #expect(firstTransition == secondTransition)
    #expect(firstTransition?.phase == .transitioning)
    #expect(firstTransition?.transitionProgress == 0)
    #expect(firstTransition?.outgoingCamera?.anchorID != firstTransition?.camera.anchorID)

    let firstComplete = first.update(deltaTime: 1.2, input: input)
    let secondComplete = second.update(deltaTime: 1.2, input: input)
    #expect(firstComplete == secondComplete)
    #expect(firstComplete?.phase == .holding)
    #expect(firstComplete?.outgoingCamera == nil)
}

@Test("Full-space presentation pauses director time")
func fullSpacePausesDirector() {
    let configuration = LiveCamDirector.Configuration(
        shotDwellDurationRange: 8 ... 8,
        transitionDurationRange: 1.2 ... 1.2
    )
    var director = LiveCamDirector(configuration: configuration)

    let initial = director.update(deltaTime: 0, input: makeDirectorInput())
    let paused = director.update(
        deltaTime: 20,
        input: makeDirectorInput(isFullSpacePresented: true)
    )
    let resumed = director.update(deltaTime: 7.9, input: makeDirectorInput())

    #expect(paused == initial)
    #expect(resumed?.phase == .holding)
    #expect(resumed?.camera.anchorID == initial?.camera.anchorID)
}

@Test("Director returns no frame when no camera anchors are available")
func directorReturnsNoFrameWithoutAnchors() {
    var director = LiveCamDirector()
    let input = LiveCamDirector.Input(
        activityPhase: "idle.loop",
        agentTransform: WorldTransform(
            position: WorldVector3(x: 0, y: 0, z: 0),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        isVoiceOverlayActive: false,
        audioEnergy: 0,
        availableCameraAnchors: [],
        isFullSpacePresented: false
    )

    #expect(director.update(deltaTime: 1, input: input) == nil)
}

private func makeDirectorInput(
    isFullSpacePresented: Bool = false
) -> LiveCamDirector.Input {
    LiveCamDirector.Input(
        activityPhase: "read.loop",
        agentTransform: WorldTransform(
            position: WorldVector3(x: 1, y: 0, z: 2),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        isVoiceOverlayActive: true,
        audioEnergy: 0.4,
        availableCameraAnchors: [
            makeAnchor(id: "camera.window", x: 2),
            makeAnchor(id: "camera.room", x: 1),
            makeAnchor(id: "camera.desk", x: 0),
        ],
        isFullSpacePresented: isFullSpacePresented
    )
}

private func makeCameraState(id: String, x: Float) -> WorldCameraState {
    WorldCameraState(anchorID: id, anchor: makeAnchor(id: id, x: x))
}

private func makeAnchor(id: String, x: Float) -> WorldCameraAnchor {
    WorldCameraAnchor(
        id: id,
        transform: WorldTransform(
            position: WorldVector3(x: x, y: 1.6, z: 4),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        fieldOfViewDegrees: 50,
        nearPlane: 0.05,
        farPlane: 100
    )
}
