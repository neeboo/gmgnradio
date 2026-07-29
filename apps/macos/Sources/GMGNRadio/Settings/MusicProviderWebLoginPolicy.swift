import Foundation

enum MusicProviderWebLoginPolicy {
    private static let neteaseCookiePriority = [
        "MUSIC_U",
        "__csrf",
        "NMTID",
        "MUSIC_A",
        "__remember_me",
        "_ntes_nuid",
        "_ntes_nnid",
        "WEVNSM",
        "WNMCID",
        "JSESSIONID-WYYY",
    ]

    private static let qqCookiePriority = [
        "uin",
        "qqmusic_uin",
        "wxuin",
        "login_type",
        "qm_keyst",
        "qqmusic_key",
        "music_key",
        "p_skey",
        "skey",
        "psrf_qqopenid",
        "psrf_qqunionid",
        "psrf_qqaccess_token",
        "psrf_qqrefresh_token",
        "wxopenid",
        "wxunionid",
        "wxrefresh_token",
        "wxskey",
        "p_uin",
        "ptcz",
        "RK",
    ]

    static func loginURL(for providerID: MusicProviderID) -> URL? {
        switch providerID {
        case .netease:
            URL(string: "https://music.163.com/#/login")
        case .qqMusic:
            URL(string: "https://y.qq.com/n/ryqq/profile")
        default:
            nil
        }
    }

    static func cookieHeader(
        for providerID: MusicProviderID,
        cookies: [HTTPCookie]
    ) -> String? {
        let priority: [String]
        switch providerID {
        case .netease:
            priority = neteaseCookiePriority
        case .qqMusic:
            priority = qqCookiePriority
        default:
            return nil
        }

        let matchingCookies = cookies.filter {
            isProviderCookieDomain($0.domain, for: providerID)
        }
        var valuesByName: [String: String] = [:]
        for cookie in matchingCookies where !cookie.value.isEmpty {
            valuesByName[cookie.name] = cookie.value
        }

        guard hasCompleteLogin(
            valuesByName,
            for: providerID
        ) else {
            return nil
        }

        return priority.compactMap { name in
            valuesByName[name].map { "\(name)=\($0)" }
        }
        .joined(separator: "; ")
    }

    static func allowsInAppNavigation(
        _ url: URL,
        for providerID: MusicProviderID
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return isProviderCookieDomain(host, for: providerID)
    }

    static func includes(
        _ cookie: HTTPCookie,
        for providerID: MusicProviderID
    ) -> Bool {
        isProviderCookieDomain(cookie.domain, for: providerID)
    }

    private static func hasCompleteLogin(
        _ cookies: [String: String],
        for providerID: MusicProviderID
    ) -> Bool {
        switch providerID {
        case .netease:
            return !(cookies["MUSIC_U"] ?? "").isEmpty
        case .qqMusic:
            let identityNames = ["uin", "qqmusic_uin", "wxuin", "p_uin"]
            let playbackKeyNames = [
                "qm_keyst",
                "qqmusic_key",
                "music_key",
                "wxskey",
            ]
            let hasIdentity = identityNames.contains {
                !(cookies[$0] ?? "").filter(\.isNumber).isEmpty
            }
            let hasPlaybackKey = playbackKeyNames.contains {
                !(cookies[$0] ?? "").isEmpty
            }
            return hasIdentity && hasPlaybackKey
        default:
            return false
        }
    }

    private static func isProviderCookieDomain(
        _ domain: String,
        for providerID: MusicProviderID
    ) -> Bool {
        let host = domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        switch providerID {
        case .netease:
            return matches(host, root: "163.com")
                || matches(host, root: "netease.com")
        case .qqMusic:
            return matches(host, root: "qq.com")
                || matches(host, root: "weixin.qq.com")
        default:
            return false
        }
    }

    private static func matches(_ host: String, root: String) -> Bool {
        host == root || host.hasSuffix(".\(root)")
    }
}
