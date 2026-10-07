import Foundation
import Observation
import WorldRuntime

enum StageAvatarFormat: String, Codable, CaseIterable, Sendable {
    case vrm
    case pmx
}

enum StageMotionFormat: String, Codable, CaseIterable, Sendable {
    case procedural
    case vrma
    case vmd
}

struct StageAvatarAsset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let format: StageAvatarFormat
    let modelURL: URL
    let resourceRootURL: URL
}

struct StageMotionAsset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL?
    let version: String?
    let sha256: String?
    let loop: Bool
    /// Authored navigation speed for an in-place locomotion clip, in meters
    /// per second. Nil means the motion is not a locomotion contract.
    let strideSpeed: Float?
    /// Playback multiplier required to reproduce the authored cadence.
    let playbackRate: Float
    /// True when horizontal movement is supplied by the world simulation.
    let inPlace: Bool?

    init(
        id: String,
        name: String,
        format: StageMotionFormat,
        url: URL?,
        version: String? = nil,
        sha256: String? = nil,
        loop: Bool = true,
        strideSpeed: Float? = nil,
        playbackRate: Float = 1,
        inPlace: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.url = url
        self.version = version
        self.sha256 = sha256
        self.loop = loop
        self.strideSpeed = strideSpeed
        self.playbackRate = playbackRate
        self.inPlace = inPlace
    }
}

struct StageMotionLocomotion: Equatable, Sendable {
    let strideSpeed: Float
    let playbackRate: Float
    let inPlace: Bool
}

extension StageMotionAsset {
    func applyingLocomotionFallback(
        _ fallback: StageMotionLocomotion
    ) -> StageMotionAsset {
        StageMotionAsset(
            id: id,
            name: name,
            format: format,
            url: url,
            version: version,
            sha256: sha256,
            loop: loop,
            strideSpeed: strideSpeed ?? fallback.strideSpeed,
            playbackRate: playbackRate == 1
                ? fallback.playbackRate
                : playbackRate,
            inPlace: inPlace ?? fallback.inPlace
        )
    }

    /// A locomotion loop is a looping, in-place clip that carries an authored
    /// ground speed (`strideSpeed`). Idle, sit, and dance loops do not carry a
    /// stride contract, so they never count as locomotion even when the
    /// generator marked them in-place. The check never invents a speed: the
    /// finite positive `strideSpeed` must already be present.
    var isLocomotionLoop: Bool {
        guard loop, inPlace == true,
              let strideSpeed, strideSpeed.isFinite, strideSpeed > 0
        else { return false }
        return true
    }
}

/// Horizontal ground-speed telemetry captured by the world executor between
/// consecutive agent snapshots, plus whether the resolved playback is a
/// locomotion loop.
///
/// Renderers combine this with ``StageLocomotionGait`` to retime the walk clip
/// against the avatar's *actual* travel, so distance per step keeps matching
/// the ground regardless of speed changes or target-rig proportions, without
/// reloading or restarting the clip (phase stays owned by the animation
/// player).
struct StageAvatarLocomotionTelemetry: Equatable, Sendable {
    /// Smoothed horizontal ground speed in meters per second.
    var measuredSpeed: Float = 0
    /// The same travel over a longer window. The world publishes snapshots on
    /// its own cadence while the clip is drawn at the render cadence, so a
    /// single sample can land on a stalled tick; the gait reads this smooth
    /// companion whenever the world is moving the avatar.
    var sustainedSpeed: Float = 0
    /// True while the world is authoritatively translating the avatar (the
    /// executor's walking phase, or observed displacement on the latest tick).
    var isWorldMoving = false
    /// True while the resolved world playback is an in-place locomotion loop.
    var isLocomotionActive = false
    /// Source world revision this measurement was derived from.
    var sourceRevision: UInt64 = 0

    static let standing = StageAvatarLocomotionTelemetry()

    /// Ground speed the visible clip must be retimed against.
    ///
    /// While the world is moving the avatar, the higher of the responsive and
    /// sustained estimates is authoritative: a stalled sample must never
    /// freeze a clip whose body is sliding across the floor. Once the world
    /// stops moving the avatar, only the responsive estimate counts, so a
    /// genuine standstill still freezes the clip promptly (no marching in
    /// place, no gait left over from the previous leg).
    var gaitGroundSpeed: Float {
        guard isWorldMoving else { return measuredSpeed }
        return max(measuredSpeed, sustainedSpeed)
    }

