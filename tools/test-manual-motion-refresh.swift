// Execute the production refresh method against inert stores; no app restart.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift"), encoding: .utf8)
let start = source.range(of: "    func refresh(forcePlaybackReload:")!.lowerBound
let end = source.range(of: "    func finishOneShotMotion(", range: start..<source.endIndex)!.lowerBound
let refresh = String(source[start..<end])
let harness = #"""
import Foundation
enum StageMotionFormat { case procedural, vrma, vmd }
struct Avatar { let name = "Kipfel"; let format = "vrm" }
struct Motion: Equatable { let id: String; let format: StageMotionFormat }
struct Snapshot { var avatar: Avatar?; var motion: Motion? }
enum Status { case disabled, available(String), failed(String) }
struct PackageStore { func activeAvatar() throws -> Avatar? { Avatar() } }
final class MotionStore {
 var selected = Motion(id: "builtin.motion.iluvslapbass-vrm", format: .vrma)
 func listMotions() throws -> [Motion] { [selected] }
 func activeMotion() throws -> Motion { selected }
}
final class Runtime {
 let packageStore: PackageStore? = PackageStore()
 let motionPackageStore: MotionStore? = MotionStore()
 var snapshot = Snapshot(avatar: nil, motion: nil)
 var installedResidentMotions: [Motion] = []
 var status = Status.disabled
 func residentLoopMotion(_ name: String, avatarFormat: String?) -> Motion? { Motion(id: "gmgn.motion.bones.idle-loop-vrm", format: .vrma) }
 func setSnapshot(avatar: Avatar?, motion: Motion?, forcePlaybackReload: Bool) { snapshot = Snapshot(avatar: avatar, motion: motion) }
 \#(refresh)
}
let runtime = Runtime()
for (id, format) in [("builtin.motion.iluvslapbass-vrm", StageMotionFormat.vrma),
                     ("motion.user-imported", .vrma),
                     ("gmgn.motion.device.jukebox-low-button-vrm", .vrma),
                     ("builtin.motion.iluvslapbass", .vmd)] {
 runtime.motionPackageStore!.selected = Motion(id: id, format: format)
 runtime.refresh()
 precondition(runtime.snapshot.motion?.id == id, "Manual selection was overwritten by idle")
 runtime.refresh()
 precondition(runtime.snapshot.motion?.id == id, "Settings refresh lost manual selection")
}
runtime.motionPackageStore!.selected = Motion(id: "builtin.motion.natural-idle", format: .procedural)
runtime.refresh()
precondition(runtime.snapshot.motion?.id == "gmgn.motion.bones.idle-loop-vrm")
print("PASS production refresh preserves selected VRMA/VMD and only replaces procedural idle")
"""#
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("main.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [file.path]
try process.run(); process.waitUntilExit()
exit(process.terminationStatus)
