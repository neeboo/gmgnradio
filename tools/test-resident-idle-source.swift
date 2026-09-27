// Pure animation-group policy check; no model loading, renderer or app host.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let text = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift"), encoding: .utf8)
let start = text.range(of: "public static func naturalIdleMotion(")!.lowerBound
let open = text[start...].firstIndex(of: "{")!
var depth = 0
var end = open
for index in text[open...].indices {
    if text[index] == "{" { depth += 1 }
    if text[index] == "}" { depth -= 1 }
    if depth == 0 { end = text.index(after: index); break }
}
let implementation = String(text[start..<end]).replacingOccurrences(of: "public static", with: "static")
let harness = #"""
import Foundation
import QuartzCore
import SceneKit
struct MMDNode {}
enum PMXMaterialCompatibility { static func isRaw2BModel(_ model: MMDNode) -> Bool { false } }
enum Renderer {
    static let naturalIdleDuration: TimeInterval = 4.8
    static func firstBone(in model: MMDNode, named names: [String]) -> SCNNode? { SCNNode() }
    static func naturalIdleTrack(for bone: SCNNode, relaxationAngle: Float, breathingAngle: Float, axis: SIMD3<Float>) -> CAKeyframeAnimation { CAKeyframeAnimation(keyPath: "generated") }
    static func raw2BNaturalIdleMotion(for model: MMDNode) -> CAAnimationGroup { CAAnimationGroup() }
    \#(implementation)
}
let idle = Renderer.naturalIdleMotion(for: MMDNode())
guard idle.animations?.isEmpty != false else {
    print("FAIL: missing BONES idle still generates authored body-motion tracks")
    exit(1)
}
print("PASS: missing BONES idle leaves a static rest pose, never generated motion")
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-idle-source-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: dir) }
let source = dir.appendingPathComponent("main.swift"), binary = dir.appendingPathComponent("test")
try harness.write(to: source, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = [source.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
