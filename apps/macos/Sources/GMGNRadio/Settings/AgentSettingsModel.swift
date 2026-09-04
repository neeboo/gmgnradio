import Foundation
import Observation

struct BailianRealtimeModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct BailianRealtimeVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

enum BailianRealtimeOptions {
    static let models = [
        BailianRealtimeModelOption(
            id: "qwen3.5-omni-flash-realtime",
            title: "Qwen3.5 Omni Flash"
        ),
        BailianRealtimeModelOption(
            id: "qwen3.5-omni-plus-realtime",
            title: "Qwen3.5 Omni Plus"
        ),
        BailianRealtimeModelOption(
            id: "qwen3-omni-flash-realtime",
            title: "Qwen3 Omni Flash"
        ),
    ]

    static let defaultModel = models[0].id

    private static let qwen35Voices = [
        BailianRealtimeVoiceOption(
            id: "Tina",
            title: "甜甜 · 温暖自然"
        ),
        BailianRealtimeVoiceOption(
            id: "Theo Calm",
            title: "予安 · 舒缓治愈"
        ),
        BailianRealtimeVoiceOption(
            id: "Ethan",
            title: "晨煦 · 阳光活力"
        ),
        BailianRealtimeVoiceOption(
            id: "Serena",
            title: "苏瑶 · 温柔"
        ),
        BailianRealtimeVoiceOption(
            id: "Maia",
            title: "四月 · 知性"
        ),
        BailianRealtimeVoiceOption(
            id: "Harvey",
            title: "厚 · 低沉温和"
        ),
        BailianRealtimeVoiceOption(
            id: "Momo",
            title: "茉兔 · 活泼"
        ),
        BailianRealtimeVoiceOption(
            id: "Ryan",
            title: "甜茶 · 戏感"
        ),
    ]

    private static let qwen3Voices = [
        BailianRealtimeVoiceOption(
            id: "Cherry",
            title: "芊悦 · 明亮亲切"
        ),
        BailianRealtimeVoiceOption(
            id: "Serena",
            title: "苏瑶 · 温柔"
        ),
        BailianRealtimeVoiceOption(
            id: "Ethan",
            title: "晨煦 · 阳光活力"
        ),
        BailianRealtimeVoiceOption(
            id: "Chelsie",
            title: "千雪 · 二次元"
        ),
        BailianRealtimeVoiceOption(
            id: "Momo",
            title: "茉兔 · 活泼"
        ),
        BailianRealtimeVoiceOption(
            id: "Vivian",
            title: "十三 · 灵动"
        ),
        BailianRealtimeVoiceOption(
            id: "Moon",
            title: "月白 · 率性"
        ),
        BailianRealtimeVoiceOption(
            id: "Maia",
            title: "四月 · 知性"
        ),
    ]

    static func voices(
        for model: String
    ) -> [BailianRealtimeVoiceOption] {
        model.hasPrefix("qwen3.5-")
            ? qwen35Voices
            : qwen3Voices
    }

    static func defaultVoice(for model: String) -> String {
        voices(for: model)[0].id
    }

    static var defaultVoice: String {
        defaultVoice(for: defaultModel)
    }
}

struct RealtimeVoiceConfiguration: Equatable, Sendable {
    let provider: RealtimeDJProvider
    let apiKey: String?
    let agentID: String?
    let conversationToken: String?
    let voiceID: String?
    let model: String?
    let appID: String?
    let accessToken: String?
    let resourceID: String?
    let microphoneDeviceID: String?

    init(
        provider: RealtimeDJProvider,
        apiKey: String?,
        agentID: String?,
        conversationToken: String?,
        voiceID: String?,
        model: String?,
        appID: String?,
        accessToken: String?,
        resourceID: String?,
        microphoneDeviceID: String? = nil
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.agentID = agentID
        self.conversationToken = conversationToken
        self.voiceID = voiceID
        self.model = model
        self.appID = appID
        self.accessToken = accessToken
        self.resourceID = resourceID
        self.microphoneDeviceID = microphoneDeviceID
    }

    var isReadyToConnect: Bool {
        switch provider {
        case .bailian:
            return apiKey?.isEmpty == false
                && model?.isEmpty == false
                && voiceID?.isEmpty == false
        case .doubao:
            return appID?.isEmpty == false
                && accessToken?.isEmpty == false
                && resourceID?.isEmpty == false
        case .elevenLabs:
            return agentID?.isEmpty == false
                || conversationToken?.isEmpty == false
        }
    }
}

