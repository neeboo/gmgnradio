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
struct StageAvatarWorldActivitySnapshot: Equatable, Sendable {
    let transform: WorldTransform
    let activity: LifeActivity
    let phase: LifeActivityPhase
    let motionPlayback: StageAvatarMotionPlayback
    let sourceRevision: UInt64
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
    private(set) var worldActivity: StageAvatarWorldActivitySnapshot?

    private let packageStore: PresencePackageStore?
    private let motionPackageStore: MotionPackageStore?
    @ObservationIgnored
    private var observers: [UUID: (StageAvatarRuntimeSnapshot) -> Void] = [:]

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

    func refresh() {
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
                motion = try motionPackageStore.activeMotion()
            } catch {
                refreshError = refreshError ?? error
            }
        } else {
            motion = nil
        }

        setSnapshot(avatar: avatar, motion: motion)
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

    func setActivity(_ activity: StageAvatarActivity) {
        self.activity = activity
        if activity != .speaking {
            voiceLevel = 0
        }
    }

    func setVoiceLevel(_ level: Float) {
        voiceLevel = min(max(level, 0), 1)
    }

    func installWorldActivity(_ activity: StageAvatarWorldActivitySnapshot) {
        worldActivity = activity
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
        motion: StageMotionAsset?
    ) {
        guard snapshot.avatar != avatar || snapshot.motion != motion else {
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
