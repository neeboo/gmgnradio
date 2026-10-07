#!/usr/bin/env python3
"""Run actual frame persistence guard against a window/defaults test double."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "apps/macos/UnityHost/UnityWindowModeBridge.swift").read_text()
method = source.split("    private func saveNormalFrame", 1)[1].split("    func setCompact", 1)[0]
program = '''import Foundation
import CoreGraphics
struct StyleMask: OptionSet {
    let rawValue: Int
    static let fullScreen = StyleMask(rawValue: 1)
}
struct NSWindow {
    var frame = NSRect(origin: .zero, size: NSSize(width: 1440, height: 900))
    var styleMask: StyleMask = []
    func contentRect(forFrameRect frame: NSRect) -> NSRect { frame }
}
final class Defaults {
    var writes = 0
    func set(_ value: String, forKey: String) { writes += 1 }
}
final class Probe {
    var isCompact = false, changingWindowMode = false, fullscreenTransition = false
    private var lastSavedNormalFrame: String?
    static let normalFrameKey = "test-only"
    let defaults = Defaults()
    private func saveNormalFrame''' + method + '''
    func sample(_ window: NSWindow) { saveNormalFrame(window) }
}
let probe = Probe()
var window = NSWindow()
for _ in 0..<10000 { probe.sample(window) }
precondition(probe.defaults.writes == 1, "Pointer polls repeatedly wrote preferences")
probe.fullscreenTransition = true
window.frame.size = NSSize(width: 4096, height: 2304)
probe.sample(window)
precondition(probe.defaults.writes == 1, "Transition persisted fullscreen intermediate frame")
probe.fullscreenTransition = false
window.styleMask = .fullScreen
probe.sample(window)
precondition(probe.defaults.writes == 1)
window.styleMask = []
window.frame.size = NSSize(width: 1024, height: 720)
probe.sample(window)
precondition(probe.defaults.writes == 2, "Actual normal resize not saved")
probe.isCompact = true
window.frame.size = NSSize(width: 224, height: 336)
probe.sample(window)
precondition(probe.defaults.writes == 2)
print("PASS: actual window persistence guard, 10000 polls/transition/fullscreen/resize/compact")
'''
with tempfile.TemporaryDirectory(prefix="gmgn-window-persist-") as temporary:
    directory = Path(temporary)
    swift = directory / "main.swift"
    swift.write_text(program)
    executable = directory / "window-check"
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
