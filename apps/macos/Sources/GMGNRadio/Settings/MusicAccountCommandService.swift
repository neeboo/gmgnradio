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
    private let sessions: any MusicProviderSessionStore
    private let neteaseClient: any AccountMusicProviderClient
    private let qqMusicClient: any AccountMusicProviderClient

    init(
        sessions: any MusicProviderSessionStore,
        neteaseClient: any AccountMusicProviderClient,
        qqMusicClient: any AccountMusicProviderClient
    ) {
        self.sessions = sessions
        self.neteaseClient = neteaseClient
        self.qqMusicClient = qqMusicClient
    }

    static func live() -> MusicAccountCommandService {
        MusicAccountCommandService(
            sessions: LocalMusicProviderSessionStore(),
            neteaseClient: NeteaseMusicProviderClient(),
            qqMusicClient: QQMusicProviderClient()
        )
    }

    func status(
        providerID: MusicProviderID
    ) async -> MusicAccountAuthorizationState {
        do {
            guard let session = try await sessions.session(for: providerID) else {
                return .disconnected
            }
            return session.authorizationState()
        } catch {
            return .unavailable
        }
    }

    func connect(
        providerID: MusicProviderID,
        cookie: String
    ) async throws {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateCookieShape(trimmed, for: providerID)
        let session = MusicProviderSession(
            credential: .cookieHeader(trimmed),
            expiresAt: nil
        )
        let client = try client(for: providerID)
        let capabilities = try await client.capabilities(session: session)
        guard capabilities.canPlay else {
            throw MusicAccountConnectionError.accountCannotPlay
        }

        _ = try await client.fetchUserLibrary(session: session)
        try await sessions.save(session, for: providerID)
    }

    func disconnect(providerID: MusicProviderID) async throws {
        try await sessions.removeSession(for: providerID)
    }

    private func client(
        for providerID: MusicProviderID
    ) throws -> any AccountMusicProviderClient {
        switch providerID {
        case .netease:
            neteaseClient
        case .qqMusic:
            qqMusicClient
        default:
            throw MusicAccountConnectionError.unsupportedProvider
        }
    }

    private func validateCookieShape(
        _ cookie: String,
        for providerID: MusicProviderID
    ) throws {
        switch providerID {
        case .netease:
            guard cookie.contains("MUSIC_U=") else {
                throw MusicAccountConnectionError.missingRequiredCookie
            }
        case .qqMusic:
            let hasUIN = cookie.contains("uin=")
                || cookie.contains("qqmusic_uin=")
                || cookie.contains("wxuin=")
                || cookie.contains("p_uin=")
            let hasKey = cookie.contains("qm_keyst=")
                || cookie.contains("qqmusic_key=")
                || cookie.contains("music_key=")
                || cookie.contains("wxskey=")
            guard hasUIN, hasKey else {
                throw MusicAccountConnectionError.missingRequiredCookie
            }
        default:
            throw MusicAccountConnectionError.unsupportedProvider
        }
    }
}

extension MusicAccountCommandService: MusicAccountServicing {}
