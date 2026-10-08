import Foundation

/// One configuration consumer for the same store used by the world's wish machine.
/// Legacy credentials may be read only when the composition explicitly authorizes that URL.
@MainActor final class UnityGenerationConfigurationBridge {
    private let generationStore: PropGenerationStore
    private let authority: RustGenerationConfigurationClient
    private let currentFile: URL
    private let legacyFile: URL?
    private var loadTask: Task<Void, Never>?
    private var active: PropGenerationConfiguration?
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var closed = false
    private var noticeCode = "generation_not_configured"
    private var hasError = false

    init(store: PropGenerationStore, authority: RustGenerationConfigurationClient, fileURL: URL, readableLegacyFileURL: URL? = nil) {
        generationStore = store
        self.authority = authority; currentFile = fileURL; legacyFile = readableLegacyFileURL
        loadTask = Task { [weak self] in await self?.load() }
    }
    var snapshot: [String: Any] {
        ["endpoint": active?.endpoint.absoluteString ?? "", "configured": active != nil,
         "checking": checkID != nil, "noticeCode": noticeCode,
         "hasError": hasError || generationStore.errorMessage != nil,
         "serviceError": generationStore.errorMessage != nil]
    }
    func settingsCommand(_ value: [String: Any]) async -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        await loadTask?.value
        guard !closed else { return false }
        switch op {
        case "generation.load": await load()
        case "generation.save":
            guard value.keys.allSatisfy({ ["op", "endpoint", "token"].contains($0) }),
                  let endpoint = value["endpoint"] as? String,
                  value["token"] == nil || value["token"] is String else { return false }
            await save(endpoint: endpoint, replacementToken: value["token"] as? String ?? "")
        case "generation.check": check()
        default: return false
        }
        return !hasError
    }
    func close() { closed = true; cancelCheck() }
    private func load() async {
        guard !closed else { return }; cancelCheck()
        do {
            let receipt = try await authority.load(currentFile: currentFile, legacyFile: legacyFile)
            let value = try await authority.configuration(receipt)
            guard !closed else { return }
            if value != active || value == nil {
                generationStore.clearConfiguration(); active = nil
                if let value { try generationStore.configure(endpoint: value.endpoint, token: value.token); active = value }
            }
            hasError = false
            noticeCode = active == nil ? "generation_not_configured" : "generation_configuration_loaded"
        } catch {
            guard !closed else { return }
            generationStore.clearConfiguration(); active = nil
            hasError = true; noticeCode = "generation_configuration_unreadable"
        }
    }
    private func save(endpoint: String, replacementToken: String) async {
        guard !closed else { return }
        cancelCheck()
        do {
            let receipt = try await authority.save(endpoint: endpoint, replacementToken: replacementToken)
            guard let value = try await authority.configuration(receipt), !closed else { return }
            try generationStore.configure(endpoint: value.endpoint, token: value.token)
            active = value; hasError = false; noticeCode = "generation_configuration_saved"
        } catch {
            guard !closed else { return }
            // No confirmed receipt: preserve the previous active consumer.
            hasError = true; noticeCode = "generation_configuration_save_failed"
        }
    }
    private func cancelCheck() { checkID = nil; checkTask?.cancel(); checkTask = nil }
    private func check() {
        cancelCheck()
        guard let active else { hasError = true; noticeCode = "generation_not_configured"; return }
        let id = UUID(); checkID = id
        checkTask = Task { [weak self] in
            do {
                _ = try await PropGenerationClient(endpoint: active.endpoint, token: active.token).health()
                guard let self, checkID == id, !Task.isCancelled else { return }
                checkID = nil; checkTask = nil; hasError = false; noticeCode = "generation_connection_ok"
            } catch {
                guard let self, checkID == id, !Task.isCancelled else { return }
                checkID = nil; checkTask = nil; hasError = true; noticeCode = "generation_connection_failed"
            }
        }
    }
}
