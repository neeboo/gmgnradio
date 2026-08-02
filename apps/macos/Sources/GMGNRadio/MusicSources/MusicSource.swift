import Foundation

struct MusicProviderID:
    RawRepresentable,
    Hashable,
    Codable,
    Sendable,
    ExpressibleByStringLiteral
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    static let local = MusicProviderID(rawValue: "local")
    static let netease = MusicProviderID(rawValue: "netease")
    static let qqMusic = MusicProviderID(rawValue: "qq-music")
    static let appleMusic = MusicProviderID(rawValue: "apple-music")
}

enum MusicSourceKind: String, Codable, Sendable {
    case localLibrary
    case streaming
}

enum MusicAccountAuthorizationState: String, Codable, Sendable {
    case disconnected
    case authorizing
    case connected
    case expired
    case denied
    case unavailable
}

enum MusicSourceAccess: Equatable, Sendable {
    case local
    case accountRequired(MusicAccountAuthorizationState)

    var isReady: Bool {
        switch self {
        case .local, .accountRequired(.connected):
            true
        case .accountRequired:
            false
        }
    }
}

struct MusicAccountCapabilities: Equatable, Sendable {
    let canSearchCatalog: Bool
    let canReadLibrary: Bool
    let canReadPlaylists: Bool
    let canReadRecentPlays: Bool
    let canPlay: Bool
}

struct MusicSearchRequest: Equatable, Sendable {
    var text: String?
    var moodTags: [String]
    var genres: [String]
    var targetEnergy: Double?
    var limit: Int

    init(
        text: String? = nil,
        moodTags: [String] = [],
        genres: [String] = [],
        targetEnergy: Double? = nil,
        limit: Int = 30
    ) {
        self.text = text
        self.moodTags = moodTags
        self.genres = genres
        self.targetEnergy = targetEnergy
        self.limit = limit
    }
}

struct MusicCandidate: Codable, Equatable, Sendable {
    let id: String
    let canonicalID: String?
    let providerID: MusicProviderID
    let source: MusicSourceKind
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let isPlayable: Bool
    let matchScore: Double
    let userAffinity: Double
    let energy: Double
    let moodTags: [String]
    let genres: [String]
    let releaseYear: Int?
    var artworkURL: URL? = nil

    var deduplicationKey: String {
        if let canonicalID, !canonicalID.isEmpty {
            return canonicalID.lowercased()
        }
        return "\(title)|\(artist)"
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            .lowercased()
    }
}

struct MusicPlaylistSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let providerID: MusicProviderID
    let name: String
    let artworkURL: URL?
    let tracks: [MusicCandidate]
    let totalTrackCount: Int

    var trackCount: Int {
        max(totalTrackCount, tracks.count)
    }

    init(
        id: String,
        providerID: MusicProviderID,
        name: String,
        artworkURL: URL?,
        tracks: [MusicCandidate],
        totalTrackCount: Int? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.artworkURL = artworkURL
        self.tracks = tracks
        self.totalTrackCount = max(totalTrackCount ?? tracks.count, tracks.count)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case name
        case artworkURL
        case tracks
        case totalTrackCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(
            MusicProviderID.self,
            forKey: .providerID
        )
        name = try container.decode(String.self, forKey: .name)
        artworkURL = try container.decodeIfPresent(
            URL.self,
            forKey: .artworkURL
        )
        tracks = try container.decode(
            [MusicCandidate].self,
            forKey: .tracks
        )
        totalTrackCount = max(
            try container.decodeIfPresent(
                Int.self,
                forKey: .totalTrackCount
            ) ?? tracks.count,
            tracks.count
        )
    }
}

struct MusicPlaylistPage: Equatable, Sendable {
    let playlistID: String
    let tracks: [MusicCandidate]
    let offset: Int
    let totalTrackCount: Int

    var hasMore: Bool {
        offset + tracks.count < totalTrackCount
    }
}

struct MusicLibrarySnapshot: Equatable, Sendable {
    let savedTracks: [MusicCandidate]
    let playlists: [MusicPlaylistSnapshot]
    let recentlyPlayedTrackIDs: [String]

    var playlistIDs: [String] {
        playlists.map(\.id)
    }

    init(
        savedTracks: [MusicCandidate],
        playlists: [MusicPlaylistSnapshot],
        recentlyPlayedTrackIDs: [String]
    ) {
        self.savedTracks = savedTracks
        self.playlists = playlists
        self.recentlyPlayedTrackIDs = recentlyPlayedTrackIDs
    }

    init(
        savedTracks: [MusicCandidate],
        playlistIDs: [String],
        recentlyPlayedTrackIDs: [String]
    ) {
        self.init(
            savedTracks: savedTracks,
            playlists: playlistIDs.map {
                MusicPlaylistSnapshot(
                    id: $0,
                    providerID: .local,
                    name: $0,
                    artworkURL: nil,
                    tracks: []
                )
            },
            recentlyPlayedTrackIDs: recentlyPlayedTrackIDs
        )
    }
}

protocol MusicSource: Sendable {
    var id: MusicProviderID { get }

    func access() async -> MusicSourceAccess
    func search(_ request: MusicSearchRequest) async throws -> [MusicCandidate]
    func fetchUserLibrary() async throws -> MusicLibrarySnapshot
    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int
    ) async throws -> MusicPlaylistPage
}

extension MusicSource {
    func access() async -> MusicSourceAccess { .local }

    func fetchUserLibrary() async throws -> MusicLibrarySnapshot {
        MusicLibrarySnapshot(
            savedTracks: [],
            playlistIDs: [],
            recentlyPlayedTrackIDs: []
        )
    }

    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int
    ) async throws -> MusicPlaylistPage {
        let library = try await fetchUserLibrary()
        guard let playlist = library.playlists.first(where: {
            $0.id == playlistID
        }) else {
            return MusicPlaylistPage(
                playlistID: playlistID,
                tracks: [],
                offset: max(0, offset),
                totalTrackCount: 0
            )
        }
        let safeOffset = min(max(0, offset), playlist.tracks.count)
        let end = min(
            safeOffset + max(1, limit),
            playlist.tracks.count
        )
        return MusicPlaylistPage(
            playlistID: playlistID,
            tracks: Array(playlist.tracks[safeOffset ..< end]),
            offset: safeOffset,
            totalTrackCount: playlist.trackCount
        )
    }
}