final class RealtimeVoicePreferences {
    static let providerKey = "voice.provider"
    static let agentIDKey = "voice.elevenlabs.agentID"
    static let voiceIDKey = "voice.elevenlabs.voiceID"
    static let conversationTokenKey =
        "voice.elevenlabs.conversationToken"
    static let apiKeyKey = "voice.elevenlabs.apiKey"
    static let microphoneDeviceIDKey = "voice.microphoneDeviceID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RealtimeVoiceConfiguration {
        let provider = defaults.string(forKey: Self.providerKey)
            .flatMap(RealtimeDJProvider.init(rawValue:))
            ?? .elevenLabs
        return load(provider: provider)
    }

    func loadMetadata() -> RealtimeVoiceConfiguration {
        let provider = defaults.string(forKey: Self.providerKey)
            .flatMap(RealtimeDJProvider.init(rawValue:))
            ?? .elevenLabs
        return load(provider: provider)
    }

    func loadMetadata(
        provider: RealtimeDJProvider
    ) -> RealtimeVoiceConfiguration {
        load(provider: provider)
    }

    func load(
        provider: RealtimeDJProvider
    ) -> RealtimeVoiceConfiguration {
        return RealtimeVoiceConfiguration(
            provider: provider,
            apiKey: normalized(
                defaults.string(forKey: key(provider, "apiKey"))
            ),
            agentID: normalized(
                defaults.string(forKey: key(provider, "agentID"))
            ),
            conversationToken: normalized(
                defaults.string(forKey: key(provider, "conversationToken"))
            ),
            voiceID: normalized(
                defaults.string(forKey: key(provider, "voiceID"))
            ),
            model: normalized(
                defaults.string(forKey: key(provider, "model"))
            ),
            appID: normalized(
                defaults.string(forKey: key(provider, "appID"))
            ),
            accessToken: normalized(
                defaults.string(forKey: key(provider, "accessToken"))
            ),
            resourceID: normalized(
                defaults.string(forKey: key(provider, "resourceID"))
            ),
            microphoneDeviceID: normalized(
                defaults.string(forKey: Self.microphoneDeviceIDKey)
            )
        )
    }

    func save(
        _ configuration: RealtimeVoiceConfiguration
    ) throws {
        defaults.set(
            configuration.provider.rawValue,
            forKey: Self.providerKey
        )
        let provider = configuration.provider
        defaults.set(
            configuration.agentID,
            forKey: key(provider, "agentID")
        )
        defaults.set(
            configuration.voiceID,
            forKey: key(provider, "voiceID")
        )
        defaults.set(
            configuration.model,
            forKey: key(provider, "model")
        )
        defaults.set(
            configuration.appID,
            forKey: key(provider, "appID")
        )
        defaults.set(
            configuration.resourceID,
            forKey: key(provider, "resourceID")
        )
        defaults.set(
            configuration.microphoneDeviceID,
            forKey: Self.microphoneDeviceIDKey
        )
        defaults.set(
            configuration.apiKey,
            forKey: key(provider, "apiKey")
        )
        defaults.set(
            configuration.conversationToken,
            forKey: key(provider, "conversationToken")
        )
        defaults.set(
            configuration.accessToken,
            forKey: key(provider, "accessToken")
        )
    }

    private func key(
        _ provider: RealtimeDJProvider,
        _ field: String
    ) -> String {
        "voice.\(provider.rawValue).\(field)"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RealtimeVoiceConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case listening
    case speaking
    case failed(String)

    var canCompleteConnectionAttempt: Bool {
        switch self {
        case .connecting, .connected, .listening, .speaking:
            true
        case .disconnected, .failed:
            false
        }
    }
}

@MainActor
@Observable
final class RealtimeVoiceStatusStore {
    static let shared = RealtimeVoiceStatusStore()

    var state: RealtimeVoiceConnectionState = .disconnected
}

@MainActor
@Observable
final class AgentSettingsModel {
    var codexState: CodexAccountState = .signedOut
    var hostPrompt: String
    var isWorking = false
    var message: String?
    var hasError = false
    var realtimeProvider: RealtimeDJProvider
    var elevenLabsAgentID: String
    var elevenLabsConversationToken: String
    var elevenLabsVoiceID: String
    var voiceAPIKey: String
    var voiceModel: String
    var voiceAppID: String
    var voiceAccessToken: String
    var voiceResourceID: String
    var voiceMicrophoneDeviceID: String
    let voiceMicrophoneDevices: [BailianMicrophoneDeviceOption]
    let defaultMicrophoneDeviceID: String?
    var takeoverEnabled: Bool
    var planningModel: String

    // MARK: Agent 聊天后端（Live Cam 文字聊天）

    var installedConversationBackendIDs:
        Set<AgentConversationBackendID> = []
    var selectedConversationBackendID: AgentConversationBackendID = .codex
    var autoSpeakAgentReplies = true

    var voiceID: String {
        get { elevenLabsVoiceID }
        set { elevenLabsVoiceID = newValue }
    }

