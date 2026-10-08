import Foundation

enum MusicAccountConnectionError: Error, Equatable, LocalizedError {
    case unsupportedProvider
    case missingRequiredCookie
    case accountCannotPlay

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "这个音乐服务暂时不能网页登录。"
        case .missingRequiredCookie:
            "官方登录信息不完整，请重新登录。"
        case .accountCannotPlay:
            "账号已识别，但当前登录态不能播放音乐。"
        }
    }
}

@MainActor
protocol MusicAccountServicing {
    func status(
        providerID: MusicProviderID
    ) async -> MusicAccountAuthorizationState

    func connect(
        providerID: MusicProviderID,
        cookie: String
    ) async throws

    func disconnect(providerID: MusicProviderID) async throws
}

struct MusicAccountCommandService: Sendable {
    private let authority: RustMusicAccountClient
    private let sessions: any MusicProviderSessionStore
    init(authority: RustMusicAccountClient, sessions: any MusicProviderSessionStore) {
        self.authority = authority; self.sessions = sessions
    }
    static func live() -> MusicAccountCommandService {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ai.gmgn.radio")
        let authority = RustMusicAccountClient(applicationSupportBase: root)
        return MusicAccountCommandService(authority: authority,
            sessions: RustMusicProviderSessionStore(authority: authority,
                legacyDirectory: root.appendingPathComponent("secrets/music-sessions")))
    }
    func status(providerID: MusicProviderID) async -> MusicAccountAuthorizationState {
        do {
            _ = try await sessions.session(for: providerID)
            return try await authority.account(providerID).state
        } catch { return .unavailable }
    }
    func connect(providerID: MusicProviderID, cookie: String) async throws {
        try await authority.connect(providerID, cookie: cookie)
    }
    func disconnect(providerID: MusicProviderID) async throws {
        _ = try await authority.disconnect(providerID)
    }
}
extension MusicAccountCommandService: MusicAccountServicing {}
