import CryptoKit
import Foundation
import WorldRuntime

@MainActor protocol UnityMarbleWorldCommands: AnyObject {
    var snapshot: [String: Any] { get }
    func command(_ value: [String: Any]) -> Bool
    func close()
}

/// Lists complete, registered world packages only. Marble SPZ caches are not
/// authority packages and cannot be selected until the adoption pipeline publishes world.json.
@MainActor final class UnitySpaceLibraryBridge {
    private struct Entry {
        let package: BundledLivingWorldPackage
        let manifestHash: String
    }
    private var roots: [URL]
    private let marble: (any UnityMarbleWorldCommands)?
    private let defaults: UserDefaults
    private let productDefaults: UserDefaults?
    private let livingPodWorldID: String?
    private let selectedWorldID: @MainActor () -> String?
    private let requestSelection: @MainActor (BundledLivingWorldPackage, UInt64) -> Bool
    private let loadMarbleWorlds: (@MainActor () async throws -> [MarbleWorld])?
    private var marbleWorlds: [MarbleWorld] = []
    private var marbleTask: Task<Void, Never>?
    private var marbleNoticeCode = "space_marble_requires_package"
    private var entries: [String: Entry] = [:]
    private var revision: UInt64 = 0
    private var pending: (id: String, revision: UInt64, hash: String)?
    private var noticeCode = "space_library_loaded"
    private var invalidPackageCount = 0
    private var closed = false

