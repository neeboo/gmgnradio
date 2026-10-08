import CryptoKit
import Foundation
import MotionDistribution
import Testing
@testable import GMGNRadio

private func settingsVRM() throws -> Data {
    var json = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0"],
        "extensionsUsed": ["VRMC_vrm"], "extensions": ["VRMC_vrm": ["specVersion": "1.0"]]])
    while !json.count.isMultiple(of: 4) { json.append(0x20) }
    var data = Data("glTF".utf8)
    for word in [UInt32(2), UInt32(20 + json.count), UInt32(json.count), UInt32(0x4e4f534a)] {
        var little = word.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    data.append(json)
    return data
}

@MainActor
@Suite
struct PresenceSettingsModelTests {
    @Test
    func rendererSpecificCompatibilityDropsOldVMDWhenSwitchingToUnityVRM() async throws {
        let authority = try await PrivatePresenceAuthorityFixture.start()
        let root = authority.root
        let motions = authority.motionStore
        var bytes = Data("Vocaloid Motion Data 0002".utf8)
        bytes.append(Data(repeating: 0, count: 54 - bytes.count))
        let source = root.appending(path: "old.vmd")
        try bytes.write(to: source)
        let old = try motions.installMotion(from: source)
        let pmxStore = try authority.pmxStore()
        let vrm = root.appendingPathComponent("settings.vrm")
        try settingsVRM().write(to: vrm)
        let store = PresencePackageStore(rootURL: authority.packageRoot,
            builtInVRMs: pmxStore.builtInVRMs + [.init(id: "settings.vrm", name: "Settings VRM", url: vrm)],
            selectionAuthority: authority.client)
        try await authority.bind(store: store, motions: motions)
        try await store.activateAsync(id: "private.pmx")
        try await authority.acknowledge()
        try await motions.activateAsync(id: old.id)
        try await authority.acknowledge()
        let observed = try store.listPackages().map { package in
            PresencePackage(manifest: package.manifest, installPath: package.installPath,
                thumbnailPath: package.thumbnailPath, isActive: package.isActive,
                isBuiltIn: package.isBuiltIn, rendererAvailable: true)
        }
        _ = try await authority.client.bind(packages: observed, motions: motions.listMotions(),
            packageRoot: store.rootURL, motionRoot: motions.rootURL, policy: "unity",
            supportedEngines: ["orb", "pmx", "vrm"], builtInMotionIDs: [MotionPackageStore.naturalIdleID])
        try await store.activateAsync(id: "settings.vrm")
        try await authority.acknowledge()
        let runtime = StageAvatarRuntimeStore(packageStore: store, motionPackageStore: motions)
        let model = PresenceSettingsModel(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            avatarRuntime: runtime, presenceStore: store,
            motionStore: motions, productSettings: RustProductSettingsClient(root: root.appendingPathComponent("TaskService")), renderPolicy: "unity", playbackCompatibility: { engine, format in
                if engine == .vrm && format == .vmd { return .incompatible("VRMA required") }
                return PresenceSettingsModel.motionCompatibility(avatarEngine: engine, motionFormat: format)
            })
        model.packages = [package(engine: .vrm)]
        try model.refreshEffectiveMotionForActiveAvatar()
        #expect(try motions.activeMotion().id == MotionPackageStore.naturalIdleID)
        do { try await model.activateMotionConfirmed(old); Issue.record("Unity VRM accepted an incompatible VMD") } catch {}
        #expect(try motions.activeMotion().id == MotionPackageStore.naturalIdleID)
        #expect(model.motionCompatibility(old) == .incompatible("VRMA required"))
        // Original SceneKit compatibility is deliberately unchanged.
        #expect(PresenceSettingsModel.motionCompatibility(avatarEngine: .vrm, motionFormat: .vmd) == .compatible)
    }

