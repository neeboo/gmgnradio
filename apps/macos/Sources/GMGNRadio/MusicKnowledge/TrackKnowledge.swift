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

    var affinityScore: Double {
        let sourceAffinity = sources.map(\.userAffinity).max() ?? 0
        let playBoost = min(0.2, Double(playCount) * 0.035)
        let completionBoost = min(
            0.15,
            Double(completedPlayCount) * 0.025
        )
        let likeBoost = isLiked ? 0.25 : 0
        let skipPenalty = min(0.45, Double(skipCount) * 0.12)
        return Self.clamp(
            sourceAffinity
                + playBoost
                + completionBoost
                + likeBoost
                - skipPenalty
        )
    }

    var preferredCandidate: MusicCandidate? {
        guard let source = preferredSource else { return nil }
        return MusicCandidate(
            id: source.trackID,
            canonicalID: canonicalID,
            providerID: source.providerID,
            source: source.source,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            isPlayable: source.isPlayable,
            matchScore: source.matchScore,
            userAffinity: affinityScore,
            energy: energy,
            moodTags: moodTags,
            genres: genres,
            releaseYear: releaseYear,
            artworkURL: artworkURL
        )
    }

    init(
        candidate: MusicCandidate,
        origin: MusicLibraryOrigin,
        seenAt: Date
    ) {
        let title = Self.cleanDisplayText(candidate.title)
        let artist = Self.cleanDisplayText(candidate.artist)
        let canonicalID = Self.cleanCanonicalID(candidate.canonicalID)
        self.identity = canonicalID.map { "canonical:\($0)" }
            ?? "metadata:\(Self.metadataKey(title: title, artist: artist))"
        self.canonicalID = canonicalID
        self.normalizedMetadataKey = Self.metadataKey(
            title: title,
            artist: artist
        )
        self.title = title
        self.artist = artist
        self.album = candidate.album.map(Self.cleanDisplayText)
        self.duration = candidate.duration
        self.energy = Self.clamp(candidate.energy)
        self.moodTags = Self.normalizedLabels(candidate.moodTags)
        self.genres = Self.normalizedLabels(candidate.genres)
        self.releaseYear = candidate.releaseYear
        self.artworkURL = candidate.artworkURL
        self.sources = [Self.sourceReference(for: candidate)]
        self.origins = [origin]
        self.firstSeenAt = seenAt
        self.lastSeenAt = seenAt
        self.playCount = 0
        self.completedPlayCount = 0
        self.skipCount = 0
        self.isLiked = false
        self.lastPlayedAt = nil
        self.lastSkippedAt = nil
    }

    mutating func merge(
        candidate: MusicCandidate,
        origin: MusicLibraryOrigin,
        seenAt: Date
    ) {
        if let incomingCanonicalID = Self.cleanCanonicalID(
            candidate.canonicalID
        ) {
            canonicalID = incomingCanonicalID
            identity = "canonical:\(incomingCanonicalID)"
        }

        let incomingSource = Self.sourceReference(for: candidate)
        sources.removeAll {
            $0.providerID == incomingSource.providerID
                && $0.trackID == incomingSource.trackID
        }
        sources.append(incomingSource)
        sources.sort(by: Self.sourceOrder)
        origins.insert(origin)
        firstSeenAt = min(firstSeenAt, seenAt)
        lastSeenAt = max(lastSeenAt, seenAt)

        if album?.isEmpty != false,
           let incomingAlbum = candidate.album,
           !incomingAlbum.isEmpty
        {
            album = Self.cleanDisplayText(incomingAlbum)
        }
        if duration <= 0, candidate.duration > 0 {
            duration = candidate.duration
        }
        energy = Self.clamp(
            (energy + Self.clamp(candidate.energy)) / 2
        )
        moodTags = Self.mergeLabels(moodTags, candidate.moodTags)
        genres = Self.mergeLabels(genres, candidate.genres)
        releaseYear = releaseYear ?? candidate.releaseYear
        artworkURL = artworkURL ?? candidate.artworkURL
    }

    mutating func merge(knowledge other: TrackKnowledge) {
        if canonicalID == nil, let otherCanonicalID = other.canonicalID {
            canonicalID = otherCanonicalID
            identity = "canonical:\(otherCanonicalID)"
        }
        for source in other.sources where !sources.contains(where: {
            $0.providerID == source.providerID && $0.trackID == source.trackID
        }) {
            sources.append(source)
        }
        sources.sort(by: Self.sourceOrder)
        origins.formUnion(other.origins)
        firstSeenAt = min(firstSeenAt, other.firstSeenAt)
        lastSeenAt = max(lastSeenAt, other.lastSeenAt)
        playCount += other.playCount
        completedPlayCount += other.completedPlayCount
        skipCount += other.skipCount
        isLiked = isLiked || other.isLiked
        lastPlayedAt = Self.latest(lastPlayedAt, other.lastPlayedAt)
        lastSkippedAt = Self.latest(lastSkippedAt, other.lastSkippedAt)
        if album?.isEmpty != false {
            album = other.album
        }
        if duration <= 0 {
            duration = other.duration
        }
        energy = Self.clamp((energy + other.energy) / 2)
        moodTags = Self.mergeLabels(moodTags, other.moodTags)
        genres = Self.mergeLabels(genres, other.genres)
        releaseYear = releaseYear ?? other.releaseYear
        artworkURL = artworkURL ?? other.artworkURL
    }

    mutating func recordPlayed(completed: Bool, at date: Date) {
        playCount += 1
        if completed {
            completedPlayCount += 1
        }
        lastPlayedAt = max(lastPlayedAt ?? date, date)
    }

    mutating func recordSkipped(at date: Date) {
        skipCount += 1
        lastSkippedAt = max(lastSkippedAt ?? date, date)
    }

    mutating func setLiked(_ liked: Bool) {
        isLiked = liked
    }

    private var preferredSource: TrackSourceReference? {
        sources.sorted(by: Self.sourceOrder).first
    }

    private static func sourceReference(
        for candidate: MusicCandidate
    ) -> TrackSourceReference {
        TrackSourceReference(
            providerID: candidate.providerID,
            trackID: candidate.id,
            source: candidate.source,
            isPlayable: candidate.isPlayable,
            matchScore: clamp(candidate.matchScore),
            userAffinity: clamp(candidate.userAffinity)
        )
    }

    private static func sourceOrder(
        _ lhs: TrackSourceReference,
        _ rhs: TrackSourceReference
    ) -> Bool {
        if lhs.isPlayable != rhs.isPlayable {
            return lhs.isPlayable
        }
        if lhs.matchScore != rhs.matchScore {
            return lhs.matchScore > rhs.matchScore
        }
        if lhs.providerID.rawValue != rhs.providerID.rawValue {
            return lhs.providerID.rawValue < rhs.providerID.rawValue
        }
        return lhs.trackID < rhs.trackID
    }

    static func cleanDisplayText(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func metadataKey(title: String, artist: String) -> String {
        "\(normalizedText(title))|\(normalizedText(artist))"
    }

    static func cleanCanonicalID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedText(_ value: String) -> String {
        cleanDisplayText(value)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func normalizedLabels(_ values: [String]) -> [String] {
        Array(Set(values.compactMap {
            let value = cleanDisplayText($0).lowercased()
            return value.isEmpty ? nil : value
        })).sorted()
    }

    private static func mergeLabels(
        _ existing: [String],
        _ incoming: [String]
    ) -> [String] {
        normalizedLabels(existing + incoming)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): max(lhs, rhs)
        case (let lhs?, nil): lhs
        case (nil, let rhs?): rhs
        case (nil, nil): nil
        }
    }
}
