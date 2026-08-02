import Observation
import SwiftUI

struct PresenceSettingsView: View {
    @State private var model = PresenceSettingsModel()
    @State private var isAddingModel = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("桌宠外观") {
                    ForEach(model.packages, id: \.manifest.id) { package in
                        PresenceRow(
                            package: package,
                            action: package.isActive || !package.rendererAvailable
                                ? nil
                                : { model.activate(package) },
                            removeAction: package.isBuiltIn
                                ? nil
                                : { model.remove(package) }
                        )
                    }
                }

                Section("呼吸球样式") {
                    ColorPicker(
                        "流光颜色",
                        selection: orbColorBinding,
                        supportsOpacity: false
                    )

                    HStack(spacing: 12) {
                        Text("流光强度")
                        Slider(
                            value: Binding(
                                get: {
                                    Double(model.orbAppearance.flowIntensity)
                                },
                                set: {
                                    model.setOrbFlowIntensity(Float($0))
                                }
                            ),
                            in: 0.35 ... 1.5
                        )
                        Text(
                            "\(Int(model.orbAppearance.flowIntensity * 100))%"
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)

            if let message = model.message {
                HStack(spacing: 7) {
                    Image(systemName: model.hasError
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill")
                    Text(message)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .task { model.load() }
        .sheet(isPresented: $isAddingModel) {
            AddPresenceSheet(model: model, isPresented: $isAddingModel)
        }
    }

    private var orbColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: Double(model.orbAppearance.red),
                    green: Double(model.orbAppearance.green),
                    blue: Double(model.orbAppearance.blue)
                )
            },
            set: { color in
                guard
                    let converted = NSColor(color).usingColorSpace(.sRGB)
                else {
                    return
                }
                model.setOrbColor(
                    red: Float(converted.redComponent),
                    green: Float(converted.greenComponent),
                    blue: Float(converted.blueComponent)
                )
            }
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("桌宠")
                    .font(.title2.weight(.semibold))
                Text("DJ 在桌面上的样子")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isAddingModel = true
            } label: {
                Label("添加模型", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

private struct PresenceRow: View {
    let package: PresencePackage
    let action: (() -> Void)?
    let removeAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            PresencePreview(package: package)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(package.manifest.name)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if package.isActive {
                Text("使用中")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
            } else if !package.rendererAvailable {
                Text(waitingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let action {
                Button("使用", action: action)
                    .buttonStyle(.borderless)
            }

            if let removeAction {
                Menu {
                    Button("移除模型", role: .destructive, action: removeAction)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        if package.isBuiltIn {
            return "内置 · 呼吸球"
        }
        let source = package.manifest.author ?? engineName
        return "\(source) · \(package.manifest.version)"
    }

    private var engineName: String {
        switch package.manifest.engine {
        case .live2D:
            "Live2D"
        case .vrm:
            "VRM"
        case .orb:
            "呼吸球"
        }
    }

    private var waitingLabel: String {
        "等待 \(engineName) 渲染"
    }
}

private struct PresencePreview: View {
    let package: PresencePackage

    var body: some View {
        Group {
            if
                let path = package.thumbnailPath,
                let image = NSImage(contentsOfFile: path)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if package.manifest.engine == .orb {
                OrbPreview()
                    .padding(3)
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue.opacity(0.75))
                    .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.blue.opacity(0.07))
        )
    }
}

private struct OrbPreview: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let breath = 0.94 + 0.06 * (sin(phase * 1.8) + 1) / 2

            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            .white,
                            Color(red: 0.30, green: 0.66, blue: 1.00),
                            Color(red: 0.08, green: 0.35, blue: 0.95),
                            .white,
                        ],
                        center: .center
                    )
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: .blue.opacity(0.35), radius: 6)
                .scaleEffect(breath)
        }
    }
}

private struct AddPresenceSheet: View {
    @Bindable var model: PresenceSettingsModel
    @Binding var isPresented: Bool
    @State private var showsDownloadField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("添加桌宠模型")
                    .font(.title2.weight(.semibold))
                Text("支持 Live2D 模型包和单个 VRM 文件。")
                    .foregroundStyle(.secondary)
            }

            Button {
                model.importLocal()
                if !model.hasError {
                    isPresented = false
                }
            } label: {
                Label("从本机选择模型包", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isWorking)

            DisclosureGroup("从 HTTPS 链接下载", isExpanded: $showsDownloadField) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://example.com/avatar.vrm", text: $model.downloadURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("下载并安装") {
                            Task {
                                await model.downloadAndInstall()
                                if !model.hasError {
                                    isPresented = false
                                }
                            }
                        }
                        .disabled(model.downloadURL.isEmpty || model.isWorking)
                    }
                }
                .padding(.top, 10)
            }

            if let message = model.message, model.hasError {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: showsDownloadField ? 310 : 230)
    }
}
