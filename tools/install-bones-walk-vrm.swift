#!/usr/bin/env swift
// One approved missing package only. Compiles the real store without the host.
import Foundation
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, arguments[0] == "--catalog", arguments[2] == "--destination",
      arguments[1].hasPrefix("/"), arguments[3].hasPrefix("/"),
      URL(fileURLWithPath: arguments[3]).lastPathComponent == "MotionPackages" else {
    print("Usage: swift tools/install-bones-walk-vrm.swift --catalog /absolute/catalog.json --destination /absolute/MotionPackages")
    exit(1)
}
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let presence = repository.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence")
let runtime = try String(contentsOf: presence.appendingPathComponent("StageAvatarRuntime.swift"), encoding: .utf8)
let types = String(runtime[..<runtime.range(of: "enum StageAvatarRuntimeStatus")!.lowerBound])
    .replacingOccurrences(of: "import Observation\n", with: "")
    .replacingOccurrences(of: "import WorldRuntime\n", with: "")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-walk-installer-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
try (types + "\nenum ProductIdentity { static let displayName = \"gmgn radio\" }\n")
    .write(to: directory.appendingPathComponent("Types.swift"), atomically: true, encoding: .utf8)
let harness = #"""
import Foundation
import CryptoKit
struct Refusal: Error { let message: String; init(_ message: String) { self.message = message } }
struct Catalog: Decodable { let schemaVersion: Int; let motions: [Entry] }
struct Entry: Decodable {
    struct Source: Decodable {
        struct Generator: Decodable { let engine: String; let sourceSHA256: String; let startFrame: Int; let endFrame: Int; let outputFPS: Int; let rootMotion: String }
        let generator: Generator
    }
    let id: String; let name: String; let version: String; let format: StageMotionFormat
    let path: String; let sha256: String; let bytes: Int; let loop: Bool
    let inPlace: Bool; let strideSpeed: Float; let playbackRate: Float; let source: Source
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
do {
    let fm = FileManager.default
    let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    guard catalog.schemaVersion == 1, catalog.motions.count == 1, let entry = catalog.motions.first,
          entry.id == "gmgn.motion.bones.walk-loop-vrm", entry.format == .vrma, entry.version == "1.0.0",
          entry.loop, entry.inPlace, entry.playbackRate == 1,
          abs(entry.strideSpeed - 1.40076154) < 0.000001,
          entry.source.generator.engine == "bones-seed",
          entry.source.generator.sourceSHA256 == "c6cbe36345c303f136aa0914a086de7a1af80f38a6eb67dc32afcfe71b7e2fc2",
          entry.source.generator.startFrame == 61, entry.source.generator.endFrame == 197,
          entry.source.generator.outputFPS == 120, entry.source.generator.rootMotion == "full" else {
        throw Refusal("catalog does not match the accepted continuous BONES VRM walk")
    }
    let package = destination.appendingPathComponent(entry.id)
    guard !fm.fileExists(atPath: package.path) else { throw Refusal("package already exists; replacement is forbidden") }
    let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
    let catalogRoot = catalogURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let source = catalogRoot.appendingPathComponent(entry.path)
    guard !entry.path.hasPrefix("/"), !components.contains(".."), !components.contains("."), !components.contains(""),
          source.resolvingSymlinksInPath().path.hasPrefix(catalogRoot.path + "/"),
          try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Refusal("unsafe source path") }
    let data = try Data(contentsOf: source)
    guard data.count == entry.bytes, digest(data) == entry.sha256 else { throw Refusal("source asset hash mismatch") }
    let selection = destination.appendingPathComponent(".selection.json")
    let before = fm.fileExists(atPath: selection.path) ? try Data(contentsOf: selection) : nil
    let store = MotionPackageStore(rootURL: destination, builtInMotions: [])
    _ = try store.installPublishedMotion(id: entry.id, name: entry.name, version: entry.version, format: entry.format,
        sourceURL: source, expectedSHA256: entry.sha256, loop: entry.loop,
        strideSpeed: entry.strideSpeed, playbackRate: entry.playbackRate, inPlace: entry.inPlace)
    guard let installed = try store.installedPublishedMotion(id: entry.id),
          let asset = try store.listMotions().first(where: { $0.id == entry.id }),
          installed.sha256 == entry.sha256, installed.loop, asset.inPlace == true,
          asset.strideSpeed == entry.strideSpeed, asset.playbackRate == 1,
          let url = asset.url, digest(try Data(contentsOf: url)) == entry.sha256 else { throw Refusal("installed readback mismatch") }
    let after = fm.fileExists(atPath: selection.path) ? try Data(contentsOf: selection) : nil
    guard before == after else { throw Refusal("selection unexpectedly changed") }
    print("Installed missing BONES VRM walk; selection unchanged; SHA256=\(entry.sha256); package=\(package.path)")
} catch {
    print("Installation refused: \(error)"); exit(1)
}
"""#
try harness.write(to: directory.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    try process.run(); process.waitUntilExit(); if process.terminationStatus != 0 { exit(process.terminationStatus) }
}
let executable = directory.appendingPathComponent("install")
try run("/usr/bin/xcrun", ["swiftc", directory.appendingPathComponent("Types.swift").path,
    presence.appendingPathComponent("MotionPackageStore.swift").path, directory.appendingPathComponent("main.swift").path, "-o", executable.path])
try run(executable.path, [arguments[1], arguments[3]])