    /// Content equality ignoring the informational revision, with speed
    /// quantized to 5 mm/s so a world ticking at 30 Hz does not churn
    /// observers while the avatar cruises at a constant speed.
    func matchesContent(_ other: StageAvatarLocomotionTelemetry) -> Bool {
        isLocomotionActive == other.isLocomotionActive
            && isWorldMoving == other.isWorldMoving
            && abs(measuredSpeed - other.measuredSpeed) <= 0.005
            && abs(sustainedSpeed - other.sustainedSpeed) <= 0.005
    }

    init(
        measuredSpeed: Float = 0,
        sustainedSpeed: Float = 0,
        isWorldMoving: Bool = false,
        isLocomotionActive: Bool = false,
        sourceRevision: UInt64 = 0
    ) {
        self.measuredSpeed = measuredSpeed.isFinite && measuredSpeed >= 0
            ? measuredSpeed
            : 0
        self.sustainedSpeed = sustainedSpeed.isFinite && sustainedSpeed >= 0
            ? sustainedSpeed
            : 0
        self.isWorldMoving = isWorldMoving
        self.isLocomotionActive = isLocomotionActive
        self.sourceRevision = sourceRevision
    }
}

/// Calibration of one locomotion clip applied to one avatar rig: the clip's
/// authored step speed plus the source/target hips heights used to scale it.
///
/// Pure playback math — no clocks, no smoothing, no player state. When either
/// side of the hips ratio is missing, ``heightScale`` stays `1` (never
/// fabricate a correction from absent data); the authored speed is then used
/// unchanged, which reproduces today's constant-speed behavior exactly.
///
/// The type is public because `PMXStageAvatarRenderer` (a public renderer
/// contract) accepts it in `loadMotion(locomotion:)` and re-exposes it through
/// ``loadedLocomotionGait``.
public struct StageLocomotionGait: Equatable, Sendable {
    /// Clip step speed at rate 1 on the reference rig, in meters per second
    /// (VRMA manifest `strideSpeed`, or the measured PMX compatibility).
    public let authoredStepSpeed: Float
    /// Reference rig hips rest height when the clip carries it (VRMA extra).
    public let sourceHipsHeight: Float?
    /// Target avatar hips rest height when it can be measured from the rig.
    public let targetHipsHeight: Float?

    /// Below this ground speed the clip freezes (rate 0) instead of pumping
    /// small steps in place; this is the "stopped, no marching" guarantee.
    public static let freezeSpeed: Float = 0.06
    /// No run clip exists beyond the authored walk, so the adaptive rate is
    /// capped (also mirrors VRMMetalKit's locomotion maximum).
    public static let maximumRate: Float = 1.3

    public init(
        authoredStepSpeed: Float,
        sourceHipsHeight: Float? = nil,
        targetHipsHeight: Float? = nil
    ) {
        self.authoredStepSpeed = authoredStepSpeed.isFinite
            && authoredStepSpeed > 0
            ? authoredStepSpeed
            : 0
        self.sourceHipsHeight = sourceHipsHeight
        self.targetHipsHeight = targetHipsHeight
    }

    /// Bipedal stride scales with hip height as a first-order proxy for leg
    /// length. Clamped so a wildly mis-sized rig cannot produce an absurd
    /// correction; missing data keeps the scale at 1.
    public var heightScale: Float {
        guard let source = sourceHipsHeight, source.isFinite, source > 0,
              let target = targetHipsHeight, target.isFinite, target > 0
        else { return 1 }
        return min(max(target / source, 0.5), 2)
    }

    /// Ground speed the clip implies at rate 1 on this avatar. Keeping the
    /// body's measured travel at this speed (or retiming the clip to it)
    /// plants the feet; any deviation is exactly the moonwalk/slide error.
    public var impliedStepSpeed: Float {
        authoredStepSpeed * heightScale
    }

    /// Playback rate that keeps the clip's steps matched to `groundSpeed`
    /// (meters/second). Zero at standstill (freeze, phase preserved); the
    /// rate is otherwise proportional `groundSpeed / impliedStepSpeed`,
    /// capped at ``maximumRate``.
    public func playbackRate(forGroundSpeed groundSpeed: Float) -> Float {
        let speed = groundSpeed.isFinite ? max(0, groundSpeed) : 0
        guard speed > 0 else { return 0 }
        let implied = impliedStepSpeed
        guard implied.isFinite, implied > 0 else { return 0 }
        if speed < Self.freezeSpeed { return 0 }
        return min(speed / implied, Self.maximumRate)
    }
}

