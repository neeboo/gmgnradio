import Foundation
import simd
import Testing
@testable import GMGNRadio

@Test
func desktopPresenceUsesTheOrbOnlyWhenNoAvatarIsSelected() {
    let empty = StageAvatarRuntimeSnapshot(
        avatar: nil,
        motion: nil,
        revision: 1
    )
    #expect(DesktopPresenceMode.resolve(snapshot: empty) == .orb)

    for format in StageAvatarFormat.allCases {
        let avatar = StageAvatarAsset(
            id: "avatar.\(format.rawValue)",
            name: format.rawValue,
            format: format,
            modelURL: URL(filePath: "/tmp/avatar.\(format.rawValue)"),
            resourceRootURL: URL(filePath: "/tmp")
        )
        let snapshot = StageAvatarRuntimeSnapshot(
            avatar: avatar,
            motion: nil,
            revision: 2
        )
        #expect(DesktopPresenceMode.resolve(snapshot: snapshot) == .liveCam)
    }
}

@Test
func liveCamRenderProfileOmitsTheWorldButKeepsTheAvatar() {
    #expect(LiveCamRenderProfile.liveCam.drawsAvatar)
    #expect(!LiveCamRenderProfile.liveCam.drawsWorld)
    #expect(!LiveCamRenderProfile.liveCam.drawsEnvironment)
    #expect(LiveCamRenderProfile.fullStage.drawsAvatar)
    #expect(LiveCamRenderProfile.fullStage.drawsWorld)
    #expect(LiveCamRenderProfile.fullStage.drawsEnvironment)
}

@Test
func liveCamOrbitFollowsTheCharacterWithoutLosingPlayerRotation() {
    var orbit = LiveCamCharacterOrbit(
        yaw: 0.35,
        pitch: -0.15,
        distance: 1.8,
        targetHeight: 0.8
    )
    let first = orbit.camera(following: SIMD3<Float>(1, 0, 2))

    orbit.rotate(deltaYaw: 0.4, deltaPitch: 0.1)
    let rotatedFirst = orbit.camera(following: SIMD3<Float>(1, 0, 2))
    let moved = orbit.camera(following: SIMD3<Float>(4, 0, -3))

    #expect(abs(orbit.yaw - 0.75) < 0.0001)
    #expect(abs(orbit.pitch - -0.05) < 0.0001)
    #expect(
        simd_length(
            (moved.position - rotatedFirst.position) - SIMD3<Float>(3, 0, -5)
        ) < 0.0001
    )
    #expect(first.position != rotatedFirst.position)
    #expect(moved.target == SIMD3<Float>(4, 0.8, -3))
}

@Test
func liveCamOrbitIgnoresVerticalAvatarMotion() {
    let orbit = LiveCamCharacterOrbit(
        yaw: 0.35,
        pitch: -0.15,
        distance: 1.8,
        targetHeight: 0.8
    )
    let grounded = orbit.camera(following: SIMD3<Float>(1, 0, 2))
    let airborne = orbit.camera(following: SIMD3<Float>(1, 3, 2))

    #expect(airborne == grounded)
}

@Test
func liveCamOrbitClampsPitchAndDistance() {
    var orbit = LiveCamCharacterOrbit(
        yaw: 0,
        pitch: 0,
        distance: 100,
        targetHeight: 0.8
    )
    orbit.rotate(deltaYaw: 0, deltaPitch: 10)
    #expect(orbit.pitch == LiveCamCharacterOrbit.maximumPitch)
    #expect(orbit.distance == LiveCamCharacterOrbit.maximumDistance)

    orbit.rotate(deltaYaw: 0, deltaPitch: -20)
    orbit.setDistance(0)
    #expect(orbit.pitch == LiveCamCharacterOrbit.minimumPitch)
    #expect(orbit.distance == LiveCamCharacterOrbit.minimumDistance)
}

