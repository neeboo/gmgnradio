import Foundation
import Metal
import simd
import Testing
import WorldRuntime
@testable import GMGNRadio

@MainActor
final class PrivateStageSettingsFixture {
    let authority: PrivatePresenceAuthorityFixture
    let settings: RustProductSettingsClient
    private init(authority: PrivatePresenceAuthorityFixture) {
        self.authority = authority
        self.settings = Self.client(authority: authority)
    }
    private static func client(authority: PrivatePresenceAuthorityFixture) -> RustProductSettingsClient {
        let transport = TaskdHTTPAuthorityClient(endpointFile: authority.root.appendingPathComponent("TaskService/taskd.endpoint.json").path,
            helperPath: "", allowsLaunching: false, timeout: 5)
        return RustProductSettingsClient(call: { [authority] method, data in
            // Retain this exact private daemon until every consumer is released.
            defer { withExtendedLifetime(authority) {} }
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RustProductSettingsClient.SettingsError.invalidProtocol
            }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        })
    }
    static func start(defaults: UserDefaults? = nil) async throws -> PrivateStageSettingsFixture {
        let fixture = PrivateStageSettingsFixture(authority: try await PrivatePresenceAuthorityFixture.start())
        let legacy = defaults?.dictionaryRepresentation().filter {
            $0.key.hasPrefix("ai.gmgn.radio.spatial.avatar-position.") || $0.key == "stage.point-cloud-choice" || $0.key == "stage.particle-size-multiplier"
        } ?? [:]
        _ = try await fixture.settings.importStageLegacy(legacy: legacy)
        return fixture
    }
    func reopenedSettings() async throws -> RustProductSettingsClient {
        let client = Self.client(authority: authority)
        try await client.ensureLoaded()
        return client
    }
    static func spatial() async throws -> SpatialStageStore {
        let fixture = try await start()
        let store = SpatialStageStore(defaults: UserDefaults(suiteName: "private-stage-" + UUID().uuidString)!, settings: fixture.settings)
        try await store.awaitSettingsReady()
        return store
    }
}

@Test
func cameraForwardMovementFollowsPitchAtConstantSpeed() {
    let origin = SIMD3<Float>(2, 3, 4)
    for pitch: Float in [-1.2, -0.6, 0, 0.6, 1.2] {
        for yaw: Float in [-1.4, 0, 1.4] {
            var camera = SpatialCameraState(position: origin, yaw: yaw, pitch: pitch)
            camera.move(.forward, distance: 2.5)
            let delta = camera.position - origin
            #expect(abs(delta.y - sin(pitch) * 2.5) < 0.00001)
            #expect(abs(delta.x + sin(yaw) * cos(pitch) * 2.5) < 0.00001)
            #expect(abs(delta.z + cos(yaw) * cos(pitch) * 2.5) < 0.00001)
            #expect(abs(simd_length(delta) - 2.5) < 0.00001)
            camera.move(.backward, distance: 2.5)
            #expect(simd_distance(camera.position, origin) < 0.00001)
        }
    }
}

@Test
func cameraLateralMovementStaysHorizontalWhileLookingUpOrDown() {
    for pitch: Float in [-1.2, 1.2] {
        for direction in [SpatialMovement.left, .right] {
            var camera = SpatialCameraState(position: .zero, yaw: 0.7, pitch: pitch)
            camera.move(direction, distance: 2.5)
            #expect(camera.position.y == 0)
            #expect(abs(simd_length(camera.position) - 2.5) < 0.00001)
        }
    }
}

@Test
func spatialAvatarUsesOnlyPreparedMeshOccluderDepth() {
    #expect(MarbleSpatialDepthPolicy.usesAlphaAwareDepth)
    #expect(MarbleSpatialDepthPolicy.avatarUsesSceneDepth)

    let withoutOccluder = MTLRenderPassDescriptor()
    withoutOccluder.depthAttachment.loadAction = .load
    MarbleSpatialDepthPolicy.configureAvatarDepth(
        withoutOccluder,
        hasPreparedOccluder: false,
        convention: .metalForward
    )
    #expect(withoutOccluder.depthAttachment.loadAction == .clear)
    #expect(withoutOccluder.depthAttachment.clearDepth == 1)

    let withOccluder = MTLRenderPassDescriptor()
    withOccluder.depthAttachment.loadAction = .clear
    MarbleSpatialDepthPolicy.configureAvatarDepth(
        withOccluder,
        hasPreparedOccluder: true,
        convention: .sceneKitReverse
    )
    #expect(withOccluder.depthAttachment.loadAction == .load)
    #expect(withOccluder.depthAttachment.clearDepth == 0)
}