    init(registeredPackageRoots: [URL], defaults: UserDefaults,
         selectedWorldID: @escaping @MainActor () -> String?,
         requestSelection: @escaping @MainActor (BundledLivingWorldPackage, UInt64) -> Bool,
         loadMarbleWorlds: (@MainActor () async throws -> [MarbleWorld])? = nil,
         productDefaults: UserDefaults? = nil, livingPodWorldID: String? = nil,
         marble: (any UnityMarbleWorldCommands)? = nil) {
        roots = registeredPackageRoots; self.defaults = defaults
        self.marble = marble
        self.productDefaults = productDefaults; self.livingPodWorldID = livingPodWorldID
        self.selectedWorldID = selectedWorldID; self.requestSelection = requestSelection
        self.loadMarbleWorlds = loadMarbleWorlds
        reload()
    }
    var savedSelectionID: String? { defaults.string(forKey: "unity.space.selectedWorldID") }
    private var defaultSpace: DefaultSpacePreference {
        // An explicit Unity choice wins; absence inherits the original product
        // preference without modifying its separate defaults domain.
        DefaultSpacePreference.load(defaults: defaults.object(forKey: DefaultSpacePreference.defaultsKey) == nil
            ? productDefaults ?? defaults : defaults)
    }
    var defaultSpaceSnapshot: [String: Any] {
        ["defaultSpace": defaultSpace.rawValue,
         "options": DefaultSpacePreference.allCases.map { ["id": $0.rawValue, "name": $0.title, "detail": $0.detail] }]
    }
    /// Startup preference only; package validation and authority readback still
    /// determine availability. Never adopt raw Marble caches as formal packages.
    func startupSelectionIDs() -> [String] {
        switch defaultSpace {
        case .livingPod: return livingPodWorldID.map { [$0] } ?? []
        case .lastMarbleWorld:
            return [defaults.string(forKey: "marble.selected-world-id"), savedSelectionID,
                    productDefaults?.string(forKey: "marble.selected-world-id")].compactMap { $0 }
        }
    }
    var snapshot: [String: Any] {
        var result: [String: Any] = ["worlds": entries.values.sorted { $0.package.manifest.worldID < $1.package.manifest.worldID }.map { entry in
            let manifest = entry.package.manifest
            return ["id": manifest.worldID, "name": manifest.displayName,
                    "packageID": manifest.packageID, "packageVersion": manifest.packageVersion,
                    "manifestPath": entry.package.packageRoot.appendingPathComponent("world.json").path,
                    "packageRoot": entry.package.packageRoot.path, "manifestSHA256": entry.manifestHash,
                    "resourceCount": manifest.resources.count,
                    "selected": selectedWorldID() == manifest.worldID] as [String: Any]
        }, "selectedID": selectedWorldID() as Any? ?? NSNull(),
         "working": pending != nil, "pendingID": pending?.id as Any? ?? NSNull(),
         "selectionRevision": revision, "noticeCode": noticeCode,
         "invalidPackageCount": invalidPackageCount, "generationSupported": false,
         "marbleWorlds": marbleWorlds.map { ["id": $0.id, "name": $0.name, "requiresFormalPackage": true] as [String: Any] },
         "marbleLoading": marbleTask != nil, "marbleNoticeCode": marbleNoticeCode]
        for (key, value) in marble?.snapshot ?? [:] { result[key] = value }
        return result
    }
    func package(for id: String) -> BundledLivingWorldPackage? {
        guard let entry = entries[id], let current = try? validated(entry.package.packageRoot),
              current.manifestHash == entry.manifestHash else { return nil }
        return current.package
    }
    func settingsCommand(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        switch op {
        case _ where op.hasPrefix("space.marble."): return marble?.command(value) ?? false
        case "space.default":
            guard let raw = value["value"] as? String, let preference = DefaultSpacePreference(rawValue: raw) else { return false }
            preference.save(defaults: defaults); return true
        case "space.library.load": guard pending == nil else { return false }; reload(); refreshMarble(); return true
        case "space.library.select":
            guard pending == nil, let id = value["id"] as? String,
                  let package = package(for: id), let entry = entries[id] else { return false }
            revision &+= 1; pending = (id, revision, entry.manifestHash); noticeCode = "space_library_switching"
            guard requestSelection(package, revision) else {
                pending = nil; noticeCode = "space_library_switch_failed"; return false
            }
            return true
        default: return false
        }
    }
    /// Call only after the actual worldSession and renderer have completed their
    /// selection transaction. A request acceptance is not a switch receipt.
    @discardableResult func completeSelection(revision: UInt64, worldID: String, success: Bool) -> Bool {
        guard !closed, let pending, pending.revision == revision, pending.id == worldID else { return false }
        self.pending = nil
        guard success, selectedWorldID() == worldID, let entry = entries[worldID],
              let current = try? validated(entry.package.packageRoot), current.manifestHash == pending.hash else {
            noticeCode = "space_library_switch_failed"; return false
        }
        defaults.set(worldID, forKey: "unity.space.selectedWorldID")
        defaults.set(worldID, forKey: "marble.selected-world-id")
        noticeCode = "space_library_selected"; return true
    }
    @discardableResult func registerPackage(_ package: BundledLivingWorldPackage) -> Bool {
        guard !closed, let entry = try? validated(package.packageRoot),
              entry.package.manifest.worldID == package.manifest.worldID,
              let marker = try? String(contentsOf: package.packageRoot.appendingPathComponent("registered.sha256"), encoding: .utf8),
              marker == entry.manifestHash else { return false }
        if let existing = entries[package.manifest.worldID], existing.manifestHash != entry.manifestHash { return false }
        roots.append(package.packageRoot)
        entries[package.manifest.worldID] = entry
        return true
    }
    func close() { closed = true; pending = nil; marbleTask?.cancel(); marbleTask = nil; marble?.close() }
    private func refreshMarble() {
        guard let loadMarbleWorlds, marbleTask == nil else { return }
        marbleTask = Task { [weak self] in
            do {
                let worlds = try await loadMarbleWorlds()
                guard let self, !closed, !Task.isCancelled else { return }
                marbleWorlds = worlds; marbleNoticeCode = "space_marble_requires_package"; marbleTask = nil
            } catch {
                guard let self, !closed, !Task.isCancelled else { return }
                marbleNoticeCode = "space_marble_read_failed"; marbleTask = nil
            }
        }
    }
    private func reload() {
        entries = [:]; invalidPackageCount = 0
        var duplicateIDs = Set<String>()
        for root in Set(roots.map { $0.standardizedFileURL }) {
            do {
                let entry = try validated(root)
                let id = entry.package.manifest.worldID
                if entries[id] != nil || duplicateIDs.contains(id) {
                    entries.removeValue(forKey: id); duplicateIDs.insert(id); invalidPackageCount += 1
                } else { entries[id] = entry }
            } catch { invalidPackageCount += 1 }
        }
        noticeCode = invalidPackageCount == 0 ? "space_library_loaded" : "space_library_invalid_packages"
    }
    private func validated(_ root: URL) throws -> Entry {
        let root = root.standardizedFileURL
        guard root.isFileURL, root.resolvingSymlinksInPath() == root,
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw InvalidPackage.invalid }
        let url = root.appendingPathComponent("world.json")
        guard url.resolvingSymlinksInPath() == url,
              try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile == true,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw InvalidPackage.invalid }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: data)
        guard !manifest.worldID.isEmpty, WorldPackageValidator().validate(manifest, packageRoot: root).isEmpty else { throw InvalidPackage.invalid }
        return Entry(package: BundledLivingWorldPackage(manifest: manifest, packageRoot: root),
                     manifestHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private enum InvalidPackage: Error { case invalid }
}
