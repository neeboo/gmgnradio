import Foundation
import Testing
@testable import GMGNRadio

@Test
func visualPresetTimelineHoldsThenCrossfadesToTheNextPreset() {
    let timeline = StageVisualPresetTimeline(
        presetDuration: 20,
        transitionDuration: 4
    )

    let held = timeline.sample(at: 12)
    #expect(held.weights == SIMD3<Float>(1, 0, 0))

    let blending = timeline.sample(at: 17)
    #expect(blending.weights == SIMD3<Float>(0.75, 0.25, 0))

    let advanced = timeline.sample(at: 20)
    #expect(advanced.weights == SIMD3<Float>(0, 1, 0))
}

@Test
func visualPresetTimelineWrapsAcrossTheLastPreset() {
    let timeline = StageVisualPresetTimeline(
        presetDuration: 20,
        transitionDuration: 4
    )

    let blending = timeline.sample(at: 59)

    #expect(blending.weights == SIMD3<Float>(0.75, 0, 0.25))
    #expect(abs(blending.weights.x + blending.weights.y + blending.weights.z - 1) < 0.000_1)
}

@Test
func visualPresetTimelineAddsASecondCompositionForEveryTopology() {
    let timeline = StageVisualPresetTimeline(
        presetDuration: 20,
        transitionDuration: 4
    )

    let foldedCanvas = timeline.sample(at: 60)
    let helixShell = timeline.sample(at: 80)
    let constellationRibbon = timeline.sample(at: 100)

    #expect(foldedCanvas.weights == SIMD3<Float>(1, 0, 0))
    #expect(helixShell.weights == SIMD3<Float>(0, 1, 0))
    #expect(constellationRibbon.weights == SIMD3<Float>(0, 0, 1))
    #expect(foldedCanvas.composition == 1)
    #expect(helixShell.composition == 1)
    #expect(constellationRibbon.composition == 1)
}

@Test
func DJVisualMoodsMapToDistinctStagePresets() {
    #expect(
        StageVisualPresetFrame.forMood(.afterglow).weights
            == SIMD3<Float>(1, 0, 0)
    )
    #expect(
        StageVisualPresetFrame.forMood(.liquid).weights
            == SIMD3<Float>(0, 1, 0)
    )
    #expect(
        StageVisualPresetFrame.forMood(.pulse).weights
            == SIMD3<Float>(0, 0, 1)
    )
    #expect(
        StageVisualPresetFrame.forMood(.pulse).dominantTopology
            == .openRibbon
    )
}

@Test
func orbitalShellUsesASculpturalBlendInsteadOfAPureSphere() {
    let directed = StageVisualPresetFrame.forMood(.liquid)
    let automatic = StageVisualPresetTimeline(
        presetDuration: 20,
        transitionDuration: 4
    ).sample(at: 20)

    #expect((0.1 ... 0.4).contains(directed.composition))
    #expect((0.1 ... 0.4).contains(automatic.composition))
}

@Test
func manualPointCloudChoicesResolveWithoutChangingTheLyricTheme() throws {
    let automaticFrame = StageVisualPresetFrame(
        weights: SIMD3<Float>(0.2, 0.3, 0.5),
        composition: 0.6
    )
    let automatic = StagePointCloudChoice.automatic.resolvedPresetFrame(
        automatic: automaticFrame
    )
    let albumRelief = StagePointCloudChoice.albumRelief.resolvedPresetFrame(
        automatic: automaticFrame
    )
    let galaxy = StagePointCloudChoice.galaxyField.resolvedPresetFrame(
        automatic: automaticFrame
    )
    let tunnel = StagePointCloudChoice.tunnel.resolvedPresetFrame(
        automatic: automaticFrame
    )
    let void = StagePointCloudChoice.void.resolvedPresetFrame(
        automatic: automaticFrame
    )

    #expect(automatic == automaticFrame)
    #expect(albumRelief.weights == SIMD3<Float>(1, 0, 0))
    #expect(albumRelief.composition == 2)
    #expect(StagePointCloudChoice.albumRelief.title == "封面")
    #expect(StagePointCloudChoice.albumRelief.allowsAutoOrbit == false)
    #expect(StagePointCloudChoice.albumRelief.rawValue == "vinylRecord")
    #expect(galaxy.weights == SIMD3<Float>(0, 0, 1))
    #expect(galaxy.composition == 2)
    #expect(tunnel.weights == SIMD3<Float>(0, 1, 0))
    #expect(tunnel.composition == 2)
    #expect(void.weights == .zero)
}

