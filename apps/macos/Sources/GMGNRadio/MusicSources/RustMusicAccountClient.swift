import Foundation

/// Typed account commands; no cookies enter public settings snapshots or SQL.
actor RustMusicAccountClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Account: Decodable, Sendable {
        let providerID: String
        let revision: UInt64
        let state: MusicAccountAuthorizationState
        let overridden: Bool
        let disabled: Bool
    }
    struct SessionReply: Decodable, Sendable {
        let account: Account
        let session: MusicProviderSession?
        let useLegacy: Bool
    }
    private let call: Call
    private let hostSessionID: String
    init(applicationSupportBase: URL, hostSessionID: String = UUID().uuidString) {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: applicationSupportBase)
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpoint.endpointFile,
            helperPath: endpoint.helperPath, allowsLaunching: false, timeout: 60)
        self.call = { method, data in
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorldAuthorityError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
        self.hostSessionID = hostSessionID
    }
    init(call: @escaping Call, hostSessionID: String = UUID().uuidString) { self.call = call; self.hostSessionID = hostSessionID }
    private func request<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as: T.Type) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: params)
        let call = self.call
        let response = try await Task.detached { try call(method, data) }.value
        return try JSONDecoder().decode(T.self, from: response)
    }
    func account(_ provider: MusicProviderID) async throws -> Account {
        try await request("music_account_session_state", ["providerID": provider.rawValue], as: Account.self)
    }
    func session(_ provider: MusicProviderID) async throws -> SessionReply {
        try await request("music_account_session", ["providerID": provider.rawValue], as: SessionReply.self)
    }
    func importLegacy(_ provider: MusicProviderID, session: MusicProviderSession?, disabled: Bool) async throws -> Account {
        let raw: Any = try session.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        return try await request("music_account_import", ["providerID": provider.rawValue, "session": raw, "disabled": disabled], as: Account.self)
    }
    func connect(_ provider: MusicProviderID, cookie: String) async throws {
        struct Receipt: Decodable, Sendable { let accepted: Bool; let account: Account }
        let receipt = try await request("music_account_connect", ["providerID": provider.rawValue, "cookie": cookie,
            "hostSessionID": hostSessionID, "requestID": UUID().uuidString], as: Receipt.self)
        guard receipt.accepted else { throw MusicAccountConnectionError.accountCannotPlay }
    }
    func disconnect(_ provider: MusicProviderID) async throws -> Account {
        let current = try await account(provider)
        return try await request("music_account_disconnect", ["providerID": provider.rawValue,
            "hostSessionID": hostSessionID, "requestID": UUID().uuidString,
            "expectedRevision": current.revision], as: Account.self)
    }
    func appleAuthorization(authorization: String, hasPlayableSubscription: Bool?, reconnect: Bool) async throws -> Account {
        let current = try await account(.appleMusic)
        return try await request("music_account_apple_authorization", ["providerID": MusicProviderID.appleMusic.rawValue,
            "hostSessionID": hostSessionID, "requestID": UUID().uuidString, "expectedRevision": current.revision,
            "authorization": authorization, "hasPlayableSubscription": hasPlayableSubscription as Any? ?? NSNull(),
            "reconnect": reconnect], as: Account.self)
    }
}
