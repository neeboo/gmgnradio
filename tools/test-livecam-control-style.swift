// Headless source and geometry regression; no AppKit initialization or host.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let panel = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift"), encoding: .utf8)
let inbox = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInboxUI.swift"), encoding: .utf8)
var failures = 0
func check(_ result: Bool, _ label: String) {
    if !result { failures += 1; print("FAIL: \(label)") }
}
check(!panel.contains("controls.heightAnchor.constraint(equalToConstant: 174)"), "six controls cannot fit the previous five-control height")
check(panel.contains("CGFloat(controls.arrangedSubviews.count) * 30") && panel.contains("CGFloat(controls.arrangedSubviews.count - 1) * controls.spacing"), "stack height derives from actual control count and gaps")
check(panel.contains("configureControlSurface(mailButton)"), "mail gets the same stable surface as other controls")
check(panel.contains("configureControlSurface(button)"), "regular controls share the surface implementation")
check(panel.contains("NSColor(white: 0.12, alpha: 0.94)") && panel.contains("borderWidth = 1"), "contrast remains stable on white and black backgrounds")
check(panel.contains("mailButton.setIconStyle(pointSize: 16, color: .white)") && panel.contains("pointSize: 16, weight: .regular"), "all symbols have one size and weight")
check(inbox.contains("private var restingTint") && inbox.contains("count > 0 ? .white : restingTint"), "unread updates preserve the configured mail contrast")
check(panel.contains("symbolName: \"message\"") && panel.contains("symbolName: \"gearshape\""), "chat and settings use the shared outline style")
print("\(failures == 0 ? "PASS" : "FAIL"): Live Cam six-control geometry and appearance, \(failures) failures")
exit(failures == 0 ? 0 : 1)
