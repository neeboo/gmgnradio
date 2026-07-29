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
}
