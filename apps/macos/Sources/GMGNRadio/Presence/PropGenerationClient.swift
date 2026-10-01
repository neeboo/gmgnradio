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

/// 提交契约里的**尺寸意图**的 app 侧镜像。两种形状，**二选一**：
///
/// 1. `{axis, meters, source}` —— **一根轴 + 一个米数**（改造前就有的那一份，线上逐字节不变）。
/// 2. `{mode:"dimensions", millimeters:{x,y,z}, source}` —— **完整三维（毫米）**。
///
/// 「用户说的那个尺寸」必须**在提交之前**就说清楚，而不是让界面事后从网格猜。
///
/// 反面教材一（真机 2026-10-01「2B 白色长剑（外形摆件）」）：只有一根"高度"轴，而生成回来的
/// 网格不保证立着，1.1 m 的请求被算成"厚度 1.1 m" ⇒ 场景里 8.28 m 长、比舱室还长、
/// 摆放被拒后从房间里消失。用户说的"一把 1.1 米的剑"，他要的是**最长边** 1.1 m。
///
/// 反面教材二（真机 2026-10-01「平面电视」）：用户的规格是 `1443 x 862 x 302 mm`，**三根轴
/// 都说死了**，而旧形状只能上报一根 ⇒ 另外两维在契约里没有位置 ⇒ 生成器交回一个大立方体。
///
/// 词汇与守护进程 `model.rs::SizeIntent` **逐字相同**（`longest`/`height`、
/// `user`/`suggested`/`default`、`mode:"dimensions"`）。缺失时整块不发：老路径的字节与行为都不变。
struct PropSizeIntent: Codable, Equatable, Sendable {
    /// 哪根轴。`longest` = 最长边（剑、扫帚、滑雪板这类横着放的东西）；
    /// `height` = 高度（咖啡机、椅子这类立着的东西，也就是旧 `height_meters` 的语义）。
    ///
    /// `CaseIterable` 是为了让 `WishMachineContract`（agent 现读的那份接口）能把轴词汇
    /// **枚举出来**而不是再抄一遍字面量：轴名的唯一拥有者始终是这个 enum。
    enum Axis: String, Codable, Equatable, Sendable, CaseIterable { case longest, height }
    /// 谁说的这个尺寸。`default` 在 Swift 里是关键字，所以 case 名与线上字面量分开写。
    enum Source: String, Codable, Equatable, Sendable {
        case user
        case suggested
        case fallback = "default"
    }

    /// 意图的**形状**。线上只有三轴形状写 `mode` 这个键；旧形状线上没有它。
    enum Mode: Equatable, Sendable {
        /// 一根轴 + 一个米数（改造前就有的那一份，线上逐字节不变）。
        case axes
        /// 完整三维（毫米）。
        case dimensions
    }

    /// 三轴尺寸（毫米）。**轴序与朝向**（与守护进程 `SizeIntentMillimeters` 逐字相同）：
    /// `x` = 宽（左右）、**`y` = 高（上下；本仓 up 钉死在 `±Y`）**、`z` = 深（前后）。
    /// 于是用户的「1443 x 862 x 302 mm」= `x` 1443（宽）、`y` 862（高）、`z` 302（深）。
    struct Millimeters: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let z: Double

