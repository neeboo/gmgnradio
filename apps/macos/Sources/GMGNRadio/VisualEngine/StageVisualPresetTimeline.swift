import Foundation

struct StageVisualPresetFrame: Equatable, Sendable {
    var weights: SIMD3<Float>
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
