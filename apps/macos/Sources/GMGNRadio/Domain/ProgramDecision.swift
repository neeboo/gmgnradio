struct ProgramDecision: Codable, Equatable, Sendable {
    enum Action: Codable, Equatable, Sendable {
        case searchMusic(query: String)
        case replaceUpcomingQueue(trackIDs: [String])
        case playTrack(id: String)
        case skipTrack
        case setMusicGain(Float)
        case rememberPreference(key: String, value: String)
        case forgetCurrentContext
        case setConversationMode(ConversationMode)
        case enterImmersiveVisuals
        case endProgram
    }

    let id: String
    let idempotencyKey: String
    let action: Action
    let rationale: String?

    init(
        id: String,
        idempotencyKey: String,
        action: Action,
        rationale: String? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.action = action
        self.rationale = rationale
    }
}

