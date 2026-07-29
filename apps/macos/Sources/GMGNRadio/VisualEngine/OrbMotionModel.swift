import Foundation
import os

struct VisualAudioFeatures: Equatable, Sendable {
    var low: Float
    var mid: Float
    var high: Float

    static let silent = VisualAudioFeatures(low: 0, mid: 0, high: 0)
}

final class VisualAudioFeatureStore {
    private let storage = OSAllocatedUnfairLock(
        initialState: VisualAudioFeatures.silent
    )

    var current: VisualAudioFeatures {
        storage.withLock { $0 }
    }

    func update(_ features: VisualAudioFeatures) {
        storage.withLock { current in
            current = features
        }
    }
}

struct OrbMotionFrame: Equatable, Sendable {
    var energy: Float
    var deformation: Float
    var glow: Float
    var particleAmount: Float
    var hue: Float
    var opacity: Float
    var scale: Float
    var listeningRing: Float

    static func interpolated(
        from start: OrbMotionFrame,
        to end: OrbMotionFrame,
        progress: Float
    ) -> OrbMotionFrame {
        let amount = min(max(progress, 0), 1)
        return OrbMotionFrame(
            energy: mix(start.energy, end.energy, amount),
            deformation: mix(start.deformation, end.deformation, amount),
            glow: mix(start.glow, end.glow, amount),
            particleAmount: mix(start.particleAmount, end.particleAmount, amount),
            hue: mix(start.hue, end.hue, amount),
            opacity: mix(start.opacity, end.opacity, amount),
            scale: mix(start.scale, end.scale, amount),
            listeningRing: mix(start.listeningRing, end.listeningRing, amount)
        )
    }

    private static func mix(_ start: Float, _ end: Float, _ amount: Float) -> Float {
        start + (end - start) * amount
    }
}

struct OrbMotionModel: Sendable {
    private(set) var targetState: DJState
    private let seed: UInt64
    private var transitionStartTime: Float
    private var transitionDuration: Float
    private var transitionStartFrame: OrbMotionFrame

    init(initial: DJState, seed: UInt64, time: Float) {
        targetState = initial
        self.seed = seed
        transitionStartTime = time
        transitionDuration = 0
        transitionStartFrame = Self.frame(
            for: initial,
            time: time,
            seed: seed,
            audio: .silent
        )
    }

    mutating func transition(
        to state: DJState,
        at time: Float,
        audio: VisualAudioFeatures
    ) {
        guard state != targetState else {
            return
        }

        transitionStartFrame = frame(at: time, audio: audio)
        transitionStartTime = time
        transitionDuration = Self.transitionDuration(to: state)
        targetState = state
    }

    func frame(at time: Float, audio: VisualAudioFeatures) -> OrbMotionFrame {
        let targetFrame = Self.frame(
            for: targetState,
            time: time,
            seed: seed,
            audio: audio
        )
        guard transitionDuration > 0 else {
            return targetFrame
        }

        let linearProgress = min(
            max((time - transitionStartTime) / transitionDuration, 0),
            1
        )
        let smoothProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        return OrbMotionFrame.interpolated(
            from: transitionStartFrame,
            to: targetFrame,
            progress: smoothProgress
        )
    }

    static func frame(
        for state: DJState,
        time: Float,
        seed: UInt64,
        audio: VisualAudioFeatures
    ) -> OrbMotionFrame {
        let phase = Float(seed % 4096) / 4096 * 2 * .pi
        let slowWave = wave(time * 0.74 + phase)
        let quickWave = wave(time * 2.1 + phase * 0.7)

        var result = switch state {
        case .dormant:
            OrbMotionFrame(
                energy: 0,
                deformation: 0,
                glow: 0,
                particleAmount: 0,
                hue: 0.62,
                opacity: 0,
                scale: 0.82,
                listeningRing: 0
            )
        case .idle:
            OrbMotionFrame(
                energy: 0.18 + slowWave * 0.025,
                deformation: 0.10 + slowWave * 0.018,
                glow: 0.23 + slowWave * 0.025,
                particleAmount: 0.006,
                hue: 0.64 + slowWave * 0.008,
                opacity: 0.86,
                scale: 1.0 + slowWave * 0.035,
                listeningRing: 0
            )
        case .listening:
            OrbMotionFrame(
                energy: 0.72 + quickWave * 0.05,
                deformation: 0.16 + quickWave * 0.025,
                glow: 0.34 + slowWave * 0.03,
                particleAmount: 0.012,
                hue: 0.54 + slowWave * 0.012,
                opacity: 0.86,
                scale: 1.01 + quickWave * 0.012,
                listeningRing: 0.86 + slowWave * 0.06
            )
        case .thinking:
            OrbMotionFrame(
                energy: 0.56 + quickWave * 0.05,
                deformation: 0.23 + slowWave * 0.035,
                glow: 0.27,
                particleAmount: 0.014,
                hue: 0.69 + quickWave * 0.014,
                opacity: 0.80,
                scale: 0.99 + slowWave * 0.01,
                listeningRing: 0.12
            )
        case .speaking:
            OrbMotionFrame(
                energy: 0.90 + quickWave * 0.07,
                deformation: 0.28 + quickWave * 0.055,
                glow: 0.40 + quickWave * 0.035,
                particleAmount: 0.018,
                hue: 0.76 + slowWave * 0.012,
                opacity: 0.92,
                scale: 1.02 + quickWave * 0.018,
                listeningRing: 0.08
            )
        case .playing:
            OrbMotionFrame(
                energy: 0.58 + slowWave * 0.08,
                deformation: 0.25 + quickWave * 0.04,
                glow: 0.29 + slowWave * 0.025,
                particleAmount: 0.022,
                hue: 0.65 + slowWave * 0.025,
                opacity: 0.84,
                scale: 1.0 + slowWave * 0.018,
                listeningRing: 0.04
            )
        case .reconnecting:
            OrbMotionFrame(
                energy: 0.34 + slowWave * 0.02,
                deformation: 0.09,
                glow: 0.20 + slowWave * 0.04,
                particleAmount: 0.006,
                hue: 0.58,
                opacity: 0.58,
                scale: 0.96,
                listeningRing: 0.22 + slowWave * 0.12
            )
        case .privacyOff:
            OrbMotionFrame(
                energy: 0.04,
                deformation: 0,
                glow: 0.015,
                particleAmount: 0,
                hue: 0,
                opacity: 0.26,
                scale: 0.92,
                listeningRing: 0
            )
        case .failed:
            OrbMotionFrame(
                energy: 0.80 + quickWave * 0.04,
                deformation: 0.14,
                glow: 0.30,
                particleAmount: 0.008,
                hue: 0.98,
                opacity: 0.82,
                scale: 0.98,
                listeningRing: 0
            )
        }

        if state == .playing {
            result.energy += audio.low * 0.18
            result.deformation += (audio.low * 0.08) + (audio.mid * 0.05)
            result.glow += audio.high * 0.06
            result.particleAmount += audio.high * 0.012
            result.scale += audio.low * 0.025
        }

        return result
    }

    private static func transitionDuration(to state: DJState) -> Float {
        switch state {
        case .dormant, .privacyOff:
            0.42
        case .listening:
            0.28
        default:
            0.34
        }
    }

    private static func wave(_ value: Float) -> Float {
        sin(value)
    }
}
