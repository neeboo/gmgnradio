import Foundation
import Testing
@testable import GMGNRadio

@Test
func particleShaderCarriesPrismaticColorAlongRhythmPropagationPath() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let shaderURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal"
        )
    let shader = try String(contentsOf: shaderURL, encoding: .utf8)

    #expect(shader.contains("stagePrismaticColor"))
    #expect(shader.contains("propagationPhase"))
    #expect(shader.contains("beatColorWave"))
}

@Test
func particleShaderBuildsASeparateAmbientDepthLayer() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let shaderURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal"
        )
    let shader = try String(contentsOf: shaderURL, encoding: .utf8)

    #expect(shader.contains("stageAmbientParticleVertex"))
    #expect(shader.contains("stageAmbientParticleFragment"))
    #expect(shader.contains("ambientShape"))
    #expect(shader.contains("ambientRotation"))
    #expect(shader.contains("facetLight"))
}

@Test
func particleShaderContainsTheMineradioDerivedManualTopologies() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let shaderURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal"
        )
    let shader = try String(contentsOf: shaderURL, encoding: .utf8)
    let uniforms = StageUniforms.make(
        camera: StageCameraModel().frame,
        audio: .silent,
        time: 0,
        viewport: SIMD2<Float>(1180, 760),
        presetWeights: SIMD3<Float>(1, 0, 0),
        composition: 2
    )

    #expect(uniforms.topologyMotion.w == 2)
    #expect(shader.contains("albumReliefPosition"))
    #expect(shader.contains("coverColumnDisplacement"))
    #expect(shader.contains("artworkTexel"))
    #expect(shader.contains("albumReliefAmount"))
    #expect(!shader.contains("vinylSpin"))
    #expect(!shader.contains("vinylRotated"))
    #expect(shader.contains("galaxyPosition"))
    #expect(shader.contains("tunnelPosition"))
    #expect(shader.contains("presetMass"))
}

@Test
func albumCoverParticlesKeepArtworkReadableOnDarkStages() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let shaderURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal"
        )
    let shader = try String(contentsOf: shaderURL, encoding: .utf8)

    #expect(shader.contains("stageReadableArtworkColor"))
    #expect(shader.contains("coverReadabilityScale"))
    #expect(shader.contains("float coverAlpha = mix(0.18, 1.0"))
    #expect(shader.contains("coverBloomBoost"))
}

@Test
func mainStageBackgroundStaysNeutralAcrossMoodChanges() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let shaderURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal"
        )
    let shader = try String(contentsOf: shaderURL, encoding: .utf8)

    #expect(shader.contains("stageNeutralBackgroundColor"))
    #expect(!shader.contains("quietAccent"))
}

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
        audio: VisualAudioFeatures(
            low: 2,
            mid: -1,
            high: 0.5,
            beat: 1.4,
            onset: 0.75,
            amplitude: 0.6,
            waveform: SIMD8<Float>(
                0,
                0.2,
                0.4,
                0.6,
                0.8,
                1,
                1.2,
                -0.2
            )
        ),
        time: 3,
        viewport: SIMD2<Float>(1440, 900),
        presetWeights: SIMD3<Float>(0.25, 0.5, 0.25),
        palette: .amber
    )

    #expect(uniforms.timeAndAudio == SIMD4<Float>(3, 1, 0, 0.5))
    #expect(uniforms.viewportAndMotion.x == 1440)
    #expect(uniforms.viewportAndMotion.y == 900)
    #expect(uniforms.visualPreset == SIMD4<Float>(0.25, 0.5, 0.25, 1))
    #expect(uniforms.rhythm.x == 1)
    #expect(uniforms.rhythm.y == 0.75)
    #expect(uniforms.rhythm.z == 0.6)
    #expect(abs(uniforms.rhythm.w - 0.5) < 0.000_001)
    #expect(uniforms.waveformA == SIMD4<Float>(0, 0.2, 0.4, 0.6))
    #expect(uniforms.waveformB == SIMD4<Float>(0.8, 1, 1, 0))
    #expect(uniforms.palettePrimary == SIMD4<Float>(1, 0.34, 0.04, 1))
    #expect(uniforms.paletteSecondary == SIMD4<Float>(1, 0.74, 0.18, 1))

    for column in 0 ..< 4 {
        for row in 0 ..< 4 {
            #expect(uniforms.viewProjection[column][row].isFinite)
        }
    }
}

@Test
func stageUniformsCarryATransparentVeilForVideoComposition() {
    let profile = StageCompositingProfile.video
    let uniforms = StageUniforms.make(
        camera: StageCameraModel().frame,
        audio: .silent,
        time: 0,
        viewport: SIMD2<Float>(1_180, 760),
        presetWeights: SIMD3<Float>(1, 0, 0),
        compositing: profile
    )

    #expect(profile.videoOpacity < 0.75)
    #expect(profile.backgroundAlpha >= 0.25)
    #expect(profile.particleScale > 1)
    #expect(profile.particlePresence > 1)
    #expect(profile.bloomStrength > 0.7)
    #expect(profile.edgeContrast > 0.7)
    #expect(uniforms.paletteBackground.w == profile.backgroundAlpha)
    #expect(
        uniforms.compositing == SIMD4<Float>(
            profile.particleScale,
            profile.particlePresence,
            profile.bloomStrength,
            profile.edgeContrast
        )
    )
}

@Test
func openRibbonTwistsWithoutIndependentParticleMotion() {
    let uniforms = StageUniforms.make(
        camera: StageCameraModel().frame,
        audio: .silent,
        time: 0,
        viewport: SIMD2<Float>(1180, 760),
        presetWeights: SIMD3<Float>(0, 0, 1)
    )

    #expect(uniforms.topologyMotion.x == 0.34)
    #expect(uniforms.topologyMotion.y == 0)
    #expect(uniforms.topologyMotion.z == 0)
}

@Test
func stageRhythmRespondsImmediatelyAndDecaysBetweenAudioFrames() {
    var response = StageRhythmResponse()
    let hit = VisualAudioFeatures(
        low: 0.8,
        mid: 0.4,
        high: 0.2,
        beat: 1,
        onset: 0.9,
        amplitude: 0.7,
        waveform: SIMD8<Float>(repeating: 1)
    )

    let attack = response.update(audio: hit, deltaTime: 1 / 60)
    let release = response.update(audio: .silent, deltaTime: 1 / 60)

    #expect(attack.beat > 0.95)
    #expect(attack.onset > 0.85)
    #expect(release.beat > 0.75)
    #expect(release.beat < attack.beat)
    #expect(release.waveform[0] > 0.7)
}
