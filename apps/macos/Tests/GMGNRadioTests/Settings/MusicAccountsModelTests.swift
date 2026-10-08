import Foundation
import Testing
@testable import GMGNRadio

@MainActor
@Test
func musicAccountsModelUsesOfficialWebLoginBeforeSavingTheAccount() async {
    let rpc = MusicSettingsFixture(), settings = RustProductSettingsClient(call: { try rpc.call($0, $1) })
    let service = MusicAccountServiceSpy()
    let webLogin = MusicProviderWebLoginStub(
        cookie: "MUSIC_U=official-session"
    )
    let model = MusicAccountsModel(
        service: service,
        webLogin: webLogin,
        defaults: UserDefaults(suiteName: "music-settings-fixture-\(UUID())")!, settings: settings
    )

    await model.connect(.netease)

    #expect(webLogin.requestedProvider == .netease)
    #expect(service.connectedProvider == .netease)
    #expect(service.connectedCookie == "MUSIC_U=official-session")
    #expect(model.neteaseState == .connected)
    #expect(!model.isWorking)
    #expect(model.syncingProviders.contains(.netease))
    #expect(settings.confirmed?.values.musicConnectedProviders == ["netease"])
    #expect(rpc.receipts == 1)
    model.handleSyncCompletion(Notification(name: .musicLibrarySyncDidFinish,
        userInfo: ["providerID": MusicProviderID.netease.rawValue, "errorDescription": "test sync failure"]))
    #expect(model.neteaseState == .connected)
    #expect(!model.isWorking && model.syncingProviders.isEmpty)
    #expect(model.hasError)
}

@MainActor
@Test
func musicAccountsModelClearsStaleWebSessionBeforeReconnect() async {
    let rpc = MusicSettingsFixture(), settings = RustProductSettingsClient(call: { try rpc.call($0, $1) })
    let service = MusicAccountServiceSpy()
    let webLogin = MusicProviderWebLoginStub(
        cookie: "MUSIC_U=fresh-session"
    )
    let model = MusicAccountsModel(
        service: service,
        webLogin: webLogin,
        defaults: UserDefaults(suiteName: "music-settings-fixture-\(UUID())")!, settings: settings
    )

    await model.connect(.netease)

    #expect(
        webLogin.events == [
            .clear(.netease),
            .login(.netease),
        ]
    )
}

private final class MusicSettingsFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    private var providers = [String]()
    private var count = 0
    var receipts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func call(_ method: String, _ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let p = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if method == "product_settings_music_receipt" {
            #expect(p["expectedRevision"] as? Int == revision)
            #expect(p["cookie"] == nil)
            let provider = p["providerID"] as! String
            if p["connected"] as! Bool { providers.append(provider) } else { providers.removeAll { $0 == provider } }
            revision += 1; count += 1
        }
        return try JSONSerialization.data(withJSONObject: ["revision": revision, "imported": true, "values": [
            "locale":"zh-CN", "residentPersona":"fixture", "backgroundTurnsPerHour":0,
            "autoSpeak":false, "autonomyEnabled":false, "agentBackend":"dsh", "selectedWorldID":NSNull(), "defaultSpace":"living-pod",
            "djHostPrompt":"", "djTakeover":false, "djPlanningModel":NSNull(),
            "ttsProvider":"bailian", "ttsModel":"fixture", "ttsVoice":"Cherry", "asrProvider":"bailian", "asrModel":"fixture", "microphoneDeviceID":NSNull(),
            "orbRed":0.16, "orbGreen":0.62, "orbBlue":1.0, "orbFlowIntensity":0.82,
            "remoteMotionCatalogURL":"https://192.168.1.85:8765/catalog.json", "shortcutAssignments":[], "globalShortcutsEnabled":true, "mediaKeysEnabled":true,
            "musicConnectedProviders":providers]])
    }
}

private enum MusicProviderWebLoginEvent: Equatable {
    case clear(MusicProviderID)
    case login(MusicProviderID)
}

@MainActor
private final class MusicProviderWebLoginStub: MusicProviderWebAuthenticating {
    let cookie: String
    var requestedProvider: MusicProviderID?
    var events: [MusicProviderWebLoginEvent] = []

    init(cookie: String) {
        self.cookie = cookie
    }

    func login(providerID: MusicProviderID) async throws -> String {
        requestedProvider = providerID
        events.append(.login(providerID))
        return cookie
    }

    func clearSession(providerID: MusicProviderID) async {
        events.append(.clear(providerID))
    }
}

@MainActor
private final class MusicAccountServiceSpy: MusicAccountServicing {
    var connectedProvider: MusicProviderID?
    var connectedCookie: String?

    func status(
        providerID: MusicProviderID
    ) async -> MusicAccountAuthorizationState {
        .disconnected
    }

    func connect(
        providerID: MusicProviderID,
        cookie: String
    ) async throws {
        connectedProvider = providerID
        connectedCookie = cookie
    }

    func disconnect(providerID: MusicProviderID) async throws {}
}
