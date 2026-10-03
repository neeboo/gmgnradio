import SwiftUI

@MainActor
private struct RustSpeechConfigurationFields: View {
    let purpose: String
    @State private var provider: RustVoiceProvider
    @State private var apiKey: String
    @State private var voiceID: String
    @State private var model: String
    @State private var saved = false
    private let preferences = RustSpeechPreferences(defaults: E2ERuntime.defaults)

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
            // Load that provider's saved credentials, never silently reuse another provider's key.
            let defaults = E2ERuntime.defaults
            let prefix = "speech.rust.\(selection.rawValue)."
            apiKey = defaults.string(forKey: prefix + "apiKey")
                ?? (selection == .bailian ? defaults.string(forKey: "voice.bailian.apiKey") ?? "" : "")
            voiceID = defaults.string(forKey: prefix + "voiceID") ?? (selection == .bailian ? "Cherry" : "")
            model = defaults.string(forKey: prefix + purpose + ".model") ?? ""
            saved = false
        }
        SecureField("API Key", text: $apiKey)
        if purpose == "tts" {
            TextField(provider == .fish ? "Reference ID" : "Voice ID", text: $voiceID)
        }
        TextField("模型（留空使用服务默认值）", text: $model)
        HStack {
            Button("保存配置") {
                preferences.save(RustVoiceConfiguration(provider: provider,
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    voiceID: voiceID.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model), for: purpose)
                saved = true
            }
            if saved { Text("已保存").font(.caption).foregroundStyle(.secondary) }
        }
        Text("传输：本机 TCP → Rust → 服务商；录放音留在系统设备层。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor
struct AgentSettingsView: View {
    @State private var model = AgentSettingsModel()
    @State private var voiceStatus = RealtimeVoiceStatusStore.shared
    @AppStorage("resident.autonomous.enabled.v1") private var residentAutonomyEnabled = false
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

    @ViewBuilder
    private var providerConfigurationFields: some View {
        switch model.realtimeProvider {
        case .elevenLabs:
            TextField(
                "Agent ID",
                text: $model.elevenLabsAgentID,
                prompt: Text("agent_...")
            )
            SecureField(
                "API Key（私有 Agent）",
                text: $model.voiceAPIKey,
                prompt: Text("sk_...")
            )
            SecureField(
                "会话令牌（可选）",
                text: $model.elevenLabsConversationToken,
                prompt: Text("已有短期令牌时填写")
            )
            TextField(
                "音色 ID（可选）",
                text: $model.elevenLabsVoiceID,
                prompt: Text("留空则使用 Agent 默认音色")
            )
        case .bailian:
            SecureField(
                "API Key",
                text: $model.voiceAPIKey,
                prompt: Text("sk-...")
            )
            LabeledContent("转写模型", value: "Qwen3 ASR Flash")
            Picker(
                "麦克风",
                selection: $model.voiceMicrophoneDeviceID
            ) {
                Text(model.systemMicrophoneLabel)
                    .tag("")
                ForEach(model.voiceMicrophoneDevices) { device in
                    Text(device.name)
                        .tag(device.id)
                }
            }
        case .doubao:
            TextField(
                "RTC App ID",
                text: $model.voiceAppID
            )
            SecureField(
                "Access Token",
                text: $model.voiceAccessToken
            )
            TextField(
                "Resource ID",
                text: $model.voiceResourceID
            )
            TextField(
                "音色",
                text: $model.voiceID,
                prompt: Text("供应商音色 ID")
            )
        }
    }

    private var providerHelpText: String {
        switch model.realtimeProvider {
        case .elevenLabs:
            "这个服务还不能转写语音，请选百炼，或直接打字。"
        case .bailian:
            "密钥只存在这台电脑上。百炼只用来说话转文字，不用再配别的。"
        case .doubao:
            "这个服务还不能转写语音，请选百炼，或直接打字。"
        }
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

private extension RealtimeDJProvider {
    var displayName: String {
        switch self {
        case .bailian:
            "阿里云百炼"
        case .doubao:
            "豆包实时语音"
        case .elevenLabs:
            "ElevenLabs"
        }
    }

    var transportLabel: String {
        switch capabilities.transport {
        case .streamingWebSocket:
            "实时 WebSocket"
        case .rtcRoom:
            "RTC"
        case .webRTC:
            "WebRTC"
        }
    }

    var canConnectLocally: Bool {
        self == .bailian
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
