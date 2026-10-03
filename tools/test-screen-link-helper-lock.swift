// 内置 helper 的**打包钉死清单 ↔ 运行时清单**一致性判据。
//
// 2026-10-03 验收的硬缺口是"`BundledHelperManifest.pinned` 的 yt-dlp sha256 为空 ⇒
// 生产定位器 fail-closed，只有显式开发覆盖才放行"，也就是**从来没真的钉过哈希**。
// 修好之后，版本 / 来源 / sha256 / 许可必须只有一处可复现来源：
//
//   tools/helpers/screen-link-helpers.lock.json   （打包脚本读它下载 + 校验）
//   BundledHelperManifest.pinned                  （运行时读它定位 + 校验）
//
// 这一份把两边**逐字段**对起来，并且做注入负对照：空哈希 / 版本漂移 / 许可漂移 /
// 少一个源码组件，四种都必须让内层判据变红。
//
// 用法：swift tools/test-screen-link-helper-lock.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resolverRoot = root
    .appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen/LinkResolver")

let innerProgram = ##"""
import Foundation

var failuresTotal = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failuresTotal += 1 }
}

/// 返回两边不一致的地方（空数组 = 一致）。
func discrepancies(lockPath: String, manifest: BundledHelperManifest) -> [String] {
    var problems: [String] = []
    guard let data = FileManager.default.contents(atPath: lockPath),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        return ["锁文件读不出来或不是 JSON：\(lockPath)"]
    }
    guard let helpers = object["helpers"] as? [[String: Any]] else {
        return ["锁文件里没有 helpers 数组"]
    }
    if (object["notices_path"] as? String) != manifest.noticesPath {
        problems.append("notices_path 与 manifest.noticesPath 不一致")
    }
    var seen: Set<String> = []
    for entry in helpers {
        guard let name = entry["name"] as? String,
              let helper = manifest.helper(named: name)
        else {
            problems.append("锁文件里的 helper 在运行时清单里没有：\(entry["name"] ?? "?")")
            continue
        }
        seen.insert(name)
        if (entry["version"] as? String) != helper.version {
            problems.append("\(name)：版本漂移（锁 \(entry["version"] ?? "?") / 运行 \(helper.version)）")
        }
        if let hash = entry["sha256"] as? String {
            if hash.lowercased() != helper.sha256.lowercased() {
                problems.append("\(name)：sha256 漂移（锁 \(hash) / 运行 \(helper.sha256)）")
            }
            if hash.count != 64 || !hash.allSatisfy(\.isHexDigit) {
                problems.append("\(name)：锁里的 sha256 不是 64 位十六进制")
            }
        } else {
            problems.append("\(name)：锁里没有 sha256")
        }
        if (entry["distribution"] as? String) != helper.distribution.rawValue {
            problems.append("\(name)：分发形态漂移")
        }
        if (entry["source_url"] as? String) != helper.sourceURL {
            problems.append("\(name)：来源地址漂移")
        }
        if (entry["upstream_license_spdx"] as? String) != helper.upstreamLicenseSPDX {
            problems.append("\(name)：上游许可漂移")
        }
        if (entry["combined_work_license_spdx"] as? String) != helper.combinedWorkLicenseSPDX {
            problems.append("\(name)：组合作品许可漂移")
        }
        // 可执行 helper 不许留空哈希（"不要空 hash 交付"）。
        if !helper.isPinned {
            problems.append("\(name)：运行时清单里的 sha256 没有钉死")
        }
    }
    for helper in manifest.helpers where !seen.contains(helper.name) {
        problems.append("运行时清单里的 helper 在锁文件里没有：\(helper.name)")
    }
    // 源码组件（没有单文件 sha256 的那些）也必须**双向**登记齐全。
    if let components = object["source_components"] as? [[String: Any]] {
        var locked: Set<String> = []
        for component in components {
            guard let name = component["name"] as? String else { continue }
            locked.insert(name)
            guard let registered = manifest.components.first(where: { $0.name == name }) else {
                problems.append("锁里的源码组件在运行时清单里没有：\(name)")
                continue
            }
            if (component["license_spdx"] as? String) != registered.licenseSPDX {
                problems.append("\(name)：源码组件许可漂移")
            }
        }
        for component in manifest.components where !locked.contains(component.name) {
            problems.append("运行时清单里的源码组件在锁文件里没有：\(component.name)")
        }
    } else {
        problems.append("锁文件里没有 source_components")
    }
    return problems
}

