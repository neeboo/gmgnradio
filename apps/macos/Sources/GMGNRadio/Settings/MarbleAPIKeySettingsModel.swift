import Foundation
import Observation

@MainActor
@Observable
final class MarbleAPIKeySettingsModel {
    var replacementKey = ""
    private(set) var isConfigured: Bool
    private(set) var message: String?
    private(set) var hasError = false

    private let provider: MarbleAPIKeyProvider

    init(provider: MarbleAPIKeyProvider = MarbleAPIKeyProvider()) {
        self.provider = provider
        isConfigured = provider.isConfigured
    }

    func save() {
        do {
            try provider.save(replacementKey)
            replacementKey = ""
            isConfigured = true
            message = "Marble API Key 已保存。"
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    func clear() {
        do {
            try provider.remove()
            replacementKey = ""
            isConfigured = false
            message = "Marble API Key 已清除。"
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }
}
