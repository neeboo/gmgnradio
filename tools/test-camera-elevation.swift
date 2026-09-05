// Run from the repository root: swift tools/test-camera-elevation.swift
// Exercises unchanged production camera declarations without an app, GPU, or UI.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let storeSource = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift"), encoding: .utf8)
let mappingSource = try String(contentsOf: root.appendingPathComponent("apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldCameraInputMapping.swift"), encoding: .utf8)
let windowSource = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"), encoding: .utf8)

guard storeSource.contains("mutating func dolly(scrollDelta:"),
      storeSource.contains("func dollyCamera(scrollDelta:") else {
    print("FAIL: spatial camera has no wheel dolly implementation")
    exit(1)
}

func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        fatalError("Missing production declaration: \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced declaration: \(signature)")
}

let harness = #"""
import Foundation
\#(mappingSource)
\#(declaration("enum SpatialMovement:", in: storeSource))
\#(declaration("struct SpatialCameraState:", in: storeSource))
final class Store {
    var camera = SpatialCameraState(position: SIMD3<Float>(2, 3, 4), pitch: -0.6)
    var activeMovement: Set<SpatialMovement> = []
    \#(declaration("func setMovement(", in: storeSource))
    \#(declaration("func clearMovement()", in: storeSource))
    \#(declaration("func stepCamera(", in: storeSource))
    \#(declaration("func dollyCamera(", in: storeSource))
}
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.00001 }
let origin = SIMD3<Float>(2, 3, 4)
for pitch: Float in [-1.2, -0.6, 0, 0.6, 1.2] {
    for yaw: Float in [-1.4, 0, 1.4] {
        var forward = SpatialCameraState(position: origin, yaw: yaw, pitch: pitch)
        forward.move(.forward, distance: 2.5)
        let delta = forward.position - origin
        check(near(delta.y, sin(pitch) * 2.5), "W elevation follows pitch \(pitch), yaw \(yaw)")
        check(near(delta.x, -sin(yaw) * cos(pitch) * 2.5), "W x follows yaw and pitch")
        check(near(delta.z, -cos(yaw) * cos(pitch) * 2.5), "W z follows yaw and pitch")
        check(near(sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z), 2.5), "W speed independent of pitch")
        forward.move(.backward, distance: 2.5)
        check(near(forward.position.x, origin.x) && near(forward.position.y, origin.y) && near(forward.position.z, origin.z), "S reverses W")
        for direction in [SpatialMovement.left, .right] {
            var lateral = SpatialCameraState(position: origin, yaw: yaw, pitch: pitch)
            lateral.move(direction, distance: 2.5)
            let delta = lateral.position - origin
            check(delta.y == 0, "A/D preserve altitude")
            check(near(sqrt(delta.x * delta.x + delta.z * delta.z), 2.5), "A/D preserve speed")
        }
    }
}
let store = Store()
for pitch: Float in [-1.2, 0, 1.2] {
    for yaw: Float in [-1.4, 0, 1.4] {
        var wheel = SpatialCameraState(position: origin, yaw: yaw, pitch: pitch)
        var keyboard = wheel
        keyboard.move(.backward, distance: 0.2)
        wheel.dolly(scrollDelta: 1, precise: false)
        check(wheel == keyboard, "positive wheel pulls back including camera pitch")
        wheel.dolly(scrollDelta: -1, precise: false)
        check(near(wheel.position.x, origin.x) && near(wheel.position.y, origin.y) && near(wheel.position.z, origin.z), "negative wheel reverses dolly")
        check(wheel.pitch == pitch && wheel.yaw == yaw, "wheel preserves view orientation")
    }
}
var precise = SpatialCameraState(position: origin)
precise.dolly(scrollDelta: 20, precise: true)
var discrete = SpatialCameraState(position: origin)
discrete.dolly(scrollDelta: 1, precise: false)
check(precise == discrete, "trackpad points and discrete wheel normalize to useful speeds")
var small = SpatialCameraState(position: origin)
small.dolly(scrollDelta: 0.25, precise: true)
check(near(small.position.z, origin.z + 0.0025), "positive trackpad input pulls back smoothly")
small.dolly(scrollDelta: -0.5, precise: true)
check(near(small.position.z, origin.z - 0.0025), "negative trackpad input pushes forward")
for delta: Float in [-100_000, 100_000] {
    var capped = SpatialCameraState(position: origin)
    capped.dolly(scrollDelta: delta, precise: false)
    check(near(abs(capped.position.z - origin.z), 0.5), "wheel spike limited to half metre per event")
}
for delta: Float in [0, .nan, .infinity, -.infinity] {
    var unchanged = SpatialCameraState(position: origin)
    unchanged.dolly(scrollDelta: delta, precise: true)
    check(unchanged == SpatialCameraState(position: origin), "zero and invalid wheel inputs do not move camera")
}
store.dollyCamera(scrollDelta: 0.25, precise: true)
var expectedStore = SpatialCameraState(position: origin, pitch: -0.6)
expectedStore.dolly(scrollDelta: 0.25, precise: true)
check(store.camera == expectedStore, "store forwards wheel delta without command minimum-distance clamp")
store.camera = SpatialCameraState(position: origin, pitch: -0.6)
store.setMovement(.forward, active: true)
store.stepCamera(deltaTime: 0.1, speedBoosted: false)
check(store.camera.position.y < origin.y, "held W descends while looking down")
let afterMove = store.camera
store.setMovement(.forward, active: false)
store.stepCamera(deltaTime: 0.1, speedBoosted: false)
check(store.camera == afterMove, "key release stops movement")
store.setMovement(.backward, active: true)
store.clearMovement()
store.stepCamera(deltaTime: 0.1, speedBoosted: false)
check(store.camera == afterMove, "clearMovement stops movement")
if failures > 0 { print("\(failures) assertions failed"); exit(1) }
print("PASS: pitch-aware W/S and wheel dolly, device sensitivity, spike cap, horizontal A/D, key release")
"""#

let interactionView = declaration("private final class StageWorldInteractionView:", in: windowSource)
guard interactionView.contains("override func scrollWheel(with event: NSEvent)"),
      interactionView.contains("spatialStage.dollyCamera("),
      interactionView.contains("event.scrollingDeltaY"),
      interactionView.contains("event.hasPreciseScrollingDeltas") else {
    print("FAIL: space interaction overlay does not forward wheel events")
    exit(1)
}

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-camera-elevation-\(UUID())")
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let harnessURL = temporaryDirectory.appendingPathComponent("main.swift")
try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [harnessURL.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