enum StageMotionCompletionPolicy {
    static func shouldReturnToNaturalIdle(
        completedURL: URL,
        selectedMotion: StageMotionAsset?
    ) -> Bool {
        guard let selectedMotion else { return false }
        return !selectedMotion.loop && selectedMotion.url == completedURL
    }
}

enum StageAvatarRuntimeStatus: Equatable, Sendable {
    case disabled
    case available(String)
    case loading(String)
    case ready(String)
    case failed(String)
}

struct StageAvatarRuntimeSnapshot: Equatable, Sendable {
    let avatar: StageAvatarAsset?
    let motion: StageMotionAsset?
    let revision: UInt64

    var modelURL: URL? { avatar?.modelURL }
    var name: String? { avatar?.name }

    init(
        avatar: StageAvatarAsset?,
        motion: StageMotionAsset?,
        revision: UInt64
    ) {
        self.avatar = avatar
        self.motion = motion
        self.revision = revision
    }

    init(modelURL: URL?, name: String?, revision: UInt64) {
        avatar = modelURL.map {
            StageAvatarAsset(
                id: "legacy.vrm.\($0.lastPathComponent)",
                name: name ?? $0.deletingPathExtension().lastPathComponent,
                format: .vrm,
                modelURL: $0,
                resourceRootURL: $0.deletingLastPathComponent()
            )
        }
        motion = nil
        self.revision = revision
    }
}

/// Ephemeral full-body state driven by the deterministic world runtime.
/// Voice/facial activity remains in `StageAvatarRuntimeStore.activity`, while
/// the user's selected avatar and motion remain in `snapshot`.
///
/// The two playback fields answer two different questions on purpose:
///
/// - ``motionPlayback`` — **what the world declared** for this activity and
///   phase, resolved against the approved motion set and nothing else. This is
///   the report channel: the host fails a generated-prop capability's enter
///   phase when this is a natural-idle fallback, because a capability whose
///   receipt-driven motion is missing must not silently "succeed".
/// - ``visualPlayback`` — **what the renderer must play**. It equals
///   ``motionPlayback`` unless the declaration resolved to nothing while the
///   avatar's ground is actually moving, in which case it is the built-in
///   walking clip (see `ResidentLocomotionMotionPolicy`).
///
/// Keeping them apart is what lets a resident that is *walking through* an
/// enter phase look like it is walking without turning "the enter motion is
/// missing" into "the usage succeeded".
struct StageAvatarWorldActivitySnapshot: Equatable, Sendable {
    let transform: WorldTransform
    let activity: LifeActivity
    let phase: LifeActivityPhase
    let motionPlayback: StageAvatarMotionPlayback
    let sourceRevision: UInt64
    var activityRequestID: String? = nil
    var visualPlayback: StageAvatarMotionPlayback? = nil

    /// The clip the renderer plays: the locomotion substitute when one was
    /// needed, otherwise the world's own declaration.
    var renderPlayback: StageAvatarMotionPlayback {
        visualPlayback ?? motionPlayback
    }
}

struct StageMotionPlaybackIdentity: Equatable, Sendable {
    let motion: StageMotionAsset
    let snapshotRevision: UInt64
    let worldActivityRequestID: String?
    let worldActivityPhase: LifeActivityPhase?
}

enum StageMotionPlaybackOutcome: Equatable, Sendable {
    case completed
    case failed(String)
}

struct StageMotionPlaybackEvent: Equatable, Sendable {
    let identity: StageMotionPlaybackIdentity
    let outcome: StageMotionPlaybackOutcome
}

@MainActor
@Observable
final class StageAvatarRuntimeStore {
    static let shared = StageAvatarRuntimeStore()

