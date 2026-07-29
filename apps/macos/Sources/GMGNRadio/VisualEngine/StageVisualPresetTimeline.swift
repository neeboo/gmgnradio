import Foundation

enum StageVisualMood: String, Codable, CaseIterable, Sendable {
    case afterglow
    case liquid
    case pulse
}

struct StageVisualPresetFrame: Equatable, Sendable {
    var weights: SIMD3<Float>

    static func forMood(_ mood: StageVisualMood) -> Self {
        switch mood {
        case .afterglow:
            Self(weights: SIMD3<Float>(1, 0, 0))
        case .liquid:
            Self(weights: SIMD3<Float>(0, 1, 0))
        case .pulse:
            Self(weights: SIMD3<Float>(0, 0, 1))
        }
    }
}

@MainActor
final class StageVisualDirectionStore {
    private(set) var currentMood: StageVisualMood?
    private(set) var currentIntensity: Float = 1
    private(set) var transitionDuration: TimeInterval = 2.4

    func update(_ mood: StageVisualMood?) {
        currentMood = mood
        currentIntensity = 1
        transitionDuration = 2.4
    }

    func update(_ cue: ProgramVisualCue) {
        currentMood = cue.mood
        currentIntensity = cue.intensity
        transitionDuration = cue.transitionDuration
    }
}

struct StageVisualPresetTimeline: Sendable {
    private static let presetCount = 3

    let presetDuration: Float
    let transitionDuration: Float

    init(
        presetDuration: Float = 24,
        transitionDuration: Float = 4
    ) {
        self.presetDuration = max(presetDuration, 1)
        self.transitionDuration = min(
            max(transitionDuration, 0),
            self.presetDuration
        )
    }

    func sample(at time: Float) -> StageVisualPresetFrame {
        let safeTime = max(time, 0)
        let cycleIndex = Int(floor(safeTime / presetDuration))
        let currentIndex = cycleIndex % Self.presetCount
        let nextIndex = (currentIndex + 1) % Self.presetCount
        let elapsed = safeTime.truncatingRemainder(dividingBy: presetDuration)
        let transitionStart = presetDuration - transitionDuration
        let blend: Float

        if transitionDuration > 0, elapsed > transitionStart {
            blend = (elapsed - transitionStart) / transitionDuration
        } else {
            blend = 0
        }

        var weights = SIMD3<Float>(repeating: 0)
        weights[currentIndex] = 1 - blend
        weights[nextIndex] += blend
        return StageVisualPresetFrame(weights: weights)
    }
}
