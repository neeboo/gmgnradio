import AppKit
import os

/// Frame-cadence bookkeeping for the explicit render loop.
///
/// Each frame is scheduled to *start* one `interval` after the previous frame
/// started, and the idle before it is that target minus the previous frame's
/// measured draw time — so the loop runs at the target cadence instead of
/// drawCPU + a full interval. When a frame overruns its interval
/// (`draw > interval`) the next frame starts immediately (machine-bound at the
/// real draw cost): missed beats are dropped rather than burst-rendered, so a
/// long main-actor hiccup can never turn into a busy catch-up burst.
struct StageRenderFramePacer: Equatable, Sendable {
    var interval: TimeInterval
    private(set) var nextStart: TimeInterval

    init(interval: TimeInterval, firstFrameAt start: TimeInterval = 0) {
        // Guard a zero/negative fps input (quality resolution edge) so the
        // loop can never sleep for zero or spin.
        self.interval = max(interval, 0.0001)
        self.nextStart = max(start, 0)
    }

    /// How long the loop should idle so the next frame starts at its paced
    /// time. Zero when the loop is already behind its cadence.
    func idleTime(now: TimeInterval) -> TimeInterval {
        max(0, nextStart - now)
    }

    /// Records one drawn frame that started at `start` and ended at `end`
    /// (seconds on the same time base as `firstFrameAt`). The next frame's
    /// start moves one interval forward, never behind this frame's real end,
    /// which is what drops missed beats instead of accumulating them.
    mutating func frameDrew(startedAt start: TimeInterval, endedAt end: TimeInterval) {
        nextStart = max(start + interval, end)
    }
}

enum StageRenderSurfaceOwner: Equatable, Sendable {
    case detached
    case liveCam
    case fullStage
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
    case gpuiLiveCam
    case gpuiFullStage
#endif
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
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
        case .gpuiLiveCam:
            true
        case .gpuiFullStage:
            isWorldPresentationRequested || isWorldPresentationVisible
#endif
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
    private var schedulingIntervalsMS: [Double] = []
    private var schedulingOvershootsMS: [Double] = []
    private var schedulingDrawDurationsMS: [Double] = []
    private var schedulingLongIntervals: [[String: Any]] = []

    private func currentSchedulingRunLoopMode() -> String {
        RunLoop.current.currentMode?.rawValue ?? "none"
    }

    /// Main-actor draw invocation timing only, not GPU completion or physical
    /// display cadence. Wait overshoot includes main-actor Task resumption delay.
    var renderSchedulingDiagnostics: [String: Any] {
        func summary(_ values: [Double]) -> [String: Any] {
            guard !values.isEmpty else { return ["samples": 0] }
            let sorted = values.sorted()
            return [
                "samples": sorted.count,
                "p50MS": sorted[(sorted.count - 1) / 2],
                "p95MS": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                "maxMS": sorted.last ?? 0,
            ]
        }
        return [
            "timingScope": "main-actor-draw-invocation-not-physical-display",
            "observedAtSystemUptime": ProcessInfo.processInfo.systemUptime,
            "sampleCapacity": 120,
            "longIntervalCapacity": 12,
            "schedulerKind": "task-sleep",
            "loopActive": renderLoopTask != nil,
            "drawStartInterval": summary(schedulingIntervalsMS),
            "waitResumeOvershoot": summary(schedulingOvershootsMS),
            "drawDuration": summary(schedulingDrawDurationsMS),
            "longDrawStartIntervals": schedulingLongIntervals,
        ]
    }

