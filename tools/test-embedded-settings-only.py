#!/usr/bin/env python3
"""Source contract: Unity settings use the embedded GPUI owner only."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
host = (root / "apps/macos/UnityHost/UnityMediaHost.swift").read_text()
package = (root / "tools/package-unity-media-host.sh").read_text()
probe = (root / "apps/unity-player/Assets/GMGN/GPUIChat2Probe.cs").read_text()
assert not (root / "apps/macos/UnityHost/UnitySettingsBridge.swift").exists()
assert not (root / "tools/unity-settings-info.plist").exists()
for retired in ("UnitySettingsBridge", "settingsBridge", 'case "settings.open"'):
    assert retired not in host, retired
for retired in ("GMGN Unity Settings", "gmgn-unity-settings", "settings_app", "settings_binary"):
    assert retired not in package, retired
for retained in ('"ui.settings.command"', "await self.settingsCommand(command)", '"settings": settingsSnapshot()', "private func settingsSnapshot()"):
    assert retained in host, retained
assert '"设置" => "ui.settings.open"' in probe
assert "gmgn-taskd" in package
print("PASS embedded settings navigation, native handlers, and taskd packaging contract")
