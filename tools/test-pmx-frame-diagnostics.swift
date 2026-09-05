// Source-only diagnostic contract; does not initialize AppKit, SceneKit or GPU.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let spatial = try String(contentsOf: base.appendingPathComponent("VisualEngine/Metal/MarbleSpatialView.swift"), encoding: .utf8)
let pmx = try String(contentsOf: base.appendingPathComponent("MMD/PMXStageAvatarRenderer.swift"), encoding: .utf8)
let checks: [(Bool, String)] = [
    (spatial.contains("let shouldLogPMXFrame = lastLoggedPMXRenderProfile != renderProfile"), "diagnostics are gated by profile changes"),
    (spatial.contains("diagnosticProfile: shouldLogPMXFrame ? profileName : nil"), "only the changed-profile frame asks SceneKit for diagnostics"),
    (spatial.contains("PMX frame geometry profile="), "actual view, drawable, texture and framing geometry are recorded"),
    (spatial.contains("boundsWidth=") && spatial.contains("drawableWidth=") && spatial.contains("textureWidth=") && spatial.contains("targetX=") && spatial.contains("distance="), "diagnostic contains values needed to distinguish size and camera mismatch"),
    (pmx.contains("if let diagnosticProfile {"), "renderer transform log remains opt-in"),
    (pmx.contains("PMX frame transforms profile=") && pmx.contains("containerPresentationScale=") && pmx.contains("modelPresentationScale="), "model and presented transforms can be compared"),
    (pmx.contains("diagnosticProfile: String? = nil"), "existing encode callers stay compatible"),
]
var failed = 0
for (passed, description) in checks where !passed { failed += 1; print("FAIL: \(description)") }
print("\(failed == 0 ? "PASS" : "FAIL"): \(checks.count) PMX one-shot diagnostic checks, \(failed) failures")
guard failed == 0 else { exit(1) }

func block(_ signature: String, in source: String, last: Bool = false) -> String {
    let start = source.range(of: signature, options: last ? .backwards : [])!.lowerBound
    let opening = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced diagnostic block")
}
// Type-check the exact new statements against real AppKit/Metal/SceneKit APIs.
// Only surrounding renderer state is inert; no renderer or window is created.
let fixture = """
import MetalKit
import SceneKit
import os
import simd
struct Bounds { var minimum: SIMD3<Float>; var maximum: SIMD3<Float>; var center: SIMD3<Float> }
struct Renderer { var localBounds: Bounds?; var animatedRootOffset: SIMD3<Float> }
enum Profile { case liveCam, fullStage }
enum LiveCamPMXTrackingPolicy {
    static func cameraOffset(animatedRootOffset: SIMD3<Float>, bounds: Bounds?) -> SIMD3<Float> { animatedRootOffset }
}
@MainActor final class Fixture {
    static let log = Logger(subsystem: "test", category: "diagnostic-typecheck")
    func check(view: MTKView, drawable: CAMetalDrawable, pmxAvatarRenderer: Renderer,
               renderProfile: Profile, pmxCameraView: simd_float4x4,
               pmxProjection: simd_float4x4, pmxModelTransform: simd_float4x4,
               profileName: String, shouldLogPMXFrame: Bool, diagnosticProfile: String?,
               modelContainerNode: SCNNode, modelNode: SCNNode, cameraNode: SCNNode,
               localTime: TimeInterval) {
        \(block("if shouldLogPMXFrame {", in: spatial, last: true))
        \(block("if let diagnosticProfile {", in: pmx))
    }
}
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-pmx-diagnostic-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("Check.swift")
try fixture.write(to: source, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-typecheck", "-target", "arm64-apple-macos14.0", source.path]
try process.run(); process.waitUntilExit()
exit(process.terminationStatus)
