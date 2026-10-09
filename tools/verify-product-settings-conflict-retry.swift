//
//  verify-product-settings-conflict-retry.swift
//  GMGNRadio
//
//  `RustProductSettingsClient.mutate` revision 冲突恢复的离线验证入口。
//
//  入口只做两件事：用真实源码 + 最小替身 **编译**，然后 **运行** 那份验证。
//  编译门：`-swift-version 6 -parse-as-library`（与 apps/macos/project.yml 的
//  `SWIFT_VERSION: "6.0"` 一致）。
//
//  运行：`swift tools/verify-product-settings-conflict-retry.swift`（仓库根目录）。
//  无网络、无 taskd、无 Keychain、无 UI、无 AppleScript、无 xcodebuild test。
//
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-settings-retry-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let sources = [
    "apps/macos/Sources/GMGNRadio/Presence/RustProductSettingsClient.swift",
    "tools/verify-product-settings-conflict-retry-support.swift",
]
var arguments = ["-swift-version", "6", "-parse-as-library", "-j1"]
for relative in sources {
    let path = root.appendingPathComponent(relative).path
    guard FileManager.default.fileExists(atPath: path) else {
        print("MISSING SOURCE: \(relative)")
        exit(1)
    }
    arguments.append(path)
}
let binary = work.appendingPathComponent("verify-product-settings-conflict-retry")
arguments.append(contentsOf: ["-o", binary.path])

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compile.arguments = ["swiftc"] + arguments
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("swift6 compile FAILED: exit=\(compile.terminationStatus)")
    exit(1)
}

let run = Process()
run.executableURL = binary
try run.run()
run.waitUntilExit()
print("swift6 compile+run exit=\(run.terminationStatus)")
exit(run.terminationStatus)