    @Test
    func exposesTheRequestedAvatarMotionCompatibilityMatrix() {
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .vrm,
                motionFormat: .procedural
            ) == .compatible
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .vrm,
                motionFormat: .vrma
            ) == .compatible
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .vrm,
                motionFormat: .vmd
            ) == .compatible
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .pmx,
                motionFormat: .procedural
            ) == .compatible
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .pmx,
                motionFormat: .vmd
            ) == .compatible
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .pmx,
                motionFormat: .vrma
            ) == .incompatible("VRMA 只能用于 VRM 角色。")
        )
    }

    @Test
    func keepsIncompatibleMotionsVisibleWithAnActionableReason() {
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .orb,
                motionFormat: .vmd
            ) == .incompatible("请先选择 VRM 或 PMX 角色。")
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: .live2D,
                motionFormat: .vrma
            ) == .incompatible("Live2D 角色暂不支持骨骼动作。")
        )
        #expect(
            PresenceSettingsModel.motionCompatibility(
                avatarEngine: nil,
                motionFormat: .procedural
            ) == .incompatible("请先选择 VRM 或 PMX 角色。")
        )
    }

    @Test
    func selectingACompatibleMotionPersistsItAndRefreshesTheRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-settings-motion-\(UUID().uuidString)")
        let presenceStore = PresencePackageStore(
            rootURL: root.appending(path: "presence"),
            builtInVRMs: []
        )
        let motionStore = MotionPackageStore(
            rootURL: root.appending(path: "motions"),
            bundledStudioGrooveURL: nil
        )
        let fixture = root.appending(path: "wave.vmd")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var vmd = Data("Vocaloid Motion Data 0002".utf8)
        vmd.append(Data(repeating: 0, count: 30 - vmd.count))
        vmd.append(Data(repeating: 0, count: 20))
        vmd.append(Data(repeating: 0, count: 4))
        try vmd.write(to: fixture)
        let installed = try motionStore.installMotion(from: fixture)
        let runtime = StageAvatarRuntimeStore(
            packageStore: nil,
            motionPackageStore: motionStore
        )
        var manualSelectionRequests: [String] = []
        let model = PresenceSettingsModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            avatarRuntime: runtime,
            presenceStore: presenceStore,
            motionStore: motionStore,
            onWillActivateMotion: { manualSelectionRequests.append($0) }
        )
        model.packages = [
            PresencePackage(
                manifest: PresenceManifest(
                    id: "test.vrm",
                    name: "Test VRM",
                    version: "1.0.0",
                    engine: .vrm,
                    entry: "test.vrm"
                ),
                installPath: root.path,
                thumbnailPath: nil,
                isActive: true,
                isBuiltIn: false,
                rendererAvailable: true
            ),
        ]

        model.activateMotion(installed)

        #expect(try motionStore.activeMotion().id == installed.id)
        #expect(model.activeMotionID == installed.id)
        #expect(runtime.snapshot.motion?.id == installed.id)
        #expect(manualSelectionRequests == [installed.id])
    }

    @Test
    func incompatibleAvatarSwitchUsesIdleWithoutForgettingTheExplicitChoice() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-settings-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let motionStore = MotionPackageStore(
            rootURL: root.appending(path: "motions"),
            bundledStudioGrooveURL: nil
        )
        let vrmaURL = root.appending(path: "favorite.vrma")
        try makeVRMA().write(to: vrmaURL)
        let favorite = try motionStore.installMotion(from: vrmaURL)
        let presenceStore = PresencePackageStore(
            rootURL: root.appending(path: "presence"),
            builtInVRMs: []
        )
        let runtime = StageAvatarRuntimeStore(
            packageStore: nil,
            motionPackageStore: motionStore
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = PresenceSettingsModel(
            defaults: defaults,
            avatarRuntime: runtime,
            presenceStore: presenceStore,
            motionStore: motionStore
        )

        model.packages = [package(engine: .vrm)]
        model.activateMotion(favorite)
        #expect(try motionStore.activeMotion().id == favorite.id)

        model.packages = [package(engine: .pmx)]
        try model.refreshEffectiveMotionForActiveAvatar()
        #expect(try motionStore.activeMotion().id == MotionPackageStore.naturalIdleID)
        #expect(runtime.snapshot.motion?.id == MotionPackageStore.naturalIdleID)

        model.packages = [package(engine: .vrm)]
        try model.refreshEffectiveMotionForActiveAvatar()
        #expect(try motionStore.activeMotion().id == favorite.id)
        #expect(runtime.snapshot.motion?.id == favorite.id)
    }

    @Test
    func refreshesAndInstallsPublishedMotionsIntoTheVisibleMotionList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-settings-remote-motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = URL(string: "http://127.0.0.1:9876/catalog.json")!
        let artifactURL = URL(
            string: "http://127.0.0.1:9876/motions/gmgn.motion.wave/1.0.0/gmgn.motion.wave.vrma"
        )!
        let vrma = try makeVRMA()
        let digest = SHA256.hash(data: vrma).map { String(format: "%02x", $0) }.joined()
        let catalog = Data(
            """
            {"schemaVersion":1,"motions":[{
              "id":"gmgn.motion.wave","name":"Wave","version":"1.0.0","format":"vrma",
              "path":"motions/gmgn.motion.wave/1.0.0/gmgn.motion.wave.vrma",
              "sha256":"\(digest)","bytes":\(vrma.count),"duration":2.0,"loop":true,
              "avatarFormats":["vrm"],"activityIDs":["greeting.wave"],
              "source":{"prompt":"wave","seed":1,"generator":{"engine":"ardy","model":"core","revision":"test"}}
            }]}
            """.utf8
        )
        let transport = PresenceRemoteMotionTransport([
            catalogURL: .init(statusCode: 200, finalURL: catalogURL, data: catalog),
            artifactURL: .init(statusCode: 200, finalURL: artifactURL, data: vrma),
        ])
        let motionStore = MotionPackageStore(
            rootURL: root.appending(path: "motions"),
            bundledStudioGrooveURL: nil
        )
        let library = RemoteMotionLibrary(
            catalogURL: catalogURL,
            motionStore: motionStore,
            cacheRootURL: root.appending(path: "cache"),
            transport: transport
        )
        let model = PresenceSettingsModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            avatarRuntime: StageAvatarRuntimeStore(
                packageStore: nil,
                motionPackageStore: motionStore
            ),
            presenceStore: PresencePackageStore(
                rootURL: root.appending(path: "presence"),
                builtInVRMs: []
            ),
            motionStore: motionStore,
            remoteMotionLibrary: library
        )

        await model.refreshPublishedMotions()
        let published = try #require(model.publishedMotions.first)
        await model.installPublishedMotion(published)

        #expect(model.publishedMotions.map(\.id) == ["gmgn.motion.wave"])
        #expect(model.motions.contains { $0.id == "gmgn.motion.wave" })
    }

    @Test
    func distinguishesAnInstalledPublishedMotionFromANewerUpdate() async throws {
        let authority = try await PrivatePresenceAuthorityFixture.start()
        let root = authority.root
        let vmdURL = root.appending(path: "backflip.vmd")
        var vmd = Data("Vocaloid Motion Data 0002".utf8)
        vmd.append(Data(repeating: 0, count: 30 - vmd.count))
        vmd.append(Data(repeating: 0, count: 20))
        vmd.append(Data(repeating: 0, count: 4))
        try vmd.write(to: vmdURL)
        let digest = SHA256.hash(data: vmd)
            .map { String(format: "%02x", $0) }
            .joined()
        let motionStore = authority.motionStore
        _ = try motionStore.installPublishedMotion(
            id: "gmgn.motion.ardy-backflip",
            name: "后空翻",
            version: "1.2.0",
            format: .vmd,
            sourceURL: vmdURL,
            expectedSHA256: digest
        )
        let store = try authority.pmxStore()
        try await authority.bind(store: store, motions: motionStore)
        try await store.activateAsync(id: "private.pmx")
        try await authority.acknowledge()
        try await motionStore.activateAsync(id: "gmgn.motion.ardy-backflip")
        try await authority.acknowledge()
        let runtime = StageAvatarRuntimeStore(
            packageStore: store,
            motionPackageStore: motionStore
        )
        let model = PresenceSettingsModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            avatarRuntime: runtime,
            presenceStore: store,
            motionStore: motionStore,
            productSettings: RustProductSettingsClient(root: root.appendingPathComponent("TaskService"))
        )
        try model.refreshEffectiveMotionForActiveAvatar()
        let installed = try publishedMotion(
            id: "gmgn.motion.ardy-backflip",
            version: "1.2.0",
            sha256: digest
        )
        let update = try publishedMotion(
            id: "gmgn.motion.ardy-backflip",
            version: "1.3.0",
            sha256: String(repeating: "a", count: 64)
        )

        #expect(model.publishedMotionInstallState(installed) == .installed)
        #expect(model.publishedMotionInstallState(update) == .updateAvailable)

        let previousRevision = runtime.snapshot.revision
        _ = try motionStore.installPublishedMotion(
            id: "gmgn.motion.ardy-backflip",
            name: "后空翻",
            version: "1.3.0",
            format: .vmd,
            sourceURL: vmdURL,
            expectedSHA256: digest
        )
        runtime.refresh()

        #expect(runtime.snapshot.motion?.version == "1.3.0")
        #expect(runtime.snapshot.revision > previousRevision)
    }

    private func package(engine: PresenceEngine) -> PresencePackage {
        PresencePackage(
            manifest: PresenceManifest(
                id: "test.\(engine.rawValue)",
                name: "Test \(engine.rawValue)",
                version: "1.0.0",
                engine: engine,
                entry: engine == .pmx ? "test.pmx" : "test.vrm"
            ),
            installPath: "/tmp",
            thumbnailPath: nil,
            isActive: true,
            isBuiltIn: false,
            rendererAvailable: true
        )
    }

    private func makeVRMA() throws -> Data {
        var json = try JSONSerialization.data(
            withJSONObject: [
                "asset": ["version": "2.0"],
                "extensions": [
                    "VRMC_vrm_animation": ["specVersion": "1.0"],
                ],
            ],
            options: [.sortedKeys]
        )
        while !json.count.isMultiple(of: 4) {
            json.append(0x20)
        }
        var data = Data("glTF".utf8)
        data.append(contentsOf: [2, 0, 0, 0])
        let totalLength = UInt32(20 + json.count).littleEndian
        withUnsafeBytes(of: totalLength) { data.append(contentsOf: $0) }
        let jsonLength = UInt32(json.count).littleEndian
        withUnsafeBytes(of: jsonLength) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        data.append(json)
        return data
    }

    private func publishedMotion(
        id: String,
        version: String,
        sha256: String
    ) throws -> PublishedMotion {
        try JSONDecoder().decode(
            PublishedMotion.self,
            from: Data(
                """
                {"id":"\(id)","name":"后空翻","version":"\(version)","format":"vmd",
                "path":"motions/\(id)/\(version)/motion.vmd","sha256":"\(sha256)",
                "bytes":54,"duration":4.0,"loop":false,"avatarFormats":["pmx"],
                "activityIDs":["dance.backflip"],"source":{"prompt":"backflip","seed":1,
                "generator":{"engine":"ardy","model":"core","revision":"test"}}}
                """.utf8
            )
        )
    }
}

private actor PresenceRemoteMotionTransport: MotionHTTPTransport {
    let responses: [URL: MotionHTTPResponse]

    init(_ responses: [URL: MotionHTTPResponse]) {
        self.responses = responses
    }

    func get(_ url: URL) async throws -> MotionHTTPResponse {
        guard let response = responses[url] else {
            throw URLError(.resourceUnavailable)
        }
        return response
    }
}