    private let account: any CodexAccountServicing
    private let preferences: DJAgentPreferences
    private let voicePreferences: RealtimeVoicePreferences

    init(
        account: any CodexAccountServicing = CodexAgentAccountService(),
        preferences: DJAgentPreferences = DJAgentPreferences(),
        voicePreferences: RealtimeVoicePreferences =
            RealtimeVoicePreferences(),
        microphoneDevices: [BailianMicrophoneDeviceOption] =
            BailianMicrophoneDeviceCatalog.availableDevices(),
        defaultMicrophoneDeviceID: String? =
            BailianMicrophoneDeviceCatalog.defaultDeviceID()
    ) {
        self.account = account
        self.preferences = preferences
        self.voicePreferences = voicePreferences
        voiceMicrophoneDevices = microphoneDevices
        self.defaultMicrophoneDeviceID = defaultMicrophoneDeviceID
        hostPrompt = preferences.hostPrompt()
        takeoverEnabled = preferences.takeoverEnabled()
        planningModel = preferences.planningModel() ?? ""
        let voice = voicePreferences.loadMetadata()
        realtimeProvider = voice.provider
        let resolvedVoiceModel: String
        if voice.provider == .bailian {
            resolvedVoiceModel =
                voice.model ?? BailianRealtimeOptions.defaultModel
        } else {
            resolvedVoiceModel = voice.model ?? ""
        }
        elevenLabsAgentID = voice.agentID ?? ""
        elevenLabsConversationToken = voice.conversationToken ?? ""
        elevenLabsVoiceID = voice.voiceID
            ?? (
                voice.provider == .bailian
                    ? BailianRealtimeOptions.defaultVoice(
                        for: resolvedVoiceModel
                    )
                    : ""
            )
        voiceAPIKey = voice.apiKey ?? ""
        voiceModel = resolvedVoiceModel
        voiceAppID = voice.appID ?? ""
        voiceAccessToken = voice.accessToken ?? ""
        voiceResourceID = voice.resourceID ?? ""
        voiceMicrophoneDeviceID = voice.microphoneDeviceID ?? ""

        let conversationService = AgentConversationService.shared
        installedConversationBackendIDs = Set(
            conversationService.installedBackends().map(\.kind)
        )
        selectedConversationBackendID =
            conversationService.effectiveBackendID
        autoSpeakAgentReplies =
            conversationService.preferenceStore.autoSpeakReplies
    }

    func refreshConversationBackends() {
        let conversationService = AgentConversationService.shared
        installedConversationBackendIDs = Set(
            conversationService.installedBackends().map(\.kind)
        )
    }

    func selectConversationBackend(
        _ id: AgentConversationBackendID
    ) {
        let conversationService = AgentConversationService.shared
        // 只切换选择，保留各后端已保存的 session id，
        // 便于切回时继续原会话。
        conversationService.selectBackend(id)
        selectedConversationBackendID =
            conversationService.effectiveBackendID
        message = nil
        hasError = false
    }

    func setAutoSpeakAgentReplies(_ enabled: Bool) {
        autoSpeakAgentReplies = enabled
        AgentConversationService.shared.setAutoSpeakReplies(enabled)
    }

    func isConversationBackendInstalled(
        _ id: AgentConversationBackendID
    ) -> Bool {
        installedConversationBackendIDs.contains(id)
    }

    var conversationBackendStatusText: String {
        let installed = installedConversationBackendIDs
        if installed.isEmpty {
            return "未检测到任何已安装的 Agent 后端。"
        }
        return "已安装："
            + installed
            .sorted {
                (AgentConversationBackends.preferredOrder.firstIndex(of: $0) ?? 0)
                    < (AgentConversationBackends.preferredOrder.firstIndex(of: $1) ?? 0)
            }
            .map { AgentConversationBackends.backend(for: $0).displayName }
            .joined(separator: "、")
    }

    func load() async {
        codexState = await account.status()
    }

    func connectCodex() async {
        isWorking = true
        message = nil
        hasError = false
        defer { isWorking = false }
        do {
            try await account.login()
            codexState = await account.status()
            message = codexState.isSignedIn
                ? "Codex 已连接。"
                : "登录尚未完成，请重试。"
            hasError = !codexState.isSignedIn
        } catch {
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            hasError = true
        }
    }

