import Foundation

/// Settings for the actual Unity session. Reuses the product's Rust speech
/// models, but never constructs AppDelegate or reads the product preferences.
@MainActor
final class UnityProductSettings {
    private let defaults: UserDefaults
    private let speech: RustSpeechPreferences
    private let client: RustVoiceClient
    private let previewStatus = AgentSpeechStatusStore()
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

    init(root: URL, defaults: UserDefaults) {
        self.defaults = defaults
        speech = RustSpeechPreferences(defaults: defaults)
        client = RustVoiceClient(root: root.appendingPathComponent("TaskService", isDirectory: true))
        let saved = RustSpeechPreferences(defaults: defaults).configuration(for: "tts", includesEnvironment: false)
        provider = saved.provider; model = saved.model ?? ""; voiceID = saved.voiceID
    }

    var snapshot: [String: Any] {
        let resident = ResidentPreferences(defaults: defaults)
        let caps = capabilities?.providers.first { $0.id == provider.rawValue }
        let asr = asrProvider.map { speech.configuration(provider: $0, for: "asr", includesEnvironment: false) }
            ?? speech.configuration(for: "asr", includesEnvironment: false)
        let asrCaps = capabilities?.providers.first { $0.id == asr.provider.rawValue }
        return [
            "agent": ["backendID": "dsh", "backends": [["id": "dsh", "name": "DSH"]],
                      "backendStatus": "当前 Unity 聊天使用 DSH。", "residentPersona": resident.persona,
                      "notice": "居民人格保存后下一轮聊天生效。回复朗读、按住说话与自主行动尚未接入 Unity。", "hasError": false],
            "tts": ["providerID": provider.rawValue, "modelID": model, "voiceID": voiceID,
                    "providers": (capabilities?.providers.filter { !$0.ttsModels.isEmpty } ?? []).map { ["id": $0.id, "name": providerName($0.id)] },
                    "models": (caps?.ttsModels ?? []).map { ["id": $0.id, "name": $0.name] },
                    "voices": voices.map { ["id": $0.id, "name": $0.name] },
                    "loading": loadingCapabilities || loadingVoices, "catalogLoaded": capabilities != nil,
                    "defaultModelID": caps?.defaultTTSModel as Any? ?? NSNull(),
                    "isSpeaking": previewStatus.isSpeaking,
                    "credentialConfigured": !speech.configuration(provider: provider, for: "tts", includesEnvironment: false).apiKey.isEmpty,
                    "notice": previewStatus.lastErrorMessage ?? notice as Any? ?? NSNull()],
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
        case "settings.load", "speech.settings.load": loadCapabilities()
        case "agent.save":
            guard let persona = value["residentPersona"] as? String, value.keys.allSatisfy({ ["op", "residentPersona"].contains($0) }) else { return false }
            ResidentPreferences(defaults: defaults).savePersona(persona)
        case "agent.backend", "agent.status": return false
        case "tts.provider":
            guard let id = value["id"] as? String, let selected = RustVoiceProvider(rawValue: id),
                  capabilities?.providers.contains(where: { $0.id == id && !$0.ttsModels.isEmpty }) == true else { return false }
            stopVoiceWork(); provider = selected
            let saved = speech.configuration(provider: selected, for: "tts", includesEnvironment: false)
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
            let old = speech.configuration(provider: selected, for: "asr", includesEnvironment: false)
            speech.save(RustVoiceConfiguration(provider: selected, apiKey: replacementKey(value, old: old.apiKey), voiceID: old.voiceID, model: model), for: "asr")
            asrProvider = selected
        case "tts.refresh":
            guard let configuration = selectedConfiguration(value) else { return false }
            refreshVoices(configuration)
        case "tts.save", "tts.preview":
            guard let configuration = selectedConfiguration(value) else { return false }
            provider = configuration.provider; model = configuration.model ?? ""; voiceID = configuration.voiceID
            preview?.stopSpeaking()
            if op == "tts.save" { speech.save(configuration, for: "tts"); notice = "已保存 Unity 语音配置。" }
            else {
                let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: previewStatus, client: client)
                preview = synthesizer; synthesizer.speak("你好，这是当前选中的声音。")
            }
        case "tts.stop": preview?.stopSpeaking(); preview = nil
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
        let old = speech.configuration(provider: selected, for: "tts", includesEnvironment: false)
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
                let saved = speech.configuration(provider: provider, for: "tts", includesEnvironment: false)
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
    func close() { stopVoiceWork(); capabilitiesTask?.cancel(); capabilitiesTask = nil }
    private func providerName(_ id: String) -> String {
        switch id { case "bailian": "百炼"; case "elevenlabs": "ElevenLabs"; case "fish": "Fish Audio"; default: id }
    }
}
