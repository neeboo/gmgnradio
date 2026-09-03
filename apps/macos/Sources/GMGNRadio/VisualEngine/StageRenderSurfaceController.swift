import AppKit
import os

enum StageRenderSurfaceOwner: Equatable, Sendable {
    case detached
    case liveCam
    case fullStage
}

enum StageRenderQuality: Equatable, Sendable {
    case full
    case balanced
    case low

    var framesPerSecond: Int {
        switch self {
        case .full:
            60
        case .balanced:
            24
        case .low:
            12
        }
    }

    var renderScale: CGFloat {
        switch self {
        case .full:
            1
        case .balanced:
            0.6
        case .low:
            0.45
        }
    }
}

struct StageRenderActivityState: Equatable, Sendable {
    let isPaused: Bool
    let isHidden: Bool

    static func resolve(
        owner: StageRenderSurfaceOwner,
        isOwnerVisible: Bool,
        isOwnerOccluded: Bool,
        isWorldPresentationRequested: Bool = false,
        isWorldPresentationVisible: Bool
    ) -> Self {
        let contentIsAvailable = switch owner {
        case .liveCam:
            true
        case .fullStage:
            isWorldPresentationRequested || isWorldPresentationVisible
        case .detached:
            false
        }
        let active = owner != .detached
            && isOwnerVisible
            && !isOwnerOccluded
            && contentIsAvailable
        return Self(
            isPaused: !active,
            isHidden: !contentIsAvailable
        )
    }
}

enum StageRenderLoopMode: Equatable, Sendable {
    case stopped
    case manual(framesPerSecond: Int)

    static func resolve(
        activity: StageRenderActivityState,
        quality: StageRenderQuality
    ) -> Self {
        guard !activity.isPaused else { return .stopped }
        return .manual(framesPerSecond: quality.framesPerSecond)
    }
}

enum StageWindowOcclusionPolicy {
    static func isOccluded(
        isVisible: Bool,
        isMiniaturized: Bool
    ) -> Bool {
        isVisible && isMiniaturized
    }
}

