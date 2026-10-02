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

    private struct Registration: Sendable {
        let imageURL: URL
        let displayName: String
        let attachmentID: UUID
    }

    /// One shared same-URL download. The token lets a finishing caller clear only the
    /// flight it awaited, so a later call that already started a replacement keeps its own.
    private struct Flight {
        let token: UUID
        let task: Task<Registration, Error>
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
    private var calls: [String: Registration] = [:]
    private var registeredByURL: [URL: Registration] = [:]
    private var inFlight: [URL: Flight] = [:]
    /// 已知连不上时的冷却：连着撞墙没有意义（真机 2026-10-01 20:49–20:50 一个回合里
    /// 撞了 3 次、每次 10 秒），但冷却**必须自愈**：到点自动失效，一旦成功立刻清掉。
    /// 这不是放宽判据 —— 它只决定"要不要再发一次请求"，判据一条都没动。
    private var cooldown: (fact: WishReferenceDiagnosis.Fact, until: Date)?
    static let cooldownInterval: TimeInterval = 30
    /// 上一次送上屏的那句话。状态**变化**才再上屏一次，避免每个失败都刷一条。
    private var lastReportedScreen: String?
    private let now: () -> Date

    init(coordinator: WishMachineCoordinator, authorizationID: UUID?, worldID: String, residentScope: String,
         isCurrent: @escaping @MainActor () -> Bool, fetcher: Fetcher = .live,
         directory: URL? = nil, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
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

    private func search(callID: String, data: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else {
            return failure(callID, "stale_wish_reference_session", "本轮空间操作已停止。")
        }
        guard let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.validateSearch(arguments), let query = (arguments["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = Self.searchURL(query: query) else {
            return failure(callID, "invalid_arguments", "参考图搜索参数不符合当前契约。")
        }
        // 冷却期内不再撞墙，但回执必须说清"这一次没有发起搜索"，而不是假装搜过。
        if let cooling = coolingDownSearchFact() {
            WishReferenceLog.cooldownSkipped(code: cooling.code, reason: cooling.reason)
            return failure(callID, cooling.code, cooling.message)
        }
        let response: Fetcher.Response
        do {
            response = try await fetcher.fetchPublicData(url, Self.maximumResponseBytes)
        } catch {
            return report(callID, .search, WishReferenceDiagnosis.transportFailure(.search, error: error))
        }
        guard !Task.isCancelled, isCurrent() else {
            return failure(callID, "stale_wish_reference_session", "会话已停止，搜索结果未采用。")
        }
        guard Self.isJSONMIMEType(response.mimeType) else {
            return report(callID, .search, WishReferenceDiagnosis.searchNotJSON(mimeType: response.mimeType))
        }
        guard let results = Self.parseSearchResults(response.data) else {
            // 服务端自报的结构化错误把它的 code/info 逐字带出来；判据不变（仍是失败）。
            let fact = Self.searchAPIErrorFact(response.data) ?? WishReferenceDiagnosis.searchUnparseable()
            return report(callID, .search, fact)
        }
        // 服务真的答了：清掉冷却，屏上那条"不可用"撤掉。
        markReachable()
        let payload: [String: Any] = [
            "ok": true, "query": query, "total": results.count,
            "results": results.map { result -> [String: Any] in
                ["title": result.title, "image_url": result.imageURL,
                 "source_page_url": result.sourcePageURL, "source": "wikimedia_commons",
                 "license_verified": false]
            },
            "license_notice": "图片来自公开网页，版权与许可未核验；仅供本机个人测试，不得声称已核验授权。",
            // 结果为空 ≠ 失败：这是服务如实返回了空列表，`ok` 仍然是 true，没有失败码。
            "message": results.isEmpty
                ? WishReferenceDiagnosis.emptyResultsMessage
                : "请选择其中一张真实直链，再用 register_wish_reference_image 登记。",
        ]
        if results.isEmpty {
            WishReferenceLog.emptyResults(query: query)
            // 空结果也上屏，但走**普通信息**这一档：它绝不是失败。
            WishReferenceAvailabilityNotice.postInfo(WishReferenceDiagnosis.emptyResultsScreenText)
        }
        return success(callID, payload)
    }

    // MARK: Register

    private func register(callID: String, data: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else {
            return failure(callID, "stale_wish_reference_session", "本轮空间操作已停止。")
        }
        guard let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.validateRegister(arguments), let rawURL = arguments["image_url"] as? String,
              let imageURL = Self.publicImageURL(rawURL),
              let displayName = arguments["display_name"] as? String else {
            return failure(callID, "invalid_arguments", "参考图登记参数不符合当前契约。")
        }
        guard let authorizationID else {
            return failure(callID, ReferenceError.unauthorized.code, ReferenceError.unauthorized.localizedDescription)
        }
        if let existing = calls[callID] {
            guard existing.imageURL == imageURL, existing.displayName == displayName else {
                return failure(callID, ReferenceError.callConflict.code, ReferenceError.callConflict.localizedDescription)
            }
            return registrationPayload(callID, existing)
        }
        if let existing = registeredByURL[imageURL] {
            calls[callID] = existing
            return registrationPayload(callID, existing)
        }
        let flight: Flight
        if let running = inFlight[imageURL] {
            flight = running
        } else {
            let created = Flight(token: UUID(), task: Task { @MainActor [self] in
                try await downloadAndRegister(imageURL: imageURL, displayName: displayName, authorizationID: authorizationID)
            })
            inFlight[imageURL] = created
            flight = created
        }
        let task = flight.task
        do {
            // Cancelling this call must cancel the shared download it awaits. The flight
            // is unstructured, so without this propagation it would finish and persist a
            // registration after the turn was already stopped.
            let registration = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            // A late completion must not become a durable call mapping once this turn was
            // cancelled or its world/scope changed.
            try Task.checkCancellation()
            guard isCurrent() else { throw ReferenceError.stale }
            if inFlight[imageURL]?.token == flight.token { inFlight[imageURL] = nil }
            calls[callID] = registration
            registeredByURL[imageURL] = registration
            markReachable()
            return registrationPayload(callID, registration)
        } catch {
            // Only clear the flight this call awaited; a replacement started meanwhile stays.
            if inFlight[imageURL]?.token == flight.token { inFlight[imageURL] = nil }
            // 领域错误（授权、冲突、额度…）保持它们自己的名字；其余都是传输失败，
            // 必须走具名诊断 —— `error.localizedDescription` 会把
            // `transportFailure("curl-exit-28")` 压成 `error 17`，真机上就是这么丢掉原因的。
            if error is ReferenceError || error is WishMachineError {
                return failure(callID, Self.code(for: error), error.localizedDescription)
            }
            return report(callID, .registration, WishReferenceDiagnosis.transportFailure(.registration, error: error))
        }
    }

    // MARK: Named failure reporting: receipt + log + screen

    /// 失败的**唯一出口**：回执、日志、屏上读的是同一份具名事实。
    ///
    /// 真机缺陷形态正是"只写回执"：`tool/result` 里有一句 `reference_search_failed`，
    /// app 系统日志里一行都没有，用户听到的只有一句「找图失败」。
    @discardableResult
    private func report(_ callID: String, _ operation: WishReferenceDiagnosis.Operation,
                        _ fact: WishReferenceDiagnosis.Fact) -> RealtimeDJToolResult {
        WishReferenceLog.failure(fact, operation: operation.rawValue)
        if fact.isConnectivity { cooldown = (fact, now().addingTimeInterval(Self.cooldownInterval)) }
        if lastReportedScreen != fact.screen {
            lastReportedScreen = fact.screen
            WishReferenceLog.availabilityChanged(fact.screen, isFailure: true)
            WishReferenceAvailabilityNotice.postFailure(fact.screen)
        }
        return failure(callID, fact.code, fact.message)
    }

    /// 冷却期内不再重复撞墙，但**必须说清这一次没有发起搜索**。
    private func coolingDownSearchFact() -> WishReferenceDiagnosis.Fact? {
        guard let cooldown, cooldown.until > now() else { return nil }
        let remaining = max(1, Int(cooldown.until.timeIntervalSince(now()).rounded(.up)))
        return WishReferenceDiagnosis.searchCoolingDown(fact: cooldown.fact, secondsRemaining: remaining)
    }

    /// 服务真的答了：冷却清掉，屏上那条"不可用"撤掉，日志留一行恢复。
    private func markReachable() {
        cooldown = nil
        guard lastReportedScreen != nil else { return }
        lastReportedScreen = nil
        WishReferenceLog.availabilityChanged(nil, isFailure: false)
        WishReferenceAvailabilityNotice.postRecovered()
    }

    /// 搜索响应里服务端自报的结构化错误。只读它，绝不把错误当空结果。
    static func searchAPIErrorFact(_ data: Data) -> WishReferenceDiagnosis.Fact? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return WishReferenceDiagnosis.searchAPIError(code: error["code"] as? String,
            info: error["info"] as? String)
    }

    private func downloadAndRegister(imageURL: URL, displayName: String, authorizationID: UUID) async throws -> Registration {
        var pendingFile: URL?
        do {
            try Task.checkCancellation()
            let data = try await fetcher.download(imageURL)
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= Self.maximumImageBytes, Self.isPNG(data) else {
                throw ReferenceError.invalidImage
            }
            guard isCurrent() else { throw ReferenceError.stale }
            let attachmentID = UUID()
            let destination = directory.appendingPathComponent(attachmentID.uuidString + ".png")
            // Mark this call's own unique destination before writing so a failed write,
            // chmod or later cancellation can only ever clean up this call's file.
            pendingFile = destination
            try writePrivate(data, to: destination)
            try Task.checkCancellation()
            guard isCurrent() else { throw ReferenceError.stale }
            let attachment = ResidentImageAttachment(id: attachmentID, url: destination,
                displayName: String(displayName.prefix(Self.maximumDisplayNameLength)))
            _ = try coordinator.registerWebReference(attachment, imageURL: imageURL, authorizationID: authorizationID,
                worldID: worldID, residentScope: residentScope, source: Self.webSource)
            pendingFile = nil // Registered: the file is retained for the asynchronous wish.
            return Registration(imageURL: imageURL, displayName: attachment.displayName, attachmentID: attachmentID)
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

    private func registrationPayload(_ callID: String, _ registration: Registration) -> RealtimeDJToolResult {
        success(callID, [
            "ok": true, "attachment_id": registration.attachmentID.uuidString,
            "display_name": registration.displayName,
            "source_image_url": registration.imageURL.absoluteString,
            "source_kind": "public_web_reference", "license_verified": false,
            "message": "已登记为本轮参考图，来源和许可没有核实。用户明确要做的时候，再提交生成。",
        ])
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
