import Foundation
import Testing
@testable import GMGNRadio

private final class LyricsLostReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func consume(_ method: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed, method == "product_settings_stage_event" else { return false }
        armed = false
        return true
    }
}

@Suite("Lyrics preferences") @MainActor
struct LyricsPreferenceTests {
@Test @MainActor
func explicitLyricStyleSurvivesTrackChangeClearAndRecreation() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let suite = "gmgn.tests.lyrics." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = StageLyricsStore(defaults: defaults, settings: RustProductSettingsClient(root: fixture.root))
    try await store.waitForAuthority()
    #expect(store.visualMode == .automatic)
    try await store.setVisualMode(.posterRail)
    store.publish(MusicLyrics(original: "[00:00.00]第一首", translation: nil), trackID: "one")
    store.clear()
    store.publish(MusicLyrics(original: "[00:00.00]第二首", translation: nil), trackID: "two")
    try await store.waitForAuthority()
    #expect(store.visualMode == .posterRail)
    let recreated = StageLyricsStore(defaults: defaults, settings: RustProductSettingsClient(root: fixture.root))
    try await recreated.waitForAuthority()
    #expect(recreated.visualMode == .posterRail)
    store.publish(MusicLyrics(original: "[00:00.00]另一首", translation: nil), trackID: "different-track")
    try await store.waitForAuthority()
    #expect(store.resolvedVisualMode == .posterRail)
}

@Test @MainActor
func automaticIsPersistedOnlyAfterExplicitSelection() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let suite = "gmgn.tests.lyrics." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = RustProductSettingsClient(root: fixture.root)
    let store = StageLyricsStore(defaults: defaults, settings: settings)
    try await store.waitForAuthority()
    try await store.setVisualMode(.foldingVerse)
    try await store.setVisualMode(.automatic)
    #expect(settings.confirmed?.values.stageLyricsMode == "automatic")
    #expect(defaults.string(forKey: StageLyricsStore.visualModePreferenceKey) == nil)
    let recreated = StageLyricsStore(defaults: defaults, settings: RustProductSettingsClient(root: fixture.root))
    try await recreated.waitForAuthority()
    #expect(recreated.visualMode == .automatic)
}

@Test @MainActor
func invalidStoredModeDefaultsWithoutOverwritingPreference() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let suite = "gmgn.tests.lyrics." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("future-style", forKey: StageLyricsStore.visualModePreferenceKey)
    let store = StageLyricsStore(defaults: defaults, settings: RustProductSettingsClient(root: fixture.root))
    try await store.waitForAuthority()
    #expect(store.visualMode == .automatic)
    #expect(defaults.string(forKey: StageLyricsStore.visualModePreferenceKey) == "future-style")
    let unpersisted = StageLyricsStore()
    await #expect(throws: RustProductSettingsClient.SettingsError.self) {
        try await unpersisted.setVisualMode(.flowingLine)
    }
    #expect(unpersisted.visualMode == .automatic)
    #expect(defaults.string(forKey: StageLyricsStore.visualModePreferenceKey) == "future-style")
}

@Test @MainActor
func lostModeReceiptDoesNotPublishUnconfirmedSelection() async throws {
    let fixture = try await PrivateMusicAuthorityFixture.start()
    defer { withExtendedLifetime(fixture) {} }
    let transport = TaskdHTTPAuthorityClient(
        endpointFile: fixture.root.appendingPathComponent("taskd.endpoint.json").path,
        helperPath: "/private/never-launch", allowsLaunching: false, timeout: 5)
    let loss = LyricsLostReceipt()
    let settings = RustProductSettingsClient(call: { method, data in
        let params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try transport.call(method: method, params: params)
        if loss.consume(method) { throw RustProductSettingsClient.SettingsError.unavailable }
        return try JSONSerialization.data(withJSONObject: result)
    })
    let store = StageLyricsStore(settings: settings)
    try await store.waitForAuthority()
    try await store.setVisualMode(.posterRail)
    loss.arm()
    await #expect(throws: RustProductSettingsClient.SettingsError.self) {
        try await store.setVisualMode(.foldingVerse)
    }
    #expect(store.visualMode == .posterRail)
    #expect(store.authorityError != nil)
    let restored = StageLyricsStore(settings: RustProductSettingsClient(root: fixture.root))
    try await restored.waitForAuthority()
    #expect(restored.visualMode == .foldingVerse)
}
}
