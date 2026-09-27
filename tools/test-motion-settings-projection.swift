// Exercise production model projections without AppKit, disk preferences or a host.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelPath = "apps/macos/Sources/GMGNRadio/Settings/PresenceSettingsModel.swift"
let source = try String(contentsOf: root.appendingPathComponent(modelPath), encoding: .utf8)
func declaration(_ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else { fatalError("missing \(signature)") }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unbalanced \(signature)")
}
let harness = #"""
import Foundation
enum PresenceEngine { case vrm, pmx, live2D, orb }
enum StageMotionFormat { case vrma, vmd, procedural }
struct PresencePackage {
    struct Manifest { let engine: PresenceEngine }
    let manifest: Manifest
    let isActive: Bool
}
struct StageMotionAsset { let id: String; let format: StageMotionFormat }
struct PublishedMotion { let id: String; let format: String }
final class Runtime {
    struct Avatar { let id: String }
    struct Snapshot { var avatar: Avatar? }
    var snapshot = Snapshot(avatar: nil)
}
\#(declaration("extension MotionFormatFilter.Engine"))
\#(declaration("extension MotionFormatFilter.Format"))
\#(declaration("extension StageMotionAsset:"))
final class Model {
    \#(declaration("enum MotionCompatibility:"))
    var packages: [PresencePackage] = []
    var motions: [StageMotionAsset] = []
    var publishedMotions: [PublishedMotion] = []
    var activeMotionID: String?
    let avatarRuntime = Runtime()
    \#(declaration("var activeAvatarID:"))
    \#(declaration("var activeAvatarEngine:"))
    \#(declaration("static func motionCompatibility("))
    \#(declaration("var availableMotions:"))
    \#(declaration("var availablePublishedMotions:"))
    \#(declaration("func motions(in category:"))
}
@main struct Check {
    static func main() {
        let m = Model()
        precondition(m.activeAvatarID == nil)
        m.avatarRuntime.snapshot.avatar = .init(id: "external-vrm")
        precondition(m.activeAvatarID == "external-vrm", "observe the shared runtime rather than a stale local package row")
        m.avatarRuntime.snapshot.avatar = nil
        precondition(m.activeAvatarID == nil, "clearing the avatar must also trigger the settings refresh")
        let pmx = StageMotionAsset(id: "gmgn.motion.bones.thinking-loop-pmx", format: .vmd)
        let vrm = StageMotionAsset(id: "gmgn.motion.bones.thinking-loop-vrm", format: .vrma)
        let custom = StageMotionAsset(id: "custom.any-name.vrma", format: .vmd)
        let idle = StageMotionAsset(id: "builtin.idle", format: .procedural)
        m.motions = [pmx, vrm, custom, idle]
        m.publishedMotions = [.init(id: "misnamed-vrm", format: "vmd"),
            .init(id: "misnamed-pmx", format: "vrma"), .init(id: "unknown", format: "fbx")]
        precondition(m.availableMotions.isEmpty && m.availablePublishedMotions.isEmpty)
        m.packages = [.init(manifest: .init(engine: .pmx), isActive: true)]
        precondition(m.availableMotions.map(\.id) == [pmx.id, custom.id, idle.id])
        precondition(m.motions(in: .work).map(\.id) == [pmx.id])
        precondition(m.motions(in: .life).isEmpty)
        precondition(m.availablePublishedMotions.map(\.id) == ["misnamed-vrm"])
        m.activeMotionID = pmx.id
        m.packages = [.init(manifest: .init(engine: .vrm), isActive: true)]
        precondition(m.availableMotions.map(\.id) == [vrm.id, idle.id])
        precondition(m.motions(in: .work).map(\.id) == [vrm.id])
        precondition(m.availablePublishedMotions.map(\.id) == ["misnamed-pmx"])
        precondition(!m.availableMotions.contains { $0.id == m.activeMotionID })
        precondition(m.motions.count == 4 && m.publishedMotions.count == 3,
                     "projection must not delete installed or catalog entries")
        // Hiding the alternate format must not revoke an existing playback adapter.
        precondition(Model.motionCompatibility(avatarEngine: .vrm, motionFormat: .vmd) == .compatible,
                     "browsing filter must preserve existing VRM VMD playback compatibility")
        precondition(Model.motionCompatibility(avatarEngine: .pmx, motionFormat: .vrma) != .compatible)
        print("PASS: actual model projections, category-format intersection, remote metadata, switching, non-mutation and legacy playback")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-model-projection-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Check.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("check")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/MotionLibraryCategory.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/MotionFormatFilter.swift").path,
    program.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