    private(set) var snapshot = StageAvatarRuntimeSnapshot(
        avatar: nil,
        motion: nil,
        revision: 0
    )
    private(set) var status: StageAvatarRuntimeStatus = .disabled
    private(set) var activity: StageAvatarActivity = .idle
    private(set) var voiceLevel: Float = 0
    /// nil keeps the legacy face path; an active zero sample closes the mouth.
    private(set) var residentSpeechLevel: Float?
    private(set) var worldActivity: StageAvatarWorldActivitySnapshot?
    /// Measured ground speed + locomotion-active flag for the visible avatar.
    /// The world executor updates this on every applied snapshot tick so
    /// renderers can retime an active walk clip without restarting it.
    private(set) var locomotion = StageAvatarLocomotionTelemetry.standing
    private var residentThinkingRunID: UUID?
    private var installedResidentMotions: [StageMotionAsset] = []

    var isResidentThinking: Bool { residentThinkingRunID != nil }

    /// Resident full-body clips come from installed BONES packages. Missing
    /// clips remain unavailable; never substitute an authored pose.
    var residentThinkingMotion: StageMotionAsset? {
        guard isResidentThinking else { return nil }
        return residentLoopMotion("thinking-loop", avatarFormat: snapshot.avatar?.format)
    }

    var residentIdleMotion: StageMotionAsset? {
        residentLoopMotion("idle-loop", avatarFormat: snapshot.avatar?.format)
    }

    var residentHoldDisplayMotion: StageMotionAsset? {
        residentLoopMotion("hold-display", avatarFormat: snapshot.avatar?.format)
    }

    private func residentLoopMotion(
        _ name: String, avatarFormat: StageAvatarFormat?
    ) -> StageMotionAsset? {
        guard let avatarFormat else { return nil }
        let suffix = avatarFormat == .pmx ? "pmx" : "vrm"
        let format: StageMotionFormat = avatarFormat == .pmx ? .vmd : .vrma
        return installedResidentMotions.first {
            $0.id == "gmgn.motion.bones.\(name)-\(suffix)"
                && $0.format == format && $0.url != nil && $0.loop
        }
    }

    private let packageStore: PresencePackageStore?
    private let motionPackageStore: MotionPackageStore?
    @ObservationIgnored
    private var observers: [UUID: (StageAvatarRuntimeSnapshot) -> Void] = [:]
    @ObservationIgnored
    private var motionPlaybackObservers: [UUID: (StageMotionPlaybackEvent) -> Void] = [:]
    @ObservationIgnored
    private var terminalPlaybackIdentities: [StageMotionPlaybackIdentity] = []

    init(
        packageStore: PresencePackageStore? = try? .liveStore(),
        motionPackageStore: MotionPackageStore? = try? .liveStore()
    ) {
        self.packageStore = packageStore
        self.motionPackageStore = motionPackageStore
    }

