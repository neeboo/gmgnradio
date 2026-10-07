// 网站链接解析的**行为与安全**判据 —— 与官方嵌入判据分开的一份。
//
// 它钉的是**新授权**下的第一条路：用户粘一个公开网站链接 → 受控解析器（内置、固定版本、
// 校验 sha256、不读 cookie、不查 PATH）→ 视频/音频流 + 请求头 → 原生播放。
//
// 手法与仓里既有离线 harness 一致：生产源码**原文**切片现编现跑；注入只在临时副本上做
// 手术。四条注入负对照（塞进 `--cookies-from-browser` / 放行任意域名 / 不再剥 cookie
// 请求头 / 把签名地址原样写进 note）都必须让内层判据变红。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resolverRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen/LinkResolver")

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS \(message)")
    } else {
        print("FAIL \(message)")
        failureCount += 1
    }
}

func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

let productionFiles = [
    "ScreenLinkContract.swift",
    "ScreenLinkRedaction.swift",
    "BundledHelperManifest.swift",
    "YtDlpInvocation.swift",
    "YtDlpResultParser.swift",
    "ScreenLinkProcess.swift",
    "ScreenLinkHelperLocator.swift",
    "ScreenLinkResolverService.swift",
]

let innerProgram = ##"""
import Foundation

var failuresTotal = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failuresTotal += 1 }
}
func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

