import Foundation

struct PresencePackageStore: Sendable {
    static let builtInOrbID = "builtin.orb"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    static func liveStore(fileManager: FileManager = .default) throws -> PresencePackageStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PresencePackageStore(
            rootURL: applicationSupport
                .appending(path: ProductIdentity.displayName, directoryHint: .isDirectory)
                .appending(path: "PresencePackages", directoryHint: .isDirectory)
        )
    }

    func listPackages(fileManager: FileManager = .default) throws -> [PresencePackage] {
        try ensureRootExists(fileManager: fileManager)
        let activeID = try readActiveID(fileManager: fileManager)
        var packages = [builtInPackage(activeID: activeID)]

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            guard
                child.lastPathComponent != "fixtures",
                (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                fileManager.fileExists(atPath: child.appending(path: "manifest.json").path),
                let manifest = try? decodeManifest(at: child),
                (try? validate(manifest: manifest, packageURL: child, fileManager: fileManager)) != nil
            else {
                continue
            }
            packages.append(
                makePackage(
                    manifest: manifest,
                    packageURL: child,
                    activeID: activeID,
                    isBuiltIn: false
                )
            )
        }

        let installed = packages.dropFirst().sorted {
            $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
        return [packages[0]] + installed
    }

    func installPackage(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> PresencePackage {
        try ensureRootExists(fileManager: fileManager)
        let stagingRoot = rootURL
            .appending(path: ".staging", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let unpackedURL = stagingRoot.appending(path: "package", directoryHint: .isDirectory)
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try fileManager.copyItem(at: sourceURL, to: unpackedURL)
        } else if ["zip", "gmgnpet"].contains(sourceURL.pathExtension.lowercased()) {
            try fileManager.createDirectory(at: unpackedURL, withIntermediateDirectories: true)
            try extractArchive(sourceURL, to: unpackedURL)
        } else {
            throw PresencePackageError.unsupportedPackage
        }

        let packageURL = try resolvedPackageRoot(in: unpackedURL, fileManager: fileManager)
        let manifest = try decodeManifest(at: packageURL)
        try validate(manifest: manifest, packageURL: packageURL, fileManager: fileManager)

        let destination = rootURL
            .appending(path: manifest.id, directoryHint: .isDirectory)
            .standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PresencePackageError.alreadyInstalled
        }
        try fileManager.copyItem(at: packageURL, to: destination)

        return makePackage(
            manifest: manifest,
            packageURL: destination,
            activeID: try readActiveID(fileManager: fileManager),
            isBuiltIn: false
        )
    }

    func activate(id: String, fileManager: FileManager = .default) throws {
        try ensureRootExists(fileManager: fileManager)
        guard try (
            id == Self.builtInOrbID
                || installedPackageExists(id: id, fileManager: fileManager)
        ) else {
            throw PresencePackageError.packageNotFound
        }
        let data = try JSONEncoder().encode(Selection(activeID: id))
        try data.write(to: selectionURL, options: .atomic)
    }

    func remove(id: String, fileManager: FileManager = .default) throws {
        guard id != Self.builtInOrbID else {
            throw PresencePackageError.cannotRemoveBuiltIn
        }
        let packageURL = rootURL.appending(path: id, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw PresencePackageError.packageNotFound
        }
        try fileManager.removeItem(at: packageURL)
        if try readActiveID(fileManager: fileManager) == id {
            try activate(id: Self.builtInOrbID, fileManager: fileManager)
        }
    }

    private var selectionURL: URL {
        rootURL.appending(path: ".selection.json")
    }

    private func builtInPackage(activeID: String) -> PresencePackage {
        PresencePackage(
            manifest: PresenceManifest(
                id: Self.builtInOrbID,
                name: "Breathing Orb",
                version: "1.0.0",
                engine: .orb,
                entry: "builtin"
            ),
            installPath: nil,
            thumbnailPath: nil,
            isActive: activeID == Self.builtInOrbID,
            isBuiltIn: true,
            rendererAvailable: true
        )
    }

    private func makePackage(
        manifest: PresenceManifest,
        packageURL: URL,
        activeID: String,
        isBuiltIn: Bool
    ) -> PresencePackage {
        let thumbnailPath = manifest.thumbnail.map {
            packageURL.appending(path: $0).standardizedFileURL.path
        }
        return PresencePackage(
            manifest: manifest,
            installPath: packageURL.path,
            thumbnailPath: thumbnailPath,
            isActive: manifest.id == activeID,
            isBuiltIn: isBuiltIn,
            rendererAvailable: manifest.engine == .orb
        )
    }

    private func ensureRootExists(fileManager: FileManager) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func readActiveID(fileManager: FileManager) throws -> String {
        guard fileManager.fileExists(atPath: selectionURL.path) else {
            return Self.builtInOrbID
        }
        let data = try Data(contentsOf: selectionURL)
        return (try? JSONDecoder().decode(Selection.self, from: data).activeID)
            ?? Self.builtInOrbID
    }

    private func installedPackageExists(id: String, fileManager: FileManager) throws -> Bool {
        let packageURL = rootURL.appending(path: id, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: packageURL.path) else { return false }
        let manifest = try decodeManifest(at: packageURL)
        return manifest.id == id
    }

    private func decodeManifest(at packageURL: URL) throws -> PresenceManifest {
        let manifestURL = packageURL.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PresencePackageError.manifestMissing
        }
        do {
            return try JSONDecoder().decode(
                PresenceManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw PresencePackageError.invalidManifest
        }
    }

    private func validate(
        manifest: PresenceManifest,
        packageURL: URL,
        fileManager: FileManager
    ) throws {
        let identifierPattern = /^[A-Za-z0-9._-]+$/
        guard manifest.id.wholeMatch(of: identifierPattern) != nil else {
            throw PresencePackageError.invalidIdentifier
        }
        guard manifest.engine == .live2D else {
            throw PresencePackageError.unsupportedPackage
        }
        let entryURL = try safeRelativeURL(manifest.entry, inside: packageURL)
        guard manifest.entry.hasSuffix(".model3.json") else {
            throw PresencePackageError.invalidEntryPath
        }
        guard fileManager.fileExists(atPath: entryURL.path) else {
            throw PresencePackageError.modelFileMissing
        }

        guard
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: entryURL))
                as? [String: Any],
            let references = object["FileReferences"] as? [String: Any],
            let mocPath = references["Moc"] as? String
        else {
            throw PresencePackageError.invalidManifest
        }
        let mocURL = try safeRelativeURL(mocPath, inside: packageURL)
        guard fileManager.fileExists(atPath: mocURL.path) else {
            throw PresencePackageError.modelReferenceMissing
        }

        if let thumbnail = manifest.thumbnail {
            _ = try safeRelativeURL(thumbnail, inside: packageURL)
        }
    }

    private func safeRelativeURL(_ path: String, inside root: URL) throws -> URL {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.split(separator: "/").contains("..")
        else {
            throw PresencePackageError.invalidEntryPath
        }
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot.appending(path: path).standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw PresencePackageError.invalidEntryPath
        }
        return candidate
    }

    private func extractArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PresencePackageError.unsupportedPackage
        }
    }

    private func resolvedPackageRoot(
        in unpackedURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        if fileManager.fileExists(atPath: unpackedURL.appending(path: "manifest.json").path) {
            return unpackedURL
        }
        let children = try fileManager.contentsOfDirectory(
            at: unpackedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.filter {
            fileManager.fileExists(atPath: $0.appending(path: "manifest.json").path)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw PresencePackageError.manifestMissing
        }
        return candidate
    }
}

private struct Selection: Codable {
    let activeID: String
}
