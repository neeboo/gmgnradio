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

struct CandidatePoolBuilder: Sendable {
    func build(
        from tracks: some Sequence<TrackKnowledge>,
        request: CandidatePoolRequest
    ) -> CandidatePool {
        let limit = min(100, max(0, request.limit))
        guard limit > 0 else {
            return CandidatePool(items: [])
        }

        let eligible = tracks.compactMap { track -> RankedTrack? in
            guard let candidate = track.preferredCandidate,
                  candidate.isPlayable,
                  !request.excludedTrackIDs.contains(candidate.id),
                  !request.excludedTrackIDs.contains(track.identity),
                  !wasRecentlySkipped(track, request: request)
            else {
                return nil
            }
            let bucket = bucket(for: track, request: request)
            return RankedTrack(
                track: track,
                candidate: candidate,
                bucket: bucket,
                score: score(track, candidate: candidate, request: request)
            )
        }

        let familiarLimit = Int(Double(limit) * 0.60)
        let rediscoveryLimit = Int(Double(limit) * 0.25)
        let explorationLimit = limit - familiarLimit - rediscoveryLimit
        let quotas: [(CandidateBucket, Int)] = [
            (.familiar, familiarLimit),
            (.rediscovery, rediscoveryLimit),
            (.exploration, explorationLimit)
        ]

        var selected: [RankedTrack] = []
        var selectedIdentities = Set<String>()
        for (bucket, quota) in quotas {
            let values = eligible
                .filter { $0.bucket == bucket }
                .sorted(by: rankedOrder)
                .prefix(quota)
            selected.append(contentsOf: values)
            selectedIdentities.formUnion(values.map(\.track.identity))
        }

        if selected.count < limit {
            let remaining = eligible
                .filter { !selectedIdentities.contains($0.track.identity) }
                .sorted(by: rankedOrder)
                .prefix(limit - selected.count)
            selected.append(contentsOf: remaining)
        }

        let items = selected
            .sorted(by: outputOrder)
            .map {
                CandidatePoolItem(
                    candidate: $0.candidate,
                    bucket: $0.bucket,
                    score: $0.score
                )
            }
        return CandidatePool(items: items)
    }

    private func bucket(
        for track: TrackKnowledge,
        request: CandidatePoolRequest
    ) -> CandidateBucket {
        guard track.isSaved || track.playCount > 0 || track.isLiked else {
            return .exploration
        }
        guard let lastPlayedAt = track.lastPlayedAt else {
            return .rediscovery
        }
        if request.now.timeIntervalSince(lastPlayedAt)
            >= request.rediscoveryAge
        {
            return .rediscovery
        }
        return .familiar
    }

    private func wasRecentlySkipped(
        _ track: TrackKnowledge,
        request: CandidatePoolRequest
    ) -> Bool {
        guard let lastSkippedAt = track.lastSkippedAt else {
            return false
        }
        let age = request.now.timeIntervalSince(lastSkippedAt)
        return age >= 0 && age < request.recentSkipWindow
    }

    private func score(
        _ track: TrackKnowledge,
        candidate: MusicCandidate,
        request: CandidatePoolRequest
    ) -> Double {
        let moodScore = moodScore(
            candidate.moodTags,
            requested: request.moodTags
        )
        let energyScore = request.targetEnergy.map {
            1 - min(1, abs(candidate.energy - $0))
        } ?? 0.5
        return track.affinityScore * 0.4
            + candidate.matchScore * 0.2
            + moodScore * 0.2
            + energyScore * 0.2
    }

    private func moodScore(
        _ values: [String],
        requested: [String]
    ) -> Double {
        let requested = Set(requested.map { $0.lowercased() })
        guard !requested.isEmpty else { return 0.5 }
        let available = Set(values.map { $0.lowercased() })
        return Double(requested.intersection(available).count)
            / Double(requested.count)
    }

    private func rankedOrder(
        _ lhs: RankedTrack,
        _ rhs: RankedTrack
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.track.identity < rhs.track.identity
    }

    private func outputOrder(
        _ lhs: RankedTrack,
        _ rhs: RankedTrack
    ) -> Bool {
        let lhsBucket = Self.bucketOrder(lhs.bucket)
        let rhsBucket = Self.bucketOrder(rhs.bucket)
        if lhsBucket != rhsBucket {
            return lhsBucket < rhsBucket
        }
        return rankedOrder(lhs, rhs)
    }

    private static func bucketOrder(_ bucket: CandidateBucket) -> Int {
        switch bucket {
        case .familiar: 0
        case .rediscovery: 1
        case .exploration: 2
        }
    }
}

private struct RankedTrack {
    let track: TrackKnowledge
    let candidate: MusicCandidate
    let bucket: CandidateBucket
    let score: Double
}
