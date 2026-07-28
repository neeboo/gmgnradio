enum ConversationMode: String, Codable, Sendable {
    case quiet
    case ambient
    case conversational
}

struct TrackReference: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String?
}

struct PlaybackContext: Codable, Equatable, Sendable {
    var currentTrack: TrackReference?
    var upcomingTrackIDs: [String]
    var musicGain: Float
    var conversationMode: ConversationMode
    var programID: String?

    init(
        currentTrack: TrackReference? = nil,
        upcomingTrackIDs: [String] = [],
        musicGain: Float = 1,
        conversationMode: ConversationMode = .ambient,
        programID: String? = nil
    ) {
        self.currentTrack = currentTrack
        self.upcomingTrackIDs = upcomingTrackIDs
        self.musicGain = musicGain
        self.conversationMode = conversationMode
        self.programID = programID
    }
}