@MainActor
final class StageRenderSurfaceController {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "StageRenderSurfaceController"
    )

    let surfaceView: MarbleSpatialView

    private let spatialStage: SpatialStageStore
    private var worldVisibilityObserverID: UUID?
    private(set) var owner: StageRenderSurfaceOwner = .detached
    private(set) var quality: StageRenderQuality = .balanced
    private var isOwnerVisible = false
    private var isOwnerOccluded = false
    private var isWorldPresentationVisible = false
    private var liveCamOrbit = LiveCamCharacterOrbit()
    private var renderLoopTask: Task<Void, Never>?
    private var renderLoopMode = StageRenderLoopMode.stopped

    init(
        spatialStage: SpatialStageStore,
        library: MarbleWorldLibrary,
        avatarRuntime: StageAvatarRuntimeStore = .shared
    ) {
        self.spatialStage = spatialStage
        isWorldPresentationVisible = spatialStage.isWorldVisible
        surfaceView = MarbleSpatialView(
            frame: .zero,
            spatialStage: spatialStage,
            library: library,
            avatarRuntime: avatarRuntime
        )
        surfaceView.identifier = NSUserInterfaceItemIdentifier(
            "stage.marble-spatial-world"
        )
        surfaceView.autoresizingMask = [.width, .height]
        surfaceView.layer?.zPosition = 1.5
        surfaceView.applyRenderProfile(.liveCam)
        surfaceView.prewarmSelectedWorld()
        worldVisibilityObserverID = spatialStage.observeWorldVisibility {
            [weak self] visible in
            self?.setWorldPresentationVisible(visible)
        }
        applyRenderState()
    }

    func attachToLiveCam(_ container: NSView) {
        // Switch the shared renderer before attaching it to a visible window.
        // Otherwise AppKit can request one frame using the previous owner's
        // camera/projection while the view is being reparented.
        surfaceView.applyRenderProfile(.liveCam)
        surfaceView.updateLiveCamOrbit(liveCamOrbit)
        attach(to: container, owner: .liveCam, quality: qualityForLiveCam)
        applyRenderState()
    }

    func attachToFullStage(_ container: NSView) {
        surfaceView.applyRenderProfile(.fullStage)
        attach(to: container, owner: .fullStage, quality: .full)
        surfaceView.prepareSelectedWorldForFullStage()
    }

    func rotateLiveCam(deltaYaw: Float, deltaPitch: Float) {
        liveCamOrbit.rotate(
            deltaYaw: deltaYaw,
            deltaPitch: deltaPitch
        )
        surfaceView.updateLiveCamOrbit(liveCamOrbit)
    }

    func resetLiveCamOrbit() {
        liveCamOrbit = LiveCamCharacterOrbit()
        surfaceView.updateLiveCamOrbit(liveCamOrbit)
    }

    func onNextLiveCamFrame(
        _ completion: @escaping @MainActor () -> Void
    ) {
        guard owner == .liveCam else { return }
        surfaceView.onNextRenderedFrame(completion)
    }

    func detach(from expectedOwner: StageRenderSurfaceOwner) {
        guard owner == expectedOwner else { return }
        stopRenderLoop()
        surfaceView.removeFromSuperview()
        owner = .detached
        isOwnerVisible = false
        isOwnerOccluded = false
        applyRenderState()
    }

    func setOwnerVisibility(
        _ visible: Bool,
        occluded: Bool = false,
        owner expectedOwner: StageRenderSurfaceOwner
    ) {
        guard owner == expectedOwner else { return }
        isOwnerVisible = visible
        isOwnerOccluded = occluded
        applyRenderState()
    }

    func setWorldPresentationVisible(_ visible: Bool) {
        isWorldPresentationVisible = visible
        applyRenderState()
    }

    func setLiveCamQuality(_ quality: StageRenderQuality) {
        guard quality != .full else {
            self.quality = .balanced
            if owner == .liveCam {
                applyRenderState()
            }
            return
        }
        self.quality = quality
        if owner == .liveCam {
            applyRenderState()
        }
    }

    private var qualityForLiveCam: StageRenderQuality {
        quality == .full ? .balanced : quality
    }

    private func attach(
        to container: NSView,
        owner newOwner: StageRenderSurfaceOwner,
        quality newQuality: StageRenderQuality
    ) {
        guard owner != newOwner || surfaceView.superview !== container else {
            setOwnerVisibility(
                container.window?.isVisible == true,
                occluded: false,
                owner: newOwner
            )
            return
        }

        surfaceView.removeFromSuperview()
        owner = newOwner
        isOwnerVisible = container.window?.isVisible == true
        isOwnerOccluded = false
        surfaceView.frame = container.bounds
        surfaceView.autoresizingMask = [.width, .height]
        container.addSubview(surfaceView)
        surfaceView.restoreAvatarObservationAfterReparent()
        surfaceView.applyRenderQuality(
            framesPerSecond: newQuality.framesPerSecond,
            renderScale: newQuality.renderScale
        )
        Self.log.notice(
            "Attached shared surface owner=\(String(describing: newOwner), privacy: .public) visible=\(self.isOwnerVisible, privacy: .public) requested=\(self.spatialStage.isWorldPresentationRequested, privacy: .public) worldVisible=\(self.isWorldPresentationVisible, privacy: .public)"
        )
        applyRenderState()
    }

    private func applyRenderState() {
        let activity = StageRenderActivityState.resolve(
            owner: owner,
            isOwnerVisible: isOwnerVisible,
            isOwnerOccluded: isOwnerOccluded,
            isWorldPresentationRequested: spatialStage
                .isWorldPresentationRequested,
            isWorldPresentationVisible: isWorldPresentationVisible
        )
        surfaceView.isHidden = activity.isHidden
        let activeQuality: StageRenderQuality = switch owner {
        case .fullStage:
            .full
        case .liveCam:
            qualityForLiveCam
        case .detached:
            qualityForLiveCam
        }
        surfaceView.applyRenderQuality(
            framesPerSecond: activeQuality.framesPerSecond,
            renderScale: activeQuality.renderScale
        )
        // MTKView's private display link can remain bound to the old window
        // after this view is reparented between Live Cam and the full stage.
        // Keep it paused and drive both owners through one explicit loop.
        surfaceView.isPaused = true
        let nextMode = StageRenderLoopMode.resolve(
            activity: activity,
            quality: activeQuality
        )
        renderLoopMode = nextMode
        switch nextMode {
        case .stopped:
            stopRenderLoop()
        case .manual:
            startRenderLoop()
        }
    }

    private func startRenderLoop() {
        guard renderLoopTask == nil else { return }
        renderLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard case let .manual(currentFramesPerSecond) =
                    self.renderLoopMode,
                    !self.surfaceView.isHidden
                else {
                    return
                }
                self.surfaceView.draw()
                let framesPerSecond = max(
                    currentFramesPerSecond,
                    1
                )
                try? await Task.sleep(
                    for: .seconds(1.0 / Double(framesPerSecond))
                )
            }
        }
    }

    private func stopRenderLoop() {
        renderLoopTask?.cancel()
        renderLoopTask = nil
    }
}
