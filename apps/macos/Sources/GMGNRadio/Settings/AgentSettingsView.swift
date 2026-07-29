import SwiftUI

@MainActor
struct AgentSettingsView: View {
    @State private var model = AgentSettingsModel()
    @State private var programStore: DJProgramStore
    private let startAIProgram: () -> Void

    init(
        programStore: DJProgramStore = .shared,
        startAIProgram: @escaping () -> Void = {}
    ) {
        _programStore = State(initialValue: programStore)
        self.startAIProgram = startAIProgram
    }

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

                    Text("复用本机 Codex 登录；节目策划不会读取音乐账号凭据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DJ 偏好") {
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

                Section("节目编排") {
                    programPlanningContent
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
    private var programPlanningContent: some View {
        switch programStore.status {
        case .planning:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("DJ 正在排节目…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .idle, .ready:
            if let plan = programStore.plan {
                let duration = plan.slots.reduce(0) {
                    $0 + $1.track.duration
                }
                Text(
                    "\(plan.slots.count) 首 · 约 \(max(1, Int(duration / 60))) 分钟"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(
                    Array(plan.slots.prefix(6).enumerated()),
                    id: \.element.track.id
                ) { index, slot in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .leading)
                        Text(slot.track.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(slot.track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if plan.slots.count > 6 {
                    Text("还有 \(plan.slots.count - 6) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("从已连接的音乐账号里生成一档约 30 分钟的节目。")
                    .foregroundStyle(.secondary)
            }
        }

        Button(
            programStore.plan == nil
                ? "按这个偏好排节目"
                : "重新编排"
        ) {
            model.savePrompt()
            startAIProgram()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            programStore.status == .planning
                || !model.codexState.isSignedIn
        )
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
