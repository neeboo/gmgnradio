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
check(source.contains("ForEach(StageControlPanelTab.allCases") && !source.contains(".onChange(of: mode)"), "All four sections must remain available without scene-driven tab changes")
check(source.contains("这些效果用于播放器画面，切回播放器后可查看"), "Player effects need a clear scope note while in space")
check(source.contains(".fill(Color(red: 0.075, green: 0.085, blue: 0.105))"), "Panel requires a stable graphite background")
check(controller.contains("let groupDivider = NSView()") && !controller.contains("let dividers = (0 ..< 6)"), "Transport should use one group divider")
check(controller.contains("imageHugsTitle = true") && controller.contains("? \"xmark\" : \"slider.horizontal.3\""), "Settings icon and text should form one compact label with a distinct expanded state")
check(source.contains("LazyVGrid(columns: videoColumns"), "MV choices must wrap in narrow panels")
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

precondition(StageControlPanelTab.allCases == [.player, .space, .motions, .activities])
precondition(StageControlPanelTab.initial(for: .player) == .player)
precondition(StageControlPanelTab.initial(for: .space) == .space)
precondition(StageControlPanelTab.allCases.map(\.title) == ["播放器", "空间", "角色", "活动"])
precondition(StageVisualPickerGroup.visibleGroups(for: .player) == [.lyricsEffects, .pointCloud, .particleSize, .musicVideo])
precondition(StageVisualPickerGroup.visibleGroups(for: .space) == [.worldSelection, .avatarPlacement, .loadingStatus])
precondition(StageControlPanelLayout.maximumWidth == 590 && StageControlPanelLayout.maximumHeight == 458)
precondition(StageControlPanelLayout.controlSize >= 44)
precondition(StageControlPanelLayout.transportWidth == 7 * StageControlPanelLayout.controlSize + StageControlPanelLayout.settingsWidth + 2 * StageControlPanelLayout.sideInset + 2 * StageControlPanelLayout.groupGap + 1)
precondition(StageActivityAvailability.canRun(isWorldVisible: true, selectedWorldID: "a", activityWorldID: "a"))
precondition(!StageActivityAvailability.canRun(isWorldVisible: false, selectedWorldID: "a", activityWorldID: "a"))
precondition(!StageActivityAvailability.canRun(isWorldVisible: true, selectedWorldID: "b", activityWorldID: "a"))
precondition(!StageActivityAvailability.canRun(isWorldVisible: true, selectedWorldID: nil, activityWorldID: nil))
precondition(StageActivityAvailability.unavailableMessage(isWorldVisible: false, isWorldPresentationRequested: false) == "进入空间后可选择生活活动。")
precondition(StageActivityAvailability.unavailableMessage(isWorldVisible: false, isWorldPresentationRequested: true) == "空间载入完成后可选择活动。")
precondition(StageActivityAvailability.unavailableMessage(isWorldVisible: true, isWorldPresentationRequested: true) == "这个空间还没有配置生活活动。")
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
