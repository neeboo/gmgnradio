import Foundation

struct BuiltInVRMResource: Sendable {
    let id: String
    let name: String
    let url: URL
    let engine: PresenceEngine

    init(
        id: String,
        name: String,
        url: URL,
        engine: PresenceEngine = .vrm
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.engine = engine
    }
}

struct PresencePackageStore: Sendable {
    static let builtInOrbID = "builtin.orb"

    let rootURL: URL
    let builtInVRMs: [BuiltInVRMResource]
    let selectionAuthority: RustPresenceSelectionClient

    init(
        rootURL: URL,
        builtInVRMs: [BuiltInVRMResource]? = nil,
        selectionAuthority: RustPresenceSelectionClient? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.builtInVRMs = builtInVRMs ?? Self.bundledVRMs()
        self.selectionAuthority = selectionAuthority ?? .forCatalogRoot(rootURL.deletingLastPathComponent())
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
        let builtIns = [builtInOrbPackage(activeID: activeID)]
            + builtInVRMs.map { builtInVRMPackage($0, activeID: activeID) }
        var installed: [PresencePackage] = []

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
            installed.append(
                makePackage(
                    manifest: manifest,
                    packageURL: child,
                    activeID: activeID,
                    isBuiltIn: false
                )
            )
        }

        installed.sort {
            $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
        return builtIns + installed
    }

    func listAvatarAssets(
        fileManager: FileManager = .default
    ) throws -> [StageAvatarAsset] {
        try listPackages(fileManager: fileManager).compactMap { package in
            guard
                let installPath = package.installPath,
                let format = package.manifest.engine.avatarFormat
            else {
                return nil
            }
            let resourceRootURL = URL(filePath: installPath, directoryHint: .isDirectory)
                .standardizedFileURL
            return StageAvatarAsset(
                id: package.manifest.id,
                name: package.manifest.name,
                format: format,
                modelURL: resourceRootURL
                    .appending(path: package.manifest.entry)
                    .standardizedFileURL,
                resourceRootURL: resourceRootURL
            )
        }
    }

    func activeAvatar(
        fileManager: FileManager = .default
    ) throws -> StageAvatarAsset? {
        let activeID = try readActiveID(fileManager: fileManager)
        let packages = try listPackages(fileManager: fileManager)
        guard let activePackage = packages.first(where: { $0.manifest.id == activeID }) else {
            throw PresencePackageError.packageNotFound
        }
        guard
            let installPath = activePackage.installPath,
            let format = activePackage.manifest.engine.avatarFormat
        else {
            return nil
        }
        let resourceRootURL = URL(filePath: installPath, directoryHint: .isDirectory)
            .standardizedFileURL
        return StageAvatarAsset(
            id: activePackage.manifest.id,
            name: activePackage.manifest.name,
            format: format,
            modelURL: resourceRootURL
                .appending(path: activePackage.manifest.entry)
                .standardizedFileURL,
            resourceRootURL: resourceRootURL
        )
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
        } else if sourceURL.pathExtension.lowercased() == "vrm" {
            try prepareRawVRMPackage(
                from: sourceURL,
                at: unpackedURL,
                fileManager: fileManager
            )
        } else if ["zip", "gmgnpet"].contains(sourceURL.pathExtension.lowercased()) {
            try fileManager.createDirectory(at: unpackedURL, withIntermediateDirectories: true)
            try validateArchiveEntries(sourceURL)
            try extractArchive(sourceURL, to: unpackedURL)
        } else {
            throw PresencePackageError.unsupportedPackage
        }
        try validateExtractedTree(at: unpackedURL, fileManager: fileManager)

        let packageURL = try resolvedOrPreparedPackageRoot(
            in: unpackedURL,
            fileManager: fileManager
        )
        let manifest = try decodeManifest(at: packageURL)
        try validate(manifest: manifest, packageURL: packageURL, fileManager: fileManager)

