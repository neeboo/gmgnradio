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

    private let store: PropGenerationConfigurationStore

    init(store: PropGenerationConfigurationStore = PropGenerationConfigurationStore()) {
        self.store = store
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
                    .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("地址与密钥只保存在本机，不使用钥匙串。支持 HTTPS 或本机转发地址；保存不会提交生成任务。")
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
        do {
            let value = try store.load()
            configured = value != nil
            if let value { endpoint = value.endpoint.absoluteString }
        } catch {
            configured = false
            hasError = true
            message = "许愿机配置读取失败，现有文件已保留。"
        }
    }

    private func save() {
        cancelCheck()
        do {
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PropGenerationError.invalidEndpoint
            }
            // A newly entered key explicitly replaces an unreadable old configuration too.
            let previous = replacementToken.isEmpty ? try store.load() : nil
            let token: String
            if replacementToken.isEmpty, let previous {
                let candidate = try PropGenerationConfiguration(endpoint: url, token: previous.token)
                guard candidate.endpoint == previous.endpoint else {
                    hasError = true
                    message = "更换服务地址时请同时填写密钥。"
                    return
                }
                token = previous.token
            } else {
                token = replacementToken
            }
            let value = try PropGenerationConfiguration(endpoint: url, token: token)
            try store.save(value)
            endpoint = value.endpoint.absoluteString
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

    private func cancelCheck() {
        checkID = nil
        checkTask?.cancel()
        checkTask = nil
    }

    private func checkConnection() {
        cancelCheck()
        do {
            guard let saved = try store.load(),
                  let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                  try PropGenerationConfiguration(endpoint: url, token: saved.token).endpoint == saved.endpoint else {
                hasError = true
                message = "请先保存服务配置，再检测连接。"
                return
            }
            let id = UUID()
            checkID = id
            message = nil
            checkTask = Task { @MainActor in
                defer { if checkID == id { checkID = nil; checkTask = nil } }
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
            }
        } catch {
            hasError = true
            message = "许愿机配置无法读取，请先保存正确配置。"
        }
    }
}
