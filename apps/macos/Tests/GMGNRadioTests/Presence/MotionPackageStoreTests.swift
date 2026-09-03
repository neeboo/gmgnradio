import CryptoKit
import Foundation
import Testing
@testable import GMGNRadio

@Suite
struct MotionPackageStoreTests {
    @Test
    func bundlesSlapBassAlongsideNaturalIdle() throws {
        let fixture = try MotionFixture()
        let slapBass = try fixture.makeVMDFile(name: "I Love Slap Bass")
        let store = MotionPackageStore(
            rootURL: fixture.rootURL,
            builtInMotions: [
                .init(
                    id: MotionPackageStore.iluvSlapBassID,
                    name: "I Love Slap Bass",
                    format: .vmd,
                    url: slapBass
                ),
            ]
        )

        let motions = try store.listMotions()

        #expect(motions.map(\.id) == [
            MotionPackageStore.naturalIdleID,
            MotionPackageStore.iluvSlapBassID,
        ])
        #expect(motions.dropFirst().allSatisfy { $0.format == .vmd })
    }

    @Test
    func startsWithNaturalIdleAndBundledStudioGroove() throws {
        let fixture = try MotionFixture()
        let studioURL = try fixture.makeVRMAFile(name: "StudioGroove")
        let store = MotionPackageStore(
            rootURL: fixture.rootURL,
            bundledStudioGrooveURL: studioURL
        )

        let motions = try store.listMotions()

        #expect(motions.map(\.id) == [
            MotionPackageStore.naturalIdleID,
            MotionPackageStore.studioGrooveID,
        ])
        #expect(motions.map(\.format) == [.procedural, .vrma])
        #expect(try store.activeMotion().id == MotionPackageStore.naturalIdleID)
    }

    @Test
    func retiredStudioSelectionMigratesToNaturalIdle() throws {
        let fixture = try MotionFixture()
        try Data(
            #"{"activeID":"builtin.motion.studio-groove"}"#.utf8
        ).write(to: fixture.rootURL.appending(path: ".selection.json"))

        #expect(
            try fixture.store.activeMotion().id
                == MotionPackageStore.naturalIdleID
        )
    }

    @Test
    func legacyAutomaticFullSelectionMigratesToNaturalIdle() throws {
        let fixture = try MotionFixture()
        try Data(
            #"{"activeID":"builtin.motion.2b-full"}"#.utf8
        ).write(to: fixture.rootURL.appending(path: ".selection.json"))

        #expect(
            try fixture.store.activeMotion().id
                == MotionPackageStore.naturalIdleID
        )
    }

    @Test
    func aVersionedRetiredFullSelectionAlsoMigratesToNaturalIdle() throws {
        let fixture = try MotionFixture()
        try Data(
            #"{"activeID":"builtin.motion.2b-full","version":2}"#.utf8
        ).write(to: fixture.rootURL.appending(path: ".selection.json"))

        #expect(
            try fixture.store.activeMotion().id
                == MotionPackageStore.naturalIdleID
        )
    }

    @Test
    func installsVRMAAndVMDWithValidatedHeaders() throws {
        let fixture = try MotionFixture()
        let vrmaURL = try fixture.makeVRMAFile(name: "Wave")
        let vmdURL = try fixture.makeVMDFile(name: "Dance")

        let vrma = try fixture.store.installMotion(from: vrmaURL)
        let vmd = try fixture.store.installMotion(from: vmdURL)

        #expect(vrma.format == .vrma)
        #expect(vmd.format == .vmd)
        #expect(vrma.url?.pathExtension.lowercased() == "vrma")
        #expect(vmd.url?.pathExtension.lowercased() == "vmd")
    }

    @Test
    func rejectsInvalidVRMAAndVMDHeaders() throws {
        let fixture = try MotionFixture()
        let vrmaURL = try fixture.makeVRMAFile(name: "BrokenVRMA", valid: false)
        let vmdURL = try fixture.makeVMDFile(name: "BrokenVMD", valid: false)

        #expect(throws: MotionPackageError.invalidVRMA) {
            try fixture.store.installMotion(from: vrmaURL)
        }
        #expect(throws: MotionPackageError.invalidVMD) {
            try fixture.store.installMotion(from: vmdURL)
        }
    }

    @Test
    func motionSelectionPersistsIndependentlyFromAvatarSelection() throws {
        let fixture = try MotionFixture()
        let vmdURL = try fixture.makeVMDFile(name: "Dance")
        let installed = try fixture.store.installMotion(from: vmdURL)

        try fixture.store.activate(id: installed.id)
        let reopened = MotionPackageStore(
            rootURL: fixture.rootURL,
            bundledStudioGrooveURL: nil
        )

        #expect(try reopened.activeMotion().id == installed.id)
    }

    @Test
    func removingTheActiveMotionFallsBackToNaturalIdle() throws {
        let fixture = try MotionFixture()
        let vmdURL = try fixture.makeVMDFile(name: "Dance")
        let installed = try fixture.store.installMotion(from: vmdURL)
        try fixture.store.activate(id: installed.id)

        try fixture.store.remove(id: installed.id)

        #expect(try fixture.store.activeMotion().id == MotionPackageStore.naturalIdleID)
    }

    @Test
    func aBrokenSelectedMotionReportsFailureInsteadOfReplacingTheSelection() throws {
        let fixture = try MotionFixture()
        let vmdURL = try fixture.makeVMDFile(name: "Dance")
        let installed = try fixture.store.installMotion(from: vmdURL)
        try fixture.store.activate(id: installed.id)
        let installedURL = try #require(installed.url)
        try FileManager.default.removeItem(at: installedURL)

        #expect(throws: MotionPackageError.motionNotFound) {
            try fixture.store.activeMotion()
        }
    }

    @Test
    func installsPublishedMotionUnderItsStableCatalogID() throws {
        let fixture = try MotionFixture()
        let source = try fixture.makeVRMAFile(name: "Kitchen Groove")
        let digest = SHA256.hash(data: try Data(contentsOf: source))
            .map { String(format: "%02x", $0) }
            .joined()

        let installed = try fixture.store.installPublishedMotion(
            id: "gmgn.motion.kitchen-groove",
            name: "Kitchen Groove",
            version: "1.0.0",
            format: .vrma,
            sourceURL: source,
            expectedSHA256: digest
        )
        let installedAgain = try fixture.store.installPublishedMotion(
            id: "gmgn.motion.kitchen-groove",
            name: "Kitchen Groove",
            version: "1.0.0",
            format: .vrma,
            sourceURL: source,
            expectedSHA256: digest
        )

        #expect(installed.id == "gmgn.motion.kitchen-groove")
        #expect(installedAgain.url == installed.url)
        #expect(try fixture.store.listMotions().contains { $0.id == installed.id })
    }

    @Test
    func preservesPublishedOneShotPlaybackMetadata() throws {
        let fixture = try MotionFixture()
        let source = try fixture.makeVRMAFile(name: "Backflip")
        let digest = SHA256.hash(data: try Data(contentsOf: source))
            .map { String(format: "%02x", $0) }
            .joined()

        let installed = try fixture.store.installPublishedMotion(
            id: "gmgn.motion.backflip",
            name: "Backflip",
            version: "1.0.0",
            format: .vrma,
            sourceURL: source,
            expectedSHA256: digest,
            loop: false
        )
        let restored = try #require(
            fixture.store.listMotions().first { $0.id == installed.id }
        )

        #expect(!installed.loop)
        #expect(!restored.loop)
    }

    @Test
    func preservesPublishedLocomotionMetadata() throws {
        let fixture = try MotionFixture()
        let source = try fixture.makeVRMAFile(name: "Walk")
        let digest = SHA256.hash(data: try Data(contentsOf: source))
            .map { String(format: "%02x", $0) }
            .joined()

        let installed = try fixture.store.installPublishedMotion(
            id: "gmgn.motion.walk",
            name: "Walk",
            version: "1.0.0",
            format: .vrma,
            sourceURL: source,
            expectedSHA256: digest,
            strideSpeed: 0.9,
            playbackRate: 1.25,
            inPlace: true
        )
        let restored = try #require(
            fixture.store.listMotions().first { $0.id == installed.id }
        )

        #expect(restored.strideSpeed == 0.9)
        #expect(restored.playbackRate == 1.25)
        #expect(restored.inPlace == true)
    }

    @Test
    func rejectsPublishedMotionWhenItsHashDoesNotMatch() throws {
        let fixture = try MotionFixture()
        let source = try fixture.makeVRMAFile(name: "Tampered")

        #expect(throws: MotionPackageError.hashMismatch) {
            try fixture.store.installPublishedMotion(
                id: "gmgn.motion.tampered",
                name: "Tampered",
                version: "1.0.0",
                format: .vrma,
                sourceURL: source,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        }
    }
}

private struct MotionFixture {
    let rootURL: URL
    let store: MotionPackageStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-motion-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        store = MotionPackageStore(rootURL: rootURL, bundledStudioGrooveURL: nil)
    }

    func makeVRMAFile(name: String, valid: Bool = true) throws -> URL {
        let fileURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: "\(name).vrma")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = ["asset": ["version": "2.0"]]
        if valid {
            json["extensionsUsed"] = ["VRMC_vrm_animation"]
            json["extensions"] = [
                "VRMC_vrm_animation": ["specVersion": "1.0"],
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

    func makeVMDFile(name: String, valid: Bool = true) throws -> URL {
        let fileURL = rootURL
            .appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: "\(name).vmd")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = Data(repeating: 0, count: 54)
        let signature = Data(
            (valid ? "Vocaloid Motion Data 0002" : "Not a VMD motion").utf8
        )
        data.replaceSubrange(0 ..< signature.count, with: signature)
        try data.write(to: fileURL)
        return fileURL
    }
}

private extension Data {
    mutating func appendUInt32LittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}
