enum OrbState: String, Codable, Sendable {
    case hidden
    case resting
    case receptive
    case processing
    case vocalizing
    case musical
    case reconnecting
    case privacyOff
    case error

    init(djState: DJState) {
        self = switch djState {
        case .dormant:
            .hidden
        case .idle:
            .resting
        case .listening:
            .receptive
        case .thinking:
            .processing
        case .speaking:
            .vocalizing
        case .playing:
            .musical
        case .reconnecting:
            .reconnecting
        case .privacyOff:
            .privacyOff
        case .failed:
            .error
        }
    }
}

