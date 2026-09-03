import Foundation

/// A full-body activity in the persistent world. Voice and facial state are
/// intentionally modeled outside this type so conversation can overlay any
/// physical activity.
public enum LifeActivity: Equatable, Hashable, Sendable {
    case idle
    case walk(destinationID: String)
    case turn(targetYaw: Float)
    case sit(anchorID: String)
    case gaze(targetID: String)
    case listenMusic(anchorID: String)
    case interact(anchorID: String)

    public var typeID: String {
        switch self {
        case .idle: "idle"
        case .walk: "walk"
        case .turn: "turn"
        case .sit: "sit"
        case .gaze: "gaze"
        case .listenMusic: "listenMusic"
        case .interact: "interact"
        }
    }

    public var approachTargetID: String? {
        switch self {
        case let .walk(destinationID): destinationID
        case let .sit(anchorID),
             let .gaze(anchorID),
             let .listenMusic(anchorID),
             let .interact(anchorID): anchorID
        case .idle, .turn: nil
        }
    }

    /// Returns the stable action name used by world manifests. A small set of
    /// legacy spellings remains readable so schema-v1 packages keep loading.
    public static func canonicalTypeID(for manifestAction: String) -> String? {
        switch manifestAction {
        case "idle", "walk", "turn", "sit", "gaze", "listenMusic", "interact":
            manifestAction
        case "listen-to-music", "listen_music":
            "listenMusic"
        default:
            nil
        }
    }
}

extension LifeActivity: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case destinationID
        case targetYaw
        case anchorID
        case targetID
    }

    private enum ActivityType: String, Codable {
        case idle
        case walk
        case turn
        case sit
        case gaze
        case listenMusic
        case interact
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ActivityType.self, forKey: .type) {
        case .idle:
            self = .idle
        case .walk:
            self = .walk(
                destinationID: try container.decode(String.self, forKey: .destinationID)
            )
        case .turn:
            self = .turn(targetYaw: try container.decode(Float.self, forKey: .targetYaw))
        case .sit:
            self = .sit(anchorID: try container.decode(String.self, forKey: .anchorID))
        case .gaze:
            self = .gaze(targetID: try container.decode(String.self, forKey: .targetID))
        case .listenMusic:
            self = .listenMusic(
                anchorID: try container.decode(String.self, forKey: .anchorID)
            )
        case .interact:
            self = .interact(
                anchorID: try container.decode(String.self, forKey: .anchorID)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(ActivityType.idle, forKey: .type)
        case let .walk(destinationID):
            try container.encode(ActivityType.walk, forKey: .type)
            try container.encode(destinationID, forKey: .destinationID)
        case let .turn(targetYaw):
            try container.encode(ActivityType.turn, forKey: .type)
            try container.encode(targetYaw, forKey: .targetYaw)
        case let .sit(anchorID):
            try container.encode(ActivityType.sit, forKey: .type)
            try container.encode(anchorID, forKey: .anchorID)
        case let .gaze(targetID):
            try container.encode(ActivityType.gaze, forKey: .type)
            try container.encode(targetID, forKey: .targetID)
        case let .listenMusic(anchorID):
            try container.encode(ActivityType.listenMusic, forKey: .type)
            try container.encode(anchorID, forKey: .anchorID)
        case let .interact(anchorID):
            try container.encode(ActivityType.interact, forKey: .type)
            try container.encode(anchorID, forKey: .anchorID)
        }
    }
}

public enum LifeActivityPhase: String, CaseIterable, Codable, Hashable, Sendable {
    case approach
    case enter
    case loop
    case exit
    case interrupt
    case failed
}

public struct ActivityPhaseContract: Codable, Equatable, Hashable, Sendable {
    public let phase: LifeActivityPhase
    public let requiredAnchorIDs: [String]
    public let motionIDs: [String]
    public let propIDs: [String]
    public let durationSeconds: TimeInterval?

    public init(
        phase: LifeActivityPhase,
        requiredAnchorIDs: [String] = [],
        motionIDs: [String] = [],
        propIDs: [String] = [],
        durationSeconds: TimeInterval? = nil
    ) {
        self.phase = phase
        self.requiredAnchorIDs = requiredAnchorIDs
        self.motionIDs = motionIDs
        self.propIDs = propIDs
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case requiredAnchorIDs
        case motionIDs
        case propIDs
        case durationSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(LifeActivityPhase.self, forKey: .phase)
        requiredAnchorIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .requiredAnchorIDs
        ) ?? []
        motionIDs = try container.decodeIfPresent([String].self, forKey: .motionIDs) ?? []
        propIDs = try container.decodeIfPresent([String].self, forKey: .propIDs) ?? []
        durationSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .durationSeconds
        )
    }
}

public struct LifeActivityDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let activity: LifeActivity
    public let phases: [ActivityPhaseContract]
    public let interruptible: Bool
    public let cooldownSeconds: TimeInterval

    public init(
        id: String,
        displayName: String? = nil,
        activity: LifeActivity,
        phases: [ActivityPhaseContract],
        interruptible: Bool,
        cooldownSeconds: TimeInterval
    ) {
        self.id = id
        self.displayName = displayName
        self.activity = activity
        self.phases = phases
        self.interruptible = interruptible
        self.cooldownSeconds = cooldownSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case activity
        case phases
        case interruptible
        case cooldownSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        activity = try container.decode(LifeActivity.self, forKey: .activity)
        phases = try container.decode([ActivityPhaseContract].self, forKey: .phases)
        interruptible = try container.decodeIfPresent(
            Bool.self,
            forKey: .interruptible
        ) ?? true
        cooldownSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .cooldownSeconds
        ) ?? 0
    }

    public func contract(for phase: LifeActivityPhase) -> ActivityPhaseContract? {
        phases.first { $0.phase == phase }
    }
}
