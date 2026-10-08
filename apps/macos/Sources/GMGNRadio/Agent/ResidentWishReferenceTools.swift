import Foundation

/// The resident's read-only public-image discovery plus a host-gated registration path.
///
/// The model never receives an authorization ID, a world, a resident scope or a local
/// path: those all come from the host lease captured here. Search reads public data and
/// never spends generation budget; registration stores one normalized PNG under a
/// private 0700 directory and hands its ID to the existing `submit_wish_generation`.
@MainActor
final class ResidentWishReferenceTools {
    /// Injected transport so the whole chain is exercisable offline. The live value is
    /// the shared downloader; tests supply a closure that answers the fixed API. The
    /// search seam preserves the verified MIME type alongside the body so a JSON search
    /// response can be refused before parsing instead of being mistaken for image bytes.
    struct Fetcher: Sendable {
        struct Response: Sendable {
            let data: Data
            let mimeType: String
        }
        var fetchPublicData: @Sendable (URL, Int) async throws -> Response
        var download: @Sendable (URL) async throws -> Data

        static let live = Fetcher(
            fetchPublicData: { url, maximumBytes in
                let response = try await ResidentWebImageDownloader().fetchPublicData(url, maximumBytes: maximumBytes)
                return Response(data: response.data, mimeType: response.mimeType)
            },
            download: { try await ResidentWebImageDownloader().download($0) }
        )
    }

    struct SearchResult: Equatable, Sendable {
        let title: String
        let imageURL: String
        let sourcePageURL: String
    }



    private enum ReferenceError: LocalizedError {
        case stale, invalidImage, unauthorized, callConflict
        var code: String {
            switch self {
            case .stale: "stale_wish_reference_session"
            case .invalidImage: "reference_image_invalid"
            case .unauthorized: "reference_registration_unauthorized"
            case .callConflict: "reference_call_conflict"
            }
        }
        var errorDescription: String? {
            switch self {
            case .stale: "本轮空间操作已停止，参考图没有登记。"
            case .invalidImage: "下载结果不是可用的 PNG 图片，参考图没有登记。"
            case .unauthorized: "本轮没有可登记的生成授权；只有当前人类回合可以登记参考图。"
            case .callConflict: "同一个工具调用编号不能用于另一张参考图。"
            }
        }
    }

    // MARK: Fixed Wikimedia Commons search surface

    static let maximumResults = 5
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let maximumImageBytes = 8 * 1024 * 1024
    static let maximumQueryLength = 200
    static let maximumDisplayNameLength = 100
    static let searchEndpoint = URL(string: "https://commons.wikimedia.org/w/api.php")!
    static let webSource = PropGenerationSource(author: "网页参考图（公开来源，未核验许可）",
        license: "未核验，仅限个人测试")