func tamper(_ object: [String: Any], _ mutate: (inout [[String: Any]]) -> Void) -> [String: Any] {
    var copy = object
    var helpers = (copy["helpers"] as? [[String: Any]]) ?? []
    mutate(&helpers)
    copy["helpers"] = helpers
    return copy
}

@main struct Probe {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            print("FAIL 缺少锁文件路径")
            exit(2)
        }
        let lockPath = CommandLine.arguments[1]
        guard let data = FileManager.default.contents(atPath: lockPath),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            print("FAIL 锁文件读不出来：\(lockPath)")
            exit(2)
        }

        let real = discrepancies(lockPath: lockPath, manifest: .pinned)
        expect(real.isEmpty, "锁文件与运行时清单逐字段一致（\(real.joined(separator: "；"))）")

        let ytdlp = BundledHelperManifest.pinned.helper(named: "yt-dlp")
        expect(ytdlp != nil, "运行时清单里有 yt-dlp")
        expect(BundledHelperManifest.pinned.helper(named: "yt-dlp")?.isPinned == true,
            "yt-dlp 的 sha256 已钉死（不再是空哈希）")
        expect(BundledHelperManifest.pinned.helper(named: "deno")?.isPinned == true,
            "deno 的 sha256 已钉死（不再是空版本 + 空哈希）")

        // 注入负对照：临时写四份被改过的锁，每一份都必须被判出问题。
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-helper-lock-\(UUID())")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func write(_ value: [String: Any]) -> String {
            let url = temporary.appendingPathComponent("lock-\(UUID()).json")
            let bytes = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
            try? bytes.write(to: url)
            return url.path
        }
        func reject(_ label: String, _ value: [String: Any]) {
            let path = write(value)
            let problems = discrepancies(lockPath: path, manifest: .pinned)
            expect(!problems.isEmpty, "注入\(label) ⇒ 必须变红（\(problems.first ?? "无")）")
        }
        reject("空 yt-dlp 哈希", tamper(object) { helpers in
            for index in helpers.indices where helpers[index]["name"] as? String == "yt-dlp" {
                helpers[index]["sha256"] = ""
            }
        })
        reject("版本漂移", tamper(object) { helpers in
            for index in helpers.indices where helpers[index]["name"] as? String == "yt-dlp" {
                helpers[index]["version"] = "1999.01.01"
            }
        })
        reject("许可漂移", tamper(object) { helpers in
            for index in helpers.indices where helpers[index]["name"] as? String == "yt-dlp" {
                helpers[index]["combined_work_license_spdx"] = "Unlicense"
            }
        })
        var missingComponent = object
        missingComponent["source_components"] = [[String: Any]]()
        reject("少一个源码组件", missingComponent)

        print("---")
        print("failures=\(failuresTotal)")
        exit(failuresTotal == 0 ? 0 : 1)
    }
}
"""##

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-helper-lock-probe-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

var sources: [String] = []
for name in ["BundledHelperManifest.swift"] {
    let destination = temporary.appendingPathComponent(name)
    try FileManager.default.copyItem(
        at: resolverRoot.appendingPathComponent(name), to: destination
    )
    sources.append(destination.path)
}
let program = temporary.appendingPathComponent("Probe.swift")
try innerProgram.write(to: program, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("probe")
let lockPath = root.appendingPathComponent("tools/helpers/screen-link-helpers.lock.json").path

func runCapturing(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let compile = try runCapturing(
    "/usr/bin/swiftc", ["-j1", "-parse-as-library"] + sources + [program.path, "-o", binary.path]
)
guard compile.status == 0 else {
    FileHandle.standardError.write(Data("PROBE COMPILE FAILED\n\(compile.output)\n".utf8))
    exit(70)
}
let run = try runCapturing(binary.path, [lockPath])
FileHandle.standardOutput.write(Data(run.output.utf8))
exit(run.status)
