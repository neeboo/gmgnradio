import Foundation
import Testing
import WorldRuntime
@testable import GMGNRadio

@Suite
@MainActor
struct StageAvatarActivityExecutorTests {
    @Test
    func worldActivityCoexistsWithSpeakingWithoutChangingSelectionRevision() throws {
        let fixture = try Fixture()
        let selectionRevision = fixture.runtime.snapshot.revision
        fixture.runtime.setActivity(.speaking)
        fixture.runtime.setVoiceLevel(0.8)

        let outcome = fixture.executor.apply(
            transform: .test(position: .init(x: 0.75, y: 0, z: -0.2), yaw: 0.67),
            activity: .sit(anchorID: "chair.sit"),
            phase: .loop,
            sourceRevision: 4,
            phaseContract: ActivityPhaseContract(
                phase: .loop,
                motionIDs: ["sit.chair"]
            )
        )

        let applied = try #require(outcome.appliedSnapshot)
        #expect(applied.activity == .sit(anchorID: "chair.sit"))
        #expect(applied.phase == .loop)
        #expect(applied.sourceRevision == 4)
        #expect(fixture.runtime.worldActivity == applied)
        #expect(fixture.runtime.activity == .speaking)
        #expect(fixture.runtime.voiceLevel == 0.8)
        #expect(fixture.runtime.snapshot.revision == selectionRevision)
        #expect(applied.motionPlayback.isNaturalIdleFallback)
        #expect(applied.motionPlayback.fallback?.requestedMotionIDs == ["sit.chair"])
    }

    @Test
    func worldNavigationUsesAbsoluteVisualAnchorsWithoutAddingSavedPlacement() throws {
        let fixture = try Fixture()
        let base = StageAvatarPlacement(
            position: SIMD3<Float>(0.1, 0, 1.1),
            scale: 0.6,
            yaw: 0.2
        )
        fixture.stage.installAvatarPlacement(base)

        _ = fixture.executor.apply(
            transform: .test(position: .init(x: -0.4, y: 0.05, z: 0.3), yaw: -0.8),
            activity: .walk(destinationID: "wp.center"),
            phase: .approach,
            sourceRevision: 5,
            phaseContract: ActivityPhaseContract(
                phase: .approach,
                motionIDs: ["walk.forward"]
            )
        )

        #expect(fixture.stage.avatarPlacement.position == SIMD3<Float>(-0.3, 0.05, 0.3))
        #expect(fixture.stage.avatarPlacement.scale == base.scale)

        let restored = SpatialStageStore(defaults: fixture.defaults)
        restored.selectWorld(id: fixture.worldID)
        restored.installAvatarPlacement(base)
        #expect(restored.avatarPlacement == base)
    }

