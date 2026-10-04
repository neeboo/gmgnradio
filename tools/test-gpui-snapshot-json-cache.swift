import Foundation
let source = try String(contentsOfFile: "apps/macos/ProductHost/ProductSnapshotEncoder.swift", encoding: .utf8)
let harness = source + """

let encoder = ProductSnapshotEncoder()
let lines = (0..<1000).map { ["id": String($0), "text": "真实来源结构测试", "start": $0] as [String: Any] }
func snapshot(_ time: Int, notice: String) -> [String: Any] {
    ["events": [], "state": ["lyrics": ["lines": lines, "playbackTime": time, "animationTime": time],
        "settings": ["voices": lines], "statusNotice": notice, "transcript": [["role": "agent", "text": notice]]]]
}
let original = snapshot(0, notice: "初始")
let first = try encoder.encode(original)
let decodedFirst = try JSONSerialization.jsonObject(with: first) as! [String: Any]
precondition(NSDictionary(dictionary: decodedFirst).isEqual(to: original))
let baseline = encoder.serializationCount
for _ in 0..<50 { _ = try encoder.encode(original) }
precondition(encoder.serializationCount == baseline, "unchanged polls must not repeat array JSON serialization")
let updated = snapshot(1, notice: "变更")
let data = try encoder.encode(updated)
let decodedUpdated = try JSONSerialization.jsonObject(with: data) as! [String: Any]
precondition(NSDictionary(dictionary: decodedUpdated).isEqual(to: updated))
precondition(encoder.serializationCount == baseline + 4, "two clocks and status/transcript change; lyric/catalog arrays stay cached")
print("PASS: complete JSON semantic equality, 50 unchanged polls no reserialization, dynamic clocks/status updated while catalog arrays stay cached")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gpui-snapshot-cache-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("test.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/swift"); process.arguments = [file.path]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
