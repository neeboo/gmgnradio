import Foundation

/// One configuration consumer for the same store used by the world's wish machine.
/// Legacy credentials may be read only when the composition explicitly authorizes that URL.
@MainActor final class UnityGenerationConfigurationBridge {
    private let generationStore: PropGenerationStore
    private let configurationStore: PropGenerationConfigurationStore
    private let legacyStore: PropGenerationConfigurationStore?
    private var active: PropGenerationConfiguration?
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var closed = false
    private var noticeCode = "generation_not_configured"
    private var hasError = false

    init(store: PropGenerationStore, fileURL: URL, readableLegacyFileURL: URL? = nil) {
        generationStore = store
        configurationStore = PropGenerationConfigurationStore(fileURL: fileURL)
        legacyStore = readableLegacyFileURL.flatMap { $0 == fileURL ? nil : PropGenerationConfigurationStore(fileURL: $0) }
        load()
    }
    var snapshot: [String: Any] {
        ["endpoint": active?.endpoint.absoluteString ?? "", "configured": active != nil,
         "checking": checkID != nil, "noticeCode": noticeCode,
         "hasError": hasError || generationStore.errorMessage != nil,
         "serviceError": generationStore.errorMessage != nil]
    }
    func settingsCommand(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        switch op {
        case "generation.load": load()
        case "generation.save":
            guard value.keys.allSatisfy({ ["op", "endpoint", "token"].contains($0) }),
                  let endpoint = value["endpoint"] as? String,
                  value["token"] == nil || value["token"] is String else { return false }
            save(endpoint: endpoint, replacementToken: value["token"] as? String ?? "")
        case "generation.check": check()
        default: return false
        }
        return true
    }
    func close() { closed = true; cancelCheck() }
    private func readConfiguration() throws -> PropGenerationConfiguration? {
        // An existing current file (even unreadable) is authoritative; never resurrect legacy credentials.
        if FileManager.default.fileExists(atPath: configurationStore.fileURL.path) { return try configurationStore.load() }
        return try legacyStore?.load()
    }
    private func load() {
        guard !closed else { return }; cancelCheck()
        do {
            let value = try readConfiguration()
            if value != active || value == nil {
                generationStore.clearConfiguration(); active = nil
                if let value { try generationStore.configure(endpoint: value.endpoint, token: value.token); active = value }
            }
            hasError = false
            noticeCode = active == nil ? "generation_not_configured" : "generation_configuration_loaded"
        } catch {
            generationStore.clearConfiguration(); active = nil
            hasError = true; noticeCode = "generation_configuration_unreadable"
        }
    }
    private func save(endpoint: String, replacementToken: String) {
        cancelCheck()
        do {
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PropGenerationError.invalidEndpoint
            }
            let previous = replacementToken.isEmpty ? try readConfiguration() : nil
            let token: String
            if let previous {
                let candidate = try PropGenerationConfiguration(endpoint: url, token: previous.token)
                guard candidate.endpoint == previous.endpoint else {
                    hasError = true; noticeCode = "generation_endpoint_requires_token"; return
                }
                token = previous.token
            } else { token = replacementToken }
            let value = try PropGenerationConfiguration(endpoint: url, token: token)
            try configurationStore.save(value)
            try generationStore.configure(endpoint: value.endpoint, token: value.token)
            active = value; hasError = false; noticeCode = "generation_configuration_saved"
        } catch {
            // Validation/storage failure must preserve the last active consumer and durable file.
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