        let destination = rootURL
            .appending(path: manifest.id, directoryHint: .isDirectory)
            .standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PresencePackageError.alreadyInstalled
        }
        try fileManager.moveItem(at: packageURL, to: destination)

        return makePackage(
            manifest: manifest,
            packageURL: destination,
            activeID: try readActiveID(fileManager: fileManager),
            isBuiltIn: false
        )
    }

    func activateAsync(id: String) async throws { _ = try await selectionAuthority.event("select_avatar", id: id) }

    func removeAsync(id: String) async throws {
        try await selectionAuthority.remove(kind: "avatars", id: id, root: rootURL)
    }


    private func builtInOrbPackage(activeID: String) -> PresencePackage {
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

    private func builtInVRMPackage(
        _ resource: BuiltInVRMResource,
        activeID: String
    ) -> PresencePackage {
        PresencePackage(
            manifest: PresenceManifest(
                id: resource.id,
                name: resource.name,
                version: "1.0.0",
                engine: resource.engine,
                entry: resource.url.lastPathComponent
            ),
            installPath: resource.url.deletingLastPathComponent().path,
            thumbnailPath: nil,
            isActive: activeID == resource.id,
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
                || manifest.engine == .vrm
                || manifest.engine == .pmx
        )
    }

    private func ensureRootExists(fileManager: FileManager) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func readActiveID(fileManager: FileManager) throws -> String {
        selectionAuthority.confirmed?.avatarID ?? Self.builtInOrbID
    }


    private static func bundledVRMs(bundle: Bundle = .main) -> [BuiltInVRMResource] {
        []
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
        switch manifest.engine {
        case .live2D:
            try validateLive2D(
                manifest: manifest,
                packageURL: packageURL,
                fileManager: fileManager
            )
        case .vrm:
            try validateVRM(
                manifest: manifest,
                packageURL: packageURL,
                fileManager: fileManager
            )
        case .pmx:
            try validatePMX(
                manifest: manifest,
                packageURL: packageURL,
                fileManager: fileManager
            )
        case .orb:
            throw PresencePackageError.unsupportedPackage
        }

        if let thumbnail = manifest.thumbnail {
            _ = try safeRelativeURL(thumbnail, inside: packageURL)
        }
    }

    private func validateLive2D(
        manifest: PresenceManifest,
        packageURL: URL,
        fileManager: FileManager
    ) throws {
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
    }

    private func validateVRM(
        manifest: PresenceManifest,
        packageURL: URL,
        fileManager: FileManager
    ) throws {
        let entryURL = try safeRelativeURL(manifest.entry, inside: packageURL)
        guard manifest.entry.lowercased().hasSuffix(".vrm") else {
            throw PresencePackageError.invalidEntryPath
        }
        guard fileManager.fileExists(atPath: entryURL.path) else {
            throw PresencePackageError.modelFileMissing
        }

        let data = try Data(contentsOf: entryURL, options: .mappedIfSafe)
        guard
            data.count >= 20,
            Array(data[0 ..< 4]) == Array("glTF".utf8),
            littleEndianUInt32(in: data, at: 4) == 2,
            littleEndianUInt32(in: data, at: 8) == data.count,
            littleEndianUInt32(in: data, at: 16) == 0x4E4F534A
        else {
            throw PresencePackageError.invalidVRM
        }

        let jsonLength = Int(littleEndianUInt32(in: data, at: 12))
        guard jsonLength >= 2, 20 + jsonLength <= data.count else {
            throw PresencePackageError.invalidVRM
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: data.subdata(in: 20 ..< (20 + jsonLength))
            ) as? [String: Any],
            let extensions = object["extensions"] as? [String: Any],
            extensions["VRMC_vrm"] != nil || extensions["VRM"] != nil
        else {
            throw PresencePackageError.invalidVRM
        }
    }

    private func validatePMX(
        manifest: PresenceManifest,
        packageURL: URL,
        fileManager: FileManager
    ) throws {
        let entryURL = try safeRelativeURL(manifest.entry, inside: packageURL)
        guard manifest.entry.lowercased().hasSuffix(".pmx") else {
            throw PresencePackageError.invalidEntryPath
        }
        guard fileManager.fileExists(atPath: entryURL.path) else {
            throw PresencePackageError.modelFileMissing
        }

        let texturePaths: [String]
        do {
            texturePaths = try PMXResourceReader(
                data: Data(contentsOf: entryURL, options: .mappedIfSafe)
            ).texturePaths()
        } catch let error as PresencePackageError {
            throw error
        } catch {
            throw PresencePackageError.invalidPMX
        }
        for rawPath in texturePaths where !rawPath.isEmpty {
            let normalizedPath = rawPath.replacingOccurrences(of: "\\", with: "/")
            let textureURL = try safeRelativeURL(normalizedPath, inside: packageURL)
            guard fileManager.fileExists(atPath: textureURL.path) else {
                throw PresencePackageError.missingPMXTexture(rawPath)
            }
        }
    }

    private func prepareRawVRMPackage(
        from sourceURL: URL,
        at packageURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let filename = sourceURL.lastPathComponent
        try fileManager.copyItem(
            at: sourceURL,
            to: packageURL.appending(path: filename)
        )
        let manifest = PresenceManifest(
            id: "vrm.\(UUID().uuidString.lowercased())",
            name: sourceURL.deletingPathExtension().lastPathComponent,
            version: "1.0.0",
            engine: .vrm,
            entry: filename
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: packageURL.appending(path: "manifest.json"),
            options: .atomic
        )
    }

    private func prepareRawPMXPackage(
        at packageURL: URL,
        entry: String
    ) throws {
        let entryURL = try safeRelativeURL(entry, inside: packageURL)
        let manifest = PresenceManifest(
            id: "pmx.\(UUID().uuidString.lowercased())",
            name: entryURL.deletingPathExtension().lastPathComponent,
            version: "1.0.0",
            engine: .pmx,
            entry: entry
        )
        try JSONEncoder().encode(manifest).write(
            to: packageURL.appending(path: "manifest.json"),
            options: .atomic
        )
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func safeRelativeURL(_ path: String, inside root: URL) throws -> URL {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !normalizedPath.isEmpty,
            !normalizedPath.hasPrefix("/"),
            normalizedPath.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
            !components.contains(".."),
            !components.contains("")
        else {
            throw PresencePackageError.invalidEntryPath
        }
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot.appending(path: normalizedPath).standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw PresencePackageError.invalidEntryPath
        }
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(resolvedRootPrefix) else {
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

    private func validateArchiveEntries(_ archiveURL: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archiveURL.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard
            process.terminationStatus == 0,
            let listing = String(data: data, encoding: .utf8)
        else {
            throw PresencePackageError.unsupportedPackage
        }
        for rawEntry in listing.split(whereSeparator: { $0.isNewline }) {
            let entry = String(rawEntry).replacingOccurrences(of: "\\", with: "/")
            let components = entry.split(separator: "/", omittingEmptySubsequences: true)
            guard
                !entry.hasPrefix("/"),
                entry.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
                !components.contains("..")
            else {
                throw PresencePackageError.unsafeArchiveEntry(entry)
            }
        }
    }

    private func validateExtractedTree(
        at root: URL,
        fileManager: FileManager
    ) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw PresencePackageError.unsupportedPackage
        }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw PresencePackageError.unsafeArchiveEntry(child.lastPathComponent)
            }
            let resolvedPath = child.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(rootPath) else {
                throw PresencePackageError.unsafeArchiveEntry(child.lastPathComponent)
            }
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

    private func resolvedOrPreparedPackageRoot(
        in unpackedURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        do {
            return try resolvedPackageRoot(in: unpackedURL, fileManager: fileManager)
        } catch PresencePackageError.manifestMissing {
            let rawPackage = try findRawPMXPackage(
                in: unpackedURL,
                fileManager: fileManager
            )
            try prepareRawPMXPackage(at: rawPackage.root, entry: rawPackage.entry)
            return rawPackage.root
        }
    }

    private func findRawPMXPackage(
        in unpackedURL: URL,
        fileManager: FileManager
    ) throws -> (root: URL, entry: String) {
        let children = try fileManager.contentsOfDirectory(
            at: unpackedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let directories = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let searchRoot = children.filter({
            $0.pathExtension.lowercased() == "pmx"
        }).isEmpty && directories.count == 1
            ? directories[0]
            : unpackedURL

        guard let enumerator = fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PresencePackageError.manifestMissing
        }
        var models: [URL] = []
        for case let candidate as URL in enumerator
        where candidate.pathExtension.lowercased() == "pmx" {
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PresencePackageError.invalidEntryPath
            }
            models.append(candidate)
        }
        guard models.count == 1, let modelURL = models.first else {
            throw PresencePackageError.manifestMissing
        }
        let rootPath = searchRoot.standardizedFileURL.path + "/"
        guard modelURL.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw PresencePackageError.invalidEntryPath
        }
        let entry = String(modelURL.standardizedFileURL.path.dropFirst(rootPath.count))
        return (searchRoot, entry)
    }
}

