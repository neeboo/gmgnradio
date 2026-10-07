import CryptoKit
import Foundation

enum MotionPackageError: Error, Equatable, LocalizedError {
    case motionNotFound
    case unsupportedFormat
    case invalidVRMA
    case invalidVMD
    case alreadyInstalled
    case cannotRemoveBuiltIn
    case invalidPublishedMotionID
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .motionNotFound:
            "找不到这个动作。"
        case .unsupportedFormat:
            "目前支持 .vrma 和 .vmd 动作文件。"
        case .invalidVRMA:
            "文件不是有效的 VRM 动作。"
        case .invalidVMD:
            "文件不是有效的 VMD 动作。"
        case .alreadyInstalled:
            "这个动作已经安装。"
        case .cannotRemoveBuiltIn:
            "内置动作不能删除。"
        case .invalidPublishedMotionID:
            "远端动作编号或版本无效。"
        case .hashMismatch:
            "动作文件哈希与发布目录不一致。"
        }
    }
}

struct BuiltInMotionResource: Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL
    var loop: Bool = true
}

struct InstalledPublishedMotion: Equatable, Sendable {
    let id: String
    let version: String
    let sha256: String
    let loop: Bool
}

struct MotionPackageStore: Sendable {
    private static let selectionVersion = 3
    static let naturalIdleID = "builtin.motion.natural-idle"
    static let studioGrooveID = "builtin.motion.studio-groove"
    static let iluvSlapBassID = "builtin.motion.iluvslapbass"
    static let iluvSlapBassVRMID = "builtin.motion.iluvslapbass-vrm"
    private static let retiredBuiltInMotionIDs: Set<String> = [
        studioGrooveID,
        "builtin.motion.2b-full",
        "builtin.motion.2b-hand",
        "builtin.motion.2b-hand-short",
    ]

    let rootURL: URL
    let builtInMotions: [BuiltInMotionResource]

    init(
        rootURL: URL,
        builtInMotions: [BuiltInMotionResource]
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.builtInMotions = builtInMotions.map {
            BuiltInMotionResource(
                id: $0.id,
                name: $0.name,
                format: $0.format,
                url: $0.url.standardizedFileURL,
                loop: $0.loop
            )
        }
    }

    init(
        rootURL: URL,
        bundledStudioGrooveURL: URL?
    ) {
        self.init(
            rootURL: rootURL,
            builtInMotions: bundledStudioGrooveURL.map {
                [
                    BuiltInMotionResource(
                        id: Self.studioGrooveID,
                        name: "Studio Groove",
                        format: .vrma,
                        url: $0
                    ),
                ]
            } ?? []
        )
    }

    init(rootURL: URL) {
        self.init(
            rootURL: rootURL,
            builtInMotions: Self.bundledMMDMotions()
        )
    }

