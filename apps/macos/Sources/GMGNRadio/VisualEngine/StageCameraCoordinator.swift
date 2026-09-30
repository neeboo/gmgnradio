import Foundation
import simd

enum DesktopPresenceMode: Equatable, Sendable {
    case orb
    case liveCam

    /// P1：光球是播放器的桌面身体，随播放器一起进插件。
    /// 电台插件关闭（默认）时这里**永不返回 `.orb`**；没有角色时由调用方
    /// （`GMGNRadioApp.applyDesktopPresence` / `showLiveCam`）走 `LiveCamPresentationRequest`
    /// 的可见引导，而不是退回光球。插件打开时恢复改动前的行为。
    static func resolve(
        snapshot: StageAvatarRuntimeSnapshot,
        isRadioPluginEnabled: Bool
    ) -> DesktopPresenceMode {
        guard isRadioPluginEnabled else { return .liveCam }
        return snapshot.avatar == nil ? .orb : .liveCam
    }
}

/// 「显示 Live Cam」在还没有角色时的可见引导。
///
/// 没有角色时桌面呈现没有可显示的对象（光球随播放器进插件后不再兜底），直接调用
/// `applyDesktopPresence` 会让用户觉得菜单没反应。这里给出可执行的设置路径，
/// 绝不引入默认角色或新权限。
enum LiveCamPresentationRequest: Equatable, Sendable {
    case present
    case needsAvatar(guidance: String)

    static let missingAvatarGuidance =
        "还没有可显示的角色。请打开 设置 → 角色，导入或选择一个角色后再显示 Live Cam。"

    static func resolve(hasAvatar: Bool) -> LiveCamPresentationRequest {
        hasAvatar ? .present : .needsAvatar(guidance: missingAvatarGuidance)
    }
}

/// 「谁可以让 Live Cam 小窗出现」的唯一判据。
///
/// 真机要求（2026-09-30）：小窗**只由用户的显式动作**出现。居民状态播报（语音、
/// 聊天、进度、失败、交付提示）、生活活动开始、走路与角色动作、许愿任务变化都
/// 不许把它顶出来 —— 这些事件只更新状态文字，绝不改变窗口形态。
///
/// 触发源做成值类型而不是散在各个调用点的 `if`：每个调用点都必须声明自己的
/// 来源，离线 harness 能逐条注入并断言，回退时立刻 FAIL。
enum LiveCamPresentationTrigger: Equatable, Sendable, CaseIterable {
    /// 用户显式的小窗动作：菜单「显示 Live Cam」、快捷键、窗口自己的入口。
    case explicitUserAction
    /// 冷启动的默认桌面形态（`ApplicationLaunchPolicy`）。这是产品定义的默认
    /// 入口，不是会话中的「切过去」；它是唯一允许的非显式呈现。
    case launchDefault
    /// 居民状态播报：语音转写、聊天状态、进度、失败与交付提示。
    case residentStatusNotice
    /// 生活活动开始/停止。
    case livingWorldActivityChange
    /// 角色动作（菜单或设置里播放动作）。
    case characterMotionChange
    /// 角色快照变化：选择角色、走路、语音电平、Agent 说话、许愿任务……
    case avatarSnapshotChange

    /// 只有显式动作与冷启动默认形态可以**呈现**小窗。
    var mayPresentLiveCam: Bool {
        switch self {
        case .explicitUserAction, .launchDefault:
            true
        case .residentStatusNotice, .livingWorldActivityChange,
             .characterMotionChange, .avatarSnapshotChange:
            false
        }
    }
}

