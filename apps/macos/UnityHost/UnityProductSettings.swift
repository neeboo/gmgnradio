import Foundation

/// Settings for the actual Unity session. Reuses the product's Rust speech
/// models without constructing AppDelegate. Product voice preferences are only
/// read when the host explicitly supplies them; isolated tests omit that source.
@MainActor
final class UnityProductSettings {
    private let defaults: UserDefaults
    private let speech: RustSpeechPreferences
    private let productSpeech: RustSpeechPreferences?
    private let productVoiceDefaults: UserDefaults?
    private let client: RustVoiceClient
    private let previewStatus = AgentSpeechStatusStore()
    private let replyStatus = AgentSpeechStatusStore()
    private var replySpeech: (any SpeechSynthesizing)?
    private static let autoSpeakKey = "unity.agent.autoSpeakReplies"
    private static let localeKey = "unity.ui.locale"
    private var preview: RustSpeechSynthesizer?
    private var capabilities: RustVoiceCapabilities?
    private var capabilitiesTask: Task<Void, Never>?
    private var voicesTask: Task<Void, Never>?
    private var provider: RustVoiceProvider
    private var model: String
    private var voiceID: String
    private var asrProvider: RustVoiceProvider?
    private var voices: [RustVoiceOption] = []
    private var loadingCapabilities = false
    private var loadingVoices = false
    private var notice: String?
    private var generation: UInt64 = 0