@Test
func marbleOccluderMeshFlattensCollisionTrianglesForMetal() {
    let triangles = [
        WorldTriangle(
            SIMD3<Float>(1, 2, 3),
            SIMD3<Float>(4, 5, 6),
            SIMD3<Float>(7, 8, 9)
        ),
    ]

    #expect(
        MarbleOccluderMesh.positions(for: triangles) == [
            SIMD3<Float>(1, 2, 3),
            SIMD3<Float>(4, 5, 6),
            SIMD3<Float>(7, 8, 9),
        ]
    )
}

@Test
func marbleOccluderDepthMatchesTheActiveAvatarRenderer() {
    let pmx = MarbleSceneDepthConvention.resolve(avatarFormat: .pmx)
    #expect(pmx == .sceneKitReverse)
    #expect(pmx.compareFunction == .greater)
    #expect(pmx.clearDepth == 0)
    #expect(abs(pmx.convert(0.95019) - 0.04981) < 0.00001)

    let vrm = MarbleSceneDepthConvention.resolve(avatarFormat: .vrm)
    #expect(vrm == .metalForward)
    #expect(vrm.compareFunction == .less)
    #expect(vrm.clearDepth == 1)
    #expect(vrm.convert(0.95019) == 0.95019)
}

@MainActor
@Test
func spatialStagePublishesAndClearsPreparedOccluderTriangles() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    let triangles = [
        WorldTriangle(.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)),
    ]

    store.installSceneOccluderTriangles(triangles)
    #expect(store.sceneOccluderRevision == 1)
    #expect(store.sceneOccluderTriangles == triangles)

    store.selectWorld(id: "another-world")
    #expect(store.sceneOccluderRevision == 2)
    #expect(store.sceneOccluderTriangles.isEmpty)
}

@Test
func spatialScenePresetsDescribeCompleteRooms() {
    #expect(SpatialScenePreset.allCases == [.djHouse, .cosyWoodHouse])
    #expect(SpatialScenePreset.djHouse.displayName == "DJ House")
    #expect(SpatialScenePreset.cosyWoodHouse.displayName == "Cosy Wood House")
    // Generation prompt/model/media contracts are asserted against real Rust
    // claimed actions in MarbleWorldClientTests, not native UI presets.
}

@MainActor
@Test
func spatialEnvironmentEffectsOnlyRenderInsideAnActiveWorld() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    #expect(!store.shouldRenderEnvironmentEffects)

    store.setWorldVisible(true)
    #expect(!store.shouldRenderEnvironmentEffects)

    store.applyEnvironment(weather: .rain)
    #expect(store.shouldRenderEnvironmentEffects)

    store.setWorldVisible(false)
    #expect(!store.shouldRenderEnvironmentEffects)
}

@MainActor
@Test
func selectingAWorldDoesNotReplaceTheStageUntilEntryCompletes() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()

    store.selectWorld(id: "world-1")
    #expect(!store.isWorldPresentationRequested)
    #expect(!store.isWorldVisible)

    store.requestWorldPresentation()
    #expect(store.isWorldPresentationRequested)
    #expect(!store.isWorldVisible)

    store.finishWorldPresentation()
    #expect(store.isWorldVisible)

    store.exitWorld()
    #expect(!store.isWorldPresentationRequested)
    #expect(!store.isWorldVisible)
}

@MainActor
@Test
func worldVisibilityObserversHideTheSpatialSurfaceAfterExit() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    var changes: [Bool] = []
    let observerID = store.observeWorldVisibility { changes.append($0) }

    store.requestWorldPresentation()
    store.finishWorldPresentation()
    store.exitWorld()

    #expect(changes == [false, false, true, false])
    store.removeWorldVisibilityObserver(observerID)
}

