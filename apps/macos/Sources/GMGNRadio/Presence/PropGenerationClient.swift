import Foundation

enum PropGenerationState: String, Codable, CaseIterable, Sendable {
    case queued, preflight, waitingResources = "waiting_resources", submitting
    case remotePending = "remote_pending", running, cancelRequested = "cancel_requested"
    case completed, failed, cancelled, interrupted
    var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
}

struct PropGenerationHealth: Decodable, Sendable {
    struct Generation: Decodable, Sendable { let ready: Bool; let reason: String? }
    let status: String
    let generation: Generation
    var isReady: Bool { status == "api_ready" && generation.ready }
    var message: String {
        if isReady { return "许愿机已就绪，可以生成道具。" }
        if generation.reason == "shared_memory_busy" { return "服务已连接，正在等待生成资源。" }
        return "服务已连接，生成暂未就绪，请稍后再检测。"
    }
}

struct PropGenerationSource: Codable, Equatable, Sendable {
    let author: String
    let license: String
}

struct PropGenerationResult: Codable, Sendable {
    let modelURL: String
    let suggestedHeightMeters: Double
    let scaleRequiresConfirmation: Bool
    let interactionStatus: String
    let workflowProfile: String
    let source: PropGenerationSource
    let inspection: PropGenerationInspection
    let affordanceCandidates: [String]
    let interactionBindings: [String]
    enum CodingKeys: String, CodingKey {
        case modelURL = "model_url", suggestedHeightMeters = "suggested_height_meters"
        case scaleRequiresConfirmation = "scale_requires_confirmation", interactionStatus = "interaction_status"
        case workflowProfile = "workflow_profile"
        case source, inspection, affordanceCandidates = "affordance_candidates", interactionBindings = "interaction_bindings"
    }
}

struct PropGenerationInspection: Codable, Sendable {
    struct Bounds: Codable, Sendable {
        let min: [Double]
        let max: [Double]
        let dimensions: [Double]?
        let units: String?
        let space: String?
    }
    let sha256: String
    let bytes: Int
    let triangles: Int
    let primitives: Int
    let materials: Int
    let accessors: Int
    let accessorBounds: [String: Bounds]
    let bounds: Bounds
    let scaleCalibrated: Bool
    let metersPerModelUnit: Double?
    let sceneTransformCount: Int
    enum CodingKeys: String, CodingKey {
        case sha256, bytes, triangles, primitives, materials, accessors, bounds
        case accessorBounds = "accessor_bounds", scaleCalibrated = "scale_calibrated"
        case metersPerModelUnit = "meters_per_model_unit", sceneTransformCount = "scene_transform_count"
    }
}

struct PropGenerationReceipt: Codable, Sendable {
    let id: String
    let state: PropGenerationState
    let reason: String?
    let name: String
    let source: PropGenerationSource
    let heightMeters: Double
    let result: PropGenerationResult?
    let computeMayContinue: Bool
    let createdAt: Double
    let updatedAt: Double
    enum CodingKeys: String, CodingKey {
        case id, state, reason, name, source, result
        case heightMeters = "height_meters", computeMayContinue = "compute_may_continue"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

enum PropGenerationError: LocalizedError {
    case invalidEndpoint, missingToken, invalidInput, invalidResponse, http(Int), unsafeDownload, oversized, invalidGLB
    case historyUnavailable, providerChanged, missingTask, knownSubmission, configurationChangedBeforeSubmit
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "服务地址只支持 HTTPS 或本机 HTTP，且不能含账号、路径或查询参数。"
        case .missingToken: return "请先配置生成服务的访问令牌。"
        case .invalidInput: return "请检查图片、名称、来源和尺寸；高度支持 0.01—3 米。"
        case .invalidResponse: return "生成服务返回无法识别的结果。"
        case .http(let code): return "生成服务请求失败（\(code)）。"
        case .unsafeDownload: return "下载地址与当前任务不一致，已停止下载。"
        case .oversized: return "生成文件超过 32 MB，已停止下载。"
        case .invalidGLB: return "下载文件的 GLB 文件头或长度不正确。"
        case .historyUnavailable: return "任务记录无法读取或保存，请保留现有文件并检查存储位置。"
        case .providerChanged: return "此任务属于另一个服务，请恢复原服务配置后操作。"
        case .missingTask: return "找不到此生成任务。"
        case .knownSubmission: return "该任务已收到服务回执，请刷新状态，不要重复提交。"
        case .configurationChangedBeforeSubmit: return "准备图片期间服务配置发生变化，本次生成尚未提交，请检查配置后重新发起。"
        }
    }
}

