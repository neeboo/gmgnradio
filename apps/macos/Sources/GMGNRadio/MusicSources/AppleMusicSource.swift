import Foundation
@preconcurrency import MusicKit

enum AppleMusicClientAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

struct AppleMusicCatalogTrack: Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let isPlayable: Bool
    let isrc: String?
    let genres: [String]
    let releaseYear: Int?
}

@MainActor
protocol AppleMusicClient: Sendable {
    func authorizationStatus() async -> AppleMusicClientAuthorization
    func requestAuthorization() async -> AppleMusicClientAuthorization
    func hasPlayableSubscription() async throws -> Bool
    func search(
        term: String,
        limit: Int
    ) async throws -> [AppleMusicCatalogTrack]
    func play(trackID: String) async throws
    func pause() async
    func skipToNextEntry() async throws
}

struct AppleMusicSource: MusicSource {
    let id = MusicProviderID.appleMusic
    private let client: any AppleMusicClient

    init(client: any AppleMusicClient) {
        self.client = client
    }

    @MainActor
    init() {
        client = SystemAppleMusicClient()
    }

    func access() async -> MusicSourceAccess {
        switch await client.authorizationStatus() {
        case .notDetermined:
            return .accountRequired(.disconnected)
        case .denied, .restricted:
            return .accountRequired(.denied)
        case .authorized:
            do {
                return try await client.hasPlayableSubscription()
                    ? .accountRequired(.connected)
                    : .accountRequired(.unavailable)
            } catch {
                return .accountRequired(.unavailable)
            }
        }
    }

    @discardableResult
    func requestAuthorization() async -> MusicSourceAccess {
        _ = await client.requestAuthorization()
        return await access()
    }

    func search(
        _ request: MusicSearchRequest
    ) async throws -> [MusicCandidate] {
        guard await access() == .accountRequired(.connected) else {
            throw MusicSourceError.authenticationRequired(id)
        }
        let term = ([request.text].compactMap { $0 }
            + request.moodTags
            + request.genres)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else {
            return []
        }
        return try await client.search(
            term: term,
            limit: max(1, min(request.limit, 30))
        ).map {
            MusicCandidate(
                id: "\(id.rawValue):\($0.id)",
                canonicalID: $0.isrc,
                providerID: id,
                source: .streaming,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration,
                isPlayable: $0.isPlayable,
                matchScore: 0.86,
                userAffinity: 0.5,
                energy: 0.5,
                moodTags: [],
                genres: $0.genres,
                releaseYear: $0.releaseYear
            )
        }
    }

    func fetchUserLibrary() async throws -> MusicLibrarySnapshot {
        MusicLibrarySnapshot(
            savedTracks: [],
            playlistIDs: [],
            recentlyPlayedTrackIDs: []
        )
    }

    func play(trackID: String) async throws {
        guard await access() == .accountRequired(.connected) else {
            throw MusicSourceError.authenticationRequired(id)
        }
        let prefix = "\(id.rawValue):"
        let rawID = trackID.hasPrefix(prefix)
            ? String(trackID.dropFirst(prefix.count))
            : trackID
        try await client.play(trackID: rawID)
    }

    func pause() async {
        await client.pause()
    }

    func skipToNextEntry() async throws {
        try await client.skipToNextEntry()
    }
}

@MainActor
final class SystemAppleMusicClient: AppleMusicClient {
    private let player = ApplicationMusicPlayer.shared

    func authorizationStatus() -> AppleMusicClientAuthorization {
        mapAuthorization(MusicAuthorization.currentStatus)
    }

    func requestAuthorization() async -> AppleMusicClientAuthorization {
        mapAuthorization(await MusicAuthorization.request())
    }

    func hasPlayableSubscription() async throws -> Bool {
        try await MusicSubscription.current.canPlayCatalogContent
    }

    func search(
        term: String,
        limit: Int
    ) async throws -> [AppleMusicCatalogTrack] {
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self]
        )
        request.limit = limit
        let response = try await request.response()
        return response.songs.map { song in
            AppleMusicCatalogTrack(
                id: song.id.rawValue,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                duration: song.duration ?? 0,
                isPlayable: song.playParameters != nil,
                isrc: song.isrc,
                genres: song.genreNames,
                releaseYear: song.releaseDate.map {
                    Calendar(identifier: .gregorian).component(
                        .year,
                        from: $0
                    )
                }
            )
        }
    }

    func play(trackID: String) async throws {
        let id = MusicItemID(trackID)
        var request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: id
        )
        request.limit = 1
        let response = try await request.response()
        guard let song = response.items.first else {
            throw MusicProviderClientError.playbackUnavailable
        }
        player.queue = [song]
        try await player.play()
    }

    func pause() {
        player.pause()
    }

    func skipToNextEntry() async throws {
        try await player.skipToNextEntry()
    }

    private func mapAuthorization(
        _ status: MusicAuthorization.Status
    ) -> AppleMusicClientAuthorization {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .authorized:
            .authorized
        @unknown default:
            .restricted
        }
    }
}
