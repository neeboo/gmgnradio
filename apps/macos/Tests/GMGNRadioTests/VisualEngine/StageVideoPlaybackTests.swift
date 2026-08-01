import Foundation
import Testing
@testable import GMGNRadio

@Test
func stageVideoPlaybackModesExposeTheThreeMVBehaviors() {
    #expect(StageVideoPlaybackMode.allCases.map(\.displayName) == [
        "单次",
        "循环",
        "随机拼接",
    ])
}

@Test
func stageVideoSequencePlannerStopsLoopsOrAvoidsImmediateRepeats() {
    #expect(
        StageVideoSequencePlanner.nextIndex(
            mode: .once,
            currentIndex: 1,
            count: 3,
            randomUnit: 0.4
        ) == nil
    )
    #expect(
        StageVideoSequencePlanner.nextIndex(
            mode: .loop,
            currentIndex: 1,
            count: 3,
            randomUnit: 0.4
        ) == 1
    )
    #expect(
        StageVideoSequencePlanner.nextIndex(
            mode: .randomSequence,
            currentIndex: 1,
            count: 3,
            randomUnit: 0
        ) == 0
    )
    #expect(
        StageVideoSequencePlanner.nextIndex(
            mode: .randomSequence,
            currentIndex: 1,
            count: 3,
            randomUnit: 0.99
        ) == 2
    )
}

@Test
func stageVideoProgramDirectorRanksClipsForTheCurrentProgramCue() {
    let assets = [
        StageVideoAsset(
            url: URL(fileURLWithPath: "/tmp/neon-city.mp4")
        ),
        StageVideoAsset(
            url: URL(fileURLWithPath: "/tmp/cozy-wood-cafe.mp4")
        ),
        StageVideoAsset(
            url: URL(fileURLWithPath: "/tmp/ocean-rain.mp4")
        ),
    ]
    let cue = ProgramVisualDirector().cue(
        for: .peak,
        mood: .pulse
    )

    let ranked = StageVideoProgramDirector().rankedAssets(
        assets,
        for: cue
    )

    #expect(ranked.first?.displayName == "neon-city")
    #expect(Set(ranked.map(\.id)) == Set(assets.map(\.id)))
}

@Test
@MainActor
func stageVideoPreferencesPersistTheSelectedPlaybackMode() throws {
    let suiteName = "stage-video-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = StageVideoPlaybackStore(defaults: defaults)
    first.setMode(.randomSequence)

    let restored = StageVideoPlaybackStore(defaults: defaults)
    #expect(restored.mode == .randomSequence)
}

@Test
@MainActor
func stageVideoBrightnessIsClampedAndPersists() throws {
    let suiteName = "stage-video-brightness-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = StageVideoPlaybackStore(defaults: defaults)
    first.setBrightness(0.42)
    #expect(abs(first.brightness - 0.42) < 0.000_1)

    let restored = StageVideoPlaybackStore(defaults: defaults)
    #expect(abs(restored.brightness - 0.42) < 0.000_1)

    restored.setBrightness(2)
    #expect(restored.brightness == 1)
    restored.setBrightness(-1)
    #expect(restored.brightness == 0.15)
}

@Test
@MainActor
func individualMP4CanBeLoadedUnloadedAndRemoved() throws {
    let suiteName = "stage-video-assets-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstURL = URL(fileURLWithPath: "/tmp/gmgn-first.mp4")
    let secondURL = URL(fileURLWithPath: "/tmp/gmgn-second.mp4")
    let firstID = StageVideoAsset(url: firstURL).id
    let secondID = StageVideoAsset(url: secondURL).id
    let store = StageVideoPlaybackStore(defaults: defaults)

    store.add([firstURL, secondURL])
    #expect(store.isActive)
    #expect(store.activeAssetID == firstID)

    store.toggle(firstID)
    #expect(!store.isActive)
    #expect(store.selectedAssetID == firstID)

    store.toggle(secondID)
    #expect(store.isActive)
    #expect(store.activeAssetID == secondID)

    store.remove(secondID)
    #expect(!store.assets.contains(where: { $0.id == secondID }))
    #expect(store.selectedAssetID == firstID)
}

@Test
@MainActor
func trackChangeRespectsTheLatestUserMVChoice() throws {
    let suiteName = "stage-video-user-choice-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asset = StageVideoAsset(
        url: URL(fileURLWithPath: "/tmp/gmgn-background.mp4")
    )
    let store = StageVideoPlaybackStore(defaults: defaults)
    let cue = ProgramVisualDirector().cue(for: .build)

    store.add([asset.url])
    store.disableByUser()
    store.apply(cue, trackID: "next-track", trackTitle: "下一首")

    #expect(!store.isUserEnabled)
    #expect(!store.isActive)
    #expect(store.pendingBoundVideo == nil)
}

@Test
@MainActor
func boundVideoAsksBeforeTemporarilyPlayingWhenMVIsDisabled() throws {
    let suiteName = "stage-video-binding-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asset = StageVideoAsset(
        url: URL(fileURLWithPath: "/tmp/gmgn-bound.mp4")
    )
    let store = StageVideoPlaybackStore(defaults: defaults)
    let cue = ProgramVisualDirector().cue(for: .peak)

    store.add([asset.url])
    store.bind(asset.id, to: "bound-track")
    store.disableByUser()
    store.apply(
        cue,
        trackID: "bound-track",
        trackTitle: "绑定歌曲"
    )

    #expect(!store.isActive)
    #expect(store.pendingBoundVideo?.asset.id == asset.id)

    store.playPendingBoundVideo()
    #expect(store.isActive)
    #expect(!store.isUserEnabled)

    store.apply(cue, trackID: "unbound-track", trackTitle: "下一首")
    #expect(!store.isActive)
}
