import Foundation

struct MusicProviderHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let mimeType: String?
    let responseURL: URL?

    init(
        data: Data,
        statusCode: Int,
        mimeType: String? = nil,
        responseURL: URL? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.responseURL = responseURL
    }
}

protocol MusicProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse
}

enum SecureMusicRedirectPolicy {
    static func secured(_ request: URLRequest) -> URLRequest {
        guard
            let url = request.url,
            url.scheme?.lowercased() == "http",
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            return request
        }
        components.scheme = "https"
        guard let securedURL = components.url else {
            return request
        }
        var securedRequest = request
        securedRequest.url = securedURL
        return securedRequest
    }
}

private final class SecureMusicRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(SecureMusicRedirectPolicy.secured(request))
    }
}

private enum MusicProviderURLSession {
    static let redirectDelegate = SecureMusicRedirectDelegate()
    static let shared = URLSession(
        configuration: .default,
        delegate: redirectDelegate,
        delegateQueue: nil
    )
}

struct URLSessionMusicProviderHTTPTransport: MusicProviderHTTPTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? MusicProviderURLSession.shared
    }

    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MusicProviderClientError.invalidResponse
        }
        return MusicProviderHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            mimeType: response.mimeType,
            responseURL: response.url
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
    case playbackAddressUnavailable
    case playbackUnavailable
    case invalidAudioPayload

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
        case .playbackAddressUnavailable:
            "音乐服务没有返回可用的播放地址。"
        case .playbackUnavailable:
            "当前账号没有这首歌的播放权限。"
        case .invalidAudioPayload:
            "音乐服务返回了网页内容，无法作为音频播放。"
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
