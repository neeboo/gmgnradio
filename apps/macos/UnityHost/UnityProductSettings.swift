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
    private let settings: RustProductSettingsClient
    var authority: RustProductSettingsClient { settings }
    private let marbleAPIKey: MarbleAPIKeySettingsModel
    private var marbleMutationRevision: UInt64 = 0
    private let previewStatus = AgentSpeechStatusStore()
    private let replyStatus = AgentSpeechStatusStore()
    private var replyPlayback = AgentSpeechPlaybackState.idle
    private var previewPlayback = AgentSpeechPlaybackState.idle
    var onSpeechPlaybackChanged: ((Bool) -> Void)?
    private var replySpeech: RustSpeechSynthesizer?
    private let speechHostSessionID = UUID().uuidString
    private lazy var chatSpeechAuthority = RustSpeechDeliveryClient(scopeID: "unity.reply", hostSessionID: speechHostSessionID, voiceClient: client)
    private var chatSpeechEventTask: Task<Void, Never>?
    private var speechClosed = false
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
        settings.confirmed?.values.microphoneDeviceID
    }

    init(root: URL, defaults: UserDefaults, productVoiceDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        let settings = RustProductSettingsClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true), allowsLaunching: true)
        self.settings = settings
        settings.bootstrap(legacy: RustProductSettingsClient.legacySnapshot(defaults))
        marbleAPIKey = MarbleAPIKeySettingsModel(provider: MarbleAPIKeyProvider(
            fileURL: root.appendingPathComponent("secrets/world-labs-api-key")))
        self.productVoiceDefaults = productVoiceDefaults
        let secrets = FileSpeechSecretStore(directory: root.appendingPathComponent("secrets"))
        productSpeech = productVoiceDefaults.map { RustSpeechPreferences(defaults: $0, settings: settings, secrets: secrets) }
        speech = RustSpeechPreferences(defaults: defaults, settings: settings, secrets: secrets)
        // `root` is the authority's Application Support base, shared with the
        // world/inbox bridges. Voice must not create a second taskd authority.
        client = RustVoiceClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true), allowsLaunching: false)
        let saved = speech.configuration(for: "tts", includesEnvironment: false, includesSecrets: false)
        provider = saved.provider; model = saved.model ?? ""; voiceID = saved.voiceID
    }

    var snapshot: [String: Any] {
        let resident = ResidentPreferences(defaults: defaults, settings: settings)
        let caps = capabilities?.providers.first { $0.id == provider.rawValue }
        let asr = speech.configuration(provider: asrProvider ?? speech.provider(for: "asr", includesEnvironment: false), for: "asr", includesEnvironment: false, includesSecrets: false)
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
                      "autonomyEnabled": settings.confirmed?.values.autonomyEnabled ?? false,
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
                    "credentialConfigured": speech.credentialConfigured(provider: provider) as Any? ?? NSNull(),
                    "notice": replyStatus.lastErrorMessage ?? previewStatus.lastErrorMessage ?? notice as Any? ?? NSNull()],
            "asr": ["providerID": asr.provider.rawValue, "modelID": asr.model ?? asrCaps?.defaultASRModel ?? "",
                    "providers": (capabilities?.providers.filter { !$0.asrModels.isEmpty } ?? []).map { ["id": $0.id, "name": providerName($0.id)] },
                    "models": (asrCaps?.asrModels ?? []).map { ["id": $0.id, "name": $0.name] },
                    "catalogLoaded": capabilities != nil, "defaultModelID": asrCaps?.defaultASRModel as Any? ?? NSNull(),
                    "credentialConfigured": speech.credentialConfigured(provider: asr.provider) as Any? ?? NSNull(),
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
            saveSettings(["locale": locale])
        case "settings.load", "speech.settings.load": loadCapabilities()
        case "agent.save":
            guard value.keys.allSatisfy({ ["op", "residentPersona", "autoSpeak", "backgroundTurnsPerHour"].contains($0) }),
                  value["residentPersona"] != nil || value["autoSpeak"] != nil || value["backgroundTurnsPerHour"] != nil,
                  value["residentPersona"] == nil || value["residentPersona"] is String,
                  value["autoSpeak"] == nil || value["autoSpeak"] is Bool,
                  value["backgroundTurnsPerHour"] == nil || value["backgroundTurnsPerHour"] is Int else { return false }
            var changes = value; changes.removeValue(forKey: "op")
            saveSettings(changes)
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
                saveSettings(["microphoneDeviceID": id])
            }
            let configuration = RustVoiceConfiguration(provider: selected, apiKey: replacementKey(value, old: old.apiKey), voiceID: old.voiceID, model: model)
            Task { do { try await speech.save(configuration, for: "asr"); asrProvider = selected; asrNotice = "已保存。" } catch { asrNotice = "设置未保存，请检查后台连接。" } }
        case "tts.refresh":
            guard let configuration = selectedConfiguration(value) else { return false }
            refreshVoices(configuration)
        case "tts.save", "tts.preview":
            guard let configuration = selectedConfiguration(value) else { return false }
            provider = configuration.provider; model = configuration.model ?? ""; voiceID = configuration.voiceID
            preview?.stopSpeaking()
            stopReplySpeech()
            if op == "tts.save" { Task { do { try await speech.save(configuration, for: "tts"); notice = "已保存。"; refreshVoices(configuration) } catch { notice = "设置未保存，请检查后台连接。" } } }
            else {
                let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: previewStatus, client: client,
                    scopeID: "unity.preview", hostSessionID: speechHostSessionID,
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
    private func saveSettings(_ changes: [String: Any]) {
        notice = "正在保存…"
        Task { do { _ = try await settings.apply(changes); if settings.confirmed?.values.autoSpeak == false { stopReplySpeech() }; notice = "已保存。" } catch { notice = "设置未保存，请检查后台连接。" } }
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
        speech.configuration(for: purpose, includesEnvironment: false)
    }
    func voiceConfiguration(for purpose: String) -> RustVoiceConfiguration {
        Self.resolveVoiceConfiguration(for: purpose, defaults: defaults, speech: speech, productSpeech: productSpeech)
    }
    private func voiceConfiguration(provider: RustVoiceProvider, for purpose: String) -> RustVoiceConfiguration {
        speech.configuration(provider: provider, for: purpose, includesEnvironment: false)
    }
    var autoSpeakReplies: Bool {
        settings.confirmed?.values.autoSpeak ?? false
    }
    var locale: String { settings.confirmed?.values.locale ?? "zh-CN" }
    var replyPlaybackSnapshot: [String: Any] { ["isPlaying": replyPlayback.isPlaying, "level": replyPlayback.level] }
    private func publishSpeechPlayback() { onSpeechPlaybackChanged?(replyPlayback.isPlaying || previewPlayback.isPlaying) }
    func replySpeechEvent(requestID: String, kind: String, source: [String: Any]? = nil) {
        guard !speechClosed else { return }
        let previous = chatSpeechEventTask
        chatSpeechEventTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !speechClosed, !Task.isCancelled else { return }
            do {
                let receipt = try await chatSpeechAuthority.chatEvent(requestID: requestID, kind: kind, source: source,
                    testMuted: ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_MUTED"] == "1")
                guard !speechClosed, !Task.isCancelled else { return }
                if let view = receipt.delivery { await replySpeech?.applyIssuedSpeechView(view) }
                if let dispatch = receipt.dispatch { await speakReply(dispatch) }
            } catch { replyStatus.lastErrorMessage = "语音回执未确认；文字回复不受影响。" }
        }
    }
    private func speakReply(_ dispatch: RustSpeechDeliveryClient.ChatDispatch) async {
        guard ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_MUTED"] != "1" else { return }
        preview?.stopSpeaking(); preview = nil
        if let replySpeech { await replySpeech.speakIssued(dispatch); return }
        replyStatus.lastErrorMessage = nil
        let synthesizer = RustSpeechSynthesizer(configuration: { [weak self] in self?.voiceConfiguration(for: "tts") ?? RustVoiceConfiguration(apiKey: "") }, statusStore: replyStatus, client: client,
            scopeID: "unity.reply", hostSessionID: speechHostSessionID, deliveryMode: "fifo",
            onPlaybackChanged: { [weak self] state in
                guard let self else { return }
                if state.isPlaying != self.replyPlayback.isPlaying {
                    NSLog("[UnitySpeech] playback=%@", state.isPlaying ? "started" : "stopped")
                }
                self.replyPlayback = state
                self.publishSpeechPlayback()
            })
        replySpeech = synthesizer
        await synthesizer.speakIssued(dispatch)
    }
    func stopReplySpeech() { replySpeech?.stopSpeaking() }
    func close() { speechClosed = true; chatSpeechEventTask?.cancel(); stopReplySpeech(); stopVoiceWork(); capabilitiesTask?.cancel(); capabilitiesTask = nil }
    private func providerName(_ id: String) -> String {
        switch id { case "bailian": "百炼"; case "elevenlabs": "ElevenLabs"; case "fish": "Fish Audio"; default: id }
    }
}
