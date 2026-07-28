enum DJState: String, Codable, Sendable {
    case dormant
    case idle
    case listening
    case thinking
    case speaking
    case playing
    case reconnecting
    case privacyOff
    case failed
}

enum DJEvent: String, Codable, Sendable {
    case wake
    case sleep
    case userSpeechStarted
    case userSpeechFinished
    case agentThinkingStarted
    case agentSpeechStarted
    case agentSpeechFinished
    case playbackStarted
    case playbackStopped
    case connectionLost
    case connectionRestored
    case privacyDisabled
    case privacyEnabled
    case failure
    case recover
}

struct DJStateMachine: Sendable {
    private(set) var state: DJState
    private var resumeState: DJState

    init(initial: DJState = .dormant) {
        state = initial
        resumeState = Self.resumableState(for: initial)
    }

    mutating func handle(_ event: DJEvent) {
        if state == .privacyOff, event != .privacyEnabled, event != .failure {
            return
        }

        switch event {
        case .wake:
            transition(to: .idle)
        case .sleep:
            transition(to: .dormant)
        case .userSpeechStarted:
            state = .listening
        case .userSpeechFinished, .agentThinkingStarted:
            state = .thinking
        case .agentSpeechStarted:
            state = .speaking
        case .agentSpeechFinished:
            state = resumeState == .playing ? .playing : .idle
        case .playbackStarted:
            transition(to: .playing)
        case .playbackStopped:
            transition(to: .idle)
        case .connectionLost:
            resumeState = Self.resumableState(for: state, fallback: resumeState)
            state = .reconnecting
        case .connectionRestored:
            state = resumeState
        case .privacyDisabled:
            state = .privacyOff
        case .privacyEnabled, .recover:
            transition(to: .idle)
        case .failure:
            state = .failed
        }
    }

    private mutating func transition(to nextState: DJState) {
        state = nextState
        resumeState = Self.resumableState(for: nextState)
    }

    private static func resumableState(
        for state: DJState,
        fallback: DJState = .idle
    ) -> DJState {
        switch state {
        case .playing:
            .playing
        case .dormant:
            .dormant
        case .idle:
            .idle
        default:
            fallback
        }
    }
}