@MainActor
@Test
func synchronousWorldFinishDoesNotDeliverStaleLoadingToOtherObservers() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    var changes = [[Bool](), [Bool]()]
    let observerIDs = (0..<2).map { index in
        store.observeWorldVisibility { visible in
            changes[index].append(visible)
            if store.isWorldPresentationRequested, !visible {
                store.finishWorldPresentation()
            }
        }
    }

    // Either dictionary observer can finish first; neither may receive a stale
    // loading notification after its nested visible notification.
    for _ in 0..<2 {
        store.requestWorldPresentation()
        #expect(store.isWorldVisible)
        #expect(changes.allSatisfy { $0.last == true })

        store.exitWorld()
        #expect(!store.isWorldVisible)
        #expect(changes.allSatisfy { $0.last == false })
    }
    observerIDs.forEach { store.removeWorldVisibilityObserver($0) }
}

@MainActor
@Test
func finishingAnAlreadyVisibleWorldDoesNotNotifyObserversAgain() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    var changes: [Bool] = []
    var didReenterFinish = false
    let observerID = store.observeWorldVisibility { visible in
        changes.append(visible)
        if visible, !didReenterFinish {
            didReenterFinish = true
            store.finishWorldPresentation()
        }
    }

    store.requestWorldPresentation()
    store.finishWorldPresentation()

    #expect(changes == [false, false, true])
    store.removeWorldVisibilityObserver(observerID)
}

@MainActor
@Test
func sceneFramingObserversReceiveTheLoadedSPZCalibration() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    let framing = MarbleSceneFraming(
        positions: [
            SIMD3<Float>(-1, -1, -2),
            SIMD3<Float>(1, 1, 2),
        ]
    )
    var received: [MarbleSceneFraming] = []
    let observerID = store.observeSceneFraming { received.append($0) }

    store.installSceneFraming(framing)

    #expect(store.sceneFraming == framing)
    #expect(received == [framing])
    store.removeSceneFramingObserver(observerID)
}

@MainActor
@Test
func spatialCameraMovesRelativeToItsYaw() {
    var camera = SpatialCameraState()
    let start = camera.position

    camera.move(.forward, distance: 2)
    let firstMove = camera.position - start
    #expect(abs(firstMove.x) < 0.0001)
    #expect(firstMove.z < -1.99)

    camera.yaw = .pi / 2
    let beforeTurnedMove = camera.position
    camera.move(.forward, distance: 1)
    #expect((camera.position - beforeTurnedMove).x < -0.99)
}

@MainActor
@Test
func spatialCameraLookClampsPitchAndResetRestoresHome() {
    var camera = SpatialCameraState(
        position: SIMD3<Float>(4, 2, -8),
        yaw: 0.4,
        pitch: 0.2
    )

    camera.look(deltaX: 80, deltaY: -20_000)
    #expect(camera.yaw < 0.4)
    #expect(camera.pitch == SpatialCameraState.maximumPitch)

    camera.reset()
    #expect(camera == SpatialCameraState())
}

@MainActor
@Test
func spatialCameraResetUsesTheLoadedWorldCalibration() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    let calibratedHome = SpatialCameraState(
        position: SIMD3<Float>(0.2, 0.82, 1.1),
        yaw: 0.12,
        pitch: -0.04
    )

    store.installCameraHome(calibratedHome)
    store.move(.forward, distance: 1)
    store.resetCamera()

    #expect(store.camera == calibratedHome)
}

@MainActor
@Test
func spatialEnvironmentUpdatesWithoutReplacingTheWorld() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    store.selectWorld(id: "world-1")

    store.selectScene(.cosyWoodHouse)
    store.applyEnvironment(weather: .thunderstorm)

    #expect(store.selectedWorldID == "world-1")
    #expect(store.selectedScene == .cosyWoodHouse)
    #expect(store.environment.weather == .thunderstorm)
    #expect(store.environment.revision == 1)
}

