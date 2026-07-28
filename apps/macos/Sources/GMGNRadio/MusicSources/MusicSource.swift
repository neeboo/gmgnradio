import Foundation

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

protocol MusicAccountSession: Sendable {
    var providerID: String { get }

    func authorizationState() async -> MusicAccountAuthorizationState
    func connect() async throws
    func disconnect() async
    func capabilities() async throws -> MusicAccountCapabilities
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

struct MusicLibrarySnapshot: Equatable, Sendable {
    let savedTracks: [MusicCandidate]
    let playlistIDs: [String]
    let recentlyPlayedTrackIDs: [String]
}

protocol MusicSource: Sendable {
    var id: String { get }
    var access: MusicSourceAccess { get }

    func search(_ request: MusicSearchRequest) async throws -> [MusicCandidate]
    func fetchUserLibrary() async throws -> MusicLibrarySnapshot
}

extension MusicSource {
    var access: MusicSourceAccess { .local }

    func fetchUserLibrary() async throws -> MusicLibrarySnapshot {
        MusicLibrarySnapshot(
            savedTracks: [],
            playlistIDs: [],
            recentlyPlayedTrackIDs: []
        )
    }
}
