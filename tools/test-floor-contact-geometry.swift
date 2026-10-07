import Foundation

// Run the exact production geometry regression functions without SwiftPM's
// persistent testing helper. WorldRuntime must be built first.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let tests = try String(contentsOf: root.appendingPathComponent("apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/ContinuousFloorSupportTests.swift"), encoding: .utf8)
let productionChecks = tests.replacingOccurrences(of: "import Testing", with: "import Foundation")
    .replacingOccurrences(of: "@Test func", with: "func")
    .replacingOccurrences(of: "#expect(", with: "require(")
let program = productionChecks + """

func require(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    guard value else { print("FAIL floor contact geometry at line \\(line)"); exit(1) }
}
@main struct Checks {
    static func main() {
        continuousFloorBridgeHasStableContacts()
        continuousFloorRejectsUnsupportedCenterAndHole()
        abruptRecessBelowRestingPlaneIsNotAnObstacle()
        continuousFloorRejectsContactHullBoundaryAndWall()
        continuousFloorRequiresResolvedPlaneAtLowAnchor()
        print("PASS five production floor geometry regressions: deep recess, slot sides below plane, stable contacts, missing floor, wall and floating/penetrating anchor")
    }
}
"""
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-floor-contact-\(UUID())")
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
compiler.arguments = ["-j1", "-parse-as-library", programURL.path, "-o", executable.path] + arguments
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let check = Process(); check.executableURL = executable
try check.run(); check.waitUntilExit(); exit(check.terminationStatus)
