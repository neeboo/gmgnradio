import Foundation

enum MusicLibraryOrigin: String, Codable, Hashable, Sendable {
    case saved
    case recent
    case discovery
}

struct TrackSourceReference: Codable, Equatable, Hashable, Sendable {
    let providerID: MusicProviderID
    let trackID: String
    let source: MusicSourceKind
    let isPlayable: Bool
    let matchScore: Double
    let userAffinity: Double
}

struct TrackKnowledge: Codable, Equatable, Sendable {
    private(set) var identity: String
    private(set) var canonicalID: String?
    private(set) var normalizedMetadataKey: String
    private(set) var title: String
    private(set) var artist: String
    private(set) var album: String?
    private(set) var duration: TimeInterval
    private(set) var energy: Double
    private(set) var moodTags: [String]
    private(set) var genres: [String]
    private(set) var releaseYear: Int?
    private(set) var artworkURL: URL?
    private(set) var sources: [TrackSourceReference]
    private(set) var origins: Set<MusicLibraryOrigin>
    private(set) var firstSeenAt: Date
    private(set) var lastSeenAt: Date
    private(set) var playCount: Int
    private(set) var completedPlayCount: Int
    private(set) var skipCount: Int
    private(set) var isLiked: Bool
    private(set) var lastPlayedAt: Date?
    private(set) var lastSkippedAt: Date?

    var isSaved: Bool {
        origins.contains(.saved)
    }

    /// Computed by the Rust knowledge authority; never recomputed by a native writer.
    private(set) var affinityScore: Double
}
