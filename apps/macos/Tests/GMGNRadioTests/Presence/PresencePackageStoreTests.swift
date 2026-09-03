import Foundation
import Testing
@testable import GMGNRadio

@Suite
struct PresencePackageStoreTests {
    @Test
    func stageAssetContractsCoverVRMAndPMXWithIndependentMotion() {
        let modelURL = URL(filePath: "/tmp/miku/model.pmx")
        let resourceRootURL = modelURL.deletingLastPathComponent()
        let avatar = StageAvatarAsset(
            id: "pmx.miku",
            name: "Miku",
            format: .pmx,
            modelURL: modelURL,
            resourceRootURL: resourceRootURL
        )
        let motion = StageMotionAsset(
            id: "motion.dance",
            name: "Dance",
            format: .vmd,
            url: URL(filePath: "/tmp/dance.vmd")
        )

        let snapshot = StageAvatarRuntimeSnapshot(
            avatar: avatar,
            motion: motion,
            revision: 7
        )

        #expect(StageAvatarFormat.allCases == [.vrm, .pmx])
        #expect(StageMotionFormat.allCases == [.procedural, .vrma, .vmd])
        #expect(snapshot.avatar == avatar)
        #expect(snapshot.motion == motion)
        #expect(snapshot.modelURL == modelURL)
        #expect(snapshot.name == "Miku")
    }

