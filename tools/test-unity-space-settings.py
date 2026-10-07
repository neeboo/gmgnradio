#!/usr/bin/env python3
"""Compile the real package bridge, defaults enum and secret provider/model offline."""
from pathlib import Path
import subprocess
import tempfile
import sys

repo = Path(__file__).resolve().parents[1]
settings = (repo / "apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift").read_text()
preference = "import Foundation\n enum DefaultSpacePreference" + settings.split("enum DefaultSpacePreference", 1)[1].split("@MainActor\nstruct GMGNSettingsView", 1)[0]
provider = (repo / "apps/macos/Sources/GMGNRadio/VisualEngine/MarbleWorldClient.swift").read_text().split("actor MarbleWorldClient", 1)[0]
product = (repo / "apps/macos/UnityHost/UnityProductSettings.swift").read_text()
key_init = product.split("        marbleAPIKey = MarbleAPIKeySettingsModel", 1)[1].split("        self.productVoiceDefaults", 1)[0]
key_commands = product.split('        case "space.key.save":', 1)[1].split('        case "app.language":', 1)[0]
key_projection = product.split('            "space": [', 1)[1].split('            "agent":', 1)[0].rstrip().removesuffix(',')
preference += '''
@MainActor final class TestProductKeys {
    private let marbleAPIKey: MarbleAPIKeySettingsModel
    private var marbleMutationRevision: UInt64 = 0
    init(root: URL) { marbleAPIKey = MarbleAPIKeySettingsModel''' + key_init + ''' }
    var snapshot: [String: Any] { [''' + key_projection + ''' }
    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op { case "space.key.save":''' + key_commands + ''' default: return false }
        return true
    }
}
'''
flags = subprocess.check_output(["sh", str(repo / "tools/world-runtime-harness-flags.sh")], text=True).splitlines()
package = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "tmp/unity-player-release-v152.app/Contents/Resources/Worlds/marble-living-cabin"
with tempfile.TemporaryDirectory(prefix="gmgn-space-settings-") as directory:
    temporary = Path(directory)
    enum_source = temporary / "preference.swift"
    enum_source.write_text(preference)
    provider_source = temporary / "provider.swift"
    provider_source.write_text(provider)
    executable = temporary / "test"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *flags,
                    str(enum_source), str(provider_source),
                    str(repo / "apps/macos/Sources/GMGNRadio/Settings/MarbleAPIKeySettingsModel.swift"),
                    str(repo / "apps/macos/UnityHost/UnitySpaceLibraryBridge.swift"),
                    str(repo / "tools/test-unity-space-library.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(package), str(temporary / "isolated-support")], check=True)
