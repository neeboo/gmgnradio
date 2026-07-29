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
    private let libraryIndex: any MusicLibraryIndexing
    private let candidatePoolBuilder: CandidatePoolBuilder

    init(
        netease: NeteaseMusicSource,
        qqMusic: QQMusicSource,
        appleMusic: AppleMusicSource,
        cache: any MusicAssetCaching,
        libraryIndex: any MusicLibraryIndexing = InMemoryMusicLibraryIndex(),
        candidatePoolBuilder: CandidatePoolBuilder = CandidatePoolBuilder()
    ) {
        self.netease = netease
        self.qqMusic = qqMusic
        self.appleMusic = appleMusic
        self.cache = cache
        self.libraryIndex = libraryIndex
        self.candidatePoolBuilder = candidatePoolBuilder
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
        for source in sources where await source.access().isReady {
            if let library = try? await source.fetchUserLibrary() {
                await libraryIndex.ingest(
                    library.savedTracks,
                    origin: .saved,
                    seenAt: Date()
                )
            }
        }

        if let searchResults = try? await search(
                MusicSearchRequest(
                    moodTags: brief.moodTags,
                    targetEnergy: brief.energyArc.isEmpty
                        ? nil
                        : brief.energyArc.reduce(0, +)
                            / Double(brief.energyArc.count),
                    limit: 30
                )
        ) {
            await libraryIndex.ingest(
                searchResults,
                origin: .discovery,
                seenAt: Date()
            )
        }
        let candidates = await programCandidates(for: brief)

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

    func recordPlaybackCompleted(_ candidate: MusicCandidate) async {
        await libraryIndex.record(
            .played(
                trackID: candidate.id,
                completed: true,
                at: Date()
            )
        )
    }

    private func programCandidates(
        for brief: ProgramBrief
    ) async -> [MusicCandidate] {
        let knowledge = await libraryIndex.snapshot()
        return candidatePoolBuilder.build(
            from: knowledge,
            request: CandidatePoolRequest(
                moodTags: brief.moodTags,
                targetEnergy: brief.energyArc.isEmpty
                    ? nil
                    : brief.energyArc.reduce(0, +)
                        / Double(brief.energyArc.count),
                excludedTrackIDs:
                    brief.blockedTrackIDs
                        .union(brief.recentlySkippedTrackIDs),
                limit: 30
            )
        ).candidates
    }
}

@MainActor
struct MusicRuntimePlaybackPreparer: ProgramPlaybackPreparing {
    let runtime: MusicRuntime

    func preparePlayback(
        for track: MusicCandidate
    ) async throws -> PreparedPlaybackTarget {
        switch try await runtime.preparePlayback(for: track) {
        case let .pcmFile(url):
            return .localFile(url)
        case let .appleMusic(trackID):
            return .providerReference(
                providerID: .appleMusic,
                trackID: trackID
            )
        }
    }
}