        /// 三个分量按 `[x, y, z]` 排（唯一的遍历顺序，避免各处各写一遍）。
        var edges: [Double] { [x, y, z] }
        /// 最长边的米数。三轴形状派生的 `axis`/`meters` 就是它。
        var longestMeters: Double { edges.max() ?? 0 / 1000 }
    }

    /// 线上 `mode` 的字面量（唯一一份）。
    static let dimensionsModeValue = "dimensions"

    let mode: Mode
    /// 旧形状的那根轴。三轴形状下它是**最长边的等价投影**（见 `init?(millimeters:source:)`）：
    /// 既有的读者（面板、回执、世界状态、渲染归一）不必改，而三根轴的真值在 `millimeters` 里。
    let axis: Axis
    /// 旧形状的米数；三轴形状下是**最长边**的米数。
    let meters: Double
    /// 三轴形状的毫米三元组；旧形状为 `nil`。
    let millimeters: Millimeters?
    let source: Source

    /// 契约允许的米数：与 `heightMeters` **同一条范围**（守护进程 `SIZE_INTENT_*_METERS`）。
    static let minimumMeters: Double = 0.01
    static let maximumMeters: Double = 3.0
    /// 三轴的毫米边界：与米数**同一条边界**（`0.01–3 m` ⇔ `10–3000 mm`）。
    static let minimumMillimeters: Double = 10
    static let maximumMillimeters: Double = 3000

    init?(axis: Axis, meters: Double, source: Source) {
        guard meters.isFinite, (Self.minimumMeters...Self.maximumMeters).contains(meters) else { return nil }
        self.mode = .axes
        self.axis = axis; self.meters = meters
        self.millimeters = nil
        self.source = source
    }

    /// 三轴形状。三根轴都必须落在与 `axis/meters` **同一条边界**上（`0.01–3 m` ⇒ `10–3000 mm`）。
    ///
    /// `axis`/`meters` 由**最长边**派生：这是与 app 侧归一策略（`WorldPropSizePolicy` 按最长边
    /// 等比）**一致的同一件事的两种写法**，不是第二个真相 —— 1443/862/302 的最长边就是 1.443 m。
    /// 另外两维只作为**期望值**记录在 `millimeters` 里，**绝不据此非等比拉伸**：渲染端只有一份
    /// 等比缩放，非等比会让碰撞盒与画面对不上（见 `WorldPropSizePolicy.intended` 的注释）。
    init?(millimeters: Millimeters, source: Source) {
        guard millimeters.edges.allSatisfy({
            $0.isFinite && (Self.minimumMillimeters...Self.maximumMillimeters).contains($0)
        }) else { return nil }
        self.mode = .dimensions
        self.axis = .longest
        self.meters = millimeters.longestMeters
        self.millimeters = millimeters
        self.source = source
    }

    var isValid: Bool {
        switch mode {
        case .axes:
            meters.isFinite && (Self.minimumMeters...Self.maximumMeters).contains(meters)
        case .dimensions:
            millimeters.map {
                $0.edges.allSatisfy { edge in
                    edge.isFinite && (Self.minimumMillimeters...Self.maximumMillimeters).contains(edge)
                }
            } ?? false
        }
    }
    /// 提交给守护进程时 `height_meters` 要填的数字。
    ///
    /// 旧形状轴是高度时它**必须**就是那个高度（守护进程强制两者相等，否则 `size_intent_conflict`）；
    /// 轴是最长边时它仍然是"生成请求的尺寸"这一个数字——远端只认它，而 app 按声明的轴归一。
    /// 三轴形状下它**必须**是三轴的 `y`（高）：三轴的 y 与"生成请求的高度"是同一件事，
    /// 守护进程对两者用的是**同一条**判据。
    var heightMetersForSubmission: Double {
        switch mode {
        case .axes: meters
        case .dimensions: (millimeters?.y ?? meters * 1000) / 1000
        }
    }
    /// 守护进程会强制 `height_meters` 等于的那个数（它的 `required_height_meters`）；
    /// `nil` = 这一份意图不管 `height_meters`。app 侧与守护进程用**同一条**判据。
    var requiredHeightMeters: Double? {
        switch mode {
        case .dimensions: millimeters.map { $0.y / 1000 }
        case .axes: axis == .height ? meters : nil
        }
    }
    /// 面板/工具回执用的一句话。
    ///
    /// 三轴形状把**原话的三个毫米数**也写进去：用户要能逐位核对自己说的
    /// 「1443 x 862 x 302 mm」，而不是看到一个换算过的近似值。
    var summary: String {
        let who = switch source {
        case .user: "用户指定"
        case .suggested: "服务建议"
        case .fallback: "默认值"
        }
        switch mode {
        case .axes:
            return "\(who)的\(axis == .longest ? "最长边" : "高度") \(String(format: "%.2f", meters)) 米"
        case .dimensions:
            guard let millimeters else { return "\(who)的三轴尺寸（读不出来）" }
            return "\(who)的三轴尺寸 \(Self.metersText(millimeters.x)) × \(Self.metersText(millimeters.y))"
                + " × \(Self.metersText(millimeters.z)) 米（宽 × 高 × 深；"
                + "你说的 \(Self.millimetersText(millimeters)) 毫米），"
                + "按最长边等比归一，另外两维只是期望值"
        }
    }

    /// 毫米数的原话写法（整数不带小数点），给面板与回执用。
    static func millimetersText(_ millimeters: Millimeters) -> String {
        millimeters.edges.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
            .joined(separator: " × ")
    }

    private static func metersText(_ millimeters: Double) -> String {
        String(format: "%.3f", millimeters / 1000)
    }

    private enum CodingKeys: String, CodingKey { case mode, axis, meters, millimeters, source }

    /// 线上两种形状的解码。`mode` 是**显式的形状标签**：有它就必须是 `dimensions`
    /// （别的值不猜），没有它就按旧形状读。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(Source.self, forKey: .source)
        if let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) {
            guard rawMode == Self.dimensionsModeValue,
                  let intent = PropSizeIntent(
                      millimeters: try container.decode(Millimeters.self, forKey: .millimeters),
                      source: source)
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "size_intent 不是合法的三轴尺寸（mode=\(rawMode)）"))
            }
            self = intent
            return
        }
        guard let intent = PropSizeIntent(
            axis: try container.decode(Axis.self, forKey: .axis),
            meters: try container.decode(Double.self, forKey: .meters),
            source: source)
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "size_intent 不是合法的旧形状尺寸"))
        }
        self = intent
    }

    /// 线上只写**一种**形状：旧形状写 `axis`/`meters`（与改造前逐字节相同），
    /// 三轴形状写 `mode`/`millimeters`。两种键永远不会同时出现。
    ///
    /// 键序也照**合成**编码那一份写（`axis, meters, source`）：旧形状上线的字节与改造前
    /// 一位不差，而不只是"语义相同"。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch mode {
        case .axes:
            try container.encode(axis, forKey: .axis)
            try container.encode(meters, forKey: .meters)
        case .dimensions:
            try container.encode(Self.dimensionsModeValue, forKey: .mode)
            try container.encode(millimeters, forKey: .millimeters)
        }
        try container.encode(source, forKey: .source)
    }
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
    /// 生成工作流自带的**碰撞代理**（可选、纯增量）。整块缺失 ⇒ 与今天逐字节一致
    /// （app 退回"尺寸 × 朝向"的偏航盒子）。出现时按它做碰撞。
    let collisionURL: String?
    let collisionFormat: String?
    let collisionSHA256: String?
    let collisionBytes: Int?
    let collisionTriangles: Int?
    /// 生成工作流给的**权威尺寸**（可选）。存在时尺寸以它为准，app 不再从网格量。
    let authoritativeSize: PropGenerationAuthoritativeSize?

    struct PropGenerationAuthoritativeSize: Codable, Sendable {
        let dimensions: [Double]
        let units: String
        let upAxis: String
        let forwardAxis: String
        enum CodingKeys: String, CodingKey {
            case dimensions, units
            case upAxis = "up_axis", forwardAxis = "forward_axis"
        }
    }

    enum CodingKeys: String, CodingKey {
        case modelURL = "model_url", suggestedHeightMeters = "suggested_height_meters"
        case scaleRequiresConfirmation = "scale_requires_confirmation", interactionStatus = "interaction_status"
        case workflowProfile = "workflow_profile"
        case source, inspection, affordanceCandidates = "affordance_candidates", interactionBindings = "interaction_bindings"
        case collisionURL = "collision_url", collisionFormat = "collision_format"
        case collisionSHA256 = "collision_sha256", collisionBytes = "collision_bytes"
        case collisionTriangles = "collision_triangles", authoritativeSize = "authoritative_size"
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

    static func validateInput(png: Data, name: String, source: PropGenerationSource, heightMeters: Double,
                              sizeIntent: PropSizeIntent? = nil) throws {
        guard (1...100).contains(name.count), !name.contains(where: { "/\\\0".contains($0) }),
              [source.author, source.license].allSatisfy({ (1...200).contains($0.count) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              heightMeters.isFinite, (0.01...3).contains(heightMeters), png.count >= 24, png.count <= 8 * 1024 * 1024,
              png.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw PropGenerationError.invalidInput }
        // 尺寸意图**存在时必须合法**，而且与 `height_meters` 不矛盾：轴是高度（或三轴的 `y`）时
        // 两者就是同一件事 ⇒ 数值必须相同，否则就是两份真相（守护进程侧同一条
        // `size_intent_conflict`）。判据来自 `requiredHeightMeters` —— app 与守护进程**同一份**。
        if let sizeIntent {
            guard sizeIntent.isValid else { throw PropGenerationError.invalidInput }
            if let required = sizeIntent.requiredHeightMeters, required != heightMeters {
                throw PropGenerationError.invalidInput
            }
        }
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
