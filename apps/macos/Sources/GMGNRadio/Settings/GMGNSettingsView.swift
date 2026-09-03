import SwiftUI

@MainActor
struct GMGNSettingsView: View {
    private enum Page: String, CaseIterable {
        case presence = "角色"
        case music = "音乐"
        case visual = "视觉"
        case shortcuts = "快捷键"
        case agent = "DJ"
    }

    @State private var page = Page.presence
    @State private var marbleAPIKey = MarbleAPIKeySettingsModel()
    @ObservedObject private var visualDirections: StageVisualDirectionStore
    @ObservedObject private var shortcutSettings: GMGNShortcutSettingsStore
    private let connectRealtimeVoice:
        (RealtimeVoiceConfiguration) -> Void
    private let disconnectRealtimeVoice: () -> Void
    private let agentConfigurationChanged: () -> Void

    init(
        visualDirections: StageVisualDirectionStore,
        shortcutSettings: GMGNShortcutSettingsStore,
        connectRealtimeVoice:
            @escaping (RealtimeVoiceConfiguration) -> Void = { _ in },
        disconnectRealtimeVoice: @escaping () -> Void = {},
        agentConfigurationChanged: @escaping () -> Void = {}
    ) {
        _visualDirections = ObservedObject(wrappedValue: visualDirections)
        _shortcutSettings = ObservedObject(wrappedValue: shortcutSettings)
        self.connectRealtimeVoice = connectRealtimeVoice
        self.disconnectRealtimeVoice = disconnectRealtimeVoice
        self.agentConfigurationChanged = agentConfigurationChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置", selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Group {
                switch page {
                case .presence:
                    PresenceSettingsView()
                case .music:
                    MusicAccountsView()
                case .visual:
                    VisualSettingsView(
                        visualDirections: visualDirections,
                        marbleAPIKey: marbleAPIKey
                    )
                case .shortcuts:
                    GMGNShortcutSettingsView(settings: shortcutSettings)
                case .agent:
                    AgentSettingsView(
                        connectRealtimeVoice: connectRealtimeVoice,
                        disconnectRealtimeVoice: disconnectRealtimeVoice,
                        agentConfigurationChanged:
                            agentConfigurationChanged
                    )
                }
            }
        }
    }
}

@MainActor
private struct VisualSettingsView: View {
    @ObservedObject var visualDirections: StageVisualDirectionStore
    @Bindable var marbleAPIKey: MarbleAPIKeySettingsModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("视觉")
                    .font(.title2.weight(.semibold))
                Text("调整舞台点阵的显示效果")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Form {
                Section("3D 点阵") {
                    HStack(spacing: 12) {
                        Text("颗粒大小")
                        Slider(
                            value: Binding(
                                get: {
                                    Double(
                                        visualDirections
                                            .particleSizeMultiplier
                                    )
                                },
                                set: {
                                    visualDirections
                                        .setParticleSizeMultiplier(Float($0))
                                }
                            ),
                            in: Double(
                                StageParticleSizing.manualRange.lowerBound
                            ) ... Double(
                                StageParticleSizing.manualRange.upperBound
                            )
                        )
                        Text(
                            "\(Int(visualDirections.particleSizeMultiplier * 100))%"
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                    }

                    Text("会在不同尺寸的屏幕上自动缩放，这里用于微调最终颗粒大小。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Marble 空间") {
                    HStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("World Labs Marble")
                            Text("用于同步和生成可探索的 3D 空间")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Label(
                            marbleAPIKey.isConfigured ? "已配置" : "未配置",
                            systemImage: marbleAPIKey.isConfigured
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.callout)
                        .foregroundStyle(
                            marbleAPIKey.isConfigured ? .green : .secondary
                        )
                    }

                    SecureField(
                        marbleAPIKey.isConfigured
                            ? "粘贴新的 API Key 可覆盖现有配置"
                            : "粘贴 API Key",
                        text: $marbleAPIKey.replacementKey
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("只保存在本机，不使用钥匙串。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if marbleAPIKey.isConfigured {
                            Button("清除", role: .destructive) {
                                marbleAPIKey.clear()
                            }
                        }

                        Button("保存 Key") {
                            marbleAPIKey.save()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            marbleAPIKey.replacementKey
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                .isEmpty
                        )
                    }

                    if let message = marbleAPIKey.message {
                        Label(
                            message,
                            systemImage: marbleAPIKey.hasError
                                ? "exclamationmark.circle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            marbleAPIKey.hasError ? .red : .secondary
                        )
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