private extension PresenceEngine {
    var avatarFormat: StageAvatarFormat? {
        switch self {
        case .vrm: .vrm
        case .pmx: .pmx
        case .orb, .live2D: nil
        }
    }
}

private struct PMXResourceReader {
    let data: Data

    func texturePaths() throws -> [String] {
        var cursor = PMXByteCursor(data: data)
        guard try cursor.readData(count: 4) == Data("PMX ".utf8) else {
            throw PresencePackageError.invalidPMX
        }
        let version = try cursor.readFloat32()
        guard abs(version - 2.0) < 0.001 || abs(version - 2.1) < 0.001 else {
            throw PresencePackageError.invalidPMX
        }
        let headerSize = Int(try cursor.readUInt8())
        guard headerSize == 8 else {
            throw PresencePackageError.invalidPMX
        }
        let header = [UInt8](try cursor.readData(count: headerSize))
        let textEncoding = header[0]
        let additionalUVCount = Int(header[1])
        let vertexIndexSize = Int(header[2])
        let boneIndexSize = Int(header[5])
        let indexSizes = header[2 ... 7]
        guard
            [0, 1].contains(textEncoding),
            (0 ... 4).contains(additionalUVCount),
            indexSizes.allSatisfy({ [1, 2, 4].contains($0) }),
            [1, 2, 4].contains(vertexIndexSize),
            [1, 2, 4].contains(boneIndexSize)
        else {
            throw PresencePackageError.invalidPMX
        }

        for _ in 0 ..< 4 {
            _ = try cursor.readText(encoding: textEncoding)
        }

        let vertexCount = try cursor.readCount(limit: 10_000_000)
        for _ in 0 ..< vertexCount {
            try cursor.skip(12 + 12 + 8 + additionalUVCount * 16)
            switch try cursor.readUInt8() {
            case 0:
                try cursor.skip(boneIndexSize)
            case 1:
                try cursor.skip(boneIndexSize * 2 + 4)
            case 2, 4:
                try cursor.skip(boneIndexSize * 4 + 16)
            case 3:
                try cursor.skip(boneIndexSize * 2 + 4 + 36)
            default:
                throw PresencePackageError.invalidPMX
            }
            try cursor.skip(4)
        }

        let surfaceIndexCount = try cursor.readCount(limit: 100_000_000)
        try cursor.skip(surfaceIndexCount * vertexIndexSize)

        let textureCount = try cursor.readCount(limit: 100_000)
        return try (0 ..< textureCount).map { _ in
            try cursor.readText(encoding: textEncoding)
        }
    }
}

