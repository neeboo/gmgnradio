import Foundation

struct ProgramVisualDirector: Sendable {
    static let minimumIntensity: Float = 0.18
    static let maximumIntensity: Float = 0.78

    func cue(for slot: ProgramSlot) -> ProgramVisualCue {
        guard let visual = slot.visualDirection else {
            return cue(for: slot.role)
        }
        return cue(
            for: slot.role,
            mood: semanticMood(for: visual),
            intensity: Float(visual.intensity)
        )
    }

    func cue(
        for role: ProgramSlotRole,
        mood requestedMood: StageVisualMood? = nil,
        intensity requestedIntensity: Float? = nil
    ) -> ProgramVisualCue {
        let direction = direction(for: role)
        let mood = requestedMood ?? direction.mood
        let intensity = clampedIntensity(
            requestedIntensity ?? direction.intensity
        )

        return ProgramVisualCue(
            role: role,
            mood: mood,
            frame: .forMood(mood),
            intensity: intensity,
            transitionDuration: direction.transitionDuration
        )
    }

    private func clampedIntensity(_ intensity: Float) -> Float {
        guard intensity.isFinite else {
            return Self.minimumIntensity
        }
        return min(
            max(intensity, Self.minimumIntensity),
            Self.maximumIntensity
        )
    }

    private func semanticMood(
        for direction: AgentVisualDirection
    ) -> StageVisualMood? {
        let description = [
            direction.mood,
            direction.palette,
            direction.motion,
        ].joined(separator: " ").lowercased()

        if description.containsOne(of: [
            "pulse", "neon", "peak", "energetic",
            "脉冲", "霓虹", "高能", "强烈",
        ]) {
            return .pulse
        }
        if description.containsOne(of: [
            "liquid", "flow", "ocean", "cyan",
            "流体", "流动", "海洋", "青蓝",
        ]) {
            return .liquid
        }
        if description.containsOne(of: [
            "afterglow", "warm", "amber", "sunset", "calm",
            "余晖", "温暖", "琥珀", "日落", "安静",
        ]) {
            return .afterglow
        }
        return nil
    }

    private func direction(for role: ProgramSlotRole) -> Direction {
        switch role {
        case .opener:
            Direction(
                mood: .afterglow,
                intensity: 0.30,
                transitionDuration: 6
            )
        case .build:
            Direction(
                mood: .liquid,
                intensity: 0.50,
                transitionDuration: 4
            )
        case .peak:
            Direction(
                mood: .pulse,
                intensity: Self.maximumIntensity,
                transitionDuration: 2
            )
        case .cooldown:
            Direction(
                mood: .liquid,
                intensity: 0.40,
                transitionDuration: 5
            )
        case .closer:
            Direction(
                mood: .afterglow,
                intensity: 0.24,
                transitionDuration: 7
            )
        }
    }
}

private extension String {
    func containsOne(of values: [String]) -> Bool {
        values.contains(where: contains)
    }
}

private extension ProgramVisualDirector {
    struct Direction {
        let mood: StageVisualMood
        let intensity: Float
        let transitionDuration: TimeInterval
    }
}