@Test
@MainActor
func stageCameraCoordinatorPreservesDirectorAndUserCameras() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.preserve")
    )
    suite.removePersistentDomain(
        forName: "StageCameraCoordinatorTests.preserve"
    )
    let stage = SpatialStageStore(defaults: suite)
    let director = SpatialCameraState(
        position: .init(1, 2, 3),
        yaw: 0.4,
        pitch: -0.2
    )
    stage.camera = director
    let coordinator = StageCameraCoordinator(spatialStage: stage)

    coordinator.activateFullStage()
    let user = SpatialCameraState(
        position: .init(-2, 1, 4),
        yaw: -0.6,
        pitch: 0.3
    )
    stage.camera = user
    coordinator.captureUserCamera()
    coordinator.activateLiveCam()

    #expect(stage.camera == director)
    #expect(coordinator.savedUserCamera == user)

    coordinator.activateFullStage()
    #expect(stage.camera == user)
}

@Test
@MainActor
func firstFullStagePresentationUsesTheWorldCameraInsteadOfLiveCamCamera() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.firstWorldCamera")
    )
    suite.removePersistentDomain(
        forName: "StageCameraCoordinatorTests.firstWorldCamera"
    )
    let stage = SpatialStageStore(defaults: suite)
    let liveCam = SpatialCameraState(
        position: .init(0.2, 0.9, 0.8),
        yaw: 0.2,
        pitch: -0.1
    )
    let worldCamera = SpatialCameraState(
        position: .init(0, 0.68, 3.35),
        yaw: 0,
        pitch: 0
    )
    stage.camera = liveCam
    let coordinator = StageCameraCoordinator(spatialStage: stage)

    coordinator.activateFullStage(defaultCamera: worldCamera)

    #expect(stage.camera == worldCamera)
    #expect(coordinator.savedDirectorCamera == liveCam)
}

@Test
func fullStageEntryRejectsASavedCameraInsideTheAvatarCloseUpZone() {
    let avatarPosition = SIMD3<Float>(0, 0, 1.1)
    let worldCamera = SpatialCameraState(
        position: SIMD3<Float>(0, 0.82, 2.05),
        yaw: 0,
        pitch: 0
    )
    let closeCamera = SpatialCameraState(
        position: SIMD3<Float>(0.39, 0.82, 1.14),
        yaw: 0.27,
        pitch: -0.17
    )
    let safeCamera = SpatialCameraState(
        position: SIMD3<Float>(1.4, 0.82, 2.2),
        yaw: -0.3,
        pitch: 0.1
    )

    #expect(
        FullStageCameraEntryPolicy.resolve(
            savedCamera: closeCamera,
            fallbackCamera: worldCamera,
            avatarPosition: avatarPosition
        ) == worldCamera
    )
    #expect(
        FullStageCameraEntryPolicy.resolve(
            savedCamera: safeCamera,
            fallbackCamera: worldCamera,
            avatarPosition: avatarPosition
        ) == safeCamera
    )
}

@Test
func fullStageEntryRejectsALiveCamScaleCloseUp() {
    let avatarPosition = SIMD3<Float>(0, 0, 1.1)
    let worldCamera = SpatialCameraState(
        position: SIMD3<Float>(0, 0.82, 2.05),
        yaw: 0,
        pitch: 0
    )
    let oversizedCamera = SpatialCameraState(
        position: SIMD3<Float>(0.8, 0.82, 1.5),
        yaw: 0.4,
        pitch: -0.15
    )

    #expect(
        FullStageCameraEntryPolicy.resolve(
            savedCamera: oversizedCamera,
            fallbackCamera: worldCamera,
            avatarPosition: avatarPosition
        ) == worldCamera
    )
}

