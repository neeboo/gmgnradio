import Foundation
import os

/// 参考图工具链的**具名诊断**：每一种失败都必须有一个能指向原因的名字。
///
/// 真机证据（居民自己的 DSH 会话，`$TMPDIR/gmgn-resident-dsh-*/sessions/*/session.jsonl`）：
/// 2026-09-30 20:31 至 2026-10-01 20:50，`search_wish_reference_images` 连续 8 次、
/// `register_wish_reference_image` 连续 2 次失败，每一次耗时都恰好 10.07–10.11 秒；
/// `tool/result` 里的回执原文是
///
///     Error: {"code":"reference_search_failed","message":"公开图片搜索暂时不可用：
///     The operation couldn’t be completed. (GMGNRadio.ResidentWebImageError error 17.)",
///     "ok":false}
///
/// `error 17` 是 `ResidentWebImageError.transportFailure(String)` 的 NSError 桥接码 ——
/// `error.localizedDescription` 把 case 名和它携带的原因（`curl-exit-28` 之类）整个丢掉了。
/// app 系统日志里一行都没有（失败只落在工具回执里），于是居民只能对用户说一句
/// 「找图失败」，而谁都查不出为什么。这个文件把那条原因**逐字**留下来，并给每一种
/// 失败一个能直接指向原因的名字。
///
/// 判据（`tools/test-resident-wish-reference-tools.swift`）：
///   - 每种失败都有具名原因，注入模糊文案 ⇒ FAIL；
///   - 连不上时明确说去哪里配、且不冒充在搜，注入静默重试 ⇒ FAIL；
///   - 结果为空 ≠ 失败，注入混为一谈 ⇒ FAIL；
///   - 失败同时上屏 + 落日志，注入只写回执 ⇒ FAIL。
enum WishReferenceDiagnosis {
    /// 一条失败的完整说法。四个字段缺一不可：回执、日志、屏上读的是**同一份**事实，
    /// 不允许任何一处只剩「失败」两个字。
    struct Fact: Equatable, Sendable {
        /// 稳定的机器码，形如 `reference_search_timeout`。
        let code: String
        /// **逐字保留**的底层原因（`curl-exit-28`、`mime:text/html`、`badvalue: invalid search`…）。
        let reason: String
        /// 给居民（模型）的完整说法：指向原因，必要时说去哪里配。
        let message: String
        /// 给屏上那一条状态行的短说法。
        let screen: String
        /// 是不是"连不上"这一类（用同一套指引，也用同一条屏上通道）。
        let isConnectivity: Bool
    }

    /// 失败发生在哪条工具上：只影响码前缀，分类与文案不分叉。
    enum Operation: String, Sendable {
        case search, registration

        var codePrefix: String {
            switch self {
            case .search: "reference_search"
            case .registration: "reference_registration"
            }
        }

        var label: String {
            switch self {
            case .search: "公开图片搜索"
            case .registration: "参考图登记"
            }
        }

        /// 屏上那一句的开头。它与 `screenPrefix` 连用，让"恢复"能**只**撤掉自己那一条。
        var screenLabel: String {
            switch self {
            case .search: "参考图搜索"
            case .registration: "参考图登记"
            }
        }
    }

    /// 屏上那句话的固定前缀。恢复时**只**撤掉带这个前缀的那一条失败行，绝不误伤别的失败
    /// （居民状态行合并规则刻意让失败行不被普通信息盖掉，所以撤除必须自己来）。
    static let screenPrefix = "参考图"

    // MARK: 保真：绝不吞掉底层原因

    /// `Error` 的**保真**描述。
    ///
    /// Swift 的 `localizedDescription` 把一个不是 `LocalizedError` 的枚举桥接成 NSError，
    /// 只留下桥接码（`error 17`）——case 名与关联值全部丢失，这正是真机上那 10 条回执
    /// 只有一句"暂时不可用"的原因。`String(describing:)` 保留
    /// `transportFailure("curl-exit-28")` 这种可排障的原文。
    ///
    /// `URLError` 单独处理：它的 `errorDescription` 是"连不上"这类人话，丢掉了 `-1004`
    /// 这种可判定的码，而分类正是按码来的，所以把码提到外面。
    static func preservedReason(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "urlerror(\(urlError.errorCode))"
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        let described = String(describing: error)
        return described.isEmpty ? String(describing: type(of: error)) : described
    }

