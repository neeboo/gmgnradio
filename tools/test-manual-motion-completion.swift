// Execute production Host receipt guards and bridge completion state transition.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
let bridge = try read("apps/macos/UnityHost/UnityPresenceSettingsBridge.swift")
let start = bridge.range(of: "    func completeSelectedMotion(")!.lowerBound
let end = bridge.range(of: "    func canSelectMotion(", range: start..<bridge.endIndex)!.lowerBound
let complete = String(bridge[start..<end])
let host = try read("apps/macos/UnityHost/UnityMediaHost.swift")
let receiptStart = host.range(of: "            case \"presence.motion.completed\":")!.upperBound
let receiptEnd = host.range(of: "            case \"presence.runtime.result\":", range: receiptStart..<host.endIndex)!.lowerBound
let route = String(host[receiptStart..<receiptEnd])
let harness = #"""
import Foundation
struct Motion { let id: String; let loop: Bool; let url: URL? }
enum MotionPackageStore { static let naturalIdleID = "idle" }
final class Runtime {
 struct Snapshot { var revision: UInt64 = 5; var motion: Motion? }
 var snapshot = Snapshot(motion: Motion(id: "finite", loop: false, url: URL(fileURLWithPath: "/clip.vrma")))
 var finished = 0
 func finishOneShotMotion(at url: URL) { finished += 1 }
}
final class Model {
 var motions = [Motion(id: "idle", loop: true, url: nil)]
 var selected: String?
 func activateMotion(_ motion: Motion) { selected = motion.id }
}
final class Bridge {
 var operation: Int?; var pendingSelection: Int?
 let runtime = Runtime(); let model = Model(); var published = 0
 func publish() { published += 1 }
 \#(complete)
}
final class Host {
 var closed = false
 var characterSelectionRevision: UInt64 = 9
 var renderedCharacterSelectionRevision: UInt64 = 9
 var renderedCharacterAssetID = "Kipfel"
 var characterRuntimeRevision: UInt64 = 5
 let presenceSettings = Bridge()
 func handle(_ value: [String: Any]) -> Bool {
 \#(route)
 }
}
let host = Host()
let valid: [String: Any] = ["revision": UInt64(9), "characterID": "Kipfel", "motionID": "finite"]
var stale = valid; stale["revision"] = UInt64(8)
precondition(!host.handle(stale))
var other = valid; other["characterID"] = "2B"
precondition(!host.handle(other))
var replaced = valid; replaced["motionID"] = "other"
precondition(!host.handle(replaced))
host.presenceSettings.runtime.snapshot.motion = Motion(id: "finite", loop: true, url: URL(fileURLWithPath: "/clip.vrma"))
precondition(!host.handle(valid))
host.presenceSettings.runtime.snapshot.motion = Motion(id: "finite", loop: false, url: URL(fileURLWithPath: "/clip.vrma"))
host.presenceSettings.pendingSelection = 1
precondition(!host.handle(valid))
host.presenceSettings.pendingSelection = nil
host.renderedCharacterSelectionRevision = 8
precondition(!host.handle(valid))
host.renderedCharacterSelectionRevision = 9
precondition(host.handle(valid))
precondition(host.presenceSettings.runtime.finished == 1)
precondition(host.presenceSettings.model.selected == "idle" && host.presenceSettings.published == 1)
print("PASS production finite-motion receipt guards and idle preference/publication")
"""#
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("main.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [file.path]; try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
