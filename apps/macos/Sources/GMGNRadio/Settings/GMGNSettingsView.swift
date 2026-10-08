import SwiftUI

enum GMGNSettingsPage: String, CaseIterable {
    case presence = "角色"
    case music = "音乐"
    case space = "空间"
    case shortcuts = "快捷键"
    case agent = "DJ"
}

@MainActor
final class GMGNSettingsNavigation: ObservableObject {
    static let shared = GMGNSettingsNavigation()
    @Published var page = GMGNSettingsPage.presence
}

enum GMGNSettingsSpacePage {
    /// 系统设置只保留默认空间和长期服务配置；颗粒大小等场景调节只在完整舞台的面板出现。
    static let sectionTitles = ["默认空间", "Marble 空间"]
}

enum DefaultSpacePreference: String, CaseIterable, Identifiable {
    case livingPod = "living-pod"
    case lastMarbleWorld = "last-marble-world"

    static let defaultsKey = "space.default-selection"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .livingPod:
            "飞船生活舱（Marble）"
        case .lastMarbleWorld:
            "上次使用的 Marble 空间"
        }
    }

    var detail: String {
        switch self {
        case .livingPod:
            "Marble 生成舱体，可交互点唱机；资源已内置，无需重新生成"
        case .lastMarbleWorld:
            "恢复你上次选择的 Marble 空间"
        }
    }

    @MainActor static func load(
        defaults: UserDefaults = .standard
    ) -> DefaultSpacePreference {
        RustProductSettingsClient.shared.bootstrap(legacy: RustProductSettingsClient.legacySnapshot(defaults))
        guard let rawValue = RustProductSettingsClient.shared.confirmed?.values.defaultSpace,
              let preference = DefaultSpacePreference(rawValue: rawValue)
        else {
            return .livingPod
        }
        return preference
    }

    @MainActor func save(defaults: UserDefaults = .standard) {
        let settings = RustProductSettingsClient.shared
        settings.bootstrap(legacy: RustProductSettingsClient.legacySnapshot(defaults))
        Task { _ = try? await settings.apply(["defaultSpace": rawValue]) }
    }
}

@MainActor
struct GMGNSettingsView: View {
    @ObservedObject private var navigation = GMGNSettingsNavigation.shared
    @State private var marbleAPIKey = MarbleAPIKeySettingsModel()
    @ObservedObject private var shortcutSettings: GMGNShortcutSettingsStore
    private let connectRealtimeVoice:
        (RealtimeVoiceConfiguration) -> Void
    private let disconnectRealtimeVoice: () -> Void
    private let agentConfigurationChanged: () -> Void

    init(
        shortcutSettings: GMGNShortcutSettingsStore,
        connectRealtimeVoice:
            @escaping (RealtimeVoiceConfiguration) -> Void = { _ in },
        disconnectRealtimeVoice: @escaping () -> Void = {},
        agentConfigurationChanged: @escaping () -> Void = {}
    ) {
        _shortcutSettings = ObservedObject(wrappedValue: shortcutSettings)
        self.connectRealtimeVoice = connectRealtimeVoice
        self.disconnectRealtimeVoice = disconnectRealtimeVoice
        self.agentConfigurationChanged = agentConfigurationChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置", selection: $navigation.page) {
                ForEach(GMGNSettingsPage.allCases, id: \.self) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Group {
                switch navigation.page {
                case .presence:
                    PresenceSettingsView()
                case .music:
                    MusicAccountsView()
                case .space:
                    SpaceSettingsView(marbleAPIKey: marbleAPIKey)
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
private struct SpaceSettingsView: View {
    @Bindable var marbleAPIKey: MarbleAPIKeySettingsModel
    @State private var defaultSpace = DefaultSpacePreference.load()

    private var defaultSpaceSelection: Binding<DefaultSpacePreference> {
        Binding(
            get: { defaultSpace },
            set: { value in
                defaultSpace = value
                value.save()
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("空间")
                    .font(.title2.weight(.semibold))
                Text("选择默认空间，并管理空间生成服务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Form {
                Section("默认空间") {
                    Picker("启动时进入", selection: defaultSpaceSelection) {
                        ForEach(DefaultSpacePreference.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    Text(defaultSpace.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("修改后下次启动生效。")
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
                PropGenerationSettingsSection()
            }
            .formStyle(.grouped)
        }
    }
}
