import Foundation
import os

enum PreparedMusicPlayback: Equatable, Sendable {
    case pcmFile(URL)
    case appleMusic(trackID: String)
}

enum ProgramDiscoveryQuery {
    static func make(from instruction: String?) -> String? {
        guard let instruction else {
            return nil
        }
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        let lowercased = normalized.lowercased()
        if lowercased.contains("city pop")
            || lowercased.contains("citypop")
            || normalized.contains("城市流行")
            || normalized.contains("シティ・ポップ")
        {
            return "City Pop"
        }

        var query = normalized
        let commandWords = [
            "请给我",
            "给我",
            "帮我",
            "重新",
            "生成一个",
            "生成一份",
            "生成",
            "做一个",
            "做一份",
            "做",
            "编排",
            "排一个",
            "排一份",
            "歌单",
            "节目单",
            "的",
        ]
        for word in commandWords {
            query = query.replacingOccurrences(of: word, with: " ")
        }
        query = query
            .trimmingCharacters(
                in: .whitespacesAndNewlines
                    .union(.punctuationCharacters)
            )
        return query.isEmpty ? normalized : query
    }
}

@MainActor
final class MusicRuntime {
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "MusicRuntime"
    )
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

    func artworkURL(for candidate: MusicCandidate) async -> URL? {
        if let artworkURL = candidate.artworkURL {
            return artworkURL
        }

        let query = "\(candidate.title) \(candidate.artist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return nil
        }
        let matches = (try? await search(
            MusicSearchRequest(text: query, limit: 12)
        )) ?? []
        let resolved = matches.first(where: {
            $0.id == candidate.id && $0.artworkURL != nil
        }) ?? matches.first(where: {
            $0.providerID == candidate.providerID
                && $0.deduplicationKey == candidate.deduplicationKey
                && $0.artworkURL != nil
        }) ?? matches.first(where: {
            $0.deduplicationKey == candidate.deduplicationKey
                && $0.artworkURL != nil
        })

        if let artworkURL = resolved?.artworkURL {
            logger.info(
                "补全歌曲封面：track=\(candidate.id, privacy: .public)，url=\(artworkURL.absoluteString, privacy: .public)"
            )
            return artworkURL
        }
        logger.warning(
            "歌曲封面补全失败：track=\(candidate.id, privacy: .public)，query=\(query, privacy: .public)"
        )
        return nil
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

        let discoveryText = ProgramDiscoveryQuery.make(
            from: brief.immediateUserInstruction
        )
        logger.info(
            "后台找歌开始：query=\(discoveryText ?? brief.moodTags.joined(separator: " "), privacy: .public)"
        )
        var discoveryCandidates: [MusicCandidate] = []
        if let searchResults = try? await search(
                MusicSearchRequest(
                    text: discoveryText,
                    moodTags: discoveryText == nil
                        ? brief.moodTags
                        : [],
                    targetEnergy: brief.energyArc.isEmpty
                        ? nil
                        : brief.energyArc.reduce(0, +)
                            / Double(brief.energyArc.count),
                    limit: 30
                )
        ) {
            discoveryCandidates = searchResults
            logger.info(
                "后台找歌完成：query=\(discoveryText ?? "默认情绪", privacy: .public)，results=\(searchResults.count)"
            )
            await libraryIndex.ingest(
                searchResults,
                origin: .discovery,
                seenAt: Date()
            )
        }
        let libraryCandidates = await programCandidates(for: brief)
        var seenCandidateIDs = Set<String>()
        let candidates = (discoveryCandidates + libraryCandidates)
            .filter { candidate in
                candidate.isPlayable
                    && seenCandidateIDs.insert(candidate.id).inserted
            }
            .prefix(30)
        logger.info(
            "后台编排候选：discovery=\(discoveryCandidates.count)，library=\(libraryCandidates.count)，merged=\(candidates.count)"
        )

        return try await AgentProgramPlanner(agent: agent).makePlan(
            brief: brief,
            candidates: Array(candidates)
        )
    }

    func preparePlayback(
        for candidate: MusicCandidate
    ) async throws -> PreparedMusicPlayback {
        logger.info(
            "解析播放资源：track=\(candidate.id, privacy: .public)，provider=\(candidate.providerID.rawValue, privacy: .public)，title=\(candidate.title, privacy: .public)"
        )
        switch candidate.providerID {
        case .netease:
            let asset: MusicPlaybackAsset
            do {
                asset = try await netease.playbackAsset(
                    for: candidate.id
                )
            } catch {
                logger.error(
                    "网易云播放地址解析失败：track=\(candidate.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            return .pcmFile(
                try await cache.store(asset, trackID: candidate.id)
            )
        case .qqMusic:
            let asset: MusicPlaybackAsset
            do {
                asset = try await qqMusic.playbackAsset(
                    for: candidate.id
                )
            } catch {
                logger.error(
                    "QQ 音乐播放地址解析失败：track=\(candidate.id, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            return .pcmFile(
                try await cache.store(asset, trackID: candidate.id)
            )
        case .appleMusic:
            return .appleMusic(trackID: candidate.id)
        default:
            throw MusicProviderClientError.playbackUnavailable
        }
    }

    func lyrics(for candidate: MusicCandidate) async throws -> MusicLyrics? {
        switch candidate.providerID {
        case .netease:
            try await netease.lyrics(for: candidate.id)
        default:
            nil
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
