public struct LiveCamDirector: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var shotDwellDurationRange: ClosedRange<Double>
        public var transitionDurationRange: ClosedRange<Double>

        public init(
            shotDwellDurationRange: ClosedRange<Double> = 8 ... 15,
            transitionDurationRange: ClosedRange<Double> = 1.2 ... 2
        ) {
            precondition(
                shotDwellDurationRange.lowerBound > 0,
                "Shot dwell duration must be positive"
            )
            precondition(
                transitionDurationRange.lowerBound > 0,
                "Transition duration must be positive"
            )
            self.shotDwellDurationRange = shotDwellDurationRange
            self.transitionDurationRange = transitionDurationRange
        }
    }

    public struct Input: Equatable, Sendable {
        public var activityPhase: String
        public var agentTransform: WorldTransform
        public var isVoiceOverlayActive: Bool
        public var audioEnergy: Float
        public var availableCameraAnchors: [WorldCameraAnchor]
        public var isFullSpacePresented: Bool

        public init(
            activityPhase: String,
            agentTransform: WorldTransform,
            isVoiceOverlayActive: Bool,
            audioEnergy: Float,
            availableCameraAnchors: [WorldCameraAnchor],
            isFullSpacePresented: Bool
        ) {
            self.activityPhase = activityPhase
            self.agentTransform = agentTransform
            self.isVoiceOverlayActive = isVoiceOverlayActive
            self.audioEnergy = audioEnergy
            self.availableCameraAnchors = availableCameraAnchors
            self.isFullSpacePresented = isFullSpacePresented
        }
    }

    public enum Phase: String, Codable, Equatable, Sendable {
        case holding
        case transitioning
    }

    public struct Frame: Equatable, Sendable {
        public let camera: WorldCameraState
        public let outgoingCamera: WorldCameraState?
        public let phase: Phase
        public let transitionProgress: Double

        public init(
            camera: WorldCameraState,
            outgoingCamera: WorldCameraState?,
            phase: Phase,
            transitionProgress: Double
        ) {
            self.camera = camera
            self.outgoingCamera = outgoingCamera
            self.phase = phase
            self.transitionProgress = transitionProgress
        }
    }

    public let configuration: Configuration

    private var currentCamera: WorldCameraState?
    private var outgoingCamera: WorldCameraState?
    private var phase: Phase = .holding
    private var elapsedInPhase: Double = 0
    private var phaseDuration: Double = 0
    private var shotOrdinal: UInt64 = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Advances a deterministic state machine. Rendering code can blend from
    /// `outgoingCamera` to `camera` using `transitionProgress`.
    public mutating func update(deltaTime: Double, input: Input) -> Frame? {
        let anchors = input.availableCameraAnchors.sorted { $0.id < $1.id }
        guard !anchors.isEmpty else {
            reset()
            return nil
        }

        ensureCurrentCamera(in: anchors, input: input)

        guard !input.isFullSpacePresented else {
            return frame()
        }

        var remainingTime = sanitized(deltaTime)
        while remainingTime > 0 || elapsedInPhase >= phaseDuration {
            let timeToBoundary = max(0, phaseDuration - elapsedInPhase)
            if remainingTime < timeToBoundary {
                elapsedInPhase += remainingTime
                remainingTime = 0
                break
            }

            elapsedInPhase += timeToBoundary
            remainingTime -= timeToBoundary
            advancePhase(anchors: anchors, input: input)

            if remainingTime == 0 {
                break
            }
        }

        return frame()
    }

    private mutating func ensureCurrentCamera(
        in anchors: [WorldCameraAnchor],
        input: Input
    ) {
        if let currentCamera,
           anchors.contains(where: { $0.id == currentCamera.anchorID }) {
            return
        }

        let index = Int(contextSeed(input: input, ordinal: shotOrdinal) % UInt64(anchors.count))
        currentCamera = WorldCameraState(anchor: anchors[index])
        outgoingCamera = nil
        phase = .holding
        elapsedInPhase = 0
        phaseDuration = duration(
            in: configuration.shotDwellDurationRange,
            seed: contextSeed(input: input, ordinal: shotOrdinal &+ 11)
        )
    }

    private mutating func advancePhase(
        anchors: [WorldCameraAnchor],
        input: Input
    ) {
        switch phase {
        case .holding:
            guard anchors.count > 1, let currentCamera else {
                shotOrdinal &+= 1
                elapsedInPhase = 0
                phaseDuration = duration(
                    in: configuration.shotDwellDurationRange,
                    seed: contextSeed(input: input, ordinal: shotOrdinal &+ 11)
                )
                return
            }

            let currentIndex = anchors.firstIndex {
                $0.id == currentCamera.anchorID
            } ?? 0
            let offsetSeed = contextSeed(input: input, ordinal: shotOrdinal &+ 29)
            let offset = 1 + Int(offsetSeed % UInt64(anchors.count - 1))
            let nextIndex = (currentIndex + offset) % anchors.count

            outgoingCamera = currentCamera
            self.currentCamera = WorldCameraState(anchor: anchors[nextIndex])
            phase = .transitioning
            elapsedInPhase = 0
            phaseDuration = duration(
                in: configuration.transitionDurationRange,
                seed: contextSeed(input: input, ordinal: shotOrdinal &+ 47)
            )

        case .transitioning:
            shotOrdinal &+= 1
            outgoingCamera = nil
            phase = .holding
            elapsedInPhase = 0
            phaseDuration = duration(
                in: configuration.shotDwellDurationRange,
                seed: contextSeed(input: input, ordinal: shotOrdinal &+ 11)
            )
        }
    }

    private func frame() -> Frame? {
        guard let currentCamera else { return nil }
        let progress: Double
        if phase == .transitioning {
            progress = min(1, max(0, elapsedInPhase / phaseDuration))
        } else {
            progress = 1
        }
        return Frame(
            camera: currentCamera,
            outgoingCamera: outgoingCamera,
            phase: phase,
            transitionProgress: progress
        )
    }

    private mutating func reset() {
        currentCamera = nil
        outgoingCamera = nil
        phase = .holding
        elapsedInPhase = 0
        phaseDuration = 0
        shotOrdinal = 0
    }

    private func duration(
        in range: ClosedRange<Double>,
        seed: UInt64
    ) -> Double {
        guard range.lowerBound != range.upperBound else {
            return range.lowerBound
        }
        let fraction = Double(seed % 10_001) / 10_000
        return range.lowerBound + ((range.upperBound - range.lowerBound) * fraction)
    }

    private func sanitized(_ deltaTime: Double) -> Double {
        deltaTime.isFinite ? max(0, deltaTime) : 0
    }

    private func contextSeed(input: Input, ordinal: UInt64) -> UInt64 {
        var seed: UInt64 = 14_695_981_039_346_656_037

        func mix(_ byte: UInt8, into value: inout UInt64) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }

        for byte in input.activityPhase.utf8 {
            mix(byte, into: &seed)
        }
        for component in [
            input.agentTransform.position.x,
            input.agentTransform.position.y,
            input.agentTransform.position.z,
            input.audioEnergy,
        ] {
            var bits = component.bitPattern
            for _ in 0 ..< 4 {
                mix(UInt8(truncatingIfNeeded: bits), into: &seed)
                bits >>= 8
            }
        }
        mix(input.isVoiceOverlayActive ? 1 : 0, into: &seed)
        var ordinalBits = ordinal
        for _ in 0 ..< 8 {
            mix(UInt8(truncatingIfNeeded: ordinalBits), into: &seed)
            ordinalBits >>= 8
        }
        return seed
    }
}
