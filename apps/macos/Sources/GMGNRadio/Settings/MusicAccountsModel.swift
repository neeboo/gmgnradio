import Foundation
import Observation

extension Notification.Name {
    static let musicAccountDidChange = Notification.Name(
        "ai.gmgn.radio.music-account-did-change"
    )
    static let musicLibrarySyncDidFinish = Notification.Name(
        "ai.gmgn.radio.music-library-sync-did-finish"
    )
}

@MainActor
@Observable
final class MusicAccountsModel {
    private static let connectedProvidersDefaultsKey =
        "music.connected-provider-ids"

    var neteaseState: MusicAccountAuthorizationState = .disconnected
    var qqMusicState: MusicAccountAuthorizationState = .disconnected
    var appleMusicState: MusicAccountAuthorizationState = .disconnected
    var isWorking = false
    var message: String?
    var hasError = false

    private let service: any MusicAccountServicing
    private let webLogin: any MusicProviderWebAuthenticating
    private let appleMusic: AppleMusicSource
    private let defaults: UserDefaults

    init(
        service: any MusicAccountServicing = MusicAccountCommandService.live(),
        webLogin: any MusicProviderWebAuthenticating = MusicProviderWebLoginController(),
        appleMusic: AppleMusicSource = AppleMusicSource(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.webLogin = webLogin
        self.appleMusic = appleMusic
        self.defaults = defaults
    }

    func load() async {
        let connected = Set(
            defaults.stringArray(
                forKey: Self.connectedProvidersDefaultsKey
            ) ?? []
        )
        neteaseState = connected.contains(MusicProviderID.netease.rawValue)
            ? .connected
            : .disconnected
        qqMusicState = connected.contains(MusicProviderID.qqMusic.rawValue)
            ? .connected
            : .disconnected
        appleMusicState = state(from: await appleMusic.access())
    }

    func sync(_ providerID: MusicProviderID) async {
        guard state(for: providerID) == .connected else {
            return
        }
        isWorking = true
        show(message: "正在同步 \(providerName(providerID))歌单…")
        publishAccountChange(providerID, connected: true)
    }

    func handleSyncCompletion(_ notification: Notification) {
        guard
            let rawProviderID = notification.userInfo?["providerID"]
                as? String
        else {
            return
        }
        let providerID = MusicProviderID(rawValue: rawProviderID)
        isWorking = false
        if let error = notification.userInfo?["errorDescription"] as? String {
            show(error: MusicLibrarySyncUIError.failed(error))
            return
        }
        let count = notification.userInfo?["playlistCount"] as? Int ?? 0
        show(message: "\(providerName(providerID))已同步 \(count) 个歌单。")
    }

    func connect(_ providerID: MusicProviderID) async {
        guard providerID == .netease || providerID == .qqMusic else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        setState(.authorizing, for: providerID)
        show(message: "请在官方页面完成登录。")
        do {
            await webLogin.clearSession(providerID: providerID)
            let cookie = try await webLogin.login(providerID: providerID)
            show(message: "正在同步 \(providerName(providerID))…")
            try await service.connect(
                providerID: providerID,
                cookie: cookie
            )
            rememberConnection(providerID, connected: true)
            setState(.connected, for: providerID)
            publishAccountChange(providerID, connected: true)
            show(message: "\(providerName(providerID))已连接。")
        } catch MusicProviderWebLoginError.cancelled {
            setState(.disconnected, for: providerID)
            show(message: "已取消登录。")
        } catch {
            setState(.disconnected, for: providerID)
            show(error: error)
        }
    }

    func disconnect(_ providerID: MusicProviderID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.disconnect(providerID: providerID)
            await webLogin.clearSession(providerID: providerID)
            rememberConnection(providerID, connected: false)
            setState(.disconnected, for: providerID)
            publishAccountChange(providerID, connected: false)
            show(message: "\(providerName(providerID))已断开。")
        } catch {
            show(error: error)
        }
    }

    func authorizeAppleMusic() async {
        isWorking = true
        defer { isWorking = false }
        appleMusicState = state(
            from: await appleMusic.requestAuthorization()
        )
        if appleMusicState == .connected {
            rememberConnection(.appleMusic, connected: true)
            publishAccountChange(.appleMusic, connected: true)
            show(message: "Apple Music 已连接。")
        } else {
            show(error: MusicAccountUIError.appleMusicUnavailable)
        }
    }

    private func publishAccountChange(
        _ providerID: MusicProviderID,
        connected: Bool
    ) {
        NotificationCenter.default.post(
            name: .musicAccountDidChange,
            object: nil,
            userInfo: [
                "providerID": providerID.rawValue,
                "connected": connected,
            ]
        )
    }

    private func rememberConnection(
        _ providerID: MusicProviderID,
        connected: Bool
    ) {
        var providerIDs = Set(
            defaults.stringArray(
                forKey: Self.connectedProvidersDefaultsKey
            ) ?? []
        )
        if connected {
            providerIDs.insert(providerID.rawValue)
        } else {
            providerIDs.remove(providerID.rawValue)
        }
        defaults.set(
            providerIDs.sorted(),
            forKey: Self.connectedProvidersDefaultsKey
        )
    }

    func state(for providerID: MusicProviderID) -> MusicAccountAuthorizationState {
        switch providerID {
        case .netease:
            neteaseState
        case .qqMusic:
            qqMusicState
        case .appleMusic:
            appleMusicState
        default:
            .unavailable
        }
    }

    func providerName(_ providerID: MusicProviderID) -> String {
        switch providerID {
        case .netease:
            "网易云音乐"
        case .qqMusic:
            "QQ 音乐"
        case .appleMusic:
            "Apple Music"
        default:
            "音乐服务"
        }
    }

    private func setState(
        _ state: MusicAccountAuthorizationState,
        for providerID: MusicProviderID
    ) {
        switch providerID {
        case .netease:
            neteaseState = state
        case .qqMusic:
            qqMusicState = state
        case .appleMusic:
            appleMusicState = state
        default:
            break
        }
    }

    private func state(
        from access: MusicSourceAccess
    ) -> MusicAccountAuthorizationState {
        switch access {
        case .local:
            .connected
        case let .accountRequired(state):
            state
        }
    }

    private func show(message: String) {
        self.message = message
        hasError = false
    }

    private func show(error: Error) {
        message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        hasError = true
    }
}

private enum MusicAccountUIError: Error, LocalizedError {
    case appleMusicUnavailable

    var errorDescription: String? {
        "Apple Music 未授权，或当前账号不能播放目录内容。"
    }
}

private enum MusicLibrarySyncUIError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}
