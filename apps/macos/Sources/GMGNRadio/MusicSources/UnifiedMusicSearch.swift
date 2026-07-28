import Foundation

struct UnifiedMusicSearch: Sendable {
    private let sources: [any MusicSource]

    init(sources: [any MusicSource]) {
        self.sources = sources
    }

    func search(_ request: MusicSearchRequest) async throws -> [MusicCandidate] {
        let sourceResults = await withTaskGroup(
            of: [MusicCandidate].self,
            returning: [[MusicCandidate]].self
        ) { group in
            for source in sources where source.access.isReady {
                group.addTask {
                    (try? await source.search(request)) ?? []
                }
            }

            var results: [[MusicCandidate]] = []
            for await candidates in group {
                results.append(candidates)
            }
            return results
        }

        var bestByRecording: [String: MusicCandidate] = [:]
        for candidate in sourceResults.joined() where candidate.isPlayable {
            let key = candidate.deduplicationKey
            guard let existing = bestByRecording[key] else {
                bestByRecording[key] = candidate
                continue
            }
            if candidateRank(candidate) > candidateRank(existing) {
                bestByRecording[key] = candidate
            }
        }

        return bestByRecording.values
            .sorted {
                let lhsRank = candidateRank($0)
                let rhsRank = candidateRank($1)
                if lhsRank == rhsRank {
                    return $0.id < $1.id
                }
                return lhsRank > rhsRank
            }
            .prefix(max(0, request.limit))
            .map { $0 }
    }

    private func candidateRank(_ candidate: MusicCandidate) -> Double {
        candidate.matchScore * 0.7 + candidate.userAffinity * 0.3
    }
}
