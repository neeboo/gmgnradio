// Source-backed pure test. No AppKit window, application or test host is started.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/ResidentImageAttachment.swift"
)
let source = try String(contentsOf: sourceURL, encoding: .utf8)

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

let policy = declaration("enum ResidentTextInputPolicy", in: source)
let harness = """
import Foundation
\(policy)

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \\(message)") }
}

check(!ResidentTextInputPolicy.shouldApplyExternalText(
    fieldText: "ni", externalText: "", isComposing: true
), "external refresh cannot erase active Chinese composition")
check(ResidentTextInputPolicy.shouldApplyExternalText(
    fieldText: "旧文字", externalText: "新文字", isComposing: false
), "external recovery still updates an idle editor")
check(!ResidentTextInputPolicy.shouldApplyExternalText(
    fieldText: "相同", externalText: "相同", isComposing: false
), "identical text is not rewritten")
check(!ResidentTextInputPolicy.shouldSubmit(isComposing: true),
      "return during Chinese composition cannot send the message")
check(ResidentTextInputPolicy.shouldSubmit(isComposing: false),
      "return sends after composition finishes")

print("\\(failures == 0 ? \"PASS\" : \"FAIL\"): resident Chinese text composition")
exit(failures == 0 ? 0 : 1)
"""

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-resident-text-\(UUID())")
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
