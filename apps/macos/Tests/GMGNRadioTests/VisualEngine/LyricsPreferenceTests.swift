import Foundation
import Testing
@testable import GMGNRadio

@Suite("Lyrics preferences") @MainActor
struct LyricsPreferenceTests {
@Test @MainActor
func explicitLyricStyleSurvivesTrackChangeClearAndRecreation() throws {
    let suite = "gmgn.tests.lyrics." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = StageLyricsStore(defaults: defaults)
    #expect(store.visualMode == .automatic)
    store.setVisualMode(.posterRail)
    store.publish(MusicLyrics(original: "[00:00.00]第一首", translation: nil), trackID: "one")
    store.clear()
    store.publish(MusicLyrics(original: "[00:00.00]第二首", translation: nil), trackID: "two")
    #expect(store.visualMode == .posterRail)
    #expect(StageLyricsStore(defaults: defaults).visualMode == .posterRail)
    #expect(StageLyricModeDirector.resolve(configuredMode: store.visualMode,
        trackID: "different-track", lines: store.lines, playbackTime: 30) == .posterRail)
}

@Test @MainActor
func automaticIsPersistedOnlyAfterExplicitSelection() throws {
    let suite = "gmgn.tests.lyrics." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = StageLyricsStore(defaults: defaults)
    store.setVisualMode(.foldingVerse)
    store.setVisualMode(.automatic)
    #expect(defaults.string(forKey: StageLyricsStore.visualModePreferenceKey) == "automatic")
    #expect(StageLyricsStore(defaults: defaults).visualMode == .automatic)
}

@Test @MainActor
func invalidStoredModeDefaultsWithoutOverwritingPreference() throws {
    let suite = "gmgn.tests.lyrics." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("future-style", forKey: StageLyricsStore.visualModePreferenceKey)
    #expect(StageLyricsStore(defaults: defaults).visualMode == .automatic)
    #expect(defaults.string(forKey: StageLyricsStore.visualModePreferenceKey) == "future-style")
    let unpersisted = StageLyricsStore()
    unpersisted.setVisualMode(.flowingLine)
    #expect(defaults.string(forKey: StageLyricsStore.visualModePreferenceKey) == "future-style")
}
}
