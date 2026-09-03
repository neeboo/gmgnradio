import Foundation
import simd
import Testing
@testable import GMGNRadio

@Suite
struct VRMAvatarMetalViewTests {
    @Test
    func onlyTheCurrentLiveDesktopLoadMayCommitRuntimeStatus() {
        let oldLoad = DesktopAvatarLoadGeneration(revision: 11)
        let currentLoad = DesktopAvatarLoadGeneration(revision: 12)

        #expect(
            !oldLoad.canCommit(
                currentRevision: 12,
                taskIsCancelled: false,
                rendererIsAlive: true
            )
        )
        #expect(
            !currentLoad.canCommit(
                currentRevision: 12,
                taskIsCancelled: true,
                rendererIsAlive: true
            )
        )
        #expect(
            !currentLoad.canCommit(
                currentRevision: 12,
                taskIsCancelled: false,
                rendererIsAlive: false
            )
        )
        #expect(
            currentLoad.canCommit(
                currentRevision: 12,
                taskIsCancelled: false,
                rendererIsAlive: true
            )
        )
    }

    @Test
    func desktopSelectionPreservesTheCompleteVRMRuntimeSelection() throws {
        let modelURL = URL(filePath: "/tmp/avatars/arisu/Arisu.vrm")
        let rootURL = modelURL.deletingLastPathComponent()
        let motionURL = URL(filePath: "/tmp/motions/wave.vmd")
        let avatar = StageAvatarAsset(
            id: "arisu",
            name: "Arisu",
            format: .vrm,
            modelURL: modelURL,
            resourceRootURL: rootURL
        )
        let motion = StageMotionAsset(
            id: "wave",
            name: "Wave",
            format: .vmd,
            url: motionURL
        )
        let snapshot = StageAvatarRuntimeSnapshot(
            avatar: avatar,
            motion: motion,
            revision: 17
        )

        let selection = DesktopPresenceSelection.resolve(snapshot: snapshot)
        let payload = try #require(selection.avatarSelection)

        #expect(selection.kind == .vrm)
        #expect(payload.avatar == avatar)
        #expect(payload.motion == motion)
        #expect(payload.revision == 17)
        #expect(payload.snapshot == snapshot)
    }

    @Test
    func desktopSelectionDistinguishesPMXFromVRMAndTheOrb() {
        let pmx = StageAvatarAsset(
            id: "miku",
            name: "Miku",
            format: .pmx,
            modelURL: URL(filePath: "/tmp/miku/model.pmx"),
            resourceRootURL: URL(filePath: "/tmp/miku")
        )

        let selection = DesktopPresenceSelection.resolve(
            snapshot: StageAvatarRuntimeSnapshot(
                avatar: pmx,
                motion: nil,
                revision: 9
            )
        )

        #expect(selection.kind == .pmx)
        #expect(selection.avatarSelection?.avatar == pmx)
        #expect(
            DesktopPresenceSelection.resolve(
                snapshot: StageAvatarRuntimeSnapshot(
                    avatar: nil,
                    motion: nil,
                    revision: 10
                )
            ) == .orb
        )
    }

    @Test
    func desktopPMXUsesNaturalIdleEvenWhenTheStageHasADanceSelected() {
        let selection = DesktopAvatarSelection(
            avatar: StageAvatarAsset(
                id: "2b",
                name: "2B",
                format: .pmx,
                modelURL: URL(filePath: "/tmp/2b/23.pmx"),
                resourceRootURL: URL(filePath: "/tmp/2b")
            ),
            motion: StageMotionAsset(
                id: "dance",
                name: "Dance",
                format: .vmd,
                url: URL(filePath: "/tmp/dance.vmd")
            ),
            revision: 1
        )

        #expect(
            DesktopPMXMotionPolicy.resolvedMotionURL(for: selection) == nil
        )
    }

    @Test
    func desktopPMXFramingLeavesHeadAndFeetInsideTheViewport() {
        let bounds = PMXAvatarBounds(
            minimum: SIMD3<Float>(-50, 0, -30),
            maximum: SIMD3<Float>(50, 170, 30)
        )
        let matrices = DesktopPMXFraming.matrices(
            bounds: bounds,
            drawableSize: CGSize(width: 300, height: 520)
        )

        for y in [bounds.minimum.y, bounds.maximum.y] {
            let world = SIMD4<Float>(
                bounds.center.x,
                y,
                bounds.center.z,
                1
            )
            let clip = simd_mul(
                matrices.projection,
                simd_mul(matrices.view, world)
            )
            let normalizedY = clip.y / clip.w
            #expect(abs(normalizedY) < 0.9)
        }
    }


    @Test
    func desktopPMXCameraCanOrbitPanAndZoomWithinSafeLimits() {
        var camera = DesktopPMXCameraState.default
        camera.rotate(deltaX: 180, deltaY: -80)
        camera.pan(deltaX: 50, deltaY: -30, modelHeight: 170)
        camera.zoom(delta: 20)

        #expect(camera.yaw != 0)
        #expect(camera.pitch > 0)
        #expect(camera.pan.x > 0)
        #expect(camera.pan.y < 0)
        #expect(camera.zoom > 1)

        camera.rotate(deltaX: 0, deltaY: 100_000)
        camera.zoom(delta: -100_000)
        #expect(abs(camera.pitch) <= DesktopPMXCameraState.maximumPitch)
        #expect(camera.zoom == DesktopPMXCameraState.minimumZoom)
    }

    @Test
    func desktopPMXFramingAppliesTheInteractiveCamera() {
        let bounds = PMXAvatarBounds(
            minimum: SIMD3<Float>(-50, 0, -30),
            maximum: SIMD3<Float>(50, 170, 30)
        )
        var camera = DesktopPMXCameraState.default
        camera.rotate(deltaX: 200, deltaY: 0)
        camera.zoom(delta: 8)
        let adjusted = DesktopPMXFraming.matrices(
            bounds: bounds,
            drawableSize: CGSize(width: 300, height: 520),
            camera: camera
        )
        let original = DesktopPMXFraming.matrices(
            bounds: bounds,
            drawableSize: CGSize(width: 300, height: 520)
        )

        #expect(adjusted.view != original.view)
    }

    @Test
    func liveCamFramingFollowsAllAnimatedRootTranslationAxes() {
        let bounds = PMXAvatarBounds(
            minimum: SIMD3<Float>(-50, 0, -30),
            maximum: SIMD3<Float>(50, 170, 30)
        )
        let rootOffset = SIMD3<Float>(13, 47, -29)
        let original = DesktopPMXFraming.matrices(
            bounds: bounds,
            drawableSize: CGSize(width: 300, height: 520)
        )
        let followed = DesktopPMXFraming.matrices(
            bounds: bounds,
            drawableSize: CGSize(width: 300, height: 520),
            trackingOffset: rootOffset
        )
        let originalCenter = SIMD4<Float>(bounds.center, 1)
        let movedCenter = SIMD4<Float>(bounds.center + rootOffset, 1)
        let originalClip = original.projection * original.view * originalCenter
        let followedClip = followed.projection * followed.view * movedCenter

        #expect(abs(originalClip.x / originalClip.w - followedClip.x / followedClip.w) < 0.0001)
        #expect(abs(originalClip.y / originalClip.w - followedClip.y / followedClip.w) < 0.0001)
        #expect(abs(originalClip.z / originalClip.w - followedClip.z / followedClip.w) < 0.0001)
    }

    @Test
    func liveCamTrackingNeverConsumesAuthoredVerticalMotion() {
        let bounds = PMXAvatarBounds(
            minimum: SIMD3<Float>(-50, 0, -30),
            maximum: SIMD3<Float>(50, 170, 30)
        )
        let smallJump = LiveCamPMXTrackingPolicy.cameraOffset(
            animatedRootOffset: SIMD3<Float>(12, 20, -28),
            bounds: bounds
        )
        let largeJump = LiveCamPMXTrackingPolicy.cameraOffset(
            animatedRootOffset: SIMD3<Float>(12, 47, -28),
            bounds: bounds
        )

        #expect(smallJump == SIMD3<Float>(12, 0, -28))
        #expect(abs(largeJump.x - 12) < 0.0001)
        #expect(abs(largeJump.y) < 0.0001)
        #expect(abs(largeJump.z + 28) < 0.0001)
        #expect(abs((47 - largeJump.y) - 47) < 0.0001)
    }

    @Test
    func desktopPMXCameraLockAndViewStatePersistTogether() throws {
        let suite = "desktop-pmx-camera-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = DesktopPMXCameraState.default
        state.rotate(deltaX: 90, deltaY: 20)

        DesktopPMXCameraSettings.save(
            state: state,
            isLocked: false,
            defaults: defaults
        )
        let restored = DesktopPMXCameraSettings.load(defaults: defaults)

        #expect(restored.state == state)
        #expect(!restored.isLocked)
    }

    @Test
    func desktopPMXLeftDragAlwaysMovesThePetWindow() {
        #expect(
            DesktopPMXInteractionPolicy.dragAction(
                buttonNumber: 0,
                shiftPressed: false,
                cameraLocked: true
            ) == .moveWindow
        )
        #expect(
            DesktopPMXInteractionPolicy.dragAction(
                buttonNumber: 0,
                shiftPressed: false,
                cameraLocked: false
            ) == .moveWindow
        )
    }

    @Test
    func desktopPMXRightDragOnlyAdjustsAnUnlockedCamera() {
        #expect(
            DesktopPMXInteractionPolicy.dragAction(
                buttonNumber: 1,
                shiftPressed: false,
                cameraLocked: true
            ) == .none
        )
        #expect(
            DesktopPMXInteractionPolicy.dragAction(
                buttonNumber: 1,
                shiftPressed: false,
                cameraLocked: false
            ) == .orbitCamera
        )
        #expect(
            DesktopPMXInteractionPolicy.dragAction(
                buttonNumber: 1,
                shiftPressed: true,
                cameraLocked: false
            ) == .panCamera
        )
    }
}
