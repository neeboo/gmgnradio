import Foundation
import simd

struct StageCompositingProfile: Sendable, Equatable {
    let videoOpacity: Float
    let backgroundAlpha: Float
    let particleScale: Float
    let particlePresence: Float
    let bloomStrength: Float
    let edgeContrast: Float

    static let standard = StageCompositingProfile(
        videoOpacity: 1,
        backgroundAlpha: 1,
        particleScale: 1,
        particlePresence: 1,
        bloomStrength: 0.18,
        edgeContrast: 0.12
    )

    static let video = StageCompositingProfile(
        videoOpacity: 0.68,
        backgroundAlpha: 0.28,
        particleScale: 1.24,
        particlePresence: 1.28,
        bloomStrength: 0.82,
        edgeContrast: 0.86
    )
}

struct StageUniforms: Sendable {
    var viewProjection: simd_float4x4
    var timeAndAudio: SIMD4<Float>
    var viewportAndMotion: SIMD4<Float>
    var visualPreset: SIMD4<Float>
    var topologyMotion: SIMD4<Float>
    var rhythm: SIMD4<Float>
    var waveformA: SIMD4<Float>
    var waveformB: SIMD4<Float>
    var palettePrimary: SIMD4<Float>
    var paletteSecondary: SIMD4<Float>
    var paletteBackground: SIMD4<Float>
    var compositing: SIMD4<Float>
    var layering: SIMD4<Float>

    static func make(
        camera: StageCameraFrame,
        audio: VisualAudioFeatures,
        time: Float,
        viewport: SIMD2<Float>,
        presetWeights: SIMD3<Float>,
        composition: Float = 0,
        palette: StageVisualPalette = .amber,
        visualIntensity: Float = 1,
        compositing: StageCompositingProfile = .standard,
        pointLayers: StagePointLayerPolicy = .init(
            primaryVisibility: 1,
            ambientVisibility: 0.72
        )
    ) -> StageUniforms {
        let width = max(viewport.x, 1)
        let height = max(viewport.y, 1)
        let aspect = width / height
        let horizontal = cos(camera.pitch) * camera.distance
        let eye = SIMD3<Float>(
            sin(camera.yaw) * horizontal,
            sin(camera.pitch) * camera.distance,
            cos(camera.yaw) * horizontal
        )
        let view = lookAt(
            eye: eye,
            target: SIMD3<Float>(0, -0.1, 0),
            up: SIMD3<Float>(0, 1, 0)
        )
        let projection = perspective(
            verticalFieldOfView: 48 * .pi / 180,
            aspect: aspect,
            near: 0.1,
            far: 80
        )

        return StageUniforms(
            viewProjection: projection * view,
            timeAndAudio: SIMD4<Float>(
                time,
                clamp(audio.low),
                clamp(audio.mid),
                clamp(audio.high)
            ),
            viewportAndMotion: SIMD4<Float>(
                width,
                height,
                min(abs(camera.yawVelocity) + abs(camera.pitchVelocity), 2),
                1
            ),
            visualPreset: SIMD4<Float>(
                presetWeights.x,
                presetWeights.y,
                presetWeights.z,
                clamp(visualIntensity)
            ),
            topologyMotion: SIMD4<Float>(
                simd_dot(
                    presetWeights,
                    SIMD3<Float>(1, 1, 0.34)
                ),
                simd_dot(
                    presetWeights,
                    SIMD3<Float>(1, 1, 0)
                ),
                simd_dot(
                    presetWeights,
                    SIMD3<Float>(1, 1, 0)
                ),
                min(max(composition, 0), 2)
            ),
            rhythm: SIMD4<Float>(
                clamp(audio.beat),
                clamp(audio.onset),
                clamp(audio.amplitude),
                clamp(
                    (0 ..< 8).reduce(Float.zero) {
                        $0 + audio.waveform[$1]
                    } / 8
                )
            ),
            waveformA: SIMD4<Float>(
                clamp(audio.waveform[0]),
                clamp(audio.waveform[1]),
                clamp(audio.waveform[2]),
                clamp(audio.waveform[3])
            ),
            waveformB: SIMD4<Float>(
                clamp(audio.waveform[4]),
                clamp(audio.waveform[5]),
                clamp(audio.waveform[6]),
                clamp(audio.waveform[7])
            ),
            palettePrimary: SIMD4<Float>(
                palette.primary.x,
                palette.primary.y,
                palette.primary.z,
                1
            ),
            paletteSecondary: SIMD4<Float>(
                palette.secondary.x,
                palette.secondary.y,
                palette.secondary.z,
                1
            ),
            paletteBackground: SIMD4<Float>(
                palette.background.x,
                palette.background.y,
                palette.background.z,
                clamp(compositing.backgroundAlpha)
            ),
            compositing: SIMD4<Float>(
                max(compositing.particleScale, 0),
                max(compositing.particlePresence, 0),
                max(compositing.bloomStrength, 0),
                clamp(compositing.edgeContrast)
            ),
            layering: SIMD4<Float>(
                clamp(pointLayers.primaryVisibility),
                max(pointLayers.ambientVisibility, 0),
                0,
                0
            )
        )
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func perspective(
        verticalFieldOfView: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let yScale = 1 / tan(verticalFieldOfView * 0.5)
        let xScale = yScale / max(aspect, 0.001)
        let zRange = far - near

        return simd_float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -far / zRange, -1),
            SIMD4<Float>(0, 0, -(far * near) / zRange, 0)
        )
    }

    private static func lookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let correctedUp = simd_cross(right, forward)

        return simd_float4x4(
            SIMD4<Float>(right.x, correctedUp.x, -forward.x, 0),
            SIMD4<Float>(right.y, correctedUp.y, -forward.y, 0),
            SIMD4<Float>(right.z, correctedUp.z, -forward.z, 0),
            SIMD4<Float>(
                -simd_dot(right, eye),
                -simd_dot(correctedUp, eye),
                simd_dot(forward, eye),
                1
            )
        )
    }
}

struct StageRhythmResponse: Sendable {
    private var displayed = VisualAudioFeatures.silent

    mutating func update(
        audio: VisualAudioFeatures,
        deltaTime: Float
    ) -> VisualAudioFeatures {
        let dt = min(max(deltaTime, 0), 0.1)
        displayed.low = follow(
            current: displayed.low,
            target: audio.low,
            decay: 7,
            deltaTime: dt
        )
        displayed.mid = follow(
            current: displayed.mid,
            target: audio.mid,
            decay: 9,
            deltaTime: dt
        )
        displayed.high = follow(
            current: displayed.high,
            target: audio.high,
            decay: 13,
            deltaTime: dt
        )
        displayed.beat = follow(
            current: displayed.beat,
            target: audio.beat,
            decay: 5.2,
            deltaTime: dt
        )
        displayed.onset = follow(
            current: displayed.onset,
            target: audio.onset,
            decay: 10,
            deltaTime: dt
        )
        displayed.amplitude = follow(
            current: displayed.amplitude,
            target: audio.amplitude,
            decay: 6,
            deltaTime: dt
        )
        for index in 0 ..< 8 {
            displayed.waveform[index] = follow(
                current: displayed.waveform[index],
                target: audio.waveform[index],
                decay: 7,
                deltaTime: dt
            )
        }
        return displayed
    }

    private func follow(
        current: Float,
        target: Float,
        decay: Float,
        deltaTime: Float
    ) -> Float {
        let safeTarget = min(max(target, 0), 1)
        if safeTarget >= current {
            return safeTarget
        }
        return safeTarget
            + (current - safeTarget) * exp(-decay * deltaTime)
    }
}
