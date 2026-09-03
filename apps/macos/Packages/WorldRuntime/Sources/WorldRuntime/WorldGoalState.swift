import Foundation

public struct WorldGoalState: Codable, Equatable, Sendable {
    public let goalID: String
    public let completedAt: Date
    public let summary: String?

    public init(
        goalID: String,
        completedAt: Date,
        summary: String? = nil
    ) {
        self.goalID = goalID
        self.completedAt = completedAt
        self.summary = summary
    }
}
