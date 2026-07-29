import SwiftUI

struct AgentSettingsView: View {
    @State private var model = AgentSettingsModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("策划 Agent") {
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
                            Text("Codex")
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
                            Button("刷新") {
                                Task { await model.refresh() }
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button("登录") {
                                Task { await model.connectCodex() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.codexState == .unavailable)
                        }
                    }
                    .padding(.vertical, 4)

                    Text("复用本机 Codex 登录；节目策划不会读取音乐账号凭据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DJ 偏好") {
                    TextEditor(text: $model.hostPrompt)
                        .font(.body)
                        .frame(minHeight: 76)

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("智能 DJ")
                .font(.title2.weight(.semibold))
            Text("负责排节目和主持")
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
            "未安装 Codex"
        case .signedOut:
            "未登录"
        case let .signedIn(method):
            "已使用 \(method) 登录"
        }
    }
}