    @Test
    func firstInstallSelectsTheFirstBundledVRM() throws {
        let fixture = try Fixture()
        let arisuURL = try fixture.makeVRMFile(name: "ArisuMaid")
        let fireflyURL = try fixture.makeVRMFile(name: "fireflyMaid")
        let store = PresencePackageStore(
            rootURL: fixture.rootURL,
            builtInVRMs: [
                .init(id: "builtin.vrm.arisu", name: "Arisu Maid", url: arisuURL),
                .init(id: "builtin.vrm.firefly", name: "Firefly Maid", url: fireflyURL),
            ]
        )

        let packages = try store.listPackages()

        #expect(packages.map(\.manifest.id) == [
            PresencePackageStore.builtInOrbID,
            "builtin.vrm.arisu",
            "builtin.vrm.firefly",
        ])
        #expect(packages.first(where: { $0.manifest.id == "builtin.vrm.arisu" })?.isActive == true)
        #expect(packages.first(where: { $0.manifest.id == PresencePackageStore.builtInOrbID })?.isActive == false)
        #expect(packages.first(where: { $0.manifest.id == "builtin.vrm.arisu" })?.rendererAvailable == true)
        #expect(packages.first(where: { $0.manifest.id == "builtin.vrm.arisu" })?.installPath == arisuURL.deletingLastPathComponent().path)
    }

    @Test
    func bundledPMXAvatarUsesItsOwnEngineAndReplacesTheRetiredCatgirlSelection() throws {
        let fixture = try Fixture()
        let modelRoot = try fixture.makePMXDirectory(
            name: "23",
            texturePaths: ["textures/body.png"]
        )
        let modelURL = modelRoot.appending(path: "23.pmx")
        let selection = Data(
            #"{"activeID":"builtin.vrm.arisu-maid"}"#.utf8
        )
        try selection.write(to: fixture.rootURL.appending(path: ".selection.json"))
        let store = PresencePackageStore(
            rootURL: fixture.rootURL,
            builtInVRMs: [
                .init(
                    id: "builtin.pmx.2b",
                    name: "2B",
                    url: modelURL,
                    engine: .pmx
                ),
            ]
        )

        let packages = try store.listPackages()
        let activeAvatar = try store.activeAvatar()
        let avatar = try #require(activeAvatar)

        #expect(packages.map(\.manifest.id) == [
            PresencePackageStore.builtInOrbID,
            "builtin.pmx.2b",
        ])
        #expect(avatar.id == "builtin.pmx.2b")
        #expect(avatar.format == .pmx)
        #expect(avatar.modelURL == modelURL.standardizedFileURL)
    }

    @Test
    func addingBundledVRMsPreservesAnExistingSelection() throws {
        let fixture = try Fixture()
        try fixture.store.activate(id: PresencePackageStore.builtInOrbID)
        let arisuURL = try fixture.makeVRMFile(name: "ArisuMaid")
        let store = PresencePackageStore(
            rootURL: fixture.rootURL,
            builtInVRMs: [
                .init(id: "builtin.vrm.arisu", name: "Arisu Maid", url: arisuURL),
            ]
        )

        let packages = try store.listPackages()

        #expect(packages.first(where: { $0.manifest.id == PresencePackageStore.builtInOrbID })?.isActive == true)
        #expect(packages.first(where: { $0.manifest.id == "builtin.vrm.arisu" })?.isActive == false)
    }

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
    func installsARawVRMFile() throws {
        let fixture = try Fixture()
        let source = try fixture.makeVRMFile(name: "Aoi")

        let installed = try fixture.store.installPackage(from: source)

        #expect(installed.manifest.engine == .vrm)
        #expect(installed.manifest.name == "Aoi")
        #expect(installed.manifest.entry == "Aoi.vrm")
        #expect(installed.manifest.id.hasPrefix("vrm."))
        #expect(installed.rendererAvailable)
        #expect(FileManager.default.fileExists(
            atPath: URL(filePath: installed.installPath!)
                .appending(path: "Aoi.vrm")
                .path
        ))
    }

    @Test
    func installsARawPMXDirectoryAndPreservesItsResourceRoot() throws {
        let fixture = try Fixture()
        let source = try fixture.makePMXDirectory(
            name: "Miku",
            texturePaths: ["textures/body.png"]
        )

        let installed = try fixture.store.installPackage(from: source)
        let avatar = try #require(
            fixture.store.listAvatarAssets().first(where: { $0.id == installed.manifest.id })
        )

        #expect(installed.manifest.engine == .pmx)
        #expect(installed.manifest.entry == "Miku.pmx")
        #expect(avatar.format == .pmx)
        #expect(avatar.resourceRootURL.path == installed.installPath)
        #expect(FileManager.default.fileExists(
            atPath: avatar.resourceRootURL.appending(path: "textures/body.png").path
        ))
    }

    @Test
    func installsARawPMXZipAndPreservesItsResourceRoot() throws {
        let fixture = try Fixture()
        let source = try fixture.makePMXDirectory(
            name: "MikuZip",
            texturePaths: ["textures/body.png"]
        )
        let archive = try fixture.makeZipArchive(containing: source, name: "MikuZip")

        let installed = try fixture.store.installPackage(from: archive)
        let avatar = try #require(
            fixture.store.listAvatarAssets().first(where: { $0.id == installed.manifest.id })
        )
        let installedRoot = URL(
            filePath: try #require(installed.installPath),
            directoryHint: .isDirectory
        )

        #expect(installed.manifest.engine == .pmx)
        #expect(installed.manifest.entry == "MikuZip.pmx")
        #expect(avatar.resourceRootURL.standardizedFileURL == installedRoot.standardizedFileURL)
        #expect(avatar.modelURL.standardizedFileURL == installedRoot.appending(path: "MikuZip.pmx").standardizedFileURL)
        #expect(FileManager.default.fileExists(
            atPath: avatar.resourceRootURL.appending(path: "textures/body.png").path
        ))
    }

    @Test
    func rejectsPMXZipEntriesThatEscapeTheExtractionRoot() throws {
        let fixture = try Fixture()
        let archive = try fixture.makeZipArchive(entryName: "../escape.txt")

        #expect(throws: PresencePackageError.unsafeArchiveEntry("../escape.txt")) {
            try fixture.store.installPackage(from: archive)
        }
    }

    @Test
    func rejectsPMXTexturePathsThatEscapeTheResourceRoot() throws {
        let fixture = try Fixture()
        let source = try fixture.makePMXDirectory(
            name: "Unsafe",
            texturePaths: ["../outside.png"]
        )

        #expect(throws: PresencePackageError.invalidEntryPath) {
            try fixture.store.installPackage(from: source)
        }
    }

    @Test
    func rejectsPMXResourcesThatEscapeThroughASymbolicLink() throws {
        let fixture = try Fixture()
        let source = try fixture.makePMXDirectory(
            name: "UnsafeLink",
            texturePaths: ["textures/body.png"]
        )
        let linkURL = source.appending(path: "textures/body.png")
        try FileManager.default.removeItem(at: linkURL)
        let outsideURL = fixture.rootURL.appending(path: "outside.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outsideURL
        )

        #expect(throws: PresencePackageError.unsafeArchiveEntry("body.png")) {
            try fixture.store.installPackage(from: source)
        }
    }

    @Test
    func rejectsFilesWithAnInvalidPMXHeader() throws {
        let fixture = try Fixture()
        let source = try fixture.makePMXDirectory(name: "Broken", validHeader: false)

        #expect(throws: PresencePackageError.invalidPMX) {
            try fixture.store.installPackage(from: source)
        }
    }

    @Test
    func aBrokenSelectedAvatarReportsFailureInsteadOfClearingTheSelection() throws {
        let fixture = try Fixture()
        let source = try fixture.makePMXDirectory(name: "Miku")
        let installed = try fixture.store.installPackage(from: source)
        try fixture.store.activate(id: installed.manifest.id)
        let installedRoot = URL(filePath: try #require(installed.installPath))
        try FileManager.default.removeItem(
            at: installedRoot.appending(path: installed.manifest.entry)
        )

        #expect(throws: PresencePackageError.packageNotFound) {
            try fixture.store.activeAvatar()
        }
    }

    @Test
    func rejectsGLBFilesWithoutAVRMExtension() throws {
        let fixture = try Fixture()
        let source = try fixture.makeVRMFile(name: "ordinary-model", vrmExtension: nil)

        #expect(throws: PresencePackageError.invalidVRM) {
            try fixture.store.installPackage(from: source)
        }
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
        store = PresencePackageStore(rootURL: rootURL, builtInVRMs: [])
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

    func makeVRMFile(
        name: String,
        vrmExtension: String? = "VRMC_vrm"
    ) throws -> URL {
        let fileURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: "\(name).vrm")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = [
            "asset": ["version": "2.0"],
        ]
        if let vrmExtension {
            json["extensionsUsed"] = [vrmExtension]
            json["extensions"] = [
                vrmExtension: vrmExtension == "VRMC_vrm"
                    ? ["specVersion": "1.0"]
                    : [:],
            ]
        }
        var jsonData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys]
        )
        while !jsonData.count.isMultiple(of: 4) {
            jsonData.append(0x20)
        }

        var data = Data("glTF".utf8)
        data.appendUInt32LittleEndian(2)
        data.appendUInt32LittleEndian(UInt32(20 + jsonData.count))
        data.appendUInt32LittleEndian(UInt32(jsonData.count))
        data.appendUInt32LittleEndian(0x4E4F534A)
        data.append(jsonData)
        try data.write(to: fileURL)
        return fileURL
    }

    func makePMXDirectory(
        name: String,
        texturePaths: [String] = [],
        validHeader: Bool = true
    ) throws -> URL {
        let directoryURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: "pmx-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        var data = Data(validHeader ? "PMX ".utf8 : "NOPE".utf8)
        data.appendFloat32LittleEndian(2.0)
        data.append(8)
        data.append(contentsOf: [
            1, // UTF-8 text
            0, // additional UV count
            4, // vertex index size
            4, // texture index size
            4, // material index size
            4, // bone index size
            4, // morph index size
            4, // rigid-body index size
        ])
        for _ in 0 ..< 4 {
            data.appendPMXText("")
        }
        data.appendInt32LittleEndian(0) // vertices
        data.appendInt32LittleEndian(0) // surface indices
        data.appendInt32LittleEndian(Int32(texturePaths.count))
        for texturePath in texturePaths {
            data.appendPMXText(texturePath)
            guard !texturePath.contains("..") else { continue }
            let textureURL = directoryURL.appending(path: texturePath)
            try FileManager.default.createDirectory(
                at: textureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: textureURL)
        }
        try data.write(to: directoryURL.appending(path: "\(name).pmx"))
        return directoryURL
    }

    func makeZipArchive(containing sourceURL: URL, name: String) throws -> URL {
        let archiveURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: "\(name).zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", sourceURL.path, archiveURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return archiveURL
    }

    func makeZipArchive(entryName: String) throws -> URL {
        let archiveURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: "unsafe-\(UUID().uuidString).zip")
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let nameData = Data(entryName.utf8)
        var data = Data()
        data.appendUInt32LittleEndian(0x0403_4B50)
        data.appendUInt16LittleEndian(20)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt16LittleEndian(UInt16(nameData.count))
        data.appendUInt16LittleEndian(0)
        data.append(nameData)

        let centralDirectoryOffset = data.count
        data.appendUInt32LittleEndian(0x0201_4B50)
        data.appendUInt16LittleEndian(20)
        data.appendUInt16LittleEndian(20)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt16LittleEndian(UInt16(nameData.count))
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.appendUInt32LittleEndian(0)
        data.append(nameData)

        let centralDirectorySize = data.count - centralDirectoryOffset
        data.appendUInt32LittleEndian(0x0605_4B50)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(0)
        data.appendUInt16LittleEndian(1)
        data.appendUInt16LittleEndian(1)
        data.appendUInt32LittleEndian(UInt32(centralDirectorySize))
        data.appendUInt32LittleEndian(UInt32(centralDirectoryOffset))
        data.appendUInt16LittleEndian(0)
        try data.write(to: archiveURL)
        return archiveURL
    }
}

private extension Data {
    mutating func appendUInt16LittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendUInt32LittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendInt32LittleEndian(_ value: Int32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendFloat32LittleEndian(_ value: Float) {
        appendUInt32LittleEndian(value.bitPattern)
    }

    mutating func appendPMXText(_ value: String) {
        let bytes = Data(value.utf8)
        appendInt32LittleEndian(Int32(bytes.count))
        append(bytes)
    }
}
