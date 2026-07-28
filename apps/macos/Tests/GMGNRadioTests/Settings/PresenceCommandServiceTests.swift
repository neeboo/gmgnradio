import Foundation
import Testing
@testable import GMGNRadio

@Suite
struct PresenceCommandServiceTests {
    @Test
    func listReturnsJSONReadyPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-command-tests-\(UUID().uuidString)")
        let service = PresenceCommandService(
            store: PresencePackageStore(rootURL: root)
        )

        let packages = try service.list()
        let encoded = try JSONEncoder().encode(packages)
        let decoded = try JSONDecoder().decode([PresencePackage].self, from: encoded)

        #expect(decoded.count == 1)
        #expect(decoded[0].manifest.id == PresencePackageStore.builtInOrbID)
    }

    @Test
    func invalidDownloadSchemesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-command-tests-\(UUID().uuidString)")
        let service = PresenceCommandService(
            store: PresencePackageStore(rootURL: root)
        )

        #expect(throws: PresenceCommandError.secureDownloadRequired) {
            try service.validatedDownloadURL("file:///tmp/model.gmgnpet")
        }
    }
}