enum LiveCamPresentationPolicy {
    /// 呈现小窗的完整判据：触发源允许 + 有角色可显示 + 完整空间没有占着渲染面。
    ///
    /// 「空间占着」时返回 false 的语义与改动前一致：**什么都不做**（既不呈现，
    /// 也不把窗口收掉），窗口形态由空间那一侧负责。
    static func shouldPresentLiveCam(
        trigger: LiveCamPresentationTrigger,
        hasAvatar: Bool,
        fullStageIsPresented: Bool
    ) -> Bool {
        guard trigger.mayPresentLiveCam else { return false }
        guard !fullStageIsPresented else { return false }
        return LiveCamPresentationRequest.resolve(hasAvatar: hasAvatar) == .present
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

/// Exponential digester for the avatar-follow camera rotation.
///
/// Living-world snapshots arrive near 30 Hz and each one asks the camera to
/// rotate by its whole bearing step. Applied directly, that rotation is only
/// visible on the render loop's frames, so the world turns in whole 30 Hz
/// jumps (stutter). Instead, snapshot deltas are queued here and each rendered
/// frame consumes a time-proportional fraction, so the camera advances on
/// every rendered frame while the total applied still converges to the total
/// queued — no lost rotation and no late snap-back.
///
/// A gap longer than `gapResetThreshold` means the explicit render loop was
/// paused or the surface was hidden/occluded; the backlog built up during that
/// gap is discarded instead of swinging the camera in a single frame.
struct AvatarFollowYawDigester: Equatable, Sendable {
    /// Exponential time constant for digesting queued follow yaw. ~30 ms keeps
    /// one 33 ms snapshot step spread across roughly two 60 fps frames.
    static let timeConstant: TimeInterval = 0.030
    /// A frame gap at or above this duration is treated as a stopped render
    /// loop (pause/hide/occlusion), not a slow frame: its backlog is dropped.
    static let gapResetThreshold: TimeInterval = 0.5

    private(set) var pending: Float = 0

    var isEmpty: Bool { pending == 0 }

    mutating func enqueue(_ delta: Float) {
        guard delta.isFinite else { return }
        pending += delta
    }

    /// Consumes the queued rotation for one rendered frame of `deltaTime`
    /// seconds. Returns how much rotation was applied; the caller adds it to
    /// the shared camera yaw (the only yaw any pass of the frame reads).
    @discardableResult
    mutating func advance(deltaTime: Float) -> Float {
        guard pending != 0 else { return 0 }
        let seconds = Double(min(max(deltaTime, 0), Float.greatestFiniteMagnitude))
        guard seconds > 0 else { return 0 }
        if seconds >= Self.gapResetThreshold {
            pending = 0
            return 0
        }
        let fraction = Float(1 - exp(-seconds / Self.timeConstant))
        let applied = pending * fraction
        pending -= applied
        return applied
    }

    mutating func cancel() {
        pending = 0
    }
}

/// Decides when a new avatar-follow delta may be queued after the user drove
/// the camera (orbit drag, reset). While the user is actively orbiting, follow
/// rotation is suppressed so it never fights the drag; once the user has been
/// idle for `suppressionInterval`, follow resumes from fresh deltas only —
/// old deltas are never replayed, so there is no late override after release.
enum AvatarFollowUserPolicy {
    static let suppressionInterval: TimeInterval = 1.0

    static func acceptsFollowYaw(secondsSinceUserInteraction age: TimeInterval) -> Bool {
        age >= suppressionInterval
    }
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
        spatialStage.setAvatarFollowActive(true)
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
        // Do not apply the snapshot's whole step to the shared camera right
        // now: the render loop would display it as a 30 Hz jump. Queue it and
        // let every rendered frame digest a fraction instead. While the user
        // is actively orbiting (or just reset) the camera, new follow rotation
        // is suppressed so it cannot fight the drag or arrive late after it.
        guard AvatarFollowUserPolicy.acceptsFollowYaw(
            secondsSinceUserInteraction:
                spatialStage.timeSinceLastCameraYawInteraction
        ) else {
            return
        }
        spatialStage.enqueueAvatarFollowYaw(bearingDelta)
    }

    func activateLiveCam() {
        spatialStage.setAvatarFollowActive(false)
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
