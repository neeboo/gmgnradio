import Testing
@testable import GMGNRadio

@Test
func stageUniformsClampAudioAndKeepFiniteProjection() {
    let uniforms = StageUniforms.make(
        camera: StageCameraFrame(
            yaw: .pi * 0.5,
            pitch: 0.2,
            distance: 8,
            yawVelocity: 0,
            pitchVelocity: 0
        ),
        audio: VisualAudioFeatures(low: 2, mid: -1, high: 0.5),
        time: 3,
        viewport: SIMD2<Float>(1440, 900),
        presetWeights: SIMD3<Float>(0.25, 0.5, 0.25)
    )

    #expect(uniforms.timeAndAudio == SIMD4<Float>(3, 1, 0, 0.5))
    #expect(uniforms.viewportAndMotion.x == 1440)
    #expect(uniforms.viewportAndMotion.y == 900)
    #expect(uniforms.visualPreset == SIMD4<Float>(0.25, 0.5, 0.25, 1))

    for column in 0 ..< 4 {
        for row in 0 ..< 4 {
            #expect(uniforms.viewProjection[column][row].isFinite)
        }
    }
}
