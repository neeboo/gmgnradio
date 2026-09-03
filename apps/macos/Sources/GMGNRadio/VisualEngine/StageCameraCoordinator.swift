import Foundation
import simd

enum DesktopPresenceMode: Equatable, Sendable {
    case orb
    case liveCam

    static func resolve(
        snapshot: StageAvatarRuntimeSnapshot
    ) -> DesktopPresenceMode {
        snapshot.avatar == nil ? .orb : .liveCam
    }
}

enum LiveCamRenderProfile: Equatable, Sendable {
    case liveCam
    case fullStage

    var drawsWorld: Bool { self == .fullStage }
    var drawsAvatar: Bool { true }
    var drawsEnvironment: Bool { self == .fullStage }
}

struct LiveCamCameraFrame: Equatable, Sendable {
    let position: SIMD3<Float>
    let target: SIMD3<Float>
}

struct LiveCamCharacterOrbit: Equatable, Sendable {
    static let minimumPitch: Float = -0.75
    static let maximumPitch: Float = 0.35
    static let minimumDistance: Float = 0.85
    static let maximumDistance: Float = 2.8

    private(set) var yaw: Float
    private(set) var pitch: Float
    private(set) var distance: Float
    private(set) var targetHeight: Float

    init(
        yaw: Float = 0.35,
        pitch: Float = -0.18,
        distance: Float = 1.45,
        targetHeight: Float = 0.72
    ) {
        self.yaw = yaw
        self.pitch = Self.clampPitch(pitch)
        self.distance = Self.clampDistance(distance)
        self.targetHeight = max(targetHeight, 0)
    }

    mutating func rotate(deltaYaw: Float, deltaPitch: Float) {
        yaw = (yaw + deltaYaw).truncatingRemainder(
            dividingBy: 2 * .pi
        )
        pitch = Self.clampPitch(pitch + deltaPitch)
    }

    mutating func setDistance(_ distance: Float) {
        self.distance = Self.clampDistance(distance)
    }

    func camera(following position: SIMD3<Float>) -> LiveCamCameraFrame {
        // Keep the desktop camera level stable while the avatar's authored
        // motion is free to jump, sit, or otherwise change root height.
        let target = SIMD3<Float>(position.x, targetHeight, position.z)
        let horizontalDistance = cos(pitch) * distance
        let offset = SIMD3<Float>(
            sin(yaw) * horizontalDistance,
            -sin(pitch) * distance,
            cos(yaw) * horizontalDistance
        )
        return LiveCamCameraFrame(position: target + offset, target: target)
    }

    private static func clampPitch(_ pitch: Float) -> Float {
        min(max(pitch, minimumPitch), maximumPitch)
    }

    private static func clampDistance(_ distance: Float) -> Float {
        min(max(distance, minimumDistance), maximumDistance)
    }
}

enum StageCameraOwner: Equatable, Sendable {
    case liveCamDirector
    case fullStageUser
}

enum FullStageCameraEntryPolicy {
    static let minimumHorizontalDistanceFromAvatar: Float = 1.0

    static func resolve(
        savedCamera: SpatialCameraState?,
        fallbackCamera: SpatialCameraState,
        avatarPosition: SIMD3<Float>
    ) -> SpatialCameraState {
        guard let savedCamera,
              savedCamera.position.x.isFinite,
              savedCamera.position.y.isFinite,
              savedCamera.position.z.isFinite
        else {
            return fallbackCamera
        }
        let horizontalOffset = SIMD2<Float>(
            savedCamera.position.x - avatarPosition.x,
            savedCamera.position.z - avatarPosition.z
        )
        guard simd_length(horizontalOffset)
                >= minimumHorizontalDistanceFromAvatar
        else {
            return fallbackCamera
        }
        return savedCamera
    }
}

@MainActor
final class StageCameraCoordinator {
    private let spatialStage: SpatialStageStore
    private let onDirectorPauseChange: @MainActor (Bool) -> Void
    private var directorCamera: SpatialCameraState
    private var userCamera: SpatialCameraState?

    private(set) var owner: StageCameraOwner = .liveCamDirector
    private(set) var isDirectorPaused = false

    init(
        spatialStage: SpatialStageStore,
        onDirectorPauseChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.spatialStage = spatialStage
        self.onDirectorPauseChange = onDirectorPauseChange
        directorCamera = spatialStage.camera
    }

    var savedDirectorCamera: SpatialCameraState {
        directorCamera
    }

    var savedUserCamera: SpatialCameraState? {
        userCamera
    }

    func updateDirectorCamera(_ camera: SpatialCameraState) {
        directorCamera = camera
        guard owner == .liveCamDirector else { return }
        spatialStage.camera = camera
    }

    func activateFullStage(defaultCamera: SpatialCameraState? = nil) {
        guard owner != .fullStageUser else { return }
        directorCamera = spatialStage.camera
        let fallbackCamera = defaultCamera ?? directorCamera
        let nextCamera = FullStageCameraEntryPolicy.resolve(
            savedCamera: userCamera,
            fallbackCamera: fallbackCamera,
            avatarPosition: spatialStage.avatarPlacement.position
        )
        owner = .fullStageUser
        setDirectorPaused(true)
        spatialStage.camera = nextCamera
    }

    func captureUserCamera() {
        guard owner == .fullStageUser else { return }
        userCamera = spatialStage.camera
    }

    func followAvatarHorizontally(
        from previousPosition: SIMD3<Float>,
        to currentPosition: SIMD3<Float>
    ) {
        guard owner == .fullStageUser else { return }
        let cameraPosition = spatialStage.camera.position
        let previousOffset = SIMD2<Float>(
            previousPosition.x - cameraPosition.x,
            previousPosition.z - cameraPosition.z
        )
        let currentOffset = SIMD2<Float>(
            currentPosition.x - cameraPosition.x,
            currentPosition.z - cameraPosition.z
        )
        guard simd_length_squared(previousOffset) > 0.0001,
              simd_length_squared(currentOffset) > 0.0001
        else {
            return
        }
        let previousBearing = atan2(-previousOffset.x, -previousOffset.y)
        let currentBearing = atan2(-currentOffset.x, -currentOffset.y)
        var bearingDelta = currentBearing - previousBearing
        if bearingDelta > .pi {
            bearingDelta -= 2 * .pi
        } else if bearingDelta < -.pi {
            bearingDelta += 2 * .pi
        }
        guard bearingDelta.isFinite else { return }
        spatialStage.camera.yaw += bearingDelta
    }

    func activateLiveCam() {
        if owner == .fullStageUser {
            userCamera = spatialStage.camera
        }
        guard owner != .liveCamDirector || isDirectorPaused else { return }
        owner = .liveCamDirector
        spatialStage.clearMovement()
        spatialStage.camera = directorCamera
        setDirectorPaused(false)
    }

    private func setDirectorPaused(_ paused: Bool) {
        guard isDirectorPaused != paused else { return }
        isDirectorPaused = paused
        onDirectorPauseChange(paused)
    }
}