private final class PropNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The configured origin is an explicit user trust decision. Credentials never follow redirects.
final class PropGenerationClient: @unchecked Sendable {
    let endpoint: URL
    private let token: String
    private let session: URLSession
    private let redirectGuard = PropNoRedirect()
    static let maxModelBytes = 32 * 1024 * 1024

    init(endpoint: URL, token: String, session: URLSession = .shared) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw PropGenerationError.invalidEndpoint }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw PropGenerationError.missingToken }
        self.endpoint = URL(string: endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        self.token = token
        self.session = session
    }

    func health() async throws -> PropGenerationHealth {
        var request = makeRequest(path: "/health", method: "GET")
        request.timeoutInterval = 5
        let data = try await load(request, limit: 16 * 1024)
        try Task.checkCancellation()
        guard let value = try? JSONDecoder().decode(PropGenerationHealth.self, from: data),
              value.status == "api_ready" else { throw PropGenerationError.invalidResponse }
        return value
    }

    func submit(png: Data, name: String, source: PropGenerationSource, heightMeters: Double, idempotencyKey: String) async throws -> PropGenerationReceipt {
        try Self.validateInput(png: png, name: name, source: source, heightMeters: heightMeters)
        guard idempotencyKey.range(of: "^[a-zA-Z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw PropGenerationError.invalidInput }
        var request = makeRequest(path: "/v1/jobs", method: "POST")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["image_base64": png.base64EncodedString(), "name": name,
            "source": ["author": source.author, "license": source.license], "height_meters": heightMeters], options: .sortedKeys)
        return try await receipt(request)
    }

    static func validateInput(png: Data, name: String, source: PropGenerationSource, heightMeters: Double) throws {
        guard (1...100).contains(name.count), !name.contains(where: { "/\\\0".contains($0) }),
              [source.author, source.license].allSatisfy({ (1...200).contains($0.count) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              heightMeters.isFinite, (0.01...3).contains(heightMeters), png.count >= 24, png.count <= 8 * 1024 * 1024,
              png.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw PropGenerationError.invalidInput }
        for offset in [16,20] {
            let n = png[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard (1...2048).contains(n) else { throw PropGenerationError.invalidInput }
        }
    }

    func status(id: String) async throws -> PropGenerationReceipt {
        try validateID(id)
        let value = try await receipt(makeRequest(path: "/v1/jobs/\(id)", method: "GET"))
        guard value.id == id else { throw PropGenerationError.invalidResponse }
        return value
    }

    func cancel(id: String) async throws -> PropGenerationReceipt {
        try validateID(id)
        var request = makeRequest(path: "/v1/jobs/\(id)/cancel", method: "POST")
        request.httpBody = Data("{}".utf8)
        let value = try await receipt(request)
        guard value.id == id else { throw PropGenerationError.invalidResponse }
        return value
    }

    func modelURL(path: String, jobID: String) throws -> URL {
        try validateID(jobID)
        let expected = endpoint.appendingPathComponent("v1/jobs/\(jobID)/model.glb")
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL, url == expected else { throw PropGenerationError.unsafeDownload }
        return url
    }

    func download(_ value: PropGenerationReceipt) async throws -> Data {
        guard value.state == .completed, let result = value.result else { throw PropGenerationError.invalidResponse }
        let url = try modelURL(path: result.modelURL, jobID: value.id)
        let data = try await load(makeRequest(url: url, method: "GET"), limit: Self.maxModelBytes)
        try Self.validateGLB(data)
        return data
    }

    /// Basic transport integrity only. The service performs the geometry inspection.
    static func validateGLB(_ data: Data) throws {
        guard data.count <= maxModelBytes else { throw PropGenerationError.oversized }
        guard data.count >= 20, data.prefix(4) == Data("glTF".utf8) else { throw PropGenerationError.invalidGLB }
        func integer(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) } }
        guard integer(4) == 2, integer(8) == data.count else { throw PropGenerationError.invalidGLB }
    }

    private func validateID(_ id: String) throws {
        guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw PropGenerationError.invalidResponse }
    }
    private func makeRequest(path: String, method: String) -> URLRequest { makeRequest(url: endpoint.appendingPathComponent(path), method: method) }
    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func receipt(_ request: URLRequest) async throws -> PropGenerationReceipt {
        let data = try await load(request, limit: 1024 * 1024)
        guard let value = try? JSONDecoder().decode(PropGenerationReceipt.self, from: data) else { throw PropGenerationError.invalidResponse }
        try validateID(value.id)
        return value
    }
    private func load(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw PropGenerationError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw PropGenerationError.http(http.statusCode) }
        guard response.expectedContentLength <= limit else { throw PropGenerationError.oversized }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw PropGenerationError.oversized }
            data.append(byte)
        }
        return data
    }
}
