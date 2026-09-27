#!/usr/bin/env swift
// Offline, explicit-destination installer. Compiles the real package store;
// never initializes the host, changes selection, or replaces existing packages.
import Foundation

enum InstallerFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw InstallerFailure.invalid("BONES installer subprocess failed (\(process.terminationStatus))")
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 4 || arguments.count == 6,
          arguments[0] == "--catalog", arguments[2] == "--destination",
          arguments[1].hasPrefix("/"), arguments[3].hasPrefix("/"),
          arguments.count == 4 || (arguments[4] == "--manifest" && arguments[5].hasPrefix("/")),
          URL(fileURLWithPath: arguments[3]).lastPathComponent == "MotionPackages" else {
        throw InstallerFailure.invalid("Usage: swift tools/install-bones-resident.swift --catalog /abs/catalog.json --destination /abs/MotionPackages [--manifest /abs/bones-arpg.json]")
    }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = repository.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence")
    let runtime = try String(contentsOf: source.appendingPathComponent("StageAvatarRuntime.swift"), encoding: .utf8)
    guard let boundary = runtime.range(of: "enum StageAvatarRuntimeStatus") else {
        throw InstallerFailure.invalid("StageAvatarRuntime type extraction boundary changed")
    }
    let types = String(runtime[..<boundary.lowerBound])
        .replacingOccurrences(of: "import Observation\n", with: "")
        .replacingOccurrences(of: "import WorldRuntime\n", with: "")
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-bones-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    let typesURL = staging.appendingPathComponent("Types.swift")
    try (types + "\nenum ProductIdentity { static let displayName = \"gmgn radio\" }\n").write(to: typesURL, atomically: true, encoding: .utf8)
    let mainURL = staging.appendingPathComponent("main.swift")
    let harness = #"""
    import CryptoKit
    import Foundation

    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }
    struct Catalog: Decodable {
        let schemaVersion: Int
        let motions: [Entry]
    }
    struct ARPGManifest: Decodable {
        struct Motion: Decodable { let key: String }
        let schemaVersion: Int
        let motions: [Motion]
    }
    struct Entry: Decodable {
        struct Source: Decodable {
            struct Generator: Decodable { let engine: String; let sourceSHA256: String }
            let generator: Generator
        }
        let id: String
        let name: String
        let version: String
        let format: StageMotionFormat
        let path: String
        let sha256: String
        let bytes: Int
        let loop: Bool
        let source: Source
        let inPlace: Bool?
        let strideSpeed: Float?
        let playbackRate: Float?
    }
    func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    func validARPGPlayback(in package: URL, required: Bool) throws -> Bool {
        guard required else { return true }
        struct Settings: Decodable {
            let inPlace: Bool?
            let playbackRate: Float?
        }
        let settings = try JSONDecoder().decode(Settings.self,
            from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
        return settings.inPlace == false && (settings.playbackRate ?? 1) == 1
    }
    do {
        let args = CommandLine.arguments
        let catalogURL = URL(fileURLWithPath: args[2]).standardizedFileURL
        let destination = URL(fileURLWithPath: args[4]).standardizedFileURL
        let fm = FileManager.default
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
        let isARPG = args.count == 7
        let allowed: Set<String>
        if isARPG {
            let manifest = try JSONDecoder().decode(ARPGManifest.self,
                from: Data(contentsOf: URL(fileURLWithPath: args[6])))
            let keys = manifest.motions.map(\.key)
            guard manifest.schemaVersion == 1, !keys.isEmpty, Set(keys).count == keys.count,
                  keys.allSatisfy({ $0.utf8.count <= 102 &&
                      $0.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil }) else {
                throw Refusal("Invalid BONES ARPG manifest: expected schema 1 and unique, nonempty safe motion keys")
            }
            allowed = Set(keys.flatMap { key in ["pmx", "vrm"].map { "gmgn.motion.bones.arpg.\(key)-\($0)" } })
            guard catalog.schemaVersion == 1, catalog.motions.count == allowed.count,
                  Set(catalog.motions.map(\.id)) == allowed else {
                throw Refusal("BONES catalog must contain exactly the manifest ARPG motion IDs, paired as pmx and vrm")
            }
        } else {
            let roles = ["thinking-loop", "idle-loop", "hold-display", "jumping-jacks"]
            allowed = Set(roles.flatMap { role in ["pmx", "vrm"].map { "gmgn.motion.bones.\(role)-\($0)" } })
            guard catalog.schemaVersion == 1, catalog.motions.count == 8,
                  Set(catalog.motions.map(\.id)) == allowed else {
                throw Refusal("BONES catalog must contain exactly the eight permitted resident motion IDs")
            }
        }
        // Validate all provenance before touching any destination or source file.
        for entry in catalog.motions {
            guard entry.source.generator.engine == "bones-seed",
                  entry.source.generator.sourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw Refusal("Non-BONES or missing source digest: \(entry.id)")
            }
            if isARPG {
                guard !entry.loop, entry.inPlace == false, (entry.playbackRate ?? 1) == 1 else {
                    throw Refusal("Invalid BONES ARPG playback settings: \(entry.id)")
                }
            }
        }
        let store = MotionPackageStore(rootURL: destination, builtInMotions: [])
        let catalogRoot = catalogURL.deletingLastPathComponent().resolvingSymlinksInPath()
        var sources: [String: URL] = [:]
        var existingIDs = Set<String>()
        for entry in catalog.motions {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !components.contains(".."), !components.contains("."), !components.contains(""),
                  entry.format == (entry.id.hasSuffix("-pmx") ? .vmd : .vrma), entry.loop == !isARPG else {
                throw Refusal("Invalid BONES source path, format, or loop: \(entry.id)")
            }
            let url = catalogRoot.appendingPathComponent(entry.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path.hasPrefix(catalogRoot.path + "/"),
                  try Data(contentsOf: url).count == entry.bytes, try digest(url) == entry.sha256 else {
                throw Refusal("BONES source bytes/hash mismatch: \(entry.id)")
            }
            sources[entry.id] = url
            let package = destination.appendingPathComponent(entry.id)
            if fm.fileExists(atPath: package.path) {
                guard try package.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      let installed = try store.installedPublishedMotion(id: entry.id),
                      installed.sha256 == entry.sha256, installed.version == entry.version, installed.loop == entry.loop,
                      try validARPGPlayback(in: package, required: isARPG),
                      try digest(package.appendingPathComponent("\(entry.id).\(entry.format.rawValue)")) == entry.sha256 else {
                    throw Refusal("Existing package differs; refusing replacement: \(entry.id)")
                }
                existingIDs.insert(entry.id)
            }
        }
        let selectionURL = destination.appendingPathComponent(".selection.json")
        let selectionBefore = fm.fileExists(atPath: selectionURL.path) ? try Data(contentsOf: selectionURL) : nil
        for entry in catalog.motions {
            if !existingIDs.contains(entry.id) {
                _ = try store.installPublishedMotion(id: entry.id, name: entry.name, version: entry.version,
                    format: entry.format, sourceURL: sources[entry.id]!, expectedSHA256: entry.sha256,
                    loop: entry.loop, strideSpeed: entry.strideSpeed, playbackRate: entry.playbackRate ?? 1,
                    inPlace: entry.inPlace)
            }
            guard let installed = try store.installedPublishedMotion(id: entry.id),
                  installed.sha256 == entry.sha256, installed.version == entry.version, installed.loop == entry.loop,
                  try validARPGPlayback(in: destination.appendingPathComponent(entry.id), required: isARPG),
                  try digest(destination.appendingPathComponent(entry.id).appendingPathComponent("\(entry.id).\(entry.format.rawValue)")) == entry.sha256 else {
                throw Refusal("Installed BONES readback failed: \(entry.id)")
            }
        }
        let selectionAfter = fm.fileExists(atPath: selectionURL.path) ? try Data(contentsOf: selectionURL) : nil
        guard selectionBefore == selectionAfter else { throw Refusal("Selection unexpectedly changed") }
        print("BONES verified: \(allowed.count); installed: \(allowed.count - existingIDs.count); already present: \(existingIDs.count); selection unchanged")
    } catch {
        FileHandle.standardError.write(Data("BONES installation refused: \(error)\n".utf8))
        exit(1)
    }
    """#
    try harness.write(to: mainURL, atomically: true, encoding: .utf8)
    let executable = staging.appendingPathComponent("install-bones")
    try run("/usr/bin/xcrun", ["swiftc", typesURL.path, source.appendingPathComponent("MotionPackageStore.swift").path, mainURL.path, "-o", executable.path])
    try run(executable.path, arguments)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
