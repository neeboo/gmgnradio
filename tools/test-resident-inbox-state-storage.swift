import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-inbox-build-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let model = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInbox.swift"), encoding: .utf8)
let types = scratch.appendingPathComponent("InboxTypes.swift")
try String(model[..<model.range(of: "/// Confirmed inbox projection.")!.lowerBound]).write(to: types, atomically: true, encoding: .utf8)
let binary = scratch.appendingPathComponent("checks")
let selected = CommandLine.arguments.contains("--unity") ? "tools/test-unity-inbox-bridge.swift" : "tools/privatefixtures/resident-inbox-storage-main.swift"
var paths = ["apps/macos/Sources/GMGNRadio/Presence/RustInboxClient.swift", "apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInboxStateStorage.swift", "apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift", "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift", "tools/privatefixtures/inbox-http-fixture.swift", selected]
if CommandLine.arguments.contains("--unity") { paths.append("apps/macos/UnityHost/UnityInboxBridge.swift") }
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", types.path] + paths.map { root.appendingPathComponent($0).path } + ["-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
if CommandLine.arguments.contains("--compile-only") { print("PASS: Swift 6 inbox fixture compilation (" + selected + ")"); exit(0) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
