import SwiftUI

@MainActor
private struct RustSpeechConfigurationFields: View {
    let purpose: String
    @State private var provider: RustVoiceProvider
    @State private var apiKey: String
    @State private var voiceID: String
    @State private var model: String
    @State private var saved = false
    @State private var voices: [RustVoiceOption] = []
    @State private var loadingVoices = false
    @State private var voiceMessage: String?
    @State private var preview: RustSpeechSynthesizer?
    @State private var previewStatus = AgentSpeechStatusStore()
    @State private var listTask: Task<Void, Never>?
    @State private var capabilities: RustVoiceCapabilities?
    @State private var capabilityMessage: String?
    @State private var capabilityTask: Task<Void, Never>?
    private let preferences = RustSpeechPreferences(defaults: E2ERuntime.defaults)
    // Match the application's voice client root, including isolated E2E homes.
    private let voiceClient = RustVoiceClient(root: E2ERuntime.productSupportDirectory()
        .appendingPathComponent("TaskService", isDirectory: true))

    init(purpose: String) {
        self.purpose = purpose
        let configuration = RustSpeechPreferences(defaults: E2ERuntime.defaults).configuration(for: purpose, includesEnvironment: false)
        _provider = State(initialValue: configuration.provider)
        _apiKey = State(initialValue: configuration.apiKey)
        _voiceID = State(initialValue: configuration.voiceID)
        _model = State(initialValue: configuration.model ?? "")
    }
    var body: some View {
        Picker("服务", selection: $provider) {
            Text("百炼").tag(RustVoiceProvider.bailian)
            Text("ElevenLabs").tag(RustVoiceProvider.elevenlabs)
            if purpose == "tts" { Text("Fish Audio").tag(RustVoiceProvider.fish) }
        }
        .onChange(of: provider) { _, selection in
            cancelPreviewAndList()
            // Load that provider's saved credentials, never silently reuse another provider's key.
            let configuration = preferences.configuration(provider: selection, for: purpose, includesEnvironment: false)
            apiKey = configuration.apiKey
            voiceID = configuration.voiceID
            model = configuration.model ?? ""
            if model.isEmpty { model = defaultModelID ?? "" }
            saved = false
            voices = []; voiceMessage = nil
        }
        SecureField("API Key", text: $apiKey)
            .onChange(of: apiKey) { _, _ in
                cancelPreviewAndList(); voices = []; voiceMessage = nil; saved = false
            }
        if purpose == "tts" {
            Picker("声音", selection: $voiceID) {
                if !voices.contains(where: { $0.id == voiceID }) {
                    Text(voiceID.isEmpty ? "请选择声音" : "当前声音（\(voiceID)）").tag(voiceID)
                }
                ForEach(voices) { voice in Text(voice.name).tag(voice.id) }
            }
            .disabled(loadingVoices)
            .onChange(of: voiceID) { _, _ in preview?.stopSpeaking(); saved = false }
            HStack {
                Button("刷新声音") { refreshVoices() }.disabled(loadingVoices)
                if loadingVoices { ProgressView().controlSize(.small) }
                Button(previewStatus.isSpeaking ? "停止试听" : "试听声音") {
                    if previewStatus.isSpeaking { preview?.stopSpeaking() }
                    else { playPreview() }
                }.disabled(voiceID.isEmpty || !modelSelectionIsValid)
            }
            if let voiceMessage { Text(voiceMessage).font(.caption).foregroundStyle(.secondary) }
            if let error = previewStatus.lastErrorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("自定义音色 ID") {
                TextField(provider == .fish ? "自定义 Reference ID" : "自定义 Voice ID", text: $voiceID)
                Text("填写该服务已有的音色 ID，无需重新上传；账号、模型及服务区域须与创建音色时一致。")
                    .font(.caption).foregroundStyle(.secondary)
                if provider == .bailian {
                    Text("百炼复刻音色需要在模型列表选择对应的 VC Realtime 快照；创建音色时的 target_model 必须匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Picker("模型", selection: $model) {
            if model.isEmpty { Text("正在加载模型选项").tag("") }
            if !model.isEmpty && !supportedModels.contains(where: { $0.id == model }) {
                Text("旧模型不受支持，请重新选择").tag(model)
            }
            ForEach(supportedModels) { option in
                Text(option.name + (option.id == defaultModelID ? "（默认）" : "")).tag(option.id)
            }
        }
            .disabled(capabilities == nil)
            .onChange(of: model) { _, _ in
                // Voice catalogs do not depend on the synthesis model. Keep
                // that request alive when Rust supplies the initial default.
                preview?.stopSpeaking(); preview = nil
                previewStatus.lastErrorMessage = nil; saved = false
            }
        if let capabilityMessage { Text(capabilityMessage).font(.caption).foregroundStyle(.secondary) }
        if capabilities != nil && !modelSelectionIsValid {
            Text("原配置模型不在当前支持列表中，请选择后保存；不会自动改用其他模型。")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("保存配置") {
                let configuration = RustVoiceConfiguration(provider: provider,
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    voiceID: voiceID.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model)
                Task { do { try await preferences.save(configuration, for: purpose); saved = true }
                    catch { saved = false; capabilityMessage = "设置未保存，请检查后台连接。" } }
            }
            .disabled(!modelSelectionIsValid)
            if saved { Text("已保存").font(.caption).foregroundStyle(.secondary) }
        }
        Text("传输：本机 HTTP → Rust → 服务商；录放音留在系统设备层。")
            .font(.caption).foregroundStyle(.secondary)
            .task { loadCapabilities(); if purpose == "tts" { refreshVoices() } }
            .onDisappear { cancelPreviewAndList(); capabilityTask?.cancel(); capabilityTask = nil }
    }

    private var providerCapabilities: RustVoiceProviderCapabilities? {
        capabilities?.providers.first(where: { $0.id == provider.rawValue })
    }
    private var supportedModels: [RustVoiceOption] {
        guard let selected = providerCapabilities else { return [] }
        return purpose == "tts" ? selected.ttsModels : selected.asrModels
    }
    private var defaultModelID: String? {
        guard let selected = providerCapabilities else { return nil }
        return purpose == "tts" ? selected.defaultTTSModel : selected.defaultASRModel
    }
    private var modelSelectionIsValid: Bool {
        guard defaultModelID != nil else { return false }
        return supportedModels.contains(where: { $0.id == model })
    }

    private func loadCapabilities() {
        capabilityTask?.cancel()
        capabilityTask = Task { @MainActor in
            do {
                let result = try await voiceClient.capabilities()
                try Task.checkCancellation()
                capabilities = result; capabilityMessage = nil
                if model.isEmpty { model = defaultModelID ?? "" }
            } catch {
                guard !Task.isCancelled else { return }
                capabilityMessage = "模型列表暂时无法加载，请重新打开设置；不会更改已有配置。"
            }
        }
    }

    private var currentConfiguration: RustVoiceConfiguration {
        let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = preferences.configuration(provider: provider, for: purpose)
        return RustVoiceConfiguration(provider: provider,
            apiKey: enteredKey.isEmpty ? available.apiKey : enteredKey,
            voiceID: voiceID.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model)
    }

    private func refreshVoices() {
        listTask?.cancel()
        let configuration = currentConfiguration
        guard configuration.provider == .bailian || !configuration.apiKey.isEmpty else {
            voices = []; voiceMessage = "请先填写该服务的 API Key，再刷新声音。"; loadingVoices = false
            return
        }
        loadingVoices = true; voiceMessage = nil
        listTask = Task { @MainActor in
            defer { if !Task.isCancelled { loadingVoices = false } }
            do {
                let result = try await voiceClient.listVoices(configuration: configuration)
                try Task.checkCancellation()
                guard provider == configuration.provider else { return }
                voices = result
                voiceMessage = result.isEmpty ? "当前列表没有可用声音；也可展开高级设置填写声音 ID。" : "已加载 \(result.count) 个声音（最多 100 个）；选择后请保存。"
            } catch {
                guard !Task.isCancelled else { return }
                voiceMessage = "声音列表暂时无法加载，请检查密钥、额度或网络后刷新。"
            }
        }
    }

    private func playPreview() {
        preview?.stopSpeaking()
        let configuration = currentConfiguration
        let synthesizer = RustSpeechSynthesizer(configuration: { configuration }, statusStore: previewStatus, client: voiceClient)
        preview = synthesizer
        synthesizer.speak("你好，这是当前选中的声音。欢迎来到你的生活空间。")
    }

    private func cancelPreviewAndList() {
        listTask?.cancel(); listTask = nil; loadingVoices = false
        preview?.stopSpeaking(); preview = nil
        previewStatus.lastErrorMessage = nil
    }
}

@MainActor
struct AgentSettingsView: View {
    @State private var model = AgentSettingsModel()
    @State private var voiceStatus = RealtimeVoiceStatusStore.shared
    @AppStorage("resident.autonomous.enabled.v1") private var residentAutonomyEnabled = true
    private let connectRealtimeVoice:
        (RealtimeVoiceConfiguration) -> Void
    private let disconnectRealtimeVoice: () -> Void
    private let agentConfigurationChanged: () -> Void

    init(
        connectRealtimeVoice:
            @escaping (RealtimeVoiceConfiguration) -> Void = { _ in },
        disconnectRealtimeVoice: @escaping () -> Void = {},
        agentConfigurationChanged: @escaping () -> Void = {}
    ) {
        self.connectRealtimeVoice = connectRealtimeVoice
        self.disconnectRealtimeVoice = disconnectRealtimeVoice
        self.agentConfigurationChanged = agentConfigurationChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("DJ 内核") {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                            .background(
                                Color.blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("gmgn DJ")
                                .fontWeight(.medium)
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if model.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else if model.codexState.isSignedIn {
                            Button("退出登录", role: .destructive) {
                                Task { await model.disconnectCodex() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("登录") {
                                Task { await model.connectCodex() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.codexState == .unavailable)
                        }
                    }
                    .padding(.vertical, 4)

                    Text("Codex 提供策划和推理能力；它与下面的声音共同属于同一个 DJ。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        isOn: Binding(
                            get: { model.takeoverEnabled },
                            set: { enabled in
                                model.takeoverEnabled = enabled
                                model.saveAgentConfiguration()
                                agentConfigurationChanged()
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许 DJ 自动接管")
                            Text("可以自主切歌、暂停、继续、重排节目和调整视觉。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("策划模型") {
                        TextField(
                            "使用 Codex 默认模型",
                            text: Binding(
                                get: { model.planningModel },
                                set: { value in
                                    model.planningModel = value
                                    model.saveAgentConfiguration(
                                        showMessage: false
                                    )
                                }
                            )
                        )
                        .frame(width: 220)
                    }
                }

                Section("DJ 人格与偏好") {
                    TextEditor(text: $model.hostPrompt)
                        .font(.body)
                        .frame(minHeight: 150)

                    HStack {
                        Text("用自然语言告诉 DJ 怎么策划和主持。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("保存") {
                            model.savePrompt()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("居民人格") {
                    TextEditor(text: $model.residentPersona)
                        .font(.body)
                        .frame(minHeight: 120)

                    HStack {
                        Text("只影响居民，和上面的 DJ 偏好分开。人格只改语气和关注点，不改变它能做什么。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("保存") {
                            model.saveResidentPersona()
                            notifyResidentAutonomyChanged()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("聊天模型") {
                    Picker(
                        "模型",
                        selection: Binding(
                            get: {
                                model.selectedConversationBackendID
                            },
                            set: { model.selectConversationBackend($0) }
                        )
                    ) {
                        ForEach(
                            AgentConversationBackends.all
                        ) { backend in
                            Text(
                                backend.displayName
                                    + (
                                        model
                                            .isConversationBackendInstalled(
                                                backend.kind
                                            )
                                            ? "" : "（未安装）"
                                    )
                            )
                            .tag(backend.kind)
                        }
                    }

                    Text(model.conversationBackendStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("空间和 Live Cam 共用这里选定的 Agent；文字和语音转写进入同一个会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("允许居民自主安排活动", isOn: $residentAutonomyEnabled)
                        .onChange(of: residentAutonomyEnabled) { _, _ in
                            notifyResidentAutonomyChanged()
                        }
                    Text("打开后，居民会自己观察和行动，会消耗模型额度。设为 0 就不再新起一轮，要先停下请按停止。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("每小时后台思考预算") {
                        Picker(
                            "每小时后台思考预算",
                            selection: Binding(
                                get: {
                                    model.backgroundTurnsPerHour
                                },
                                set: { value in
                                    _ = model
                                        .saveBackgroundTurnsPerHour(value)
                                    notifyResidentAutonomyChanged()
                                }
                            )
                        ) {
                            ForEach(
                                0...ResidentPreferences
                                    .maximumBackgroundTurnsPerHour,
                                id: \.self
                            ) { value in
                                Text(
                                    value == 0 ? "0 轮（不再新起）" : "\(value) 轮"
                                )
                                .tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    Text("按最近一小时算，默认 6。这只数后台思考的次数，不等于请求次数或费用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("回复语音") {
                    Toggle("自动朗读 Agent 回复", isOn: Binding(
                        get: { model.autoSpeakAgentReplies },
                        set: { model.setAutoSpeakAgentReplies($0) }))
                    RustSpeechConfigurationFields(purpose: "tts")
                    Text("Rust 流式合成，开麦停止旧朗读；失败保留文字，不自动切换服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("按住说话") {
                    RustSpeechConfigurationFields(purpose: "asr")
                    Text("在空间或 Live Cam 按住麦克风录音，松开后将完整转写交给当前 Agent。没有双向实时通话。")
                        .font(.caption).foregroundStyle(.secondary)
                    if voiceStatus.state.isConversationOpen {
                        Button("取消录音", action: disconnectRealtimeVoice)
                    }
                }

            }
            .formStyle(.grouped)

            if let message = model.message {
                Label(
                    message,
                    systemImage: model.hasError
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .task { await model.load() }
    }

    /// 复用既有的自主设置通知，让宿主热更新自主开关与后台思考预算；
    /// 居民人格本身由居民会话每轮重新读取，无需重建会话。
    private func notifyResidentAutonomyChanged() {
        NotificationCenter.default.post(
            name: Notification.Name("gmgnResidentAutonomyChanged"),
            object: nil
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Agent 与语音")
                .font(.title2.weight(.semibold))
            Text("文字和语音共用同一会话，回答后再朗读")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        switch model.codexState {
        case .unavailable:
            "策划引擎当前不可用"
        case .signedOut:
            "策划引擎未登录"
        case let .signedIn(method):
            "策划引擎已使用 \(method) 登录"
        }
    }

    private var voiceStatusText: String {
        switch voiceStatus.state {
        case .disconnected:
            "尚未连接"
        case .connecting:
            "正在连接麦克风和转写服务"
        case .connected:
            "录音已就绪，说完一句自动发送"
        case .listening:
            "正在录音和转写"
        case .speaking:
            "正在朗读 Agent 回复"
        case let .failed(message):
            message
        }
    }

    private var voiceStatusIcon: String {
        switch voiceStatus.state {
        case .disconnected:
            "mic.slash"
        case .connecting:
            "ellipsis"
        case .connected:
            "waveform.circle.fill"
        case .listening:
            "ear.fill"
        case .speaking:
            "speaker.wave.2.fill"
        case .failed:
            "exclamationmark.circle.fill"
        }
    }

    private var voiceStatusColor: Color {
        switch voiceStatus.state {
        case .connected, .listening, .speaking:
            .cyan
        case .failed:
            .red
        case .disconnected, .connecting:
            .secondary
        }
    }
}

private extension RealtimeVoiceConnectionState {
    var isConversationOpen: Bool {
        switch self {
        case .connecting, .connected, .listening, .speaking:
            true
        case .disconnected, .failed:
            false
        }
    }
}