@MainActor
@Test
func continuousMovementUsesHeldKeysAndShiftSpeed() async throws {
    let store = try await PrivateStageSettingsFixture.spatial()
    store.setMovement(.forward, active: true)
    let home = store.camera.position
    store.stepCamera(deltaTime: 1, speedBoosted: false)
    let normalDistance = simd_length(store.camera.position - home)

    store.camera.reset()
    let resetHome = store.camera.position
    store.stepCamera(deltaTime: 1, speedBoosted: true)
    let boostedDistance = simd_length(store.camera.position - resetHome)

    #expect(boostedDistance > normalDistance * 1.9)
}

@Test
func avatarMotionOnlyOpensTheMouthWhileTheDJIsSpeaking() {
    let idle = StageAvatarMotionFrame.resolve(
        activity: .idle,
        voiceLevel: 0.9,
        time: 1.25
    )
    let speaking = StageAvatarMotionFrame.resolve(
        activity: .speaking,
        voiceLevel: 0.7,
        time: 1.25
    )

    #expect(idle.mouthWeight == 0)
    #expect(speaking.mouthWeight > 0.65)
    #expect(speaking.mouthWeight <= 1)
}

@Test
func avatarMotionKeepsIdleMovementSubtle() {
    let frame = StageAvatarMotionFrame.resolve(
        activity: .idle,
        voiceLevel: 0,
        time: 2.4
    )

    #expect(abs(frame.spineYaw) < 0.04)
    #expect(abs(frame.headTilt) < 0.05)
}

@Test
func avatarMotionFallbackLowersBothArmsFromTheTPose() {
    let frame = StageAvatarMotionFrame.resolve(
        activity: .idle,
        voiceLevel: 0,
        time: 0
    )

    #expect(frame.leftUpperArmDrop > 1.1)
    #expect(frame.rightUpperArmDrop < -1.1)
    #expect(frame.leftElbowBend < -0.2)
    #expect(frame.rightElbowBend > 0.2)
}

@Test
func avatarAnimationPlaybackKeepsIdleCalmAndAddsEnergyWhileSpeaking() {
    let idle = StageAvatarAnimationPlayback.speed(for: .idle)
    let listening = StageAvatarAnimationPlayback.speed(for: .listening)
    let speaking = StageAvatarAnimationPlayback.speed(for: .speaking)

    #expect(idle > 0)
    #expect(listening < idle)
    #expect(speaking > idle)
    #expect(speaking <= 1)
}

@Test
func avatarPlacementUsesAStableAnchorForEachSpatialScene() {
    let studio = StageAvatarPlacement.forScene(.djHouse)
    let kitchen = StageAvatarPlacement.forScene(.cosyWoodHouse)

    #expect(studio != kitchen)
    #expect(studio.scale > 0)
    #expect(kitchen.scale > 0)
    #expect(studio.position.y == 0)
    #expect(kitchen.position.y == 0)
    #expect(kitchen.yaw == 0)
    #expect(kitchen.position.x == 0)
    #expect(SpatialCameraState.defaultHome.position.x == kitchen.position.x)
    #expect(SpatialCameraState.defaultHome.position.y < 1)
    #expect(SpatialCameraState.defaultHome.position.z < 1.5)
    #expect(SpatialCameraState().pitch == SpatialCameraState.defaultHome.pitch)
}

@Test
func publicKitchenWorldsUseTheCosySceneCoordinatePreset() {
    #expect(
        SpatialScenePreset.inferred(
            worldID: "world-labs-example-warm-kitchen",
            name: "Warm Kitchen"
        ) == .cosyWoodHouse
    )
    #expect(
        SpatialScenePreset.inferred(
            worldID: "generated-dj-house",
            name: "gmgn DJ House"
        ) == .djHouse
    )
}

@Suite
struct SpatialWorldCalibrationTests {
    @Test
    func warmKitchenPlacesTheAvatarAtTheCaptureSpawn() throws {
        let calibration = try #require(
            SpatialWorldCalibration.resolve(
                worldID: "world-labs-example-warm-kitchen"
            )
        )
        let placement = try #require(calibration.avatarPlacement)