@Test
func pointCloudLayeringKeepsVideoScenesOpenAndPreservesCoverDetail() {
    let automatic = StagePointLayerPolicy.resolve(
        choice: .automatic,
        videoActive: true
    )
    let galaxy = StagePointLayerPolicy.resolve(
        choice: .galaxyField,
        videoActive: true
    )
    let cover = StagePointLayerPolicy.resolve(
        choice: .albumRelief,
        videoActive: true
    )
    let void = StagePointLayerPolicy.resolve(
        choice: .void,
        videoActive: true
    )

    #expect(automatic.primaryVisibility < automatic.ambientVisibility)
    #expect(galaxy.primaryVisibility < 0.2)
    #expect(galaxy.ambientVisibility >= 1)
    #expect(cover.primaryVisibility > automatic.primaryVisibility)
    #expect(cover.primaryVisibility < 0.75)
    #expect(cover.ambientVisibility < automatic.ambientVisibility)
    #expect(void.primaryVisibility == 0)
    #expect(void.ambientVisibility == 0)
}

@Test
@MainActor
func stageVisualDirectionStoreAcceptsAndClearsDJDirection() {
    let store = StageVisualDirectionStore()

    store.update(.pulse)
    #expect(store.currentMood == .pulse)

    store.update(nil)
    #expect(store.currentMood == nil)
}

@Test
@MainActor
func stageVisualDirectionStoreKeepsTheActiveProgramCue() {
    let store = StageVisualDirectionStore()
    let cue = ProgramVisualDirector().cue(
        for: .peak,
        mood: .pulse,
        intensity: 0.72
    )

    store.update(cue)

    #expect(store.currentMood == .pulse)
    #expect(store.currentIntensity == 0.72)
    #expect(store.transitionDuration == 2)
}

@Test
@MainActor
func manualPointCloudChoiceRemainsLockedWhenTheDJChangesTheSceneCue() throws {
    let suiteName = "gmgn-radio-point-cloud-lock-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = StageVisualDirectionStore(defaults: defaults)
    store.selectPointCloud(.albumRelief)

    store.update(
        ProgramVisualDirector().cue(
            for: .peak,
            mood: .pulse,
            intensity: 0.72
        )
    )

    #expect(store.currentPointCloudChoice == .albumRelief)
    #expect(store.currentMood == .pulse)
}

@Test
@MainActor
func manualPointCloudChoiceIsRestoredWithoutUsingTheKeychain() throws {
    let suiteName = "gmgn-radio-point-cloud-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let first = StageVisualDirectionStore(defaults: defaults)
    first.selectPointCloud(.galaxyField)
    let restored = StageVisualDirectionStore(defaults: defaults)

    #expect(restored.currentPointCloudChoice == .galaxyField)
}

@Test
@MainActor
func legacyVinylPreferenceRestoresAsAlbumRelief() throws {
    let suiteName = "gmgn-radio-cover-relief-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.set("vinylRecord", forKey: "stage.point-cloud-choice")

    let restored = StageVisualDirectionStore(defaults: defaults)

    #expect(restored.currentPointCloudChoice == .albumRelief)
}

@Test
@MainActor
func particleSizeFineTuneIsClampedAndRestoredLocally() throws {
    let suiteName = "gmgn-radio-particle-size-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let first = StageVisualDirectionStore(defaults: defaults)
    #expect(first.particleSizeMultiplier == 1)

    first.setParticleSizeMultiplier(1.32)
    let restored = StageVisualDirectionStore(defaults: defaults)
    #expect(abs(restored.particleSizeMultiplier - 1.32) < 0.001)

    restored.setParticleSizeMultiplier(3)
    #expect(restored.particleSizeMultiplier == 1.6)
}
