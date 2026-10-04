import Foundation

let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift", encoding: .utf8)
let content = String(source[source.range(of: "private final class StageContentView")!.lowerBound...])
func declaration(_ signature: String) -> String {
    let start = content.range(of: signature)!.lowerBound
    let opening = content[start...].firstIndex(of: "{")!
    var depth = 0
    for index in content[opening...].indices {
        if content[index] == "{" { depth += 1 }
        if content[index] == "}" { depth -= 1 }
        if depth == 0 { return String(content[start...index]).replacingOccurrences(of: "private func", with: "func") }
    }
    fatalError("unterminated production method")
}
let property = String(content[content.range(of: "    private var metalView: MetalStageView?")!])
let harness = """
import AppKit
final class MetalStageView: NSView {}
final class Host: NSView {
\(property)
    let renderSurfaceContainer = NSView()
    weak var observedPlayer: MetalStageView?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(renderSurfaceContainer)
        let player = MetalStageView(frame: bounds)
        metalView = player; observedPlayer = player
        addSubview(player)
    }
    required init?(coder: NSCoder) { fatalError() }
    func restoreNativeWorldInteraction() { restoreNativePlayerSurface() }
\(declaration("func attachGPUIPlayerSurface(to container: NSView)"))
\(declaration("private func restoreNativePlayerSurface()"))
}
let host = Host(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
let identity = ObjectIdentifier(host.observedPlayer!)
for _ in 0..<8 {
    autoreleasepool {
        let old = NSView(frame: host.bounds)
        precondition(host.attachGPUIPlayerSurface(to: old))
        precondition(host.observedPlayer?.superview === old)
    }
    precondition(host.observedPlayer != nil, "closing the previous GPUI container must not destroy the original player")
    let replacement = NSView(frame: host.bounds)
    precondition(host.attachGPUIPlayerSurface(to: replacement))
    precondition(ObjectIdentifier(host.observedPlayer!) == identity)
    host.restoreNativePlayerSurface()
    precondition(host.observedPlayer?.superview === host)
}
print("PASS: actual production player attach/restore, eight released-container transitions, same original instance")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gpui-player-lifecycle-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("callback.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [file.path]
try process.run(); process.waitUntilExit()
exit(process.terminationStatus)