    private func recordRenderScheduling(
        intervalMS: Double?, overshootMS: Double, drawDurationMS: Double,
        startedAtUptime: Double, runLoopMode: String, waited: Bool
    ) {
        func appendBounded(_ value: Double, to values: inout [Double]) {
            values.append(value)
            if values.count > 120 { values.removeFirst(values.count - 120) }
        }
        if let intervalMS {
            appendBounded(intervalMS, to: &schedulingIntervalsMS)
            if intervalMS > 50 {
                schedulingLongIntervals.append([
                    "startedAtSystemUptime": startedAtUptime,
                    "drawStartIntervalMS": intervalMS,
                    "runLoopMode": runLoopMode,
                    "waitResumeOvershootMS": overshootMS,
                    "drawDurationMS": drawDurationMS,
                    "didWait": waited,
                ])
                if schedulingLongIntervals.count > 12 {
                    schedulingLongIntervals.removeFirst(
                        schedulingLongIntervals.count - 12
                    )
                }
            }
        }
        if waited { appendBounded(overshootMS, to: &schedulingOvershootsMS) }
        appendBounded(drawDurationMS, to: &schedulingDrawDurationsMS)
    }

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

#if GMGN_GPUI_PRODUCT_BOOTSTRAP
    func attachToGPUI(_ container: NSView, fullStage: Bool) {
        surfaceView.applyRenderProfile(fullStage ? .fullStage : .liveCam)
        if !fullStage { surfaceView.updateLiveCamOrbit(liveCamOrbit) }
        attach(to: container, owner: fullStage ? .gpuiFullStage : .gpuiLiveCam,
               quality: fullStage ? .full : qualityForLiveCam)
        if fullStage { surfaceView.prepareSelectedWorldForFullStage() }
    }
#endif

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
            if ownsLiveCamProfile {
                applyRenderState()
            }
            return
        }
        self.quality = quality
        if ownsLiveCamProfile {
            applyRenderState()
        }
    }

    private var qualityForLiveCam: StageRenderQuality {
        quality == .full ? .balanced : quality
    }

    private var ownsLiveCamProfile: Bool {
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
        owner == .liveCam || owner == .gpuiLiveCam
#else
        owner == .liveCam
#endif
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
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
        case .gpuiFullStage:
            .full
        case .gpuiLiveCam:
            qualityForLiveCam
#endif
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
        surfaceView.setResidentPropRenderingActive(nextMode != .stopped)
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
            let clock = ContinuousClock()
            let loopStart = clock.now
            var pacer = StageRenderFramePacer(interval: 0)
            // Local to this task: stopped time cannot become a draw interval.
            var previousFrameStart: TimeInterval?
            func elapsedSeconds(_ duration: Duration) -> TimeInterval {
                Double(duration.components.seconds)
                    + Double(duration.components.attoseconds)
                    / 1_000_000_000_000_000_000
            }
            while !Task.isCancelled {
                guard let self else { return }
                guard case let .manual(currentFramesPerSecond) = self.renderLoopMode,
                      !self.surfaceView.isHidden else { return }
                let interval = 1.0 / Double(max(currentFramesPerSecond, 1))
                let now = elapsedSeconds(clock.now - loopStart)
                if pacer.interval != interval {
                    pacer = StageRenderFramePacer(interval: interval, firstFrameAt: now)
                }
                let idle = pacer.idleTime(now: now)
                let sleepDeadline = clock.now + .seconds(idle)
                if idle > 0 {
                    try? await Task.sleep(for: .seconds(idle))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled,
                      case .manual = self.renderLoopMode,
                      !self.surfaceView.isHidden else { return }
                let frameStart = elapsedSeconds(clock.now - loopStart)
                let resumeOvershootMS = idle > 0
                    ? max(0, elapsedSeconds(clock.now - sleepDeadline) * 1000) : 0
                let startedAtUptime = ProcessInfo.processInfo.systemUptime
                let runLoopMode = self.currentSchedulingRunLoopMode()
                self.surfaceView.draw()
                let frameEnd = elapsedSeconds(clock.now - loopStart)
                self.recordRenderScheduling(
                    intervalMS: previousFrameStart.map { (frameStart - $0) * 1000 },
                    overshootMS: resumeOvershootMS,
                    drawDurationMS: (frameEnd - frameStart) * 1000,
                    startedAtUptime: startedAtUptime,
                    runLoopMode: runLoopMode, waited: idle > 0
                )
                previousFrameStart = frameStart
                pacer.frameDrew(startedAt: frameStart, endedAt: frameEnd)
            }
        }
    }

    private func stopRenderLoop() {
        renderLoopTask?.cancel()
        renderLoopTask = nil
    }
}
