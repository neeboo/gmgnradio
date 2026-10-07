import Foundation

// MARK: - yt-dlp 输出 → 跨平台回执（纯函数、可离线驱动）

/// 把 yt-dlp `--dump-single-json` 的 stdout 读成 `ScreenLinkResolution`，把它的 stderr
/// 读成**具名失败**。
///
/// 这个类型**不启动进程、不碰网络**，所以它能被离线判据（真 JSON 夹具 + 注入）完整驱动。
/// 进程与超时/取消在 `PosixScreenLinkProcessRunner` 那一侧，两者用 `ScreenLinkResolution`
/// 对接 —— 这正是"解析协议/请求/回执/取消/错误跨平台"的落地方式。
enum YtDlpResultParser {
    /// 解析信息 JSON。
    ///
    /// - Parameters:
    ///   - standardOutput: `--dump-single-json` 的原始 stdout。
    ///   - pageURL: 用户给的公开网站链接（用于站点归类与回执里的"放的是哪个页面"）。
    ///   - now: 注入时钟（测试用）。
    static func parse(
        standardOutput: Data,
        pageURL: String,
        now: Date = Date()
    ) -> ScreenLinkResolution {
        guard !standardOutput.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: standardOutput)) as? [String: Any]
        else { return .failed(.outputUnreadable("json")) }
        // `--no-playlist` 之下不该拿到列表；真拿到了就取第一条，而不是把整个列表当成一个视频。
        var info = object
        if let entries = object["entries"] as? [[String: Any]], let first = entries.first {
            info = first
        }

        if let failure = availabilityFailure(info) { return .failed(failure) }

        let video = info["vcodec"] as? String
        let audio = info["acodec"] as? String
        let isLive = (info["is_live"] as? Bool) ?? (info["live_status"] as? String == "is_live")

        // 分轨：`requested_formats` 是 yt-dlp 真正选中的那几条；`requested_downloads`
        // 在"合并"时只有一条**没有 url** 的组合记录，不能拿它当流。
        let candidates: [[String: Any]]
        if let requested = info["requested_formats"] as? [[String: Any]], !requested.isEmpty {
            candidates = requested
        } else {
            candidates = [info]
        }

        var videoStream: ScreenLinkStream?
        var audioStream: ScreenLinkStream?
        for candidate in candidates {
            let stream = makeStream(candidate, topLevelHeaders: info["http_headers"] as? [String: Any])
            guard let stream else { continue }
            if stream.hasVideo, videoStream == nil {
                videoStream = stream
                // 合流：这条自带声音，就不再有独立音频轨。
                if stream.hasAudio { audioStream = nil }
            } else if stream.hasAudio, !stream.hasVideo, audioStream == nil {
                audioStream = stream
            }
        }
        // 顶层是"视频自带声音"的那种单文件时，`makeStream(info)` 已经带上了 acodec。
        if videoStream == nil, let muxed = makeStream(info, topLevelHeaders: info["http_headers"] as? [String: Any]),
           muxed.hasVideo {
            videoStream = muxed
        }
        guard let videoStream else {
            return .failed(.noPlayableStream)
        }
        // A muxed video already owns its soundtrack; a later audio candidate must not duplicate it.
        if videoStream.hasAudio { audioStream = nil }
        // `vcodec`/`acodec` 在顶层可能只是"这种站点声称的"；以实际选中的流为准。
        _ = video
        _ = audio

        let extractor = (info["extractor"] as? String) ?? (info["extractor_key"] as? String) ?? ""
        let site = ScreenLinkSitePolicy.site(forPageURL: pageURL) ?? site(forExtractor: extractor)
        let title = (info["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = (info["duration"] as? NSNumber)?.doubleValue
        let expiresAt = expiry(of: videoStream.url)

        var note = "extractor=\(extractor.isEmpty ? "unknown" : extractor)"
        note += " live=\(isLive)"
        note += " video=\(videoStream.technicalDescription)"
        if let audioStream { note += " audio=\(audioStream.technicalDescription)" }
        note += " muxed=\(audioStream == nil && videoStream.hasAudio)"
        note += " expires=\(expiresAt == nil ? "unknown" : "known")"

        return .resolved(ScreenLinkResolutionValue(
            pageURL: pageURL,
            site: site,
            title: (title?.isEmpty == false) ? title! : site.displayName,
            durationSeconds: (duration?.isFinite == true && duration! > 0) ? duration : nil,
            isLive: isLive,
            video: videoStream,
            audio: audioStream,
            resolvedAt: now,
            expiresAt: expiresAt,
            extractor: extractor,
            note: note
        ))
    }

    // MARK: 逐字段读取

    private static func makeStream(
        _ object: [String: Any], topLevelHeaders: [String: Any]?
    ) -> ScreenLinkStream? {
        guard let rawURL = (object["url"] as? String) ?? (object["manifest_url"] as? String),
              !rawURL.isEmpty
        else { return nil }
        let vcodec = normalizeCodec(object["vcodec"] as? String)
        let acodec = normalizeCodec(object["acodec"] as? String)
        let protocolName = (object["protocol"] as? String)?.lowercased() ?? ""
        let isManifest = protocolName.contains("m3u8") || protocolName.contains("dash")
            || (object["manifest_url"] as? String) != nil
        let headers = sanitizedHeaders(
            (object["http_headers"] as? [String: Any]) ?? topLevelHeaders
        )
        return ScreenLinkStream(
            url: rawURL,
            formatID: (object["format_id"] as? String) ?? "",
            container: (object["ext"] as? String) ?? "",
            videoCodec: vcodec,
            audioCodec: acodec,
            width: (object["width"] as? NSNumber)?.intValue,
            height: (object["height"] as? NSNumber)?.intValue,
            frameRate: (object["fps"] as? NSNumber)?.doubleValue,
            bandwidth: (object["tbr"] as? NSNumber)?.intValue,
            isManifest: isManifest,
            hasVideo: vcodec != nil,
            hasAudio: acodec != nil,
            headers: headers
        )
    }

    /// `"none"` / 空串 = 这条流没有这一路的编码。
    private static func normalizeCodec(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return trimmed
    }

    /// **只留下无凭据的请求头**。
    ///
    /// 解析器从不产出 cookie / Authorization；即便某天它产出了，这里也**结构上丢掉**，
    /// 绝不让它们被播放器带上、更不会被写进日志。这是"不读浏览器账号 cookies"这条线
    /// 在原生播放这一侧的兜底。
    private static func sanitizedHeaders(_ raw: [String: Any]?) -> [String: String] {
        guard let raw else { return [:] }
        let forbidden = ["cookie", "authorization", "set-cookie", "proxy-authorization"]
        var headers: [String: String] = [:]
        for (key, value) in raw {
            guard let text = value as? String, !text.isEmpty else { continue }
            guard !forbidden.contains(key.lowercased()) else { continue }
            headers[key] = text
        }
        return headers
    }

    /// 从地址里读解析器给的过期时刻（YouTube 的 `expire`）。读的是**数值**，不保存地址。
    private static func expiry(of url: String) -> Date? {
        guard let components = URLComponents(string: url),
              let raw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
              let epoch = Double(raw), epoch.isFinite, epoch > 0
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    private static func site(forExtractor extractor: String) -> ScreenLinkSite {
        let lowered = extractor.lowercased()
        if lowered.contains("youtube") || lowered.contains("youtu") { return .youtube }
        if lowered.contains("bilibili") || lowered.contains("bili") { return .bilibili }
        if lowered.contains("twitch") { return .twitch }
        return .other
    }

    // MARK: 可用性 → 具名失败

    /// 信息 JSON 自己声明的"放不放得了"。**先于任何格式选择**判：一条私享视频就算
    /// 解析出了地址也不该被当成成功。
    private static func availabilityFailure(_ info: [String: Any]) -> ScreenLinkFailure? {
        if (info["_has_drm"] as? Bool) == true { return .drmProtected }
        // 某些提取器把 `has_drm` 放在单个格式上。
        if let formats = info["formats"] as? [[String: Any]],
           formats.contains(where: { ($0["has_drm"] as? Bool) == true }) {
            return .drmProtected
        }
        let availability = ((info["availability"] as? String) ?? "").lowercased()
        switch availability {
        case "private", "needs_auth", "unlisted_needs_auth": return .loginRequired
        case "premium_only", "subscriber_only": return .membersOnly
        case "public", "unlisted", "": break
        default: break
        }
        if let liveStatus = (info["live_status"] as? String)?.lowercased(),
           liveStatus == "is_upcoming" {
            return .noPlayableStream
        }
        return nil
    }

    // MARK: stderr → 具名失败

    /// 把 yt-dlp 的 stderr 读成**具名失败**。`terminationStatus == 0` 时返回 `nil`
    /// （stdout 那一侧才是权威）。
    ///
    /// 摘要只取**第一行 `ERROR:`**，并把地址与 token 抹掉 —— 日志里也不许出现它们。
    static func failure(terminationStatus: Int32, standardError: String) -> ScreenLinkFailure? {
        guard terminationStatus != 0 else { return nil }
        let lines = standardError.split(separator: "\n").map(String.init)
        let errorLine = lines.first(where: { $0.contains("ERROR:") }) ?? lines.first ?? ""
        let lowered = errorLine.lowercased()
        if lowered.contains("timed out") || lowered.contains("timeout") { return .helperTimedOut }
        if lowered.contains("members-only") || lowered.contains("members only")
            || lowered.contains("join this channel") || lowered.contains("channel's members") {
            return .membersOnly
        }
        if lowered.contains("private video") || lowered.contains("sign in")
            || lowered.contains("login") || lowered.contains("requires authentication")
            || lowered.contains("account") && lowered.contains("cookies") {
            return .loginRequired
        }
        if lowered.contains("in your country") || lowered.contains("not available in your")
            || lowered.contains("geo") || lowered.contains("blocked in your country") {
            return .geoRestricted
        }
        if lowered.contains("drm") { return .drmProtected }
        if lowered.contains("video unavailable") || lowered.contains("does not exist")
            || lowered.contains("has been removed") || lowered.contains("404")
            || lowered.contains("not found") {
            return .notFound
        }
        if lowered.contains("unsupported url") { return .unsupportedSite("") }
        if lowered.contains("getaddrinfo") || lowered.contains("unable to download webpage")
            || lowered.contains("connection") || lowered.contains("network")
            || lowered.contains("temporary failure") || lowered.contains("ssl") {
            return .network
        }
        return .helperFailed(code: terminationStatus, summary: sanitizedSummary(errorLine))
    }

    /// 把一行摘要里的地址与常见 token 抹成占位符，并截断。
    static func sanitizedSummary(_ text: String) -> String {
        var output = text
        // 抹掉 http(s) 地址（保留 host 都不必 —— 直接换成 <url>）。
        if let regex = try? NSRegularExpression(pattern: "https?://\\S+") {
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output),
                withTemplate: "<url>"
            )
        }
        for token in ["expire=", "sig=", "signature=", "token=", "cookie=", "authorization="] {
            if let range = output.range(of: token, options: .caseInsensitive) {
                let tail = output[range.upperBound...]
                let end = tail.firstIndex(where: { $0 == "&" || $0 == " " }) ?? tail.endIndex
                output.replaceSubrange(range.lowerBound..<end, with: "\(token)<redacted>")
            }
        }
        return String(output.prefix(240))
    }
}
