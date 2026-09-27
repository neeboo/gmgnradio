import Observation
import MotionDistribution
import SwiftUI

struct PresenceSettingsView: View {
    @State private var model = PresenceSettingsModel()
    @State private var isAddingFromLink = false
    @State private var motionCategory: MotionLibraryCategory?

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("角色") {
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

                Section {
                    Picker("分类", selection: $motionCategory) {
                        Text("全部").tag(MotionLibraryCategory?.none)
                        ForEach(MotionLibraryCategory.allCases) { category in
                            Text(category.title).tag(MotionLibraryCategory?.some(category))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if let notice = model.motionListNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.motions(in: motionCategory), id: \.id) { motion in
                        MotionRow(
                            motion: motion,
                            compatibility: model.motionCompatibility(motion),
                            isActive: model.activeMotionID == motion.id,
                            action: { model.activateMotion(motion) },
                            removeAction: model.isBuiltInMotion(motion)
                                ? nil
                                : { model.removeMotion(motion) }
                        )
                    }
                    if motionCategory != nil, model.motionListNotice == nil,
                       model.motions(in: motionCategory).isEmpty {
                        Text("这个分类下暂无当前角色可用的动作。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("动作")
                } footer: {
                    Text("VRM 列表显示 VRMA 和自然待机；PMX 列表显示 VMD 和自然待机。切换角色格式时会分别记住动作选择。两类动作都保留安装，已有转接播放能力不变。")
                }

                Section("动作库") {
                    HStack(spacing: 10) {
                        TextField(
                            "动作目录地址",
                            text: $model.remoteMotionCatalogURL,
                            prompt: Text("https://…/catalog.json")
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await model.refreshPublishedMotions() }
                        }

                        Button("获取动作列表") {
                            Task { await model.refreshPublishedMotions() }
                        }
                        .disabled(model.isWorking || model.remoteMotionCatalogURL.isEmpty)
                    }

                    if model.publishedMotions.isEmpty == false,
                       model.availablePublishedMotions.isEmpty,
                       let notice = model.motionListNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.availablePublishedMotions, id: \.catalogIdentity) { published in
                        PublishedMotionRow(
                            motion: published,
                            installState: model.publishedMotionInstallState(published),
                            action: {
                                Task { await model.installPublishedMotion(published) }
                            }
                        )
                    }
                }

                if model.activeAvatarEngine == .orb {
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
                            Text("\(Int(model.orbAppearance.flowIntensity * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
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
        .onChange(of: model.activeAvatarID) { _, _ in model.load() }
        .sheet(isPresented: $isAddingFromLink) {
            AddPresenceFromLinkSheet(
                model: model,
                isPresented: $isAddingFromLink
            )
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
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
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
                Text("角色与动作")
                    .font(.title2.weight(.semibold))
                Text("选择 DJ 的形象与表演动作")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    model.importModel()
                } label: {
                    Label("角色模型…", systemImage: "person.crop.rectangle")
                }

                Button {
                    model.importMotion()
                } label: {
                    Label("动作文件…", systemImage: "figure.dance")
                }

                Divider()

                Button {
                    isAddingFromLink = true
                } label: {
                    Label("从链接导入角色…", systemImage: "link")
                }
            } label: {
                Label("导入", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

private extension PublishedMotion {
    var catalogIdentity: String { "\(id)@\(version)" }
}

private struct PublishedMotionRow: View {
    let motion: PublishedMotion
    let installState: PresenceSettingsModel.PublishedMotionInstallState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: motion.loop ? "repeat" : "figure.dance")
                .frame(width: 28, height: 28)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(motion.name)
                    .fontWeight(.medium)
                Text("版本 \(motion.version) · \(motion.duration, format: .number.precision(.fractionLength(1))) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installState == .installed {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button(
                    installState == .updateAvailable ? "更新" : "安装",
                    action: action
                )
            }
        }
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
                Label("当前角色", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
            } else if !package.rendererAvailable {
                Text("等待 \(engineName) 渲染")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let action {
                Button("选择", action: action)
                    .buttonStyle(.borderless)
            }

            if let removeAction {
                Menu {
                    Button("移除角色", role: .destructive, action: removeAction)
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
            return "内置 · \(engineName)"
        }
        let source = package.manifest.author ?? engineName
        return "\(source) · \(package.manifest.version)"
    }

    private var engineName: String {
        switch package.manifest.engine {
        case .live2D: "Live2D"
        case .vrm: "VRM"
        case .pmx: "PMX"
        case .orb: "呼吸球"
        }
    }
}

private struct MotionRow: View {
    let motion: StageMotionAsset
    let compatibility: PresenceSettingsModel.MotionCompatibility
    let isActive: Bool
    let action: () -> Void
    let removeAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: motion.format == .procedural
                ? "figure.mind.and.body"
                : "figure.dance")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isCompatible ? Color.cyan : Color.secondary)
                .frame(width: 40, height: 40)
                .background(
                    (isCompatible ? Color.cyan : Color.secondary)
                        .opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(motion.name)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isCompatible ? Color.secondary : Color.orange)
            }

            Spacer()

            if isActive, isCompatible {
                Label("当前动作", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
            } else {
                Button("选择", action: action)
                    .buttonStyle(.borderless)
                    .disabled(!isCompatible)
            }

            if let removeAction {
                Menu {
                    Button("移除动作", role: .destructive, action: removeAction)
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

    private var isCompatible: Bool {
        compatibility == .compatible
    }

    private var detail: String {
        switch compatibility {
        case .compatible:
            return formatName
        case let .incompatible(reason):
            return "\(formatName) · \(reason)"
        }
    }

    private var formatName: String {
        switch motion.format {
        case .procedural: "内置动态"
        case .vrma: "VRMA"
        case .vmd: "VMD"
        }
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
                Image(systemName: package.manifest.engine == .pmx
                    ? "figure.arms.open"
                    : "person.crop.circle")
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
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                .shadow(color: .blue.opacity(0.35), radius: 6)
                .scaleEffect(breath)
        }
    }
}

private struct AddPresenceFromLinkSheet: View {
    @Bindable var model: PresenceSettingsModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("从链接导入角色")
                    .font(.title2.weight(.semibold))
                Text("支持 HTTPS 地址指向 VRM、ZIP 或 gmgnpet 模型包。")
                    .foregroundStyle(.secondary)
            }

            TextField("https://example.com/avatar.vrm", text: $model.downloadURL)
                .textFieldStyle(.roundedBorder)

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
                Button("下载并安装") {
                    Task {
                        await model.downloadAndInstall()
                        if !model.hasError {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.downloadURL.isEmpty || model.isWorking)
            }
        }
        .padding(24)
        .frame(width: 460, height: 230)
    }
}
