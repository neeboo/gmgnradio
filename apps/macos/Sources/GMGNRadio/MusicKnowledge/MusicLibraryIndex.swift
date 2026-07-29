import Foundation

enum MusicListeningEvent: Equatable, Sendable {
    case played(trackID: String, completed: Bool, at: Date)
    case skipped(trackID: String, at: Date)
    case liked(trackID: String, isLiked: Bool, at: Date)

    var trackID: String {
        switch self {
        case let .played(trackID, _, _),
             let .skipped(trackID, _),
             let .liked(trackID, _, _):
            trackID
        }
    }
}

protocol MusicLibraryIndexPersistence: Sendable {
    func load() async throws -> [TrackKnowledge]
    func save(_ tracks: [TrackKnowledge]) async throws
}

protocol MusicLibraryIndexing: Sendable {
    func ingest(
        _ candidates: [MusicCandidate],
        origin: MusicLibraryOrigin,
        seenAt: Date
    ) async
    func record(_ event: MusicListeningEvent) async
    func snapshot() async -> [TrackKnowledge]
}

actor InMemoryMusicLibraryIndex: MusicLibraryIndexing {
    private var tracksByIdentity: [String: TrackKnowledge]

    init(seed: [TrackKnowledge] = []) {
        self.tracksByIdentity = Dictionary(
            uniqueKeysWithValues: seed.map { ($0.identity, $0) }
        )
    }

    func ingest(
        _ candidates: [MusicCandidate],
        origin: MusicLibraryOrigin,
        seenAt: Date = Date()
    ) {
        for candidate in candidates {
            ingest(candidate, origin: origin, seenAt: seenAt)
        }
    }

    func record(_ event: MusicListeningEvent) {
        guard let identity = identity(forTrackID: event.trackID),
              var track = tracksByIdentity[identity]
        else {
            return
        }

        switch event {
        case let .played(_, completed, at):
            track.recordPlayed(completed: completed, at: at)
        case let .skipped(_, at):
            track.recordSkipped(at: at)
        case let .liked(_, isLiked, _):
            track.setLiked(isLiked)
        }
        tracksByIdentity[identity] = track
    }

    func snapshot() -> [TrackKnowledge] {
        tracksByIdentity.values.sorted { $0.identity < $1.identity }
    }

    private func ingest(
        _ candidate: MusicCandidate,
        origin: MusicLibraryOrigin,
        seenAt: Date
    ) {
        var merged = TrackKnowledge(
            candidate: candidate,
            origin: origin,
            seenAt: seenAt
        )

        let matchingIdentities = tracksByIdentity.compactMap {
            identity,
            track -> String? in
            if identity == merged.identity
                || track.normalizedMetadataKey
                    == merged.normalizedMetadataKey
            {
                return identity
            }
            return nil
        }.sorted()
        for identity in matchingIdentities {
            if let existing = tracksByIdentity.removeValue(
                forKey: identity
            ) {
                merged.merge(knowledge: existing)
            }
        }
        tracksByIdentity[merged.identity] = merged
    }

    private func identity(forTrackID trackID: String) -> String? {
        if tracksByIdentity[trackID] != nil {
            return trackID
        }
        return tracksByIdentity.first(where: { _, track in
            track.sources.contains { $0.trackID == trackID }
        })?.key
    }
}
