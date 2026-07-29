import Foundation

enum PreparedMusicPlayback: Equatable, Sendable {
    case pcmFile(URL)
    case appleMusic(trackID: String)
}

@MainActor
final class MusicRuntime {
    private let netease: NeteaseMusicSource
    private let qqMusic: QQMusicSource
    private let appleMusic: AppleMusicSource
    private let cache: any MusicAssetCaching

    init(
        netease: NeteaseMusicSource,
        qqMusic: QQMusicSource,
        appleMusic: AppleMusicSource,
        cache: any MusicAssetCaching
    ) {
        self.netease = netease
        self.qqMusic = qqMusic
        self.appleMusic = appleMusic
        self.cache = cache
    }

    static func live() -> MusicRuntime {
        let sessions = KeychainMusicProviderSessionStore()
        return MusicRuntime(
            netease: NeteaseMusicSource(
                sessions: sessions,
                client: NeteaseMusicProviderClient()
            ),
            qqMusic: QQMusicSource(
                sessions: sessions,
                client: QQMusicProviderClient()
            ),
            appleMusic: AppleMusicSource(),
            cache: StreamingMusicCache()
        )
    }

    func search(
        _ request: MusicSearchRequest
    ) async throws -> [MusicCandidate] {
        try await UnifiedMusicSearch(
            sources: [netease, qqMusic, appleMusic]
        ).search(request)
    }

    func makeProgramPlan(
        brief: ProgramBrief,
        agent: any DJTrackRankingAgent
    ) async throws -> ProgramPlan {
        let sources: [any MusicSource] = [
            netease,
            qqMusic,
            appleMusic,
        ]
        var candidates: [MusicCandidate] = []
        for source in sources where await source.access().isReady {
            if let library = try? await source.fetchUserLibrary() {
                candidates.append(contentsOf: library.savedTracks)
            }
        }

        candidates = deduplicated(candidates)
        if candidates.count < 5 {
            let searchResults = try await search(
                MusicSearchRequest(
                    moodTags: brief.moodTags,
                    targetEnergy: brief.energyArc.isEmpty
                        ? nil
                        : brief.energyArc.reduce(0, +)
                            / Double(brief.energyArc.count),
                    limit: 30
                )
            )
            candidates = deduplicated(candidates + searchResults)
        }

        return try await AgentProgramPlanner(agent: agent).makePlan(
            brief: brief,
            candidates: candidates
        )
    }

    func preparePlayback(
        for candidate: MusicCandidate
    ) async throws -> PreparedMusicPlayback {
        switch candidate.providerID {
        case .netease:
            let asset = try await netease.playbackAsset(
                for: candidate.id
            )
            return .pcmFile(
                try await cache.store(asset, trackID: candidate.id)
            )
        case .qqMusic:
            let asset = try await qqMusic.playbackAsset(
                for: candidate.id
            )
            return .pcmFile(
                try await cache.store(asset, trackID: candidate.id)
            )
        case .appleMusic:
            return .appleMusic(trackID: candidate.id)
        default:
            throw MusicProviderClientError.playbackUnavailable
        }
    }

    func startAppleMusic(trackID: String) async throws {
        try await appleMusic.play(trackID: trackID)
    }

    private func deduplicated(
        _ candidates: [MusicCandidate]
    ) -> [MusicCandidate] {
        var seen = Set<String>()
        return candidates.filter {
            $0.isPlayable && seen.insert($0.deduplicationKey).inserted
        }
    }
}