    static func liveStore(
        fileManager: FileManager = .default
    ) throws -> MotionPackageStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return MotionPackageStore(
            rootURL: applicationSupport
                .appending(path: ProductIdentity.displayName, directoryHint: .isDirectory)
                .appending(path: "MotionPackages", directoryHint: .isDirectory)
        )
    }

    func listMotions(
        fileManager: FileManager = .default
    ) throws -> [StageMotionAsset] {
        try ensureRootExists(fileManager: fileManager)
        var motions = [naturalIdle]
        for resource in builtInMotions {
            switch resource.format {
            case .vrma:
                try validateVRMA(at: resource.url)
            case .vmd:
                try validateVMD(at: resource.url)
            case .procedural:
                continue
            }
            motions.append(
                StageMotionAsset(
                    id: resource.id,
                    name: resource.name,
                    format: resource.format,
                    url: resource.url,
                    loop: resource.loop
                )
            )
        }

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var installed: [StageMotionAsset] = []
        for child in children {
            guard
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]),
                values.isDirectory == true,
                values.isSymbolicLink != true,
                let asset = try? decodeAndValidateMotion(
                    at: child,
                    fileManager: fileManager
                )
            else {
                continue
            }
            if !motions.contains(where: { $0.id == asset.id }) { installed.append(asset) }
        }
        installed.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return motions + installed
    }

    func activeMotion(
        fileManager: FileManager = .default
    ) throws -> StageMotionAsset {
        let activeID = try readActiveID(fileManager: fileManager)
        guard let motion = try listMotions(fileManager: fileManager).first(where: {
            $0.id == activeID
        }) else {
            throw MotionPackageError.motionNotFound
        }
        return motion
    }

    func installedPublishedMotion(
        id: String,
        fileManager: FileManager = .default
    ) throws -> InstalledPublishedMotion? {
        let packageURL = rootURL.appending(path: id, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: packageURL.path) else {
            return nil
        }
        let manifest = try JSONDecoder().decode(
            MotionManifest.self,
            from: Data(contentsOf: packageURL.appending(path: "manifest.json"))
        )
        guard
            manifest.id == id,
            let version = manifest.version,
            let sha256 = manifest.sha256
        else {
            return nil
        }
        _ = try decodeAndValidateMotion(at: packageURL, fileManager: fileManager)
        return InstalledPublishedMotion(
            id: id,
            version: version,
            sha256: sha256,
            loop: manifest.loop ?? true
        )
    }

    func installMotion(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> StageMotionAsset {
        try ensureRootExists(fileManager: fileManager)
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard
            sourceValues.isRegularFile == true,
            sourceValues.isSymbolicLink != true
        else {
            throw MotionPackageError.unsupportedFormat
        }
        let format: StageMotionFormat
        switch sourceURL.pathExtension.lowercased() {
        case "vrma":
            try validateVRMA(at: sourceURL)
            format = .vrma
        case "vmd":
            try validateVMD(at: sourceURL)
            format = .vmd
        default:
            throw MotionPackageError.unsupportedFormat
        }

        let id = "motion.\(UUID().uuidString.lowercased())"
        let destination = rootURL.appending(path: id, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MotionPackageError.alreadyInstalled
        }
        let staging = rootURL
            .appending(path: ".staging", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let filename = sourceURL.lastPathComponent
        try fileManager.copyItem(at: sourceURL, to: staging.appending(path: filename))
        let manifest = MotionManifest(
            id: id,
            name: sourceURL.deletingPathExtension().lastPathComponent,
            format: format,
            entry: filename
        )
        try JSONEncoder().encode(manifest).write(
            to: staging.appending(path: "manifest.json"),
            options: .atomic
        )
        try fileManager.moveItem(at: staging, to: destination)
        return StageMotionAsset(
            id: id,
            name: manifest.name,
            format: format,
            url: destination.appending(path: filename).standardizedFileURL
        )
    }

    func installPublishedMotion(
        id: String,
        name: String,
        version: String,
        format: StageMotionFormat,
        sourceURL: URL,
        expectedSHA256: String,
        loop: Bool = true,
        strideSpeed: Float? = nil,
        playbackRate: Float = 1,
        inPlace: Bool? = nil,
        fileManager: FileManager = .default
    ) throws -> StageMotionAsset {
        guard
            id.range(
                of: #"^[a-z0-9][a-z0-9._-]{2,127}$"#,
                options: .regularExpression
            ) != nil,
            version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            ) != nil,
            expectedSHA256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil,
            !name.isEmpty,
            strideSpeed.map({ $0.isFinite && $0 > 0 }) ?? true,
            playbackRate.isFinite && playbackRate > 0 && playbackRate <= 8
        else {
            throw MotionPackageError.invalidPublishedMotionID
        }
        let expectedExtension: String
        switch format {
        case .vrma:
            expectedExtension = "vrma"
            try validateVRMA(at: sourceURL)
        case .vmd:
            expectedExtension = "vmd"
            try validateVMD(at: sourceURL)
        case .procedural:
            throw MotionPackageError.unsupportedFormat
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            sourceURL.pathExtension.lowercased() == expectedExtension
        else {
            throw MotionPackageError.unsupportedFormat
        }
        guard try sha256(at: sourceURL) == expectedSHA256 else {
            throw MotionPackageError.hashMismatch
        }

        try ensureRootExists(fileManager: fileManager)
        let destination = rootURL.appending(path: id, directoryHint: .isDirectory)
        let filename = "\(id).\(expectedExtension)"
        let manifest = MotionManifest(
            id: id,
            name: name,
            format: format,
            entry: filename,
            version: version,
            sha256: expectedSHA256,
            loop: loop,
            strideSpeed: strideSpeed,
            playbackRate: playbackRate,
            inPlace: inPlace
        )
        if fileManager.fileExists(atPath: destination.path),
           let existing = try? JSONDecoder().decode(
               MotionManifest.self,
               from: Data(contentsOf: destination.appending(path: "manifest.json"))
           ),
           existing.id == id,
           existing.version == version,
           existing.sha256 == expectedSHA256,
           (existing.loop ?? true) == loop,
           existing.strideSpeed == strideSpeed,
           (existing.playbackRate ?? 1) == playbackRate,
           existing.inPlace == inPlace,
           let asset = try? decodeAndValidateMotion(
               at: destination,
               fileManager: fileManager
           ) {
            return asset
        }

        let transactionID = UUID().uuidString
        let staging = rootURL
            .appending(path: ".staging", directoryHint: .isDirectory)
            .appending(path: transactionID, directoryHint: .isDirectory)
        let backup = rootURL
            .appending(path: ".staging", directoryHint: .isDirectory)
            .appending(path: "\(transactionID)-backup", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }
        try fileManager.copyItem(
            at: sourceURL,
            to: staging.appending(path: filename)
        )
        try JSONEncoder().encode(manifest).write(
            to: staging.appending(path: "manifest.json"),
            options: .atomic
        )
        let hadExisting = fileManager.fileExists(atPath: destination.path)
        if hadExisting {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
            if hadExisting {
                try fileManager.removeItem(at: backup)
            }
        } catch {
            if hadExisting,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        return try decodeAndValidateMotion(at: destination, fileManager: fileManager)
    }

    func activate(
        id: String,
        fileManager: FileManager = .default
    ) throws {
        try ensureRootExists(fileManager: fileManager)
        guard try listMotions(fileManager: fileManager).contains(where: { $0.id == id }) else {
            throw MotionPackageError.motionNotFound
        }
        try JSONEncoder().encode(
            MotionSelection(
                activeID: id,
                version: Self.selectionVersion
            )
        ).write(
            to: selectionURL,
            options: .atomic
        )
    }

    func remove(
        id: String,
        fileManager: FileManager = .default
    ) throws {
        guard !builtInIDs.contains(id) else {
            throw MotionPackageError.cannotRemoveBuiltIn
        }
        let destination = rootURL.appending(path: id, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw MotionPackageError.motionNotFound
        }
        try fileManager.removeItem(at: destination)
        if try readActiveID(fileManager: fileManager) == id {
            try activate(id: Self.naturalIdleID, fileManager: fileManager)
        }
    }

    private var naturalIdle: StageMotionAsset {
        StageMotionAsset(
            id: Self.naturalIdleID,
            name: "自然待机",
            format: .procedural,
            url: nil
        )
    }

    private var builtInIDs: Set<String> {
        Set([Self.naturalIdleID] + builtInMotions.map(\.id))
    }

    private var selectionURL: URL {
        rootURL.appending(path: ".selection.json")
    }

    private func ensureRootExists(fileManager: FileManager) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func readActiveID(fileManager: FileManager) throws -> String {
        try ensureRootExists(fileManager: fileManager)
        guard fileManager.fileExists(atPath: selectionURL.path) else {
            return Self.naturalIdleID
        }
        let selection = try? JSONDecoder().decode(
            MotionSelection.self,
            from: Data(contentsOf: selectionURL)
        )
        let selected = selection?.activeID ?? Self.naturalIdleID
        let requiresLegacyDefaultMigration = Self.retiredBuiltInMotionIDs
            .contains(selected)
        if requiresLegacyDefaultMigration {
            try JSONEncoder().encode(
                MotionSelection(
                    activeID: Self.naturalIdleID,
                    version: Self.selectionVersion
                )
            ).write(to: selectionURL, options: .atomic)
            return Self.naturalIdleID
        }
        return selected
    }

    private func decodeAndValidateMotion(
        at packageURL: URL,
        fileManager: FileManager
    ) throws -> StageMotionAsset {
        let manifestURL = packageURL.appending(path: "manifest.json")
        let manifest = try JSONDecoder().decode(
            MotionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.id == packageURL.lastPathComponent else {
            throw MotionPackageError.motionNotFound
        }
        let assetURL = packageURL.appending(path: manifest.entry).standardizedFileURL
        let rootPrefix = packageURL.standardizedFileURL.path + "/"
        let entryComponents = manifest.entry
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
        let isSymbolicLink = try? assetURL
            .resourceValues(forKeys: [.isSymbolicLinkKey])
            .isSymbolicLink
        guard
            !manifest.entry.hasPrefix("/"),
            !entryComponents.contains(".."),
            assetURL.path.hasPrefix(rootPrefix),
            fileManager.fileExists(atPath: assetURL.path),
            isSymbolicLink != true
        else {
            throw MotionPackageError.motionNotFound
        }
        switch manifest.format {
        case .vrma:
            try validateVRMA(at: assetURL)
        case .vmd:
            try validateVMD(at: assetURL)
        case .procedural:
            throw MotionPackageError.unsupportedFormat
        }
        return StageMotionAsset(
            id: manifest.id,
            name: manifest.name,
            format: manifest.format,
            url: assetURL,
            version: manifest.version,
            sha256: manifest.sha256,
            loop: manifest.loop ?? true,
            strideSpeed: manifest.strideSpeed,
            playbackRate: manifest.playbackRate ?? 1,
            inPlace: manifest.inPlace
        )
    }

    private func validateVRMA(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard
            data.count >= 20,
            data.prefix(4) == Data("glTF".utf8),
            littleEndianUInt32(in: data, at: 4) == 2,
            littleEndianUInt32(in: data, at: 8) == data.count,
            littleEndianUInt32(in: data, at: 16) == 0x4E4F534A
        else {
            throw MotionPackageError.invalidVRMA
        }
        let jsonLength = Int(littleEndianUInt32(in: data, at: 12))
        guard
            jsonLength >= 2,
            20 + jsonLength <= data.count,
            let object = try? JSONSerialization.jsonObject(
                with: data.subdata(in: 20 ..< 20 + jsonLength)
            ) as? [String: Any],
            let extensions = object["extensions"] as? [String: Any],
            extensions["VRMC_vrm_animation"] != nil
        else {
            throw MotionPackageError.invalidVRMA
        }
    }

    private func validateVMD(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 30 else {
            throw MotionPackageError.invalidVMD
        }
        let header = data.prefix(30)
        if header.starts(with: Data("Vocaloid Motion Data 0002".utf8)) {
            guard data.count >= 54 else { throw MotionPackageError.invalidVMD }
        } else if header.starts(with: Data("Vocaloid Motion Data file".utf8)) {
            guard data.count >= 44 else { throw MotionPackageError.invalidVMD }
        } else {
            throw MotionPackageError.invalidVMD
        }
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func bundledMMDMotions(
        bundle: Bundle = .main
    ) -> [BuiltInMotionResource] {
        let music = [(iluvSlapBassID, StageMotionFormat.vmd), (iluvSlapBassVRMID, .vrma)].compactMap { id, format -> BuiltInMotionResource? in
            guard let url = bundle.url(forResource: "iluvslapbass_motion",
                withExtension: format.rawValue, subdirectory: "MMDMotions") else { return nil }
            return BuiltInMotionResource(id: id, name: "I Love Slap Bass", format: format, url: url)
        }
        let buttons = [("gmgn.motion.device.jukebox-low-button-pmx", StageMotionFormat.vmd),
                       ("gmgn.motion.device.jukebox-low-button-vrm", .vrma)].compactMap { id, format -> BuiltInMotionResource? in
            guard let url = bundle.url(forResource: id, withExtension: format.rawValue, subdirectory: "MMDMotions"),
                  let manifestURL = bundle.url(forResource: id, withExtension: "json", subdirectory: "MMDMotions"),
                  let manifest = try? JSONDecoder().decode(MotionManifest.self, from: Data(contentsOf: manifestURL)),
                  manifest.id == id, manifest.format == format, manifest.entry == url.lastPathComponent,
                  manifest.loop == false, let data = try? Data(contentsOf: url),
                  manifest.sha256 == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
            else { return nil }
            return BuiltInMotionResource(id: id, name: manifest.name, format: format, url: url, loop: false)
        }
        return music + buttons
    }
}

private struct MotionManifest: Codable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let entry: String
    let version: String?
    let sha256: String?
    let loop: Bool?
    let strideSpeed: Float?
    let playbackRate: Float?
    let inPlace: Bool?

    init(
        id: String,
        name: String,
        format: StageMotionFormat,
        entry: String,
        version: String? = nil,
        sha256: String? = nil,
        loop: Bool? = nil,
        strideSpeed: Float? = nil,
        playbackRate: Float? = nil,
        inPlace: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.entry = entry
        self.version = version
        self.sha256 = sha256
        self.loop = loop
        self.strideSpeed = strideSpeed
        self.playbackRate = playbackRate
        self.inPlace = inPlace
    }
}

private struct MotionSelection: Codable {
    let activeID: String
    let version: Int?
}