    /// The fixed Commons query assembled through URLComponents; the model only supplies
    /// the search text, never any other parameter.
    static func searchURL(query: String) -> URL? {
        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "\(maximumResults)"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "1024"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "gsrsearch", value: query),
        ]
        return components?.url
    }

    /// The search response is only accepted when the transport verified a JSON media type.
    /// Parameters are ignored and `+json` suffixes are accepted, but HTML/plain error pages
    /// can never be parsed as a successful empty search.
    static func isJSONMIMEType(_ raw: String) -> Bool {
        let media = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return media == "application/json" || media == "text/json" || media.hasSuffix("+json")
    }

    /// Parses real Commons JSON into at most five structured results and never invents a
    /// link: pages without an imageinfo URL are skipped, and a legitimate response without
    /// `query` is empty. A structured API `error` is an explicit failure, never an empty list.
    static func parseSearchResults(_ data: Data) -> [SearchResult]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard root["error"] == nil else { return nil }
        guard let query = root["query"] as? [String: Any] else { return [] }
        let pages: [[String: Any]]
        if let dictionary = query["pages"] as? [String: Any] {
            pages = dictionary.values.compactMap { $0 as? [String: Any] }
        } else if let array = query["pages"] as? [[String: Any]] {
            pages = array
        } else {
            pages = []
        }
        var results: [SearchResult] = []
        for page in pages {
            guard results.count < maximumResults else { break }
            guard let title = page["title"] as? String, !title.isEmpty, title.count <= 300,
                  let info = (page["imageinfo"] as? [[String: Any]])?.first else { continue }
            let rawImage = (info["thumburl"] as? String) ?? (info["url"] as? String)
            guard let image = rawImage.flatMap(publicImageURL) else { continue }
            let sourcePage = (info["descriptionurl"] as? String).flatMap(publicPageURL)
                ?? commonsPageURL(title: title)
            guard let sourcePage else { continue }
            results.append(SearchResult(title: title, imageURL: image.absoluteString,
                sourcePageURL: sourcePage.absoluteString))
        }
        return results
    }

    /// Only public HTTPS on the standard port; credentials and fragments are rejected
    /// before any download is attempted.
    static func publicImageURL(_ raw: String) -> URL? {
        guard (1...2048).contains(raw.count), let url = URL(string: raw),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private static func publicPageURL(_ raw: String) -> URL? {
        guard (1...2048).contains(raw.count), let url = URL(string: raw),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func commonsPageURL(title: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        guard let encoded = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/" + encoded)
    }

    // MARK: Lease

    private let coordinator: WishMachineCoordinator
    private let authorizationID: UUID?
    private let worldID: String
    private let residentScope: String
    private let isCurrent: @MainActor () -> Bool
    private let fetcher: Fetcher
    private let directory: URL
    private let fileManager: FileManager
    private let referenceClient: RustWishReferenceClient
    static let cooldownInterval: TimeInterval = 30
    /// 上一次送上屏的那句话。状态**变化**才再上屏一次，避免每个失败都刷一条。
    private var lastReportedScreen: String?
    private let now: () -> Date

    init(coordinator: WishMachineCoordinator, authorizationID: UUID?, worldID: String, residentScope: String,
         isCurrent: @escaping @MainActor () -> Bool, fetcher: Fetcher = .live,
         directory: URL? = nil, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init,
         referenceClient: RustWishReferenceClient? = nil) {
        self.coordinator = coordinator
        self.authorizationID = authorizationID
        self.worldID = worldID
        self.residentScope = residentScope
        self.isCurrent = isCurrent
        self.fetcher = fetcher
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/ResidentWishReferences", isDirectory: true)
        self.fileManager = fileManager
        self.now = now
        self.referenceClient = referenceClient ?? RustWishReferenceClient()
    }

    var tools: [ResidentWorldToolSession.AdditionalTool] {
        [
            .init(name: "search_wish_reference_images",
                description: "检索公开网页图片作为制作参考。返回真实图片直链、来源页面和版权未核验声明；没有结果时如实返回空列表，不得编造图片链接。搜索只读，任何回合都可用，不代表生成，也不消耗生成额度。read_wish_generation 缺少附件时先搜索真实图片。",
                inputSchema: [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "要搜索的英文物件名关键词，例如 red wooden chair"]],
                    "required": ["query"], "additionalProperties": false,
                ],
                validate: { Self.validateSearch($0) },
                handle: { [self] callID, arguments in await search(callID: callID, data: arguments) }),
            .init(name: "register_wish_reference_image",
                description: "把一张公开图片直链安全下载并归一成 PNG，登记到当前人类回合与空间，返回 attachment_id 供 submit_wish_generation 使用。来源随图片保留，许可未核验；登记不生成、不消耗生成额度。若 read_wish_generation 显示 generation_authorized=false 且没有附件，先调用本工具登记一张真实参考图来建立本轮图片授权，不要只反复读取或要求用户找图。用户没给图时由你自行搜索登记，也不得凭空声称已看图。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "image_url": ["type": "string", "description": "搜索结果里的公开图片直链（https），也可以是其他公开网页图片直链"],
                        "display_name": ["type": "string", "description": "给这张参考图起的简短名字"],
                    ],
                    "required": ["image_url", "display_name"], "additionalProperties": false,
                ],
                validate: { Self.validateRegister($0) },
                handle: { [self] callID, arguments in await register(callID: callID, data: arguments) }),
        ]
    }

    /// Stable host construction used by the app factory for every wishworld turn.
    ///
    /// Both schemas are always present, including background turns without a human
    /// generation grant. A nil authorization only makes `register` refuse inside its
    /// handler; it must never remove a schema from the manifest, because Codex registers
    /// tools once per thread and DSH caches the manifest, so a later human resume could
    /// never add the missing tool back. Search stays read-only and never generates.
    static func sessionTools(coordinator: WishMachineCoordinator, authorizationID: UUID?, worldID: String,
                             residentScope: String, isCurrent: @escaping @MainActor () -> Bool,
                             fetcher: Fetcher = .live, directory: URL? = nil,
                             fileManager: FileManager = .default) -> [ResidentWorldToolSession.AdditionalTool] {
        ResidentWishReferenceTools(coordinator: coordinator, authorizationID: authorizationID, worldID: worldID,
            residentScope: residentScope, isCurrent: isCurrent, fetcher: fetcher, directory: directory,
            fileManager: fileManager).tools
    }

    // MARK: Validation

    static func validateSearch(_ arguments: [String: Any]) -> Bool {
        guard Set(arguments.keys) == ["query"], let query = arguments["query"] as? String else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumQueryLength
    }

    static func validateRegister(_ arguments: [String: Any]) -> Bool {
        guard Set(arguments.keys) == ["image_url", "display_name"],
              let rawURL = arguments["image_url"] as? String, publicImageURL(rawURL) != nil,
              let name = arguments["display_name"] as? String,
              (1...maximumDisplayNameLength).contains(name.count),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    // MARK: Search

    private func authority(callID: String) throws -> ResidentWorldToolSession.RustDispatchAuthority {
        guard let claim = ResidentWorldToolSession.rustDispatchAuthority,
              claim.callID == callID, claim.worldID == worldID, claim.residentScope == residentScope else {
            throw RustWishReferenceClient.ClientError.missingClaim
        }
        return claim
    }

    private func search(callID: String, data: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else {
            return failure(callID, "stale_wish_reference_session", "本轮空间操作已停止。")
        }
        do {
            let claim = try authority(callID: callID)
            guard let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return failure(callID, "invalid_arguments", "参考图搜索参数不符合当前契约。")
            }
            let result = try await referenceClient.request("wish_reference_search", authority: claim, fields: arguments)
            try Task.checkCancellation()
            guard isCurrent() else { throw ReferenceError.stale }
            return renderAuthorityResult(callID, result, operation: .search)
        } catch {
            return authorityFailure(callID, error: error, operation: .search)
        }
    }

    private func register(callID: String, data: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else {
            return failure(callID, "stale_wish_reference_session", "本轮空间操作已停止。")
        }
        do {
            let claim = try authority(callID: callID)
            guard let authorizationID,
                  var arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReferenceError.unauthorized
            }
            arguments["authorizationID"] = authorizationID.uuidString
            var result = try await referenceClient.request("wish_reference_prepare", authority: claim, fields: arguments)
            // Rust owns the durable URL flight. Another call observes it without
            // creating a second native download or a second attachment.
            let deadline = Date().addingTimeInterval(20)
            while result["action"] as? String == "wait" {
                try Task.checkCancellation()
                guard isCurrent(), Date() < deadline else { throw ReferenceError.stale }
                try await Task.sleep(for: .milliseconds(100))
                result = try await referenceClient.request("wish_reference_prepare", authority: claim, fields: arguments)
            }
            if result["action"] as? String == "download" {
                guard let rawURL = result["image_url"] as? String, let imageURL = URL(string: rawURL),
                      let displayName = result["display_name"] as? String,
                      let rawID = result["attachment_id"] as? String, let attachmentID = UUID(uuidString: rawID),
                      let token = result["token"] as? String else { throw RustWishReferenceClient.ClientError.invalidProtocol }
                arguments["token"] = token
                do {
                    try await downloadLeaf(imageURL: imageURL, displayName: displayName,
                        attachmentID: attachmentID, authorizationID: authorizationID)
                    arguments["success"] = true
                } catch {
                    let fact = WishReferenceDiagnosis.transportFailure(.registration, error: error)
                    arguments["success"] = false
                    arguments["code"] = error is ReferenceError || error is WishMachineError ? Self.code(for: error) : fact.code
                    arguments["reason"] = WishReferenceDiagnosis.preservedReason(error)
                    arguments["isConnectivity"] = fact.isConnectivity
                }
                try Task.checkCancellation()
                guard isCurrent() else { throw ReferenceError.stale }
                result = try await referenceClient.request("wish_reference_complete", authority: claim, fields: arguments)
            }
            return renderAuthorityResult(callID, result, operation: .registration)
        } catch {
            return authorityFailure(callID, error: error, operation: .registration)
        }
    }

    private func authorityFailure(_ callID: String, error: Error,
                                  operation: WishReferenceDiagnosis.Operation) -> RealtimeDJToolResult {
        let fact = WishReferenceDiagnosis.transportFailure(operation, error: error)
        let code: String
        if let authorityError = error as? WorldAuthorityError, case let .daemon(remote) = authorityError { code = remote }
        else if let transportError = error as? TaskdHTTPError, case let .rejected(remote) = transportError { code = remote }
        else if error is ReferenceError || error is WishMachineError { code = Self.code(for: error) }
        else { code = fact.code }
        return renderAuthorityResult(callID, ["ok": false, "code": code, "reason": fact.reason,
            "message": fact.message, "screen": fact.screen, "isConnectivity": fact.isConnectivity], operation: operation)
    }

    /// Native only presents the Rust result; it does not change retry/cooldown state.
    private func renderAuthorityResult(_ callID: String, _ payload: [String: Any],
                                       operation: WishReferenceDiagnosis.Operation) -> RealtimeDJToolResult {
        if payload["ok"] as? Bool == true {
            if lastReportedScreen != nil {
                lastReportedScreen = nil
                WishReferenceAvailabilityNotice.postRecovered()
            }
            if operation == .search, payload["total"] as? Int == 0 {
                WishReferenceAvailabilityNotice.postInfo(WishReferenceDiagnosis.emptyResultsScreenText)
            }
            return success(callID, payload)
        }
        let fact = WishReferenceDiagnosis.Fact(code: payload["code"] as? String ?? "reference_registration_failed",
            reason: payload["reason"] as? String ?? "authority-failure",
            message: payload["message"] as? String ?? "参考图服务失败。",
            screen: payload["screen"] as? String ?? "参考图服务失败。",
            isConnectivity: payload["isConnectivity"] as? Bool ?? false)
        WishReferenceLog.failure(fact, operation: operation.rawValue)
        if lastReportedScreen != fact.screen {
            lastReportedScreen = fact.screen
            WishReferenceAvailabilityNotice.postFailure(fact.screen)
        }
        return .init(callID: callID, resultJSON: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8), isError: true)
    }

    /// Platform security/download normalization and file I/O remain native leaves.
    /// Attachment identity and download permission came from Rust, and the existing
    /// wish-control authority records the actual attachment before completion.
    private func downloadLeaf(imageURL: URL, displayName: String, attachmentID: UUID,
                              authorizationID: UUID) async throws {
        var pendingFile: URL?
        do {
            try Task.checkCancellation()
            let data = try await fetcher.download(imageURL)
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= Self.maximumImageBytes, Self.isPNG(data) else { throw ReferenceError.invalidImage }
            guard isCurrent() else { throw ReferenceError.stale }
            let destination = directory.appendingPathComponent(attachmentID.uuidString + ".png")
            pendingFile = destination
            try writePrivate(data, to: destination)
            try Task.checkCancellation()
            guard isCurrent() else { throw ReferenceError.stale }
            let attachment = ResidentImageAttachment(id: attachmentID, url: destination, displayName: displayName)
            _ = try await coordinator.registerWebReference(attachment, imageURL: imageURL,
                authorizationID: authorizationID, worldID: worldID, residentScope: residentScope, source: Self.webSource)
            pendingFile = nil
        } catch {
            if let pendingFile { try? fileManager.removeItem(at: pendingFile) }
            throw error
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func isPNG(_ data: Data) -> Bool {
        data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
    }

    private static func code(for error: Error) -> String {
        if let reference = error as? ReferenceError { return reference.code }
        if let wish = error as? WishMachineError {
            switch wish {
            case .consumedAuthorization: return "reference_authorization_consumed"
            case .wrongScope: return "reference_scope_mismatch"
            case .conflictingCall: return "reference_call_conflict"
            case .imageLimitReached: return "reference_image_limit"
            case .unavailable: return "reference_registration_unavailable"
            default: return "reference_registration_failed"
            }
        }
        return "reference_registration_failed"
    }

    static func searchAPIErrorFact(_ data: Data) -> WishReferenceDiagnosis.Fact? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return WishReferenceDiagnosis.searchAPIError(code: error["code"] as? String, info: error["info"] as? String)
    }

    private func success(_ callID: String, _ payload: [String: Any]) -> RealtimeDJToolResult {
        .init(callID: callID,
            resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8),
            isError: false)
    }

    private func failure(_ callID: String, _ code: String, _ message: String) -> RealtimeDJToolResult {
        .init(callID: callID,
            resultJSON: (try? JSONSerialization.data(withJSONObject: ["ok": false, "code": code, "message": message],
                options: .sortedKeys)) ?? Data("{}".utf8),
            isError: true)
    }
}
