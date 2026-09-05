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

    private(set) var worlds: [MarbleWorld] = MarblePublicWorldCatalog.worlds
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
        spatialStage: SpatialStageStore
    ) {
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
        guard let world = worlds.first(where: { $0.id == worldID }) else {
            return nil
        }
        selectionRevision &+= 1
        selectedLocalWorldID = nil
        selectedWorld = world
        spatialStage.selectScene(
            .inferred(worldID: world.id, name: world.name)
        )
        spatialStage.selectWorld(id: world.id)
        localSplatURL = nil
        errorMessage = nil
        return await cacheSelectedWorld()
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
        worlds.contains { world in
            world.name.compare(
                preset.worldDisplayName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    func activate(preset: SpatialScenePreset) async {
        guard generatingPreset == nil else {
            return
        }

        errorMessage = nil
        if worlds.isEmpty {
            await reloadWorlds()
        }

        if let world = world(for: preset) {
            spatialStage.selectScene(preset)
            _ = await select(worldID: world.id)
            return
        }

        await generateAndActivate(preset)
    }

    private func performPreparation(
        expectedSelectionRevision: UInt64
    ) async -> URL? {
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        do {
            let accountWorlds = try await client.listWorlds(pageSize: 50)
            guard selectionRevision == expectedSelectionRevision else {
                return localSplatURL
            }
            worlds = mergedWithPublicExamples(accountWorlds)

            let savedID = UserDefaults.standard.string(
                forKey: "marble.selected-world-id"
            )
            selectedWorld = worlds.first { $0.id == savedID }
                ?? world(for: .djHouse)
                ?? worlds.first { $0.id == Self.preferredInitialWorldID }
                ?? worlds.first
            if let selectedWorld {
                spatialStage.selectScene(
                    .inferred(
                        worldID: selectedWorld.id,
                        name: selectedWorld.name
                    )
                )
            }
            spatialStage.selectWorld(id: selectedWorld?.id)
            return await cacheSelectedWorld()
        } catch {
            worlds = MarblePublicWorldCatalog.worlds
            guard selectionRevision == expectedSelectionRevision else {
                return localSplatURL
            }
            selectedWorld = restoredOrInitialWorld()
            if let selectedWorld {
                spatialStage.selectScene(
                    .inferred(
                        worldID: selectedWorld.id,
                        name: selectedWorld.name
                    )
                )
            }
            spatialStage.selectWorld(id: selectedWorld?.id)
            Self.log.notice("Marble account unavailable; using official public SPZ examples: \(error.localizedDescription, privacy: .public)")
            return await cacheSelectedWorld()
        }
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
            UserDefaults.standard.set(
                selectedWorld.id,
                forKey: "marble.selected-world-id"
            )
            onLocalSplatChange?(url)
            return url
        } catch {
            guard selectionRevision == expectedSelectionRevision else { return localSplatURL }
            errorMessage = error.localizedDescription
            Self.log.error("Unable to cache Marble world: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func world(for preset: SpatialScenePreset) -> MarbleWorld? {
        worlds.first { world in
            world.name.compare(
                preset.worldDisplayName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    private func reloadWorlds() async {
        do {
            worlds = mergedWithPublicExamples(
                try await client.listWorlds(pageSize: 100)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergedWithPublicExamples(
        _ accountWorlds: [MarbleWorld]
    ) -> [MarbleWorld] {
        let accountIDs = Set(accountWorlds.map(\.id))
        return accountWorlds + MarblePublicWorldCatalog.worlds.filter {
            !accountIDs.contains($0.id)
        }
    }

    private func restoredOrInitialWorld() -> MarbleWorld? {
        let savedID = UserDefaults.standard.string(
            forKey: "marble.selected-world-id"
        )
        return worlds.first { $0.id == savedID }
            ?? world(for: .djHouse)
            ?? worlds.first { $0.id == Self.preferredInitialWorldID }
            ?? worlds.first
    }

    private func generateAndActivate(_ preset: SpatialScenePreset) async {
        generatingPreset = preset
        generationProgress = nil
        generationMessage = "正在生成 \(preset.displayName)…"
        defer {
            generatingPreset = nil
            generationProgress = nil
        }

        do {
            var operation = try await client.generateWorld(preset: preset)
            for _ in 0 ..< 120 {
                try Task.checkCancellation()
                if operation.isDone {
                    break
                }
                generationProgress = operation.progressPercentage
                if let percentage = operation.progressPercentage {
                    generationMessage = "正在生成 \(preset.displayName) · \(percentage)%"
                }
                try await Task.sleep(for: .seconds(3))
                operation = try await client.operation(id: operation.id)
            }

            if let message = operation.errorMessage {
                throw MarbleWorldClientError.generationFailed(message)
            }
            guard operation.isDone else {
                throw MarbleWorldClientError.generationTimedOut
            }

            generationMessage = "空间完成，正在下载…"
            for _ in 0 ..< 10 {
                await reloadWorlds()
                if let generatedWorld = world(for: preset) {
                    spatialStage.selectScene(preset)
                    _ = await select(worldID: generatedWorld.id)
                    generationMessage = "已进入 \(preset.displayName)"
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw MarbleWorldClientError.generatedWorldMissing
        } catch is CancellationError {
            generationMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            generationMessage = nil
            Self.log.error("Unable to generate Marble world: \(error.localizedDescription, privacy: .public)")
        }
    }
}
