import Testing
@testable import GMGNRadio

@MainActor
@Test
func musicAccountsModelUsesOfficialWebLoginBeforeSavingTheAccount() async {
    let service = MusicAccountServiceSpy()
    let webLogin = MusicProviderWebLoginStub(
        cookie: "MUSIC_U=official-session"
    )
    let model = MusicAccountsModel(
        service: service,
        webLogin: webLogin
    )

    await model.connect(.netease)

    #expect(webLogin.requestedProvider == .netease)
    #expect(service.connectedProvider == .netease)
    #expect(service.connectedCookie == "MUSIC_U=official-session")
    #expect(model.neteaseState == .connected)
}

@MainActor
private final class MusicProviderWebLoginStub: MusicProviderWebAuthenticating {
    let cookie: String
    var requestedProvider: MusicProviderID?

    init(cookie: String) {
        self.cookie = cookie
    }

    func login(providerID: MusicProviderID) async throws -> String {
        requestedProvider = providerID
        return cookie
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
