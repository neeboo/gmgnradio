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

    func sanitized(
        knownTrackIDs: Set<String>,
        maximumTrackCount: Int = 8
    ) -> AgentShowProposal {
        var seen = Set<String>()
        let safeSlots: [AgentShowSlotProposal] = slots
            .prefix(maximumTrackCount)
            .compactMap { slot -> AgentShowSlotProposal? in
            guard
                knownTrackIDs.contains(slot.trackID),
                seen.insert(slot.trackID).inserted
            else {
                return nil
            }
            return AgentShowSlotProposal(
                trackID: slot.trackID,
                selectionReason: slot.selectionReason.cleaned(limit: 180),
                shouldTalkBefore: slot.shouldTalkBefore,
                transitionIntent: slot.transitionIntent.cleaned(limit: 180),
                visual: AgentVisualDirection(
                    mood: slot.visual.mood.cleaned(limit: 60),
                    palette: slot.visual.palette.cleaned(limit: 60),
                    motion: slot.visual.motion.cleaned(limit: 60),
                    intensity: min(1, max(0, slot.visual.intensity))
                )
            )
            }
        return AgentShowProposal(
            title: title.cleaned(limit: 60),
            direction: direction.cleaned(limit: 240),
            slots: safeSlots
        )
    }
}

private extension String {
    func cleaned(limit: Int) -> String {
        String(
            trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(limit)
        )
    }
}
