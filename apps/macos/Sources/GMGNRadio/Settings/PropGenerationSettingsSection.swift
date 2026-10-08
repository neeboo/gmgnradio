import SwiftUI

@MainActor
struct PropGenerationSettingsSection: View {
    @State private var endpoint = "http://127.0.0.1:8191"
    @State private var replacementToken = ""
    @State private var configured = false
    @State private var message: String?
    @State private var hasError = false
    @State private var checkTask: Task<Void, Never>?
    @State private var checkID: UUID?
    @State private var saving = false
    private let authority: RustGenerationConfigurationClient
    private let legacyFile: URL
    private let currentFile: URL
    init(authority: RustGenerationConfigurationClient? = nil, legacyFile: URL = PropGenerationConfigurationStore.defaultFileURL) {
        let root = WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase: E2ERuntime.applicationSupportBase)
        self.authority = authority ?? RustGenerationConfigurationClient(root: root)
        self.legacyFile = legacyFile
        currentFile = root.deletingLastPathComponent().appendingPathComponent("secrets/prop-generation.json")
    }

    var body: some View {
        Section("许愿机") {
            TextField("生成服务地址", text: Binding(get: { endpoint }, set: {
                cancelCheck()
                endpoint = $0
                message = nil
            }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            SecureField(configured ? "填写新密钥可替换；留空保留现有密钥" : "生成服务密钥", text: Binding(get: { replacementToken }, set: {
                cancelCheck()
                replacementToken = $0
                message = nil
            }))
                .textFieldStyle(.roundedBorder)

            HStack {
                Label(configured ? "已配置" : "未配置", systemImage: configured ? "checkmark.circle" : "circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(checkID == nil ? "检测连接" : "检测中…") { checkConnection() }
                    .disabled(!configured || checkID != nil || !replacementToken.isEmpty)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }

            Text("地址和密钥只存在这台电脑上，保存后不会立刻开始生成。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(hasError ? Color.red : Color.secondary)
            }
        }
        .onAppear { load() }
        .onDisappear { cancelCheck() }
    }

    private func load() {
      Task { @MainActor in
        do {
            let value = try await authority.load(currentFile: currentFile, legacyFile: legacyFile)
            configured = value.configured
            if let origin = value.endpoint { endpoint = origin }
        } catch {
            configured = false
            hasError = true
            message = "许愿机配置读取失败，现有文件已保留。"
        }
      }
    }

    private func save() {
        cancelCheck()
        guard !saving else { return }; saving = true
      Task { @MainActor in
        defer { saving = false }
        do {
            let value = try await authority.save(endpoint: endpoint, replacementToken: replacementToken)
            guard let origin = value.endpoint else { throw RustGenerationConfigurationClient.ConfigurationError.invalidProtocol }
            endpoint = origin
            replacementToken = ""
            configured = true
            hasError = false
            message = "许愿机配置已保存。"
            NotificationCenter.default.post(name: .propGenerationConfigurationDidChange, object: nil)
        } catch let error as PropGenerationError {
            hasError = true
            message = error.localizedDescription
        } catch {
            hasError = true
            message = "许愿机配置无法保存，请检查本机存储权限。"
        }
      }
    }

    private func cancelCheck() {
        checkID = nil
        checkTask?.cancel()
        checkTask = nil
    }

    private func checkConnection() {
        cancelCheck()
        let id = UUID(); checkID = id
        checkTask = Task { @MainActor in
          defer { if checkID == id { checkID = nil; checkTask = nil } }
        do {
            guard let saved = try await authority.validatedConfiguration(endpoint: endpoint) else {
                hasError = true
                message = "请先保存服务配置，再检测连接。"
                return
            }
            message = nil
                do {
                    let health = try await PropGenerationClient(endpoint: saved.endpoint, token: saved.token).health()
                    guard !Task.isCancelled, checkID == id else { return }
                    hasError = false
                    message = health.message
                } catch {
                    guard !Task.isCancelled, checkID == id else { return }
                    hasError = true
                    message = (error as? PropGenerationError)?.errorDescription
                        ?? "暂时无法连接生成服务，请检查连接后重试。"
                }
        } catch {
            hasError = true
            message = "许愿机配置无法读取，请先保存正确配置。"
        }
        }
    }
}