    @discardableResult
    func observe(
        _ observer: @escaping (StageAvatarRuntimeSnapshot) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    func refresh(forcePlaybackReload: Bool = false) {
        var avatar = snapshot.avatar
        var motion = snapshot.motion
        var refreshError: Error?

        if let packageStore {
            do {
                avatar = try packageStore.activeAvatar()
            } catch {
                refreshError = error
            }
        } else {
            avatar = nil
        }

        if let motionPackageStore {
            do {
                installedResidentMotions = try motionPackageStore.listMotions()
                motion = try motionPackageStore.activeMotion()
            } catch {
                installedResidentMotions = []
                refreshError = refreshError ?? error
            }
        } else {
            installedResidentMotions = []
            motion = nil
        }

        // Preserve the user's verified selection, including VRMA and imported
        // clips. Only natural/procedural idle needs a humanoid idle resource.
        if motion == nil || motion?.format == .procedural {
            motion = residentLoopMotion("idle-loop", avatarFormat: avatar?.format)
        }

        setSnapshot(avatar: avatar, motion: motion, forcePlaybackReload: forcePlaybackReload)
        if let refreshError {
            status = .failed(refreshError.localizedDescription)
        } else if let avatar {
            status = .available(avatar.name)
        } else {
            status = .disabled
        }
    }

    func finishOneShotMotion(at completedURL: URL) {
        guard StageMotionCompletionPolicy.shouldReturnToNaturalIdle(
            completedURL: completedURL,
            selectedMotion: snapshot.motion
        ), let motionPackageStore
        else {
            return
        }
        do {
            try motionPackageStore.activate(id: MotionPackageStore.naturalIdleID)
            refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Playback identity of one motion.
    ///
    /// Identity is attached only to the world's **declared** playback
    /// (``StageAvatarWorldActivitySnapshot/motionPlayback``), never to the
    /// locomotion substitute in ``StageAvatarWorldActivitySnapshot/visualPlayback``:
    /// the built-in walk clip is not the world's contract, so its completion
    /// or failure must not be written back as a world receipt (that would let
    /// an asset the world never declared fail or finish its activity).
    func playbackIdentity(for motion: StageMotionAsset) -> StageMotionPlaybackIdentity {
        let world: StageAvatarWorldActivitySnapshot?
        if case let .temporary(activeMotion) = worldActivity?.motionPlayback,
           activeMotion == motion {
            world = worldActivity
        } else {
            world = nil
        }
        return StageMotionPlaybackIdentity(
            motion: motion,
            snapshotRevision: snapshot.revision,
            worldActivityRequestID: world?.activityRequestID,
            worldActivityPhase: world?.phase
        )
    }

    @discardableResult
    func observeMotionPlayback(_ observer: @escaping (StageMotionPlaybackEvent) -> Void) -> UUID {
        let id = UUID()
        motionPlaybackObservers[id] = observer
        return id
    }

    func removeMotionPlaybackObserver(_ id: UUID?) {
        guard let id else { return }
        motionPlaybackObservers[id] = nil
    }

    func reportMotionPlayback(
        identity: StageMotionPlaybackIdentity,
        outcome: StageMotionPlaybackOutcome
    ) {
        guard playbackIdentity(for: identity.motion) == identity,
              !terminalPlaybackIdentities.contains(identity)
        else { return }
        if outcome == .completed, identity.motion.loop { return }
        terminalPlaybackIdentities.append(identity)
        if terminalPlaybackIdentities.count > 32 {
            terminalPlaybackIdentities.removeFirst()
        }
        if case let .failed(message) = outcome { status = .failed(message) }
        let event = StageMotionPlaybackEvent(identity: identity, outcome: outcome)
        for observer in Array(motionPlaybackObservers.values) { observer(event) }
        // World activity completion is owned by the world bridge. A stale
        // renderer must never clear a replacement user selection.
        if outcome == .completed,
           identity.worldActivityPhase == nil,
           snapshot.revision == identity.snapshotRevision,
           snapshot.motion == identity.motion,
           let url = identity.motion.url {
            finishOneShotMotion(at: url)
        }
    }

    func setActivity(_ activity: StageAvatarActivity) {
        self.activity = activity
        if activity != .speaking {
            voiceLevel = 0
        }
    }

    func setVoiceLevel(_ level: Float) {
        voiceLevel = min(max(level, 0), 1)
    }

    func setResidentSpeechPlayback(isPlaying: Bool, level: Float) {
        residentSpeechLevel = isPlaying
            ? (level.isFinite ? min(max(level, 0), 1) : 0)
            : nil
    }

    func beginResidentThinking(runID: UUID) {
        residentThinkingRunID = runID
    }

    func endResidentThinking(runID: UUID) {
        guard residentThinkingRunID == runID else { return }
        residentThinkingRunID = nil
    }

    func clearResidentThinking() {
        residentThinkingRunID = nil
    }

    func installWorldActivity(_ activity: StageAvatarWorldActivitySnapshot) {
        worldActivity = activity
    }

    /// Commits ground-speed telemetry measured by the world executor. Content
    /// is coalesced (speed quantized to 5 mm/s, revision ignored) so a paused
    /// or constant-speed world does not churn observers every tick.
    func updateLocomotion(_ telemetry: StageAvatarLocomotionTelemetry) {
        guard !locomotion.matchesContent(telemetry) else { return }
        locomotion = telemetry
    }

    func clearWorldActivity() {
        worldActivity = nil
    }

    func markLoading() {
        guard let name = snapshot.name else { return }
        status = .loading(name)
    }

    func markReady() {
        guard let name = snapshot.name else { return }
        status = .ready(name)
    }

    func markFailed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    private func setSnapshot(
        avatar: StageAvatarAsset?,
        motion: StageMotionAsset?,
        forcePlaybackReload: Bool = false
    ) {
        guard forcePlaybackReload || snapshot.avatar != avatar || snapshot.motion != motion else {
            return
        }
        snapshot = StageAvatarRuntimeSnapshot(
            avatar: avatar,
            motion: motion,
            revision: snapshot.revision &+ 1
        )
        for observer in observers.values {
            observer(snapshot)
        }
    }
}
