import SwiftUI

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

                Section("Agent 聊天后端") {
                    Picker(
                        "后端",
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
                            NotificationCenter.default.post(name: Notification.Name("gmgnResidentAutonomyChanged"), object: nil)
                        }
                    Text("开启后，居民可在空闲或活动变化时使用当前 Codex 思考并操作已支持的物件，会消耗模型额度。试验版每小时最多主动思考 6 轮，停止按钮可随时暂停。其他后端暂不自动运行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("回复语音") {
                    Toggle(
                        isOn: Binding(
                            get: { model.autoSpeakAgentReplies },
                            set: {
                                model.setAutoSpeakAgentReplies($0)
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动朗读 Agent 回复")
                            Text("选定的 Agent 回答后，使用百炼语音朗读；开麦会停止旧朗读。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("朗读服务", value: "百炼 Qwen3 TTS")
                    Picker("回复音色", selection: Binding(
                        get: { model.selectedReplyVoiceID },
                        set: { model.selectReplyVoice($0) }
                    )) {
                        ForEach(BailianTTSVoice.allCases) { voice in
                            Text(voice.title).tag(voice.rawValue)
                        }
                    }
                    Text("与下方百炼转写共用本机 API Key。只朗读选定 Agent 的回答，失败时保留文字，不切换到其它回答模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("语音输入") {
                    Picker(
                        "服务",
                        selection: Binding(
                            get: { model.realtimeProvider },
                            set: { model.selectRealtimeProvider($0) }
                        )
                    ) {
                        ForEach(
                            RealtimeDJProvider.allCases,
                            id: \.self
                        ) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }

                    providerConfigurationFields

                    LabeledContent("传输") {
                        Text(model.realtimeProvider.transportLabel)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label(voiceStatusText, systemImage: voiceStatusIcon)
                            .font(.caption)
                            .foregroundStyle(voiceStatusColor)

                        Spacer()

                        if model.realtimeProvider == .bailian {
                            Button("保存配置") {
                                _ = model.saveVoiceConfiguration()
                            }
                            .buttonStyle(.bordered)
                        }
                        if voiceStatus.state.isConversationOpen {
                            Button("取消录音") {
                                disconnectRealtimeVoice()
                            }
                            .buttonStyle(.bordered)
                        } else if model.realtimeProvider.canConnectLocally {
                            Button("录制一句") {
                                guard
                                    let configuration =
                                        model.saveVoiceConfiguration()
                                else {
                                    return
                                }
                                connectRealtimeVoice(configuration)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                voiceStatus.state == .connecting
                            )
                        } else {
                            Button("保存配置") {
                                _ = model.saveVoiceConfiguration()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text(providerHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("语音转文字 → 选定的 Agent → 百炼朗读。说完一句后麦克风自动关闭，转写服务不生成回答。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            "此服务尚未接入居民语音转写，请选择百炼或直接输入文字。原有配置可以保留。"
        case .bailian:
            "API Key 仅保存在本机配置中。百炼只负责语音转写，固定使用 Qwen3 ASR；无需配置回答模型或音色。"
        case .doubao:
            "此服务尚未接入居民语音转写，请选择百炼或直接输入文字。"
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
