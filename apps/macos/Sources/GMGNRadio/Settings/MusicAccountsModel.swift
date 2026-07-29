import Foundation
import Observation

@MainActor
@Observable
final class MusicAccountsModel {
    var neteaseState: MusicAccountAuthorizationState = .disconnected
    var qqMusicState: MusicAccountAuthorizationState = .disconnected
    var appleMusicState: MusicAccountAuthorizationState = .disconnected
    var cookie = ""
    var editingProvider: MusicProviderID?
    var isWorking = false
    var message: String?
    var hasError = false

    private let service: MusicAccountCommandService
    private let appleMusic: AppleMusicSource

    init(
        service: MusicAccountCommandService = .live(),
        appleMusic: AppleMusicSource = AppleMusicSource()
    ) {
        self.service = service
        self.appleMusic = appleMusic
    }

    func load() async {
        async let netease = service.status(providerID: .netease)
        async let qqMusic = service.status(providerID: .qqMusic)
        neteaseState = await netease
        qqMusicState = await qqMusic
        appleMusicState = state(from: await appleMusic.access())
    }

    func beginConnecting(_ providerID: MusicProviderID) {
        cookie = ""
        editingProvider = providerID
        message = nil
        hasError = false
    }

    func connect() async {
        guard let providerID = editingProvider else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.connect(
                providerID: providerID,
                cookie: cookie
            )
            cookie = ""
            editingProvider = nil
            setState(.connected, for: providerID)
            show(message: "\(providerName(providerID))已连接。")
        } catch {
            show(error: error)
        }
    }

    func disconnect(_ providerID: MusicProviderID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.disconnect(providerID: providerID)
            setState(.disconnected, for: providerID)
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
            show(message: "Apple Music 已连接。")
        } else {
            show(error: MusicAccountUIError.appleMusicUnavailable)
        }
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
