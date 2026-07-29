import Foundation
import Testing
@testable import GMGNRadio

@Suite
struct MusicProviderWebLoginPolicyTests {
    @Test
    func neteaseLoginRequiresMusicUserCookieFromOfficialDomain() throws {
        let cookies = [
            try cookie(name: "MUSIC_U", value: "session", domain: ".music.163.com"),
            try cookie(name: "tracker", value: "ignore", domain: ".example.com"),
        ]

        let header = MusicProviderWebLoginPolicy.cookieHeader(
            for: .netease,
            cookies: cookies
        )

        #expect(header == "MUSIC_U=session")
    }

    @Test
    func qqLoginRequiresIdentityAndPlaybackKey() throws {
        let incompleteCookies = [
            try cookie(name: "uin", value: "o12345", domain: ".qq.com"),
            try cookie(name: "p_skey", value: "account-only", domain: ".qq.com"),
        ]
        let playableCookies = incompleteCookies + [
            try cookie(name: "qm_keyst", value: "playback", domain: ".y.qq.com"),
        ]

        #expect(
            MusicProviderWebLoginPolicy.cookieHeader(
                for: .qqMusic,
                cookies: incompleteCookies
            ) == nil
        )
        #expect(
            MusicProviderWebLoginPolicy.cookieHeader(
                for: .qqMusic,
                cookies: playableCookies
            ) == "uin=o12345; qm_keyst=playback; p_skey=account-only"
        )
    }

    @Test
    func loginWindowOnlyKeepsProviderWebsitesInsideTheApp() {
        #expect(
            MusicProviderWebLoginPolicy.allowsInAppNavigation(
                URL(string: "https://music.163.com/#/login")!,
                for: .netease
            )
        )
        #expect(
            MusicProviderWebLoginPolicy.allowsInAppNavigation(
                URL(string: "https://xui.ptlogin2.qq.com/cgi-bin/xlogin")!,
                for: .qqMusic
            )
        )
        #expect(
            !MusicProviderWebLoginPolicy.allowsInAppNavigation(
                URL(string: "https://example.com/phishing")!,
                for: .qqMusic
            )
        )
    }

    private func cookie(
        name: String,
        value: String,
        domain: String
    ) throws -> HTTPCookie {
        try #require(
            HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
            ])
        )
    }
}
