import Foundation

enum MarbleWorldClientError: LocalizedError, Equatable {
    case missingAPIKey
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "尚未配置 Marble API Key。"
        case let .generationFailed(message):
            "Marble 空间生成失败：\(message)"
        }
    }
}

struct MarbleAPIKeyProvider: Sendable {
    static let defaultFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent("ai.gmgn.radio/secrets")
        .appendingPathComponent("world-labs-api-key")

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    var isConfigured: Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    func read() throws -> String {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            throw MarbleWorldClientError.missingAPIKey
        }
        return value
    }

    func save(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MarbleWorldClientError.missingAPIKey
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try Data(value.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

actor MarbleWorldClient {
    /// A native transport observation. Rust alone interprets provider JSON,
    /// status codes, operation progress and retry eligibility.
    struct HTTPFact: Sendable {
        let statusCode: Int?
        let body: Data?
        let transportErrorCode: String?
    }
    private let baseURL: URL
    private let session: URLSession
    private let apiKeyProvider: MarbleAPIKeyProvider
    private let suppliedAPIKey: String?

    init(
        baseURL: URL = URL(string: "https://api.worldlabs.ai")!,
        session: URLSession = .shared,
        apiKeyProvider: MarbleAPIKeyProvider = MarbleAPIKeyProvider(),
        suppliedAPIKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.suppliedAPIKey = suppliedAPIKey
    }

    /// Executes precisely one persisted Rust action, with no native polling or
    /// decoding. The test seam supplies an in-memory dummy key, never a user key.
    func executePlannedHTTP(method: String, path: String, body: Data?) async -> HTTPFact {
        guard ["GET", "POST"].contains(method),path.hasPrefix("/marble/v1/"),
              !path.contains(".."),!path.contains("?"),!path.contains("#"),
              var components = URLComponents(url:baseURL,resolvingAgainstBaseURL:false) else {
            return HTTPFact(statusCode:nil,body:nil,transportErrorCode:"invalid_plan")
        }
        components.path = path
        guard let url=components.url else {return HTTPFact(statusCode:nil,body:nil,transportErrorCode:"invalid_plan")}
        var request=URLRequest(url:url)
        request.httpMethod=method;request.httpBody=body
        if body != nil {request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        do {try authorize(&request)}
        catch {return HTTPFact(statusCode:nil,body:nil,transportErrorCode:"missing_api_key")}
        do {
            let (data,response)=try await session.data(for:request)
            if let key = request.value(forHTTPHeaderField: "WLT-Api-Key"),
               !key.isEmpty, data.range(of: Data(key.utf8)) != nil {
                return HTTPFact(statusCode:nil,body:nil,transportErrorCode:"credential_echo")
            }
            guard let response=response as? HTTPURLResponse else {
                return HTTPFact(statusCode:nil,body:data,transportErrorCode:"invalid_response")
            }
            return HTTPFact(statusCode:response.statusCode,body:data,transportErrorCode:nil)
        } catch {
            let code=(error as NSError).code
            return HTTPFact(statusCode:nil,body:nil,transportErrorCode:
                code == NSURLErrorCancelled ? "cancelled" : code == NSURLErrorTimedOut ? "timeout" : "transport_error")
        }
    }

    private func authorize(_ request: inout URLRequest) throws {
        request.setValue(
            try suppliedAPIKey ?? apiKeyProvider.read(),
            forHTTPHeaderField: "WLT-Api-Key"
        )
    }

}
