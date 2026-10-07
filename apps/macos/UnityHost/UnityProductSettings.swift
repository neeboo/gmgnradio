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
    private let marbleAPIKey: MarbleAPIKeySettingsModel
    private var marbleMutationRevision: UInt64 = 0
    private let previewStatus = AgentSpeechStatusStore()
    private let replyStatus = AgentSpeechStatusStore()
    private var replyPlayback = AgentSpeechPlaybackState.idle
    private var previewPlayback = AgentSpeechPlaybackState.idle
    private var replySpeechGeneration: UInt64 = 0
    var onSpeechPlaybackChanged: ((Bool) -> Void)?
    private var replySpeech: (any SpeechSynthesizing)?
    private var pendingReplySpeech: [String] = []
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
    private var microphoneDevices: [BailianMicrophoneDeviceOption] = []
    private var asrNotice: String?
    var microphoneDeviceID: String? {
        let key = RealtimeVoicePreferences.microphoneDeviceIDKey
        let value = defaults.object(forKey: key) != nil ? defaults.string(forKey: key) : productVoiceDefaults?.string(forKey: key)
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(root: URL, defaults: UserDefaults, productVoiceDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        marbleAPIKey = MarbleAPIKeySettingsModel(provider: MarbleAPIKeyProvider(
            fileURL: root.appendingPathComponent("secrets/world-labs-api-key")))
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
            "space": ["credentialConfigured": marbleAPIKey.isConfigured,
                      "marbleMutationRevision": marbleMutationRevision,
                      "marbleMessage": marbleAPIKey.message as Any? ?? NSNull(),
                      "marbleHasError": marbleAPIKey.hasError],
            "agent": ["backendID": "dsh", "backends": [["id": "dsh", "name": "DSH"]],
                      "backendStatus": "当前 Unity 聊天使用 DSH。", "residentPersona": resident.persona,
                      "autoSpeak": autoSpeakReplies,
                      "autonomyEnabled": defaults.object(forKey: UnityResidentAgentLoopBridge.enabledKey) as? Bool ?? true,
                      "backgroundTurnsPerHour": resident.backgroundTurnsPerHour,
                      "budgetOptions": Array(0...ResidentPreferences.maximumBackgroundTurnsPerHour),
                      "notice": replyStatus.lastErrorMessage ?? "居民人格保存后下一轮聊天生效。", "hasError": replyStatus.lastErrorMessage != nil],
            "tts": ["providerID": provider.rawValue, "modelID": model, "voiceID": voiceID,
                    "providers": (capabilities?.providers.filter { !$0.ttsModels.isEmpty } ?? []).map { ["id": $0.id, "name": providerName($0.id)] },
                    "models": (caps?.ttsModels ?? []).map { ["id": $0.id, "name": $0.name] },
                    "voices": voices.map { ["id": $0.id, "name": $0.name] },
                    "loading": loadingCapabilities || loadingVoices, "catalogLoaded": capabilities != nil,
                    "defaultModelID": caps?.defaultTTSModel as Any? ?? NSNull(),
                    "isSpeaking": previewStatus.isSpeaking || replyStatus.isSpeaking,
                    "isReplyPlaying": replyPlayback.isPlaying,
                    "replyLevel": replyPlayback.level,
                    "credentialConfigured": !voiceConfiguration(provider: provider, for: "tts").apiKey.isEmpty,
                    "notice": replyStatus.lastErrorMessage ?? previewStatus.lastErrorMessage ?? notice as Any? ?? NSNull()],
            "asr": ["providerID": asr.provider.rawValue, "modelID": asr.model ?? asrCaps?.defaultASRModel ?? "",
                    "providers": (capabilities?.providers.filter { !$0.asrModels.isEmpty } ?? []).map { ["id": $0.id, "name": providerName($0.id)] },
                    "models": (asrCaps?.asrModels ?? []).map { ["id": $0.id, "name": $0.name] },
                    "catalogLoaded": capabilities != nil, "defaultModelID": asrCaps?.defaultASRModel as Any? ?? NSNull(),
                    "credentialConfigured": !asr.apiKey.isEmpty,
                    "microphoneDeviceID": microphoneDeviceID ?? "",
                    "microphoneDevices": [["id": "", "name": "系统默认"]] + microphoneDevices.map { ["id": $0.id, "name": $0.name] },
                    "notice": asrNotice as Any? ?? NSNull()],
        ]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op {
        case "space.key.save":
            guard let key = value["apiKey"] as? String else { return false }
            marbleAPIKey.replacementKey = key
            marbleAPIKey.save()
            guard !marbleAPIKey.hasError else { return false }
            marbleMutationRevision &+= 1
        case "space.key.clear":
            marbleAPIKey.clear()
            guard !marbleAPIKey.hasError else { return false }
            marbleMutationRevision &+= 1
        case "app.language":
            guard let locale = value["locale"] as? String, ["zh-CN", "en", "ja"].contains(locale) else { return false }
            defaults.set(locale, forKey: Self.localeKey)
        case "settings.load", "speech.settings.load": loadCapabilities()
        case "agent.save":
            guard value.keys.allSatisfy({ ["op", "residentPersona", "autoSpeak", "backgroundTurnsPerHour"].contains($0) }),
                  value["residentPersona"] != nil || value["autoSpeak"] != nil || value["backgroundTurnsPerHour"] != nil,
                  value["residentPersona"] == nil || value["residentPersona"] is String,
                  value["autoSpeak"] == nil || value["autoSpeak"] is Bool,
                  value["backgroundTurnsPerHour"] == nil || value["backgroundTurnsPerHour"] is Int else { return false }
            if let budget = value["backgroundTurnsPerHour"] as? Int { ResidentPreferences(defaults: defaults).saveBackgroundTurnsPerHour(budget) }
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
            refreshVoices(RustVoiceConfiguration(provider: selected, apiKey: saved.apiKey,
                voiceID: voiceID, model: model))
        case "asr.provider":
            guard let id = value["id"] as? String, let selected = RustVoiceProvider(rawValue: id),
                  capabilities?.providers.contains(where: { $0.id == id && !$0.asrModels.isEmpty }) == true else { return false }
            asrProvider = selected
        case "asr.save":
            guard let id = value["providerID"] as? String, let selected = RustVoiceProvider(rawValue: id),
                  let model = value["modelID"] as? String,
                  capabilities?.providers.first(where: { $0.id == id })?.asrModels.contains(where: { $0.id == model }) == true else { return false }
            let old = voiceConfiguration(provider: selected, for: "asr")
            if let id = value["microphoneDeviceID"] as? String {
                microphoneDevices = BailianMicrophoneDeviceCatalog.availableDevices()
                guard id.isEmpty || microphoneDevices.contains(where: { $0.id == id }) else {
                    asrNotice = "所选麦克风已断开，请重新选择。"; return false
                }
                defaults.set(id, forKey: RealtimeVoicePreferences.microphoneDeviceIDKey)
            }
            speech.save(RustVoiceConfiguration(provider: selected, apiKey: replacementKey(value, old: old.apiKey), voiceID: old.voiceID, model: model), for: "asr")
            asrProvider = selected
            asrNotice = "已保存。"
        case "tts.refresh":
            guard let configuration = selectedConfiguration(value) else { return false }
            refreshVoices(configuration)
        case "tts.save", "tts.preview":
            guard let configuration = selectedConfiguration(value) else { return false }
            provider = configuration.provider; model = configuration.model ?? ""; voiceID = configuration.voiceID
            preview?.stopSpeaking()
            stopReplySpeech()
            if op == "tts.save" { speech.save(configuration, for: "tts"); notice = "已保存。"; refreshVoices(configuration) }
            else {
                let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: previewStatus, client: client,
                    onPlaybackChanged: { [weak self] state in
                        guard let self else { return }
                        self.previewPlayback = state
                        self.publishSpeechPlayback()
                    })
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
        microphoneDevices = BailianMicrophoneDeviceCatalog.availableDevices()
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
        if configuration.provider != .bailian && configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voices = []; loadingVoices = false; notice = "请先填写 API Key，再刷新声音。"; return
        }
        voicesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await client.listVoices(configuration: configuration); try Task.checkCancellation()
                guard lease == generation, provider == configuration.provider else { return }
                voices = loaded; loadingVoices = false; notice = loaded.isEmpty ? "该账号暂无可用声音，可填写自定义音色 ID。" : nil
            } catch {
                guard !Task.isCancelled, lease == generation else { return }
                loadingVoices = false; notice = "声音列表暂时无法加载，请检查服务配置后刷新。"
            }
        }
    }
    private func stopVoiceWork() {
        generation &+= 1; voicesTask?.cancel(); voicesTask = nil; loadingVoices = false
        preview?.stopSpeaking(); preview = nil; previewStatus.lastErrorMessage = nil
        previewPlayback = .idle; publishSpeechPlayback()
    }
    /// Presence of a local choice/key is authoritative even when empty. A user
    /// revocation must never resurrect a key or silently select another provider.
    private static func resolveVoiceConfiguration(for purpose: String, defaults: UserDefaults,
        speech: RustSpeechPreferences, productSpeech: RustSpeechPreferences?) -> RustVoiceConfiguration {
        let local = speech.configuration(for: purpose, includesEnvironment: false)
        let hasLocalChoice = defaults.object(forKey: "speech.rust.\(purpose).provider") != nil
        let hasLocalKey = defaults.object(forKey: "speech.rust.\(local.provider.rawValue).apiKey") != nil
            || (local.provider == .bailian && defaults.object(forKey: "voice.bailian.apiKey") != nil)
        guard !hasLocalKey, let productSpeech else { return local }
        if hasLocalChoice {
            let inherited = productSpeech.configuration(provider: local.provider, for: purpose, includesEnvironment: false)
            return RustVoiceConfiguration(provider: local.provider, apiKey: inherited.apiKey,
                voiceID: local.voiceID, model: local.model)
        }
        let inherited = productSpeech.configuration(for: purpose, includesEnvironment: false)
        let inheritedKey = defaults.object(forKey: "speech.rust.\(inherited.provider.rawValue).apiKey") != nil
            || (inherited.provider == .bailian && defaults.object(forKey: "voice.bailian.apiKey") != nil)
        if inheritedKey {
            let overridden = speech.configuration(provider: inherited.provider, for: purpose, includesEnvironment: false)
            return RustVoiceConfiguration(provider: inherited.provider, apiKey: overridden.apiKey,
                voiceID: inherited.voiceID, model: inherited.model)
        }
        return inherited
    }
    func voiceConfiguration(for purpose: String) -> RustVoiceConfiguration {
        Self.resolveVoiceConfiguration(for: purpose, defaults: defaults, speech: speech, productSpeech: productSpeech)
    }
    private func voiceConfiguration(provider: RustVoiceProvider, for purpose: String) -> RustVoiceConfiguration {
        let effective = voiceConfiguration(for: purpose)
        let local = effective.provider == provider ? effective : speech.configuration(provider: provider, for: purpose, includesEnvironment: false)
        let explicitKey = defaults.object(forKey: "speech.rust.\(provider.rawValue).apiKey") != nil
            || (provider == .bailian && defaults.object(forKey: "voice.bailian.apiKey") != nil)
        if explicitKey { return speech.configuration(provider: provider, for: purpose, includesEnvironment: false) }
        guard let productSpeech else { return local }
        let inherited = productSpeech.configuration(provider: provider, for: purpose, includesEnvironment: false)
        if defaults.string(forKey: "speech.rust.\(purpose).provider") == provider.rawValue {
            return RustVoiceConfiguration(provider: provider, apiKey: inherited.apiKey,
                voiceID: local.voiceID, model: local.model)
        }
        return inherited
    }
    var autoSpeakReplies: Bool {
        defaults.object(forKey: Self.autoSpeakKey) as? Bool
            ?? productVoiceDefaults?.object(forKey: "agentConversation.autoSpeakReplies") as? Bool ?? true
    }
    var locale: String { defaults.string(forKey: Self.localeKey).flatMap { ["zh-CN", "en", "ja"].contains($0) ? $0 : nil } ?? "zh-CN" }
    var replyPlaybackSnapshot: [String: Any] { ["isPlaying": replyPlayback.isPlaying, "level": replyPlayback.level] }
    private func publishSpeechPlayback() { onSpeechPlaybackChanged?(replyPlayback.isPlaying || previewPlayback.isPlaying) }
    func speakReply(_ text: String) {
        guard autoSpeakReplies, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingReplySpeech.append(text)
        startNextReplySpeech()
    }
    private func startNextReplySpeech() {
        guard replySpeech == nil, !pendingReplySpeech.isEmpty else { return }
        let text = pendingReplySpeech.removeFirst()
        preview?.stopSpeaking(); preview = nil
        replyStatus.lastErrorMessage = nil
        let configuration = voiceConfiguration(for: "tts")
        let playbackGeneration = replySpeechGeneration
        let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: replyStatus, client: client,
            onPlaybackChanged: { [weak self] state in
                guard let self, self.replySpeechGeneration == playbackGeneration else { return }
                if state.isPlaying != self.replyPlayback.isPlaying {
                    NSLog("[UnitySpeech] playback=%@", state.isPlaying ? "started" : "stopped")
                }
                self.replyPlayback = state
                self.publishSpeechPlayback()
            })
        replySpeech = synthesizer
        NSLog("[UnitySpeech] utterance=started characters=%lu queued=%lu", text.count, pendingReplySpeech.count)
        synthesizer.speak(text, completion: { [weak self] outcome in
            guard let self, self.replySpeechGeneration == playbackGeneration else { return }
            NSLog("[UnitySpeech] utterance=%@ characters=%lu", String(describing: outcome), text.count)
            // Let the completed synthesizer finish its cleanup before starting
            // another reply against the shared playback status store.
            Task { @MainActor [weak self] in
                guard let self, self.replySpeechGeneration == playbackGeneration else { return }
                self.replySpeech = nil
                self.startNextReplySpeech()
            }
        })
    }
    func stopReplySpeech() { replySpeechGeneration &+= 1; pendingReplySpeech.removeAll(); replySpeech?.stopSpeaking(); replySpeech = nil; replyPlayback = .idle; publishSpeechPlayback() }
    func close() { stopReplySpeech(); stopVoiceWork(); capabilitiesTask?.cancel(); capabilitiesTask = nil }
    private func providerName(_ id: String) -> String {
        switch id { case "bailian": "百炼"; case "elevenlabs": "ElevenLabs"; case "fish": "Fish Audio"; default: id }
    }
}
