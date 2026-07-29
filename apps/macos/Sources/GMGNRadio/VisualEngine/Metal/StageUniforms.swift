import Foundation
import simd

struct StageUniforms: Sendable {
    var viewProjection: simd_float4x4
    var timeAndAudio: SIMD4<Float>
    var viewportAndMotion: SIMD4<Float>

    static func make(
        camera: StageCameraFrame,
        audio: VisualAudioFeatures,
        time: Float,
        viewport: SIMD2<Float>
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

