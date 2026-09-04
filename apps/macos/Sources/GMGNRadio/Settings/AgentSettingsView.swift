import SwiftUI

@MainActor
struct AgentSettingsView: View {
    @State private var model = AgentSettingsModel()
    @State private var voiceStatus = RealtimeVoiceStatusStore.shared
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
                            Text("使用系统语音朗读文字回复，与实时语音相互独立。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Live Cam 的文字聊天直接走这里选定的后端，无需连接实时语音。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DJ 声音") {
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

                        if voiceStatus.state.isConversationOpen {
                            Button("断开") {
                                disconnectRealtimeVoice()
                            }
                            .buttonStyle(.bordered)
                        } else if model.realtimeProvider.canConnectLocally {
                            Button("连接语音") {
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

                    Text("实时语音为实验功能，仅影响麦克风语音对话；Live Cam 文字聊天无需连接这里。")
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
            Picker(
                "实时模型",
                selection: Binding(
                    get: { model.voiceModel },
                    set: { model.selectBailianModel($0) }
                )
            ) {
                ForEach(BailianRealtimeOptions.models) { option in
                    Text(option.title)
                        .tag(option.id)
                }
            }
            Picker(
                "音色",
                selection: $model.voiceID
            ) {
                ForEach(
                    BailianRealtimeOptions.voices(
                        for: model.voiceModel
                    )
                ) { option in
                    Text(option.title)
                        .tag(option.id)
                }
            }
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
            "可填写公开 Agent ID；私有 Agent 的 API Key 保存在本机配置中。"
        case .bailian:
            "API Key 保存在本机配置中；改麦克风后请断开再连接。连接后由百炼负责听你说话和实时主持。"
        case .doubao:
            "豆包凭据会保存在本机；当前客户端尚未安装 RTC 连接器。"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("智能 DJ")
                .font(.title2.weight(.semibold))
            Text("同一个 DJ 负责策划、主持和播放")
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
            "正在连接麦克风和实时会话"
        case .connected:
            "已连接，可以直接和 DJ 说话"
        case .listening:
            "DJ 正在听"
        case .speaking:
            "DJ 正在说话"
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
        hasLocalRuntime
    }
}

private extension RealtimeVoiceConnectionState {
    var isConversationOpen: Bool {
        switch self {
        case .connected, .listening, .speaking:
            true
        case .disconnected, .connecting, .failed:
            false
        }
    }
}
