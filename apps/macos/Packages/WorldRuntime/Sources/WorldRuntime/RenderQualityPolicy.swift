public enum RenderPressure: Int, Codable, CaseIterable, Comparable, Sendable {
    case normal
    case elevated
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum RenderQualityTier: Int, Codable, CaseIterable, Comparable, Sendable {
    case constrained
    case balanced
    case full

    public var targetFramesPerSecond: Int {
        switch self {
        case .constrained: 15
        case .balanced: 30
        case .full: 60
        }
    }

    public var renderScale: Double {
        switch self {
        case .constrained: 0.5
        case .balanced: 0.75
        case .full: 1
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RenderQualityPolicy: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var recoveryDelay: Double

        public init(recoveryDelay: Double = 10) {
            precondition(recoveryDelay >= 0, "Recovery delay cannot be negative")
            self.recoveryDelay = recoveryDelay
        }
    }

    public struct Input: Equatable, Sendable {
        public var isOccluded: Bool
        public var thermalPressure: RenderPressure
        public var powerPressure: RenderPressure

        public init(
            isOccluded: Bool = false,
            thermalPressure: RenderPressure = .normal,
            powerPressure: RenderPressure = .normal
        ) {
            self.isOccluded = isOccluded
            self.thermalPressure = thermalPressure
            self.powerPressure = powerPressure
        }
    }

    public struct Decision: Equatable, Sendable {
        public let shouldRender: Bool
        public let qualityTier: RenderQualityTier
        public let targetFramesPerSecond: Int
        public let renderScale: Double

        public init(shouldRender: Bool, qualityTier: RenderQualityTier) {
            self.shouldRender = shouldRender
            self.qualityTier = qualityTier
            targetFramesPerSecond = shouldRender
                ? qualityTier.targetFramesPerSecond
                : 0
            renderScale = qualityTier.renderScale
        }
    }

    public let configuration: Configuration
    public private(set) var qualityTier: RenderQualityTier

    private var recoveryElapsed: Double = 0

    public init(
        configuration: Configuration = Configuration(),
        initialQualityTier: RenderQualityTier = .full
    ) {
        self.configuration = configuration
        qualityTier = initialQualityTier
    }

    public mutating func update(deltaTime: Double, input: Input) -> Decision {
        guard !input.isOccluded else {
            return Decision(shouldRender: false, qualityTier: qualityTier)
        }

        let desiredTier = Self.desiredTier(
            for: max(input.thermalPressure, input.powerPressure)
        )

        if desiredTier < qualityTier {
            qualityTier = desiredTier
            recoveryElapsed = 0
        } else if desiredTier > qualityTier {
            recoveryElapsed += sanitized(deltaTime)
            if recoveryElapsed >= configuration.recoveryDelay {
                qualityTier = nextHigherTier(from: qualityTier)
                recoveryElapsed = 0
            }
        } else {
            recoveryElapsed = 0
        }

        return Decision(shouldRender: true, qualityTier: qualityTier)
    }

    private static func desiredTier(
        for pressure: RenderPressure
    ) -> RenderQualityTier {
        switch pressure {
        case .normal: .full
        case .elevated: .balanced
        case .critical: .constrained
        }
    }

    private func nextHigherTier(
        from tier: RenderQualityTier
    ) -> RenderQualityTier {
        switch tier {
        case .constrained: .balanced
        case .balanced, .full: .full
        }
    }

    private func sanitized(_ deltaTime: Double) -> Double {
        deltaTime.isFinite ? max(0, deltaTime) : 0
    }
}
