import Foundation
import Observation
import os

@MainActor
@Observable
final class MarbleWorldLibrary {
    static let preferredInitialWorldID =
        "56934fab-6a88-4136-bdf8-a46fef39b2f0"

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "MarbleWorldLibrary"
    )

    private(set) var worlds: [MarbleWorld] = []
    private(set) var selectedWorld: MarbleWorld?
    private(set) var localSplatURL: URL?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?
    private(set) var generatingPreset: SpatialScenePreset?
    private(set) var generationProgress: Int?
    private(set) var generationMessage: String?

    var onLocalSplatChange: ((URL) -> Void)?

    var publicExampleWorlds: [MarbleWorld] {
        worlds.filter(\.isPublicExample)
    }

    private let authority: RustMarbleControlClient
    private let preparePackage: @MainActor @Sendable (MarbleWorld) async throws -> String
    private var controlBusy = false
    private var importedLegacySelection = false
    private var presetWorldIDs: [String: String] = [:]
    private let client: MarbleWorldClient
    private let cache: MarbleWorldCache
    private let spatialStage: SpatialStageStore
    private var prepareTask: Task<URL?, Never>?
    private var selectionRevision: UInt64 = 0
    private var selectedLocalWorldID: String?
    private var bundledColliders: [String: URL] = [:]

    init(
        client: MarbleWorldClient = MarbleWorldClient(),
        cache: MarbleWorldCache = MarbleWorldCache(),
        spatialStage: SpatialStageStore,
        authority: RustMarbleControlClient,
        preparePackage: @escaping @MainActor @Sendable (MarbleWorld) async throws -> String
    ) {
        self.authority = authority
        self.preparePackage = preparePackage
        self.client = client
        self.cache = cache
        self.spatialStage = spatialStage
    }

    func prepare() async -> URL? {
        guard selectedLocalWorldID == nil else {
            return localSplatURL
        }
        if let localSplatURL {
            return localSplatURL
        }
        if let prepareTask {
            return await prepareTask.value
        }

        let expectedSelectionRevision = selectionRevision
        let task: Task<URL?, Never> = Task { [weak self] in
            guard let self else {
                return nil
            }
            return await self.performPreparation(
                expectedSelectionRevision: expectedSelectionRevision
            )
        }
        prepareTask = task
        let result = await task.value
        prepareTask = nil
        return result
    }

    func select(worldID: String) async -> URL? {
        guard !controlBusy else { return nil }
        controlBusy = true
        defer { controlBusy = false }
        do {
            let current = try await authority.read()
            try await consume(try await authority.command("select", expectedRevision: current.revision, worldID: worldID))
            return await cacheSelectedWorld()
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func selectLocalWorld(id: String, scene: SpatialScenePreset) {
        selectionRevision &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        selectedLocalWorldID = id
        selectedWorld = nil
        localSplatURL = nil
        errorMessage = nil
        spatialStage.selectScene(scene)
        spatialStage.selectWorld(id: id)
    }

    /// Select an adopted generated world without catalog fetches or auto-selection.
    func adoptCachedWorld(
        _ world: MarbleWorld, splatURL: URL, colliderURL: URL
    ) {
        selectionRevision &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        selectedLocalWorldID = world.id
        selectedWorld = world
        worlds.removeAll { $0.id == world.id }
        worlds.insert(world, at: 0)
        bundledColliders[world.id] = colliderURL
        localSplatURL = splatURL
        errorMessage = nil
        isPreparing = false
        spatialStage.selectScene(.inferred(worldID: world.id, name: world.name))
        spatialStage.selectWorld(id: world.id)
        onLocalSplatChange?(splatURL)
    }

    func reportLivingCabinFailure(_ error: Error) {
        selectionRevision &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        selectedLocalWorldID = LivingWorldBootstrap.marbleCabinDirectoryName
        selectedWorld = nil
        localSplatURL = nil
        isPreparing = false
        errorMessage = error.localizedDescription
    }

    func localCollider(
        for worldID: String
    ) async throws -> (URL, MarbleColliderSourceCoordinates)? {
        if let url = bundledColliders[worldID],
           let world = worlds.first(where: { $0.id == worldID }) {
            return (url, world.colliderSourceCoordinates)
        }
        guard let world = worlds.first(where: { $0.id == worldID }),
              let url = try await cache.localCollider(for: world)
        else {
            return nil
        }
        return (url, world.colliderSourceCoordinates)
    }

    func hasWorld(for preset: SpatialScenePreset) -> Bool {
        presetWorldIDs[preset.rawValue] != nil
    }

    func activate(preset: SpatialScenePreset) async {
        guard !controlBusy else { return }
        controlBusy = true
        generatingPreset = preset
        defer { controlBusy = false; generatingPreset = nil }
        do {
            let current = try await authority.read()
            try await consume(authority.command("activate_preset", expectedRevision: current.revision, presetID: preset.rawValue))
            _ = await cacheSelectedWorld()
        } catch { errorMessage = error.localizedDescription }
    }

    private func performPreparation(expectedSelectionRevision: UInt64) async -> URL? {
        guard !controlBusy else { return localSplatURL }
        controlBusy = true
        isPreparing = true
        defer { controlBusy = false; isPreparing = false }
        do {
            let current = try await authority.read()
            let saved = importedLegacySelection ? nil : UserDefaults.standard.string(forKey: "marble.selected-world-id")
            let confirmed = try await authority.command("refresh", expectedRevision: current.revision,
                pageSize: 50, savedSelectedWorldID: saved)
            importedLegacySelection = true
            try await consume(confirmed)
            return await cacheSelectedWorld()
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    private func nativeWorld(_ world: RustMarbleControlClient.World) throws -> MarbleWorld {
        guard ["glTF", "worldLabsOpenCV"].contains(world.colliderCoordinates) else { throw RustMarbleControlError.invalidResponse }
        let assets = try world.splatFallbacks.map { asset -> MarbleSplatAsset in
            guard let quality = MarbleSplatQuality(rawValue: asset.quality) else { throw RustMarbleControlError.invalidResponse }
            return MarbleSplatAsset(quality: quality, url: asset.url)
        }
        return MarbleWorld(id: world.id, name: world.name, model: world.model,
            thumbnailURL: world.thumbnailURL, colliderURL: world.colliderURL,
            colliderSourceCoordinates: world.colliderCoordinates == "glTF" ? .glTF : .worldLabsOpenCV,
            semantics: MarbleWorldSemantics(metricScale: world.semantics.metricScale,
                groundPlaneOffset: world.semantics.groundPlaneOffset), splatFallbacks: assets)
    }

    private func project(_ value: RustMarbleControlClient.Snapshot) throws {
        worlds = try value.worlds.map(nativeWorld)
        presetWorldIDs = value.presetWorldIDs
        generationProgress = value.task?.progress
        generationMessage = value.task?.phase
        errorMessage = value.task?.errorMessage ?? value.task?.errorCode
        if selectedWorld?.id != value.selectedWorldID {
            selectionRevision &+= 1
            selectedLocalWorldID = nil
            localSplatURL = nil
            selectedWorld = worlds.first { $0.id == value.selectedWorldID }
            if let world = selectedWorld { spatialStage.selectScene(.inferred(worldID: world.id, name: world.name)) }
            spatialStage.selectWorld(id: value.selectedWorldID)
        } else if let selectedID = value.selectedWorldID {
            selectedWorld = worlds.first { $0.id == selectedID }
        }
    }

    private func consume(_ initial: RustMarbleControlClient.Snapshot) async throws {
        var value = initial
        while true {
            try project(value)
            guard let task = value.task, task.status == "pending" else { return }
            if let delay = value.waitMS, delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
                value = try await authority.read()
                continue
            }
            value = try await authority.claim(taskID: task.taskID, expectedRevision: value.revision)
            if value.action == nil, let delay = value.waitMS, delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
                value = try await authority.read()
                continue
            }
            guard let action = value.action, action.taskID == task.taskID,
                  action.hostSessionID == task.hostSessionID,
                  action.generation == task.generation,
                  action.status == "inflight" else { throw RustMarbleControlError.executionUnknown }
            if action.kind == "prepare_package" {
                guard let world = action.world else { throw RustMarbleControlError.invalidResponse }
                let digest: String
                do { digest = try await preparePackage(nativeWorld(world)) }
                catch {
                    value = try await record(action, fact: RustMarbleControlClient.PackageFailureFact(
                        preparationErrorCode: error is CancellationError ? "native_cancelled" : "native_preparation_failed"))
                    continue
                }
                value = try await record(action, fact: RustMarbleControlClient.PackageFact(manifestSHA256: digest))
            } else {
                guard let method = action.method, let path = action.path else { throw RustMarbleControlError.invalidResponse }
                let observed = await client.executePlannedHTTP(method: method, path: path, body: try action.bodyData)
                let fact: RustMarbleControlClient.HTTPFact
                if let code = observed.transportErrorCode { fact = .init(transportErrorCode: code) }
                else if let status = observed.statusCode, let body = observed.body { fact = .init(statusCode: status, body: body) }
                else { throw RustMarbleControlError.executionUnknown }
                value = try await record(action, fact: fact)
            }
        }
    }

    private func record<F: Encodable & Sendable>(_ action: RustMarbleControlClient.Action,
                                                 fact: F) async throws -> RustMarbleControlClient.Snapshot {
        // Only the identical observed receipt is retried. The native action is never replayed.
        let requestID = UUID().uuidString
        do { return try await authority.receipt(action, fact: fact, requestID: requestID) }
        catch { return try await authority.receipt(action, fact: fact, requestID: requestID) }
    }

    private func cacheSelectedWorld() async -> URL? {
        guard let selectedWorld,
              let asset = selectedWorld.preferredSplat
        else {
            errorMessage = "这个 Marble 空间还没有 SPZ 资源。"
            return nil
        }

        let expectedSelectionRevision = selectionRevision
        do {
            let url = try await cache.localSplat(
                for: selectedWorld,
                asset: asset
            )
            guard selectionRevision == expectedSelectionRevision,
                  self.selectedWorld?.id == selectedWorld.id else {
                return localSplatURL
            }
            localSplatURL = url
            onLocalSplatChange?(url)
            return url
        } catch {
            guard selectionRevision == expectedSelectionRevision else { return localSplatURL }
            errorMessage = error.localizedDescription
            Self.log.error("Unable to cache Marble world: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}
