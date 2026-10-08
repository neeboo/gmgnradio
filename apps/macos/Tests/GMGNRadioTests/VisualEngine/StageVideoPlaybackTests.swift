import Foundation
import Testing
@testable import GMGNRadio

@MainActor
private func stageVideoTestClient(_ fixture: PrivateMusicAuthorityFixture, scope: String = "stage-video-test") throws -> RustStageVideoClient {
    let binary = try #require(ProcessInfo.processInfo.environment["GMGN_TASKD_TEST_BINARY"] ?? ProcessInfo.processInfo.environment["TASKD_BIN"])
    return RustStageVideoClient(endpointFile: fixture.root.appendingPathComponent("taskd.endpoint.json").path,
        helperPath: binary, allowsLaunching: false, scope: scope, hostSessionID: UUID().uuidString)
}

// Receipt acceptance is a controlled native boundary fact; all selection,
// queue planning, claiming and confirmation still execute in the real daemon.
private func settleStageVideo(_ client: RustStageVideoClient, _ snapshot: RustStageVideoClient.Snapshot) async throws -> RustStageVideoClient.Snapshot {
    guard let action = snapshot.state.pendingAction else { return snapshot }
    #expect(action.executionStatus == "planned")
    let claimed = try await client.claim(action)
    let confirmedAction = try #require(claimed.state.pendingAction)
    #expect(confirmedAction.actionID == action.actionID)
    #expect(confirmedAction.executionStatus == "claimed")
    let result = try await client.receipt(confirmedAction, accepted: true)
    #expect(result.state.pendingAction == nil)
    return result
}

@MainActor
private func confirmStageVideoStore(_ store: StageVideoPlaybackStore) async {
    await store.waitForAuthority()
    #expect(store.authorityError == nil)
}

@Test
func stageVideoPlaybackModesExposeTheThreeMVBehaviors() {
    #expect(StageVideoPlaybackMode.allCases.map(\.displayName) == [
        "单次",
        "循环",
        "随机拼接",
    ])
}

@Test
@MainActor
func stageVideoSequencePlannerStopsLoopsOrAvoidsImmediateRepeats() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let assets = (0..<3).map { StageVideoAsset(url: fixture.root.appendingPathComponent("sequence-\($0).mp4")) }
    for mode in [StageVideoPlaybackMode.once, .loop, .randomSequence] {
        let client = try stageVideoTestClient(fixture, scope: mode.rawValue)
        _ = try await client.read()
        _ = try await client.importLegacy(.init(assets: assets, bindings: [:], selectedAssetID: assets[1].id, enabled: true, mode: mode.rawValue, brightness: nil))
        var current = try await settleStageVideo(client, client.command(.init(op: "start")))
        #expect(current.state.playback.queue.first?.assetID == assets[1].id)
        let head = try #require(current.state.playback.queue.first)
        let ended = try await client.command(.init(op: "ended", generation: current.state.playback.generation, entryID: head.entryID))
        current = try await settleStageVideo(client, ended)
        switch mode {
        case .once:
            #expect(current.state.playback.queue.isEmpty)
            #expect(!current.state.playback.active)
        case .loop:
            #expect(current.state.playback.queue.first?.assetID == assets[1].id)
            #expect(current.state.playback.active)
        case .randomSequence:
            let next = try #require(current.state.playback.queue.first)
            #expect(next.assetID == assets[0].id || next.assetID == assets[2].id)
            #expect(next.assetID != assets[1].id)
            // Actual service randomness must preserve the invariant on every
            // queue transition; no client randomUnit or sequence reducer exists.
            for _ in 0..<32 {
                let queue = current.state.playback.queue
                #expect(queue.count == 2)
                #expect(queue[0].assetID != queue[1].assetID)
                #expect(queue[0].entryID != queue[1].entryID)
                let receipt = try await client.command(.init(op: "ended", generation: current.state.playback.generation, entryID: queue[0].entryID))
                current = try await settleStageVideo(client, receipt)
            }
        }
    }
}

@Test
@MainActor
func stageVideoProgramDirectorRanksClipsForTheCurrentProgramCue() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
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

    let client = try stageVideoTestClient(fixture)
    _ = try await client.read()
    _ = try await client.importLegacy(.init(assets: assets, bindings: [:], selectedAssetID: nil, enabled: false, mode: nil, brightness: nil))
    let result = try await client.command(.init(op: "cue", mood: cue.mood.rawValue, role: cue.role.rawValue))
    let ranked = result.state.rankedIDs.compactMap { id in assets.first { $0.id == id } }

    #expect(ranked.first?.displayName == "neon-city")
    #expect(Set(ranked.map(\.id)) == Set(assets.map(\.id)))
}