    @Test
    func warmKitchenCenterCannotBePushedOutsideTheVisibleRoomBySavedXYZ() throws {
        let fixture = try Fixture()
        fixture.stage.installAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(0, 0, 1.1),
                scale: 0.6,
                yaw: 0.67
            )
        )
        fixture.stage.setAvatarPosition(-0.09, axis: .y)
        fixture.stage.setAvatarPosition(-0.75, axis: .z)

        _ = fixture.executor.apply(
            transform: .test(
                position: .init(x: 0, y: 0, z: 0.2),
                yaw: 0
            ),
            activity: .walk(destinationID: "wp.center"),
            phase: .approach,
            sourceRevision: 5
        )

        #expect(fixture.stage.avatarPlacement.position == SIMD3<Float>(0, 0, 0.2))
    }

    @Test
    func worldSpawnKeepsTheUsersSavedXYZAndYaw() throws {
        let fixture = try Fixture()
        let calibrated = StageAvatarPlacement(
            position: SIMD3<Float>(0, 0.055, 1.1),
            scale: 0.6,
            yaw: 0.67
        )
        fixture.stage.installAvatarPlacement(calibrated)
        fixture.stage.setAvatarPosition(0, axis: .x)
        fixture.stage.setAvatarPosition(-0.09, axis: .y)
        fixture.stage.setAvatarPosition(-0.75, axis: .z)
        let saved = fixture.stage.avatarPlacement

        _ = fixture.executor.apply(
            transform: .test(
                position: .init(x: 0, y: 0, z: 1.1),
                yaw: 0.67
            ),
            activity: .idle,
            phase: .loop,
            sourceRevision: 1
        )

        #expect(fixture.stage.avatarPlacement == saved)
    }

    @Test
    func staleRevisionCannotReplaceActivityOrPlacement() throws {
        let fixture = try Fixture()
        _ = fixture.executor.apply(
            transform: .test(position: .init(x: 0.4, y: 0, z: 0.2), yaw: 0.3),
            activity: .gaze(targetID: "window.gaze"),
            phase: .loop,
            sourceRevision: 8
        )
        let currentActivity = try #require(fixture.runtime.worldActivity)
        let currentPlacement = fixture.stage.avatarPlacement

        let outcome = fixture.executor.apply(
            transform: .test(position: .init(x: 1.4, y: 0, z: -1.2), yaw: -1),
            activity: .listenMusic(anchorID: "music.listen"),
            phase: .loop,
            sourceRevision: 7
        )

        #expect(outcome == .rejectedStale(submitted: 7, latest: 8))
        #expect(fixture.runtime.worldActivity == currentActivity)
        #expect(fixture.stage.avatarPlacement == currentPlacement)
    }

    @Test
    func identicalWorldTicksDoNotReinstallTheVisibleActivity() throws {
        let fixture = try Fixture()
        let transform = WorldTransform.test(
            position: .init(x: 0.4, y: 0, z: 0.2),
            yaw: 0.3
        )
        _ = fixture.executor.apply(
            transform: transform,
            activity: .gaze(targetID: "window.gaze"),
            phase: .loop,
            sourceRevision: 8
        )
        let installed = try #require(fixture.runtime.worldActivity)

        let outcome = fixture.executor.apply(
            transform: transform,
            activity: .gaze(targetID: "window.gaze"),
            phase: .loop,
            sourceRevision: 9
        )

        #expect(outcome == .unchanged(sourceRevision: 9))
        #expect(fixture.runtime.worldActivity == installed)
        #expect(
            fixture.executor.apply(
                transform: transform,
                activity: .idle,
                phase: .loop,
                sourceRevision: 8
            ) == .rejectedStale(submitted: 8, latest: 9)
        )
    }

    @Test
    func completingActivityRestoresStablePlacementAndKeepsVoiceOverlay() throws {
        let fixture = try Fixture()
        let base = StageAvatarPlacement(
            position: SIMD3<Float>(0.2, 0, 0.9),
            scale: 0.62,
            yaw: 0.1
        )
        fixture.stage.installAvatarPlacement(base)
        fixture.stage.setAvatarPosition(-0.25, axis: .x)
        let userPlacement = fixture.stage.avatarPlacement
        fixture.runtime.setActivity(.listening)

        _ = fixture.executor.apply(
            transform: .test(position: .init(x: 0.8, y: 0, z: -0.6), yaw: 1.2),
            activity: .sit(anchorID: "chair.sit"),
            phase: .exit,
            sourceRevision: 10
        )
        let outcome = fixture.executor.finish(sourceRevision: 11)

        #expect(outcome == .cleared(sourceRevision: 11))
        #expect(fixture.runtime.worldActivity == nil)
        #expect(fixture.stage.avatarPlacement == userPlacement)
        #expect(fixture.runtime.activity == .listening)
    }

    @Test
    func onlyApprovedTemporaryMotionCanReplaceNaturalIdle() throws {
        let fixture = try Fixture()
        let approved = StageMotionAsset(
            id: "walk.forward",
            name: "Licensed Walk",
            format: .vrma,
            url: URL(filePath: "/tmp/licensed-walk.vrma")
        )

        _ = fixture.executor.apply(
            transform: .test(position: .init(x: 0, y: 0, z: 0.4), yaw: 0),
            activity: .walk(destinationID: "wp.center"),
            phase: .approach,
            sourceRevision: 2,
            phaseContract: ActivityPhaseContract(
                phase: .approach,
                motionIDs: [approved.id]
            ),
            approvedMotions: [approved.id: approved]
        )

        #expect(fixture.runtime.worldActivity?.motionPlayback == .temporary(approved))
    }

    @Test
    func missingLivingMotionsAllFallBackToNaturalIdle() throws {
        let fixture = try Fixture()
        let activities: [LifeActivity] = [
            .walk(destinationID: "wp.center"),
            .sit(anchorID: "chair.sit"),
            .gaze(targetID: "window.gaze"),
            .listenMusic(anchorID: "music.listen"),
        ]

        for (offset, activity) in activities.enumerated() {
            let outcome = fixture.executor.apply(
                transform: .test(
                    position: .init(x: Float(offset) * 0.1, y: 0, z: 0),
                    yaw: 0
                ),
                activity: activity,
                phase: .loop,
                sourceRevision: UInt64(offset + 1)
            )
            let playback = try #require(outcome.appliedSnapshot?.motionPlayback)

            #expect(playback.isNaturalIdleFallback)
            #expect(playback.fallback?.activityTypeID == activity.typeID)
            #expect(playback.fallback?.reason == .phaseHasNoApprovedMotion)
        }
    }

    @Test
    func resolvedMotionKeepsSelectedDanceOnlyDuringRealIdle() {
        let selectedDance = StageMotionAsset(
            id: "dance.selected",
            name: "Selected Dance",
            format: .vmd,
            url: URL(filePath: "/tmp/selected-dance.vmd")
        )
        let approvedActivityMotion = StageMotionAsset(
            id: "activity.gaze",
            name: "Approved Gaze",
            format: .vrma,
            url: URL(filePath: "/tmp/approved-gaze.vrma")
        )
        let missingActivity = StageAvatarMotionFallback(
            activityTypeID: LifeActivity.gaze(targetID: "window").typeID,
            phase: .loop,
            requestedMotionIDs: ["gaze.window"],
            reason: .approvedMotionUnavailable
        )

        #expect(
            StageAvatarResolvedMotion.resolve(
                selectedMotion: selectedDance,
                worldPlayback: nil
            ) == .asset(selectedDance)
        )
        #expect(
            StageAvatarResolvedMotion.resolve(
                selectedMotion: selectedDance,
                worldPlayback: .naturalIdle(fallback: nil)
            ) == .asset(selectedDance)
        )
        #expect(
            StageAvatarResolvedMotion.resolve(
                selectedMotion: selectedDance,
                worldPlayback: .naturalIdle(fallback: missingActivity)
            ) == .naturalIdle
        )
        #expect(
            StageAvatarResolvedMotion.resolve(
                selectedMotion: selectedDance,
                worldPlayback: .temporary(approvedActivityMotion)
            ) == .asset(approvedActivityMotion)
        )
    }

    @Test
    func userIdleDoesNotTurnAMissingWorldIdleAssetIntoADanceFallback() {
        let selectedDance = StageMotionAsset(
            id: MotionPackageStore.iluvSlapBassID,
            name: "I Love Slap Bass",
            format: .vmd,
            url: URL(filePath: "/tmp/slap-bass.vmd")
        )
        let authoredIdle = ActivityPhaseContract(
            phase: .loop,
            motionIDs: ["idle.natural"]
        )
        let effectiveContract = LivingWorldAvatarPresentationPolicy
            .phaseContract(
                mode: .userIdle,
                authoredContract: authoredIdle
            )
        let playback = StageAvatarMotionPlayback.resolve(
            activity: .idle,
            phase: .loop,
            phaseContract: effectiveContract,
            approvedMotions: [:]
        )

        #expect(playback == .naturalIdle(fallback: nil))
        #expect(
            StageAvatarResolvedMotion.resolve(
                selectedMotion: selectedDance,
                worldPlayback: playback
            ) == .asset(selectedDance)
        )
    }

    @MainActor
    private final class Fixture {
        let worldID = "world-labs-example-warm-kitchen"
        let defaults: UserDefaults
        let runtime: StageAvatarRuntimeStore
        let stage: SpatialStageStore
        let executor: StageAvatarActivityExecutor

        init() throws {
            let suiteName = "StageAvatarActivityExecutorTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            runtime = StageAvatarRuntimeStore(
                packageStore: nil,
                motionPackageStore: nil
            )
            stage = SpatialStageStore(defaults: defaults)
            stage.selectWorld(id: worldID)
            executor = StageAvatarActivityExecutor(
                runtime: runtime,
                spatialStage: stage,
                worldSpawn: .test(
                    position: .init(x: 0, y: 0, z: 1.1),
                    yaw: 0.67
                )
            )
        }
    }
}

private extension StageAvatarActivityApplyOutcome {
    var appliedSnapshot: StageAvatarWorldActivitySnapshot? {
        guard case let .applied(snapshot) = self else { return nil }
        return snapshot
    }
}

private extension WorldTransform {
    static func test(position: WorldVector3, yaw: Float) -> WorldTransform {
        WorldTransform(
            position: position,
            rotation: WorldQuaternion(
                x: 0,
                y: sin(yaw / 2),
                z: 0,
                w: cos(yaw / 2)
            ),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        )
    }
}
