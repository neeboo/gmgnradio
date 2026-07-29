import Foundation

struct MusicProviderHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol MusicProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse
}

struct URLSessionMusicProviderHTTPTransport: MusicProviderHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MusicProviderClientError.invalidResponse
        }
        return MusicProviderHTTPResponse(
            data: data,
            statusCode: response.statusCode
        )
    }
}

struct MusicPlaybackAsset: Equatable, Sendable {
    let url: URL
    let requestHeaders: [String: String]
}

enum MusicProviderClientError: Error, Equatable, LocalizedError {
    case invalidCredential
    case invalidResponse
    case httpStatus(Int)
    case accountUnavailable
    case playbackUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "音乐账号登录信息无效。"
        case .invalidResponse:
            "音乐服务返回了无法识别的数据。"
        case let .httpStatus(code):
            "音乐服务请求失败（\(code)）。"
        case .accountUnavailable:
            "暂时无法读取这个音乐账号。"
        case .playbackUnavailable:
            "当前账号没有这首歌的播放权限。"
        }
    }
}

extension MusicProviderSession {
    func cookieHeader() throws -> String {
        guard case let .cookieHeader(value) = credential else {
            throw MusicProviderClientError.invalidCredential
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MusicProviderClientError.invalidCredential
        }
        return trimmed
    }
}

func checkedProviderResponse(
    _ response: MusicProviderHTTPResponse
) throws -> Data {
    guard (200 ... 299).contains(response.statusCode) else {
        throw MusicProviderClientError.httpStatus(response.statusCode)
    }
    return response.data
}