@Test
@MainActor
func stageVideoPreferencesPersistTheSelectedPlaybackMode() async throws {
    let suiteName = "stage-video-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let first = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(first)
    first.setMode(.randomSequence)
    await confirmStageVideoStore(first)

    let restored = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(restored)
    #expect(restored.mode == .randomSequence)
}

@Test
@MainActor
func stageVideoBrightnessIsClampedAndPersists() async throws {
    let suiteName = "stage-video-brightness-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let first = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(first)
    first.setBrightness(0.42)
    await confirmStageVideoStore(first)
    #expect(abs(first.brightness - 0.42) < 0.000_1)

    let restored = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(restored)
    #expect(abs(restored.brightness - 0.42) < 0.000_1)

    restored.setBrightness(2)
    await confirmStageVideoStore(restored)
    #expect(restored.brightness == 1)
    restored.setBrightness(-1)
    await confirmStageVideoStore(restored)
    #expect(restored.brightness == 0.15)
}

@Test
@MainActor
func individualMP4CanBeLoadedUnloadedAndRemoved() async throws {
    let suiteName = "stage-video-assets-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstURL = URL(fileURLWithPath: "/tmp/gmgn-first.mp4")
    let secondURL = URL(fileURLWithPath: "/tmp/gmgn-second.mp4")
    let firstID = StageVideoAsset(url: firstURL).id
    let secondID = StageVideoAsset(url: secondURL).id
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let store = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(store)

    store.add([firstURL, secondURL])
    await confirmStageVideoStore(store)
    #expect(store.isActive)
    #expect(store.activeAssetID == firstID)

    store.toggle(firstID)
    await confirmStageVideoStore(store)
    #expect(!store.isActive)
    #expect(store.selectedAssetID == firstID)

    store.toggle(secondID)
    await confirmStageVideoStore(store)
    #expect(store.isActive)
    #expect(store.activeAssetID == secondID)

    store.remove(secondID)
    await confirmStageVideoStore(store)
    #expect(!store.assets.contains(where: { $0.id == secondID }))
    #expect(store.selectedAssetID == firstID)
}

@Test
@MainActor
func trackChangeRespectsTheLatestUserMVChoice() async throws {
    let suiteName = "stage-video-user-choice-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asset = StageVideoAsset(
        url: URL(fileURLWithPath: "/tmp/gmgn-background.mp4")
    )
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let store = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(store)
    let cue = ProgramVisualDirector().cue(for: .build)

    store.add([asset.url])
    await confirmStageVideoStore(store)
    store.disableByUser()
    await confirmStageVideoStore(store)
    store.apply(cue, trackID: "next-track", trackTitle: "下一首")
    await confirmStageVideoStore(store)

    #expect(!store.isUserEnabled)
    #expect(!store.isActive)
    #expect(store.pendingBoundVideo == nil)
}

@Test
@MainActor
func boundVideoAsksBeforeTemporarilyPlayingWhenMVIsDisabled() async throws {
    let suiteName = "stage-video-binding-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asset = StageVideoAsset(
        url: URL(fileURLWithPath: "/tmp/gmgn-bound.mp4")
    )
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let store = StageVideoPlaybackStore(defaults: defaults, authority: try stageVideoTestClient(fixture), execute: { _, _ in true })
    await confirmStageVideoStore(store)
    let cue = ProgramVisualDirector().cue(for: .peak)

    store.add([asset.url])
    await confirmStageVideoStore(store)
    store.bind(asset.id, to: "bound-track")
    await confirmStageVideoStore(store)
    store.disableByUser()
    await confirmStageVideoStore(store)
    store.apply(
        cue,
        trackID: "bound-track",
        trackTitle: "绑定歌曲"
    )
    await confirmStageVideoStore(store)

    #expect(!store.isActive)
    #expect(store.pendingBoundVideo?.asset.id == asset.id)

    store.playPendingBoundVideo()
    await confirmStageVideoStore(store)
    #expect(store.isActive)
    #expect(!store.isUserEnabled)

    store.apply(cue, trackID: "unbound-track", trackTitle: "下一首")
    await confirmStageVideoStore(store)
    #expect(!store.isActive)
}