    init(root: URL, defaults: UserDefaults, productVoiceDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.productVoiceDefaults = productVoiceDefaults
        productSpeech = productVoiceDefaults.map { RustSpeechPreferences(defaults: $0) }
        speech = RustSpeechPreferences(defaults: defaults)
        // `root` is the authority's Application Support base, shared with the
        // world/inbox bridges. Voice must not create a second taskd authority.
        client = RustVoiceClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true), allowsLaunching: false)
        let saved = Self.resolveVoiceConfiguration(for: "tts", defaults: defaults, speech: speech, productSpeech: productSpeech)
        provider = saved.provider; model = saved.model ?? ""; voiceID = saved.voiceID
    }

    var snapshot: [String: Any] {
        let resident = ResidentPreferences(defaults: defaults)
        let caps = capabilities?.providers.first { $0.id == provider.rawValue }
        let asr = asrProvider.map { voiceConfiguration(provider: $0, for: "asr") }
            ?? voiceConfiguration(for: "asr")
        let asrCaps = capabilities?.providers.first { $0.id == asr.provider.rawValue }
        return [
            "locale": locale,
            "agent": ["backendID": "dsh", "backends": [["id": "dsh", "name": "DSH"]],
                      "backendStatus": "当前 Unity 聊天使用 DSH。", "residentPersona": resident.persona,
                      "autoSpeak": autoSpeakReplies,
                      "notice": replyStatus.lastErrorMessage ?? "居民人格保存后下一轮聊天生效。按住说话与自主行动尚未接入 Unity。", "hasError": replyStatus.lastErrorMessage != nil],
            "tts": ["providerID": provider.rawValue, "modelID": model, "voiceID": voiceID,
                    "providers": (capabilities?.providers.filter { !$0.ttsModels.isEmpty } ?? []).map { ["id": $0.id, "name": providerName($0.id)] },
                    "models": (caps?.ttsModels ?? []).map { ["id": $0.id, "name": $0.name] },
                    "voices": voices.map { ["id": $0.id, "name": $0.name] },
                    "loading": loadingCapabilities || loadingVoices, "catalogLoaded": capabilities != nil,
                    "defaultModelID": caps?.defaultTTSModel as Any? ?? NSNull(),
                    "isSpeaking": previewStatus.isSpeaking || replyStatus.isSpeaking,
                    "credentialConfigured": !voiceConfiguration(provider: provider, for: "tts").apiKey.isEmpty,
                    "notice": replyStatus.lastErrorMessage ?? previewStatus.lastErrorMessage ?? notice as Any? ?? NSNull()],
            "asr": ["providerID": asr.provider.rawValue, "modelID": asr.model ?? asrCaps?.defaultASRModel ?? "",
                    "providers": (capabilities?.providers.filter { !$0.asrModels.isEmpty } ?? []).map { ["id": $0.id, "name": providerName($0.id)] },
                    "models": (asrCaps?.asrModels ?? []).map { ["id": $0.id, "name": $0.name] },
                    "catalogLoaded": capabilities != nil, "defaultModelID": asrCaps?.defaultASRModel as Any? ?? NSNull(),
                    "credentialConfigured": !asr.apiKey.isEmpty,
                    "notice": "可保存语音识别配置；Unity 按住说话尚未接入。"],
        ]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op {
        case "app.language":
            guard let locale = value["locale"] as? String, ["zh-CN", "en", "ja"].contains(locale) else { return false }
            defaults.set(locale, forKey: Self.localeKey)
        case "settings.load", "speech.settings.load": loadCapabilities()
        case "agent.save":
            guard value.keys.allSatisfy({ ["op", "residentPersona", "autoSpeak"].contains($0) }),
                  value["residentPersona"] != nil || value["autoSpeak"] != nil,
                  value["residentPersona"] == nil || value["residentPersona"] is String,
                  value["autoSpeak"] == nil || value["autoSpeak"] is Bool else { return false }
            if let persona = value["residentPersona"] as? String { ResidentPreferences(defaults: defaults).savePersona(persona) }
            if let enabled = value["autoSpeak"] as? Bool {
                defaults.set(enabled, forKey: Self.autoSpeakKey)
                if !enabled { stopReplySpeech() }
            }
        case "agent.backend", "agent.status": return false
        case "tts.provider":
            guard let id = value["id"] as? String, let selected = RustVoiceProvider(rawValue: id),
                  capabilities?.providers.contains(where: { $0.id == id && !$0.ttsModels.isEmpty }) == true else { return false }
            stopVoiceWork(); provider = selected
            let saved = voiceConfiguration(provider: selected, for: "tts")
            model = saved.model ?? capabilities?.providers.first(where: { $0.id == id })?.defaultTTSModel ?? ""
            voiceID = saved.voiceID; voices = []; notice = nil
        case "asr.provider":
            guard let id = value["id"] as? String, let selected = RustVoiceProvider(rawValue: id),
                  capabilities?.providers.contains(where: { $0.id == id && !$0.asrModels.isEmpty }) == true else { return false }
            asrProvider = selected
        case "asr.save":
            guard let id = value["providerID"] as? String, let selected = RustVoiceProvider(rawValue: id),
                  let model = value["modelID"] as? String,
                  capabilities?.providers.first(where: { $0.id == id })?.asrModels.contains(where: { $0.id == model }) == true else { return false }
            let old = voiceConfiguration(provider: selected, for: "asr")
            speech.save(RustVoiceConfiguration(provider: selected, apiKey: replacementKey(value, old: old.apiKey), voiceID: old.voiceID, model: model), for: "asr")
            asrProvider = selected
        case "tts.refresh":
            guard let configuration = selectedConfiguration(value) else { return false }
            refreshVoices(configuration)
        case "tts.save", "tts.preview":
            guard let configuration = selectedConfiguration(value) else { return false }
            provider = configuration.provider; model = configuration.model ?? ""; voiceID = configuration.voiceID
            preview?.stopSpeaking()
            stopReplySpeech()
            if op == "tts.save" { speech.save(configuration, for: "tts"); notice = "已保存 Unity 语音配置。" }
            else {
                let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: previewStatus, client: client)
                preview = synthesizer; synthesizer.speak("你好，这是当前选中的声音。")
            }
        case "tts.stop": preview?.stopSpeaking(); preview = nil; stopReplySpeech()
        case "speech.settings.cancel":
            stopVoiceWork()
            if value["cancelCapabilities"] as? Bool != false { capabilitiesTask?.cancel(); capabilitiesTask = nil; loadingCapabilities = false }
            if value["clearVoices"] as? Bool == true { voices = []; notice = nil }
        default: return false
        }
        return true
    }

    private func replacementKey(_ value: [String: Any], old: String) -> String {
        let replacement = (value["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return replacement.isEmpty ? old : replacement
    }
    private func selectedConfiguration(_ value: [String: Any]) -> RustVoiceConfiguration? {
        guard let id = value["providerID"] as? String, let selected = RustVoiceProvider(rawValue: id),
              let model = value["modelID"] as? String, let voice = value["voiceID"] as? String,
              capabilities?.providers.first(where: { $0.id == id })?.ttsModels.contains(where: { $0.id == model }) == true else {
            notice = "请先加载模型列表并选择有效模型。"; return nil
        }
        let old = voiceConfiguration(provider: selected, for: "tts")
        return RustVoiceConfiguration(provider: selected, apiKey: replacementKey(value, old: old.apiKey), voiceID: voice, model: model)
    }
    private func loadCapabilities() {
        capabilitiesTask?.cancel(); loadingCapabilities = true; notice = nil
        capabilitiesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await client.capabilities(); try Task.checkCancellation()
                capabilities = loaded; loadingCapabilities = false
                if model.isEmpty { model = loaded.providers.first(where: { $0.id == provider.rawValue })?.defaultTTSModel ?? "" }
                let saved = voiceConfiguration(provider: provider, for: "tts")
                refreshVoices(RustVoiceConfiguration(provider: provider, apiKey: saved.apiKey, voiceID: voiceID, model: model))
            } catch {
                guard !Task.isCancelled else { return }
                loadingCapabilities = false; notice = "模型列表暂时无法加载，已有配置已保留。"
            }
        }
    }
    private func refreshVoices(_ configuration: RustVoiceConfiguration) {
        voicesTask?.cancel(); generation &+= 1; let lease = generation; loadingVoices = true
        voicesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await client.listVoices(configuration: configuration); try Task.checkCancellation()
                guard lease == generation, provider == configuration.provider else { return }
                voices = loaded; loadingVoices = false; notice = "声音列表已加载。"
            } catch {
                guard !Task.isCancelled, lease == generation else { return }
                loadingVoices = false; notice = "声音列表暂时无法加载，请检查服务配置后刷新。"
            }
        }
    }
    private func stopVoiceWork() {
        generation &+= 1; voicesTask?.cancel(); voicesTask = nil; loadingVoices = false
        preview?.stopSpeaking(); preview = nil; previewStatus.lastErrorMessage = nil
    }
    /// Presence of a local choice/key is authoritative even when empty. A user
    /// revocation must never resurrect a key or silently select another provider.
    private static func resolveVoiceConfiguration(for purpose: String, defaults: UserDefaults,
        speech: RustSpeechPreferences, productSpeech: RustSpeechPreferences?) -> RustVoiceConfiguration {
        let local = speech.configuration(for: purpose, includesEnvironment: false)
        let hasLocalChoice = defaults.object(forKey: "speech.rust.\(purpose).provider") != nil
        let hasLocalKey = defaults.object(forKey: "speech.rust.\(local.provider.rawValue).apiKey") != nil
            || (local.provider == .bailian && defaults.object(forKey: "voice.bailian.apiKey") != nil)
        guard !hasLocalChoice, !hasLocalKey, let productSpeech else { return local }
        return productSpeech.configuration(for: purpose, includesEnvironment: false)
    }
    func voiceConfiguration(for purpose: String) -> RustVoiceConfiguration {
        Self.resolveVoiceConfiguration(for: purpose, defaults: defaults, speech: speech, productSpeech: productSpeech)
    }
    private func voiceConfiguration(provider: RustVoiceProvider, for purpose: String) -> RustVoiceConfiguration {
        let effective = voiceConfiguration(for: purpose)
        guard effective.provider != provider else { return effective }
        return speech.configuration(provider: provider, for: purpose, includesEnvironment: false)
    }
    var autoSpeakReplies: Bool {
        defaults.object(forKey: Self.autoSpeakKey) as? Bool
            ?? productVoiceDefaults?.object(forKey: "agentConversation.autoSpeakReplies") as? Bool ?? true
    }
    var locale: String { defaults.string(forKey: Self.localeKey).flatMap { ["zh-CN", "en", "ja"].contains($0) ? $0 : nil } ?? "zh-CN" }
    func speakReply(_ text: String) {
        stopReplySpeech()
        guard autoSpeakReplies, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preview?.stopSpeaking(); preview = nil
        replyStatus.lastErrorMessage = nil
        let configuration = voiceConfiguration(for: "tts")
        let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: replyStatus, client: client)
        replySpeech = synthesizer
        synthesizer.speak(text)
    }
    func stopReplySpeech() { replySpeech?.stopSpeaking(); replySpeech = nil }
    func close() { stopReplySpeech(); stopVoiceWork(); capabilitiesTask?.cancel(); capabilitiesTask = nil }
    private func providerName(_ id: String) -> String {
        switch id { case "bailian": "百炼"; case "elevenlabs": "ElevenLabs"; case "fish": "Fish Audio"; default: id }
    }
}