        #expect(placement.position == SIMD3<Float>(0, 0, 1.1))
        #expect(abs(placement.scale - 0.60) < 0.0001)
        #expect(placement.yaw > 0.6)
        #expect(abs(calibration.cameraHome.position.x) < 0.001)
        #expect(calibration.cameraHome.position.z > placement.position.z)
        #expect(abs(calibration.cameraHome.yaw) < 0.001)
        #expect(calibration.lighting == .warmInterior)
    }

    @MainActor
    @Test
    func reenteringTheLoadedKitchenKeepsItsInstalledAvatarCalibration() async throws {
        let worldID = "world-labs-example-warm-kitchen"
        let calibration = try #require(
            SpatialWorldCalibration.resolve(worldID: worldID)
        )
        let placement = try #require(calibration.avatarPlacement)
        let store = try await PrivateStageSettingsFixture.spatial()

        store.selectScene(.cosyWoodHouse)
        store.selectWorld(id: worldID)
        store.installCameraHome(calibration.cameraHome)
        store.installAvatarPlacement(placement)

        store.selectScene(.cosyWoodHouse)
        store.selectWorld(id: worldID)

        #expect(store.avatarPlacement == placement)
    }

    @MainActor
    @Test
    func avatarPositionAdjustmentsPersistForTheSelectedWorld() async throws {
        let suiteName = "SpatialStageStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let worldID = "world-labs-example-warm-kitchen"
        let calibrated = StageAvatarPlacement(
            position: SIMD3<Float>(0, 0, 1.1),
            scale: 0.6,
            yaw: 0.67
        )

        let fixture = try await PrivateStageSettingsFixture.start(defaults: defaults)
        let firstStore = SpatialStageStore(defaults: defaults, settings: fixture.settings)
        try await firstStore.awaitSettingsReady()
        firstStore.selectWorld(id: worldID)
        firstStore.installAvatarPlacement(calibrated)
        try await firstStore.setAvatarPosition(rawValue: -0.24, axis: "x")
        try await firstStore.setAvatarPosition(rawValue: -0.18, axis: "y")
        try await firstStore.setAvatarPosition(rawValue: 0.76, axis: "z")

        let restoredStore = SpatialStageStore(defaults: defaults, settings: try await fixture.reopenedSettings())
        try await restoredStore.awaitSettingsReady()
        restoredStore.selectWorld(id: worldID)
        restoredStore.installAvatarPlacement(calibrated)

        #expect(
            restoredStore.avatarPlacement.position
                == SIMD3<Float>(-0.24, -0.18, 0.76)
        )
        #expect(restoredStore.avatarPlacement.scale == calibrated.scale)
        #expect(restoredStore.avatarPlacement.yaw == calibrated.yaw)
    }

    @MainActor
    @Test
    func avatarPositionAdjustmentsStayScopedToOneWorld() async throws {
        let suiteName = "SpatialStageStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = StageAvatarPlacement(
            position: SIMD3<Float>(0, 0, 1.1),
            scale: 0.6,
            yaw: 0.67
        )
        let fixture = try await PrivateStageSettingsFixture.start(defaults: defaults)
        let store = SpatialStageStore(defaults: defaults, settings: fixture.settings)
        try await store.awaitSettingsReady()

        store.selectWorld(id: "kitchen-a")
        store.installAvatarPlacement(base)
        try await store.setAvatarPosition(rawValue: 0.42, axis: "x")

        store.selectWorld(id: "kitchen-b")
        store.installAvatarPlacement(base)

        #expect(store.avatarPlacement.position == base.position)
    }

    @MainActor
    @Test
    func resettingAvatarPositionRestoresTheWorldCalibration() async throws {
        let suiteName = "SpatialStageStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = StageAvatarPlacement(
            position: SIMD3<Float>(0.1, -0.04, 0.9),
            scale: 0.6,
            yaw: 0.67
        )
        let fixture = try await PrivateStageSettingsFixture.start(defaults: defaults)
        let store = SpatialStageStore(defaults: defaults, settings: fixture.settings)
        try await store.awaitSettingsReady()

        store.selectWorld(id: "world-labs-example-warm-kitchen")
        store.installAvatarPlacement(base)
        try await store.setAvatarPosition(rawValue: -0.7, axis: "x")
        try await store.resetAvatarPositionConfirmed()

        #expect(store.avatarPlacement == base)
    }

    @Test
    func kitchenCalibrationUsesTheCapturedFloorBelowTheAvatar() throws {
        let calibration = try #require(
            SpatialWorldCalibration.resolve(
                worldID: "world-labs-example-warm-kitchen"
            )
        )
        let placement = try #require(calibration.avatarPlacement)
        let grounded = StageAvatarPlacementSolver.grounded(
            placement: placement,
            normalizedSamples: [
                SpatialSplatSample(
                    position: SIMD3<Float>(-0.03, 0.055, 1.08),
                    horizontalRadius: 0.04,
                    verticalRadius: 0.02
                ),
                SpatialSplatSample(
                    position: SIMD3<Float>(0.04, 0.06, 1.12),
                    horizontalRadius: 0.04,
                    verticalRadius: 0.02
                ),
                SpatialSplatSample(
                    position: SIMD3<Float>(0.02, 0.9, 1.1),
                    horizontalRadius: 0.04,
                    verticalRadius: 0.02
                ),
            ]
        )

        #expect(abs(grounded.position.y - 0.055) < 0.0001)
        #expect(grounded.position.x == placement.position.x)
        #expect(grounded.position.z == placement.position.z)
        #expect(grounded.scale == placement.scale)
        #expect(grounded.yaw == placement.yaw)
    }

    @MainActor
    @Test
    func lateWorldCalibrationRebasesTheTransientAvatarOnTheCapturedFloor() async throws {
        let store = try await PrivateStageSettingsFixture.spatial()
        store.selectWorld(id: "world-labs-example-warm-kitchen")
        store.setTransientAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(-0.4, 0, -0.8),
                scale: 0.82,
                yaw: -1.47
            )
        )

        store.installAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(0, 0.055, 1.1),
                scale: 0.60,
                yaw: 0.67
            )
        )

        #expect(store.avatarPlacement.position == SIMD3<Float>(-0.4, 0.055, 0.3))
        #expect(store.avatarPlacement.scale == 0.60)
        #expect(abs(store.avatarPlacement.yaw - -0.8) < 0.0001)
    }

    @MainActor
    @Test
    func transientWorldHeightIsRelativeToTheCapturedFloor() async throws {
        let store = try await PrivateStageSettingsFixture.spatial()
        store.selectWorld(id: "world-labs-example-warm-kitchen")
        store.installAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(0, 0.055, 1.1),
                scale: 0.60,
                yaw: 0.67
            )
        )

        store.setTransientAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(0.25, 0.20, -1.5),
                scale: 0.82,
                yaw: 0.43
            )
        )

        #expect(store.avatarPlacement.position == SIMD3<Float>(0.25, 0.255, -0.4))
        #expect(store.avatarPlacement.scale == 0.60)
    }

    @MainActor
    @Test
    func worldPlacementUsesTheCalibratedSpawnInsteadOfSavedManualXYZ() async throws {
        let suiteName = "SpatialStageStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let fixture = try await PrivateStageSettingsFixture.start(defaults: defaults)
        let store = SpatialStageStore(defaults: defaults, settings: fixture.settings)
        try await store.awaitSettingsReady()
        store.selectWorld(id: "world-labs-example-warm-kitchen")
        store.installAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(0, 0, 1.1),
                scale: 0.60,
                yaw: 0.67
            )
        )
        try await store.setAvatarPosition(rawValue: -0.09, axis: "y")
        try await store.setAvatarPosition(rawValue: -0.75, axis: "z")

        store.setWorldAvatarPlacement(
            StageAvatarPlacement(
                position: SIMD3<Float>(0, 0, -0.9),
                scale: 0.60,
                yaw: -0.67
            )
        )

        #expect(store.avatarPlacement.position == SIMD3<Float>(0, 0, 0.2))
        #expect(store.avatarPlacement.yaw == 0)
    }
}