@Test
@MainActor
func fullStageReentryRepairsOnlyAnUnsafeSavedUserCamera() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.safeReentry")
    )
    suite.removePersistentDomain(
        forName: "StageCameraCoordinatorTests.safeReentry"
    )
    let stage = SpatialStageStore(defaults: suite)
    stage.setTransientAvatarPlacement(
        StageAvatarPlacement(
            position: SIMD3<Float>(0, 0, 1.1),
            scale: 0.60,
            yaw: 0.67
        )
    )
    let worldCamera = SpatialCameraState(
        position: SIMD3<Float>(0, 0.82, 2.05),
        yaw: 0,
        pitch: 0
    )
    let coordinator = StageCameraCoordinator(spatialStage: stage)

    coordinator.activateFullStage(defaultCamera: worldCamera)
    stage.camera = SpatialCameraState(
        position: SIMD3<Float>(0.39, 0.82, 1.14),
        yaw: 0.27,
        pitch: -0.17
    )
    coordinator.activateLiveCam()
    coordinator.activateFullStage(defaultCamera: worldCamera)

    #expect(stage.camera == worldCamera)
}

@Test
@MainActor
func stageCameraCoordinatorPausesDirectorOnlyDuringFullStage() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.pause")
    )
    suite.removePersistentDomain(forName: "StageCameraCoordinatorTests.pause")
    let stage = SpatialStageStore(defaults: suite)
    var changes: [Bool] = []
    let coordinator = StageCameraCoordinator(
        spatialStage: stage,
        onDirectorPauseChange: { changes.append($0) }
    )

    coordinator.activateFullStage()
    coordinator.activateFullStage()
    coordinator.activateLiveCam()
    coordinator.activateLiveCam()

    #expect(changes == [true, false])
    #expect(coordinator.owner == .liveCamDirector)
    #expect(!coordinator.isDirectorPaused)
}

@Test
@MainActor
func directorUpdatesDoNotOverrideAnActiveUserCamera() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.director")
    )
    suite.removePersistentDomain(
        forName: "StageCameraCoordinatorTests.director"
    )
    let stage = SpatialStageStore(defaults: suite)
    let coordinator = StageCameraCoordinator(spatialStage: stage)
    coordinator.activateFullStage()
    let user = SpatialCameraState(position: .init(4, 1, -3))
    stage.camera = user

    let nextDirector = SpatialCameraState(position: .init(0, 3, 8))
    coordinator.updateDirectorCamera(nextDirector)

    #expect(stage.camera == user)
    #expect(coordinator.savedDirectorCamera == nextDirector)

    coordinator.activateLiveCam()
    #expect(stage.camera == nextDirector)
}

@Test
@MainActor
func fullStageCameraPansWithAvatarWithoutMovingIntoTheWorld() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.avatarFollow")
    )
    suite.removePersistentDomain(
        forName: "StageCameraCoordinatorTests.avatarFollow"
    )
    let stage = SpatialStageStore(defaults: suite)
    let coordinator = StageCameraCoordinator(spatialStage: stage)
    coordinator.activateFullStage()
    stage.camera = SpatialCameraState(
        position: SIMD3<Float>(0.4, 0.82, 2.1),
        yaw: 0.7,
        pitch: -0.2
    )

    coordinator.followAvatarHorizontally(
        from: SIMD3<Float>(0, 0, -0.9),
        to: SIMD3<Float>(0.72, 1.4, 0.55)
    )

    #expect(stage.camera.position == SIMD3<Float>(0.4, 0.82, 2.1))
    let previousBearing = atan2(Float(0.4), Float(3.0))
    let currentBearing = atan2(Float(-0.32), Float(1.55))
    let expectedYaw = 0.7 + currentBearing - previousBearing
    #expect(abs(stage.camera.yaw - expectedYaw) < 0.0001)
    #expect(stage.camera.pitch == -0.2)
}

