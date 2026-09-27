// Source-backed pure test. No AppKit, GPU, application or test host is started.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String {
    try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
}
let source = try read("DesktopPresence/PMXAvatarMetalView.swift")

func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{")
    else {
        fatalError("Missing production declaration: \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced production declaration: \(signature)")
}

let state = declaration("struct DesktopPMXCameraState:", in: source)
let framing = declaration("enum DesktopPMXFraming", in: source)
let bounds = declaration("public struct PMXAvatarBounds:", in: try read("MMD/PMXStageAvatarRenderer.swift"))
let cameraSource = try read("VisualEngine/StageCameraCoordinator.swift")
let orbit = declaration("struct LiveCamCameraFrame:", in: cameraSource) + "\n"
    + declaration("struct LiveCamCharacterOrbit:", in: cameraSource)
let spatial = try read("VisualEngine/Metal/MarbleSpatialView.swift")
let assignmentStart = spatial.range(of: "var localCamera = DesktopPMXCameraState.default")!.lowerBound
let assignmentEnd = spatial.range(of: "let framing = DesktopPMXFraming.matrices(", range: assignmentStart..<spatial.endIndex)!.lowerBound
let cameraAssignment = String(spatial[assignmentStart..<assignmentEnd])
let harness = """
import Foundation
import simd
\(state)
\(bounds)
\(framing)
\(orbit)

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \\(message)") }
}

// Bounds read from the real installed 2B's frame diagnostics. Check projected
// head/feet, not a zoom constant, using the production camera assignment.
let model = PMXAvatarBounds(minimum: .init(-8.051082, -0.00220418, -3.9398482),
                            maximum: .init(8.051082, 21.225172, 3.2858686))
let liveCamOrbit = LiveCamCharacterOrbit()
let placement = (yaw: Float(0), scale: Float(1))
\(cameraAssignment)
var referenceSpan: Float?
for renderScale: CGFloat in [1, 0.6, 0.45] {
    let matrices = DesktopPMXFraming.matrices(bounds: model,
        drawableSize: CGSize(width: 224 * 2 * renderScale, height: 336 * 2 * renderScale),
        camera: localCamera)
    func projectedY(_ y: Float) -> Float {
        let clip = matrices.projection * matrices.view * SIMD4<Float>(0, y, model.center.z, 1)
        return clip.y / clip.w
    }
    let head = projectedY(model.maximum.y), feet = projectedY(model.minimum.y)
    let span = (head - feet) / 2
    check(span > 0.70 && span < 0.95, "2B occupies a readable full-body portrait height")
    check(head < 1 && feet > -1, "head and feet remain inside the portrait")
    if let referenceSpan { check(abs(referenceSpan - span) < 0.0001, "quality cannot change character size") }
    referenceSpan = span
    print("height fraction=\\(span) head=\\(head) feet=\\(feet) quality=\\(renderScale)")
}

print("\\(failures == 0 ? \"PASS\" : \"FAIL\"): Live Cam PMX framing")
exit(failures == 0 ? 0 : 1)
"""

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-livecam-framing-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let testURL = directory.appendingPathComponent("main.swift")
try harness.write(to: testURL, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [testURL.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