    // MARK: 传输失败：逐条具名

    /// 传输层失败 → 具名诊断。已知的 curl 退出码/传输阶段各给一个名字；
    /// **未知原因也照样逐字带出来**，绝不退回"失败"两个字。
    static func transportFailure(_ operation: Operation, error: Error) -> Fact {
        transportFact(operation, reason: preservedReason(error))
    }

    static func transportFact(_ operation: Operation, reason: String) -> Fact {
        let classification = classify(reason)
        return Fact(
            code: "\(operation.codePrefix)_\(classification.suffix)",
            reason: reason,
            message: "\(operation.label)\(classification.cause)：\(reason)。\(classification.guidance)",
            screen: "\(operation.screenLabel)\(classification.screenSuffix)：\(reason)",
            isConnectivity: classification.isConnectivity)
    }

    private struct Classification {
        let suffix: String
        /// 接在操作名后面的原因短语，例如 "超时（10 秒内没有连上）"。
        let cause: String
        /// "去哪里配"。
        let guidance: String
        /// 屏上那一句里跟在 `screenLabel` 后面的部分。
        let screenSuffix: String
        let isConnectivity: Bool
    }

    /// 直连出口的指引：这份工具链**刻意**绕过系统代理（`--proxy "" --noproxy "*"`，
    /// 为的是让 `--resolve` 钉住的公开地址真正生效、不被代理重新解析），所以在一个
    /// 只允许经代理出网的本机上它必然连不上。指引必须说清"去哪里配"，而不是让用户
    /// 反复重试。
    private static let directEgressGuidance =
        "这一步刻意绕过系统代理以保持地址校验，所以本机必须有一条直连出口；"
        + "请在网络层给本 app 放行 dns.google:443 与 commons.wikimedia.org:443"
        + "（或允许直连出网）。在配好之前参考图搜索不可用，不会假装在搜。"

    private static let directEgressScreen =
        "当前不可用：本机没有直连出口。请给 app 放行 dns.google:443 与 commons.wikimedia.org:443"

    private static func classify(_ reason: String) -> Classification {
        let lower = reason.lowercased()
        func contains(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }

        if contains("curl-exit-28", "timedout", "timed out", "timeout", "-1001") {
            return Classification(suffix: "timeout", cause: "超时（10 秒内没有连上）",
                guidance: directEgressGuidance, screenSuffix: directEgressScreen, isConnectivity: true)
        }
        if contains("curl-exit-6", "-1003", "dnsfailure", "could not resolve", "nodename nor servname") {
            return Classification(suffix: "dns_failed", cause: "域名解析失败",
                guidance: directEgressGuidance, screenSuffix: directEgressScreen, isConnectivity: true)
        }
        if contains("curl-exit-7", "-1004", "connection refused", "couldn't connect to the server",
                    "cannot connect to host", "not connected to the internet", "-1009", "-1005") {
            return Classification(suffix: "unreachable", cause: "连不上",
                guidance: directEgressGuidance, screenSuffix: directEgressScreen, isConnectivity: true)
        }
        if contains("curl-exit-35", "curl-exit-60", "ssl", "tls", "certificate", "-1200", "-1202") {
            return Classification(suffix: "tls_failed", cause: "TLS 握手/证书失败",
                guidance: "请检查本机时间、根证书与中间盒拦截（企业代理常做 TLS 解密）。",
                screenSuffix: "TLS/证书校验失败", isConnectivity: true)
        }
        if contains("curl-launch") {
            return Classification(suffix: "transport_missing", cause: "起不了本机的下载传输",
                guidance: "本机缺少可用的 /usr/bin/curl，或 app 沙盒不允许启动它；请修复后重试。",
                screenSuffix: "本机下载传输不可用", isConnectivity: false)
        }
        if contains("temporary-directory", "temporary-file", "curl-pipe", "malformed-response",
                    "no-response", "read") {
            return Classification(suffix: "local_io", cause: "本机传输阶段失败",
                guidance: "这是本机的进程/磁盘问题，不是搜索服务的问题；请重试，反复出现请重启 app。",
                screenSuffix: "本机传输阶段失败", isConnectivity: false)
        }
        return Classification(suffix: "transport_failed", cause: "传输失败",
            guidance: directEgressGuidance, screenSuffix: directEgressScreen, isConnectivity: true)
    }

