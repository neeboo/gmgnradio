import Foundation
import Observation

/// Portable voice choices are independent of the retired realtime-conversation SDK.
@MainActor
final class RustSpeechPreferences {
    private let settings: RustProductSettingsClient
    private let secrets: any ProductSpeechSecretStore
    private let legacyDefaults: UserDefaults
    private var observedCredentials: [String: Bool] = [:]
    private static var savingProviders = Set<String>()
    init(defaults: UserDefaults = E2ERuntime.defaults, settings: RustProductSettingsClient = .shared,
         secrets: any ProductSpeechSecretStore = FileSpeechSecretStore()) {
        self.settings = settings; self.secrets = secrets; legacyDefaults = defaults
        settings.bootstrap(legacy: RustProductSettingsClient.legacySnapshot(defaults))
    }
    private func credential(provider: String) -> String {
        if !secrets.legacyImported(provider: provider) {
            let old = legacyDefaults.string(forKey: "speech.rust.\(provider).apiKey")
                ?? (provider == "bailian" ? legacyDefaults.string(forKey: "voice.bailian.apiKey") : nil)
            do {
                if secrets.read(provider: provider) == nil, let old { try secrets.write(provider: provider, key: old) }
                try secrets.markLegacyImported(provider: provider)
            } catch { /* No plaintext preference writer or credential logging. */ }
        }
        let key = secrets.read(provider: provider) ?? ""
        observedCredentials[provider] = !key.isEmpty
        return key
    }
    func credentialConfigured(provider: RustVoiceProvider) -> Bool? { observedCredentials[provider.rawValue] }
    func provider(for purpose: String, includesEnvironment: Bool = true) -> RustVoiceProvider {
        let configured = purpose == "asr" ? settings.confirmed?.values.asrProvider : settings.confirmed?.values.ttsProvider
        let explicit = includesEnvironment ? ProcessInfo.processInfo.environment["GMGN_VOICE_\(purpose.uppercased())_PROVIDER"] : nil
        return (explicit ?? configured).flatMap(RustVoiceProvider.init(rawValue:)) ?? .bailian
    }
    func configuration(for purpose: String, includesEnvironment: Bool = true, includesSecrets: Bool = true) -> RustVoiceConfiguration {
        configuration(provider: provider(for: purpose, includesEnvironment: includesEnvironment), for: purpose, includesEnvironment: includesEnvironment, includesSecrets: includesSecrets)
    }
    func configuration(provider: RustVoiceProvider, for purpose: String, includesEnvironment: Bool = true, includesSecrets: Bool = true) -> RustVoiceConfiguration {
        let env = includesEnvironment ? ProcessInfo.processInfo.environment : [:]
        let prefix = "GMGN_VOICE_\(provider.rawValue.uppercased())_"
        let values = settings.confirmed?.values
        let selected = purpose == "asr" ? values?.asrProvider : values?.ttsProvider
        let model = selected == provider.rawValue ? (purpose == "asr" ? values?.asrModel : values?.ttsModel) : nil
        let voice = selected == provider.rawValue ? values?.ttsVoice : nil
        let key = includesSecrets ? (env[prefix + "API_KEY"] ?? (provider == .elevenlabs ? env["ELEVENLABS_API_KEY"] : nil) ?? credential(provider: provider.rawValue)) : ""
        return RustVoiceConfiguration(provider: provider, apiKey: key, voiceID: env[prefix + "VOICE_ID"] ?? voice ?? (provider == .bailian ? "Cherry" : ""),
            model: env[prefix + purpose.uppercased() + "_MODEL"] ?? model)
    }
    func save(_ configuration: RustVoiceConfiguration, for purpose: String) async throws {
        guard ["tts","asr"].contains(purpose), let model = configuration.model else { throw RustProductSettingsClient.SettingsError.invalidProtocol }
        var changes: [String: Any] = [purpose + "Provider":configuration.provider.rawValue, purpose + "Model":model]
        if purpose == "tts" { changes["ttsVoice"] = configuration.voiceID }
        // Credentials cross only the private native file boundary, never this JSON request.
        let provider = configuration.provider.rawValue
        guard Self.savingProviders.insert(provider).inserted else { throw RustProductSettingsClient.SettingsError.unavailable }
        defer { Self.savingProviders.remove(provider) }
        let previousKey = secrets.read(provider: provider) ?? ""
        try secrets.write(provider: provider, key: configuration.apiKey)
        do { _ = try await settings.apply(changes); observedCredentials[provider] = !configuration.apiKey.isEmpty }
        catch {
            try secrets.write(provider: provider, key: previousKey)
            throw error
        }
    }
}

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

    var isReadyForResidentTranscription: Bool {
        provider == .bailian && apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
    var takeoverEnabled: Bool
    var planningModel: String

    // MARK: 居民人格与后台思考预算

    /// 独立于 DJ hostPrompt 的居民人格；保存后下一轮注入 Codex/DSH 居民会话。
    var residentPersona: String
    /// 本次居民会话滚动一小时内的后台自主思考预算（0...6，默认 6），可读写。
    /// 额度随循环实例存活，不跨循环重建或重启保留；实际 loop 预算由循环接线方读取。
    var backgroundTurnsPerHour: Int

    // MARK: Agent 聊天后端（Live Cam 文字聊天）

    var installedConversationBackendIDs:
        Set<AgentConversationBackendID> = []
    var selectedConversationBackendID: AgentConversationBackendID = .codex
    var autoSpeakAgentReplies = true
    private let account: any CodexAccountServicing
    private let preferences: DJAgentPreferences
    private let residentPreferences: ResidentPreferences

    init(
        account: any CodexAccountServicing = CodexAgentAccountService(),
        preferences: DJAgentPreferences = DJAgentPreferences(),
        residentPreferences: ResidentPreferences = ResidentPreferences()
    ) {
        self.account = account
        self.preferences = preferences
        self.residentPreferences = residentPreferences
        hostPrompt = preferences.hostPrompt()
        takeoverEnabled = preferences.takeoverEnabled()
        planningModel = preferences.planningModel() ?? ""
        residentPersona = residentPreferences.persona
        backgroundTurnsPerHour =
            residentPreferences.backgroundTurnsPerHour
        let conversationService = AgentConversationService.shared
        installedConversationBackendIDs = Set(
            conversationService.installedBackends(refresh: true).map(\.kind)
        )
        selectedConversationBackendID =
            conversationService.effectiveBackendID
        autoSpeakAgentReplies =
            conversationService.preferenceStore.autoSpeakReplies
    }

    func refreshConversationBackends() {
        let conversationService = AgentConversationService.shared
        installedConversationBackendIDs = Set(
            conversationService.installedBackends(refresh: true).map(\.kind)
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
            return "还没有安装可用的对话模型。"
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
        let prompt = hostPrompt
        Task { do { try await preferences.saveHostPrompt(prompt); hostPrompt = preferences.hostPrompt(); message = "DJ 偏好已保存。"; hasError = false } catch { message = "设置未保存，请检查后台连接。"; hasError = true } }
        saveAgentConfiguration(showMessage: false)
    }

    /// 保存居民人格。人格独立于 DJ hostPrompt；居民会话每轮重新读取，保存后
    /// 下一轮生效，切换空间仍保留。设置页保存后另行发出既有自主设置通知。
    func saveResidentPersona() {
        let persona = residentPersona
        Task { do { try await residentPreferences.savePersona(persona); residentPersona = residentPreferences.persona; message = "居民人格已保存，下一轮思考生效。"; hasError = false; NotificationCenter.default.post(name: .init("gmgnResidentAutonomyChanged"), object: nil) } catch { message = "设置未保存，请检查后台连接。"; hasError = true } }
    }

    /// 保存本次居民会话滚动一小时的后台思考预算（0...6），返回收敛后的值供设置页回显。
    /// 0 只表示不再发起新的后台思考，不会取消正在进行的一轮；实际 loop 预算由居民
    /// 循环接线方读取 `ResidentPreferences`，额度不跨循环重建或重启保留。
    @discardableResult
    func saveBackgroundTurnsPerHour(_ value: Int) -> Int {
        Task { do { let saved = try await residentPreferences.saveBackgroundTurnsPerHour(value); backgroundTurnsPerHour = saved; message = saved == 0 ? "已保存：不再发起新的后台思考，不会取消正在进行的一轮。" : "后台思考预算已保存：本次会话滚动一小时内最多 \(saved) 轮。"; hasError = false; NotificationCenter.default.post(name: .init("gmgnResidentAutonomyChanged"), object: nil) } catch { message = "设置未保存，请检查后台连接。"; hasError = true } }
        return backgroundTurnsPerHour
    }

    func saveAgentConfiguration(showMessage: Bool = true) {
        let enabled = takeoverEnabled, model = planningModel
        Task { do { try await preferences.saveConfiguration(takeover: enabled, model: model); planningModel = preferences.planningModel() ?? ""; takeoverEnabled = preferences.takeoverEnabled(); if showMessage { message = takeoverEnabled ? "DJ 接管已开启。" : "DJ 接管已关闭。"; hasError = false } } catch { message = "设置未保存，请检查后台连接。"; hasError = true } }
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
