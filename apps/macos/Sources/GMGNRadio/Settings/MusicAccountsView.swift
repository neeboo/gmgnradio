import Combine
import SwiftUI

struct MusicAccountsView: View {
    @State private var model = MusicAccountsModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("音乐服务") {
                    MusicAccountRow(
                        providerID: .netease,
                        symbol: "music.note",
                        tint: .red,
                        model: model
                    )
                    MusicAccountRow(
                        providerID: .qqMusic,
                        symbol: "music.note.list",
                        tint: .green,
                        model: model
                    )
                    MusicAccountRow(
                        providerID: .appleMusic,
                        symbol: "apple.logo",
                        tint: .pink,
                        model: model
                    )
                }
            }
            .formStyle(.grouped)

            if let message = model.message {
                HStack(spacing: 7) {
                    if model.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(
                            systemName: model.hasError
                                ? "exclamationmark.circle.fill"
                                : "checkmark.circle.fill"
                        )
                    }
                    Text(message)
                }
                .font(.caption)
                .foregroundStyle(
                    model.hasError ? Color.red : Color.secondary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .task { await model.load() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .musicLibrarySyncDidFinish
            )
        ) { notification in
            model.handleSyncCompletion(notification)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("音乐")
                .font(.title2.weight(.semibold))
            Text("DJ 可以使用的账号")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

private struct MusicAccountRow: View {
    let providerID: MusicProviderID
    let symbol: String
    let tint: Color
    @Bindable var model: MusicAccountsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.providerName(providerID))
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state == .authorizing {
                ProgressView()
                    .controlSize(.small)
            } else if state == .connected {
                Button("同步") {
                    Task { await model.sync(providerID) }
                }
                .buttonStyle(.borderless)
                Button("断开") {
                    Task { await model.disconnect(providerID) }
                }
                .buttonStyle(.borderless)
            } else {
                Button("连接") {
                    if providerID == .appleMusic {
                        Task { await model.authorizeAppleMusic() }
                    } else {
                        Task { await model.connect(providerID) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .disabled(model.isWorking)
    }

    private var state: MusicAccountAuthorizationState {
        model.state(for: providerID)
    }

    private var statusText: String {
        switch state {
        case .connected:
            "已连接"
        case .authorizing:
            "正在连接"
        case .expired:
            "登录已过期"
        case .denied:
            "未授权"
        case .unavailable:
            "当前不可用"
        case .disconnected:
            "未连接"
        }
    }
}
