import Foundation

struct ProgramBrief: Codable, Equatable, Sendable {
    let id: String
    let targetDuration: TimeInterval
    let moodTags: [String]
    let energyArc: [Double]
    let conversationMode: ConversationMode
    let immediateUserInstruction: String?
    let blockedTrackIDs: Set<String>
    let recentlySkippedTrackIDs: Set<String>

    init(
        id: String,
        targetDuration: TimeInterval,
        moodTags: [String],
        energyArc: [Double],
        conversationMode: ConversationMode,
        immediateUserInstruction: String? = nil,
        blockedTrackIDs: Set<String> = [],
        recentlySkippedTrackIDs: Set<String> = []
    ) {
        self.id = id
        self.targetDuration = targetDuration
        self.moodTags = moodTags
        self.energyArc = energyArc
        self.conversationMode = conversationMode
        self.immediateUserInstruction = immediateUserInstruction
        self.blockedTrackIDs = blockedTrackIDs
        self.recentlySkippedTrackIDs = recentlySkippedTrackIDs
    }
}

enum ProgramSlotRole: String, Codable, Sendable {
    case opener
    case build
    case peak
    case cooldown
    case closer
}

struct ProgramHostHint: Codable, Equatable, Sendable {
    let shouldTalkBefore: Bool
    let maxSentenceCount: Int
    let selectionReason: String
    let currentTrack: TrackReference
    let nextTrack: TrackReference?
    let facts: [String]
    let transitionIntent: String?
}

struct ProgramSlot: Codable, Equatable, Sendable {
    let track: MusicCandidate
    let role: ProgramSlotRole
    let hostHint: ProgramHostHint
    let visualDirection: AgentVisualDirection?

    init(
        track: MusicCandidate,
        role: ProgramSlotRole,
        hostHint: ProgramHostHint,
        visualDirection: AgentVisualDirection? = nil
    ) {
        self.track = track
        self.role = role
        self.hostHint = hostHint
        self.visualDirection = visualDirection
    }
}

struct ProgramPlan: Codable, Equatable, Sendable {
    let brief: ProgramBrief
    let slots: [ProgramSlot]
    let revision: Int
    let generatedAt: Date
    let replanAfterTrackCount: Int
    let title: String?
    let direction: String?

    init(
        brief: ProgramBrief,
        slots: [ProgramSlot],
        revision: Int,
        generatedAt: Date,
        replanAfterTrackCount: Int,
        title: String? = nil,
        direction: String? = nil
    ) {
        self.brief = brief
        self.slots = slots
        self.revision = revision
        self.generatedAt = generatedAt
        self.replanAfterTrackCount = replanAfterTrackCount
        self.title = title
        self.direction = direction
    }
}

enum ProgramPlannerError: Error, Equatable {
    case insufficientPlayableCandidates(required: Int, available: Int)
}

@MainActor
struct ProgramPlanner {
    private let client: RustMusicProgramClient
    init(client: RustMusicProgramClient? = nil) { self.client = client ?? RustMusicProgramClient() }
    func makePlan(brief: ProgramBrief, candidates: [MusicCandidate]) async throws -> ProgramPlan {
        // Candidate IDs/model proposals cannot authorize a native-written plan.
        // The daemon applies the same deterministic policy to provider facts.
        return try await client.plan(brief: brief, discoveryCandidates: candidates,
                                     libraryCandidates: [], hostPrompt: "")
    }
}
