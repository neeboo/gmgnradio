import Foundation

// Extract the exact production entrance so this bounded regression does not
// launch the full app or SwiftPM test runner. WorldRuntime must be built first.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropPlacementService.swift"), encoding: .utf8)
let signature = "private static func supportLayer(at position: WorldVector3, footprint: WorldPlanarFootprint,"
guard let begin = source.range(of: signature)?.lowerBound,
      let open = source[begin...].firstIndex(of: "{") else { fatalError("Production support-layer entrance missing") }
var depth = 0, end: String.Index?
for index in source[open...].indices {
    if source[index] == "{" { depth += 1 }
    if source[index] == "}" { depth -= 1 }
    if depth == 0 { end = index; break }
}
guard let end else { fatalError("Production function not balanced") }
let function = String(source[begin...end]).replacingOccurrences(of: "private static func", with: "static func")
let program = """
import Foundation
import WorldRuntime
enum LayerEntrance { \(function) }
struct MeasuredFloor: WorldPropSupportQuerying {
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
    func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>, to end: SIMD3<Float>, maximumStepHeight: Float) -> Bool { true }
    func groundHeight(at position: SIMD3<Float>) -> Float? {
        let height: Float = position.x == 0 && position.z == 0 ? -0.015 : 0
        return height <= position.y + 0.05 ? height : nil
    }
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        [WorldTriangle(SIMD3<Float>(0,-0.015,0),SIMD3<Float>(2,0,0),SIMD3<Float>(0,0,2))]
    }
}
@main struct Checks {
    static func main() {
        let grid = PropSupportGridBuilder.build(collision: MeasuredFloor(),
            bounds: WorldPlanarBounds(minimumX: 0, maximumX: 1.75, minimumZ: 0, maximumZ: 1.75),
            seed: WorldVector3(x: 0.5,y: 0,z: 0.5))
        let footprint = WorldPlanarFootprint(size: SIMD2<Float>(0.4,0.4))
        func require(_ value: Bool,_ label: String) { if !value { print("FAIL: " + label); exit(1) } }
        require(grid.layers(at: PropSupportColumn(x: 0,z: 0)).first?.supportHeight == -0.015, "low corner must be present")
        let resolved = LayerEntrance.supportLayer(at: WorldVector3(x: 0.125,y: 0,z: 0.125), footprint: footprint,grid: grid)
        require(resolved?.supportHeight == 0, "highest measured plane must match submitted placement despite corner being 15mm lower")
        require(LayerEntrance.supportLayer(at: WorldVector3(x: 0.125,y: -0.015,z: 0.125),footprint: footprint,grid: grid) == nil, "a corner-height placement that penetrates the higher floor must reject")
        require(LayerEntrance.supportLayer(at: WorldVector3(x: 0.125,y: 0.025,z: 0.125),footprint: footprint,grid: grid) == nil, "floating placement must reject")
        require(LayerEntrance.supportLayer(at: WorldVector3(x: 20,y: 0,z: 20),footprint: footprint,grid: grid) == nil, "missing floor must reject")
        print("PASS production floor support-layer entrance: lower corner accepted at highest measured plane; penetration, floating and absent floor reject")
    }
}
"""
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-floor-layer-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let programURL = temporary.appendingPathComponent("Checks.swift"), executable = temporary.appendingPathComponent("checks")
try program.write(to: programURL, atomically: true, encoding: .utf8)
let flags = Process(), pipe = Pipe()
flags.executableURL = URL(fileURLWithPath: "/bin/sh")
flags.arguments = [root.appendingPathComponent("tools/world-runtime-harness-flags.sh").path]
flags.standardOutput = pipe
try flags.run(); flags.waitUntilExit()
guard flags.terminationStatus == 0 else { exit(flags.terminationStatus) }
let arguments = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1","-parse-as-library",programURL.path,"-o",executable.path] + arguments
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let check = Process(); check.executableURL = executable
try check.run(); check.waitUntilExit(); exit(check.terminationStatus)
