// Headless policy execution and wiring checks. Does not open the application.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift"), encoding: .utf8)
let controller = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"), encoding: .utf8)
func declaration(_ signature: String) -> String? {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    return nil
}
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
let declarations = ["enum StageVisualPickerMode:", "enum StageVisualPickerGroup:", "enum StageControlPanelTab:", "enum StageControlPanelLayout", "enum StageActivityAvailability"]
for signature in declarations { check(declaration(signature) != nil, "Missing policy: \(signature)") }
check(source.contains("ScrollView {") && source.contains("Picker(\"设置分区\""), "Control panel needs scrollable sections")
check(source.contains("model.activateMotion(motion)"), "Motion row must call existing activation")
check(source.contains("model.motionCompatibility(motion)"), "Motion compatibility must control selection")
check(source.contains("onRunActivity(item.id)") && source.contains("Button(\"停止活动\", action: onStopActivity)"), "Activities must call the app handlers")
check(source.contains("Button(\"管理角色与动作…\", action: onManageAssets)"), "Asset management must be reachable")
check(source.contains("spatialStage.resetCamera()"), "Space settings must expose camera reset")
check(controller.contains("title = \"设置\""), "Settings button needs a visible title")
check(controller.contains("visualPicker.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor"), "Panel must fit parent width")
check(controller.contains("visualPicker.topAnchor.constraint(greaterThanOrEqualTo: topAnchor"), "Panel must fit parent height")
for callback in ["onRunActivity", "onStopActivity", "onManageAssets"] {
    check(controller.components(separatedBy: "\(callback): \(callback)").count - 1 == 2, "\(callback) must be forwarded through controller and content view")
}
guard failures == 0 else { exit(1) }
let harness = "import Foundation\n" + declarations.compactMap(declaration).joined(separator: "\n") + #"""

precondition(StageControlPanelTab.available(for: .player) == [.visuals, .motions])
precondition(StageControlPanelTab.available(for: .space) == [.visuals, .motions, .activities])
precondition(StageControlPanelTab.activities.resolved(for: .player) == .visuals)
precondition(StageControlPanelTab.motions.resolved(for: .player) == .motions)
precondition(StageControlPanelTab.motions.resolved(for: .space) == .motions)
precondition(StageControlPanelTab.visuals.title(for: .player) == "画面")
precondition(StageControlPanelTab.visuals.title(for: .space) == "空间")
precondition(StageVisualPickerGroup.visibleGroups(for: .player) == [.lyricsEffects, .pointCloud, .particleSize, .musicVideo])
precondition(StageVisualPickerGroup.visibleGroups(for: .space) == [.worldSelection, .avatarPlacement, .loadingStatus])
precondition(StageControlPanelLayout.maximumWidth == 590 && StageControlPanelLayout.maximumHeight == 458)
precondition(StageControlPanelLayout.transportWidth == StageControlPanelLayout.settingsLeading + StageControlPanelLayout.settingsWidth + 1 + 44 + 4)
precondition(StageActivityAvailability.canRun(isWorldVisible: true, selectedWorldID: "a", activityWorldID: "a"))
precondition(!StageActivityAvailability.canRun(isWorldVisible: false, selectedWorldID: "a", activityWorldID: "a"))
precondition(!StageActivityAvailability.canRun(isWorldVisible: true, selectedWorldID: "b", activityWorldID: "a"))
precondition(!StageActivityAvailability.canRun(isWorldVisible: true, selectedWorldID: nil, activityWorldID: nil))
print("PASS: panel mode, preserved groups, activity availability, layout policy and source wiring")
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-panel-tests-\(UUID()).swift")
try harness.write(to: temporary, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: temporary) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [temporary.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
