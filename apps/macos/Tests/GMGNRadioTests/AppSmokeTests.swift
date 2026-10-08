import Foundation
import Testing
@testable import GMGNRadio

@Test
func productIdentityIsStable() {
    #expect(ProductIdentity.displayName == "gmgn radio")
    #expect(ProductIdentity.bundleIdentifier == "ai.gmgn.radio")
}

@Test
func testHostNeverRestoresRealUserPlaybackOrCredentials() {
    #expect(
        ApplicationLaunchPolicy.shouldRestoreUserState(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/gmgn-radio.xctestconfiguration"
            ]
        ) == false
    )
    #expect(
        ApplicationLaunchPolicy.shouldRestoreUserState(
            environment: [:]
        )
    )
}

@Test
func backgroundCredentialReadsCanNeverShowAKeychainPasswordPrompt() throws {
    let macOSRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceFiles = [
        "Sources/GMGNRadio/MusicSources/KeychainMusicProviderSessionStore.swift",
        "Sources/GMGNRadio/Settings/AgentSettingsModel.swift",
        "Sources/GMGNRadio/Presence/ProductSpeechSecretStore.swift",
        "UnityHost/UnityProductSettings.swift",
    ]

    for relativePath in sourceFiles {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        for forbidden in ["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete", "KeychainSpeechSecretStore(", "find-generic-password", "add-generic-password"] {
            #expect(!source.contains(forbidden))
        }
    }
}
