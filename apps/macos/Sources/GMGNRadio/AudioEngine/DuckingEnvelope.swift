import Foundation

struct DuckingEnvelope: Equatable, Sendable {
    private let sampleRate: Double
    private let attackDuration: TimeInterval
    private let releaseDelay: TimeInterval
    private let releaseDuration: TimeInterval
    private let duckGain: Float

    private(set) var currentGain: Float = 1
    private var djIsSpeaking = false
    private var releaseDelayFramesRemaining = 0

    init(
        sampleRate: Double,
        attackDuration: TimeInterval = 0.15,
        releaseDelay: TimeInterval = 0.14,
        releaseDuration: TimeInterval = 0.45,
        duckGain: Float = 0.3
    ) {
        self.sampleRate = max(sampleRate, 1)
        self.attackDuration = max(attackDuration, 0.001)
        self.releaseDelay = max(releaseDelay, 0)
        self.releaseDuration = max(releaseDuration, 0.001)
        self.duckGain = min(max(duckGain, 0), 1)
    }

    mutating func setDJSpeaking(_ speaking: Bool) {
        djIsSpeaking = speaking
        if speaking {
            releaseDelayFramesRemaining = 0
        } else {
            releaseDelayFramesRemaining = Int(releaseDelay * sampleRate)
        }
    }

    mutating func advance(frameCount: Int) -> Float {
        var remainingFrames = max(frameCount, 0)
        guard remainingFrames > 0 else {
            return currentGain
        }

        if djIsSpeaking {
            let gainPerFrame = (1 - duckGain)
                / Float(attackDuration * sampleRate)
            currentGain = max(
                duckGain,
                currentGain - gainPerFrame * Float(remainingFrames)
            )
            return currentGain
        }

        if releaseDelayFramesRemaining > 0 {
            let heldFrames = min(
                remainingFrames,
                releaseDelayFramesRemaining
            )
            releaseDelayFramesRemaining -= heldFrames
            remainingFrames -= heldFrames
        }

        guard remainingFrames > 0 else {
            return currentGain
        }

        let gainPerFrame = (1 - duckGain)
            / Float(releaseDuration * sampleRate)
        currentGain = min(
            1,
            currentGain + gainPerFrame * Float(remainingFrames)
        )
        return currentGain
    }
}
