import Foundation
@testable import GMGNRadio

actor ProviderHTTPTransportStub: MusicProviderHTTPTransport {
    private var responses: [MusicProviderHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [MusicProviderHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return responses.removeFirst()
    }
}

func providerResponse(
    _ json: String,
    statusCode: Int = 200
) -> MusicProviderHTTPResponse {
    MusicProviderHTTPResponse(
        data: Data(json.utf8),
        statusCode: statusCode
    )
}

func providerSession(_ cookie: String) -> MusicProviderSession {
    MusicProviderSession(
        credential: .cookieHeader(cookie),
        expiresAt: nil
    )
}