private struct PMXByteCursor {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw PresencePackageError.invalidPMX }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readInt32() throws -> Int32 {
        let bytes = try readData(count: 4)
        let value = UInt32(bytes[bytes.startIndex])
            | (UInt32(bytes[bytes.startIndex + 1]) << 8)
            | (UInt32(bytes[bytes.startIndex + 2]) << 16)
            | (UInt32(bytes[bytes.startIndex + 3]) << 24)
        return Int32(bitPattern: value)
    }

    mutating func readFloat32() throws -> Float {
        Float(bitPattern: UInt32(bitPattern: try readInt32()))
    }

    mutating func readCount(limit: Int) throws -> Int {
        let count = Int(try readInt32())
        guard count >= 0, count <= limit else {
            throw PresencePackageError.invalidPMX
        }
        return count
    }

    mutating func readText(encoding: UInt8) throws -> String {
        let length = try readCount(limit: 16 * 1_024 * 1_024)
        let bytes = try readData(count: length)
        let stringEncoding: String.Encoding = encoding == 0 ? .utf16LittleEndian : .utf8
        guard let value = String(data: bytes, encoding: stringEncoding) else {
            throw PresencePackageError.invalidPMX
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw PresencePackageError.invalidPMX
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func skip(_ count: Int) throws {
        _ = try readData(count: count)
    }
}
