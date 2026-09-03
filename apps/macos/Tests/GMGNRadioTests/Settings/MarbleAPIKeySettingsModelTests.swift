import Foundation
import Testing
@testable import GMGNRadio

@Test
func marbleAPIKeyProviderSavesTrimmedKeyWithPrivatePermissions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarbleAPIKeyTests-\(UUID().uuidString)")
    let fileURL = root.appendingPathComponent("secrets/world-labs-api-key")
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = MarbleAPIKeyProvider(fileURL: fileURL)
    try provider.save("  test-key\n")

    #expect(try provider.read() == "test-key")
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test
func marbleAPIKeyProviderReportsWhetherAKeyIsConfigured() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarbleAPIKeyStateTests-\(UUID().uuidString)")
    let fileURL = root.appendingPathComponent("secrets/world-labs-api-key")
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = MarbleAPIKeyProvider(fileURL: fileURL)
    #expect(!provider.isConfigured)

    try provider.save("configured-key")

    #expect(provider.isConfigured)
}

@MainActor
@Test
func marbleAPIKeySettingsModelSavesWithoutRetainingTheSecret() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarbleAPIKeyModelTests-\(UUID().uuidString)")
    let fileURL = root.appendingPathComponent("secrets/world-labs-api-key")
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = MarbleAPIKeyProvider(fileURL: fileURL)
    let model = MarbleAPIKeySettingsModel(provider: provider)
    model.replacementKey = "new-private-key"

    model.save()

    #expect(model.isConfigured)
    #expect(model.replacementKey.isEmpty)
    #expect(model.message == "Marble API Key 已保存。")
    #expect(try provider.read() == "new-private-key")
}

@MainActor
@Test
func marbleAPIKeySettingsModelClearsTheStoredKey() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarbleAPIKeyClearTests-\(UUID().uuidString)")
    let fileURL = root.appendingPathComponent("secrets/world-labs-api-key")
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = MarbleAPIKeyProvider(fileURL: fileURL)
    try provider.save("existing-key")
    let model = MarbleAPIKeySettingsModel(provider: provider)

    model.clear()

    #expect(!model.isConfigured)
    #expect(model.message == "Marble API Key 已清除。")
    #expect(throws: MarbleWorldClientError.missingAPIKey) {
        try provider.read()
    }
}