    func disconnectCodex() async {
        isWorking = true
        message = nil
        hasError = false
        defer { isWorking = false }
        do {
            try await account.logout()
            codexState = await account.status()
            message = codexState == .signedOut
                ? "Codex 已退出登录。"
                : "退出登录尚未完成，请重试。"
            hasError = codexState != .signedOut
        } catch {
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            hasError = true
        }
    }

    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        codexState = await account.status()
    }

    func savePrompt() {
        preferences.saveHostPrompt(hostPrompt)
        saveAgentConfiguration(showMessage: false)
        hostPrompt = preferences.hostPrompt()
        message = "DJ 偏好已保存。"
        hasError = false
    }

    func saveAgentConfiguration(showMessage: Bool = true) {
        preferences.saveTakeoverEnabled(takeoverEnabled)
        preferences.savePlanningModel(planningModel)
        planningModel = preferences.planningModel() ?? ""
        if showMessage {
            message = takeoverEnabled
                ? "DJ 接管已开启。"
                : "DJ 接管已关闭。"
            hasError = false
        }
    }

    func saveVoiceConfiguration() -> RealtimeVoiceConfiguration? {
        let configuration = RealtimeVoiceConfiguration(
            provider: realtimeProvider,
            apiKey: normalized(voiceAPIKey),
            agentID: normalized(elevenLabsAgentID),
            conversationToken: normalized(
                elevenLabsConversationToken
            ),
            voiceID: normalized(elevenLabsVoiceID),
            model: normalized(voiceModel),
            appID: normalized(voiceAppID),
            accessToken: normalized(voiceAccessToken),
            resourceID: normalized(voiceResourceID),
            microphoneDeviceID: normalized(voiceMicrophoneDeviceID)
        )

        guard validate(configuration) else {
            hasError = true
            return nil
        }

        do {
            try voicePreferences.save(configuration)
            message = "实时语音配置已保存。"
            hasError = false
            return configuration
        } catch {
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            hasError = true
            return nil
        }
    }

    func selectRealtimeProvider(_ provider: RealtimeDJProvider) {
        realtimeProvider = provider
        apply(voicePreferences.loadMetadata(provider: provider))
        message = nil
        hasError = false
    }

    func selectBailianModel(_ model: String) {
        voiceModel = model
        let voices = BailianRealtimeOptions.voices(for: model)
        if !voices.contains(where: { $0.id == voiceID }) {
            voiceID = BailianRealtimeOptions.defaultVoice(for: model)
        }
        message = nil
        hasError = false
    }

    private func apply(_ configuration: RealtimeVoiceConfiguration) {
        elevenLabsAgentID = configuration.agentID ?? ""
        elevenLabsConversationToken =
            configuration.conversationToken ?? ""
        voiceAPIKey = configuration.apiKey ?? ""
        if configuration.provider == .bailian {
            voiceModel =
                configuration.model ?? BailianRealtimeOptions.defaultModel
            let voices = BailianRealtimeOptions.voices(for: voiceModel)
            elevenLabsVoiceID = configuration.voiceID
                .flatMap { selected in
                    voices.contains(where: { $0.id == selected })
                        ? selected
                        : nil
                }
                ?? BailianRealtimeOptions.defaultVoice(for: voiceModel)
        } else {
            elevenLabsVoiceID = configuration.voiceID ?? ""
            voiceModel = configuration.model ?? ""
        }
        voiceAppID = configuration.appID ?? ""
        voiceAccessToken = configuration.accessToken ?? ""
        voiceResourceID = configuration.resourceID ?? ""
        voiceMicrophoneDeviceID = configuration.microphoneDeviceID ?? ""
    }

    var systemMicrophoneLabel: String {
        guard
            let defaultMicrophoneDeviceID,
            let device = voiceMicrophoneDevices.first(
                where: { $0.id == defaultMicrophoneDeviceID }
            )
        else {
            return "跟随系统"
        }
        return "跟随系统（\(device.name)）"
    }

    private func validate(
        _ configuration: RealtimeVoiceConfiguration
    ) -> Bool {
        switch configuration.provider {
        case .elevenLabs:
            if configuration.conversationToken != nil {
                return true
            }
            guard
                let agentID = configuration.agentID,
                agentID.hasPrefix("agent_"),
                agentID.count > "agent_".count
            else {
                message =
                    "填写真实的 ElevenLabs Agent ID（以 agent_ 开头），或填写会话令牌。"
                return false
            }
            return true
        case .bailian:
            guard configuration.apiKey != nil else {
                message = "填写百炼 API Key。"
                return false
            }
            guard configuration.model != nil else {
                message = "填写百炼实时语音模型。"
                return false
            }
            return true
        case .doubao:
            guard configuration.appID != nil else {
                message = "填写豆包 RTC App ID。"
                return false
            }
            guard configuration.accessToken != nil else {
                message = "填写豆包 RTC Access Token。"
                return false
            }
            guard configuration.resourceID != nil else {
                message = "填写豆包实时语音 Resource ID。"
                return false
            }
            return true
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CodexAccountState {
    var isSignedIn: Bool {
        if case .signedIn = self {
            return true
        }
        return false
    }
}