@main struct Probe {
    static func main() async {
        // =========================================================
        // 断言 1：站点分类 —— 只认公开观看页，不认字节 CDN / 非 https
        // =========================================================
        expect(ScreenLinkSitePolicy.site(forPageURL: "https://www.youtube.com/watch?v=aqz-KE-bpKQ") == .youtube,
            "断言1：YouTube 观看页 ⇒ .youtube")
        expect(ScreenLinkSitePolicy.site(forPageURL: "https://youtu.be/aqz-KE-bpKQ") == .youtube,
            "断言1：youtu.be 短链 ⇒ .youtube")
        expect(ScreenLinkSitePolicy.site(forPageURL: "https://www.bilibili.com/video/BV1xx411c7mD") == .bilibili,
            "断言1：哔哩哔哩观看页 ⇒ .bilibili")
        expect(ScreenLinkSitePolicy.site(forPageURL: "https://www.twitch.tv/eslcs") == .twitch,
            "断言1：Twitch 频道页 ⇒ .twitch")
        expect(ScreenLinkSitePolicy.site(forPageURL: "https://www.twitch.tv/videos/123456") == .twitch,
            "断言1：Twitch VOD ⇒ .twitch")
        for bad in [
            "https://r1---sn-x.media.example/videoplayback?expire=1",
            "https://evil.example/watch?v=aqz-KE-bpKQ",
            "http://www.youtube.com/watch?v=aqz-KE-bpKQ",
            "https://www.youtube.com/feed/subscriptions",
            "https://www.twitch.tv/directory",
        ] {
            expect(ScreenLinkSitePolicy.site(forPageURL: bad) == nil,
                "断言1：不交给原生解析「\(bad)」")
        }

        // =========================================================
        // 断言 2：参数表里**结构上**没有读 cookie / 登录 / 绕地区的开关
        // =========================================================
        let request = ScreenLinkRequest(pageURL: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")
        let invocation = YtDlpInvocation.make(request: request, executablePath: "/controlled/yt-dlp")
        let joined = invocation.arguments.joined(separator: " ")
        expect(joined.contains("--ignore-config"), "断言2：不读用户配置（`--ignore-config`）")
        expect(joined.contains("--no-playlist"), "断言2：只处理这一个视频（`--no-playlist`）")
        expect(invocation.arguments.contains("--no-js-runtimes"),
            "断言2：清空辅助程序默认 JS 运行时发现，未接受控运行时也不查 PATH")
        let controlledJS = YtDlpInvocation.make(request: request, executablePath: "/controlled/yt-dlp",
            javascriptRuntimeName: "deno", javascriptRuntimePath: "/controlled/deno")
        let resetIndex = controlledJS.arguments.firstIndex(of: "--no-js-runtimes")
        let explicitIndex = controlledJS.arguments.firstIndex(of: "--js-runtimes")
        expect(resetIndex != nil && explicitIndex != nil && resetIndex! < explicitIndex!
            && controlledJS.arguments[explicitIndex! + 1] == "deno:/controlled/deno",
            "断言2：仅在清空默认运行时后添加显式受控 Deno 路径")
        expect(joined.contains("--no-cache-dir") && joined.contains("--no-update"),
            "断言2：不写缓存、不联网自更新")
        expect(joined.contains("--dump-single-json"), "断言2：只打印信息、不下载")
        expect(invocation.arguments.last == request.pageURL,
            "断言2：URL 是最后一个参数（前面有 `--` 分隔符，防止被当成开关）")
        for token in YtDlpInvocation.forbiddenArgumentTokens {
            expect(!joined.contains(token), "断言2：参数表里没有「\(token)」")
        }
        // 格式选择器：分轨优先、有合流兜底、带上高度上限。
        expect(YtDlpInvocation.formatSelector(for: request).contains("+ba") && YtDlpInvocation.formatSelector(for: request).hasPrefix("bv["),
            "断言2：默认走「最佳视频 + 最佳音频」（分轨）")
        let capped = ScreenLinkRequest(
            pageURL: request.pageURL, preferredMaximumHeight: 1080, allowsSeparateStreams: false
        )
        expect(YtDlpInvocation.formatSelector(for: capped) == "b[height<=1080]/b",
            "断言2：合流模式只挑自带声音且不超高度的")

        // =========================================================
        // 断言 3：分轨 JSON → 视频 + 音频 + 请求头（cookie 头必须被剥掉）
        // =========================================================
        let merged = json([
            "id": "aqz-KE-bpKQ", "title": "Sample", "extractor": "youtube",
            "duration": 120, "is_live": false, "availability": "public",
            "requested_formats": [
                ["format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none",
                 "width": 1920, "height": 1080, "fps": 30,
                 "url": "https://media.example/videoplayback?expire=9999999999&sig=SECRETSIG",
                 "http_headers": ["User-Agent": "UA", "Cookie": "session=SECRET"]],
                ["format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
                 "url": "https://media.example/audio?expire=9999999999",
                 "http_headers": ["User-Agent": "UA"]],
            ],
        ])
        guard case let .resolved(value) = YtDlpResultParser.parse(
            standardOutput: merged, pageURL: request.pageURL
        ) else {
            expect(false, "断言3：分轨 JSON 应该解析成功")
            print("INNER-FAILURES=\(failuresTotal)")
            if failuresTotal > 0 { exit(1) }
            return
        }
        expect(value.video.hasVideo && value.video.audioCodec == nil,
            "断言3：视频轨只带画面（format=137）")
        expect(value.audio?.hasAudio == true && value.audio?.hasVideo == false,
            "断言3：音频轨单独成一条（format=140）")
        expect(value.hasAudio, "断言3：分轨也算「有声音」（不是无声视频假通过）")
        expect(value.video.headers["User-Agent"] == "UA",
            "断言3：请求头被逐字保留（服务端要求它）")
        expect(!value.video.headers.keys.contains { $0.lowercased() == "cookie" },
            "断言3：`Cookie` 请求头被**结构上**剥掉（不代持用户凭据）")
        expect(value.expiresAt != nil, "断言3：地址自带的过期时刻被读成 Date（不是写进日志）")

        // 判据：note / 日志口径里**不许**出现签名地址与凭据。
        expect(!ScreenLinkRedaction.containsCredential(value.note),
            "断言3：工程口径的 note 是干净的（无地址、无 token）")
        let redacted = ScreenLinkRedaction.redacted(value.video.url)
        expect(!redacted.contains("?") && !redacted.contains("sig"),
            "断言3：脱敏后的地址只剩 scheme://host/path（实测 \(redacted)）")
        expect(ScreenLinkRedaction.containsCredential(value.video.url),
            "断言3：原始签名地址被判据认成「含临时授权」（证明脱敏不是空转）")

        // =========================================================
        // 断言 4：合流单文件 + 具名失败分类
        // =========================================================
        let muxed = json([
            "id": "x", "title": "Muxed", "extractor": "youtube", "availability": "public",
            "format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a",
            "url": "https://media.example/muxed?expire=9999999999",
            "http_headers": ["User-Agent": "UA"],
        ])
        let duplicateAudio = json(["extractor": "youtube", "requested_formats": [
            ["format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "url": "https://media.example/v"],
            ["format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a", "url": "https://media.example/a"]
        ]])
        if case let .resolved(combined) = YtDlpResultParser.parse(standardOutput: duplicateAudio, pageURL: request.pageURL) {
            expect(combined.video.hasAudio && combined.audio == nil, "断言4：合流视频后面的音频不能重复播放")
        } else { expect(false, "断言4：合流加额外音频回执应可解析") }
        if case let .resolved(mux) = YtDlpResultParser.parse(
            standardOutput: muxed, pageURL: request.pageURL
        ) {
            expect(mux.audio == nil && mux.video.hasAudio,
                "断言4：合流单文件 = 视频自带声音（没有第二条音频轨）")
        } else {
            expect(false, "断言4：合流 JSON 应该解析成功")
        }
        for (name, fixture, expected) in [
            ("DRM", json(["title": "d", "availability": "public", "_has_drm": true,
                          "url": "https://media.example/x", "vcodec": "avc1", "acodec": "mp4a"]),
             ScreenLinkFailure.drmProtected),
            ("需要登录", json(["title": "p", "availability": "private",
                            "url": "https://media.example/x", "vcodec": "avc1", "acodec": "mp4a"]),
             .loginRequired),
            ("会员限定", json(["title": "m", "availability": "subscriber_only",
                           "url": "https://media.example/x", "vcodec": "avc1", "acodec": "mp4a"]),
             .membersOnly),
            ("只有音频", json(["title": "a", "availability": "public",
                           "requested_formats": [["format_id": "140", "ext": "m4a", "vcodec": "none",
                                                  "acodec": "mp4a", "url": "https://media.example/a"]]]),
             .noPlayableStream),
        ] {
            if case let .failed(failure) = YtDlpResultParser.parse(
                standardOutput: fixture, pageURL: request.pageURL
            ) {
                expect(failure == expected, "断言4：\(name) ⇒ \(failure)")
            } else {
                expect(false, "断言4：\(name) 应该被判成失败")
            }
        }
        // 坏 JSON 也要具名，不许静默。
        if case .failed(.outputUnreadable) = YtDlpResultParser.parse(
            standardOutput: Data("not json".utf8), pageURL: request.pageURL
        ) {
            expect(true, "断言4：坏 JSON ⇒ outputUnreadable")
        } else {
            expect(false, "断言4：坏 JSON 应该被判成 outputUnreadable")
        }

        // stderr 分类：登录 / 会员 / 地区 / DRM / 删除 / 网络 / 超时。
        for (text, expected) in [
            ("ERROR: Private video. Sign in if you've been granted access", ScreenLinkFailure.loginRequired),
            ("ERROR: This video is available to this channel's members", ScreenLinkFailure.membersOnly),
            ("ERROR: The uploader has not made this video available in your country", ScreenLinkFailure.geoRestricted),
            ("ERROR: This video is DRM protected", ScreenLinkFailure.drmProtected),
            ("ERROR: Video unavailable", ScreenLinkFailure.notFound),
            ("ERROR: Unable to download webpage: getaddrinfo failed", ScreenLinkFailure.network),
            ("ERROR: Read timed out", ScreenLinkFailure.helperTimedOut),
        ] {
            expect(YtDlpResultParser.failure(terminationStatus: 1, standardError: text) == expected,
                "断言4：stderr「\(text.prefix(28))…」⇒ \(expected)")
        }
        // 摘要里也不许出现地址。
        let leakyStderr = "ERROR: unable to open https://media.example/v?expire=1&sig=SECRET"
        let summary = YtDlpResultParser.sanitizedSummary(leakyStderr)
        expect(!summary.contains("media.example") && !summary.contains("SECRET"),
            "断言4：stderr 摘要抹掉了地址与签名（实测 \(summary)）")

        // =========================================================
        // 断言 5：许可清单 —— 独立二进制是 **GPLv3+ 组合作品**，不是"只有 Unlicense"
        // =========================================================
        let manifest = BundledHelperManifest.pinned
        guard let ytdlp = manifest.helper(named: "yt-dlp") else {
            expect(false, "断言5：清单里必须有 yt-dlp")
            print("INNER-FAILURES=\(failuresTotal)")
            if failuresTotal > 0 { exit(1) }
            return
        }
        expect(ytdlp.upstreamLicenseSPDX == "Unlicense",
            "断言5：上游许可是 Unlicense（实测 \(ytdlp.upstreamLicenseSPDX)）")
        expect(ytdlp.distribution == .pyinstallerStandalone,
            "断言5：分发形态记的是独立二进制")
        expect(ytdlp.combinedWorkLicenseSPDX == "GPL-3.0-or-later",
            "断言5：独立二进制是组合作品 GPLv3+（实测 \(ytdlp.combinedWorkLicenseSPDX)）")
        expect(ytdlp.combinedWorkLicenseSPDX != ytdlp.upstreamLicenseSPDX,
            "断言5：**没有**把 GPL 组合作品写成只有 Unlicense")
        expect(manifest.noticesFileRequired && manifest.noticesPath.contains("THIRD_PARTY_LICENSES"),
            "断言5：分发必须带第三方许可声明")
        for component in ["meriyah", "astring", "Python", "ffmpeg"] {
            expect(manifest.components.contains { $0.name == component },
                "断言5：第三方组件「\(component)」在清单里")
        }
        expect(manifest.helper(named: "deno")?.distribution == .javascriptRuntime,
            "断言5：YouTube 解签所需的 JS 运行时也在受控清单里")

        // =========================================================
        // 断言 6：定位器 —— 只查受控路径，未钉哈希在生产里不许执行
        // =========================================================
        let fakeHelperDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-link-helper-\(UUID())")
        try? FileManager.default.createDirectory(at: fakeHelperDir, withIntermediateDirectories: true)
        let fakeHelper = fakeHelperDir.appendingPathComponent("yt-dlp")
        try? FileManager.default.copyItem(atPath: "/bin/echo", toPath: fakeHelper.path)
        expect(ScreenLinkResolverService.bundledDenoPath(
            bundleHelpersDirectory: nil, managedHelpersDirectory: nil) == nil,
            "断言6：缺少受控 Deno 时不会从 PATH 发现运行时")
        let fakeDeno = fakeHelperDir.appendingPathComponent("deno")
        try? FileManager.default.copyItem(atPath: "/bin/echo", toPath: fakeDeno.path)
        expect(ScreenLinkResolverService.bundledDenoPath(
            bundleHelpersDirectory: fakeHelperDir.path, managedHelpersDirectory: nil) == nil,
            "断言6：Deno 哈希不匹配时不会执行运行时")

        let missing = ScreenLinkHelperLocator(
            bundleHelpersDirectory: nil, managedHelpersDirectory: nil,
            devOverridePath: nil, allowDevOverride: false
        ).locate()
        if case .missing = missing {
            expect(true, "断言6：没有任何内置副本 ⇒ 具名 missing（不是去 PATH 找）")
        } else {
            expect(false, "断言6：应该报 missing")
        }

        // 生产 + 清单**未钉哈希** ⇒ 拒绝执行（哪怕文件真的在、真的可执行）。
        // 运行时的 yt-dlp 现在钉死了（见 test-screen-link-helper-lock），所以这里显式
        // 造一份空哈希的清单，把"忘了钉哈希不会悄悄变成可执行路径"这条判据钉住。
        func manifestWithYTDLPSHA(_ sha: String) -> BundledHelperManifest {
            let base = BundledHelperManifest.pinned
            return BundledHelperManifest(
                helpers: base.helpers.map { helper in
                    guard helper.name == "yt-dlp" else { return helper }
                    return BundledHelperManifest.Helper(
                        name: helper.name, version: helper.version, sha256: sha,
                        distribution: helper.distribution, sourceURL: helper.sourceURL,
                        upstreamLicenseSPDX: helper.upstreamLicenseSPDX,
                        combinedWorkLicenseSPDX: helper.combinedWorkLicenseSPDX,
                        licenseNote: helper.licenseNote
                    )
                },
                components: base.components, noticesFileRequired: base.noticesFileRequired,
                noticesPath: base.noticesPath
            )
        }
        let unpinnedProduction = ScreenLinkHelperLocator(
            manifest: manifestWithYTDLPSHA(""),
            bundleHelpersDirectory: fakeHelperDir.path, managedHelpersDirectory: nil,
            devOverridePath: nil, allowDevOverride: false
        ).locate()
        if case .integrityFailure(.helperIntegrityMismatch) = unpinnedProduction {
            expect(true, "断言6：生产路径下未钉哈希的内置副本被拒（宁可放不了，也不跑未校验的东西）")
        } else {
            expect(false, "断言6：未钉哈希的内置副本应该被拒")
        }

        // 开发覆盖：显式绝对路径 + 允许覆盖 ⇒ 放行，且回执**如实标出**这是开发覆盖。
        let devLocation = ScreenLinkHelperLocator(
            bundleHelpersDirectory: nil, managedHelpersDirectory: nil,
            devOverridePath: fakeHelper.path, allowDevOverride: true
        ).locate()
        if case let .found(location) = devLocation {
            expect(location.isDevOverride && !location.isPinned,
                "断言6：开发覆盖被如实标记（isDevOverride=\(location.isDevOverride)）")
        } else {
            expect(false, "断言6：显式开发覆盖应该被放行")
        }
        // 哈希不匹配 ⇒ 具名失败（注入一份被改过的副本）。钉死的清单必须真的在比摘要。
        let tampered = manifestWithYTDLPSHA(String(repeating: "0", count: 64))
        let tamperedLookup = ScreenLinkHelperLocator(
            manifest: tampered, bundleHelpersDirectory: fakeHelperDir.path,
            managedHelpersDirectory: nil, devOverridePath: nil, allowDevOverride: false
        ).locate()
        if case .integrityFailure(.helperIntegrityMismatch) = tamperedLookup {
            expect(true, "断言6：内容与钉死哈希不一致 ⇒ 具名 integrityFailure")
        } else {
            expect(false, "断言6：哈希不一致应该被拒")
        }
        // 钉死的清单必须**接受**一份哈希逐字节相同的副本：证明它比的不是"非空"而是摘要本身。
        let matchingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-link-helper-match-\(UUID())")
        try? FileManager.default.createDirectory(at: matchingDir, withIntermediateDirectories: true)
        let matchingFile = matchingDir.appendingPathComponent("yt-dlp")
        try? Data("pinned-helper-bytes".utf8).write(to: matchingFile)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: matchingFile.path
        )
        if let digest = ScreenLinkIntegrity.sha256Hex(ofFileAt: matchingFile.path) {
            let matchingLookup = ScreenLinkHelperLocator(
                manifest: manifestWithYTDLPSHA(digest),
                bundleHelpersDirectory: matchingDir.path, managedHelpersDirectory: nil,
                devOverridePath: nil, allowDevOverride: false
            ).locate()
            if case let .found(location) = matchingLookup {
                expect(location.isPinned && !location.isDevOverride && location.sha256 == digest,
                    "断言6：与钉死哈希逐字节一致的副本被接受（isPinned=true）")
            } else {
                expect(false, "断言6：哈希一致的副本应该被接受（实测 \(matchingLookup)）")
            }
        } else {
            expect(false, "断言6：算不出测试副本的 sha256")
        }

        // =========================================================
        // 断言 7：编排 —— 缺 helper / 超时 / 取消 / 非零退出都变成具名回执
        // =========================================================
        let jsonData = merged
        let emptyLocator = ScreenLinkHelperLocator(
            bundleHelpersDirectory: nil, managedHelpersDirectory: nil,
            devOverridePath: nil, allowDevOverride: false
        )
        let missingService = ScreenLinkResolverService(
            locator: emptyLocator,
            runner: FakeScreenLinkProcessRunner(output: jsonData)
        )
        if case .failed(.missingHelper) = await missingService.resolve(request) {
            expect(true, "断言7：缺 helper ⇒ 具名 missingHelper（不是去 PATH 找）")
        } else {
            expect(false, "断言7：缺 helper 应该具名")
        }

        let devLocator = ScreenLinkHelperLocator(
            bundleHelpersDirectory: nil, managedHelpersDirectory: nil,
            devOverridePath: fakeHelper.path, allowDevOverride: true
        )
        let successService = ScreenLinkResolverService(
            locator: devLocator, runner: FakeScreenLinkProcessRunner(output: jsonData)
        )
        if case let .resolved(value) = await successService.resolve(request) {
            expect(value.video.hasVideo && value.hasAudio,
                "断言7：编排成功 ⇒ 有画面、有声音")
        } else {
            expect(false, "断言7：编排应该成功")
        }

        let timeoutService = ScreenLinkResolverService(
            locator: devLocator,
            runner: FakeScreenLinkProcessRunner(timedOut: true)
        )
        if case .failed(.helperTimedOut) = await timeoutService.resolve(request) {
            expect(true, "断言7：超时 ⇒ helperTimedOut（不是一直转圈）")
        } else {
            expect(false, "断言7：超时应该具名")
        }

        let cancelService = ScreenLinkResolverService(
            locator: devLocator,
            runner: FakeScreenLinkProcessRunner(cancelled: true)
        )
        if case .failed(.cancelled) = await cancelService.resolve(request) {
            expect(true, "断言7：取消 ⇒ cancelled")
        } else {
            expect(false, "断言7：取消应该具名")
        }

        let failService = ScreenLinkResolverService(
            locator: devLocator,
            runner: FakeScreenLinkProcessRunner(
                status: 1, error: "ERROR: Video unavailable"
            )
        )
        if case .failed(.notFound) = await failService.resolve(request) {
            expect(true, "断言7：非零退出 + 删除原文 ⇒ notFound")
        } else {
            expect(false, "断言7：非零退出应该被分类")
        }

        // 入口判据：非 https / 不支持站点在**没跑任何进程**时就拒。
        let guardRunner = FakeScreenLinkProcessRunner(output: jsonData)
        let guardService = ScreenLinkResolverService(locator: devLocator, runner: guardRunner)
        if case .failed(.unsupportedScheme) = await guardService.resolve(
            ScreenLinkRequest(pageURL: "http://www.youtube.com/watch?v=aqz-KE-bpKQ")
        ) {
            expect(true, "断言7：http ⇒ unsupportedScheme")
        } else {
            expect(false, "断言7：http 应该在入口被拒")
        }
        if case .failed(.unsupportedSite) = await guardService.resolve(
            ScreenLinkRequest(pageURL: "https://evil.example/watch?v=aqz-KE-bpKQ")
        ) {
            expect(true, "断言7：不支持站点 ⇒ unsupportedSite")
        } else {
            expect(false, "断言7：不支持站点应该在入口被拒")
        }
        expect(guardRunner.requests.isEmpty,
            "断言7：入口判据在**没有跑进程**时就拒（不浪费一次解析）")

        print("INNER-FAILURES=\(failuresTotal)")
        if failuresTotal > 0 { exit(1) }
    }
}
"""##

// ---------------------------------------------------------------------------
// 现编现跑
// ---------------------------------------------------------------------------

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-link-resolver-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func runCapturing(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func runProbe(patches: [(file: String, from: String, to: String)] = [])
    throws -> (status: Int32, output: String, note: String)
{
    let directory = temporary.appendingPathComponent("probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [String] = []
    for name in productionFiles {
        var text = try read(resolverRoot.appendingPathComponent(name))
        for patch in patches where patch.file == name {
            guard text.contains(patch.from) else {
                return (-1, "", "注入锚点在 \(name) 里找不到：\(patch.from)")
            }
            text = text.replacingOccurrences(of: patch.from, with: patch.to)
        }
        let destination = directory.appendingPathComponent(name)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        sources.append(destination.path)
    }
    let program = directory.appendingPathComponent("Probe.swift")
    try innerProgram.write(to: program, atomically: true, encoding: .utf8)
    let binary = directory.appendingPathComponent("probe")
    let compile = try runCapturing(
        "/usr/bin/swiftc", ["-j1", "-parse-as-library"] + sources + [program.path, "-o", binary.path]
    )
    guard compile.status == 0 else {
        return (-1, compile.output,
                "探针没编起来（exit \(compile.status)）："
                    + compile.output.split(separator: "\n")
                        .filter { $0.contains("error:") }.prefix(4)
                        .joined(separator: " | "))
    }
    let run = try runCapturing(binary.path, [])
    return (run.status, run.output, "")
}

func reportFailures(_ output: String, limit: Int = 4) {
    for line in output.split(separator: "\n").filter({ $0.hasPrefix("FAIL") }).prefix(limit) {
        print("  · \(line)")
    }
}

// MARK: 原件必须全绿

let clean = try runProbe()
check(clean.note.isEmpty && clean.status == 0 && clean.output.contains("INNER-FAILURES=0"),
    "解析安全/行为判据在**原件**上全部通过"
        + "（exit \(clean.status)，"
        + "\(clean.output.split(separator: "\n").last(where: { $0.hasPrefix("INNER-FAILURES=") }) ?? "没有结论")）"
        + (clean.note.isEmpty ? "" : " —— \(clean.note)"))
reportFailures(clean.output, limit: 8)

// MARK: 注入负对照 —— 每一条都必须红

/// ① 参数表里塞进 `--cookies-from-browser` ⇒ 断言 2 必须红。
let cookieInjection = try runProbe(patches: [(
    file: "YtDlpInvocation.swift",
    from: "            \"--dump-single-json\",\n        ]",
    to: "            \"--dump-single-json\",\n            \"--cookies-from-browser\", \"safari\",\n        ]"
)])
check(cookieInjection.note.isEmpty && cookieInjection.status != 0
        && cookieInjection.output.contains("参数表里没有"),
    "断言2（注入负对照「读浏览器 cookies」）：探针必须红在禁令牌这一条上"
        + "（exit \(cookieInjection.status)）"
        + (cookieInjection.note.isEmpty ? "" : " —— \(cookieInjection.note)"))
reportFailures(cookieInjection.output)

/// ② 站点判据放行任意域名 ⇒ 断言 1 / 7 必须红。
let siteBypassInjection = try runProbe(patches: [(
    file: "ScreenLinkRedaction.swift",
    from: "        return rules.first(where: { $0.hosts.contains(host) && $0.isWatchPath(url) })?.site",
    to: "        return rules.first(where: { $0.hosts.contains(host) && $0.isWatchPath(url) })?.site ?? .other"
)])
check(siteBypassInjection.note.isEmpty && siteBypassInjection.status != 0
        && siteBypassInjection.output.contains("evil.example"),
    "断言1（注入负对照「放行任意域名」）：探针必须红在 evil.example 被放行这一条上"
        + "（exit \(siteBypassInjection.status)）"
        + (siteBypassInjection.note.isEmpty ? "" : " —— \(siteBypassInjection.note)"))
reportFailures(siteBypassInjection.output)

/// ③ 不再剥 `Cookie` 请求头 ⇒ 断言 3 必须红。
let headerInjection = try runProbe(patches: [(
    file: "YtDlpResultParser.swift",
    from: "        let forbidden = [\"cookie\", \"authorization\", \"set-cookie\", \"proxy-authorization\"]",
    to: "        let forbidden: [String] = []"
)])
check(headerInjection.note.isEmpty && headerInjection.status != 0
        && headerInjection.output.contains("Cookie"),
    "断言3（注入负对照「不再剥 cookie 请求头」）：探针必须红在 cookie 这一条上"
        + "（exit \(headerInjection.status)）"
        + (headerInjection.note.isEmpty ? "" : " —— \(headerInjection.note)"))
reportFailures(headerInjection.output)

/// ④ 把签名地址原样写进 note ⇒ 断言 3 的"note 干净"必须红。
let noteInjection = try runProbe(patches: [(
    file: "YtDlpResultParser.swift",
    from: "        var note = \"extractor=\\(extractor.isEmpty ? \"unknown\" : extractor)\"",
    to: "        var note = \"extractor=\\(extractor.isEmpty ? \"unknown\" : extractor) url=\\(videoStream.url)\""
)])
check(noteInjection.note.isEmpty && noteInjection.status != 0
        && noteInjection.output.contains("note 是干净的"),
    "断言3（注入负对照「签名地址写进工程 note」）：探针必须红在 note 干净这一条上"
        + "（exit \(noteInjection.status)）"
        + (noteInjection.note.isEmpty ? "" : " —— \(noteInjection.note)"))
reportFailures(noteInjection.output)

print(failureCount == 0 ? "PASS 解析安全/行为判据全部通过" : "FAIL 解析判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
