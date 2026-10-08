import Foundation

enum CandidateBucket: String, Codable, Equatable, Sendable {
    case familiar
    case rediscovery
    case exploration
}

struct CandidatePoolRequest: Equatable, Sendable {
    var moodTags: [String]
    var targetEnergy: Double?
    var excludedTrackIDs: Set<String>
    var limit: Int
    var now: Date
    var recentSkipWindow: TimeInterval
    var rediscoveryAge: TimeInterval

    init(
        moodTags: [String] = [],
        targetEnergy: Double? = nil,
        excludedTrackIDs: Set<String> = [],
        limit: Int = 30,
        now: Date = Date(),
        recentSkipWindow: TimeInterval = 7 * 86_400,
        rediscoveryAge: TimeInterval = 30 * 86_400
    ) {
        self.moodTags = moodTags
        self.targetEnergy = targetEnergy
        self.excludedTrackIDs = excludedTrackIDs
        self.limit = limit
        self.now = now
        self.recentSkipWindow = recentSkipWindow
        self.rediscoveryAge = rediscoveryAge
    }
}

struct CandidatePoolItem: Codable, Equatable, Sendable {
    let candidate: MusicCandidate
    let bucket: CandidateBucket
    let score: Double
}

struct CandidatePool: Codable, Equatable, Sendable {
    let items: [CandidatePoolItem]

    var candidates: [MusicCandidate] {
        items.map(\.candidate)
    }
}

// Candidate selection and quota/scoring rules live in Rust music_program_rules.
