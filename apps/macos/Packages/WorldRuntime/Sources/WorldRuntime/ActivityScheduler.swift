import Foundation

public enum ActivityPriority: Int, CaseIterable, Codable, Comparable, Sendable {
    case explicitUserRequest = 0
    case activeConversation = 1
    case scheduledSharedActivity = 2
    case musicContext = 3
    case autonomousIdle = 4
    case safeIdleFallback = 5

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ScheduledActivity: Codable, Equatable, Sendable {
    public let id: String
    public let definitionID: String
    public let activity: LifeActivity
    public let priority: ActivityPriority
    public let requestedAt: Date

    public init(
        id: String,
        definitionID: String,
        activity: LifeActivity,
        priority: ActivityPriority,
        requestedAt: Date
    ) {
        self.id = id
        self.definitionID = definitionID
        self.activity = activity
        self.priority = priority
        self.requestedAt = requestedAt
    }
}

/// Selects from already-authored choices. It has no model or network dependency,
/// so equal inputs always produce the same result.
public struct ActivityScheduler: Sendable {
    public init() {}

    public func select(
        from candidates: [ScheduledActivity],
        at date: Date,
        cooldowns: [String: Date]
    ) -> ScheduledActivity? {
        candidates
            .filter { candidate in
                guard let cooldownUntil = cooldowns[candidate.definitionID] else {
                    return true
                }
                return cooldownUntil <= date
            }
            .min { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                if lhs.requestedAt != rhs.requestedAt {
                    return lhs.requestedAt < rhs.requestedAt
                }
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                return lhs.definitionID < rhs.definitionID
            }
    }
}