@Test
@MainActor
func avatarMovementDoesNotMoveTheFullStageCameraWhileLiveCamOwnsIt() throws {
    let suite = try #require(
        UserDefaults(suiteName: "StageCameraCoordinatorTests.liveFollow")
    )
    suite.removePersistentDomain(
        forName: "StageCameraCoordinatorTests.liveFollow"
    )
    let stage = SpatialStageStore(defaults: suite)
    stage.camera = SpatialCameraState(
        position: SIMD3<Float>(0.4, 0.82, 2.1),
        yaw: 0.7,
        pitch: -0.2
    )
    let coordinator = StageCameraCoordinator(spatialStage: stage)

    coordinator.followAvatarHorizontally(
        from: SIMD3<Float>(0, 0, -0.9),
        to: SIMD3<Float>(0.72, 1.4, 0.55)
    )

    #expect(
        stage.camera
            == SpatialCameraState(
                position: SIMD3<Float>(0.4, 0.82, 2.1),
                yaw: 0.7,
                pitch: -0.2
            )
    )
}

@Test
func stageRenderQualityHasBoundedDesktopProfiles() {
    #expect(StageRenderQuality.balanced.framesPerSecond == 24)
    #expect(StageRenderQuality.balanced.renderScale == 0.6)
    #expect(StageRenderQuality.low.framesPerSecond == 12)
    #expect(StageRenderQuality.low.renderScale == 0.45)
}

@Test
func hiddenOccludedAndDetachedRenderSurfacesPause() {
    let visible = StageRenderActivityState.resolve(
        owner: .liveCam,
        isOwnerVisible: true,
        isOwnerOccluded: false,
        isWorldPresentationVisible: true
    )
    let occluded = StageRenderActivityState.resolve(
        owner: .liveCam,
        isOwnerVisible: true,
        isOwnerOccluded: true,
        isWorldPresentationVisible: true
    )
    let hidden = StageRenderActivityState.resolve(
        owner: .liveCam,
        isOwnerVisible: false,
        isOwnerOccluded: false,
        isWorldPresentationVisible: true
    )
    let detached = StageRenderActivityState.resolve(
        owner: .detached,
        isOwnerVisible: true,
        isOwnerOccluded: false,
        isWorldPresentationVisible: true
    )

    #expect(!visible.isPaused)
    #expect(occluded.isPaused)
    #expect(hidden.isPaused)
    #expect(detached.isPaused)
}

@Test
func visibleStageOnlyPausesWhenMiniaturized() {
    #expect(
        !StageWindowOcclusionPolicy.isOccluded(
            isVisible: true,
            isMiniaturized: false
        )
    )
    #expect(
        StageWindowOcclusionPolicy.isOccluded(
            isVisible: true,
            isMiniaturized: true
        )
    )
    #expect(
        !StageWindowOcclusionPolicy.isOccluded(
            isVisible: false,
            isMiniaturized: true
        )
    )
}

@Test
func liveCamAndLoadingFullStageKeepTheSharedSurfaceVisible() {
    let activity = StageRenderActivityState.resolve(
        owner: .liveCam,
        isOwnerVisible: true,
        isOwnerOccluded: false,
        isWorldPresentationVisible: false
    )
    let fullStage = StageRenderActivityState.resolve(
        owner: .fullStage,
        isOwnerVisible: true,
        isOwnerOccluded: false,
        isWorldPresentationRequested: true,
        isWorldPresentationVisible: false
    )

    #expect(!activity.isPaused)
    #expect(!activity.isHidden)
    #expect(!fullStage.isPaused)
    #expect(!fullStage.isHidden)
}

@Test
func sharedSurfaceUsesOneExplicitRenderLoopAcrossWindowReparenting() {
    let active = StageRenderActivityState(
        isPaused: false,
        isHidden: false
    )
    let paused = StageRenderActivityState(
        isPaused: true,
        isHidden: false
    )

    #expect(
        StageRenderLoopMode.resolve(
            activity: active,
            quality: .balanced
        ) == .manual(framesPerSecond: 24)
    )
    #expect(
        StageRenderLoopMode.resolve(
            activity: active,
            quality: .full
        ) == .manual(framesPerSecond: 60)
    )
    #expect(
        StageRenderLoopMode.resolve(
            activity: paused,
            quality: .full
        ) == .stopped
    )
}
