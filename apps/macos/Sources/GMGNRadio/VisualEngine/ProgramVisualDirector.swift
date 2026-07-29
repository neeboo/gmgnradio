import Foundation

struct ProgramVisualDirector: Sendable {
    static let minimumIntensity: Float = 0.18
    static let maximumIntensity: Float = 0.78

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

private extension ProgramVisualDirector {
    struct Direction {
        let mood: StageVisualMood
        let intensity: Float
        let transitionDuration: TimeInterval
    }
}
