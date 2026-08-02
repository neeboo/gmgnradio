import SwiftUI

@MainActor
struct GMGNSettingsView: View {
    private enum Page: String, CaseIterable {
        case presence = "桌宠"
        case music = "音乐"
        case visual = "视觉"
        case agent = "DJ"
    }

    @State private var page = Page.presence
    @ObservedObject private var visualDirections: StageVisualDirectionStore
    private let connectRealtimeVoice:
        (RealtimeVoiceConfiguration) -> Void
    private let disconnectRealtimeVoice: () -> Void
    private let agentConfigurationChanged: () -> Void

    init(
        visualDirections: StageVisualDirectionStore,
        connectRealtimeVoice:
            @escaping (RealtimeVoiceConfiguration) -> Void = { _ in },
        disconnectRealtimeVoice: @escaping () -> Void = {},
        agentConfigurationChanged: @escaping () -> Void = {}
    ) {
        _visualDirections = ObservedObject(wrappedValue: visualDirections)
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
            .frame(width: 240)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Group {
                switch page {
                case .presence:
                    PresenceSettingsView()
                case .music:
                    MusicAccountsView()
                case .visual:
                    VisualSettingsView(visualDirections: visualDirections)
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
            }
            .formStyle(.grouped)
        }
    }
}
