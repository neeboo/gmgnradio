import Foundation

struct AgentVisualDirection: Codable, Equatable, Sendable {
    let mood: String
    let palette: String
    let motion: String
    let intensity: Double
}

struct AgentShowSlotProposal: Codable, Equatable, Sendable {
    let trackID: String
    let selectionReason: String
    let shouldTalkBefore: Bool
    let transitionIntent: String
    let visual: AgentVisualDirection

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case selectionReason = "selection_reason"
        case shouldTalkBefore = "should_talk_before"
        case transitionIntent = "transition_intent"
        case visual
    }
}

struct AgentShowProposal: Codable, Equatable, Sendable {
    let title: String
    let direction: String
    let slots: [AgentShowSlotProposal]

}
