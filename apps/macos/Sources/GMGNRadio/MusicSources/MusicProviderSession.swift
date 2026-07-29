import Foundation

enum MusicProviderCredential: Codable, Equatable, Sendable {
    case cookieHeader(String)
    case bearerToken(String)
}

struct MusicProviderSession: Codable, Equatable, Sendable {
    let credential: MusicProviderCredential
    let expiresAt: Date?

    func authorizationState(
        now: Date = Date()
    ) -> MusicAccountAuthorizationState {
        guard let expiresAt else {
            return .connected
        }
        return expiresAt > now ? .connected : .expired
    }
}

protocol MusicProviderSessionStore: Sendable {
    func session(
        for providerID: MusicProviderID
    ) async throws -> MusicProviderSession?

    func save(
        _ session: MusicProviderSession,
        for providerID: MusicProviderID
    ) async throws

    func removeSession(
        for providerID: MusicProviderID
    ) async throws
}

actor InMemoryMusicProviderSessionStore: MusicProviderSessionStore {
    private var sessions: [MusicProviderID: MusicProviderSession] = [:]

    func session(
        for providerID: MusicProviderID
    ) -> MusicProviderSession? {
        sessions[providerID]
    }

    func save(
        _ session: MusicProviderSession,
        for providerID: MusicProviderID
    ) {
        sessions[providerID] = session
    }

    func removeSession(
        for providerID: MusicProviderID
    ) {
        sessions.removeValue(forKey: providerID)
    }
}
