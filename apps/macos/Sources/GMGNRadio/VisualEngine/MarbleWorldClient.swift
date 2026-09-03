import Foundation

enum MarbleWorldClientError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case rejected(statusCode: Int, message: String)
    case generationFailed(String)
    case generationTimedOut
    case generatedWorldMissing

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "尚未配置 Marble API Key。"
        case .invalidResponse:
            "Marble 返回了无法识别的数据。"
        case let .rejected(statusCode, message):
            "Marble 请求失败（\(statusCode)）：\(message)"
        case let .generationFailed(message):
            "Marble 空间生成失败：\(message)"
        case .generationTimedOut:
            "Marble 仍在生成空间，请稍后再刷新。"
        case .generatedWorldMissing:
            "空间已经生成，但暂时还没有出现在空间列表中。"
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
    private let baseURL: URL
    private let session: URLSession
    private let apiKeyProvider: MarbleAPIKeyProvider
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = URL(string: "https://api.worldlabs.ai")!,
        session: URLSession = .shared,
        apiKeyProvider: MarbleAPIKeyProvider = MarbleAPIKeyProvider()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    func listWorlds(pageSize: Int = 20) async throws -> [MarbleWorld] {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "marble/v1/worlds:list"
            )
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "page_size": min(max(pageSize, 1), 100),
            "sort_by": "created_at",
            "status": "SUCCEEDED",
        ])
        try authorize(&request)

        let data = try await responseData(for: request)
        return try decoder.decode(
            MarbleWorldListResponse.self,
            from: data
        ).worlds
    }

    func world(id: String) async throws -> MarbleWorld {
        let worldURL = baseURL
            .appendingPathComponent("marble/v1/worlds")
            .appendingPathComponent(id)
        var request = URLRequest(url: worldURL)
        request.httpMethod = "GET"
        try authorize(&request)

        let data = try await responseData(for: request)
        return try decoder.decode(
            MarbleWorldResponse.self,
            from: data
        ).world
    }

    func generateWorld(
        preset: SpatialScenePreset
    ) async throws -> MarbleOperation {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "marble/v1/worlds:generate"
            )
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            MarbleGenerateWorldRequest(preset: preset)
        )
        try authorize(&request)

        return try decoder.decode(
            MarbleOperation.self,
            from: try await responseData(for: request)
        )
    }

    func operation(id: String) async throws -> MarbleOperation {
        let operationURL = baseURL
            .appendingPathComponent("marble/v1/operations")
            .appendingPathComponent(id)
        var request = URLRequest(url: operationURL)
        request.httpMethod = "GET"
        try authorize(&request)

        return try decoder.decode(
            MarbleOperation.self,
            from: try await responseData(for: request)
        )
    }

    private func authorize(_ request: inout URLRequest) throws {
        request.setValue(
            try apiKeyProvider.read(),
            forHTTPHeaderField: "WLT-Api-Key"
        )
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MarbleWorldClientError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "未知错误"
            throw MarbleWorldClientError.rejected(
                statusCode: response.statusCode,
                message: String(message.prefix(300))
            )
        }
        return data
    }
}