    // MARK: 搜索响应的三种拒绝，各有各的名字

    /// 搜索响应不是 JSON。**判据不变**（仍然是拒绝，仍然不采用任何结果），
    /// 只是不再和"解析失败""服务器报错"共用一个码。
    static func searchNotJSON(mimeType: String) -> Fact {
        Fact(code: "reference_search_not_json", reason: "mime:\(mimeType)",
            message: "公开图片搜索返回的不是 JSON 内容（\(mimeType)），未采用任何结果；"
                + "多半是中继/门户页拦截，请检查网络层。",
            screen: "\(Operation.search.screenLabel)返回的不是 JSON（\(mimeType)）", isConnectivity: true)
    }

    /// 搜索响应无法解析。**判据不变**。
    static func searchUnparseable() -> Fact {
        Fact(code: "reference_search_unparseable", reason: "unparseable-json",
            message: "公开图片搜索返回的内容无法解析，未采用任何结果；请稍后重试。",
            screen: "\(Operation.search.screenLabel)返回的内容无法解析", isConnectivity: false)
    }

    /// 搜索服务自报结构化错误。**判据不变**（仍然是失败，绝不当作空结果），
    /// 但把服务端自己的 `code`/`info` 逐字带出来。
    static func searchAPIError(code: String?, info: String?) -> Fact {
        let reason = "api:\(code ?? "unknown")\(info.map { ": \($0)" } ?? "")"
        return Fact(code: "reference_search_api_error", reason: reason,
            message: "公开图片搜索服务返回错误 \(reason)，未采用任何结果；"
                + "这是搜索服务端拒绝（常见于查询词不被接受），换一个英文关键词再试。",
            screen: "\(Operation.search.screenLabel)服务返回错误（\(reason)）", isConnectivity: false)
    }

    // MARK: 已知不可用时的短回执（不是静默重试）

    /// 冷却期内不再重复撞墙，但**必须说清楚这一次没有发起搜索**。
    static func searchCoolingDown(fact: Fact, secondsRemaining: Int) -> Fact {
        Fact(code: fact.code, reason: fact.reason,
            message: "参考图搜索当前不可用（\(fact.reason)），\(secondsRemaining) 秒内不重复尝试，"
                + "所以这一次**没有**发起搜索。\(fact.message)",
            screen: "参考图搜索当前不可用：\(fact.reason)",
            isConnectivity: fact.isConnectivity)
    }

    // MARK: 结果为空 ≠ 失败

    /// "服务正常、但没有可用图片"——这是**成功**，不是失败。
    ///
    /// 真机缺陷形态之一就是把它当成失败，于是"没有找到"和"连不上"在用户那里变成
    /// 同一句话。两者必须永远不同：这个事实的 `ok` 是 true，也没有失败码。
    static let emptyResultsMessage =
        "没有找到可用图片；这不是失败，是搜索服务如实返回了空结果。不要编造图片链接，"
        + "可以换一个英文关键词，或直接询问用户。"

    static let emptyResultsScreenText = "参考图搜索已完成：没有找到可用图片。"

    /// 空结果要用**成功**回执上报，绝不套失败码。
    static func isEmptyResultsPayload(_ payload: [String: Any]) -> Bool {
        guard payload["ok"] as? Bool == true else { return false }
        guard let results = payload["results"] as? [[String: Any]] else { return false }
        return results.isEmpty
    }
}

