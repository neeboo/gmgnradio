import Foundation
import Testing
@testable import GMGNRadio

@Suite
struct PresencePackageStoreTests {
    @Test
    func startsWithTheBuiltInOrbSelected() throws {
        let fixture = try Fixture()

        let packages = try fixture.store.listPackages()

        #expect(packages.count == 1)
        #expect(packages[0].manifest.id == PresencePackageStore.builtInOrbID)
        #expect(packages[0].isActive)
        #expect(packages[0].rendererAvailable)
    }

    @Test
    func installsAValidLive2DDirectory() throws {
        let fixture = try Fixture()
        let source = try fixture.makeLive2DPackage(id: "mori.blue")

        let installed = try fixture.store.installPackage(from: source)
        let packages = try fixture.store.listPackages()

        #expect(installed.manifest.id == "mori.blue")
        #expect(installed.manifest.engine == .live2D)
        #expect(!installed.rendererAvailable)
        #expect(packages.map(\.manifest.id) == [
            PresencePackageStore.builtInOrbID,
            "mori.blue",
        ])
    }

    @Test
    func rejectsEntriesThatEscapeThePackage() throws {
        let fixture = try Fixture()
        let source = try fixture.makeLive2DPackage(
            id: "unsafe.model",
            entry: "../outside.model3.json"
        )

        #expect(throws: PresencePackageError.invalidEntryPath) {
            try fixture.store.installPackage(from: source)
        }
    }

    @Test
    func remembersTheSelectedPresence() throws {
        let fixture = try Fixture()
        let source = try fixture.makeLive2DPackage(id: "mori.blue")
        _ = try fixture.store.installPackage(from: source)

        try fixture.store.activate(id: "mori.blue")

        let packages = try fixture.store.listPackages()
        #expect(packages.first(where: { $0.manifest.id == "mori.blue" })?.isActive == true)
        #expect(packages.first(where: {
            $0.manifest.id == PresencePackageStore.builtInOrbID
        })?.isActive == false)
    }

    @Test
    func removingTheSelectedPresenceFallsBackToTheOrb() throws {
        let fixture = try Fixture()
        let source = try fixture.makeLive2DPackage(id: "mori.blue")
        _ = try fixture.store.installPackage(from: source)
        try fixture.store.activate(id: "mori.blue")

        try fixture.store.remove(id: "mori.blue")

        let packages = try fixture.store.listPackages()
        #expect(packages.count == 1)
        #expect(packages[0].manifest.id == PresencePackageStore.builtInOrbID)
        #expect(packages[0].isActive)
    }
}

private struct Fixture {
    let rootURL: URL
    let store: PresencePackageStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-presence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        store = PresencePackageStore(rootURL: rootURL)
    }

    func makeLive2DPackage(
        id: String,
        entry: String = "avatar.model3.json"
    ) throws -> URL {
        let packageURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )

        let manifest: [String: Any] = [
            "id": id,
            "name": "Mori",
            "version": "1.0.0",
            "engine": "live2d",
            "entry": entry,
            "author": "gmgn labs",
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: packageURL.appending(path: "manifest.json"))

        if entry == "avatar.model3.json" {
            let model: [String: Any] = [
                "Version": 3,
                "FileReferences": ["Moc": "avatar.moc3"],
            ]
            let modelData = try JSONSerialization.data(
                withJSONObject: model,
                options: [.prettyPrinted, .sortedKeys]
            )
            try modelData.write(to: packageURL.appending(path: entry))
            try Data([0x4d, 0x4f, 0x43, 0x33])
                .write(to: packageURL.appending(path: "avatar.moc3"))
        }

        return packageURL
    }
}
