struct OrbUniforms: Equatable, Sendable {
    var resolution: SIMD2<Float>
    var time: Float
    var energy: Float
    var deformation: Float
    var glow: Float
    var particleAmount: Float
    var hue: Float
    var opacity: Float
    var audioLow: Float
    var audioMid: Float
    var audioHigh: Float
    var transitionProgress: Float
    var scale: Float
    var listeningRing: Float

    static func forState(_ state: DJState) -> OrbUniforms {
        let parameters: (
            energy: Float,
            deformation: Float,
            glow: Float,
            particles: Float,
            hue: Float,
            opacity: Float
        ) = switch state {
        case .dormant:
            (0.00, 0.00, 0.00, 0.00, 0.62, 0.00)
        case .idle:
            (0.18, 0.08, 0.14, 0.01, 0.64, 0.64)
        case .listening:
            (0.72, 0.18, 0.36, 0.02, 0.54, 0.86)
        case .thinking:
            (0.56, 0.24, 0.28, 0.02, 0.69, 0.80)
        case .speaking:
            (0.90, 0.30, 0.42, 0.03, 0.76, 0.92)
        case .playing:
            (0.62, 0.28, 0.30, 0.04, 0.65, 0.84)
        case .reconnecting:
            (0.35, 0.10, 0.22, 0.01, 0.58, 0.60)
        case .privacyOff:
            (0.04, 0.00, 0.02, 0.00, 0.00, 0.28)
        case .failed:
            (0.80, 0.14, 0.32, 0.01, 0.98, 0.82)
        }

        return OrbUniforms(
            resolution: SIMD2<Float>(1, 1),
            time: 0,
            energy: parameters.energy,
            deformation: parameters.deformation,
            glow: parameters.glow,
            particleAmount: parameters.particles,
            hue: parameters.hue,
            opacity: parameters.opacity,
            audioLow: 0,
            audioMid: 0,
            audioHigh: 0,
            transitionProgress: 1,
            scale: 1,
            listeningRing: 0
        )
    }

    static func preferredFramesPerSecond(
        for state: DJState,
        screenMaximumFPS: Int
    ) -> Int {
        let available = max(15, screenMaximumFPS)

        return switch state {
        case .dormant, .idle, .privacyOff:
            15
        case .reconnecting, .failed:
            min(30, available)
        case .thinking:
            min(60, available)
        case .listening, .speaking, .playing:
            min(120, available)
        }
    }
}