/// 参考图链的**日志出口**。
///
/// 真机 2026-09-30/10-01 那 10 条失败在 app 系统日志里一行都没有 —— 只落在工具回执里，
/// 所以 `log show` 查 `找图|参考图|reference|search_wish` 零命中。这一条通道就是为了
/// 让同一个事实在日志里**查得到**。限流 64 条/进程，不构成刷屏压力。
@MainActor
enum WishReferenceLog {
    static let log = Logger(subsystem: "ai.gmgn.radio", category: "ResidentWishReference")
    private static var budget = 64

    /// 测试缝：设上之后每一行**同时**交给它，并把限流预算放到足够大，便于离线断言
    /// "这条事实真的落了日志"。生产里从没被调用，os.log 那一行照发（两个出口不是二选一）。
    private(set) static var testSink: (@MainActor (String) -> Void)?

    static func startTestCapture(_ sink: @escaping @MainActor (String) -> Void) {
        testSink = sink
        budget = 1_000_000
    }

    static func stopTestCapture() { testSink = nil }

    /// 整条消息一次性标成 public：os.log 默认把动态字符串打成 `<private>`，
    /// 那样真机上 grep 只会看到占位符，诊断等于没有。
    private static func emit(_ message: String, isError: Bool) {
        guard budget > 0 else { return }
        budget -= 1
        testSink?(message)
        if isError {
            log.error("\(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
    }

    static func failure(_ fact: WishReferenceDiagnosis.Fact, operation: String) {
        emit("[参考图链] \(operation) 失败 code=\(fact.code) reason=\(fact.reason)", isError: true)
    }

    /// 空结果**不是**失败，日志里也必须看得出来。
    static func emptyResults(query: String) {
        emit("[参考图链] 搜索完成，无可用结果（这不是失败）query=\(query)", isError: false)
    }

    /// 状态变化：可用/不可用。屏上出口由 `LiveCamWindowController` 接这条通知。
    static func availabilityChanged(_ text: String?, isFailure: Bool) {
        emit("[参考图链] 可用状态变化 不可用=\(isFailure) \(text ?? "已恢复")", isError: isFailure)
    }

    /// 冷却期内跳过一次尝试。**必须与真正的失败区分开**：这一次没有发请求。
    static func cooldownSkipped(code: String, reason: String) {
        emit("[参考图链] 冷却中，未发起搜索 code=\(code) reason=\(reason)", isError: false)
    }
}

/// 把"参考图搜索当前到底能不能用"送到**屏上**的唯一一条通道。
///
/// 为什么走 `NotificationCenter` 而不是直接在工具里调 UI：本线不得改
/// `App/GMGNRadioApp.swift`（点唱机线正在改它），而参考图工具的唯一构造点就在那里。
/// 通知是本仓库既有的解耦方式（`ResidentAutonomySwitch.didChangeNotification`、
/// `.propGenerationConfigurationDidChange` 同形），由 `LiveCamWindowController`
/// 在 `DesktopPresence` 侧接住并落到居民状态行 —— 于是"日志 + 屏上"两个出口都在，
/// 且不需要碰那条线。
enum WishReferenceAvailabilityNotice {
    static let didChangeNotification = Notification.Name("gmgnWishReferenceAvailabilityChanged")
    /// 屏上那一句；`nil` 表示恢复，屏上那条失败行应当撤掉。
    static let textKey = "text"
    /// 这一句是不是**失败**。空结果走 `false`（普通信息），绝不上失败行 ——
    /// "没有找到"与"连不上"在屏幕上也不许长成同一句话。
    static let isFailureKey = "isFailure"

    @MainActor
    static func postFailure(_ text: String) { post(text: text, isFailure: true) }

    @MainActor
    static func postInfo(_ text: String) { post(text: text, isFailure: false) }

    @MainActor
    static func postRecovered() { post(text: nil, isFailure: false) }

    @MainActor
    private static func post(text: String?, isFailure: Bool) {
        NotificationCenter.default.post(name: didChangeNotification, object: nil,
            userInfo: text.map { [textKey: $0, isFailureKey: isFailure] } ?? [isFailureKey: false])
    }
}
